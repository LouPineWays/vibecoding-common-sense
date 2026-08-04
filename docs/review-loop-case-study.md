# Case study: 26 rounds to fix one script, and how to need fewer next time

`scripts/watch-codex-review.sh` and this pack's `CLAUDE.md.template` rule ("When one spot
keeps needing fixes, stop and diagnose before patch three") both came out of building
[PR #1](https://github.com/LouPineWays/vibecoding-common-sense/pull/1): getting a ~250-line
bash script right took 32 commits, 26 of them fixes for a finding from an automated
reviewer, almost entirely concentrated on one function's timing and error-handling logic.
That CLAUDE.md rule states the diagnosis-first principle in general terms. This is the more
specific version: what actually made the round count that high, and what would have cut it,
concretely enough to apply to your own version of this situation.

## What the 26 rounds actually looked like

Not random bugs. A recurring pattern:

- **Symptom-fix, not requirement-fix.** A finding names one failing scenario, the fix makes
  that scenario pass, and the fix ships without re-deriving what the *general* rule should
  be. Several rounds were exactly this shape.
- **Fighting requirements, five rounds running.** The worst stretch (gotchas #19, #21, #22,
  #23, #25 in the script's own header comments) was one underlying tension — "give the
  moment right before the deadline a real chance to be checked" versus "never let the
  watcher run past the deadline it was given" — solved four different ways in a row, each
  one satisfying whichever half of the tension the *last* finding had complained about while
  quietly breaking the other half. Nobody wrote both halves down together until round five.
- **The fix for "don't lose data on failure" got reintroduced by the fix for "detect
  persistent failures."** Two rounds after fixing "a failed fetch shouldn't discard an
  earlier successful fetch in the same call," the persistent-failure-detection feature
  added its own early `exit 1` — the identical bug, from a new direction, because the new
  code was written without checking it against the rule the previous fix had just
  established.
- **No fast way to check any of this.** Every fix, through round ~20, was verified by
  pushing, re-triggering the real bot, and waiting several minutes for it to respond — so
  even a correct fix couldn't be cheaply re-confirmed against the *other* nine scenarios it
  might have affected. Verification cost shaped what got verified: only the one reported
  case, every time.

## What actually cut the round count

Once `scripts/test/fake-gh.sh` existed (built starting around round 20, after a direct
prompt to stop and diagnose rather than keep patching), the remaining rounds converged
fast: a finding became a test case in seconds, the fix got checked against the *entire*
matrix — not just the new scenario — before ever touching the real PR, and most fixes
needed only one more real-world round to confirm instead of two or three. The fix that
finally closed the five-round timing fight (#25) was the first one written *after* the
harness existed to make "does this satisfy every requirement, not just the reported one"
answerable in seconds instead of a several-minute guess.

## For next time

1. **Build the fast local repro before the second fix, not after the eighth.** The general
   version of this is already in `CLAUDE.md.template`. The specific trigger: the moment
   verifying a fix costs real external time (a slow bot, a live API, a human), and you're
   about to fix the same function for the second time, stop and build the repro first. Its
   cost is fixed; paying it once and amortizing beats paying the external round-trip tax on
   every attempt.
2. **When a fix is your second or third attempt at the same behavior, write the full
   requirement list before writing the code, not after the next finding.** The five-round
   timing fight had exactly four requirements in tension (always poll at least once; never
   exceed the deadline; don't busy-loop; don't discard budget that's genuinely still there).
   All four were discoverable from the first round — they just weren't written down
   together until the fifth. A two-minute list turns "does this fix the reported case"
   into "does this fix satisfy every requirement simultaneously," which is the question
   that actually matters and the one narrow patches keep failing silently.
3. **Check every new fix against the invariants your last fix just established.** The
   discard-on-failure bug came back because the persistent-failure code was written without
   re-checking it against "don't let one endpoint's failure discard another's already-fetched
   result" — a rule that had been fixed and documented two rounds earlier, in the same
   function, and simply wasn't re-applied to the new code path. Skimming your own recent
   fixes to the function you're about to touch again is cheap; re-discovering the same bug
   from a reviewer is not.
4. **Turn each finding into a test case before writing the fix, once the harness exists.**
   Red, then green, same as any other TDD loop — it's what made the last several rounds of
   PR #1 converge in one round apiece instead of two or three.

None of this is specific to bash, timing logic, or Codex. The pattern — narrow, individually
correct fixes that never converge because nobody re-derives the general shape of the
problem, and no cheap way exists to check a fix against more than the one case that
prompted it — shows up anywhere a fix is verified against a slow, external signal. The fix
is the same wherever it shows up: stop, name the actual requirement set, build a fast local
way to check against all of it, and keep both up to date as you learn more.
