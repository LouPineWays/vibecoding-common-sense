#!/usr/bin/env bash
# Poll a GitHub PR for a review response (from Codex, or any other
# review-on-comment bot) instead of manually re-checking it yourself every
# few minutes.
#
# Usage:
#   ./watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval SECONDS] [--timeout SECONDS]
#
#   --trigger        post "@codex review" as a new PR comment before watching
#   --interval N     seconds between checks (default 20)
#   --timeout N      give up after this many seconds (default 900 = 15 min)
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

set -euo pipefail

REPO="${1:?usage: watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval N] [--timeout N]}"
PR="${2:?usage: watch-codex-review.sh <owner/repo> <pr-number> [--trigger] [--interval N] [--timeout N]}"
shift 2

TRIGGER=false
INTERVAL=20
TIMEOUT=900

while [ $# -gt 0 ]; do
  case "$1" in
    --trigger) TRIGGER=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Runs "$@", printing only its stdout, but kills it and returns non-zero if
# it's still running after $1 seconds. $1 <= 0 means "no bound" — used for
# the one-time baseline calls below, which happen before there's any
# deadline to measure against. stdout and stderr are captured to separate
# files, not merged: `gh` can write a successful call's diagnostics to
# stderr (an update-available notice, or GH_DEBUG output) without that being
# an error, and merging the two would corrupt the JSON on our stdout with
# that text, breaking the jq parse downstream even though the call
# succeeded. stderr is still replayed to our own stderr either way, so nothing
# useful is lost — it just isn't allowed to land in the JSON stream.
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
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      cat "$err" >&2
      cat "$out"
      rm -f "$out" "$err"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
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
# in the JSON array passed as $1.
new_by_id() {
  jq --argjson baseline "$1" '[.[] | select(.id as $i | ($baseline | index($i)) == null)]'
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

if [ "$TRIGGER" = true ]; then
  TRIGGER_REMAINING=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$TRIGGER_REMAINING" -le 0 ]; then
    echo "Error: timed out before the @codex review trigger comment could be posted" >&2
    exit 1
  fi
  with_timeout "$TRIGGER_REMAINING" gh pr comment "$PR" --repo "$REPO" --body "@codex review" >/dev/null \
    || { echo "Error: failed to post the @codex review trigger comment (network issue, rate limit, or timeout)" >&2; exit 1; }
  echo "Posted @codex review on $REPO#$PR"
fi

BASELINE_REVIEW_COUNT="$(echo "$BASELINE_REVIEW_IDS" | jq 'length')"
BASELINE_COMMENT_COUNT="$(echo "$BASELINE_COMMENT_IDS" | jq 'length')"
echo "Watching $REPO#$PR (baseline reviews: $BASELINE_REVIEW_COUNT, review comments: $BASELINE_COMMENT_COUNT, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

# Runs one check. Prints the "[Ns] ..." status line and, if either baseline
# set gained an ID that wasn't there before, the "New activity" summary too.
# Returns 0 (and has already printed the summary) when new activity was
# found, 1 otherwise (including when the budget ran out mid-check, which
# looks the same to the caller as "nothing new this round" — the outer
# loop's own deadline check is what turns that into the final timeout
# message, so this doesn't need to duplicate it).
poll_once() {
  local remaining

  remaining=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$remaining" -le 0 ]; then
    return 1
  fi
  CURRENT_REVIEWS_JSON="$(api_list "$remaining" "repos/$REPO/pulls/$PR/reviews")" \
    || { echo "Error: failed to fetch reviews from the GitHub API (network issue, rate limit, or timeout)" >&2; exit 1; }

  remaining=$(( TIMEOUT - ( $(date +%s) - START_TS ) ))
  if [ "$remaining" -le 0 ]; then
    return 1
  fi
  CURRENT_COMMENTS_JSON="$(api_list "$remaining" "repos/$REPO/pulls/$PR/comments")" \
    || { echo "Error: failed to fetch review comments from the GitHub API (network issue, rate limit, or timeout)" >&2; exit 1; }

  NEW_REVIEWS_JSON="$(echo "$CURRENT_REVIEWS_JSON" | new_by_id "$BASELINE_REVIEW_IDS")" \
    || { echo "Error: failed to compute new reviews" >&2; exit 1; }
  NEW_COMMENTS_JSON="$(echo "$CURRENT_COMMENTS_JSON" | new_by_id "$BASELINE_COMMENT_IDS")" \
    || { echo "Error: failed to compute new review comments" >&2; exit 1; }
  NEW_REVIEW_COUNT="$(echo "$NEW_REVIEWS_JSON" | jq 'length')" || exit 1
  NEW_COMMENT_COUNT="$(echo "$NEW_COMMENTS_JSON" | jq 'length')" || exit 1

  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "  [${ELAPSED}s] new reviews: $NEW_REVIEW_COUNT, new review comments: $NEW_COMMENT_COUNT"

  if [ "$NEW_REVIEW_COUNT" -gt 0 ] || [ "$NEW_COMMENT_COUNT" -gt 0 ]; then
    echo
    echo "New activity on $REPO#$PR:"
    echo "$NEW_REVIEWS_JSON" | jq -r '.[] | "- review by \(.user.login): \(.state)"'
    echo "$NEW_COMMENTS_JSON" | jq -r '.[] | "- \(.path):\(.line // "?") — " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    return 0
  fi
  return 1
}

# Unconditional first poll, before any deadline math — see gotcha #6. This is
# the only way a --timeout at or below --interval (or just a fast responder)
# ever gets observed at all.
poll_once && exit 0

while :; do
  NOW_TS=$(date +%s)
  REMAINING=$((TIMEOUT - (NOW_TS - START_TS)))
  if [ "$REMAINING" -le 0 ]; then
    break
  fi
  SLEEP_FOR=$INTERVAL
  if [ "$SLEEP_FOR" -gt "$REMAINING" ]; then
    SLEEP_FOR=$REMAINING
  fi
  sleep "$SLEEP_FOR"

  NOW_TS=$(date +%s)
  if [ "$((TIMEOUT - (NOW_TS - START_TS)))" -le 0 ]; then
    break
  fi

  poll_once && exit 0
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
