---
name: model-check
description: Recommends which model — a local model, Codex, or Claude Haiku / Sonnet / Opus — and, for Sonnet and Opus, which effort tier fits the task you're about to do, so you don't default to a high-effort model for simple work. Also decides when a task should be split across an orchestrator and cheaper worker subagents rather than run on one model. Use this whenever you run /model-check, ask "what model should I use", "is this overkill for Sonnet High", "do I need Opus for this", "is this a Haiku task", "should Codex handle this", "should I offload this locally", "should I use high effort", "should I split this into subagents", "would an orchestrator help here", or similar meta-questions about model/effort/agent selection at the start of a conversation or when the shape of the task changes mid-conversation. Advisory only — produces a recommendation, does not switch models itself.
---

# Model Check

Most people default to their editor's highest-effort model for nearly everything, because
switching feels like friction and downgrading feels risky. That default is usually more
model than the task in front of you needs. This skill's job is to look honestly at the task
and recommend the cheapest/fastest tier that's still safe for it, not to justify staying
at the top.

**This is advisory only.** You cannot switch your own model or effort tier mid-session.
Give the recommendation and the reasoning; the user acts on it by picking the model when
they start or continue a session. Say this explicitly in your answer — don't let it read
like you're about to do something.

**Stop after giving the diagnosis. Do not start the underlying task.** When this skill is
invoked, its output *is* the deliverable — not a preamble to work you then launch into.
Give the recommendation and stop your turn there, even if the task itself sounded clear and
you could technically just start doing it. The user may want to switch models or effort
first, and diving in removes that choice — it means the "wrong" model, the one this skill
exists to steer away from, ends up doing the work anyway. Wait for the user's next message
before touching the task, whether that message says to proceed on the current model or
confirms they've switched.

## Adapt this to your own picker

The tiers below (Haiku / Sonnet / Opus, with Low/Medium/High/Extra/Max/Ultracode effort
rungs on Sonnet and Opus) match Claude Code's model picker as of when this was written.
**Confirm your own `/model` menu before trusting these names** — effort-tier labels and
which models carry a dial at all have changed before and will again. If your environment
also exposes a model that draws from a separate credit pool or quota rather than your
normal allowance, exclude it from routine recommendations the same way — note that
explicitly here once you've confirmed which one that is for you, so this skill doesn't
recommend it by default.

A **local model** (e.g. something run via Ollama on your own machine) costs zero
API tokens/credits but also has no tool access, no repo context beyond what's pasted to it,
and materially weaker reasoning than even the smallest hosted tier. It's for offloading a
step entirely out of the session, not a rung to switch to mid-conversation the way effort
tiers are. Treat it as the floor below your smallest hosted model: worth recommending when
the task is so mechanical/self-contained that even that model's judgment is more than
needed, and the task doesn't require touching the repo through the agent's own tools
(edit/run/search/etc). Typical fits: drafting boilerplate text from a fully-specified
template, formatting or converting a blob of text, summarizing a short self-contained
passage, generating a list of straightforward variations. Poor fits: anything needing file
reads/edits, multi-step tool use, project-specific context, or judgment about correctness —
a local model can't verify itself against the codebase, so route those up instead.

This is two independent decisions, not one — *which model* (a capability/judgment
question) and *how much effort within it* (a deliberation question). Collapsing both into a
single score is a common mistake: it can never reach the top model at anything but max
effort, or the middle model at its higher effort rungs. Do it as two stages instead.

## Where a second coding agent fits (a separate tool, not a rung)

If you also run a second coding agent (Codex, or similar) alongside your primary one, it
isn't a tier of the same model — it's a separate tool with its own repo access (often
configured by its own file, e.g. `AGENTS.md`, the way `CLAUDE.md` configures Claude Code).
Where you've decided a split of responsibilities (see this repo's `CLAUDE.md.template`,
"Multi-agent collaboration"), a second agent is often the better fit than any single-model
tier for:

- **Capabilities your primary agent doesn't have** — image generation, a different tool
  integration, whatever it's actually good at that the other isn't.
- **Self-contained tasks that don't need deep, ongoing repo-wide context** — a narrow bug
  fix, a standalone script, a scoped backlog item — especially when your primary agent is
  already busy with something else, so routing the second task elsewhere adds real
  parallel capacity instead of queuing behind it.
- **Independent second-opinion adversarial review on a correctness-sensitive diff** — a
  second agent doesn't share your primary agent's blind spots. Default to recommending this
  whenever a PR touches real application code, not just changes that look higher-stakes at
  a glance — a routine-looking PR is exactly what slips through unreviewed otherwise. Skip
  it only for PRs that can't ship a user-facing bug (docs, tooling, content edits).

