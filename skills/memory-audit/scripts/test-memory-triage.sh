#!/usr/bin/env bash
# test-memory-triage.sh — fixture tests for memory-triage.py.
# Builds throwaway memory dirs + a throwaway git repo, asserts on findings.
set -u
SCRIPT="$(cd "$(dirname "$0")" && pwd)/memory-triage.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

expect() { # expect <label> <pattern> <file>
  if grep -qE "$2" "$3"; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (missing: $2)"; fi
}
refute() { # refute <label> <pattern> <file>
  if grep -qE "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 (unexpected: $2)";
  else PASS=$((PASS+1)); fi
}
mem() { mkdir -p "$T/$1"; }
mk() { # mk <dir> <file> <type> <body...>
  local d="$1" f="$2" ty="$3"; shift 3
  printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: %s\n---\n%s\n' \
    "${f%.md}" "$ty" "$*" > "$T/$d/$f"
}

# --- fixture 1: structural checks ------------------------------------------
mem m1
mk m1 good-memory.md project "A fact. Never do X."
mk m1 old-thing-shipped.md project "We shipped it. It went well. All done fine."
printf -- '---\nname: hr-file\ndescription: d\nmetadata:\n  type: project\n---\nkeep this line\n\n---\n\nafter the rule NEVER drop the part above\n' > "$T/m1/hr-file.md"
printf 'no frontmatter at all\n' > "$T/m1/no-fm.md"
printf -- '---\nname: bad-type\ndescription: d\nmetadata:\n  type: banana\n---\nbody\n' > "$T/m1/bad-type.md"
printf -- '---\nname: empty-body-shipped\ndescription: d\nmetadata:\n  type: project\n---\n' > "$T/m1/empty-body-shipped.md"
mk m1 rel-date.md project "done 3 days ago, more next month"
mk m1 linker.md project "see [[good-memory]] and [[gone-memory]] and [[good-memoryy]]"
cat > "$T/m1/MEMORY.md" <<'EOF'
- [Good](good-memory.md) — hook
- [Good again](good-memory.md) — duplicate line
- [Ghost](ghost-file.md) — dangling index entry
- [Old](old-thing-shipped.md) — SUPERSEDED by good
EOF
touch -t 202501010000 "$T/m1/old-thing-shipped.md"
O="$T/out1"; python3 "$SCRIPT" "$T/m1" > "$O" 2>&1 || { echo "FAIL: run1 exited $?"; FAIL=$((FAIL+1)); }
expect fm-missing        'FM-MISSING: no-fm.md'                    "$O"
expect fm-bad-type       'FM-BAD-TYPE: bad-type.md'                "$O"
expect index-dup         'INDEX-DUP: good-memory.md'               "$O"
expect index-orphan      'INDEX-ORPHAN: ghost-file.md'             "$O"
expect rel-date          'REL-DATE: rel-date.md'                   "$O"
expect link-dangling     'LINK-DANGLING: linker.md \[\[gone-memory\]\]' "$O"
expect link-typo         'LINK-TYPO: linker.md \[\[good-memoryy\]\]'    "$O"
expect orphan            'ORPHAN: rel-date.md'                     "$O"
expect superseded-idx    'RETIRE-CANDIDATE: old-thing-shipped.md'  "$O"
expect untriageable-fm   'UNTRIAGEABLE: no-fm.md'                  "$O"
expect untriageable-body 'UNTRIAGEABLE: empty-body-shipped.md'     "$O"
# the HR file's pre-rule content must survive: 3 body lines counted (both
# sides of the horizontal rule), not just what follows the last '---'
expect hr-body-kept      'hr-file.md \| .*rules=1/3'               "$O"

# --- fixture 2: repo validation + dead refs --------------------------------
mem m2
git -C "$T" init -q repo && mkdir -p "$T/repo/app" \
  && echo x > "$T/repo/app/real.py" && echo y > "$T/repo/app/untracked.py"
git -C "$T/repo" add app/real.py >/dev/null 2>&1
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm i >/dev/null 2>&1
mk m2 refs.md project "uses app/real.py and app/gone.py and app/untracked.py and /tmp/abs.py"
printf -- '- [refs](refs.md)\n' > "$T/m2/MEMORY.md"
O="$T/out2"; python3 "$SCRIPT" "$T/m2" --repo "$T/repo" > "$O" 2>&1
expect dead-detected   'dead=1:app/gone.py' "$O"
refute abs-not-dead    'dead=[0-9]+:.*abs'  "$O"
expect untracked-seen  'untracked=1'        "$O"
# missing repo: analysis must be SKIPPED, not everything-dead
O="$T/out3"; python3 "$SCRIPT" "$T/m2" --repo "$T/nowhere" > "$O" 2>&1
expect repo-unavailable 'REPO-UNAVAILABLE'  "$O"
refute no-false-dead    'dead='             "$O"
# worktree (.git file) must be accepted
git -C "$T/repo" worktree add -q "$T/wt" >/dev/null 2>&1
O="$T/out4"; python3 "$SCRIPT" "$T/m2" --repo "$T/wt" > "$O" 2>&1
refute worktree-ok 'REPO-UNAVAILABLE' "$O"

