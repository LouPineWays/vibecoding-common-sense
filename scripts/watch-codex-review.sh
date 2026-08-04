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
# Two gotchas this script exists to get right:
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
# its review lands with a timestamp older than SINCE and its comments are
# already folded into the "baseline" — so the poll loop below would never
# see it as new and the watcher would time out despite a real response.
#
# Everything below is compared against this timestamp, not a specific commit
# SHA, so it also catches reviews that land with no inline comments at all
# (a plain approval, or a "looks good").
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASELINE_COMMENTS="$(api_list "repos/$REPO/pulls/$PR/comments" | jq 'length')"

if [ "$TRIGGER" = true ]; then
  gh pr comment "$PR" --repo "$REPO" --body "@codex review" >/dev/null
  echo "Posted @codex review on $REPO#$PR"
fi

echo "Watching $REPO#$PR since $SINCE (baseline review comments: $BASELINE_COMMENTS, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))

  NEW_REVIEWS="$(api_list "repos/$REPO/pulls/$PR/reviews" | jq --arg since "$SINCE" '[.[] | select(.submitted_at > $since)] | length')"
  CURRENT_COMMENTS="$(api_list "repos/$REPO/pulls/$PR/comments" | jq 'length')"

  echo "  [${ELAPSED}s] new reviews: $NEW_REVIEWS, review comments: $CURRENT_COMMENTS (was $BASELINE_COMMENTS)"

  if [ "$NEW_REVIEWS" -gt 0 ] || [ "$CURRENT_COMMENTS" -ne "$BASELINE_COMMENTS" ]; then
    echo
    echo "New activity on $REPO#$PR:"
    api_list "repos/$REPO/pulls/$PR/reviews" \
      | jq --arg since "$SINCE" -r '.[] | select(.submitted_at > $since) | "- review by \(.user.login): \(.state)"'
    api_list "repos/$REPO/pulls/$PR/comments" \
      | jq -r --argjson skip "$BASELINE_COMMENTS" \
        '.[$skip:] | .[] | "- \(.path):\(.line // "?") — " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    exit 0
  fi
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
