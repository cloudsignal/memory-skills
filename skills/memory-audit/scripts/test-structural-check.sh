#!/usr/bin/env bash
# test-structural-check.sh — fixture-based test for structural-check.sh.
# Builds a temp memory dir with one known defect per check, runs the checker,
# and diffs normalized actual output against expected findings.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# --- fixture memory files ----------------------------------------------------
cat > "$FIX/good.md" <<'EOF'
---
name: good
description: a clean memory with a deliberate forward-ref link
metadata:
  type: project
---

Body. Links to [[never-written-yet]] which is allowed by design.
EOF

cat > "$FIX/typo.md" <<'EOF'
---
name: typo
description: has a typo'd link that near-matches good
metadata:
  type: project
---

See [[goood]] for details.
EOF

cat > "$FIX/malformed.md" <<'EOF'
---
name: ""
metadata:
  node_type: memory
---

Mimics the real-world broken file: empty name, no description, no type.
EOF

cat > "$FIX/stale-date.md" <<'EOF'
---
name: stale-date
description: contains a relative date phrase
metadata:
  type: feedback
---

This was fixed last week and should be absolutized.
EOF

cat > "$FIX/big.md" <<'EOF'
---
name: big
description: oversized body under the test override
metadata:
  type: reference
---

Padding padding padding padding padding padding padding padding padding.
Padding padding padding padding padding padding padding padding padding.
Padding padding padding padding padding padding padding padding padding.
Padding padding padding padding padding padding padding padding padding.
EOF

cat > "$FIX/unindexed.md" <<'EOF'
---
name: unindexed
description: exists but has no MEMORY.md line
metadata:
  type: project
---

Body.
EOF

cat > "$FIX/ai-template-edit-alpha.md" <<'EOF'
---
name: ai-template-edit-alpha
description: duplicate-topic candidate A
metadata:
  type: project
---

Body.
EOF

cat > "$FIX/ai-template-edit-beta.md" <<'EOF'
---
name: ai-template-edit-beta
description: duplicate-topic candidate B
metadata:
  type: project
---

Body.
EOF

cat > "$FIX/MEMORY.md" <<'EOF'
# Memory Index

- [Good](good.md) — clean memory
- [Good again](good.md) — duplicate index line for the same file
- [Typo](typo.md) — has a typo'd link
- [Malformed](malformed.md) — broken frontmatter
- [Stale date](stale-date.md) — this entry line is deliberately padded far past the two-hundred-character budget so the INDEX-LONG check fires on it, padding padding padding padding padding padding padding padding padding padding
- [Big](big.md) — oversized body
- [Ghost](ghost.md) — points at a file that does not exist
- [Alpha](ai-template-edit-alpha.md) — dup candidate A
- [Beta](ai-template-edit-beta.md) — dup candidate B
EOF

# --- run + normalize -----------------------------------------------------------
actual="$(MEMAUDIT_INDEX_BUDGET=300 MEMAUDIT_BODY_FLAG=300 \
  "$HERE/structural-check.sh" "$FIX" | sed -E 's/ \([^)]*\)$//')"

expected="$(cat <<'EOF'
OVERSIZED: big.md
INDEX-DUP: good.md
FM-NAME-MISMATCH: malformed.md
FM-NO-DESC: malformed.md
FM-BAD-TYPE: malformed.md
NOT-INDEXED: unindexed.md
INDEX-ORPHAN: ghost.md
INDEX-SIZE: MEMORY.md
INDEX-LONG: stale-date.md
LINK-DANGLING: good.md [[never-written-yet]]
LINK-TYPO: typo.md [[goood]]
REL-DATE: stale-date.md
DUP-CANDIDATE: ai-template-edit-alpha.md ~ ai-template-edit-beta.md
TOTAL-FINDINGS: 13
EOF
)"

if [ "$actual" = "$expected" ]; then
  echo "OK: structural-check matches expected findings (13)"
else
  echo "FAIL: output mismatch"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
  exit 1
fi