# --- fixture 2b: moved refs, repo-escape refs, md dangling links -----------
mk m2 moved-ref.md project "moved: other/real.py escape: ../outside.py md-link: (gone-child.md)"
O="$T/out2b"; python3 "$SCRIPT" "$T/m2" --repo "$T/repo" > "$O" 2>&1
expect moved-classified 'moved-ref.md \| .*moved=1'          "$O"
refute escape-ignored   'moved-ref.md \| .*(dead|untracked)' "$O"
expect md-dangling      'LINK-DANGLING-MD: moved-ref.md \(gone-child.md\)' "$O"

# --- fixture 4: per-link supersession, DUP containment, CRLF ---------------
mem m4
mk m4 alpha-keep-one.md project "still-good rules: never do X"
mk m4 alpha-gone-one.md project "old fact body"
mk m4 alpha-super-note.md project "newer fact. supersedes [alpha-gone-one](alpha-gone-one.md)"
mk m4 foo-bar.md project "one fact"
mk m4 foo-bar-extra.md project "containment sibling"
printf -- '---\r\nname: crlf-file\r\ndescription: d\r\nmetadata:\r\n  type: project\r\n---\r\nbody line never break\r\n' > "$T/m4/crlf-file.md"
cat > "$T/m4/MEMORY.md" <<'EOF'
- [keep](alpha-keep-one.md) — [old one SUPERSEDED](alpha-gone-one.md), [super](alpha-super-note.md)
- [foo](foo-bar.md) — [foo extra](foo-bar-extra.md), [crlf](crlf-file.md)
EOF
touch -t 202501010000 "$T/m4/alpha-gone-one.md" "$T/m4/alpha-keep-one.md" "$T/m4/alpha-super-note.md"
O="$T/out7"; python3 "$SCRIPT" "$T/m4" > "$O" 2>&1
expect marked-retires     'RETIRE-CANDIDATE: alpha-gone-one.md'  "$O"
refute sibling-not-marked 'RETIRE-CANDIDATE: alpha-keep-one.md'  "$O"
refute superseder-safe    'RETIRE-CANDIDATE: alpha-super-note.md' "$O"
expect dup-containment    'DUP-CANDIDATE: foo-bar.md ~ foo-bar-extra.md' "$O"
refute crlf-fm-parses     'FM-MISSING: crlf-file.md'             "$O"

