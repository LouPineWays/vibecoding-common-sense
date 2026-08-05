---
name: skill-observer
description: Notice and log when a skill in .claude/skills/ produces wrong or incomplete output, gets corrected, or gets manually worked around. Use whenever you are actively running one of your own skills and get corrected on its output, a documented step turns out stale or missing a case, or its instructions conflict with something CLAUDE.md now says. Not for general working-style feedback about the agent itself (that belongs in whatever memory/preferences system you use, not here). Also use when the user asks "any skill observations logged?" or wants to review the log.
---

# Skill Observer

A stripped-down, small-repo alternative to `task-observer`
(https://github.com/rebelytics/one-skill-to-rule-them-all by Eoghan Henn / rebelytics.com,
licensed CC BY 4.0). That project logs skill-improvement observations to a shared file
across large libraries of skills under heavy parallel-session load, and carries matching
machinery for that scale: numbered-append collision detection, DOTALL-safe log mutation,
multi-writer survival checks, and always-on session activation. Most repos don't operate
at that scale, so this skill leaves all of that out and keeps only the core idea: notice
when a skill's own instructions were wrong, and write it down. If your setup grows into
many skills under heavy concurrent use, the full task-observer is worth adopting instead —
this isn't a replacement for it, just a lighter on-ramp for everyone else.

Adapted under CC BY 4.0: credit to Eoghan Henn / rebelytics.com and the original repo
linked above. If you redistribute this file, keep this attribution.

**Scope boundary:** this skill is for defects in a *skill file's own instructions* —
something `.claude/skills/<name>/SKILL.md` tells the agent to do that turned out wrong,
missing, or stale. It is not for how you'd like your agent to work with you in general;
route that to whatever memory or preferences mechanism you already use, so the two don't
end up duplicating each other.

## When to log

Only while a skill is actively in use, for one of:

- You correct output that skill produced.
- A documented step in that skill turns out stale, wrong, or missing an edge case.
- The skill's instructions conflict with something `CLAUDE.md` (or your equivalent) now
  says.
- A workaround happens manually that the skill should have covered.

Don't log: one-off corrections that don't generalize, or anything already captured by
existing memory/preferences or `CLAUDE.md`.

## How to log

Append to `.claude/skills/skill-observer/log.md` (create it from the template below if
missing). Keep entries short — this is a punch list for the next time someone edits that
skill, not an audit trail.

```markdown
### [YYYY-MM-DD] — [skill name]

**Trigger:** what happened
**Suggested fix:** concrete change to that skill's SKILL.md (or reference file)
```

Log silently, in the same turn the friction happens — don't wait to be asked, and don't
just remember it for later instead of writing it down.

## Reviewing

No scheduled review and no forced end-of-session surfacing. Mention open entries when
you're already touching that skill, or whenever asked directly ("any skill observations
logged?"). When acting on an entry, edit the target skill's `SKILL.md` directly, then
remove the entry from the log (git history is the record of what changed and why — the log
only needs to hold what's still open).

## Log template

If `.claude/skills/skill-observer/log.md` doesn't exist yet, create it as:

```markdown
# Skill Observation Log

Defects and gaps noticed in this repo's own skills during real use. Scoped to skill-file
content only — see skill-observer's SKILL.md for the boundary against general memory.

---
```
