# The bounded review cycle: two passes, then stop

[`pre-review-checklist.md`](pre-review-checklist.md) and [`doc-review-checklist.md`](doc-review-checklist.md)
attack review-round inflation from the front: run some cheap checks before the first request, so the
external reviewer sees a better draft than it otherwise would. This doc attacks the same problem
from the other end, because preparation alone doesn't bound anything.

Even a well-prepared change turns into a tennis match. The reviewer finds something, you fix it, the
reviewer looks again and finds something new, you fix that, and nobody ever decided how many times
that could happen. Each round looks justified on its own. The sequence has no stopping rule, and
"review until the reviewer stops finding things" isn't one — a reviewer re-reading a changed diff
from scratch will nearly always find *something*, because there's always another angle.

The fix is to decide the stopping rule in advance. A change worth reviewing gets **two** reviewer
passes, deliberately different in shape, and then the cycle is closed.

| Stage | Where | What it looks at | Bound |
| --- | --- | --- | --- |
| 1. Inline review | On the PR, before merge | The diff, line by line | Exactly one round |
| 2. Acceptance audit | On an issue, after merge | The merged result as a whole | Exactly one round, ends in a verdict |

Stage 2 is the stopping review for that cycle. It isn't "one more look" — it asks a different
question, once, about the finished thing rather than about the change that produced it.

## When this applies

When the change is important enough to warrant an independent review at all. Whatever rule your
project already uses to decide that still decides it. This doc governs what happens *after* you've
decided to review, not whether to review.

It does not apply to changes your existing policy already lets skip independent review — docs,
tooling config, content edits, anything that can't ship a user-facing bug. Don't put a typo fix
through a post-merge acceptance audit. A two-stage process attached to a trivial change is pure
overhead, and overhead is exactly what gets a process skipped on the change where it actually
mattered.

## Stage 1: one inline review round

1. Finish the change and run the checks your project requires locally. Name what you actually ran,
   and don't imply a check passed that you didn't run.
2. **Freeze the head.** Note the exact commit SHA you're asking about. Everything below refers to
   that commit.
3. Request **one** inline review round at that frozen head. If you're using
   [`scripts/watch-codex-review.sh`](../scripts/watch-codex-review.sh), that's the `--trigger` form,
   which posts the request and then polls for the response. Drop `--trigger` if the review was
   already requested some other way; passing it while a request is in flight re-posts the comment
   and can produce a duplicate response.
4. Tell the reviewer to read your project's agent instructions and relevant source-of-truth
   material, inspect the complete change in context rather than isolated diff hunks, report only
   actionable defects, distinguish genuine defects from scope expansion / deferred parameters /
   stylistic preference / superseded material, and not modify files unless explicitly asked.
5. **Verify every finding yourself.** A finding is a claim, not a fact. This matters more than it
   sounds: review bots produce confident, plausible-sounding non-issues, and a fix applied to a
   non-issue is a real regression bought with real time.
6. Reject false positives, and record why. A rejected finding with a stated reason is a closed
   question; a silently ignored one comes back.
7. Deduplicate what's left by underlying defect, not by comment count. Three comments about one
   root cause are one fix.
8. Batch every valid finding into **one** consolidated correction pass.
9. Re-run the required checks.
10. **Do not request a second inline round on that PR.**
11. Merge only when all of these hold:
    - every valid finding from the one round is fixed;
    - required tests and checks pass, and CI is green on the head commit;
    - no Critical finding, unresolved owner decision, security concern, data-loss risk, migration
      uncertainty, or other blocker remains;
    - the PR head and intended merge target are what you think they are, re-verified.

**One round is a bound on review, not permission to merge a known defect.** If the round exposes a
decision that can't be settled safely without whoever owns the project, stop and get that decision.
Once it's made and implemented, verify locally and carry on — that isn't a new round, and it doesn't
restart the exchange.

## Stage 2: one post-merge acceptance audit

1. Record the exact merge commit SHA. If your project squash-merges, that's the squash commit on the
   default branch, not the PR head.
2. Open **one** issue for a read-only holistic audit of that exact commit.
3. Put the complete audit specification in the issue body.
4. Trigger the reviewer with a **separate comment** on that issue.

