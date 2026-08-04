# Vibecoding Common Sense

A small starter pack of guardrails, rules, and skills for building software with AI coding
agents — Claude Code, Codex, or whatever you're using. The unknown unknowns that bite you
once, then become obvious in hindsight: an agent branching from the wrong commit and
quietly dragging someone else's unreviewed work into your PR, a status doc that says
"done" three weeks after it stopped being true, defaulting to the most expensive model for
every task because switching feels like a chore.

None of this is exotic. It's the stuff you'd tell a friend who just started letting an
agent touch their repo, if you had twenty minutes and they had one incident already behind
them. This pack exists so you don't need the incident first.

Everything here was pulled from a real production app's working setup, then stripped of
anything specific to that project. It's meant to be edited, not adopted wholesale — the
value is in having a place to write down your own rules once you learn them, not in these
exact words.

## What's inside

| File | What it does |
|---|---|
| [`CLAUDE.md.template`](CLAUDE.md.template) | Drop-in project rules: branch-safety, "check don't read" for status claims, file-safety, house-style conventions, multi-agent review. Copy to `CLAUDE.md` (and `AGENTS.md` if you also run Codex) at your repo root. |
| [`.claude/skills/model-check/`](.claude/skills/model-check/SKILL.md) | A skill that scores the task in front of you and recommends the cheapest model/effort tier that's still safe for it, instead of defaulting to the most expensive one out of habit. Includes an optional script for dispatching trivial tasks to a free local model. |
| [`.claude/skills/humanize/`](.claude/skills/humanize/SKILL.md) | A checklist skill for stripping the statistical tells of AI-generated writing out of short public copy (store listings, pinned comments, changelog notes) before you publish it. |
| [`scripts/watch-codex-review.sh`](scripts/watch-codex-review.sh) | Polls a PR for a review response (Codex or any other review-on-comment bot) so you don't have to keep re-checking it yourself. See "Waiting on a PR review" below. |

## Quickstart

1. Copy `CLAUDE.md.template` to `CLAUDE.md` at the root of your repo (and to `AGENTS.md`
   too, if you also run Codex against the same repo).
2. Copy `.claude/skills/model-check/` and `.claude/skills/humanize/` into your own
   `.claude/skills/` directory, and `scripts/watch-codex-review.sh` into your own repo (a
   top-level `scripts/` directory works, or wherever you keep repo tooling) — the copied
   `CLAUDE.md` references it by that relative path.
3. Read through what you copied and delete anything that doesn't apply. The file-safety
   section in particular has a placeholder for *your* no-touch data — fill it in with the
   real thing, don't leave it generic.
4. Paste the prompt below into a fresh session so your agent tailors the model-check skill
   to what you actually have available, instead of assuming a Claude-only setup.

### Bootstrap prompt (paste this into a new session after installing)

```
I just installed the vibecoding-common-sense starter pack. Before we do anything else,
figure out what I actually have available so model-check gives me real recommendations
instead of guessing:

1. Check whether Codex (or another second coding agent) is configured for this repo —
   look for an AGENTS.md, or just ask me directly.
2. Check whether I run a local model via Ollama — try reaching localhost:11434, or ask me.
3. Ask me to open my own model picker (e.g. /model) and tell you what tiers and effort
   levels it actually shows, since that varies by tool and changes over time.
4. Based on what you find, edit .claude/skills/model-check/SKILL.md so its tier names and
   "where a second agent fits" section match my real setup, and delete the local-model
   dispatch section entirely if I don't run one.

Then give me a one-paragraph summary of what you changed.
```

## Waiting on a PR review

If your `CLAUDE.md`'s multi-agent section has you requesting a second-opinion review on
every PR (see `CLAUDE.md.template`, "Multi-agent collaboration"), you end up needing to
check back on that PR a few minutes later to see if it responded. `scripts/watch-codex-review.sh`
does that waiting for you:

```
./scripts/watch-codex-review.sh <owner/repo> <pr-number> --trigger
```

`--trigger` posts `@codex review` for you first; drop it if you already triggered the
review yourself and just want to watch. It polls every 20 seconds (`--interval` to change
that) for up to 15 minutes (`--timeout`) and exits the moment a new review, new inline
comment, or new conversation comment from the reviewer bot shows up (including a clean
"no findings" pass, which Codex posts as a plain comment rather than a formal review),
printing a summary. If you're watching a different bot, pass its account name with
`--bot <login>` (default `chatgpt-codex-connector[bot]`, Codex's own) *and* whatever
comment actually summons it with `--trigger-comment <text>` (default `"@codex review"`,
which won't mean anything to a different bot). Needs `gh` (authenticated) and `jq`.

If you're changing this script yourself, run `scripts/test/run-tests.sh` first —
it exercises the timing/error-handling edge cases (partial failures, a persistently
broken API, a tight timeout, bot filtering) against a fake `gh` in a few seconds,
instead of you finding out about them one at a time from a real bot review that takes
minutes to respond. See `CLAUDE.md.template`, "When one spot keeps needing fixes," for
why that harness exists at all, and [`docs/review-loop-case-study.md`](docs/review-loop-case-study.md)
for the full account of the 26-round loop that rule and this harness came out of.

The script's own header comment explains the one bug worth knowing about if you write
anything similar yourself: `gh api --jq <expr>` takes a single query-string argument and
does not understand jq's own `--arg` flag, so bolting `--arg` onto a `gh api --jq` call
silently mis-parses instead of erroring clearly. Pipe into the real `jq` binary instead
whenever the filter needs a parameter.

## Why this exists

A couple of people asked, after seeing a comment about how a Claude Code skill decides
what model to reach for and when to hand something to Codex for review, whether that setup
was something they could use too. Instead of answering one comment at a time, this is that
setup, cleaned up and made generic. If you build on it, feel free to share what you added —
the best version of a "common sense pack" is one that keeps absorbing other people's
near-misses, not just the first one's.

## About

This came out of building [WordBurner](https://play.google.com/store/apps/details?id=com.loupineways.wordburner),
a speed-reading app for Android — these rules earned their keep keeping that project from
breaking every time an agent went off the rails. More at [wolfscairn.com](https://wolfscairn.com),
or find me on Reddit as [u/Wolfscairn](https://www.reddit.com/user/Wolfscairn/).

## License

MIT — see [`LICENSE`](LICENSE). Use it, fork it, strip your own project's name into it. MIT
only requires keeping the copyright and permission notice in the `LICENSE` file itself when
you redistribute a substantial portion of this repo — beyond that, no separate credit or
backlink is required (though one's always appreciated).
