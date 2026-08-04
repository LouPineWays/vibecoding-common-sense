# Before you request review: a checklist for cutting round count

[`review-loop-case-study.md`](review-loop-case-study.md) documents what a 26-round Codex review
loop actually looked like, and closes with four lessons for next time. Those are framed
reactively — what to do once you've noticed you're a few patches deep into the same spot. This is
the same four lessons moved earlier: run these five checks before you request review at all,
especially before re-requesting it on a function you've already touched once for a finding. None
of it is specific to Codex, bash, or any particular kind of bug — it applies to any change a slow,
external reviewer is about to look at.

1. **Tension check.** Does this change involve two or more things that can trade off against each
   other — timing versus correctness, two different failure modes, performance versus safety? If
   yes, write the full requirement list, a sentence each, *before* you finish the diff. The
   case study's five-round timing fight had exactly four requirements in tension, all
   discoverable from round one — they just weren't written down together until round five.

2. **Second-attempt check.** Is this the 2nd-or-later time you're touching this exact function or
   area for a review finding, and does verifying a fix cost real external round-trip time (a slow
   bot, a live API, a human in the loop)? If yes, stop before writing the next patch and build or
   reuse a fast local repro. Its cost is fixed; paying it once and amortizing beats paying the
   external round-trip tax on every remaining attempt.

3. **Invariant check.** Does the file or function you're editing already carry documented rules
   from a past fix — numbered gotcha comments, a house rule in `CLAUDE.md`, a prior PR's fix? If
   yes, check your new diff against every one of them, not just the new behavior you're adding.
   The case study's discard-on-failure bug came back two rounds after it was fixed, because the
   next feature touching the same function was written without re-checking it against the rule
   the previous fix had just established.

4. **Harness check.** If a fast local harness already exists for this code path (yours from check
   2, or one that predates this change), turn the requirement list from check 1 into test cases
   and get them green before pushing. Red, then green, same as any other TDD loop — Codex should
   be reviewing logic you've already verified against every requirement, not first-draft logic.

5. **Symptom-vs-rule check.** For each line you changed, can you name a slightly different input
   that would still break the same way? If yes, the fix targets the one reported case, not the
   general rule behind it — go back before requesting review. This is the single question that
   separates "correct for the reported case" from "correct in general," and narrow patches keep
   failing it silently.

## Why run these before the request, not after

Every one of these checks is cheap — a few minutes at most. Every round they prevent costs
whatever your reviewer's turnaround actually is: seconds for a fast local test, minutes for a real
bot, longer for a human. The five-round timing fight and the reintroduced discard bug in
[`review-loop-case-study.md`](review-loop-case-study.md) are both cases where the fix that
eventually worked was available from the first round — the round count came from paying the
external round-trip cost to discover it patch by patch instead of naming it up front. See
`CLAUDE.md.template`'s "When one spot keeps needing fixes, stop and diagnose before patch three"
for the reactive version of this same rule, for when you notice the loop after it's already
started.