Poor fits: anything needing sustained multi-file reasoning in one continuous session,
exploratory/ambiguous work that benefits from conversational back-and-forth, or any
decision that's really the user's to make. If a second agent runs a task in parallel with
an active session on the same repo, it should use a separate worktree or clone, not just a
separate branch — a shared working directory can only have one branch checked out at a
time, so two concurrent processes in it can still overwrite each other's files.

**The reason to reach for a second agent is often the budget, not just the task type.** If
it bills against a separate account or subscription rather than sharing your primary tool's
quota, it's also your quota-relief valve — worth weighting up whenever you're actually
constrained by a shared rate limit (a long unattended run, several tasks queued at once),
even for work that would otherwise sit comfortably with your primary tool. Two costs come
with using it that way, both worth checking rather than assuming: a task finished on the
second tool doesn't necessarily land back in your repo on its own — check whether it needs
a manual publish, merge, or push step before you treat it as shipped — and the task's own
summary of what it did is never itself evidence; verify against the actual commit, PR, or
file it claims to have touched before trusting it.

Check this fit *before* running the model/effort scoring below — if the task is clearly a
second-agent-shaped task, say so up front. This doesn't replace the primary-model
recommendation (something still has to review the second agent's output, or it may not be
the chosen path this time), so still run the scoring and give both.

## Orchestrator + worker subagents (a shape, not a rung either)

Sometimes the right answer isn't one model at all: a stronger model plans and reviews while
cheaper workers handle the bulk. If your tool can spawn sub-agents with a model override
(Claude Code's `Agent` tool works this way), a session can farm sub-tasks out to a cheaper
tier with no setup, no credential, and no extra infrastructure. It works from anywhere the
primary session runs, including a phone-driven cloud session.

**Recommend it only when the sub-tasks are genuinely independent**, because every spawned
agent starts cold and re-derives context the orchestrator already has. Several subagents on
several slices of *one* problem — where each slice needs the whole picture first — costs
*more* than doing it in one session. Several subagents searching unrelated areas, or
drafting several independent things from self-contained briefs, amortizes that cost
properly. Good fits: parallel search across separate parts of a repo, several independent
files getting the same mechanical treatment, a batch of self-contained drafts. Poor fits:
anything where step two depends on step one's answer, or where the orchestrator would have
to paste most of its own context into every worker anyway.

Frame it honestly as **parallelism with a modest token discount, not quota relief** —
subagents spawned this way typically draw on the same account or quota as the parent
session. When the actual constraint is a shared rate limit rather than wall-clock time, a
second coding agent billing against its own separate account (see above) is the answer, not
a subagent fan-out.

**Be wary of proposing an external worker model reached by a bare API call** (a third-party
hosted model, called directly from inside an agent session, as a cheap stand-in for a
subagent or a second coding agent). The failure mode usually isn't the model or its price —
it's that agent cloud/sandboxed environments typically have no real secrets store. An API
key pasted into a session or set as an environment variable sits in plaintext somewhere the
platform's own docs will tell you not to put credentials. On top of that, a worker reached
by a bare API call has no repo access, no tools, and no way to check its own output against
the codebase; you still pay the orchestration cost of assembling its prompt and reviewing
what comes back, so for anything but a large batch, that round trip is often comparable to
just doing the task yourself. The one real exception is a CI system with its own encrypted
secrets store (GitHub Actions and similar) — worth considering only when a task is
genuinely bulk, mechanical, and verifiable by a deterministic script without human
judgment. If nothing in your own backlog currently has that shape, treat this as a door
left open rather than a live option, and don't build it speculatively.

## What to evaluate

Look at the task just described (or, if invoked with no clear task in view, ask what's
about to happen). Score it honestly on these five axes, 0-2 each:

1. **Reasoning depth** — 0: pure lookup/mechanical. 1: some multi-step logic. 2: deep
   judgment, debugging a subtle bug, or genuine architectural tradeoffs.
2. **Ambiguity** — 0: fully specified, one obvious way to do it. 1: a few gaps to fill in.
   2: open-ended or exploratory, real risk of solving the wrong problem.
3. **Novelty vs. rote** — 0: boilerplate, renames, formatting, a script you've written a
   hundred times. 1: adapting a known pattern to a new spot. 2: designing something new.
4. **Blast radius if wrong** — 0: throwaway/local, easy to redo. 1: touches a real
   project's working state but is reversible. 2: irreversible, published, or affects
   production data/money.
5. **Benefit from extended thinking** — 0: thinking harder wouldn't change the output.
   1: some benefit. 2: the task is exactly the kind (multi-file refactor, subtle bug hunt,
   architecture decision) where extended thinking visibly helps.

Also note one flag: **is this a sustained coding grind** — many iterations across multiple
files, the kind of task where the model will be reading/editing/rerunning repeatedly rather
than answering once? (0 = no, 1 = yes.) This exists to separate the two highest rungs, if
your picker has two, from each other.

## Stage 1: pick the model

Add novelty + ambiguity + blast radius (range 0-6) — these three are the "how much
capability and judgment does this need" axes, independent of how hard it has to think.

| Sum | Model   |
|-----|---------|
| 0-1 | Smallest hosted model (e.g. Haiku) |
| 2-4 | Mid-tier model (e.g. Sonnet) |
| 5-6 | Top-tier model (e.g. Opus) |

*At sum 0-1, recommending a local model needs two things to both hold, not just one:
the tool-use gate above (no repo/tool access, no project-specific context needed), AND
reasoning depth scored 0-1, not 2. A fully self-contained, pasted-in task can still need
real reasoning — a subtle bug in a snippet someone pastes you can score 0 on novelty/
ambiguity/blast-radius (nothing new, fully specified, throwaway) while reasoning depth
is 2 (finding it takes real judgment), and that's exactly the "judgment about what's
correct" case the local-model description above already calls a poor fit — a local
model can't verify itself against anything, pasted snippet included. Only recommend
**local model (free)** and say so explicitly when the tool-use gate passes AND
reasoning depth is also 0-1.

If the tool-use gate fails (tools or project context are actually needed), stay on the
smallest hosted model — that's just the table's normal sum 0-1 result. But if reasoning
depth is 2, don't fall back to the smallest hosted model either: that tier has no effort
dial (Stage 2 below is skipped for it), so a task that genuinely needs deep reasoning
would land there with no way to get either more model capability or more deliberation —
neither Stage 1's sum nor Stage 2's effort ever actually sees the reasoning-depth signal.
Promote to at least the mid-tier model instead, so Stage 2 has an effort dial to spend
that signal on.

## Stage 2: pick the effort (skip for tiers with no effort dial)

Add reasoning depth + thinking-benefit + the coding-grind flag (range 0-5) — these are the
"how much deliberation does this need" axes.

| Sum | Effort (example rungs) |
|-----|-----------|
| 0   | Low       |
| 1   | Medium    |
| 2   | High      |
| 3   | Extra     |
| 4   | Max       |
| 5   | Ultracode |

On a tie or borderline sum in either stage, round down to the cheaper option — the whole
point of this skill is correcting an over-High default, so ties favor stepping down, not
up.

## Output format

Keep it to a few lines. Don't pad it.

```
[**Second-agent fit: [why, one line]** — omit entirely if the task isn't shaped for one]
[**Delegation fit: [why, one line]** — omit unless the task splits into genuinely
independent sub-tasks; name the orchestrator tier and the worker tier]
**Recommendation: [Model]**[, [Effort] effort — omit for tiers with no dial]
Why: [one line naming the axes that actually drove each stage — not generic filler]
(Advisory only — I can't switch mid-session. Pick this next time you start/continue a
session.)
```

If the task is a poor fit for the current session's model (e.g. you're running the top
tier but this scores as a bottom-tier task), say so plainly rather than softening it —
that's the whole reason this skill exists.

