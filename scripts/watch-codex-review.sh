#!/usr/bin/env bash
# Poll a GitHub PR for a review response (from Codex, or any other
# review-on-comment bot) instead of manually re-checking it yourself every
# few minutes.
#
# Usage:
#   ./watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval SECONDS] [--timeout SECONDS] [--bot LOGIN] [--trigger-comment TEXT]
#
#   --trigger        post a comment (see --trigger-comment) as a new PR comment
#                    before watching
#   --interval N     seconds between checks (default 20)
#   --timeout N      give up after this many seconds (default 900 = 15 min)
#   --bot LOGIN      .user.login to treat as the reviewer for the issue-comments
#                    check (default "chatgpt-codex-connector[bot]") — see gotcha #18
#   --trigger-comment TEXT
#                    the comment body --trigger posts (default "@codex review").
#                    Change this alongside --bot when watching a different
#                    review-on-comment bot — Codex's trigger phrase won't summon
#                    anyone else's bot. See gotcha #31.
#
# Exits 0 and prints a summary the moment a genuinely new review or review
# comment (by ID, not just a changed count) appears after the watch started.
# Exits 1 on timeout.
#
# Requires: gh (authenticated), jq
#
# Gotchas this script exists to get right:
#
# 1. `gh api --jq <expr>` only accepts a single query-string argument — it
#    does NOT understand jq's own flags like `--arg`. `gh api ... --jq --arg
#    since "$SINCE" '...'` silently mis-parses: `--jq` swallows the literal
#    string "--arg" as its entire query, and `since`, `$SINCE`, and the real
#    filter all become stray positional arguments, which gh then rejects (or,
#    worse, just no-ops). If you need a parametrized filter, pipe the raw
#    JSON into the real `jq` binary instead — that's what every query below
#    does, on purpose.
#
# 2. Plain `gh api <list-endpoint>` only returns the first page (30 items by
#    default). A PR with more history than that would silently look
#    unchanged to this script forever. `--paginate --slurp` fetches every
#    page and wraps them as an array of per-page arrays, so `jq 'add'`
#    flattens them back into one real list — see api_list() below.
#
# 3. Detecting activity by comparing item *counts* to a baseline is fooled
#    two different ways: a deletion can land at the same moment as a new
#    item and cancel it out in the count, or a deletion alone can make the
#    count look "changed" with nothing new to actually report. Comparing IDs
#    against a baseline ID set — new activity is anything whose ID wasn't in
#    the baseline — has neither failure mode, so that's what both reviews
#    and comments use below, never a raw count.
#
# 4. Comparing `submitted_at` to a captured timestamp has a second-resolution
#    race on top of the count problem above: a review submitted in the same
#    UTC second the baseline was captured compares equal, not greater, and a
#    strict `>` would silently miss it. ID comparison sidesteps this too.
#
# 5. `sleep "$INTERVAL"` every iteration, uncorrected, lets the script run
#    well past `--timeout`: once because a timeout shorter than one interval
#    still sleeps the full interval, and every time because the seconds
#    spent actually making the paginated API requests are never subtracted
#    from the budget. This script tracks wall-clock elapsed time from a
#    fixed start and caps each sleep at whatever's left.
#
# 6. "Cap sleep at whatever's left" and "always poll at least once" are two
#    separate requirements, not one — collapsing them into a single "recheck
#    the deadline, then maybe sleep, then poll" loop means a --timeout at or
#    below --interval consumes the entire budget in that first capped sleep
#    and the loop exits before ever making a single request, so even an
#    instant response is never observed. The fix is to poll once
#    unconditionally before the deadline-bounded loop even starts, then let
#    that loop's sleep-then-recheck logic govern every poll after the first.
#
# 7. Calling a function as the left side of `&&` (as poll_once is, both here
#    and in the loop) disables `set -e` for every command inside that
#    function, not just its own return value — a well-known bash gotcha. If
#    a `gh api` call inside poll_once fails (rate limit, network blip), the
#    assignment silently keeps going with empty/garbage JSON instead of
#    stopping, and later commands can fail confusingly (`jq`/`[` erroring on
#    empty input) or, worse, just report a misleading timeout instead of the
#    real error. Every command inside poll_once that can fail is checked
#    explicitly with `|| exit 1` instead of relying on errexit to catch it.
#
# 8. None of the above bounds an individual `gh api` call itself — a request
#    that stalls (or a slow/rate-limited response) can still block past
#    `--timeout` on its own, however tight the sleep/deadline logic around it
#    is. `with_timeout` below bounds each request to whatever's left of the
#    budget, by polling `kill -0` on the backgrounded command once a second
#    rather than calling the `timeout` command — `timeout` isn't part of a
#    stock macOS install (only Linux and Git-for-Windows ship it by default),
#    so depending on it would silently break for a chunk of users the first
#    time a request actually hangs, which is exactly when it matters. A
#    background-`sleep`-plus-`kill` watchdog was the first attempt at this,
#    but killing the watchdog process once the real command finishes doesn't
#    kill the `sleep` it's blocked on — Unix reparents that child instead of
#    ending it, so it lingers for its full original duration every time,
#    piling up one straggler per poll. `bash 4.3+`'s `wait -n` can wait on
#    either of two backgrounded jobs and would avoid that, but stock macOS
#    ships bash 3.2 (GPL licensing), which doesn't have it — so this polls
#    instead of blocking on anything backgrounded, and never creates a
#    process it has to remember to separately clean up.
#
# 9. `remaining` can reach zero or go negative mid-`poll_once` — e.g. the
#    reviews request used almost the whole budget, so `remaining` recomputed
#    right before the comments request is already <= 0. Passed straight
#    through, that collides with `with_timeout`'s own "`<= 0` means
#    unbounded" sentinel (intentional for the one-time baseline calls, which
#    pass `$TIMEOUT` — a real bound, see #11 below), so an exhausted budget
#    would mean "no bound at all" — the opposite of the intent. An earlier
#    version of this fix clamped `remaining` up to a minimum of 1 instead,
#    which avoided the unbounded sentinel but is its own bug: it grants a
#    bonus second to a request that shouldn't be attempted at all once the
#    deadline has already passed, so `--timeout 1` could still run ~2
#    seconds long. `poll_once` now checks `remaining <= 0` and returns
#    (without attempting the request) before every `api_list` call instead
#    of clamping — an exhausted budget is treated as "nothing new to report
#    this round," identical to a normal empty check, and the outer loop's
#    own deadline test is what turns that into the final timeout message.
#
# 10. `with_timeout` originally merged the wrapped command's stdout and
#     stderr into one captured stream (`2>&1`). `gh` can write to stderr on
#     an otherwise-successful call — an update-available notice, or
#     `GH_DEBUG` output — and merging the two lets that text land ahead of
#     the JSON that gets piped into `jq`, breaking the parse even though the
#     API request itself worked. stdout and stderr are captured to separate
#     files instead; stderr is still replayed to our own stderr afterward,
#     so nothing is silently dropped, it just can't corrupt the JSON stream.
#
# 11. The two one-time baseline requests were bounded with a literal `0`
#     ("unbounded"), and `START_TS` wasn't set until after they finished —
#     so a stalled baseline request could hang forever before the watcher
#     ever entered its own deadline-bounded loop, well past the advertised
#     `--timeout`. `START_TS` is now set first, and both baseline requests
#     are bounded, so the whole script's "give up after this many seconds"
#     promise actually covers its full run, not just the polling loop after
#     setup.
#
# 12. Two things that first fix (#11) still got wrong: it passed `$TIMEOUT`
#     — the *original* full budget — to the second baseline request too,
#     instead of recomputing what's actually left after the first one ran;
#     sequential calls that each get handed the full budget can together run
#     for close to their combined total before anything fails, the same
#     mistake `poll_once` had already been fixed to avoid. And the
#     `--trigger` comment POST wasn't wrapped in `with_timeout` at all, so a
#     stalled post could still block past `--timeout` even though the clock
#     was already running by that point. Both now recompute the remaining
#     budget immediately before they run, bail out if it's already gone, and
#     — for the trigger POST — go through `with_timeout` like every other
#     network call.
#
# 13. All of the above guards `remaining` at every internal call site, but
#     none of it stops a user from passing `--timeout 0` or a negative
#     number directly — which reaches `with_timeout`'s own "`<= 0` means
#     unbounded" sentinel on the very first request, turning an obviously
#     broken input into "run forever" instead of a clear, immediate error.
#     `--timeout` (and `--interval`, same risk class) are validated as
#     positive integers right after argument parsing, before anything runs.
#
# 14. `with_timeout`'s completion check only ran once a second — fine for
#     actually catching a stall, but it means a command that finishes in,
#     say, 50ms can still sit through most of a second before the next
#     `kill -0` notices it's done. That's not free: `poll_once` makes two
#     of these calls, baseline setup makes two more, and a fast, healthy
#     response pays that ~1s tax on every single one of them — enough that
#     a `--timeout` in the low single digits could expire before a single
#     real request even finished, independent of the network. Polling every
#     0.1s instead of every 1s cuts that worst case by 10x.
#
# 15. Reviews and inline review comments (`pulls/.../reviews`,
#     `pulls/.../comments`) only exist when Codex actually has findings to
#     post. A clean pass — no findings — lands as a plain comment on the
#     issue-comments timeline instead ("Codex Review: Didn't find any major
#     issues. Delightful!"), an endpoint this script didn't watch at all
#     until this gotcha was written — discovered live, by this exact PR
#     going "all clear" and the watcher still reporting a timeout. Watching
#     only the first two endpoints means a genuinely clean response is
#     indistinguishable from Codex never responding. `issues/$PR/comments`
#     is now a third watched endpoint, baselined the same race-free way as
#     the other two (captured before the trigger comment is posted) — which
#     means the trigger comment itself would otherwise look like "new
#     activity" the moment it's posted. Its own ID, parsed out of `gh pr
#     comment`'s URL output, is folded into the baseline explicitly so it's
#     excluded without reintroducing that race.
#
# 16. #15's fix opened its own gap: `issues/$PR/comments` is a general
#     conversation thread, not a review-response channel — anyone can post
#     there. Treating any new comment there as "Codex responded" means a
#     human saying literally anything on the PR while the watcher is running
#     produces a false success. `new_bot_comments_by_id` originally filtered
#     to `.user.type == "Bot"` before checking for a new ID — narrowed
#     further to a specific bot login in #18 below, once it turned out "any
#     bot" had the same problem as "any commenter."
#
# 17. Known, accepted gap, not fixed: `START_TS` and every `remaining`/
#     `ELAPSED` computation use `date +%s`, which truncates to whole
#     seconds. Near a second boundary, a `--timeout` of a few seconds can
#     look exhausted early or run up to ~1s late. A real fix needs subsecond
#     timestamps, and the portable ways to get them are worse than the
#     problem: GNU `date`'s `%N` (nanoseconds) isn't available on stock
#     macOS's BSD `date` — the same class of gap `with_timeout` was already
#     rewritten twice to avoid (gotchas #6/#8) — and bash's `$EPOCHREALTIME`
#     needs 5.0+, unavailable on stock macOS's bash 3.2 either. This only
#     bites at `--timeout` values low enough that nobody would realistically
#     use them waiting on a review bot that typically takes minutes to
#     respond, so the fix was judged not worth trading away the portability
#     every other timing fix in this script was written to protect.
#
# 18. #16's `.user.type == "Bot"` filter was still too wide: it accepts a
#     comment from *any* bot account, and a repo can easily run more than
#     one — a CI status bot, a deploy bot, a coverage reporter — any of
#     which posting on the PR while this is watching would be wrongly
#     treated as "Codex responded." `--bot LOGIN` (default
#     `chatgpt-codex-connector[bot]`, Codex's actual `.user.login`) makes the
#     expected reviewer's identity explicit and configurable, and
#     `new_bot_comments_by_id` now matches `.user.login == $bot` instead of
#     the generic account type.
#
# 19. The outer loop rechecked the deadline a second time right after waking
#     from sleep, before calling `poll_once` — added back when `poll_once`
#     had no internal budget awareness of its own, specifically to stop it
#     from starting a real round of paginated requests after the timeout had
#     already passed. `poll_once` has since grown its own per-call
#     `remaining <= 0` guards (the whole point of gotcha #9), so calling it
#     when the budget is already gone now costs a `date` call and a
#     comparison, not a wasted request. The outer recheck had become pure
#     downside: since `SLEEP_FOR` is capped to exactly `REMAINING`, that
#     recheck was *guaranteed* to see the deadline as reached and skip the
#     call — discarding the one poll that covers activity arriving anywhere
#     up to and including the deadline itself, every single run. Removed;
#     `poll_once && exit 0` runs unconditionally after every sleep now.
#
# 20. Known, accepted gap, not fixed: the reviews/comments/issue-comments
#     baselines are three sequential requests, not one atomic snapshot — the
#     GitHub REST API doesn't offer a way to fetch all three at once. If
#     `--trigger` is omitted (the review was requested some other way) and
#     the bot responds while baseline capture is still in flight, its ID can
#     land inside the baseline instead of being seen as new, and the watcher
#     times out despite a real response — the same shape of problem #15/#18
#     solved for the `--trigger` path by baselining before this script's own
#     trigger post. There's no equivalent anchor point in the no-trigger
#     case: the review was requested by something outside this script, at a
#     time this script has no way to know. Closing this fully would mean
#     comparing `created_at` against `START_TS` instead of ID-set
#     membership, which reintroduces the exact second-resolution race #4
#     moved away from ID comparison to avoid — trading one narrow race for
#     another, not eliminating it. Left as documented risk instead: narrow
#     in practice, since it only fires if the bot responds within the few
#     seconds baseline capture takes, and every real response observed
#     while building this script took multiple minutes.
#
# 21. (Superseded by #25 — kept as a record of the reasoning trail.) #19's
#     "just remove the outer recheck" fix didn't actually fix anything — it
#     moved the exact same problem one level deeper. `poll_once`'s own
#     top-of-function guard checked `remaining <= 0` before its first
#     request, and since `SLEEP_FOR` was capped to exactly `REMAINING`,
#     waking up from that final sleep always landed on `remaining` being ~0
#     — so that guard was just as guaranteed to bail as the outer recheck
#     it replaced. Attempted fix: stop the capped sleep `$FINAL_POLL_RESERVE`
#     seconds short of the deadline instead, so the wake-up would have a
#     few real seconds of budget left.
#
# 22. (Superseded by #25.) #21's reserve fixed "no attempt at all" but
#     created a new failure: once `SLEEP_FOR` was capped, it clamped to 0
#     whenever `REMAINING` was already below `$FINAL_POLL_RESERVE` — and if
#     `poll_once` returned without finding anything while `REMAINING` was
#     *still* barely positive (the reserve wasn't fully used, or the poll
#     was just fast), the loop went right back to the same "capped sleep"
#     branch and did it again — sleep 0, three more paginated requests,
#     repeat — until `REMAINING` finally hit zero. Attempted fix: treat
#     entering the capped-sleep branch as inherently the final iteration and
#     unconditionally break right after it, win or lose.
#
# 23. (Superseded by #25.) #22's unconditional break was itself wrong, in
#     the opposite direction: it gave up the instant the reserved poll
#     finished, even when several genuine seconds still remained before the
#     real deadline (confirmed with a mocked `--timeout 6`: it exited around
#     3.2s, throwing away ~2.8s of the advertised budget). Attempted fix:
#     move the guarantee into `poll_once` itself via a one-shot `GRACE_USED`
#     flag, spending `$FINAL_POLL_RESERVE` seconds *past* `TIMEOUT` for
#     exactly one attempt — which worked for that scenario, but had a
#     problem of its own: see #25.
#
# 24. `--bot`/`.user.login` filtering (#18) only ever got applied to the
#     issue-comments check — reviews and inline review comments still used
#     plain `new_by_id`, unfiltered by author. A different human reviewer,
#     or an unrelated CI/deploy/coverage bot, submitting a real formal
#     review or a real inline comment on the same PR while this watches for
#     one specific bot's response would have been wrongly treated as that
#     bot answering. `new_by_id` and `new_bot_comments_by_id` are now one
#     function, `new_by_bot_and_id`, applied identically to all three
#     watched endpoints — `--bot` now actually scopes everything this script
#     watches, not just the endpoint the bug happened to be noticed on.
#
# 25. #23's grace flag fixed the "give the boundary a real chance" problem
#     but broke a different, more important guarantee: "never exceed
#     --timeout." Spending `$FINAL_POLL_RESERVE` seconds *past* `TIMEOUT`
#     means the watcher can both run measurably longer than what was asked
#     for, and — the sharper issue — report success for activity that, as
#     far as this script can actually prove, arrived *after* the deadline.
#     ID-based detection (gotcha #3/#4) has no `created_at` to check that
#     against without reintroducing the exact timestamp race those gotchas
#     moved away from, so there's no honest way to tell "arrived just
#     before the deadline" from "arrived just after, during the borrowed
#     grace" once grace exists at all. The fix removes borrowing entirely:
#     `poll_once`'s guard is back to a plain, unconditional `remaining <= 0`
#     → refuse, exactly like before any of #19/#21/#22/#23 touched it. The
#     "give the boundary a real chance" half of the problem is solved in
#     the outer loop instead, the same way #21 first tried — reserve
#     `$FINAL_POLL_RESERVE` seconds *of the original, unborrowed budget* by
#     stopping the capped sleep that much short — but *without* #22's
#     "treat this as the final iteration, break unconditionally" rule. The
#     ordinary `REMAINING <= 0` check is what ends the loop, same as always;
#     nothing about it needs to know this was a "final" iteration. Any
#     extra iterations in the last stretch, once `REMAINING` has shrunk
#     below the reserve, are cheap — `poll_once`'s unconditional guard
#     refuses instantly, with no network calls, so there's no repeated round
#     of real requests left to waste, just a few near-zero-cost checks
#     before `REMAINING` finally reads at or below zero and the loop exits.
#     Net effect versus #23: strictly bounded within `TIMEOUT` again (the
#     property that actually matters), at the cost of a narrow edge case
#     #23 covered and this doesn't — activity landing in the sliver of time
#     between the last real check and the deadline can still be missed. That
#     trade was judged correct: silently reporting success past a stated
#     deadline is a worse failure mode than occasionally, honestly, timing
#     out despite a response that arrived in the final instant.
#
# 26. `poll_once` used to `return 1` the moment ANY of its three fetches
#     found `remaining <= 0` — including discarding a review that an
#     *earlier* fetch in the same call had already successfully brought
#     back. A new bot review sitting correctly in `CURRENT_REVIEWS_JSON`
#     would never even be checked for new activity if the *unrelated*
#     comments fetch right after it ran out of budget — reporting a
#     timeout despite having already observed the real response, seconds
#     before the actual deadline. Each fetch now defaults to `"[]"` and is
#     skipped (not fatal) once the budget's gone, rather than aborting the
#     whole function — whatever WAS successfully fetched still gets
#     checked for new activity at the end, every time.
#
# 27. #25's closing note claimed extra tail iterations were free because
#     `poll_once`'s guard "refuses instantly, with no network calls" —
#     untested, and wrong. That's only true once `REMAINING` reads exactly
#     `<= 0`; while it's still barely positive across several fast
#     iterations in a row (a real, observed pattern, not a hypothetical),
#     `poll_once` passes its guard and makes a genuine round of API calls
#     every single time — confirmed with a mocked `--timeout 4`: four
#     polling rounds, twelve total requests, for what should have been one
#     reserved attempt. `RESERVE_USED` bounds the sleep-reservation from
#     gotcha #25 to firing exactly once: the first time the sleep would
#     otherwise be capped, reserve `$FINAL_POLL_RESERVE` seconds and spend
#     the one real attempt; every time after that, sleep out whatever's
#     left instead of reserving again, so the loop runs out the clock and
#     ends via the ordinary `REMAINING <= 0` check with no further requests.
#
# 28. #26 only skipped a fetch when the budget check *before* it failed —
#     a fetch that started with real budget and then failed outright (a
#     `with_timeout` kill, or a genuine HTTP error) still hit a fatal
#     `exit 1`, discarding whatever an EARLIER fetch in the same call had
#     already successfully brought back. Reproduced directly with the local
#     test harness (`scripts/test/`): reviews shows a real new ID, comments
#     fails right after — the watcher reported an error and lost the
#     finding, instead of reporting the review it had genuinely already
#     seen. Every fetch failure is a warning now, never fatal on its own —
#     a separate, deliberately coarser signal (see #29) is what decides
#     whether a failure pattern is actually worth giving up over.
#
# 29. The first version of that "deliberately coarser signal" pooled all
#     three endpoints into one counter, reset the instant ANY of them
#     succeeded. That's blind to exactly the case that matters most: one
#     endpoint persistently broken (bad scope on a token, a resource-
#     specific rate limit) while the other two stay healthy never trips an
#     aggregate counter, because two successes reset it every round — but
#     that one broken endpoint could be the exact one that would have shown
#     the real response, and the watcher would run out the full `--timeout`
#     reporting an ordinary, unremarkably-worded "no new activity," not
#     "reviews specifically couldn't be checked the whole time." Each
#     endpoint now has its own independent streak
#     (`REVIEWS_FAILURE_STREAK` / `COMMENTS_FAILURE_STREAK` /
#     `ISSUE_COMMENTS_FAILURE_STREAK`) and can trip the loud exit on its
#     own — after `$MAX_ENDPOINT_FAILURES` consecutive failures on that one
#     endpoint, regardless of how the other two are doing, naming which
#     endpoint is degraded so the message is actually actionable.
#
# 30. Two problems, same round of review, both worth recording. First: #29
#     put `exit 1` right where each endpoint's threshold check lived —
#     which reintroduces the *exact* bug #26/#28 already fixed once, just
#     from a new direction. An endpoint hitting its failure threshold would
#     abort immediately, before the other two endpoints were even fetched
#     this call, discarding whatever an earlier fetch in the very same call
#     had already found, or skipping a still-healthy endpoint's check
#     entirely — e.g. reviews finally trips its threshold right as Codex
#     posts a clean-pass issue comment, and the watcher dies on an API
#     error instead of reporting the response it could have observed one
#     fetch later. Fixed by *not* exiting inline: a hit threshold is
#     recorded in `PERSISTENT_FAILURE_MESSAGE`, the function keeps going
#     and evaluates whatever it fetched, reports real activity if there is
#     any (a broken endpoint stops mattering the moment a healthy one finds
#     the actual answer), and only exits on the recorded message at the
#     very end, once nothing was found. Second, unrelated but caught in the
#     same pass: the sleep-reservation branch used `[ "$SLEEP_FOR" -gt
#     "$REMAINING" ]` — strict greater-than — so the exact-equality case
#     (`SLEEP_FOR == REMAINING`) skipped the reserve branch entirely and
#     slept away the whole remaining budget with none held back, landing
#     right back on gotcha #25's original problem at that one specific
#     boundary. Changed to `-ge`.
#
# 31. `--bot LOGIN` (gotcha #18) makes this script's own *detection* generic
#     across review-on-comment bots, but `--trigger` still posted the
#     hardcoded literal `"@codex review"` regardless — combine `--trigger`
#     with `--bot other-reviewer[bot]` and the watcher summons nothing (that
#     phrase means nothing to a different bot), then waits for a response
#     to a request that was never actually made, and eventually times out.
#     `--trigger-comment TEXT` (default `"@codex review"`, so existing
#     invocations are unaffected) makes the posted body configurable too —
#     set it alongside `--bot` when watching something other than Codex.
#
# 32. Known, accepted gap, not fixed: `with_timeout`'s `kill -TERM "$pid"` on
#     expiry only signals the direct backgrounded command, not any of its
#     own children. In the test harness this orphans `fake-gh.sh`'s `sleep N`
#     (used by the `slow:N` mode) when the wrapping command times out first;
#     in real use it would matter only if `gh` itself ever spawned a
#     detached child, which it doesn't currently. Killing the whole process
#     group instead needs job control (`set -m`) scoped tightly enough not
#     to change this script's own output (job-control status lines like
#     "[1]+ Terminated" would land on stderr and could break callers, and
#     several existing tests match exact output text) — and this script's
#     one available test environment is Git-for-Windows Bash, which has
#     neither `pkill` nor verified negative-PID process-group kill
#     semantics, so a fix written and only validated here could easily be
#     wrong on the macOS/Linux environments this script actually documents
#     supporting elsewhere (see gotcha #8's `timeout`-availability discussion
#     and gotcha #17). Left undone rather than shipped unverified; the two
#     ingredients a real fix needs are `set -m` scoped to a subshell around
#     just the backgrounded call, and a way to confirm on a real macOS or
#     Linux box that group-kill actually reaps the children without
#     otherwise changing this script's stdout/stderr contract.

