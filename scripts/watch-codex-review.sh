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
#    fixed start, caps each sleep at whatever's left, and rechecks the
#    deadline again right after waking up — before spending any more time on
#    API calls — so a request only ever starts while time still remains.

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

# Fetches every page of a list endpoint and returns it as one flat JSON array.
api_list() {
  gh api --paginate --slurp "$1" | jq 'add'
}

# Reads a JSON array on stdin, returns the elements whose .id isn't present
# in the JSON array passed as $1.
new_by_id() {
  jq --argjson baseline "$1" '[.[] | select(.id as $i | ($baseline | index($i)) == null)]'
}

# Snapshot the current state BEFORE posting the trigger comment, not after.
# A review bot can respond fast enough that if the trigger goes out first,
# its review and comments land inside what would become the "baseline" —
# so the poll loop below would never see them as new and the watcher would
# time out despite a real response.
BASELINE_REVIEWS_JSON="$(api_list "repos/$REPO/pulls/$PR/reviews")"
BASELINE_REVIEW_IDS="$(echo "$BASELINE_REVIEWS_JSON" | jq '[.[].id]')"
BASELINE_COMMENTS_JSON="$(api_list "repos/$REPO/pulls/$PR/comments")"
BASELINE_COMMENT_IDS="$(echo "$BASELINE_COMMENTS_JSON" | jq '[.[].id]')"

if [ "$TRIGGER" = true ]; then
  gh pr comment "$PR" --repo "$REPO" --body "@codex review" >/dev/null
  echo "Posted @codex review on $REPO#$PR"
fi

BASELINE_REVIEW_COUNT="$(echo "$BASELINE_REVIEW_IDS" | jq 'length')"
BASELINE_COMMENT_COUNT="$(echo "$BASELINE_COMMENT_IDS" | jq 'length')"
echo "Watching $REPO#$PR (baseline reviews: $BASELINE_REVIEW_COUNT, review comments: $BASELINE_COMMENT_COUNT, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

START_TS=$(date +%s)
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
  ELAPSED=$((NOW_TS - START_TS))
  if [ "$((TIMEOUT - ELAPSED))" -le 0 ]; then
    break
  fi

  CURRENT_REVIEWS_JSON="$(api_list "repos/$REPO/pulls/$PR/reviews")"
  CURRENT_COMMENTS_JSON="$(api_list "repos/$REPO/pulls/$PR/comments")"
  NEW_REVIEWS_JSON="$(echo "$CURRENT_REVIEWS_JSON" | new_by_id "$BASELINE_REVIEW_IDS")"
  NEW_COMMENTS_JSON="$(echo "$CURRENT_COMMENTS_JSON" | new_by_id "$BASELINE_COMMENT_IDS")"
  NEW_REVIEW_COUNT="$(echo "$NEW_REVIEWS_JSON" | jq 'length')"
  NEW_COMMENT_COUNT="$(echo "$NEW_COMMENTS_JSON" | jq 'length')"

  echo "  [${ELAPSED}s] new reviews: $NEW_REVIEW_COUNT, new review comments: $NEW_COMMENT_COUNT"

  if [ "$NEW_REVIEW_COUNT" -gt 0 ] || [ "$NEW_COMMENT_COUNT" -gt 0 ]; then
    echo
    echo "New activity on $REPO#$PR:"
    echo "$NEW_REVIEWS_JSON" | jq -r '.[] | "- review by \(.user.login): \(.state)"'
    echo "$NEW_COMMENTS_JSON" | jq -r '.[] | "- \(.path):\(.line // "?") — " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    exit 0
  fi
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
