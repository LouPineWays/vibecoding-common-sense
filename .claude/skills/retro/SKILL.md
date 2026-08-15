---
name: retro
description: Review this repo's own git and PR history for evidence of process failures — the same spot patched three times, work landing on the default branch with no review, review rounds inflating, CI red at merge, branches abandoned half-done — then propose at most three fixes, each one moving a specific rule up exactly one rung from "written down somewhere" toward "a mechanism that can't be skipped". Use when the user says "/retro", "review my repo activity", "how's my process", "what should I change about how I work", "run a retrospective", "are my rules actually working", "what keeps going wrong here", or asks after a release or milestone what to do differently next time. Evidence-only and read-only: every finding cites a SHA or PR number, velocity and productivity metrics are deliberately out of scope, and it never edits CLAUDE.md, commits, or opens an issue on its own — it proposes the exact change and waits.
---

# Retro — read the repo's own history, then fix the mechanism

A repo records every process failure you've had, precisely and with timestamps, and almost
nobody reads it that way. The rules in `CLAUDE.md` were written from the failures you happened
to notice; the ones you didn't notice are still in the log, repeating. This skill reads the log
for that specific purpose — not to summarize what happened, but to find the two or three places
where the *way* work is happening keeps producing the same kind of damage, and to say what to
change so it stops.

The trap it exists to avoid is the dashboard: twelve metrics, all true, none of them anything
you'd act on. A retro that hands back a list changes nothing. A retro that hands back one
concrete edit to one file, backed by three commit SHAs, changes the next month.

## Scope check — settle these first, they change every verdict

1. **The window.** Default to the last 30 days. Widen it if the repo is slow (a 5-commit window
   supports no conclusions) and narrow it if it's fast. State it in the output — "3 of your PRs
   went in unreviewed" is meaningless without the denominator.
2. **The stakes.** Ask, or infer from the repo and stop if you can't: does this ship to users,
   or is it a scratchpad? *A process is only broken relative to what it's protecting.* A solo
   repo with no users doesn't need a review gate, and telling it otherwise is exactly the
   generic best-practice nagging that makes people stop running retros. Findings that assume
   stakes the repo doesn't have are noise.
3. **Where the rules live.** `CLAUDE.md`, `AGENTS.md`, both, or nowhere yet. Fixes land there,
   so a repo with no rules file at all is a different (and much simpler) first finding than a
   repo with a rules file being ignored.
4. **Which evidence layers you can actually reach** — next section.

## Evidence layers, and saying which one you had

**Layer 1, git, always available.** Run the bundled collector:

```
.claude/skills/retro/collect-git-evidence.sh --since "30 days ago"
```

It resolves the default branch rather than assuming `main`, prints nine numbered sections, and
mutates nothing. Read its header comment before hand-rolling any of these queries yourself —
two of them have traps documented there that silently inflate the counts.

**Layer 2, PRs and CI, only if a host API is reachable** (`gh`, a GitHub MCP server, or the
equivalent for your host). This layer is where the highest-value signals live, and it is
routinely unavailable — a sandboxed session may have neither `gh` nor network. Ask it for, per
merged PR in the window: review count and approval state, number of review comments, number of
pushes after the first review, the check-run conclusions at the merge commit, and time from
"ready" to merge. Plus workflow re-run counts, which is the only way to see flaky CI.

Three things about this layer that will otherwise produce a confidently wrong retro:

- **`merged` and `merged_at` disagree.** Some clients return `"merged": false` on a PR that
  demonstrably landed, while `merged_at` carries the real timestamp. Trust `merged_at`, or
  cross-check against the default branch's log. A retro reporting "0 of 14 PRs merged" is the
  visible version of this; the invisible version is a merge-rate finding built on the same field.
- **A clean review often isn't a review.** Review bots frequently post a no-findings pass as an
  ordinary issue comment, not a formal review — so "0 reviews" can mean "reviewed and clean".
  Check comments as well as reviews before claiming anything went in unreviewed, and identify
  the reviewer by account name rather than assuming.
- **Time-to-merge is the cheapest reality check you have.** A PR created and merged inside a
  minute cannot have been reviewed by anything, whatever the review count says. Read it against
  the stakes rather than as a defect on its own: for content and docs it's usually the workflow
  working as intended, and only becomes a finding when it's code the repo's own rules say should
  have been looked at.

**Never substitute status prose for either layer.** A README badge, a "done" section, a comment
claiming something is enforced — those are the artifacts most likely to be stale, and a retro
built on them measures your documentation habits rather than your process. Only the log and the
API count. If you cannot check a claim, it goes in Unknowns.

