#!/usr/bin/env python3
"""memory-triage.py <memory-dir> [--repo <repo-dir>] [--json]

Tier-1/1.5 triage scanner for a Claude Code file-based memory directory.
A single pass over the corpus that (a) performs the structural hygiene checks
and (b) NOMINATES consolidation candidates per file: RETIRE-CANDIDATE /
MERGE-CANDIDATE -> <parent> / VERIFY-CANDIDATE / REVIEW-CANDIDATE /
UNTRIAGEABLE / CLEAN, each with its evidence signals.

The script only nominates. The verdict (and any merge's surviving content)
stays with the judgment pass of the memory-audit skill, applied only after
user approval. Bodies are read once each; only filename-level checks
(duplicate slugs, dangling-link near-matches) are quadratic, over slugs, not
content. Exit 0 even with findings; argparse exits 2 on usage errors.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from datetime import date

INDEX_BUDGET = int(os.environ.get("MEMAUDIT_INDEX_BUDGET", 24576))
ENTRY_MAX = int(os.environ.get("MEMAUDIT_ENTRY_MAX", 200))
BODY_FLAG = int(os.environ.get("MEMAUDIT_BODY_FLAG", 8192))

# consolidation thresholds (tuned against the 2026-08-28 audit's agent verdicts)
RULE_DENSITY_LOW = 0.12    # below this a one-shot reads as narrative
MERGE_RULE_LINES_MAX = 10  # durable rule-lines small enough to fold into a parent
RETIRE_AGE_DAYS = 60       # a narrative one-shot must be at least this old
LEAF_LINES_MAX = 15        # "small old leaf" body-line ceiling
SUPPRESS_DAYS = 14         # "recently-validated" info-signal window (never suppresses)
SURVIVOR_SIZE_FLAG = 16384 # parent+child projected size worth flagging
CLUSTER_MIN = 3            # smallest name-prefix group that gets a parent
VALID_TYPES = {"user", "feedback", "project", "reference"}

ONESHOT_RE = re.compile(
    r"(shipped|deployed|hotfix|backfill|bug|broken|import|-fix(ed)?\b)", re.I)
RULE_RE = re.compile(
    r"\b(never|always|must|don'?t|do not|gotcha|footgun|beware|instead of|"
    r"watch out|only if|NOT\b)", re.I)
STATUS_RE = re.compile(
    r"\b(pending|not yet|NOT (built|implemented|deployed|shipped|pushed)|"
    r"blocked on|still (open|broken)|unfixed|not fixed|deferred|next step|"
    r"TODO|paused|dormant|on hold)\b", re.I)
REL_DATE_RE = re.compile(
    r"\b(yesterday|tomorrow|last (week|month)|next (week|month)|"
    r"\d+ (days?|weeks?|months?) ago)\b", re.I)
WIKILINK_RE = re.compile(r"\[\[([a-z0-9-]+)\]\]")
MDLINK_RE = re.compile(r"\(([a-z0-9-]+\.md)\)")
SUPERSEDES_WIKI_RE = re.compile(r"supersedes \[\[([a-z0-9-]+)\]\]", re.I)
SUPERSEDES_MD_RE = re.compile(  # the HREF is the target, never the label
    r"supersedes \[[^\]]*\]\(([a-z0-9-]+)\.md\)", re.I)
# deliberately narrow: "replaced by" in a body usually describes the FEATURE
# ("the tag link is replaced by a join table"), not the memory itself
SUPERSEDED_BY_RE = re.compile(r"\bsuperseded by\b", re.I)
PATHREF_RE = re.compile(
    r"[`\s(\[]((?:\./)?[A-Za-z0-9_.@/-]+\.(?:py|tsx?|sql|sh|ya?ml|mjs|cjs|"
    r"json|css|html|go|rs|rb|java|toml))\b")
SUBMEM_RE = re.compile(r"^##+\s*sub-memories", re.I | re.M)


def fm_and_body(text):
    """Frontmatter = lines between an exact '---' first line and the FIRST
    subsequent exact '---'/'...' line. Everything after is body — a later
    horizontal rule is body, never a delimiter. Handles CRLF."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text, False
    for j in range(1, len(lines)):
        if lines[j].strip() in ("---", "..."):
            fm = {}
            for line in lines[1:j]:
                m = re.match(r"^\s*([a-zA-Z_]+):\s*(.*)$", line)
                if m:
                    fm[m.group(1)] = m.group(2).strip().strip("\"'")
            return fm, "\n".join(lines[j + 1:]), True
    return {}, text, False  # unclosed frontmatter: treat whole text as body


