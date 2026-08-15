#!/usr/bin/env bash
# Collect the git-layer evidence a retro runs on, in one pass.
#
# Why this is a script and not a list of commands in SKILL.md: two of these
# incantations have traps that silently inflate the numbers, and a retro whose
# numbers are wrong is worse than no retro. Both are fixed here so nobody has to
# remember them.
#
#   1. `git log --grep` searches the WHOLE commit message, not the subject line.
#      Agent-written commit bodies narrate the fixes they made, so a body-matched
#      "fix-shaped commit" count over-reports badly — measured at 6 vs 3 on a
#      17-commit history, i.e. 100% inflation, purely from prose like "26 of them
#      review-finding fixes" inside commits that fixed nothing. Everything below
#      matches on `%s` (subject) only.
#   2. Merge-commit subjects carry the branch name ("Merge pull request #5 from
#      user/port-review-loop-fixes"), so a branch called `...-fixes` registers as
#      a fix commit forever. Hence --no-merges on the classification passes.
#
# Output is plain text sections, meant to be read by an agent running the retro
# skill, not parsed. Read-only: nothing here writes, fetches, or mutates.
#
# Usage: collect-git-evidence.sh [--since <git-date>] [--branch <default-branch>]
# Defaults: --since "30 days ago", --branch autodetected from origin/HEAD.

set -uo pipefail

SINCE="30 days ago"
BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || { echo "--since requires a value" >&2; exit 2; }
      SINCE="$2"; shift 2 ;;
    --branch)
      [ $# -ge 2 ] || { echo "--branch requires a value" >&2; exit 2; }
      BRANCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 1; }

# GNU `date -d` parses the same loose syntax git's --since accepts, so it doubles
# as a validator; a malformed --since doesn't error inside git, it silently
# matches nothing, which reads as an empty, healthy-looking window. BSD/macOS
# `date` doesn't support -d, so this check is skipped there rather than made to
# fail on a platform difference — better to under-validate than to false-positive.
if date -d "$SINCE" >/dev/null 2>&1; then
  : # parses fine
elif command -v gdate >/dev/null 2>&1 && gdate -d "$SINCE" >/dev/null 2>&1; then
  : # GNU coreutils installed under its usual macOS/Homebrew name
elif date -d "30 days ago" >/dev/null 2>&1; then
  # GNU date is present and rejected $SINCE outright — a real typo, not a
  # syntax GNU date just doesn't happen to support.
  echo "invalid --since value: '$SINCE'" >&2
  exit 2
fi

# Resolve the default branch rather than assuming main. origin/HEAD is only set
# if someone ran `git remote set-head`, so fall back through the likely names and
# finally to the current branch — an unresolvable default is a caveat to report,
# not a reason to guess silently.
if [ -z "$BRANCH" ]; then
  BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  if [ -z "$BRANCH" ]; then
    for candidate in main master trunk develop; do
      if git show-ref --verify --quiet "refs/remotes/origin/$candidate" \
      || git show-ref --verify --quiet "refs/heads/$candidate"; then
        BRANCH="$candidate"; break
      fi
    done
  fi
  [ -z "$BRANCH" ] && BRANCH=$(git branch --show-current)
fi

REF="$BRANCH"
git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" && REF="origin/$BRANCH"

# A mistyped --branch, or a repo with none of the usual default-branch names and
# a detached HEAD, leaves REF pointing at nothing. Every section below pipes
# `git log`'s exit code into `wc`/`sort`/etc, which always exits 0 — so an
# unresolved REF would otherwise produce a silent, confident-looking empty
# report instead of an error. Catch it once, here, rather than in nine places.
git rev-parse --verify --quiet "$REF" >/dev/null \
  || { echo "cannot resolve ref '$REF' (from --branch '$BRANCH') — check the branch name" >&2; exit 1; }

FIXWORDS='\b(fix|fixes|fixed|bug|bugfix|hotfix|revert|reverts|regress|regression|broken|oops|typo)'

echo "=== retro evidence ==="
echo "default branch : $BRANCH   (analysing $REF)"
echo "window         : since $SINCE"
echo "collected      : $(date -u '+%Y-%m-%d %H:%MZ')"
LASTFETCH=$(git log -1 --format=%cr "$REF" 2>/dev/null || echo unknown)
echo "tip of $REF is $LASTFETCH — if that looks stale, fetch before trusting any count below"