set -euo pipefail

REPO="${1:?usage: watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval N] [--timeout N]}"
PR="${2:?usage: watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval N] [--timeout N]}"
shift 2

TRIGGER=false
INTERVAL=20
TIMEOUT=900
BOT_LOGIN="chatgpt-codex-connector[bot]"
TRIGGER_BODY="@codex review"
# Seconds of budget deliberately left unslept before the deadline, so the
# final poll wakes up with real time left instead of exactly zero — see
# gotcha #21. Not a flag: it's an internal implementation margin, not
# something callers should need to tune.
FINAL_POLL_RESERVE=3

while [ $# -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --bot) BOT_LOGIN="$2"; shift 2 ;;
    --trigger-comment) TRIGGER_BODY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --timeout <= 0 would reach with_timeout's own "<= 0 means unbounded"
# sentinel directly (see gotcha #9) — every internal call site recomputes a
# guarded, always-positive "remaining" before calling it, but a user-supplied
# --timeout 0 or a negative value bypasses that entirely and hits the
# sentinel on the very first request, turning it unbounded instead of
# instantly failing. Reject both here before anything runs. Same check
# applies to --interval so a bad value fails loudly instead of spinning.
case "$INTERVAL" in
  ''|*[!0-9]*)
    echo "Error: --interval must be a positive integer, got '$INTERVAL'" >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -le 0 ]; then
  echo "Error: --interval must be a positive integer, got '$INTERVAL'" >&2
  exit 2