**Say which layers you had, in the output header, every time.** A retro that ran git-only and
reports "no unreviewed merges found" is stating something it had no way to observe, and that
false clean bill of health is the single most damaging thing this skill can produce.

## What the signals mean

The collector's sections map onto specific failure modes. The mapping is the point — a raw count
is not a finding.

- **§2, landings with no PR reference** → work reaching the default branch unreviewed. Weigh it
  against the stakes from the scope check before calling it a defect.
- **§3 and §5, fix-shaped commits and the files they touch** → the repeat-patch loop. Three or
  more fix commits on one file in one window is the "stop and diagnose before patch three"
  threshold: probably not several bugs but one fragile design emitting a new symptom each round.
  The fix is rarely another patch; it's a fast local repro so attempts cost seconds, or a
  restructure.
- **§4, commits per merged branch** → review-round inflation, on merge-commit repos. A branch
  that took eleven pushes to land spent most of them answering review findings one at a time.
  Squash-merge repos destroy this history, so get it from the PR layer or say you couldn't.
- **§7, reverts** → something shipped that shouldn't have. Always worth reading individually;
  the count matters less than what the revert says about how it got through.
- **§8, unmerged branches** → abandoned work, and a branch-safety hazard. The risk isn't the
  waste, it's that a future branch gets cut from one of these by accident and drags it along.
- **§9, mechanism inventory** → *which rung each rule currently sits on*, which is what makes
  the escalation below concrete rather than a vibe.
- **PR layer** → unreviewed merges of real application code, merges with checks not green, CI
  re-run without a code change (flaky suite), PRs open long enough to go stale against their base.

## What earns a place in the output

Most signals should die here. Be ruthless — this filter is most of the skill's value.

- **Two occurrences, or one with irreversible blast radius.** One occurrence is an anecdote.
  Writing a standing rule from a single event is how a rules file grows to a length nobody
  reads, which costs more than the event did. Name single occurrences as incidents if they're
  severe, and say plainly that they aren't yet patterns.
- **Cite the evidence inline.** SHAs, PR numbers, file paths. A finding a reader can't verify
  in thirty seconds gets ignored, and rightly.
- **Counts, not percentages, below n=20.** "3 of 6 PRs" is a fact; "50% of PRs" invites a trend
  line through six points. Percentages on small n are the fastest route to acting on noise.
- **Every finding ends in one concrete artifact change** — a specific line to add to a specific
  file, a check to add to an existing checklist, a script, a CI step. If you can't name the
  artifact and roughly where it goes, the finding isn't ready; drop it and say so in Unknowns.
- **Cost the fix honestly, and refuse it if it exceeds the damage.** A CI gate for something
  that cost twenty minutes once a quarter is worse than the thing it prevents. This is a real
  and frequent outcome — "this happens, it isn't worth mechanizing" is a legitimate finding.
- **Check the declined log first.** If a finding was raised before and the user said no, don't
  re-raise it as if it were new. Either drop it, or raise it as "this recurred N more times
  since you declined it" with the new evidence — which is a genuinely different claim.
- **Cap at three.** Rank by damage × evidence strength, report the top three, and say how many
  weaker signals you suppressed so the user can ask for them. The cap is not a formatting
  preference: a person acts on one to three things and skims a list of ten.

## The escalation ladder

The most useful thing history tells you isn't *that* something went wrong — it's whether the
rule meant to prevent it already existed. Those are completely different findings.

Five rungs, weakest to strongest:

1. **Nothing written down.** It lives in someone's head.
2. **A rule in `CLAUDE.md` / `AGENTS.md`.** The agent reads it every session. Free, but relies
   on it being applied in the moment, against whatever else is in context.
3. **A checklist item** in a doc the workflow already stops at — a pre-review checklist, a
   release checklist. Forced at one specific moment instead of hoped for continuously.
4. **A hook or a script** that runs at the moment of risk. Can't be forgotten. Can be skipped.
5. **A CI gate** that blocks the merge. Can't be skipped, costs the most to build and keep, and
   becomes background noise if it ever fires falsely.

**A failure that recurred after its rule was written moves up exactly one rung.** Read §9 of the
collector to see which rung it's on now — that's why the inventory is in there.

Two ways this goes wrong, both common:

- **Rewording a rule is not a rung.** When a rule exists and is being violated anyway, the
  wording is almost never why. Bolder phrasing, a bigger heading, and an added "IMPORTANT" all
  feel like action and change nothing. If the rule is clear and still isn't holding, the honest
  conclusion is that prose is the wrong instrument for it — go up a rung.
