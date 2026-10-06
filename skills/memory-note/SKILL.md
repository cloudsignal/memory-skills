---
name: memory-note
description: Use when the user invokes /memory-note, asks whether a finding or session takeaway should be saved to memory, or wants session learnings reviewed for what is worth remembering
---

# Memory Note

Evaluate finding(s) against the memory rubric, advise save/update/skip with reasons, then do it.

## Input

The finding is the skill argument. If no argument: scan THIS conversation for candidates (corrections received, user directives, decisions made, gotchas hit, rejected approaches) and evaluate each. If the conversation has no clear candidates, ask the user for the finding (one question).

## Decision rubric

Advise SAVE only if ALL hold; otherwise SKIP and say which line failed:

1. **Changes future behavior.** A future session would act differently knowing this. "Interesting" is not enough.
2. **Not derivable from the repo.** Code structure, past fixes, git history, CLAUDE.md, specs, and `docs/superpowers/REVISIONS.md` already persist. If the user asks to remember one of those anyway, ask what was non-obvious about it and save that instead.
3. **Not conversation-local.** Matters beyond the current task.
4. **Survives time.** Convert relative dates to absolute. If it names a file/function/flag, verify it exists before writing.

Pick the type: `user` (who they are) · `feedback` (how to work, incl. corrections; must include why) · `project` (status, constraints, goals) · `reference` (URLs, dashboards, tickets).

## Before writing — duplicate check (mandatory)

Read `MEMORY.md` in the memory directory and grep the directory for the topic.
- Same fact or same failure mode → UPDATE that file, never create a sibling.
- Same vendor/domain but a DIFFERENT failure mode or rule → new file, cross-linked with `[[name]]` both ways.
- Contradiction → fix or delete the stale memory and tell the user.

## Writing

- One file per fact in the memory directory, with `name` / `description` / `metadata.type` frontmatter.
- `feedback`/`project` bodies include `**Why:**` and `**How to apply:**` lines.
- Link related memories with `[[name]]`.
- Add ONE pointer line to `MEMORY.md` (`- [Title](file.md) — hook`). The index never holds content.
- Save the reusable rule, not the story. "Never `git add -A` in this repo's worktrees (untracked junk)" beats "on June 12 an agent committed .turbo by accident".

## Report

Per finding: **SAVE** (type, filename) / **UPDATE** (which file, what changed) / **SKIP** (which rubric line failed). Execute the saves/updates, then summarize what changed.

## Common mistakes

- Saving what CLAUDE.md or the repo already records (rubric 2).
- A new file when an existing memory covers the topic — update instead.
- Narrative instead of rule; missing Why/How-to-apply on feedback.
- Relative dates ("yesterday", "last week") written into the body.
