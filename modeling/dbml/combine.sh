#!/usr/bin/env bash
# Combine DBML schema files for diagramming and documentation tools that
# don't support cross-file schema references (dbdiagram.io, dbml-renderer, etc.).
#
# Modes:
#   default          full concat of listed (or default) schemas, single Project block
#   --scope <name>   extract tables listed in scopes/<name>.txt; strip refs to unlisted
#   --scope --stubs  extract listed tables; add minimal stub Tables for FK targets not in scope
#
# Usage:
#   ./combine.sh                              # ref + integration + catalog
#   ./combine.sh --all                        # ref + integration + catalog + staging + raw
#   ./combine.sh ref.dbml integration.dbml    # explicit file list
#   ./combine.sh --scope core                 # extract per scopes/core.txt
#   ./combine.sh --scope core --stubs         # same, but with FK target stubs
#   ./combine.sh --scope core | pbcopy        # straight to clipboard (macOS)
#   ./combine.sh --scope core | dbml-renderer -i /dev/stdin -o /tmp/core.svg
#
# See scopes/README.md for the scope-manifest format and design rationale.

set -euo pipefail

cd "$(dirname "$0")"

SCOPE=""
STUBS=0
FILES=()

print_help() {
  sed -n '2,18p' "$0" | sed -E 's|^# ?||'
  echo
  echo "Available scopes:"
  if [ -d scopes ]; then
    ls scopes/*.txt 2>/dev/null | sed 's|scopes/||; s|\.txt||; s|^|  |' || echo "  (none)"
  else
    echo "  (scopes/ directory not present)"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      if [ $# -lt 2 ]; then
        echo "combine.sh: --scope requires an argument" >&2
        exit 1
      fi
      SCOPE="$2"
      shift 2
      ;;
    --stubs)
      STUBS=1
      shift
      ;;
    --all)
      FILES=(ref.dbml integration.dbml catalog.dbml staging.dbml raw.dbml)
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# ============================================================================
# Scope mode
# ============================================================================
if [ -n "$SCOPE" ]; then
  SCOPE_FILE="scopes/${SCOPE}.txt"
  if [ ! -f "$SCOPE_FILE" ]; then
    echo "combine.sh: scope file not found: $SCOPE_FILE" >&2
    if [ -d scopes ]; then
      echo "Available:" >&2
      ls scopes/*.txt 2>/dev/null | sed 's|scopes/||; s|\.txt||; s|^|  |' >&2
    fi
    exit 1
  fi

  # Parse the manifest: drop comment and blank lines
  WANT=$(grep -v '^[[:space:]]*#' "$SCOPE_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ' ')

  # Source files: default ref + integration (covers all current scope needs).
  # Override by listing files explicitly after --scope.
  if [ ${#FILES[@]} -eq 0 ]; then
    FILES=(ref.dbml integration.dbml)
  fi

  for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
      echo "combine.sh: source file not found: $f" >&2
      exit 1
    fi
  done

  # Extract listed Table blocks (+ first Project block) via awk;
  # post-process via Python to strip refs (strict) or add stubs (--stubs).
  awk -v want="$WANT" '
    BEGIN { n = split(want, arr, " "); for (i=1; i<=n; i++) wanted[arr[i]] = 1; project_seen = 0 }
    /^Project / { if (project_seen) { in_skip=1; next } project_seen=1; in_keep=1; print; next }
    /^Table / { name=$2; if (name in wanted) { in_keep=1; print } else { in_skip=1 }; next }
    in_keep && /^}/ { print; in_keep=0; next }
    in_keep { print; next }
    in_skip && /^}/ { in_skip=0; next }
    in_skip { next }
    !in_skip { print }
  ' "${FILES[@]}" | python3 -c "
import re, sys
WANT = set(sys.argv[1].split())
STUBS = sys.argv[2] == '1'
src = sys.stdin.read()
if STUBS:
    targets = set(m.group(1) + '.' + m.group(2) for m in re.finditer(r'ref: > ([a-z_]+)\.([a-z_0-9]+)\.[a-z_0-9]+', src))
    out_of_scope = sorted(targets - WANT)
    if out_of_scope:
        src += '\n// ' + '-' * 75 + '\n'
        src += '// Stub tables for out-of-scope FK targets (--stubs mode).\n'
        src += '// FKs render but referenced tables are not fully described here.\n'
        src += '// ' + '-' * 75 + '\n\n'
        for t in out_of_scope:
            src += 'Table ' + t + ' {\n  id  bigint  [pk]\n}\n\n'
else:
    def strip(m):
        target = m.group(1) + '.' + m.group(2)
        return '' if target not in WANT else m.group(0)
    src = re.sub(r', ref: > ([a-z_]+)\.([a-z_0-9]+)\.[a-z_0-9]+', strip, src)
    src = re.sub(r'ref: > ([a-z_]+)\.([a-z_0-9]+)\.[a-z_0-9]+, ', strip, src)
    src = re.sub(r' *\[ref: > ([a-z_]+)\.([a-z_0-9]+)\.[a-z_0-9]+\]', strip, src)
sys.stdout.write(src)
" "$WANT" "$STUBS"
  exit 0
fi

# ============================================================================
# Default mode: full concat (existing behavior)
# ============================================================================
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=(ref.dbml integration.dbml catalog.dbml)
fi

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "combine.sh: file not found: $f" >&2
    exit 1
  fi
done

awk '
  /^Project / { project_count++; in_project=1 }
  in_project {
    if (project_count == 1) print
    if (/^}/) in_project=0
    next
  }
  { print }
' "${FILES[@]}"