def load_repo_index(repo):
    """(inventory, toplevel) for a validated repo, or (None, None). Accepts
    worktrees (.git file) via rev-parse; requires a successful ls-files."""
    if not repo:
        return None, None
    try:
        ok = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"],
                            capture_output=True, text=True, timeout=30)
        if ok.returncode != 0:
            return None, None
        toplevel = ok.stdout.strip()
        # ls-files from the RESOLVED toplevel: invoked from a subdirectory it
        # would return subdir-relative paths and misclassify everything.
        # Empty output is a VALID (zero-tracked-files) inventory, not failure.
        out = subprocess.run(["git", "-C", toplevel, "ls-files"],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            return None, None
    except (OSError, subprocess.SubprocessError):
        return None, None
    by_base = defaultdict(list)
    for p in out.stdout.splitlines():
        by_base[os.path.basename(p)].append(p)
    return by_base, toplevel


def parse_iso(d):
    try:
        return date.fromisoformat(d) if isinstance(d, str) else None
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("memory_dir")
    ap.add_argument("--repo", default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    mem = args.memory_dir.rstrip("/")
    if not os.path.isdir(mem):
        ap.error(f"not a directory: {mem}")

    structural, triage = [], []

    repo_by_base, repo_root = load_repo_index(args.repo)
    if args.repo and repo_by_base is None:
        structural.append(f"REPO-UNAVAILABLE: {args.repo} "
                          "(dead-ref analysis skipped)")

    validated = {}  # file -> date; every invalid entry is diagnosed, not dropped silently
    state_path = os.path.join(mem, ".audit-state.json")
    if os.path.exists(state_path):
        try:
            with open(state_path) as f:
                state = json.load(f)
            v = state.get("validated") if isinstance(state, dict) else None
            if isinstance(v, dict):
                for k, x in v.items():
                    dt = parse_iso(x)
                    if dt:
                        validated[k] = dt
                    else:
                        structural.append(
                            f"STATE-INVALID-ENTRY: {k} ({x!r}; mtime fallback)")
            else:
                structural.append("STATE-CORRUPT: .audit-state.json "
                                  "(validated map unusable; ages fall back to mtime)")
        except (ValueError, OSError):
            structural.append("STATE-CORRUPT: .audit-state.json (unparseable)")
    today = date.today()
    now = time.time()

    files = {}
    for fn in sorted(os.listdir(mem)):
        if not fn.endswith(".md") or fn == "MEMORY.md":
            continue
        path = os.path.join(mem, fn)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            structural.append(f"UNREADABLE: {fn}")
            triage.append({"file": fn, "verdict": "UNTRIAGEABLE",
                           "signals": ["unreadable"], "rank": (5, 0, 0)})
            continue
        fm, body, had_fm = fm_and_body(text)
        files[fn] = {"text": text, "fm": fm, "body": body, "had_fm": had_fm,
                     "size": len(text.encode()),
                     "mtime": os.path.getmtime(path)}

    idx_path = os.path.join(mem, "MEMORY.md")
    idx_text = open(idx_path).read() if os.path.exists(idx_path) else ""
    idx_lines = idx_text.splitlines()

    # ---- structural: index-level -------------------------------------------
    if not idx_text:
        structural.append("INDEX-MISSING: MEMORY.md not found")
    else:
        size = len(idx_text.encode())
        if size > INDEX_BUDGET:
            structural.append(
                f"INDEX-SIZE: MEMORY.md {size} bytes (budget {INDEX_BUDGET})")
        for n, line in enumerate(idx_lines, 1):
            if len(line) > ENTRY_MAX:
                m = MDLINK_RE.search(line)
                who = m.group(1) if m else f"line {n}"
                structural.append(f"INDEX-LONG: {who} ({len(line)} chars)")

    idx_link_counts = defaultdict(int)
    for tgt in MDLINK_RE.findall(idx_text):
        idx_link_counts[tgt] += 1
    indexed = set(idx_link_counts)
    for fn, c in sorted(idx_link_counts.items()):
        if c > 1:
            structural.append(f"INDEX-DUP: {fn} ({c} index lines)")

    slugs = {fn[:-3] for fn in files}
    squeeze = lambda s: re.sub(r"(.)\1+", r"\1", s)
    squeezed = defaultdict(list)
    for s in sorted(slugs):
        squeezed[squeeze(s)].append(s)

    def near(slug):
        cands = [s for s in squeezed.get(squeeze(slug), []) if s != slug]
        if not cands:
            cands = [s for s in sorted(slugs)
                     if s != slug and (slug in s or s in slug)]
        return cands[0] if cands else None

    for fn in sorted(indexed):
        if fn not in files:
            n = near(fn[:-3])
            structural.append(f"INDEX-ORPHAN-NEARMATCH: {fn} (~ {n}.md)"
                              if n else f"INDEX-ORPHAN: {fn}")

    # reachability + inbound: index links, [[wikilinks]], (x.md) body links
    inbound = defaultdict(int)
    reachable = set(indexed)
    superseded_targets = set()
    for fn, d in files.items():
        for tgt in WIKILINK_RE.findall(d["body"]):
            t = tgt + ".md"
            if t != fn:
                inbound[t] += 1
                reachable.add(t)
        for tgt in MDLINK_RE.findall(d["body"]):
            if tgt != fn:
                inbound[tgt] += 1
                reachable.add(tgt)
        for tgt in SUPERSEDES_WIKI_RE.findall(d["body"]):
            superseded_targets.add(tgt + ".md")
        for tgt in SUPERSEDES_MD_RE.findall(d["body"]):
            superseded_targets.add(tgt + ".md")
        if SUPERSEDED_BY_RE.search(d["body"]):
            superseded_targets.add(fn)
    for fn in indexed:
        inbound[fn] += 1
    FULL_MDLINK_RE = re.compile(r"\[([^\]]*)\]\(([a-z0-9-]+\.md)\)")
    for line in idx_lines:  # one pass, precomputed (not per-file)
        for m in SUPERSEDES_WIKI_RE.finditer(line):
            superseded_targets.add(m.group(1) + ".md")
        for m in SUPERSEDES_MD_RE.finditer(line):
            superseded_targets.add(m.group(1) + ".md")
        # a SUPERSEDED marker binds to ITS link only (in the label, or in the
        # trailing text before the next link) — never to siblings on the line.
        # \bSUPERSEDED\b will not match the active form "supersedes".
        for m in FULL_MDLINK_RE.finditer(line):
            nxt = line.find("[", m.end())
            trailing = line[m.end():nxt if nxt != -1 else len(line)]
            if re.search(r"\bSUPERSEDED\b", m.group(1)) \
                    or re.search(r"\bSUPERSEDED\b", trailing):
                superseded_targets.add(m.group(2))

    # ---- structural: per-file ----------------------------------------------
    for fn, d in files.items():
        fm = d["fm"]
        fm_ok = True
        for key in ("name", "description", "type"):
            if not fm.get(key):
                structural.append(f"FM-MISSING: {fn} ({key})")
                fm_ok = False
        if fm.get("type") and fm["type"] not in VALID_TYPES:
            structural.append(f"FM-BAD-TYPE: {fn} (type: {fm['type']})")
            fm_ok = False
        if fm.get("name") and fm["name"] != fn[:-3]:
            structural.append(f"FM-NAME-MISMATCH: {fn} (name: {fm['name']})")
        if d["size"] > BODY_FLAG:
            structural.append(f"OVERSIZED: {fn} ({d['size']} bytes)")
        if fn not in reachable:
            structural.append(f"ORPHAN: {fn} (not in index, no inbound link)")
        elif fn not in indexed:
            structural.append(f"SUB-ONLY: {fn} (reachable via parent, not indexed)")
        m = REL_DATE_RE.search(d["body"])
        if m:
            structural.append(f"REL-DATE: {fn} ({m.group(1)})")
        for tgt in WIKILINK_RE.findall(d["body"]):
            if tgt + ".md" not in files:
                n = near(tgt)
                structural.append(f"LINK-TYPO: {fn} [[{tgt}]] (~ {n}.md)"
                                  if n else f"LINK-DANGLING: {fn} [[{tgt}]]")
        for tgt in set(MDLINK_RE.findall(d["body"])):
            if tgt not in files:  # plain markdown links dangle too (Sub-memories)
                n = near(tgt[:-3])
                structural.append(f"LINK-TYPO-MD: {fn} ({tgt}) (~ {n}.md)"
                                  if n else f"LINK-DANGLING-MD: {fn} ({tgt})")
        d["fm_ok"] = fm_ok

    # duplicate detection = repeated-char squeeze + whole-slug containment.
    # The old scanner's 3-token-overlap heuristic is DELIBERATELY not ported:
    # on this corpus's long compound slugs it flags topical siblings, and real
    # duplicates surface through squeeze/containment or the triage clusters.
    for group in squeezed.values():
        if len(group) > 1:
            structural.append(f"DUP-CANDIDATE: {group[0]}.md ~ {group[1]}.md")
    seen_pairs = {tuple(sorted(g[:2])) for g in squeezed.values() if len(g) > 1}
    for s1 in sorted(slugs):  # slug containment (filename-level only)
        for s2 in sorted(slugs):
            if s1 < s2 and (s1 in s2 or s2 in s1) \
                    and (s1, s2) not in seen_pairs:
                structural.append(f"DUP-CANDIDATE: {s1}.md ~ {s2}.md")
                seen_pairs.add((s1, s2))

    # ---- triage: cluster parents -------------------------------------------
    # A parent is trustworthy when it declares "## Sub-memories" for its
    # first-token group, or shares a 2-token prefix; a bare first-token group
    # qualifies only when the token is specific (not a generic short prefix).
    tok1 = defaultdict(list)
    tok2 = defaultdict(list)
    for fn in files:
        parts = fn[:-3].split("-")
        tok1[parts[0].rstrip("s")].append(fn)
        if len(parts) >= 2:
            tok2[(parts[0].rstrip("s"), parts[1])].append(fn)

    def pick(pool, exclude):
        # a survivor must itself be triageable (valid frontmatter, a body,
        # reachable) and not superseded — a retiring file cannot absorb others
        pool = [m for m in pool if m != exclude and m in reachable
                and m not in superseded_targets
                and files[m].get("fm_ok") and files[m]["body"].strip()]
        if not pool:
            return None
        return max(pool, key=lambda m: (inbound.get(m, 0), files[m]["size"]))

    GENERIC_TOKENS = {"ai", "web", "pwa", "e2e", "co", "org", "app", "api"}
    parent_of = {}
    for key, members in tok2.items():  # precise 2-token groups bind first
        if len(members) < CLUSTER_MIN:
            continue
        for m in members:
            p = pick(members, m)
            if p:
                parent_of[m] = p
    for tok, members in tok1.items():
        if len(members) < CLUSTER_MIN:
            continue
        subholders = [m for m in members if SUBMEM_RE.search(files[m]["body"])]
        pool = subholders
        if not pool and len(tok) >= 4 and tok not in GENERIC_TOKENS:
            pool = members
        for m in members:
            if m not in parent_of:
                p = pick(pool, m)
                if p:
                    parent_of[m] = p

    # ---- triage: signals + nomination --------------------------------------
    for fn, d in files.items():
        body_lines = [ln for ln in d["body"].splitlines() if ln.strip()]
        if not body_lines or not d.get("fm_ok", False):
            triage.append({"file": fn, "verdict": "UNTRIAGEABLE",
                           "signals": ["empty-body" if not body_lines
                                       else "invalid-frontmatter"],
                           "rank": (5, 0, 0)})
            continue
        rule_lines = [ln for ln in body_lines if RULE_RE.search(ln)]
        density = len(rule_lines) / len(body_lines)
        oneshot = bool(ONESHOT_RE.search(fn))
        superseded = fn in superseded_targets \
            or bool(SUPERSEDED_BY_RE.search(d["body"]))
        status_hot = bool(STATUS_RE.search(d["body"]))
        vdate = validated.get(fn)
        if vdate:
            age = (today - vdate).days
        else:
            age = int((now - d["mtime"]) / 86400)  # never validated: file age
        mdate = date.fromtimestamp(d["mtime"])
        # informational only (a repo-side change can invalidate a memory the
        # day after validation, so this never suppresses a nomination); a
        # future-dated validation is corrupt, never "recent"
        recently_validated = vdate is not None \
            and 0 <= (today - vdate).days <= SUPPRESS_DAYS and mdate <= vdate

        dead, moved, untracked = [], [], []
        if repo_by_base is not None:
            seen = set()
            for ref in PATHREF_RE.findall(d["body"]):
                ref = ref.lstrip("`([")
                if ref.startswith("./"):
                    ref = ref[2:]
                if "://" in ref or "*" in ref or "<" in ref or ref in seen:
                    continue
                seen.add(ref)
                if ref.startswith("/") or ".." in ref.split("/"):
                    continue  # absolute or repo-escaping path: not evidence
                if "/" not in ref and not ref.endswith((".yml", ".yaml", ".sql")):
                    continue  # bare non-workflow/migration basenames: too noisy
                cands = repo_by_base.get(os.path.basename(ref))
                if cands:
                    if not any(p == ref or p.endswith("/" + ref) for p in cands):
                        moved.append(ref)
                elif os.path.exists(os.path.join(repo_root, ref)):
                    untracked.append(ref)
                else:
                    dead.append(ref)

        signals = []
        if oneshot:
            signals.append("oneshot")
        if superseded:
            signals.append("superseded")
        if status_hot:
            signals.append("status-words")
        signals.append(f"rules={len(rule_lines)}/{len(body_lines)}")
        signals.append(f"age={age}d" + ("" if vdate else "*"))
        signals.append(f"in={inbound.get(fn, 0)}")
        if dead:
            signals.append(f"dead={len(dead)}:" + ",".join(dead[:3]))
        if moved:
            signals.append(f"moved={len(moved)}")
        if untracked:
            signals.append(f"untracked={len(untracked)}")
        parent = parent_of.get(fn)
        if recently_validated:
            signals.append("recently-validated")

        # nomination (ordered; status-words qualify, they never veto;
        # an unknown/None age can never satisfy an age threshold)
        review_eligible = len(body_lines) <= LEAF_LINES_MAX \
            and age >= RETIRE_AGE_DAYS and inbound.get(fn, 0) <= 2 \
            and d["fm"].get("type") == "project"
        tiny_leaf = len(body_lines) <= 6 and parent \
            and not SUBMEM_RE.search(d["body"])  # a parent is never a leaf
        if superseded:
            verdict = "RETIRE-CANDIDATE"
        elif oneshot and density < RULE_DENSITY_LOW and age >= RETIRE_AGE_DAYS:
            verdict = "RETIRE-CANDIDATE"
        elif (oneshot or tiny_leaf) and parent \
                and len(rule_lines) <= MERGE_RULE_LINES_MAX:
            verdict = f"MERGE-CANDIDATE -> {parent}"
        elif dead or moved or (status_hot and age >= 30):
            verdict = "VERIFY-CANDIDATE"
        elif review_eligible:
            # small old barely-linked leaf: frontmatter overhead likely
            # outweighs the content — fold it somewhere or keep deliberately
            verdict = "REVIEW-CANDIDATE (small-old-leaf)"
        else:
            verdict = "CLEAN"
        if verdict != "CLEAN" and status_hot:
            signals.append("verify-status")
        # non-merge fallback: what this file is if it loses its nomination —
        # the full post-merge decision chain (VERIFY → REVIEW → CLEAN), so a
        # demoted survivor keeps its evidence instead of turning CLEAN
        if dead or moved or (status_hot and age >= 30):
            fallback = "VERIFY-CANDIDATE"
        elif review_eligible:
            fallback = "REVIEW-CANDIDATE (small-old-leaf)"
        else:
            fallback = "CLEAN"

        triage.append({"file": fn, "verdict": verdict, "signals": signals,
                       "fallback": fallback,
                       "dead": dead, "moved": moved, "parent": parent,
                       "rank": (0 if verdict.startswith("RETIRE")
                                else 1 if verdict.startswith("MERGE")
                                else 2 if verdict.startswith("VERIFY")
                                else 3 if verdict.startswith("REVIEW")
                                else 4 if verdict == "CLEAN" else 5,
                                -len(dead), -age)})

    # merge-graph normalization: a survivor is never also a source, so the
    # graph stays acyclic and `sources ∩ survivors = ∅` holds by construction.
    # Iterate to a fixpoint; in a reciprocal pair the higher-(inbound, size)
    # file wins survivor-hood and its own merge nomination is demoted.
    entries = {t["file"]: t for t in triage}
    while True:
        survivors = {t["parent"] for t in triage
                     if t["verdict"].startswith("MERGE-CANDIDATE")}
        conflicted = [entries[s] for s in survivors
                      if s in entries
                      and entries[s]["verdict"].startswith("MERGE-CANDIDATE")]
        if not conflicted:
            break
        # demote the strongest conflicted survivor first, then re-derive
        t = max(conflicted, key=lambda t: (inbound.get(t["file"], 0),
                                           files[t["file"]]["size"]))
        t["verdict"] = t.get("fallback", "CLEAN")
        t["signals"].append("kept-as-survivor")
        t["rank"] = (2 if t["verdict"].startswith("VERIFY")
                     else 3 if t["verdict"].startswith("REVIEW") else 4,
                     -len(t.get("dead", [])), t["rank"][2])
    for s in survivors:  # a retiring survivor is a contradiction — surface it
        if s in entries and entries[s]["verdict"] == "RETIRE-CANDIDATE":
            entries[s]["signals"].append("CONFLICT:merge-target")

    # accumulated survivor size: parent + ALL nominated children, not one pair
    by_parent = defaultdict(list)
    for t in triage:
        if t["verdict"].startswith("MERGE-CANDIDATE") and t.get("parent"):
            by_parent[t["parent"]].append(t)
    for parent, kids in by_parent.items():
        total = files[parent]["size"] + sum(files[k["file"]]["size"]
                                            for k in kids)
        if total > SURVIVOR_SIZE_FLAG:
            for k in kids:
                k["signals"].append(f"size!({total // 1024}KB projected)")

    triage.sort(key=lambda t: (t["rank"], t["file"]))

    if args.json:
        for t in triage:
            t.pop("rank")
        print(json.dumps({"structural": structural, "triage": triage},
                         indent=1))
        return

    print("== STRUCTURAL ==")
    for line in structural:
        print(line)
    print(f"STRUCTURAL-TOTAL: {len(structural)}")
    print("\n== TRIAGE (nominations only — verdicts need the judgment pass) ==")
    counts = defaultdict(int)
    for t in triage:
        counts[t["verdict"].split("-CANDIDATE")[0].split(" ")[0]] += 1
        print(f"{t['verdict']}: {t['file']} | " + " ".join(t["signals"]))
    print(f"\nTRIAGE-TOTAL: retire={counts['RETIRE']} merge={counts['MERGE']} "
          f"verify={counts['VERIFY']} review={counts['REVIEW']} "
          f"untriageable={counts['UNTRIAGEABLE']} clean={counts['CLEAN']} "
          f"(* = never validated; age from mtime)")


if __name__ == "__main__":
    main()