fi
case "$TIMEOUT" in
  ''|*[!0-9]*)
    echo "Error: --timeout must be a positive integer, got '$TIMEOUT'" >&2
    exit 2
    ;;
esac
if [ "$TIMEOUT" -le 0 ]; then
  echo "Error: --timeout must be a positive integer, got '$TIMEOUT'" >&2
  exit 2
fi

# Runs "$@", printing only its stdout, but kills it and returns non-zero if
# it's still running after $1 seconds. $1 <= 0 means "no bound" — no call
# site actually passes that anymore (every internal caller recomputes a
# guarded, positive "remaining" first, and --timeout/--interval are validated
# above), it's kept only as a defensive fallback rather than assumed dead
# code. stdout and stderr are captured to separate files, not merged: `gh`
# can write a successful call's diagnostics to stderr (an update-available
# notice, or GH_DEBUG output) without that being an error, and merging the
# two would corrupt the JSON on our stdout with that text, breaking the jq
# parse downstream even though the call succeeded. stderr is still replayed
# to our own stderr either way, so nothing useful is lost — it just isn't
# allowed to land in the JSON stream.
with_timeout() {
  local secs="$1"; shift
  if [ "$secs" -le 0 ]; then
    "$@"
    return $?
  fi
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  "$@" >"$out" 2>"$err" &
  local pid=$!
  # Poll every 0.1s (tenths, since bash arithmetic is integer-only), not
  # every 1s — seven of these run per poll_once call (two baseline, two per
  # poll), and every one that lets a fast completion sit through a needless
  # ~1s sleep before noticing adds up. See gotcha #14.
  local deadline_ticks=$((secs * 10))
  local ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$deadline_ticks" ]; then
      # Only signals $pid itself, not any children it may have spawned. See
      # gotcha #32 for why that's left as a known gap rather than guessed at.
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      cat "$err" >&2
      cat "$out"
      rm -f "$out" "$err"
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null
  local status=$?
  cat "$err" >&2
  cat "$out"
  rm -f "$out" "$err"
  return "$status"
}

