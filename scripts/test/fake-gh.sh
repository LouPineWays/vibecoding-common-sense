#!/usr/bin/env bash
# A fake `gh` for testing watch-codex-review.sh without touching the real
# GitHub API or waiting on a real bot. Put this file's directory first on
# PATH (as `gh`) and every network call the script makes lands here instead.
#
# Controlled entirely by environment variables, one set per logical
# endpoint (reviews / pull-request review comments / issue comments):
#
#   FAKE_GH_REVIEWS_MODE, FAKE_GH_COMMENTS_MODE, FAKE_GH_ISSUE_COMMENTS_MODE
#     success (default) | error | slow:<seconds>
#     "slow:N" sleeps N seconds and then still succeeds — for exercising
#     with_timeout's kill behavior and the sleep-reservation logic. Applies
#     to every call to that endpoint; use the *_MODE_SEQUENCE variant below
#     to vary it call by call instead.
#
#   FAKE_GH_REVIEWS_MODE_SEQUENCE, FAKE_GH_COMMENTS_MODE_SEQUENCE,
#   FAKE_GH_ISSUE_COMMENTS_MODE_SEQUENCE
#     Semicolon-separated list of modes, one entry per call — same
#     call-index/repeat-last-entry rules as the ID sequences below. Lets a
#     call succeed during baseline capture (call 1) and then fail on a
#     later poll, e.g. "success;success;error" — the shape needed to test
#     "a later fetch fails after an earlier one in the same poll already
#     found something," as opposed to failing baseline setup outright.
#     Overrides the static *_MODE above when set.
#
#   FAKE_GH_REVIEWS_SEQUENCE, FAKE_GH_COMMENTS_SEQUENCE,
#   FAKE_GH_ISSUE_COMMENTS_SEQUENCE
#     Semicolon-separated list of comma-separated ID lists, one entry per
#     call to that endpoint — e.g. "1,2;1,2;1,2,3" returns {1,2} on the
#     first two calls and {1,2,3} (a new id 3) from the third call on.
#     Once the list is exhausted, the last entry repeats. Defaults to a
#     constant "1,2" (i.e. nothing ever looks new). Call counts are tracked
#     per endpoint in $FAKE_GH_STATE_DIR (default: a fixed tmp path — set
#     this explicitly per test run so parallel/successive tests don't share
#     counters).
#
#   FAKE_GH_TRIGGER_MODE
#     success (default) | error — controls `gh pr comment ...`.
#
# Every returned item is a Bot-authored object shaped enough like the real
# reviews/comments/issue-comments API responses for watch-codex-review.sh's
# jq filters to work unmodified (.id, .user.login, .user.type, .state,
# .path, .line, .body).

set -euo pipefail

STATE_DIR="${FAKE_GH_STATE_DIR:-/tmp/fake-gh-state}"
mkdir -p "$STATE_DIR"

next_call_index() {
  # Returns 1, 2, 3, ... for successive calls to the same endpoint key.
  local key="$1" counter_file="$STATE_DIR/$key.count" n
  n=0
  [ -f "$counter_file" ] && n="$(cat "$counter_file")"
  n=$((n + 1))
  echo "$n" > "$counter_file"
  echo "$n"
}

