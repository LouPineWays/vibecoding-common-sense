---
name: spend
description: Read this session's own transcript to find where the tokens actually went — the startup payload re-read on every turn, a cache miss that re-wrote the whole context, one skill or file read that tripled the context everything after it pays for — then propose at most three specific changes, each with the tokens it would save. Use when the user says "/spend", "where are my tokens going", "why is this session so expensive", "what's burning context", "how do I make this cheaper", "am I wasting tokens", "why did I hit my limit so fast", or asks after a long session what to do differently. Checks the built-in surfaces (/usage, /context, /insights) first and says plainly when one of them already answers the question. Read-only: it never edits config, never clears context, and never prints transcript content — transcripts sit unencrypted on disk and contain whatever passed through a tool.
---

# Spend — read the transcript, then cut the thing that costs the most

Token spend feels like it tracks how much work you did. It doesn't. It tracks how much *context*
was in front of the model, multiplied by how many times the model looked at it — and that second
factor is invisible while you work. A 50K-token context costs 50K once and then roughly 5K again
on every single turn afterward, forever, whether or not any of it is still relevant. Which means
the expensive decision is almost never the long answer you just read. It's the file you loaded
forty turns ago and never needed again.

The trap this skill exists to avoid is the dashboard: a total, a chart, four percentages, nothing
you'd act on. `/usage` already gives you a good dashboard. This skill's job is different and
narrower — find the two or three *specific* things in this session that cost the most, name what
you'd change, and put a number on what the change saves.

## Check the built-ins first — say plainly when one of them already answers it

Claude Code ships four surfaces that overlap this skill. Running it without checking them wastes
the user's time and your credibility. Confirm what's actually in the current version rather than
trusting this list:

| Surface | What it gives you | Where it stops |
|---|---|---|
| `/usage` (`/cost` is an alias) | Session totals by model; on a plan, recent usage attributed to skills, subagents, plugins and MCP servers, plus behavior flags at ≥10% | Percentages, rolled up across sessions on this machine, approximate. Tells you *that* a skill was 40%, not *which call* or *what to change* |
| `/context` | Live map of what's occupying the window right now, with optimization hints | A snapshot of the present. Can't see the cache miss forty turns back, or what a turn cost |
| `/insights` | HTML report on working patterns across recent sessions | About friction, not tokens. **Not available in cloud sessions** |
| `ccusage` (third party, npm) | Per-day/session/model accounting from the same JSONL | Accounting, not diagnosis. Answers "what did I spend", not "what should I change" |

**If `/usage`'s attribution or `/context`'s hints already name the problem, say so and stop.** A
one-line "run `/context`, your MCP tools are 30% of the window" is a better answer than a report
that re-derives it. Reach for this skill when the question is *why* and *what changes* — which
turn, which call, how much would trimming it actually save.

## The evidence, and the three traps in it

Everything comes from the session transcript at
`~/.claude/projects/<project>/<session>.jsonl` (`CLAUDE_CONFIG_DIR` moves it). Run the bundled
collector rather than parsing it yourself:

```
.claude/skills/spend/collect-token-evidence.py            # this session
.claude/skills/spend/collect-token-evidence.py --list     # pick another
.claude/skills/spend/collect-token-evidence.py --all --days 7
```

Python 3, stdlib only, mutates nothing. Read its header before hand-rolling any of this — three
properties of the format will silently corrupt the numbers, and none of them announce themselves:

- **One API response is written as several transcript lines**, each carrying the *same* `usage`
  object. Summing usage across `type == "assistant"` lines double-counts. Measured on the session
  that built this skill: **2.44×**. Dedupe on `message.id`.
- **Cache reads are most of the volume and are ~10× cheaper per token**, while cache writes are
  1.25× (5-minute TTL) or 2× (1-hour) *more* expensive than fresh input. A raw token total blends
  three prices into one number that means nothing — and since reads dominate the count, that
  number is dominated by its cheapest component.
- **Subagent transcripts live in `<session>/subagents/`**, and tool output too large for context
  is spilled to `<session>/tool-results/` with only a preview inlined. Read only the main file and
  a delegating session looks far cheaper than it was; measure the spill files and you count tokens
  that never reached context.

Transcripts are deleted after `cleanupPeriodDays` (default 30), so there's a horizon on history.
If nothing is on disk — fresh clone, different machine than the work happened on — say so and stop
rather than reporting on an empty set.

## Units: weighted tokens, not dollars

The collector reports **weighted input-token equivalents (wu)** — one unit is one fresh input
token — using `input ×1`, `cache write ×1.25` (5m) or `×2` (1h), `cache read ×0.1`, `output ×5`.
Three reasons not to print dollars:

1. **On a subscription, dollars aren't what you spend.** Usage draws on a plan allowance; Claude
   Code's own docs say the session dollar figure isn't relevant for billing for subscribers.
