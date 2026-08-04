#!/usr/bin/env bash
# Local, fast test matrix for watch-codex-review.sh, using fake-gh.sh instead
# of the real GitHub API. Every scenario here used to require a real PR and
# a real bot review to reproduce — several minutes of round-trip latency
# per attempt. This runs the whole matrix in well under a minute.
#
# Usage: ./run-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/../watch-codex-review.sh"
FAKE_GH_DIR="$SCRIPT_DIR/fake-gh-bin"
STATE_ROOT="$SCRIPT_DIR/.fake-gh-state"

mkdir -p "$FAKE_GH_DIR"
ln -sf "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/gh"
export PATH="$FAKE_GH_DIR:$PATH"

PASS=0
FAIL=0

# run_case <name> <expected_exit> <must_contain_regex> -- <env assignments...>
# The env assignments are exported, the watcher is run with a fresh
# FAKE_GH_STATE_DIR, and the case passes if the exit code matches AND (if a
# pattern was given) the combined stdout+stderr contains it.
run_case() {
  local name="$1" expected_exit="$2" must_contain="$3"
  shift 3
  [ "$1" = "--" ] && shift

  local state_dir="$STATE_ROOT/$name"
  rm -rf "$state_dir"
  mkdir -p "$state_dir"

  local out
  out="$(env PATH="$PATH" FAKE_GH_STATE_DIR="$state_dir" "$@" \
    bash "$WATCHER" fake/repo 1 "${EXTRA_ARGS[@]}" 2>&1)"
  local actual_exit=$?

  local ok=true
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    ok=false
  fi
  if [ -n "$must_contain" ] && ! printf '%s' "$out" | grep -qiE "$must_contain"; then
    ok=false
  fi

  if [ "$ok" = true ]; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name (exit=$actual_exit, expected=$expected_exit, pattern=/$must_contain/)"
    echo "--- output ---"
    printf '%s\n' "$out" | sed 's/^/    /'
    echo "--------------"
  fi
}

echo "== watch-codex-review.sh test matrix (using fake-gh.sh) =="
echo

EXTRA_ARGS=(--interval 2 --timeout 5)
run_case "clean-timeout-nothing-new" 1 "Timed out after 5s" -- \
  FAKE_GH_REVIEWS_SEQUENCE=1,2 FAKE_GH_COMMENTS_SEQUENCE=1,2 FAKE_GH_ISSUE_COMMENTS_SEQUENCE=1,2

EXTRA_ARGS=(--interval 2 --timeout 6)
run_case "detects-new-review" 0 "review by chatgpt-codex-connector" -- \
  FAKE_GH_REVIEWS_SEQUENCE="1,2;1,2,3"

EXTRA_ARGS=(--interval 2 --timeout 6)
run_case "detects-new-issue-comment-clean-pass" 0 "comment by chatgpt-codex-connector" -- \
  FAKE_GH_ISSUE_COMMENTS_SEQUENCE="1,2;1,2,3"

# "success;error" on comments: call 1 (baseline capture) succeeds, so setup
# completes normally; call 2 (the mandatory first poll) is where reviews
# shows a genuinely new id AND comments fails in the same poll_once call —
# exactly the shape of the bug this test exists to catch (a later fetch's
# failure discarding an earlier fetch's already-found result).
EXTRA_ARGS=(--interval 2 --timeout 6)
run_case "partial-failure-error-after-success-still-reports" 0 "review by chatgpt-codex-connector" -- \
  FAKE_GH_REVIEWS_SEQUENCE="1,2;1,2,3" FAKE_GH_COMMENTS_MODE_SEQUENCE="success;error"

EXTRA_ARGS=(--interval 2 --timeout 8)
run_case "partial-failure-slow-after-success-still-reports" 0 "review by chatgpt-codex-connector" -- \
  FAKE_GH_REVIEWS_SEQUENCE="1,2;1,2,3" FAKE_GH_COMMENTS_MODE_SEQUENCE="success;slow:30"

# Baseline (call 1) succeeds for all three endpoints, so setup completes;
# every poll from the mandatory first one on, all three fail. Should be
# recognized as a persistent problem and exited out of loudly, well before
# --timeout would otherwise elapse -- not silently retried for the full
# --timeout and reported as an ordinary "nothing new" timeout.
EXTRA_ARGS=(--interval 1 --timeout 25)
run_case "persistent-total-failure-exits-loudly" 1 "persistently failing|repeated failures|giving up" -- \
  FAKE_GH_REVIEWS_MODE_SEQUENCE="success;error" \
  FAKE_GH_COMMENTS_MODE_SEQUENCE="success;error" \
  FAKE_GH_ISSUE_COMMENTS_MODE_SEQUENCE="success;error"

# Reviews specifically stays broken every round; comments and issue
# comments stay healthy the whole time. An aggregate all-three-failed
# counter would never trip here, since two endpoints keep succeeding every
# round and would keep resetting it -- this is exactly the blind spot
# gotcha #29 exists to close. Should still exit loudly, naming reviews
# specifically, well before --timeout elapses.
EXTRA_ARGS=(--interval 1 --timeout 25)
run_case "single-endpoint-persistent-failure-exits-loudly" 1 "reviews.*failed.*times in a row" -- \
  FAKE_GH_REVIEWS_MODE_SEQUENCE="success;error" \
  FAKE_GH_COMMENTS_SEQUENCE=1,2 \
  FAKE_GH_ISSUE_COMMENTS_SEQUENCE=1,2

# Reviews reaches its failure threshold on call 4 -- the exact same call
# where issue comments (healthy the whole time) shows a genuinely new id.
# Reviews is fetched first each round, so the old inline-exit behavior
# would abort before issue comments was ever fetched that round, losing a
# finding that was one fetch away. Should still report the real activity
# (exit 0), not die on the persistent-failure error.
EXTRA_ARGS=(--interval 1 --timeout 30)
run_case "finding-survives-concurrent-persistent-failure" 0 "comment by chatgpt-codex-connector" -- \
  FAKE_GH_REVIEWS_MODE_SEQUENCE="success;error;error;error" \
  FAKE_GH_COMMENTS_SEQUENCE=1,2 \
  FAKE_GH_ISSUE_COMMENTS_SEQUENCE="1,2;1,2;1,2;1,2,3"

# --trigger-comment should override the hardcoded "@codex review" -- the
# whole point being that a different bot's summon phrase actually gets
# posted, not Codex's, when --bot is pointed at someone else.
EXTRA_ARGS=(--interval 2 --timeout 6 --trigger --trigger-comment "@other-bot please review")
run_case "custom-trigger-comment-is-actually-posted" 1 "posted trigger body: @other-bot please review" -- \
  FAKE_GH_ISSUE_COMMENTS_SEQUENCE=1,2

EXTRA_ARGS=(--interval 20 --timeout 3)
run_case "very-tight-timeout-still-attempts-and-stays-bounded" 1 "Timed out after 3s" -- \
  FAKE_GH_REVIEWS_SEQUENCE=1,2

EXTRA_ARGS=(--interval 2 --timeout 6 --bot "some-other-bot[bot]")
run_case "bot-filter-excludes-non-matching-login" 1 "Timed out after 6s" -- \
  FAKE_GH_REVIEWS_SEQUENCE="1,2;1,2,3"

EXTRA_ARGS=(--interval 2 --timeout 6 --trigger)
run_case "trigger-does-not-self-detect" 1 "Timed out after 6s" -- \
  FAKE_GH_ISSUE_COMMENTS_SEQUENCE=1,2

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