### The issue-trigger rule

> Put the full audit specification in the issue body, then invoke the reviewer in a separate issue
> comment that points at the body and names the exact commit SHA.

A mention in the issue body alone does not reliably start the task. Never put the invocation in both
the body and a comment — that's how two agents end up auditing the same commit and you get a
duplicate report to reconcile. Before adding the trigger comment, check whether someone already
invoked it. Same duplicate-invocation trap as re-triggering a review that's already in flight.

One mechanical gotcha worth knowing: **GitHub eats angle brackets in an issue body as HTML.** A
generic type or a templated placeholder written the usual way comes back with its contents silently
gone. Write them in words instead, and re-read the created issue rather than trusting what you
submitted. An audit spec whose entire value is that nothing has to be inferred can't afford a
sentence that quietly lost half its meaning.

### What the audit asks for

The specification should require the reviewer to:

- read your project's agent instructions, its source-of-truth hierarchy, and any applicable
  checklist;
- read the merged PR and its one inline review round;
- inspect the **complete current files**, not only diff hunks;
- verify the disposition of every valid finding from the PR review;
- look for cross-file contradictions, regressions, missing state transitions, authority conflicts,
  unhandled boundary cases, and architectural traps *exposed by the consolidated fix* — the class of
  problem a line-level pass structurally cannot see;
- distinguish semantic defects from intentionally deferred parameters;
- deduplicate findings by root cause;
- return **one consolidated report**, not piecemeal comments;
- include severity counts, exact evidence, the consequence, the smallest correction, and whether
  owner judgment is required;
- end with an explicit **CLEAN** or **NOT CLEAN** verdict;
- modify nothing: no files, branches, PRs, or issues.

Say plainly that inventing findings to justify another round isn't wanted, and that a deferred
parameter isn't a defect unless its absence blocks implementation. A report saying "nothing material
remains" is a successful audit, not a lazy one. Add whatever your own project's standing conventions
are to the rubric — the point of a fixed rubric is that the reviewer checks the same things you'd
check, instead of free-associating a new opinion each time (see
[`doc-review-checklist.md`](doc-review-checklist.md), check 2, for why that distinction drives loop
length).

## If the audit is CLEAN

Stop. The cycle is closed. Don't invent a third stage.

Close the audit issue, and close whatever issue the PR implemented if it's still open. Record the
outcome wherever your project records outcomes, ideally somewhere falsifiable — a status entry
citing the merge commit beats a checkbox someone ticked.

## If the audit is NOT CLEAN

1. Verify each finding against the audited merge commit.
2. Reject false positives and duplicates.
3. Settle any required owner decisions together, before editing.
4. Batch every accepted finding into **one** new correction PR.
5. Run that PR through this same cycle: one inline round, batch, verify, merge, one audit.

Don't answer findings one at a time with repeated fix-and-re-review loops. That's the tennis match
this doc exists to end, and it doesn't become acceptable just because an audit started it.

## What counts as a round

Worth stating precisely, because "one round" is only a bound if everyone counts the same way.

- Multiple comments from **one** review invocation are **one** round.
- Fix commits answering that round do **not** create another round.
- A new review invocation on the same PR **is** a second round, and is prohibited by default.
- The post-merge audit is a separate acceptance stage, **not** a second PR-review round.
- Two reviewers accidentally run against the same frozen commit are **parallel opinions** on one
  round. Consolidate them; don't treat them as two sequential rounds.

## Why two passes beat six

Two passes of deliberately different shape catch more than six passes of the same shape.

The inline round catches what's wrong with the lines. The acceptance audit catches what's wrong with
the result — including anything the consolidated fix itself introduced, which is exactly the code
the inline round never saw. That last part matters more than it looks: **the fix commits from a
review are the least-reviewed code in the whole change**, because by the time they exist the PR
already looks thoroughly reviewed and nobody's inclined to start over. A holistic pass over the
merged files is what closes that gap, and it closes it without another inline round.

Meanwhile the marginal thing found in round six is rarely the thing that would have shipped a bug,
and every round costs whatever your reviewer's turnaround actually is. Bounding the cycle isn't
lowering the bar — it's spending the same attention on two questions that are actually different,
instead of six repetitions of one.
