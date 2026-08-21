# Skill Observation Log

Defects and gaps noticed in this repo's own skills during real use. Scoped to skill-file
content only — see skill-observer's SKILL.md for the boundary against general memory.

---

### [2026-08-21] — spend

**Trigger:** The "Cache misses" bullet in `.claude/skills/spend/SKILL.md` named `AskUserQuestion`
as *the* source of a `claude-sonnet-5 -> <synthetic> -> claude-sonnet-5` cache-miss hop, based on
one Covenant session. A second Covenant session (`512c543b-caf3-56a7-808d-2158e0e53b57`, request
#83) hit the identical shape with no `AskUserQuestion` call anywhere in the session — the hop
landed at the same turn boundary as three local slash commands (`/context`, `/usage`, `/spend`)
run back to back. Reading Claude Code's own client source confirmed `<synthetic>` is a general
placeholder for any locally-generated assistant turn that never made a real API call (message-
history repair on a dangling user-role turn, subagent-completion summaries, interrupted-turn
resume, and genuine API errors all produce it), not something special-cased for one tool. Fixed
directly in this pass — this entry is only for the follow-up that's still open.

**Suggested fix (still open):** Covenant's copy of `.claude/skills/spend/SKILL.md` is parity-
tracked against this repo's copy per Covenant's `docs/parity-manifest.json` (whole
`.claude/skills/spend` directory, byte-identical). This session only had push access to
vibecoding-common-sense's designated branch, so vibecoding-common-sense's copy (commit `664beab`
on `claude/synthetic-model-triggers-9j1tho`) now has the generalized bullet and Covenant's does
not — a real parity drift until a companion commit lands in Covenant.