TOTAL=$(git log --oneline --since="$SINCE" "$REF" 2>/dev/null | wc -l | tr -d ' ')
FIRSTP=$(git log --oneline --first-parent --since="$SINCE" "$REF" 2>/dev/null | wc -l | tr -d ' ')
echo
echo "--- 1. window size (n, for the small-n rule) ---"
echo "commits in window          : $TOTAL"
echo "first-parent (≈ landings)  : $FIRSTP"

echo
echo "--- 2. landings without a PR reference (direct-to-default proxy) ---"
echo "Non-merge commits on the default branch with no (#N) in the subject. On a"
echo "squash-merge repo these are commits that never went through a PR. On a"
echo "merge-commit repo, check them against section 4 before believing it. On a"
echo "rebase-merge repo this signal is unreliable in the other direction: reviewed"
echo "commits land individually with no (#N) and no merge commit, so this section"
echo "can flag ordinary reviewed work as unreviewed. Corroborate against the PR"
echo "API before calling any of these unreviewed, not just this git layer alone."
git log --first-parent --no-merges --since="$SINCE" --format='%h  %ad  %an  %s' --date=short "$REF" \
  | grep -vE '\(#[0-9]+\)' || echo "(none)"

echo
echo "--- 3. fix-shaped landings (subject-line match only) ---"
git log --no-merges --since="$SINCE" --format='%h  %ad  %s' --date=short "$REF" \
  | grep -iE "$FIXWORDS" || echo "(none)"

echo
echo "--- 4. merge commits and their branch commit counts (review-round hint) ---"
echo "This counts commits reachable on the branch, not pushes — a branch pushed"
echo "once with eleven commits and one force-pushed eleven times down to one both"
echo "read differently here. Treat a high count as 'worth checking the PR API for"
echo "the real push/review-round count', not as review-round inflation on its own."
echo "Empty on a squash-merge repo — that history is gone, use the PR layer instead."
git log --merges --first-parent --since="$SINCE" --format='%h|%s' "$REF" 2>/dev/null | while IFS='|' read -r h s; do
  n=$(git rev-list --count "$h^1..$h^2" 2>/dev/null || echo '?')
  printf '%4s commits  %s  %s\n' "$n" "$h" "$s"
done
[ -z "$(git log --merges --first-parent --since="$SINCE" --format='%h' "$REF" 2>/dev/null)" ] && echo "(no merge commits in window)"

echo
echo "--- 5. hotspots: files touched by fix-shaped commits (repeat-patch signal) ---"
echo "Count >= 3 is the 'stop and diagnose before patch three' threshold."
HOTSPOTS=$(git log --no-merges --since="$SINCE" --format='%h%x09%s' "$REF" \
  | grep -iE "$FIXWORDS" | cut -f1 \
  | xargs -r -n1 git show --format='' --name-only 2>/dev/null \
  | grep -v '^$' | sort | uniq -c | sort -rn | head -15)
if [ -n "$HOTSPOTS" ]; then echo "$HOTSPOTS"; else echo "(no fix-shaped commits in the window)"; fi

echo
echo "--- 6. hotspots: overall churn, all commits ---"
git log --no-merges --since="$SINCE" --format='' --name-only "$REF" \
  | grep -v '^$' | sort | uniq -c | sort -rn | head -15

echo
echo "--- 7. explicit reverts ---"
git log --since="$SINCE" --format='%h  %ad  %s' --date=short "$REF" \
  | grep -iE '\brevert' || echo "(none)"

echo
echo "--- 8. branches not merged into the default branch (abandoned-work proxy) ---"
git for-each-ref refs/remotes/origin --no-merged "$REF" \
  --format='%(committerdate:short)  %(refname:short)' --sort=committerdate \
  | grep -v "origin/$BRANCH\$" || echo "(none)"

echo
echo "--- 9. mechanism rungs already present in this repo ---"
echo "Which rung a rule already sits on decides what 'escalate one rung' means."
for p in CLAUDE.md AGENTS.md .claude/settings.json .claude/settings.local.json \
         .claude/hooks .githooks .github/workflows .pre-commit-config.yaml; do
  [ -e "$p" ] && echo "present : $p" || echo "absent  : $p"
done
if [ -d .github/workflows ]; then
  echo "workflows:"; ls .github/workflows | sed 's/^/  /'
fi

echo
echo "=== end evidence ==="
echo "Keyword matches above are a filter, not a verdict — read the subjects before"
echo "counting them. 'Port real fixes found upstream' matches the fix pattern and"
echo "fixed nothing here."
