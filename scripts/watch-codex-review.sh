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
# The one gotcha this script exists to get right: `gh api --jq <expr>` only
# accepts a single query-string argument — it does NOT understand jq's own
# flags like `--arg`. `gh api ... --jq --arg since "$SINCE" '...'` silently
# mis-parses: `--jq` swallows the literal string "--arg" as its entire query,
# and `since`, `$SINCE`, and the real filter all become stray positional
# arguments, which gh then rejects (or, worse, just no-ops). If you need a
# parametrized filter, pipe the raw JSON into the real `jq` binary instead —
# that's what every query below does, on purpose.

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

if [ "$TRIGGER" = true ]; then
  gh pr comment "$PR" --repo "$REPO" --body "@codex review" >/dev/null
  echo "Posted @codex review on $REPO#$PR"
fi

# Everything below is compared against this timestamp, not a specific commit
# SHA, so it also catches reviews that land with no inline comments at all
# (a plain approval, or a "looks good").
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BASELINE_COMMENTS="$(gh api "repos/$REPO/pulls/$PR/comments" | jq 'length')"

echo "Watching $REPO#$PR since $SINCE (baseline review comments: $BASELINE_COMMENTS, checking every ${INTERVAL}s, timeout ${TIMEOUT}s)"

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))

  NEW_REVIEWS="$(gh api "repos/$REPO/pulls/$PR/reviews" | jq --arg since "$SINCE" '[.[] | select(.submitted_at > $since)] | length')"
  CURRENT_COMMENTS="$(gh api "repos/$REPO/pulls/$PR/comments" | jq 'length')"

  echo "  [${ELAPSED}s] new reviews: $NEW_REVIEWS, review comments: $CURRENT_COMMENTS (was $BASELINE_COMMENTS)"

  if [ "$NEW_REVIEWS" -gt 0 ] || [ "$CURRENT_COMMENTS" -ne "$BASELINE_COMMENTS" ]; then
    echo
    echo "New activity on $REPO#$PR:"
    gh api "repos/$REPO/pulls/$PR/reviews" \
      | jq --arg since "$SINCE" -r '.[] | select(.submitted_at > $since) | "- review by \(.user.login): \(.state)"'
    gh api "repos/$REPO/pulls/$PR/comments" \
      | jq -r --argjson skip "$BASELINE_COMMENTS" \
        '.[$skip:] | .[] | "- \(.path):\(.line // "?") — " + (.body | gsub("<[^>]+>"; "") | gsub("\n\n"; " "))'
    exit 0
  fi
done

echo "Timed out after ${TIMEOUT}s with no new review activity on $REPO#$PR."
exit 1