- **Skipping to rung 5.** Over-escalation is its own failure. A CI gate built in irritation
  after one bad week is a maintenance burden that outlives the irritation. One rung, then
  re-check next retro.

## What this skill deliberately does not measure

- **Velocity of any kind** — commits per day, lines changed, PR throughput, time-to-merge as a
  target. When an agent writes the code these measure the agent's verbosity, not your progress,
  and optimizing them makes it write more, which is the opposite of what anyone wants. Time-to-
  merge is worth reading only as a staleness signal on a specific PR, never as a number to lower.
- **Anything comparing contributors.** Not what this is for.
- **Retiring a rule because nothing violated it.** This looks like tidiness and is a trap: a
  rule with zero violations is at least as likely to be working as to be useless, and absence of
  evidence cannot tell you which. Never propose deleting a rule on that basis. Propose it only
  when the thing the rule protects against has genuinely stopped applying — the dependency is
  gone, the workflow changed — which is a claim about the repo, not about a count.

## The verdict

Print this in chat. Writing it to a file, opening an issue, or editing anything is gated — see
below.

```
## Retro — <repo> · <window> · <n> commits, <m> landings
Evidence: git (tip <age>) + PR/CI via <host>      |  or:  git only — PR layer unavailable (<why>)
Stakes:   <ships to users | internal | scratchpad>
Rules at: <CLAUDE.md | AGENTS.md | none yet>

### 1. <the finding, one line>
Evidence:  <SHA/PR list — enough to verify in 30 seconds>
Pattern:   <the class of failure, not the instances>
Rung now:  <1-5, from §9 + the rules file>  — <"no rule exists" | "rule exists, violated anyway">
Proposal:  <the exact artifact change: file, and what goes in it>  → rung <N+1>
Cost:      <honest — build time, maintenance, false-positive risk>

### 2. …
### 3. …

Suppressed: <k> weaker signals (<short list>) — say the word if you want them.

### Holding
<rules the evidence shows are working — so don't escalate them. Omit if you can't
 evidence it; "no violations seen" is not evidence a rule is working.>

### Unknowns
<what you couldn't check and why. Never empty by convention — write "none" on purpose.>
```

`Rung now` is the line that makes this a retro rather than a lint report, so don't drop it even
when the answer is a boring "1, nothing written down".

If the window holds too little to support anything — a handful of commits, no landings — say
**INSUFFICIENT-HISTORY**, report the window and the counts, and stop. Manufacturing three
findings from four commits is how a retro teaches people to ignore it.

## The declined log

Findings the user explicitly declined go in `.claude/skills/retro/declined.md`, appended without
asking, because re-raising a settled decision every month is the fastest way to make this skill
annoying enough to uninstall. Nothing else is logged there — recurrence of a *finding* is
re-derivable from the history each run, and the current rung is re-derivable from the repo, so
neither needs a file that can go stale.

```markdown
# Declined retro findings

Raised, considered, and deliberately not acted on. Re-raise only with new evidence that the
problem recurred after the decision — and say so explicitly when you do.

---

### [YYYY-MM-DD] — <finding, one line>
**Declined because:** <the user's reason, in their words where possible>
**Would reconsider if:** <what new evidence would change it, if anything>
```

When the user acts on a finding instead, log nothing — the commit that changed the rules file is
the record, and it's a better one.

## The gate

**Free, no confirmation needed:** running the collector, any read-only `git log`/`show`/
`for-each-ref`, read-only host API calls, reading `CLAUDE.md` and the rules and checklists,
printing the verdict, appending to `declined.md`.

**Stop and ask** before editing `CLAUDE.md`, `AGENTS.md`, or any checklist or workflow file;
creating a hook, script, or CI job; committing, branching, or pushing; opening an issue or PR;
and anything that touches the history you're analysing. These are standing rules for the whole
repo — changing them from an automated read of a 30-day window, without the user in the loop, is
exactly the kind of unsupervised scope creep the rules exist to prevent.

**Retro ends in a proposal.** If the user says go, implementing it is a separate task under the
normal workflow. If the fix should exist identically in sibling repos, propagating it is
`recon`'s job, not this one.

## Cadence

Roughly every 20 landings, or after a milestone — whichever comes first. Running it more often
than the history moves produces the same findings with fewer data points behind them, which
trains the reader to skim. If you put it on a schedule, gate it on the window having actually
moved since the last run, and skip silently when it hasn't.
