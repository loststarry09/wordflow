#!/usr/bin/env bash
#
# Verify every DOCX fixture under tests/fixtures/ with OfficeCLI.
#
# For each fixture this runs:
#   1. officecli validate            -> schema must pass (hard failure)
#   2. officecli view <f> issues     -> reported as advisories (not blocking)
#   3. officecli view <f> screenshot  -> a render must be produced (hard failure)
#
# It also asserts the portability fixture is Transitional OOXML, not Strict.
#
# Renders are written to tests/.out/ (git-ignored).
#
# Requirements: officecli >= 1.0.152 on PATH.
# Usage: tests/validate-fixtures.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
OUT="$ROOT/tests/.out"

command -v officecli >/dev/null || { echo "officecli not found on PATH" >&2; exit 2; }

# Bound every OfficeCLI call so a stuck resident fails a fixture instead of hanging the run.
TMO="timeout 60"

mkdir -p "$OUT"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

while IFS= read -r -d '' f; do
  rel="${f#"$FIX"/}"

  officecli close "$f" >/dev/null 2>&1 || true

  # 1. schema validation (hard)
  if $TMO officecli validate "$f" >/dev/null 2>&1; then
    report_ok "validate   $rel"
  else
    report_fail "$rel" "officecli validate failed or timed out"
  fi

  # 2. issue view (advisory only)
  issues="$($TMO officecli view "$f" issues 2>&1 | head -1)"
  printf '  \033[36mINFO\033[0m issues   %s — %s\n' "$rel" "$issues"

  # 3. render (hard)
  png="$OUT/${rel//\//__}.png"
  if $TMO officecli view "$f" screenshot --grid auto -o "$png" >/dev/null 2>&1 && [[ -s "$png" ]]; then
    report_ok "render     $rel"
  else
    report_fail "$rel" "screenshot render produced no output"
  fi

  # 4. conformance marker for the transitional fixture
  if [[ "$rel" == "portability/transitional-baseline.docx" ]]; then
    doc="$($TMO officecli raw "$f" /document 2>/dev/null)"
    if grep -q 'schemas.openxmlformats.org/wordprocessingml/2006/main' <<<"$doc" \
       && ! grep -q 'purl.oclc.org/ooxml' <<<"$doc"; then
      report_ok "conformance $rel (Transitional)"
    else
      report_fail "$rel" "expected Transitional namespace, found Strict or unknown"
    fi
  fi

  officecli close "$f" >/dev/null 2>&1 || true
done < <(find "$FIX" -name '*.docx' -print0 | sort -z)

echo
echo "Fixtures: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Renders:  $OUT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