# Fetches every page of a list endpoint and returns it as one flat JSON
# array, bounding the network request to $1 seconds (<= 0 for unbounded).
# Returns non-zero (and prints nothing) if the request failed or timed out —
# checked explicitly by callers rather than left to errexit, since errexit
# is disabled inside any function invoked as the left side of `&&` (see
# gotcha #7), which is exactly how this gets called from poll_once.
api_list() {
  local bound_secs="$1" path="$2" raw
  raw="$(with_timeout "$bound_secs" gh api --paginate --slurp "$path")" || return 1
  printf '%s' "$raw" | jq 'add'
}

# Reads a JSON array on stdin, returns the elements whose .id isn't present
# in the JSON array passed as $1 and whose .user.login matches $2. Used for
# all three watched endpoints (reviews, inline review comments, issue
# comments). It's tempting to think reviews/inline comments don't need an
# author filter, since submitting either is inherently review-shaped
# regardless of who does it — but "review-shaped" isn't the same as "the
# review being waited for": a different human reviewer, or an unrelated CI/
# deploy/coverage bot, can submit a real formal review or leave a real
# inline comment on the same PR while this is watching for one specific
# bot's response, and none of that should count as Codex having answered.
new_by_bot_and_id() {
  jq --argjson baseline "$1" --arg bot "$2" '[.[] | select(.user.login == $bot) | select(.id as $i | ($baseline | index($i)) == null)]'
}

