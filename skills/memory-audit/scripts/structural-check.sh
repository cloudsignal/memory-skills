#!/usr/bin/env bash
# structural-check.sh <memory-dir>
# Tier-1 structural hygiene for a Claude Code file-based memory directory.
# Prints "LABEL: detail" finding lines to stdout; exits 0 even with findings
# (findings are data, not errors). Exit 2 = usage error.
# Bash-3.2/BSD-portable: no GNU-only flags, no arrays. Detail suffixes are
# parenthesized so callers/tests can normalize with: sed -E 's/ \([^)]*\)$//'
#
# Env overrides (used by the test): MEMAUDIT_INDEX_BUDGET (default 24576),
# MEMAUDIT_ENTRY_MAX (200), MEMAUDIT_BODY_FLAG (8192).
set -u

MEM="${1:-}"
if [ -z "$MEM" ] || [ ! -d "$MEM" ]; then
  echo "usage: structural-check.sh <memory-dir>" >&2
  exit 2
fi
IDX="$MEM/MEMORY.md"
BUDGET="${MEMAUDIT_INDEX_BUDGET:-24576}"
ENTRY_MAX="${MEMAUDIT_ENTRY_MAX:-200}"
BODY_FLAG="${MEMAUDIT_BODY_FLAG:-8192}"

OUT="$(mktemp)"
TOK="$(mktemp -d)"
trap 'rm -rf "$OUT" "$TOK"' EXIT

say() { printf '%s\n' "$*" >> "$OUT"; }

# frontmatter of $1: text between the first two --- lines (empty if absent)
fm() { awk 'NR==1 && $0 != "---" {exit} /^---$/ {n++; if (n==2) exit; next} n==1 {print}' "$1"; }

fm_field() { # fm_field <file> <key>  -> first value, quotes stripped
  fm "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1 | tr -d '"' | tr -d "'"
}

# nearest existing memory whose slug contains / is contained by $1's slug,
# or equals it after squeezing repeated chars (catches doubled-letter typos)
near_match() {
  s1="${1%.md}"
  sq1="$(printf '%s' "$s1" | tr -s 'a-z0-9')"
  for g in "$MEM"/*.md; do
    [ -f "$g" ] || continue
    b2="$(basename "$g")"
    [ "$b2" = "MEMORY.md" ] && continue
    s2="${b2%.md}"
    [ "$s1" = "$s2" ] && continue
    case "$s1" in *"$s2"*) printf '%s' "$b2"; return 0;; esac
    case "$s2" in *"$s1"*) printf '%s' "$b2"; return 0;; esac
    sq2="$(printf '%s' "$s2" | tr -s 'a-z0-9')"
    if [ "$sq1" = "$sq2" ]; then printf '%s' "$b2"; return 0; fi
  done
  return 1
}

HAVE_IDX=0
if [ -f "$IDX" ]; then HAVE_IDX=1; else say "INDEX-MISSING: MEMORY.md not found"; fi

# --- per-file checks (alphabetical) ------------------------------------------
for f in "$MEM"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "MEMORY.md" ] && continue
  slug="${b%.md}"

  if [ "$HAVE_IDX" = 1 ]; then
    n="$(grep -cF "](${b})" "$IDX")" || true
    if [ "$n" -eq 0 ]; then say "NOT-INDEXED: $b"; fi
    if [ "$n" -gt 1 ]; then say "INDEX-DUP: $b ($n index lines)"; fi
  fi

  name="$(fm_field "$f" name)"
  desc="$(fm_field "$f" description)"
  typ="$(fm "$f" | sed -n 's/^[[:space:]]*type:[[:space:]]*//p' | head -1)"
  if [ "$name" != "$slug" ]; then say "FM-NAME-MISMATCH: $b (name '$name')"; fi
  if [ -z "$desc" ]; then say "FM-NO-DESC: $b"; fi
  case "$typ" in
    user|feedback|project|reference) : ;;
    *) say "FM-BAD-TYPE: $b (type '${typ:-missing}')" ;;
  esac

  sz=$(($(wc -c < "$f")))
  if [ "$sz" -gt "$BODY_FLAG" ]; then say "OVERSIZED: $b ($sz bytes)"; fi
done

# --- index-side checks ---------------------------------------------------------
if [ "$HAVE_IDX" = 1 ]; then
  grep -oE '\]\([^)]*\.md\)' "$IDX" | sed 's/^](//; s/)$//' | sort -u | \
  while IFS= read -r t; do
    tb="$(basename "$t")"
    if [ ! -f "$MEM/$tb" ]; then
      if nm="$(near_match "$tb")"; then
        say "INDEX-ORPHAN-NEARMATCH: $tb (~ $nm)"
      else
        say "INDEX-ORPHAN: $tb"
      fi
    fi
  done

  isz=$(($(wc -c < "$IDX")))
  if [ "$isz" -gt "$BUDGET" ]; then say "INDEX-SIZE: MEMORY.md ($isz bytes > budget $BUDGET)"; fi

  awk -v m="$ENTRY_MAX" '/^- \[/ && length($0) > m {
    if (match($0, /\]\([^)]*\.md\)/)) { t = substr($0, RSTART + 2, RLENGTH - 3) } else { t = "?" }
    printf "INDEX-LONG: %s (%d chars)\n", t, length($0)
  }' "$IDX" >> "$OUT"
fi

# --- [[link]] checks ------------------------------------------------------------
for f in "$MEM"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "MEMORY.md" ] && continue
  grep -oE '\[\[[a-z0-9-]+\]\]' "$f" 2>/dev/null | sort -u | \
  while IFS= read -r l; do
    tgt="$(printf '%s' "$l" | tr -d '[]')"
    if [ ! -f "$MEM/$tgt.md" ]; then
      if nm="$(near_match "$tgt.md")"; then
        say "LINK-TYPO: $b [[${tgt}]] (~ $nm)"
      else
        say "LINK-DANGLING: $b [[${tgt}]]"
      fi
    fi
  done
done

# --- relative-date phrases -------------------------------------------------------
for f in "$MEM"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "MEMORY.md" ] && continue
  p="$(grep -oiE 'yesterday|tomorrow|last week|last month|next week|next month|[0-9][0-9]* (day|week)s? ago' "$f" | head -1)"
  if [ -n "$p" ]; then say "REL-DATE: $b ($p)"; fi
done

# --- duplicate-topic candidates (slug token overlap >= 3) -----------------------
STOP='^(shipped|status|deployed|fixed|broken|bug|next|steps|and|the|for|via|v1|v2)$'
for f in "$MEM"/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "MEMORY.md" ] && continue
  slug="${b%.md}"
  printf '%s\n' "$slug" | tr '-' '\n' | grep -vE "$STOP" | sort -u > "$TOK/$slug" || true
done
for a in "$TOK"/*; do
  [ -f "$a" ] || continue
  for c in "$TOK"/*; do
    [ -f "$c" ] || continue
    sa="$(basename "$a")"
    sc="$(basename "$c")"
    [ "$sa" \< "$sc" ] || continue
    common="$(comm -12 "$a" "$c" | grep -c .)" || true
    if [ "$common" -ge 3 ]; then say "DUP-CANDIDATE: $sa.md ~ $sc.md"; fi
  done
done

# --- emit -------------------------------------------------------------------------
cat "$OUT"
printf 'TOTAL-FINDINGS: %s\n' "$(grep -c . "$OUT")"
exit 0
