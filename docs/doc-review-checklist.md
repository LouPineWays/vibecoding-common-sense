# Before you request review on a design or architecture doc: a checklist for cutting round count

[`pre-review-checklist.md`](pre-review-checklist.md) is the code-review version of this same idea:
a handful of cheap checks run before sending something to a slow, external reviewer, aimed at
catching in minutes what would otherwise cost several review round-trips. Two of its five checks
(tension check, symptom-vs-rule check) generalize to prose as-is; the other three don't translate
directly, because a design doc has no compiler or test suite to converge against. A reviewer
without a fixed target free-reviews from taste every round, which is what makes a doc loop
open-ended in a way a code review loop usually isn't — code review tennis at least terminates when
every reported bug is fixed; doc review tennis can keep finding new things to reorganize
indefinitely. This is the doc-specific version, prompted by a review loop on a design doc that ran
to 16 rounds in a production repo built on this pack's conventions — enough to be worth a checklist
rather than another one-off diagnosis.

1. **Tension check.** Does the doc involve two or more things that can trade off against each
   other — speed vs. simplicity, one component's ownership vs. another's, a decision made now vs.
   one deliberately deferred? If yes, write the full list of things in tension, a sentence each,
   before the first draft goes out for review. Discovering these one round at a time, as each
   reviewer round surfaces the next one, is the single biggest driver of a long doc loop.

2. **Rubric check.** Before requesting review, write down the specific questions this doc must
   answer without ambiguity — what talks to what, what's explicitly out of scope, what's deferred
   and why, who owns what. A reviewer checking a draft against a fixed rubric converges; a
   reviewer re-reading from scratch each round free-associates a new opinion every time, and
   "free opinion, addressed, repeat" is what a long loop actually looks like from the inside.

3. **Invariant check.** Does this doc depend on a decision already settled elsewhere — a past
   architecture decision, a house rule in `CLAUDE.md`, a question a previous review round already
   resolved? Check the new draft against every one of those, not just the section you just edited.
   A doc that quietly contradicts a decision made two rounds ago, in a section nobody thought to
   re-check, is the prose equivalent of the reintroduced bug in
   [`review-loop-case-study.md`](review-loop-case-study.md).

4. **Self-review pass.** Read the whole doc end-to-end against the rubric from check 2 before
   sending it for review. A rubric nobody actually consults before hitting send is dead weight —
   this step is what makes it real.

5. **Symptom-vs-rule check.** For each review comment you just addressed, can you name a slightly
   different question a reader could still ask that your edit doesn't answer? If yes, you patched
   the sentence the reviewer pointed at, not the structural gap behind it, and the next round will
   just find the gap from a different angle.

6. **Round-cap check.** A doc has no compiler forcing convergence, so agree — with yourself or
   whoever's reviewing — on what "good enough to ship, revise later" looks like before round three.
   Feedback that's a genuine unanswered question from the rubric is blocking; feedback that's a
   phrasing preference or "I'd have organized this differently" is a follow-up note, not another
   round. Without this line drawn in advance, every round looks equally mandatory and the loop has
   no natural stopping point.

## Why run these before the request, not after

Same reasoning as the code checklist: each of these costs a few minutes, and every round they
prevent costs whatever the reviewer's actual turnaround is. The difference for docs is that
there's no fast local harness to fall back on if you skip this — a compiler tells you when code is
wrong; nothing tells you a doc is done except a human or reviewer deciding it is, which is exactly
why doing this work before the first round is the only lever that exists.