# The whole script's "give up after --timeout seconds" promise has to start
# here, before the baseline requests, not after them — a stalled baseline
# request bounded to 0 (unbounded) would otherwise hang forever before the
# watcher ever entered its own deadline-bounded loop.
START_TS=$(date +%s)

# Snapshot the current state BEFORE posting the trigger comment, not after.
# A review bot can respond fast enough that if the trigger goes out first,
# its review and comments land inside what would become the "baseline" —
# so the poll loop below would never see them as new and the watcher would
# time out despite a real response.
BASELINE_REVIEWS_JSON="$(api_list "$TIMEOUT" "repos/$REPO/pulls/$PR/reviews")" \
  || { echo "Error: failed to fetch the baseline reviews from the GitHub API (network issue, rate limit, or timeout)" >&2; exit 1; }
BASELINE_REVIEW_IDS="$(echo "$BASELINE_REVIEWS_JSON" | jq '[.[].id]')"

# Recompute what's left of $TIMEOUT rather than passing $TIMEOUT again — the
# reviews call above may already have used part (or all) of it, and passing
# the original full budget to every sequential baseline call would let setup
# run for close to their combined total before failing, not the one
# advertised deadline.
BASELINE_REMAINING=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
if [ "$BASELINE_REMAINING" -le 0 ]; then
  echo "Error: timed out fetching the baseline reviews before the comments baseline could even start" >&2
  exit 1
