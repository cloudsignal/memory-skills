---
name: memory-audit
description: Use when the user invokes /memory-audit, asks to audit, validate, clean, or optimize the project's stored memories, or when weekly memory maintenance is due - stale memory files, MEMORY.md index over its load limit, memories contradicting current code or specs
---

# Memory Audit

Maintenance counterpart to `memory-note` (the write path). Verify the session's file-based memory against the current repo; propose cleanups. **Report-only: apply nothing without explicit approval in this session.**

## 0. Resolve + state

- Target = the memory directory named in this session's Memory section. None → say so, stop.
- Report header: the directory path, days since last audit (flag if > 10), mode.
- Load `<memory-dir>/.audit-state.json`:

      { "last_run": "YYYY-MM-DD",
        "validated": { "<file>.md": "YYYY-MM-DD" },
        "declined":  [ { "key": "<action>:<file>:<claim-slug>", "date": "YYYY-MM-DD" } ] }

- Missing = first run: no Tier-2 window; every file counts as never-validated; prioritize `project`-type. Corrupted: regenerate, say so. Prune on load: `validated` entries whose file is gone; `declined` entries older than 90 days or whose file is gone.
- Arg `full`: ignore `last_run` and the ledger, deep-check everything, no cap.

## 1. Tier 1 — structural + triage (deterministic, one pass)

Run `python3 <skill-dir>/scripts/memory-triage.py "<memory-dir>" --repo "<repo-dir>"`, where `<skill-dir>` is this skill's directory (`~/.claude/skills/memory-audit` when installed globally) (single pass over bodies, sub-second on hundreds of files — only filename-level checks are quadratic; supersedes the old `structural-check.sh`; fixture tests: `scripts/test-memory-triage.sh`) — never read all bodies for hygiene. It emits two sections.

**STRUCTURAL** findings, judgment as before:

- `INDEX-SIZE`/`INDEX-LONG` → ONE batch-A finding: a rewritten `MEMORY.md` (entries one line ≤ 200 chars, keep newest-first order; show before/after bytes + 3 sample lines). If trimming can't reach budget, escalate: "corpus needs consolidation, not trimming".
- `FM-*` → per-file repair; derive a missing description from the body; preserve unknown frontmatter keys (`node_type`, `originSessionId` are harness provenance).
- `INDEX-ORPHAN-NEARMATCH` → retarget the line; `INDEX-ORPHAN` → drop the line; `ORPHAN` (unreachable from index AND from any link) → add an index line or a parent link (indexing, not creating). `SUB-ONLY` (reachable via a parent's link, not indexed) → fine by design, no action.
- `LINK-TYPO` → fix. `LINK-DANGLING`, `OVERSIZED` → informational only (dangling forward-refs are allowed by design; suggest narrative→rules compression).
- `DUP-CANDIDATE` → judge; real duplicates become batch-C merge proposals.

**TRIAGE** nominations — the script's consolidation shortlist. These are *nominations from deterministic signals* (dead file refs vs `git ls-files`, one-shot naming, rule-line density, supersession markers, name-prefix cluster parent, inbound links, validated age), never verdicts:

- `RETIRE-CANDIDATE` / `MERGE-CANDIDATE -> <parent>` → read the file, apply the memory-note rubric ("derivable from the repo?"), confirm or demote; confirmed ones become batch C. The suggested parent is prefix-derived — override it when a better thematic parent exists.
- `VERIFY-CANDIDATE` (dead refs or aged status words) → these are the priority pool for the Tier 2/3 deep-check cap, ranked as printed.
- `REVIEW-CANDIDATE (small-old-leaf)` → tiny old barely-linked file: fold it somewhere or keep it deliberately.
- `CLEAN` → skip; Tier 3 rotation remains the backstop for what the signals can't see (semantic supersession with no textual marker).

## 2. Tier 2 — delta (skip without a git repo)

- `git fetch origin -q`; `boundary=$(git rev-list -1 --before="<last_run>T00:00" origin/main)`; `git diff --name-only "$boundary"..origin/main`. Diff against `origin/main` (landed truth; the session may sit in a worktree). Also read a chronological change log if the repo keeps one (e.g. `docs/superpowers/REVISIONS.md`). Never iterate commit-by-commit.
- Map changed paths/specs → memories by grepping memory names/descriptions/bodies. Best-effort; Tier 3 backstops misses.
- Deep-check implicated memories (full read): named files/functions/flags/migrations still exist (grep the repo); status words ("pending", "NOT deployed", "unfixed", "next", "deferred") against newer evidence (newer memories, change log, specs); cross-memory contradictions.
- **Read-only on the repo: never run app code, hit prod, or query live databases.** External claims (deploy state, live-DB facts): supersession check only; otherwise report "unverified" and leave untouched.
- Flag only claims that would change future behavior if wrong. Historical narrative ("the trigger was…", old paths) is context — never "fix" it.

## 3. Tier 3 — rotation

- Deep-check the 10 longest-unvalidated memories (absent from `validated` = oldest). Combined Tier 2+3 cap: 20 per normal run, split so no pool starves: ~8 slots for `VERIFY-CANDIDATE`s in printed rank, ~6 for unconfirmed retire/merge nominations, ~6 for plain rotation (oldest-unvalidated regardless of nomination). The script's `recently-validated` signal is informational only (it never suppresses a nomination — a repo-side change can invalidate a memory the day after validation); use it plus the declined ledger to deprioritize, so a nomination that persists across runs does not monopolize the cap. Overflow prioritized (`project`-type > most-referenced > oldest) and reported as "deferred N deep checks" — never silently skipped.
- May fan out read-only Explore subagents; their prompts MUST state: read-only, never edit, never commit, never push.

## 4. Report → approve → apply

- Batches: **A** index/structural (bulk index rewrite = one finding) · **B** content corrections, repo evidence quoted · **C** merges/deletions, each citing the memory-note rubric line it fails. Then: validated clean N · deferred N · suppressed N (ledger hits) · informational lists.
- **Batch C requires a per-item manifest before approval** — aggregate counts are not approvable. For every merge/retire: source file → survivor (or "delete"), the exact durable lines that will be carried over (verbatim or a tight paraphrase), the evidence the rest is repo-derivable or superseded, and the inbound links to rewrite — **both `[[wikilinks]]` AND plain `(file.md)` markdown links** (parents' `## Sub-memories` lists use the markdown form; deleting a child without rewriting them leaves silent dangles). Write the manifest to a file, give each action an id (C1, C2…), and let approval reference ids ("C except C7"). **The manifest must form a consistent graph**: one final survivor per cluster, `sources ∩ survivors = ∅`, no survivor that is itself retired, no reciprocal or chained deletions. The script normalizes merge cycles itself (`kept-as-survivor`, preserving the file's full fallback verdict — VERIFY or REVIEW, never forced CLEAN) but only FLAGS a retiring merge target (`CONFLICT:merge-target`) — resolving that contradiction is judgment work, and a manifest violating the graph invariant is not approvable. **Every final survivor must have been judgment-read in the current run with no unresolved VERIFY/REVIEW/UNTRIAGEABLE/CONFLICT state** — a REVIEW survivor is resolved by recording "keep as final survivor" plus the reason in its manifest entry; folding content into an unverified survivor is forbidden. Applying a C action whose manifest entry the user has not seen is forbidden.
- Zero findings → write state, report "all clean", stop — no approval question. Otherwise ONE AskUserQuestion (multiSelect over A/B/C); honor free-text partial approvals ("C except C3").
- Apply approved batches only:
  1. Backup first: `cp -R <memory-dir> <parent>/memory-backups/<YYYY-MM-DD-HHMMSS>/` (timestamped — same-day reruns must not collide; sibling of the memory dir, never inside it); keep newest 3, prune older after success. No backup if nothing approved. **A batch C with deletions additionally gets a permanent snapshot**: copy to `<parent>/memory-backups/pre-consolidation-<YYYY-MM-DD-HHMMSS>/` — excluded from the rolling prune, kept until the user deletes it — and **verify it before deleting anything**: file count and total bytes of the snapshot must equal the memory dir's; a mismatch aborts the batch.
  2. mtime guard: a target file changed since it was read (another session wrote it) → drop that finding with a note; it re-audits next run.
  3. Order **C → B → A**: merge = fold unique facts into the survivor, fix inbound links across memories in BOTH forms (`[[wikilinks]]` and plain `(file.md)` markdown links, including `## Sub-memories` lists), delete the loser and its index line; B skips files deleted in C; index last, reflecting the final file set. **Apply C in chunks** (one cluster/parent at a time), re-running the triage script's structural section after each chunk; a new ORPHAN/LINK-DANGLING after a chunk means stop and repair before the next chunk — never leave a mixed corpus.
  4. Re-measure `MEMORY.md` ≤ 24,576 bytes; still over → escalate in the summary.
  5. Write state: `last_run` = today; `validated[<file>]` = today for every deep-checked file (Tiers 2/3, including declined — Tier-1-only files get no validated date); append declined finding keys.
  6. Summarize: applied / dropped-by-guard / declined.

## Rails

- Correct with evidence, never embellish; unverifiable claims are reported, not rewritten.
- Never create new memories (merge survivors excepted) — that is `memory-note`'s job; never invoke it.
- Clean validations touch nothing: no mtime churn, validation dates live only in the state file.

## Red flags — stop if you catch yourself

Reading every memory file for hygiene · applying anything before approval · rewriting a claim without repo evidence · "verifying" a deploy/DB claim against a live system · re-proposing a finding the declined ledger suppresses · treating a triage NOMINATION as a verdict (retire/merge always needs the judgment read + approval).

## Defaults

overdue > 10 days · index ≤ 24,576 bytes · entry ≤ 200 chars, one line · deep-check cap 20 · rotation slice 10 · oversized flag > 8 KB · declined expiry 90 days · backups kept 3
