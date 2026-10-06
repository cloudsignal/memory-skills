# Memory Skills

Two agent skills for keeping Claude Code's file-based memory useful: one decides what gets saved, the other keeps what was saved accurate as the code changes.

| Skill | Command | What it does |
|-------|---------|--------------|
| [memory-note](skills/memory-note/) | `/memory-note` | Checks a finding against a four-line rubric (changes future behavior, not derivable from the repo, not conversation-local, survives time), checks for duplicates, then saves, updates, or skips it with a reason. |
| [memory-audit](skills/memory-audit/) | `/memory-audit` | Verifies stored memories against the current repo and proposes cleanups in batches you approve: index and frontmatter repairs, corrections backed by repo evidence, and merges or retirements with a per-item manifest. Report-only until you approve. |

`memory-note` is the write path and `memory-audit` is the maintenance path. The audit never creates memories, and the note never audits.

## Install

```bash
npx skills add cloudsignal/memory-skills
```

The skills work with any memory directory that follows Claude Code's layout: one Markdown file per memory with `name` / `description` / `metadata.type` frontmatter, indexed by a `MEMORY.md`.

## How memory-audit works

1. **Structural triage, one deterministic pass.** `scripts/memory-triage.py` checks the index size, frontmatter, broken and orphaned links, and likely duplicates, and nominates files to verify, merge, or retire from signals such as file references that no longer exist in `git ls-files`.
2. **Delta check.** Memories touched by changes on `origin/main` since the last audit are re-read against the repo.
3. **Rotation.** The longest-unvalidated memories are re-checked each run, up to a cap, so nothing goes stale unnoticed.
4. **Approve, then apply.** Nothing changes without approval. Changes are backed up first, and merges are applied one cluster at a time with a structural re-check after each.

The audit is read-only on the repository: it never runs application code or queries live systems. Claims it cannot verify are reported as unverified rather than rewritten.

## Requirements

- Python 3.9 or newer (standard library only)
- bash and git

## Tests

```bash
bash skills/memory-audit/scripts/test-memory-triage.sh
bash skills/memory-audit/scripts/test-structural-check.sh
```

CI runs both on Ubuntu and macOS with Python 3.9 and 3.12.

## License

MIT