2. **List prices drift on known dates.** Sonnet 5 has run a promotional rate that reverts on
   2026-08-31. A skill that hardcodes dollars is wrong on a date you could look up.
3. **The ratios are the explanation.** The dollar figure just rescales them, and rescaling by a
   constant never changes which line item to cut.

Output is `×5` on every current Claude model (Opus 5 $5/$25, Sonnet 5 $3/$15, Haiku 4.5 $1/$5,
Fable 5 $10/$50), which is why the output weight needs no per-model table. To compare *across*
models the collector applies a second multiplier indexed to Haiku 4.5. If the user wants money,
quote today's pricing page — don't compute it from a number written here.

## What the signals mean

A raw count is not a finding. The mapping is the point.

- **Startup payload** (`STARTUP`) → everything in the prompt before the user typed: system
  prompt, tool schemas, MCP tool names, the skill listing, `CLAUDE.md`. Paid once at full write
  price, then re-read at 0.1× on *every* later request. **Its true cost is size × remaining
  turns**, which is why it's usually the highest-leverage target in a long session and invisible
  in a short one. Levers: trim `CLAUDE.md` (move workflow detail into skills, which load on
  demand), disable unused MCP servers, prefer CLI tools over MCP servers where both exist.
- **Cache misses** (`CACHE MISSES`) → a request that re-wrote the entire context at write rates.
  The collector names the probable cause. **Switching models mid-session is the one people don't
  expect**: caches are model-scoped, so `/model` costs a full context rewrite. Idle gaps past the
  cache TTL do the same. **A `<synthetic>` model hop is a third, less obvious source, and it is not
  specific to one tool**: the collector logs it as a model switch (`claude-sonnet-5` → `<synthetic>`
  → `claude-sonnet-5`) because Claude Code's own client writes `<synthetic>` as `message.model` on
  any locally-generated assistant turn that never made a real API call — confirmed from the client
  source to cover several distinct cases, including a message-history repair step that fires
  whenever the reconstructed conversation ends on a turn with no assistant reply yet (which is
  exactly what an `AskUserQuestion` answer or a local slash command's output looks like at that
  point), plus subagent-completion summaries and genuine API errors (rate limit, timeout,
  context-window-exceeded). Whichever one fires, the next real request pays a full write-rate
  rewrite the same way `/model` does. Confirmed in two independent Covenant sessions: 2026-08-20,
  request #21, 130,006 tokens rewritten (260,012 wu), immediately after that turn's first
  `AskUserQuestion` call; and 2026-08-21 (session `512c543b-caf3-56a7-808d-2158e0e53b57`), request
  #83, 181,289 tokens rewritten (362,578 wu, 14.4% of that session's spend), with no
  `AskUserQuestion` call anywhere in the session — the `<synthetic>` hop landed at the same turn
  boundary as three local slash commands (`/context`, `/usage`, `/spend`) run back to back. Not a
  reason to ask fewer necessary questions or avoid local commands — a genuine stopping point stays
  a stopping point — but the cost scales with context size at the moment the hop happens, so doing
  either early in a long-running task (while context is still small) is cheap, and doing either late
  is not. Lever: choose the model before the context is large, front-load `AskUserQuestion` calls
  and batches of local slash commands when a task is expected to need them, or `/clear` first.
- **A single large jump in `CONTEXT GROWTH`** → one call that everything afterward pays interest
  on. A skill body, an unfiltered log or build output, a wide file read. Levers, in order of
  power: a `PreToolUse` hook that filters the output before it's ever seen; delegating the verbose
  step to a subagent so only the summary returns; reading narrower in the first place.
- **A long flat-then-high curve** → the session outlived its context. Everything from the earlier,
  unrelated task is still being re-read. Lever: `/clear` between unrelated tasks — it costs
  nothing, whereas `/compact` reads the whole context to summarize it.
- **Thinking share of output** → whether the effort tier matched the work. High thinking share on
  mechanical turns is the signature of an over-high default. This is `model-check`'s question, not
  this skill's — hand it off rather than re-deriving it.
- **Subagent requests** → each one starts cold and re-derives context the parent already had.
  Worth it for genuinely independent work, expensive for slices of one problem. Also `model-check`
  territory.
- **`BY SKILL`** → which skill invocations the requests were attributed to. A skill that loads a
  large body for a small question is the most common single-line finding this produces.

## Worked example — the session that built this skill

Ran against its own transcript, the collector reported: request #13 added **350,618 tokens** to
context in one call, taking the window from 84K to 434K. `attributionSkill` on that request was
`claude-api`; the skill's on-disk bundle is 1.1 MB, inlining SDK docs for eight languages. It was
invoked to check two pricing multipliers — a few hundred tokens of actual answer.

The cost wasn't the 350K. It was that every one of the six requests afterward re-read a 440K
context at 0.1×, about 44K wu each. That one call came to **72% of the session's total spend**.

