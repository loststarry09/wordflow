#!/usr/bin/env bash
#
# Acceptance tests for WordFlow style inspection and ownership decision (#16).
#
# These tests exercise the *external behaviour* of the reproducible operation
# scripts/wf-style-ownership.sh: given a source document (and an optional
# template) it must report the style inventory and a single ownership decision,
# and it must never modify the source.
#
# They deliberately assert the decision and the inventory facts, not the exact
# OfficeCLI commands the operation runs internally.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH.
# Usage: tests/style-ownership.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-style-ownership.sh"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
  exit 2
fi

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

# run the operation and capture its JSON report
inspect() {
  local src="$1"; shift
  "$TOOL" "$src" "$@" --json
}

# assert_eq <label> <actual> <expected>
assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

# assert_decides <label> <expected decision> <src> [tool args...]
# Also asserts the source document is byte-identical before and after.
assert_case() {
  local label="$1" expected="$2" src="$3"; shift 3
  local before after json decision coherent
  before="$(sha256sum "$src" | awk '{print $1}')"
  json="$(inspect "$src" "$@")" || { report_fail "$label" "operation exited non-zero"; return; }
  after="$(sha256sum "$src" | awk '{print $1}')"

  decision="$(jq -r '.decision // "<none>"' <<<"$json")"
  assert_eq "$label: decision" "$decision" "$expected"

  if [[ "$before" == "$after" ]]; then report_ok "$label: source unchanged"; else report_fail "$label: source unchanged" "source bytes changed"; fi

  coherent="$(jq -r '.coherent // false' <<<"$json")"
  if [[ "$coherent" == "true" || "$coherent" == "false" ]]; then report_ok "$label: coherent field present"; else report_fail "$label: coherent field present" "missing coherent"; fi

  if jq -e '.change_report | length > 0' <<<"$json" >/dev/null; then
    report_ok "$label: decision reported in change report"
  else
    report_fail "$label: decision reported in change report" "empty change_report"
  fi
}

echo "Style ownership (#16) — $TOOL"

# 1. coherent styles -> preserve
assert_case "coherent styles" "preserve-and-tidy" "$FIX/styles/heading-hierarchy.docx"
json="$(inspect "$FIX/styles/heading-hierarchy.docx")"
assert_eq "coherent styles: no dangling" "$(jq -c '[.dangling_styles[]?] | length' <<<"$json")" "0"
assert_eq "coherent styles: heading hierarchy true" "$(jq -r '.has_heading_hierarchy' <<<"$json")" "true"
assert_eq "coherent styles: heading levels 1-3" "$(jq -c '.heading_levels' <<<"$json")" "[1,2,3]"

# 2. no named styles -> rebuild
assert_case "no named styles" "rebuild-with-standard-styles" "$FIX/styles/unstyled.docx"
json="$(inspect "$FIX/styles/unstyled.docx")"
assert_eq "no named styles: no named styles in use" "$(jq -c '[.named_styles_in_use[]?] | length' <<<"$json")" "0"

# 3. document + template -> template wins, and the template is actually read
assert_case "document + template" "use-template-styles" "$FIX/styles/heading-hierarchy.docx" --template "$FIX/styles/template.docx"
json="$(inspect "$FIX/styles/heading-hierarchy.docx" --template "$FIX/styles/template.docx")"
assert_eq "document + template: template styles read" "$(jq -c '.template_styles | (index("WF Body") != null) and (index("WF Quote") != null)' <<<"$json")" "true"
assert_case "unstyled + template" "use-template-styles" "$FIX/styles/unstyled.docx" --template "$FIX/styles/template.docx"

# 4. dangling reference -> preserve with a repair item, marked incoherent
assert_case "dangling reference" "preserve-and-tidy" "$FIX/styles/caption-dangling.docx"
json="$(inspect "$FIX/styles/caption-dangling.docx")"
assert_eq "dangling reference: Caption detected" "$(jq -r '[.dangling_styles[]? | ascii_downcase] | index("caption") != null' <<<"$json")" "true"
assert_eq "dangling reference: coherent false" "$(jq -r '.coherent' <<<"$json")" "false"

# 5. bad usage: a missing --template argument is rejected, not a silent crash
"$TOOL" "$FIX/styles/unstyled.docx" --template >/dev/null 2>&1
assert_eq "bad usage: --template without value exits 2" "$?" "2"

echo
echo "Style ownership: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