fi
BASELINE_COMMENTS_JSON="$(api_list "$BASELINE_REMAINING" "repos/$REPO/pulls/$PR/comments")" \
  || { echo "Error: failed to fetch the baseline review comments from the GitHub API (network issue, rate limit, or timeout)" >&2; exit 1; }
BASELINE_COMMENT_IDS="$(echo "$BASELINE_COMMENTS_JSON" | jq '[.[].id]')"

# A PR review is also a formal "review" object (pulls/.../reviews) with
# inline comments (pulls/.../comments) ONLY when Codex has findings to post.
# A clean pass — no findings — lands as a plain conversation comment on the
# issue-comments timeline instead ("Codex Review: Didn't find any major
# issues. Delightful!"), which neither of the above endpoints will ever
# surface. Without watching this endpoint too, a genuinely clean response is
# indistinguishable from Codex never having responded at all, and the
# watcher times out despite the review having actually happened. See #15.
BASELINE_REMAINING=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
if [ "$BASELINE_REMAINING" -le 0 ]; then
  echo "Error: timed out fetching the review-comments baseline before the issue-comments baseline could even start" >&2
  exit 1
fi
BASELINE_ISSUE_COMMENTS_JSON="$(api_list "$BASELINE_REMAINING" "repos/$REPO/issues/$PR/comments")" \
  || { echo "Error: failed to fetch the baseline issue comments from the GitHub API (network issue, rate limit, or timeout)" >&2; exit 1; }
BASELINE_ISSUE_COMMENT_IDS="$(echo "$BASELINE_ISSUE_COMMENTS_JSON" | jq '[.[].id]')"

if [ "$TRIGGER" = true ]; then
  TRIGGER_REMAINING=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$TRIGGER_REMAINING" -le 0 ]; then
    echo "Error: timed out before the trigger comment could be posted" >&2
    exit 1
  fi
  TRIGGER_OUTPUT="$(with_timeout "$TRIGGER_REMAINING" gh pr comment "$PR" --repo "$REPO" --body "$TRIGGER_BODY")" \
    || { echo "Error: failed to post the trigger comment (network issue, rate limit, or timeout)" >&2; exit 1; }
  # gh prints the new comment's URL (".../pull/1#issuecomment-<id>") to
  # stdout. The issue-comments baseline was captured just above, BEFORE this
  # post, specifically so a fast response can't race past it (see the
  # reviews/comments baseline comment above) — but that means this trigger
  # comment itself is not yet in that baseline and would otherwise be
  # mistaken for Codex's response the moment it appears. Add its own ID to
  # the baseline explicitly so it's excluded without reintroducing the race.
  #
  # `|| true` is load-bearing, not decoration: `gh pr comment` is documented
  # only to post the comment, not to guarantee a trailing numeric ID on
  # stdout, so a `gh` version or output format that omits one makes `grep`
  # find nothing and exit 1. Under `set -o pipefail` that failure propagates
  # out of the whole `cmd | grep | tail` pipeline, and under `set -e` an
  # unprotected nonzero assignment here would abort the script before ever
  # reaching the `-n` check below that already treats a missing ID as fine.
  # The extraction is optional by design; only its own failure should be, too.
  TRIGGER_COMMENT_ID="$(printf '%s' "$TRIGGER_OUTPUT" | grep -oE '[0-9]+$' | tail -1)" || true
  if [ -n "$TRIGGER_COMMENT_ID" ]; then
    BASELINE_ISSUE_COMMENT_IDS="$(echo "$BASELINE_ISSUE_COMMENT_IDS" | jq --argjson id "$TRIGGER_COMMENT_ID" '. + [$id]')"
  fi
  echo "Posted \"$TRIGGER_BODY\" on $REPO#$PR"
fi

BASELINE_REVIEW_COUNT="$(echo "$BASELINE_REVIEW_IDS" | jq 'length')"
BASELINE_COMMENT_COUNT="$(echo "$BASELINE_COMMENT_IDS" | jq 'length')"
BASELINE_ISSUE_COMMENT_COUNT="$(echo "$BASELINE_ISSUE_COMMENT_IDS" | jq 'length')"
echo "Watching $REPO#$PR (baseline reviews: $BASELINE_REVIEW_COUNT, review comments: $BASELINE_COMMENT_COUNT, issue comments: $BASELINE_ISSUE_COMMENT_COUNT, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