# --- fixture 5: merge-graph normalization, md-label supersession, subdir repo
mem m5
# reciprocal cluster: strongest (most-linked) member must survive, not cycle
mk m5 sync-pair-alpha-shipped.md project "fact a: never break the invariant. rollout still pending"
mk m5 sync-pair-beta-shipped.md project "fact b: always check first. see [[sync-pair-alpha-shipped]]"
mk m5 sync-pair-gamma-shipped.md project "fact c: must gate writes. see [[sync-pair-alpha-shipped]]"
# supersedes with a DESCRIPTIVE label: the href is the target, not the label
mk m5 note-super.md project "supersedes [the old approach](real-target-shipped.md)"
mk m5 real-target-shipped.md project "old body"
mk m5 old-approach.md project "unrelated; must NOT be marked"
cat > "$T/m5/MEMORY.md" <<'EOF'
- [a](sync-pair-alpha-shipped.md), [b](sync-pair-beta-shipped.md), [g](sync-pair-gamma-shipped.md)
- [ns](note-super.md), [rt](real-target-shipped.md), [oa](old-approach.md)
EOF
touch -t 202501010000 "$T"/m5/*.md
O="$T/out8"; python3 "$SCRIPT" "$T/m5" > "$O" 2>&1
expect md-label-target   'RETIRE-CANDIDATE: real-target-shipped.md' "$O"
refute md-label-not-label 'RETIRE-CANDIDATE: old-approach.md'       "$O"
expect survivor-kept     'kept-as-survivor'                         "$O"
# survivor never also a source: alpha (most inbound) must not be merged away
refute survivor-not-source 'MERGE-CANDIDATE[^:]*: sync-pair-alpha-shipped.md' "$O"
expect others-merge-in   'MERGE-CANDIDATE -> sync-pair-alpha-shipped.md: sync-pair-beta-shipped.md' "$O"
# a demoted survivor with status evidence must fall back to VERIFY, not CLEAN
expect survivor-keeps-verify 'VERIFY-CANDIDATE: sync-pair-alpha-shipped.md \| .*kept-as-survivor' "$O"
# repo passed as a SUBDIRECTORY must resolve to the toplevel inventory
O="$T/out9"; python3 "$SCRIPT" "$T/m2" --repo "$T/repo/app" > "$O" 2>&1
expect subdir-resolves 'dead=1:app/gone.py' "$O"
refute subdir-no-noise 'refs.md \| .*(dead=[2-9]|moved=[1-9])' "$O"

# --- fixture 6: empty repo is a valid zero-file inventory ------------------
mem m6
git -C "$T" init -q m6repo && mkdir -p "$T/m6repo/lib" && echo z > "$T/m6repo/lib/present.py"
mk m6 eref.md project "refs lib/gone.py and lib/present.py: never guess"
printf -- '- [e](eref.md)\n' > "$T/m6/MEMORY.md"
O="$T/outA"; python3 "$SCRIPT" "$T/m6" --repo "$T/m6repo" > "$O" 2>&1
refute empty-repo-ok    'REPO-UNAVAILABLE' "$O"
expect empty-repo-dead  'dead=1:lib/gone.py' "$O"
expect empty-repo-untr  'untracked=1'        "$O"

# --- fixture 7: retiring merge target is FLAGGED, never silently absorbed --
mem m7
mk m7 dead-pool-parent-shipped.md project "plain narrative body only here"
mk m7 dead-pool-childa-shipped.md project "child a: never skip. see [[dead-pool-parent-shipped]]"
mk m7 dead-pool-childb-shipped.md project "child b: always gate. see [[dead-pool-parent-shipped]]"
printf -- '- [p](dead-pool-parent-shipped.md), [a](dead-pool-childa-shipped.md), [b](dead-pool-childb-shipped.md)\n' > "$T/m7/MEMORY.md"
touch -t 202501010000 "$T"/m7/*.md
O="$T/outB"; python3 "$SCRIPT" "$T/m7" > "$O" 2>&1
expect conflict-flagged 'RETIRE-CANDIDATE: dead-pool-parent-shipped.md \| .*CONFLICT:merge-target' "$O"

# --- fixture 8: demoted tiny-leaf survivor falls back to REVIEW, not CLEAN -
mem m8
mk m8 tiny-pair-alpha-shipped.md project "one rule: never inline secrets. plus extra body padding line"
mk m8 tiny-pair-beta-shipped.md project "one rule: always pin versions"
mk m8 tiny-pair-gamma-shipped.md project "one rule: must audit writes"
printf -- '- [a](tiny-pair-alpha-shipped.md), [b](tiny-pair-beta-shipped.md), [g](tiny-pair-gamma-shipped.md)\n' > "$T/m8/MEMORY.md"
touch -t 202501010000 "$T"/m8/*.md
O="$T/outC"; python3 "$SCRIPT" "$T/m8" > "$O" 2>&1
expect leaf-survivor-review 'REVIEW-CANDIDATE \(small-old-leaf\): tiny-pair-alpha-shipped.md \| .*kept-as-survivor' "$O"

# --- global graph invariants (JSON mode) -----------------------------------
for d in m5 m7; do
  O="$T/json-$d"; python3 "$SCRIPT" "$T/$d" --json > "$O" 2>&1
  if python3 - "$O" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
merges = [t for t in d["triage"] if t["verdict"].startswith("MERGE-CANDIDATE")]
sources = {t["file"] for t in merges}
survivors = {t["parent"] for t in merges}
retire = {t["file"] for t in d["triage"] if t["verdict"] == "RETIRE-CANDIDATE"}
assert not (sources & survivors), f"source/survivor overlap: {sources & survivors}"
assert all(t["parent"] not in sources for t in merges), "chained merge"
unflagged = [f for f in (retire & survivors)
             if not any("CONFLICT:merge-target" in s
                        for t in d["triage"] if t["file"] == f
                        for s in t["signals"])]
assert not unflagged, f"unflagged retiring survivors: {unflagged}"
PY
  then PASS=$((PASS+1)); else echo "FAIL: json graph invariants ($d)"; FAIL=$((FAIL+1)); fi
done

# --- fixture 3: corrupt state, CLI errors ----------------------------------
mem m3
mk m3 solo-note-shipped.md project "shipped narrative only, plain text here"
touch -t 202501010000 "$T/m3/solo-note-shipped.md"
printf -- '- [s](solo-note-shipped.md)\n' > "$T/m3/MEMORY.md"
echo 'null' > "$T/m3/.audit-state.json"
O="$T/out5"; python3 "$SCRIPT" "$T/m3" > "$O" 2>&1 || { echo "FAIL: corrupt state crashed"; FAIL=$((FAIL+1)); }
expect state-corrupt 'STATE-CORRUPT' "$O"
printf '{"validated": {"solo-note-shipped.md": "not-a-date"}}' > "$T/m3/.audit-state.json"
O="$T/out6"; python3 "$SCRIPT" "$T/m3" > "$O" 2>&1 || { echo "FAIL: bad date crashed"; FAIL=$((FAIL+1)); }
expect state-invalid-entry 'STATE-INVALID-ENTRY: solo-note-shipped.md' "$O"
# an invalid date must fall back to mtime, not block the age threshold
expect bad-date-mtime-age  'solo-note-shipped.md \| .*age=[0-9]+d\*'   "$O"
python3 "$SCRIPT" --repo 2>/dev/null; [ $? -eq 2 ] \
  && PASS=$((PASS+1)) || { echo "FAIL: trailing --repo should exit 2"; FAIL=$((FAIL+1)); }
python3 "$SCRIPT" "$T/does-not-exist" 2>/dev/null; [ $? -eq 2 ] \
  && PASS=$((PASS+1)) || { echo "FAIL: missing dir should exit 2"; FAIL=$((FAIL+1)); }

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
