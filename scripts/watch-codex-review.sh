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
# Exits 0 and prints a summary the moment a new review or new review comments
# appear after the watch started. Exits 1 on timeout.
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
# 3. Detecting "new reviews" by comparing `submitted_at` to a captured
#    timestamp has a second-resolution race: a review submitted in the same
#    UTC second the baseline was captured compares equal, not greater, and
#    a strict `>` would silently miss it. Comparing review IDs against a
#    baseline ID set (the same way the comment count already worked) has no
#    such boundary, so that's what this script does instead of timestamps.
#
# 4. `sleep "$INTERVAL"` every iteration means the script can run well past
#    `--timeout` — once for a timeout shorter than one interval, and every
#    time for the seconds spent actually making the paginated API requests,
#    which are never subtracted from the budget. This script tracks wall-clock
#    elapsed time from a fixed start and caps each sleep at whatever's left.

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

# Snapshot the current state BEFORE posting the trigger comment, not after.
# A review bot can respond fast enough that if the trigger goes out first,
# its review and comments land inside what would become the "baseline" —
# so the poll loop below would never see them as new and the watcher would
# time out despite a real response.
BASELINE_REVIEWS_JSON="$(api_list "repos/$REPO/pulls/$PR/reviews")"
BASELINE_REVIEW_IDS="$(echo "$BASELINE_REVIEWS_JSON" | jq '[.[].id]')"
BASELINE_REVIEW_COUNT="$(echo "$BASELINE_REVIEWS_JSON" | jq 'length')"
BASELINE_COMMENTS="$(api_list "repos/$REPO/pulls/$PR/comments" | jq 'length')"

if [ "$TRIGGER" = true ]; then
  gh pr comment "$PR" --repo "$REPO" --body "@codex review" >/dev/null
  echo "Posted @codex review on $REPO#$PR"
fi

echo "Watching $REPO#$PR (baseline reviews: $BASELINE_REVIEW_COUNT, review comments: $BASELINE_COMMENTS, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

START_TS=$(date +%s)
while :; do
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))
  REMAINING=$((TIMEOUT - ELAPSED))
  if [ "$REMAINING" -le 0 ]; then
    break
  fi
  SLEEP_FOR=$INTERVAL
  if [ "$SLEEP_FOR" -gt "$REMAINING" ]; then
    SLEEP_FOR=$REMAINING
  fi
  sleep "$SLEEP_FOR"

  CURRENT_REVIEWS_JSON="$(api_list "repos/$REPO/pulls/$PR/reviews")"
  CURRENT_REVIEW_COUNT="$(echo "$CURRENT_REVIEWS_JSON" | jq 'length')"
  CURRENT_COMMENTS="$(api_list "repos/$REPO/pulls/$PR/comments" | jq 'length')"

  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - START_TS))
  echo "  [${ELAPSED}s] reviews: $CURRENT_REVIEW_COUNT (was $BASELINE_REVIEW_COUNT), review comments: $CURRENT_COMMENTS (was $BASELINE_COMMENTS)"

  if [ "$CURRENT_REVIEW_COUNT" -ne "$BASELINE_REVIEW_COUNT" ] || [ "$CURRENT_COMMENTS" -ne "$BASELINE_COMMENTS" ]; then
    echo
    echo "New activity on $REPO#$PR:"
    echo "$CURRENT_REVIEWS_JSON" \
      | jq --argjson baseline "$BASELINE_REVIEW_IDS" -r \
        '.[] | select(.id as $i | ($baseline | index($i)) == null) | "- review by \(.user.login): \(.state)"'
    api_list "repos/$REPO/pulls/$PR/comments" \
      | jq -r --argjson skip "$BASELINE_COMMENTS" \
        '.[$skip:] | .[] | "- \(.path):\(.line // "?") — " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    exit 0
  fi
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
