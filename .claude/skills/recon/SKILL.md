---
name: recon
description: Copy a skill, hook, or tool from this repo into one or more sibling repos (Covenant, vibecoding-common-sense) and register it in docs/parity-manifest.json plus the cross-repo-parity workflow's trigger paths, so future drift gets caught by CI instead of going unnoticed the way model-check once did. Use when the user says "/recon", "share this skill with Covenant", "copy this across repos", "keep this in sync with the sibling repos", or wants a skill/file to propagate with drift monitoring. Does not apply to a deliberately-adapted port (different content per repo on purpose, like skill-observer) — see "Byte-identical vs adapted" below before using this on those.
---

# Recon — cross-repo skill/tool propagation with parity tracking

This repo already has a working cross-repo parity system: `docs/parity-manifest.json` lists,
per sibling repo, which paths must stay byte-identical (content, CRLF-normalized, and git file
mode); `tools/parity-check.mjs` does the comparison; `.github/workflows/cross-repo-parity.yml`
runs it on PRs touching a listed path, on a weekly schedule, and on manual dispatch. This skill
exists because that system only catches drift in things it already knows about — getting a new
shared file registered correctly, in both directions, with the workflow trigger updated too, is
exactly the kind of multi-step bookkeeping that's easy to half-do by hand (which is how
model-check drifted silently between Word_Burner and Covenant in the first place, per the
manifest's own note). Read `docs/parity-manifest.json`'s `note` field and
`tools/parity-check.mjs`'s header comment before running this the first time in a session; they
carry the authoritative detail this file summarizes.

## Byte-identical vs adapted — ask before doing anything

Two genuinely different things get called "copy this skill to another repo":

- **Byte-identical share** (what this skill is for): the same file, same content, in both
  repos, meant to stay that way. `model-check` and `humanize` between Word_Burner and Covenant
  are the existing examples. Parity-tracking is the right tool.
- **Adapted port** (not what this skill is for): the idea is copied but the content is
  deliberately different per repo, because the target repo has different context (different
  skill names to reference, different scale, different audience). `skill-observer` is the
  existing example: WordBurner's, Covenant's, and vibecoding-common-sense's copies all differ on
  purpose and are not meant to be forced back into sync. Registering an adapted port in the
  parity manifest would make CI fail forever on a difference that's supposed to exist.

**One part of an adapted port must still match across copies: upstream attribution.** If the
ported idea came from someone else's licensed work, the credit block — author, license, a link
to the license text, and the indication that you changed it — reads the same everywhere,
because that's a license term rather than a house-style choice. `skill-observer` is again the
example: all three copies carry the same CC BY 4.0 paragraph crediting `task-observer`, even
though the prose around it is deliberately different per repo. Nothing enforces this, since an
adapted port is out of the parity manifest by definition, so when you touch one copy's
attribution, update the others in the same pass. Word_Burner's and Covenant's drifted until
2026-08-06 (a bare link naming neither author nor license) and only a manual read caught it.

If it's not obvious which one the user means, ask. Don't guess and don't default to
parity-tracking just because copying is involved.

## Known repos

Local checkouts as of this writing (confirm with `ls`/`git remote -v` if a path seems off,
paths and sibling sets do change):

| Repo | Local path | GitHub slug | Has its own manifest + workflow? |
|---|---|---|---|
| Word_Burner | `C:\Word_Burner` | `LouPineWays/Word_Burner` | Yes |
| Covenant | `C:\Covenant` | `LouPineWays/Covenant` | Yes |
| vibecoding-common-sense | `C:\vibecoding-common-sense` | `LouPineWays/vibecoding-common-sense` | No — it's the leaf starter-pack repo; Word_Burner and Covenant check against it, it doesn't check back |

If the user names a repo not in this table, ask for its local path and GitHub slug rather than
guessing.

## Procedure (byte-identical share)

1. **Identify the source.** A skill directory (`.claude/skills/<name>/`) or a specific file
   (a hook, a tool script). Confirm it exists in the repo you're currently in.

2. **Identify targets.** Ask if not given. Can be more than one.

