#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow risk policy (#30).
#
# One test per D11 trigger (spec `docs/spec/v0.1.md` §D11), plus the invariants:
# the policy is defined once and callable by every feature, no downgrade is
# silent (it reaches the change report through #28), stop paths produce no
# output and ask the user, and placeholders never ship silently.
#
# These exercise the *external behaviour* of scripts/wf-risk-policy.sh and its
# integration with the real scripts/wf-change-report.sh. No OfficeCLI, no DOCX.
#
# Requirements: jq and coreutils on PATH.
# Usage: tests/risk-policy.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-risk-policy.sh"
REPORT_TOOL="$ROOT/scripts/wf-change-report.sh"
POLICY_DOC="$ROOT/references/workflow/risk-policy.md"

command -v jq >/dev/null || { echo "jq not found on PATH" >&2; exit 2; }
for f in "$TOOL" "$REPORT_TOOL" "$POLICY_DOC"; do
  if [[ ! -f "$f" ]]; then echo "missing: $f" >&2; exit 2; fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

out=""; rc=0
run() { out="$("$TOOL" "$@" 2>"$TMP/err")"; rc=$?; }
errmsg() { cat "$TMP/err"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_exit() {
  if [[ "$rc" == "$2" ]]; then report_ok "$1"; else report_fail "$1" "expected exit $2, got $rc"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "missing '$3'"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "unexpected '$3'"; fi
}
assert_nonempty() {
  if [[ -n "$2" ]]; then report_ok "$1"; else report_fail "$1" "empty"; fi
}

new_report() { "$REPORT_TOOL" new --source "$1" --output "$2" --out "$3" >/dev/null; }
report_area() { jq -r ".$2 | length" "$1"; }

echo "Risk policy (#30) — $TOOL"
echo

# ===========================================================================
# 1. The policy is a single, listable data table.
# ===========================================================================
run list --json
assert_exit "list --json: exits 0" 0
assert_eq "list --json: is a non-empty array" "$(jq -r 'type=="array" and length>0' <<<"$out")" "true"

EXPECTED_IDS="floating-image nested-table columns first-odd-even-headers page-number-restart complex-equation preferred-unavailable content-change restructure-unconfirmed source-unreadable portability-no-alternative unverifiable-field"
for id in $EXPECTED_IDS; do
  if jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$out" >/dev/null 2>&1; then
    report_ok "table: defines trigger '$id'"
  else
    report_fail "table: defines trigger '$id'" "not found"
  fi
done
assert_eq "table: exact trigger count" "$(jq -r 'length' <<<"$out")" "12"

# every trigger code is documented in the normative reference
while IFS=$'\t' read -r id code; do
  if grep -qF "$code" "$POLICY_DOC"; then
    report_ok "doc: '$id' code documented ($code)"
  else
    report_fail "doc: '$id' code documented" "$code not in risk-policy.md"
  fi
done < <(jq -r '.[] | [.id,.code] | @tsv' <<<"$out")

# defined once: no other script carries a D11 trigger code
stray="$(grep -l 'D11-' "$ROOT"/scripts/*.sh 2>/dev/null | grep -v "wf-risk-policy.sh" || true)"
assert_eq "defined once: no D11 codes outside the policy" "$stray" ""

# ===========================================================================
# 2. D11 row 1 — a construction may render differently -> warn + continue.
# ===========================================================================
WARN_REPORT="$TMP/warn.json"
new_report "content.md" "content-排版.docx" "$WARN_REPORT"
for id in floating-image nested-table columns first-odd-even-headers page-number-restart complex-equation; do
  run decide --trigger "$id" --json
  assert_exit "warn[$id]: exits 0" 0
  assert_eq "warn[$id]: decision" "$(jq -r '.decision' <<<"$out")" "warn"
  assert_eq "warn[$id]: area"     "$(jq -r '.area' <<<"$out")"     "warnings"
  assert_eq "warn[$id]: code"     "$(jq -r '.code' <<<"$out")"     "D11-$id"
  assert_eq "warn[$id]: entry uses [CODE] format" \
    "$(jq -r '.entry | startswith("[D11-'"$id"'] ")' <<<"$out")" "true"
  run emit --report "$WARN_REPORT" --trigger "$id"
  assert_exit "warn[$id]: emit exits 0" 0
done
assert_eq "warn: all six in the report's warnings" "$(report_area "$WARN_REPORT" warnings)" "6"
assert_eq "warn: nothing downgraded"               "$(report_area "$WARN_REPORT" downgrades)" "0"
assert_eq "warn: nothing unverified"               "$(report_area "$WARN_REPORT" unverified)" "0"

# ===========================================================================
# 3. D11 row 2 — preferred unavailable with a fallback -> downgrade + report.
# ===========================================================================
DGR_REPORT="$TMP/downgrade.json"
new_report "content.md" "content-排版.docx" "$DGR_REPORT"
run decide --trigger preferred-unavailable --fallback exists --detail "anchored image" --json
assert_exit "downgrade: exits 0" 0
assert_eq "downgrade: decision" "$(jq -r '.decision' <<<"$out")" "downgrade"
assert_eq "downgrade: area"     "$(jq -r '.area' <<<"$out")"     "downgrades"
run emit --report "$DGR_REPORT" --trigger preferred-unavailable --fallback exists --detail "anchored image"
assert_exit "downgrade: emit exits 0" 0
assert_eq "downgrade: reported in downgrades (never silent)" "$(report_area "$DGR_REPORT" downgrades)" "1"
assert_eq "downgrade: entry carries the detail" \
  "$(jq -r '.downgrades[0] | startswith("[D11-preferred-unavailable] anchored image")' "$DGR_REPORT")" "true"

# the emitting report was created and rendered by #28 unchanged
run_render="$(cd "$ROOT" && "$REPORT_TOOL" render --report "$DGR_REPORT" --format text 2>&1)"
assert_contains "downgrade: appears when the report is rendered" "$run_render" "[D11-preferred-unavailable]"
assert_not_contains "downgrade: rendered downgrades section is not 'none'" "$run_render" "Downgrades: none"

# ===========================================================================
# 4. D11 row 2 without a fallback resolves to stop (row 6), not silently.
# ===========================================================================
run decide --trigger preferred-unavailable --fallback none --json
assert_exit "no fallback: exits 3 (stop)" 3
assert_eq "no fallback: decision" "$(jq -r '.decision' <<<"$out")" "stop"
assert_nonempty "no fallback: asks the user" "$(jq -r '.ask' <<<"$out")"

# ===========================================================================
# 5-8. D11 rows 3,4,5,6 — stop and ask. One test each.
# ===========================================================================
for id in content-change restructure-unconfirmed source-unreadable portability-no-alternative; do
  run decide --trigger "$id" --json
  assert_exit "stop[$id]: exits 3" 3
  assert_eq "stop[$id]: decision" "$(jq -r '.decision' <<<"$out")" "stop"
  assert_eq "stop[$id]: no report area" "$(jq -r '.area' <<<"$out")" "none"
  assert_eq "stop[$id]: no entry produced" "$(jq -r '.entry == null' <<<"$out")" "true"
  assert_contains "stop[$id]: asks the user" "$(jq -r '.ask' <<<"$out")" "ask the user"
done

# a stop path via emit: no stdout, no report entry, ask on stderr, exit 3
STOP_REPORT="$TMP/stop.json"
new_report "content.md" "content-排版.docx" "$STOP_REPORT"
before="$(sha256sum "$STOP_REPORT" | awk '{print $1}')"
run emit --report "$STOP_REPORT" --trigger content-change
assert_exit "stop emit: exits 3" 3
assert_eq "stop emit: stdout is empty" "$out" ""
assert_contains "stop emit: ask goes to stderr" "$(errmsg)" "ask the user"
after="$(sha256sum "$STOP_REPORT" | awk '{print $1}')"
assert_eq "stop emit: report untouched" "$before" "$after"
assert_eq "stop emit: no entries anywhere" \
  "$(jq -r '[.changed,.decisions,.warnings,.downgrades,.unverified]|map(length)|add' "$STOP_REPORT")" "0"

# ===========================================================================
# 9-11. D11 row 7 — a placeholder / unguaranteed page number never ships silently.
# ===========================================================================
FIELD_REPORT="$TMP/field.json"
new_report "content.md" "content-排版.docx" "$FIELD_REPORT"

# omit -> downgrade, recorded as an intentional omission in unverified
run decide --trigger unverifiable-field --resolution omit --detail "TOC page numbers" --json
assert_exit "field omit: exits 0" 0
assert_eq "field omit: decision downgrade" "$(jq -r '.decision' <<<"$out")" "downgrade"
assert_eq "field omit: area unverified"    "$(jq -r '.area' <<<"$out")"     "unverified"
run emit --report "$FIELD_REPORT" --trigger unverifiable-field --resolution omit --detail "TOC page numbers"
assert_exit "field omit: emit exits 0" 0
assert_eq "field omit: recorded as an intentional omission" "$(report_area "$FIELD_REPORT" unverified)" "1"
assert_contains "field omit: omission is explicit" \
  "$(jq -r '.unverified[0]' "$FIELD_REPORT")" "omitted"

# state -> warn, recorded as unverified (shipped but not guaranteed)
run decide --trigger unverifiable-field --resolution state --detail "page number" --json
assert_exit "field state: exits 0" 0
assert_eq "field state: decision warn" "$(jq -r '.decision' <<<"$out")" "warn"
assert_eq "field state: area unverified" "$(jq -r '.area' <<<"$out")"   "unverified"

# no resolution -> stop: shipping a placeholder silently is unrepresentable
run decide --trigger unverifiable-field --json
assert_exit "field silent: exits 3 (stop)" 3
assert_eq "field silent: decision" "$(jq -r '.decision' <<<"$out")" "stop"
before="$(sha256sum "$FIELD_REPORT" | awk '{print $1}')"
run emit --report "$FIELD_REPORT" --trigger unverifiable-field
assert_exit "field silent emit: exits 3" 3
assert_eq "field silent emit: stdout empty" "$out" ""
after="$(sha256sum "$FIELD_REPORT" | awk '{print $1}')"
assert_eq "field silent emit: nothing written" "$before" "$after"

# ===========================================================================
# 12. classify is an alias for decide; both share the decision.
# ===========================================================================
run classify --trigger columns --json
assert_exit "classify: exits 0" 0
assert_eq "classify: same decision as decide" "$(jq -r '.decision' <<<"$out")" "warn"

# ===========================================================================
# 13. All decisions accumulate in one report and render through #28.
# ===========================================================================
BIG="$TMP/all.json"
new_report "content.md" "content-排版.docx" "$BIG"
"$TOOL" emit --report "$BIG" --trigger floating-image >/dev/null
"$TOOL" emit --report "$BIG" --trigger nested-table >/dev/null
"$TOOL" emit --report "$BIG" --trigger preferred-unavailable --fallback exists --detail "anchored image" >/dev/null
"$TOOL" emit --report "$BIG" --trigger unverifiable-field --resolution state --detail "page number" >/dev/null
assert_eq "accumulate: warnings"   "$(report_area "$BIG" warnings)" "2"
assert_eq "accumulate: downgrades" "$(report_area "$BIG" downgrades)" "1"
assert_eq "accumulate: unverified" "$(report_area "$BIG" unverified)" "1"
"$REPORT_TOOL" validate --report "$BIG" >/dev/null 2>&1; rc=$?
assert_exit "accumulate: report still valid" 0
rendered="$("$REPORT_TOOL" render --report "$BIG" --format markdown)"
assert_contains "accumulate: warning in markdown"    "$rendered" "D11-floating-image"
assert_contains "accumulate: downgrade in markdown"  "$rendered" "D11-preferred-unavailable"
assert_contains "accumulate: unverified in markdown" "$rendered" "D11-unverifiable-field"

# ===========================================================================
# 14. Usage errors.
# ===========================================================================
run decide --trigger does-not-exist --json
assert_exit "usage: unknown trigger exits 2" 2
run decide --json
assert_exit "usage: decide without --trigger exits 2" 2
run emit --trigger floating-image
assert_exit "usage: emit without --report exits 2" 2
run emit --report "$WARN_REPORT"
assert_exit "usage: emit without --trigger exits 2" 2
run
assert_exit "usage: no command exits 2" 2
run bogus
assert_exit "usage: unknown command exits 2" 2

echo
echo "Risk policy: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