End your turn immediately after this output. Do not follow it with "starting now" or any
work on the underlying task — wait for the user to respond first.

## Dispatching to a local model

If you run a local model via Ollama, `local-llm.ps1` in this skill's folder calls Ollama's
REST API directly (`localhost:11434/api/generate`) rather than the interactive `ollama run`
CLI, because the CLI's TTY output is full of ANSI spinner/cursor codes that pollute
captured output — the API returns clean JSON.

**Local-machine only — check before attempting dispatch.** This only works when the
session actually has a shell on the machine running Ollama. In a cloud/remote/sandboxed
session there is no local machine to reach: the script won't be on disk,
`localhost:11434` won't have anything listening, and a shell tool may not even be offered.
If a quick reachability check fails, don't keep retrying — that's the signal you're not on
the right machine. In that case still give the local-model recommendation in your output
(it's still the right advisory answer), but skip the dispatch and hand over the command to
run once the user is at that machine:

```
powershell -File path\to\local-llm.ps1 "your prompt here"
```

Usage (when dispatching yourself, on the right machine):

```
powershell -File path\to\local-llm.ps1 "your prompt here"
powershell -File path\to\local-llm.ps1 -File path\to\prompt.txt
some-command | powershell -File path\to\local-llm.ps1
```

Prints only the model's response text to stdout (no thinking trace, no JSON wrapper). Only
dispatch tasks that are self-contained text in/text out with no need for this session's
file/repo access, since a local model never sees the codebase. If Ollama isn't running, the
script errors clearly rather than hanging — report that back rather than retrying blindly.