3. **For each target repo:**
   - `git -C <target> fetch origin main`
   - `git -C <target> checkout -b recon-<skill-name> origin/main` (never branch from whatever's
     currently checked out — that repo's own CLAUDE.md has the same "always branch from
     origin/main" rule this repo does, for the same reason: a shared working directory can have
     another session's unmerged work sitting on the branch you'd otherwise inherit from)
   - Copy the file(s) verbatim. Preserve the executable bit if the source has one (`git ls-files
     -s -- <path>` shows the mode; a `100755` source must land as `100755` in the target, not
     `100644` — this is the exact failure mode `parity-check.mjs` was written to catch, so don't
     let the copy step itself reintroduce it).
   - `git -C <target> add <path>` then commit, in that repo, following its own git conventions
     (confirm branch first, never commit to main directly — same rule as this repo).

4. **Update the parity manifest — in whichever repos on either side actually carry one,
   regardless of which side originated the file.** A manifest entry always lives in the
   *checking* repo, under the sibling key naming the *other* repo in that pair — direction of
   the copy doesn't change that. Word_Burner and Covenant both carry a manifest;
   vibecoding-common-sense doesn't (it's the leaf repo — nothing ever checks outward from it,
   even on the runs where it's the one that originated the shared file, e.g. something drafted
   there first and pulled into Word_Burner or Covenant). Concretely:
   - If both sides are manifest-carrying repos (Word_Burner and Covenant), add the entry in
     *both* repos' `docs/parity-manifest.json`, each under the sibling key naming the other —
     that's what makes the check bidirectional. Create the sibling key with its `repo` slug if
     this is a new sibling.
   - If one side is vibecoding-common-sense, only the manifest-carrying side gets an entry
     (under vibecoding-common-sense's existing sibling key there). vibecoding-common-sense's own
     copy has nothing to add. This is the same whether vibecoding-common-sense supplied the file
     or received it.
   - Entry shape: `{"path": "...", "type": "file", "mode": "..."}` or `{"path": "...", "type":
     "dir"}` for a whole skill directory — `dir` entries compare every file inside recursively
     and don't need individual mode pinning unless a specific file inside needs one. File entries
     pin an explicit `mode`; dir entries (skills) generally don't. Look at the current
     `.claude/skills/model-check` and `.claude/skills/recon` entries in `docs/parity-manifest.json`
     as the template.

5. **Update the parity workflow's trigger paths — in any repo that has
   `.github/workflows/cross-repo-parity.yml` and now carries the new shared path** (currently
   Word_Burner and Covenant). Add the path to the `on.pull_request.paths` list. The sibling
   discovery in that workflow is already dynamic (reads the manifest at run time), but the PR
   trigger's path list is a literal, hand-maintained array — a manifest edit alone doesn't make
   PRs touching the new path actually trigger the check; without this, it only gets caught on
   the Monday-morning schedule or a manual run, not on the PR that introduced the drift.

6. **Commit the manifest and workflow edits** in each repo they were made in, alongside (or
   right after) the file-copy commit from step 3. They can be the same commit or a following one
   in the same branch; they should not be split across sessions, since an unregistered copy is
   exactly the silent-drift state this skill exists to prevent.

7. **Do not push or open PRs without asking first**, in every repo touched. This applies even
   though the branch, commit, and manifest work above doesn't need per-step confirmation — those
   are local and reversible; pushing and opening PRs are the actions this project's standing
   rule requires a stop for.

8. **Report a summary**: what was copied, to which repos, which manifests and workflow files
   were updated, and which branches now hold uncommitted-to-main work waiting on the user's
   go-ahead to push.

## Caveats worth surfacing when relevant

- The parity check itself needs a `SIBLING_REPO_TOKEN` secret configured in each repo that runs
  the workflow, with read access to every sibling named in its manifest. That's existing
  infrastructure this skill doesn't set up or verify — if a newly-added sibling isn't covered by
  that token's scope yet, say so, don't assume it's covered.
- The scheduled run is weekly (Monday), not daily — drift introduced entirely on a sibling's
  side (no local diff to trigger a PR check here) won't be caught until that run, or a manual
  `workflow_dispatch`.
- If the user later asks to add another sibling repo that doesn't have a manifest yet at all
  (like vibecoding-common-sense doesn't), that's a bigger step than this skill covers — it means
  standing up `tools/parity-check.mjs`, the workflow file, and a manifest from scratch in that
  repo, not just adding an entry. Flag it rather than attempting it inline.