sequence_entry() {
  # sequence_entry "<sequence string>" <call_index> -> the comma-separated
  # ID list for that call, or the last entry if the index runs past the end.
  local seq="$1" idx="$2"
  IFS=';' read -ra entries <<< "$seq"
  local count=${#entries[@]}
  if [ "$idx" -gt "$count" ]; then
    idx=$count
  fi
  echo "${entries[$((idx - 1))]}"
}

build_json() {
  # build_json "<comma-separated ids>" -> a --paginate --slurp shaped
  # response: an array containing one page-array of objects.
  local ids="$1"
  if [ -z "$ids" ]; then
    echo '[[]]'
    return
  fi
  local out="[[" first=true
  IFS=',' read -ra arr <<< "$ids"
  for id in "${arr[@]}"; do
    if [ "$first" = true ]; then first=false; else out+=","; fi
    out+="{\"id\":$id,\"user\":{\"login\":\"chatgpt-codex-connector[bot]\",\"type\":\"Bot\"},\"state\":\"COMMENTED\",\"path\":\"file.sh\",\"line\":1,\"body\":\"test comment $id\",\"submitted_at\":\"2026-01-01T00:00:00Z\"}"
  done
  out+="]]"
  echo "$out"
}

respond() {
  # $4 (mode_seq), if set, picks the mode per call index the same way $3
  # (ids seq) picks the ID list — e.g. "success;success;error" succeeds on
  # calls 1-2 (so baseline capture, which is call 1, always succeeds) and
  # fails from call 3 on. Falls back to the single static $2 when unset.
  local key="$1" mode="$2" seq="$3" mode_seq="${4:-}"
  local idx
  idx="$(next_call_index "$key")"
  if [ -n "$mode_seq" ]; then
    mode="$(sequence_entry "$mode_seq" "$idx")"
  fi
  case "$mode" in
    error)
      echo "fake-gh: simulated API error for $key (call $idx)" >&2
      exit 1
      ;;
    slow:*)
      sleep "${mode#slow:}"
      ;;
  esac
  local ids
  ids="$(sequence_entry "$seq" "$idx")"
  build_json "$ids"
}

args=("$@")

if [ "${args[0]:-}" = "api" ]; then
  path=""
  for a in "${args[@]:1}"; do
    case "$a" in
      --paginate|--slurp) ;;
      *) path="$a" ;;
    esac
  done
  case "$path" in
    */pulls/*/reviews)
      respond reviews "${FAKE_GH_REVIEWS_MODE:-success}" "${FAKE_GH_REVIEWS_SEQUENCE:-1,2}" "${FAKE_GH_REVIEWS_MODE_SEQUENCE:-}"
      ;;
    */pulls/*/comments)
      respond comments "${FAKE_GH_COMMENTS_MODE:-success}" "${FAKE_GH_COMMENTS_SEQUENCE:-1,2}" "${FAKE_GH_COMMENTS_MODE_SEQUENCE:-}"
      ;;
    */issues/*/comments)
      respond issue_comments "${FAKE_GH_ISSUE_COMMENTS_MODE:-success}" "${FAKE_GH_ISSUE_COMMENTS_SEQUENCE:-1,2}" "${FAKE_GH_ISSUE_COMMENTS_MODE_SEQUENCE:-}"
      ;;
    *)
      echo "fake-gh: unrecognized api path: $path" >&2
      exit 1
      ;;
  esac
elif [ "${args[0]:-}" = "pr" ] && [ "${args[1]:-}" = "comment" ]; then
  if [ "${FAKE_GH_TRIGGER_MODE:-success}" = "error" ]; then
    echo "fake-gh: simulated trigger post error" >&2
    exit 1
  fi
  body=""
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "--body" ]; then
      body="${args[$((i + 1))]}"
    fi
  done
  echo "fake-gh: posted trigger body: $body" >&2
  # Real `gh pr comment` isn't documented to guarantee a trailing numeric ID
  # on stdout. FAKE_GH_TRIGGER_OUTPUT lets a test exercise that: unset, this
  # defaults to the normal ID-bearing URL; set to text with no trailing
  # digits (e.g. "ok", or empty), it reproduces the shape of output the
  # watcher's optional ID extraction must survive without crashing.
  if [ -n "${FAKE_GH_TRIGGER_OUTPUT+set}" ]; then
    printf '%s\n' "$FAKE_GH_TRIGGER_OUTPUT"
  else
    echo "https://github.com/fake/repo/pull/1#issuecomment-999999"
  fi
else
  echo "fake-gh: unhandled invocation: ${args[*]}" >&2
  exit 1
fi