# Runs one check. Prints the "[Ns] ..." status line and, if either baseline
# set gained an ID that wasn't there before, the "New activity" summary too.
# Returns 0 (and has already printed the summary) when new activity was
# found, 1 otherwise (including when the budget ran out mid-check, which
# looks the same to the caller as "nothing new this round" — the outer
# loop's own deadline check is what turns that into the final timeout
# message, so this doesn't need to duplicate it).
poll_once() {
  local remaining

  # No grace, no borrowed time — a call that starts with remaining <= 0
  # simply refuses, every time. See gotcha #25 for why: an earlier design
  # (gotcha #23) let this guard spend a few seconds of "grace" past TIMEOUT
  # for exactly one attempt, which meant the watcher could both run past
  # the advertised deadline AND report success for activity that, for all
  # this script can prove, actually arrived after it. Getting the final
  # moment before the deadline a genuine chance is the outer loop's job now
  # (leaving real, unborrowed budget for this call to spend — see the sleep
  # reservation below), not this guard's.
  #
  # Each of the three fetches below is independently skippable once the
  # budget runs out mid-call, AND independently allowed to just fail — set
  # to "[]" and left alone either way, never aborting the whole function.
  # See gotcha #26 (the budget-exhausted case) and gotcha #28 (this one):
  # the earlier version treated a fetch that *started* with real budget but
  # then failed outright (a timeout via with_timeout, or a genuine HTTP
  # error) as fatal — discarding a review an EARLIER fetch in the very same
  # call had already successfully brought back, and reporting a timeout
  # despite having actually observed the response. A failure is now a
  # warning, not an abort; whatever WAS fetched still gets checked below.
  # attempted/success counts feed the persistent-failure check further
  # down — a single flaky fetch next to two good ones is normal API noise,
  # not a problem worth ending the watch over.
  CURRENT_REVIEWS_JSON='[]'
  CURRENT_COMMENTS_JSON='[]'
  CURRENT_ISSUE_COMMENTS_JSON='[]'

  # Failures are tracked PER ENDPOINT, not pooled into one aggregate count
  # — see gotcha #29. A single endpoint that's persistently broken (say,
  # reviews returning 403 every time) while the other two stay healthy
  # would never trip an aggregate "all three failed" counter, since two
  # successes reset it every round — but that one broken endpoint could be
  # exactly the one that would have shown the real response, and the
  # watcher would run out the full --timeout and report an ordinary,
  # misleadingly unremarkable "no new activity" instead of "reviews
  # couldn't be checked the whole time." Each endpoint gets its own streak
  # and can independently flag a persistent failure.
  #
  # None of the three blocks below exits immediately on hitting its
  # threshold — see gotcha #30. Exiting inline reintroduces the exact bug
  # #26/#28 already fixed: an endpoint hitting its failure threshold would
  # abort before the OTHER two endpoints were even fetched, discarding
  # whatever an earlier fetch in this same call had already found, or
  # skipping a still-healthy endpoint's check entirely. A hit threshold is
  # recorded in PERSISTENT_FAILURE_MESSAGE instead; the function finishes
  # evaluating whatever it fetched, reports real activity if there is any
  # (a persistently broken endpoint stops mattering the moment a healthy
  # one finds the actual response), and only exits on the recorded message
  # at the very end, once nothing was found.
  PERSISTENT_FAILURE_MESSAGE=""

  remaining=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$remaining" -gt 0 ]; then
    if CURRENT_REVIEWS_JSON="$(api_list "$remaining" "repos/$REPO/pulls/$PR/reviews")"; then
      REVIEWS_FAILURE_STREAK=0
    else
      CURRENT_REVIEWS_JSON='[]'
      REVIEWS_FAILURE_STREAK=$((REVIEWS_FAILURE_STREAK + 1))
      echo "Warning: failed to fetch reviews from the GitHub API ($REVIEWS_FAILURE_STREAK in a row)" >&2
      if [ "$REVIEWS_FAILURE_STREAK" -ge "$MAX_ENDPOINT_FAILURES" ]; then
        PERSISTENT_FAILURE_MESSAGE="fetching reviews has failed $REVIEWS_FAILURE_STREAK times in a row: this endpoint looks persistently broken (auth, rate limit, network), and a real review response could be sitting there unobserved"
      fi
    fi
  fi

  remaining=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$remaining" -gt 0 ]; then
    if CURRENT_COMMENTS_JSON="$(api_list "$remaining" "repos/$REPO/pulls/$PR/comments")"; then
      COMMENTS_FAILURE_STREAK=0
    else
      CURRENT_COMMENTS_JSON='[]'
      COMMENTS_FAILURE_STREAK=$((COMMENTS_FAILURE_STREAK + 1))
      echo "Warning: failed to fetch review comments from the GitHub API ($COMMENTS_FAILURE_STREAK in a row)" >&2
      if [ "$COMMENTS_FAILURE_STREAK" -ge "$MAX_ENDPOINT_FAILURES" ]; then
        PERSISTENT_FAILURE_MESSAGE="fetching review comments has failed $COMMENTS_FAILURE_STREAK times in a row: this endpoint looks persistently broken (auth, rate limit, network), and a real inline comment could be sitting there unobserved"
      fi
    fi
  fi

  remaining=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$remaining" -gt 0 ]; then
    if CURRENT_ISSUE_COMMENTS_JSON="$(api_list "$remaining" "repos/$REPO/issues/$PR/comments")"; then
      ISSUE_COMMENTS_FAILURE_STREAK=0
    else
      CURRENT_ISSUE_COMMENTS_JSON='[]'
      ISSUE_COMMENTS_FAILURE_STREAK=$((ISSUE_COMMENTS_FAILURE_STREAK + 1))
      echo "Warning: failed to fetch issue comments from the GitHub API ($ISSUE_COMMENTS_FAILURE_STREAK in a row)" >&2
      if [ "$ISSUE_COMMENTS_FAILURE_STREAK" -ge "$MAX_ENDPOINT_FAILURES" ]; then
        PERSISTENT_FAILURE_MESSAGE="fetching issue comments has failed $ISSUE_COMMENTS_FAILURE_STREAK times in a row: this endpoint looks persistently broken (auth, rate limit, network), and a real clean-pass response could be sitting there unobserved"
      fi
    fi
  fi

  NEW_REVIEWS_JSON="$(echo "$CURRENT_REVIEWS_JSON" | new_by_bot_and_id "$BASELINE_REVIEW_IDS" "$BOT_LOGIN")" \
    || { echo "Error: failed to compute new reviews" >&2; exit 1; }
  NEW_COMMENTS_JSON="$(echo "$CURRENT_COMMENTS_JSON" | new_by_bot_and_id "$BASELINE_COMMENT_IDS" "$BOT_LOGIN")" \
    || { echo "Error: failed to compute new review comments" >&2; exit 1; }
  NEW_ISSUE_COMMENTS_JSON="$(echo "$CURRENT_ISSUE_COMMENTS_JSON" | new_by_bot_and_id "$BASELINE_ISSUE_COMMENT_IDS" "$BOT_LOGIN")" \
    || { echo "Error: failed to compute new issue comments" >&2; exit 1; }
  NEW_REVIEW_COUNT="$(echo "$NEW_REVIEWS_JSON" | jq 'length')" || exit 1
  NEW_COMMENT_COUNT="$(echo "$NEW_COMMENTS_JSON" | jq 'length')" || exit 1
  NEW_ISSUE_COMMENT_COUNT="$(echo "$NEW_ISSUE_COMMENTS_JSON" | jq 'length')" || exit 1

  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "  [${ELAPSED}s] new reviews: $NEW_REVIEW_COUNT, new review comments: $NEW_COMMENT_COUNT, new issue comments: $NEW_ISSUE_COMMENT_COUNT"

  if [ "$NEW_REVIEW_COUNT" -gt 0 ] || [ "$NEW_COMMENT_COUNT" -gt 0 ] || [ "$NEW_ISSUE_COMMENT_COUNT" -gt 0 ]; then
    echo
    echo "New activity on $REPO#$PR:"
    echo "$NEW_REVIEWS_JSON" | jq -r '.[] | "- review by \(.user.login): \(.state)"'
    echo "$NEW_COMMENTS_JSON" | jq -r '.[] | "- \(.path):\(.line // "?"): " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    echo "$NEW_ISSUE_COMMENTS_JSON" | jq -r '.[] | "- comment by \(.user.login): " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    return 0
  fi

  # Only checked here, after everything fetched this round has already
  # been evaluated for real activity — see gotcha #30. If something was
  # actually found above, this function already returned 0 and none of the
  # following runs; a persistently broken endpoint stops being worth
  # ending the watch over the moment a still-healthy one finds the answer.
  if [ -n "$PERSISTENT_FAILURE_MESSAGE" ]; then
    echo "Error: $PERSISTENT_FAILURE_MESSAGE. Giving up rather than silently reporting a possibly-misleading timeout." >&2
    exit 1
  fi
  return 1
}