Two things make this the right shape for a finding: the number is verifiable in one command, and
the fix is nameable — for a two-line lookup, fetch the pricing page directly, or send the question
to a subagent so the 350K stays in *its* context and only the answer comes back. Note also what
the finding is *not*: "don't use that skill". It was the correct skill; the docs it loaded were
accurate and the pricing facts in this file came from it. The finding is about the shape of one
call, not the value of the tool.

## What earns a place in the output

Most signals should die here. This filter is most of the skill's value.

- **A number and a lever, or it isn't a finding.** "Cache reads are 20% of spend" is a fact about
  how caching works, not something the user did. If you can't name what to do differently, drop it.
- **Cite the request index and the token count inline**, so any claim is verifiable in one command.
- **Size the fix against the session it would run in.** Trimming 2K from the startup payload saves
  ~200 wu per later turn — real over a 60-turn session, noise over a 6-turn one. Say which you're
  assuming. **A finding whose saving is under ~2% of session spend is noise; drop it.**
- **Never propose `/clear` or `/compact` mid-analysis.** Both destroy the thing being analysed,
  and `/compact` is itself a large request. Propose them as habits for *next* session.
- **Cap at three.** Rank by wu saved × confidence, and say how many weaker signals you suppressed.
  A person acts on one to three things and skims a list of ten.
- **"This session was fine" is a real result.** A short session with a small context and no cache
  misses has nothing worth cutting, and saying so is more useful than manufacturing three findings
  from it.

## The verdict

Print this in chat.

```
## Spend — session <id> · <n> requests · <wu> wu
Built-ins checked: <what /usage or /context already covers, or "not available here">

Where it went:  cache writes <x>% · cache reads <y>% · output <z>% (thinking <t>% of output)
Startup:        <n> tokens, re-read <m> times ≈ <wu> wu
Peak context:   <n> tokens at request #<i>

### 1. <the finding, one line>
Evidence:  request #<i>, <n> tokens — reproduce with: collect-token-evidence.py --session <id>
Cost:      <wu> wu (<x>% of session)
Change:    <the specific thing to do differently>
Saves:     <wu, and the session length that assumes>

### 2. …
### 3. …

Suppressed: <k> weaker signals (<short list>) — say the word.

### Not this skill's call
<effort tier, model choice, subagent fan-out → /model-check>

### Unknowns
<what you couldn't measure and why. Write "none" on purpose, never by omission.>
```

If the session is too short to support conclusions — a handful of requests, no cache misses, a
context that never grew — say **INSUFFICIENT-SESSION**, report the totals, and stop.

## Privacy — this is a hard rule, not a preference

Transcripts are **unencrypted on disk and contain whatever passed through a tool**: file contents,
command output, pasted text, and any credential a command happened to print. This skill reads them.

- **Never print transcript content.** Not message text, not tool arguments, not tool results, not
  file contents. Token counts, request indices, model IDs, tool names — nothing else. The collector
  is built to emit only those; keep it that way if you edit it.
- **Never publish the output** to an artifact, a gist, a PR comment, or an issue without the user
  explicitly asking. A spend report is about their working session.
- **`--json` is for local piping**, not for sending anywhere.

If a finding genuinely requires quoting something from the transcript to be actionable, describe
it instead — "the build output at request #9" — and let the user look.

## What this skill deliberately does not measure

- **Tokens as a productivity metric.** Token count measures verbosity, not progress. Optimizing
  for fewer tokens produces terser, worse work — the goal is removing *waste*, which is context
  the model re-read without using, not effort.
- **Anything comparing people.** Not what this is for.
- **Whether a model or effort tier was right.** That's `model-check`, before the work. This skill
  runs after and can tell it what actually happened — they're two halves of one loop, and this one
  should hand off rather than guess.
- **Real-time budget tracking.** Post-hoc only. If the user wants a live readout, point them at
  the status line's context-window display or `/usage`, not at this.

## The gate

**Free, no confirmation:** running the collector, reading transcripts, reading `CLAUDE.md`,
`.mcp.json`, settings, and skill files to size the startup payload, printing the verdict.

**Stop and ask** before editing `CLAUDE.md` or any settings file, adding or changing a hook,
disabling an MCP server, deleting transcripts, or running `/clear` or `/compact`. Every one of
those changes how future sessions behave, and some destroy the evidence.

**Spend ends in a proposal.** If the user says go, implementing it is a separate task. If the fix
should exist identically in sibling repos, propagating it is `recon`'s job.

## Cadence

After a session that felt expensive, or after one that hit a usage limit — those are the moments
the evidence is freshest and the finding is most likely to stick. Running it on every session
produces the same startup-payload finding every time and trains the reader to skim. It's worth a
second run after acting on a finding, to confirm the number actually moved.