# Per-endpoint consecutive-failure counts (not skipped for lack of budget —
# genuinely attempted and failed). See gotcha #28/#29.
REVIEWS_FAILURE_STREAK=0
COMMENTS_FAILURE_STREAK=0
ISSUE_COMMENTS_FAILURE_STREAK=0
MAX_ENDPOINT_FAILURES=3

# Unconditional first poll, before any deadline math — see gotcha #6. This is
# the only way a --timeout at or below --interval (or just a fast responder)
# ever gets observed at all.
poll_once && exit 0

# Whether the sleep reservation below has already been used once. See
# gotcha #27: without this, "reserve $FINAL_POLL_RESERVE seconds" fires
# again on every later iteration too, for as long as REMAINING stays
# barely positive — and each of those firings makes a real, if small,
# round of network calls, not a free no-op the way this comment used to
# (wrongly) claim.
RESERVE_USED=false

while :; do
  NOW_TS=$(date +%s)
  REMAINING=$((TIMEOUT - (NOW_TS - START_TS)))
  if [ "$REMAINING" -le 0 ]; then
    break
  fi
  SLEEP_FOR=$INTERVAL
  # -ge, not -gt: when SLEEP_FOR exactly equals REMAINING, sleeping the
  # full amount is just as much "sleep away the entire budget" as sleeping
  # more than it — the strict > let that exact-equality case skip the
  # reserve branch entirely, landing right back on poll_once waking up
  # with zero budget, gotcha #25's original problem, at that one specific
  # boundary. See gotcha #30.
  if [ "$SLEEP_FOR" -ge "$REMAINING" ]; then
    if [ "$RESERVE_USED" = true ]; then
      # Already spent the one reserved attempt (below) on an earlier
      # iteration. Sleep out whatever's left instead of reserving again —
      # this iteration's sleep ends the loop via the ordinary REMAINING <=
      # 0 check above on the next pass, with no further network calls.
      SLEEP_FOR=$REMAINING
    else
      # Leave $FINAL_POLL_RESERVE seconds of the ORIGINAL remaining budget
      # unslept, rather than sleeping all the way to the deadline — so the
      # poll below starts with genuine, unborrowed time still on the
      # clock. See gotcha #25: this reserve lives entirely within
      # TIMEOUT, unlike the grace-based attempt it replaces, which
      # extended past it instead.
      SLEEP_FOR=$((REMAINING - FINAL_POLL_RESERVE))
      if [ "$SLEEP_FOR" -lt 0 ]; then
        SLEEP_FOR=0
      fi
      RESERVE_USED=true
    fi
  fi
  sleep "$SLEEP_FOR"

  poll_once && exit 0
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
