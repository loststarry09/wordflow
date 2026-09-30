#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow change-report contract (#28).
#
# These tests exercise the *external behaviour* of scripts/wf-change-report.sh:
# a job can create a report, contribute entries for each of the five areas, and
# render it with empty areas stated explicitly; malformed reports and bad usage
# are rejected with the documented exit codes.
#
# They assert the contract (shape, CLI, exit codes, rendered content), not the
# internal jq/OfficeCLI commands. Representative content is asserted: a downgrade,
# a default applied on the user's behalf, and an intentional omission.
#
# Requirements: jq and coreutils on PATH. No OfficeCLI, no DOCX.
# Usage: tests/change-report.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-change-report.sh"

command -v jq >/dev/null || { echo "jq not found on PATH" >&2; exit 2; }

if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable tool: $TOOL" >&2
  exit 2
fi

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
assert_file_valid() { # assert_valid <label> <file>
  if "$TOOL" validate --report "$2" >/dev/null 2>&1; then report_ok "$1"; else report_fail "$1" "not valid"; fi
  return 0
}

echo "Change report (#28) — $TOOL"

# --- 1. new: an empty report with all five areas present --------------------
R="$TMP/report.json"
run new --source "input.md" --output "input-排版.docx" --out "$R"
assert_exit "new: exits 0" 0
assert_file_valid "new: report is valid" "$R"
assert_eq "new: source set"        "$(jq -r '.source' "$R")" "input.md"
assert_eq "new: output set"        "$(jq -r '.output' "$R")" "input-排版.docx"
assert_eq "new: five areas, all empty" \
  "$(jq -c '[.changed,.decisions,.warnings,.downgrades,.unverified] | map(length) | add' "$R")" "0"
assert_eq "new: exact key set" \
  "$(jq -c 'keys' "$R")" '["changed","decisions","downgrades","output","source","unverified","warnings"]'

# --- 2. render on a fresh report: every empty area stated explicitly --------
run render --report "$R"
assert_exit "render empty: exits 0" 0
assert_contains "render empty: source line"     "$out" "source: input.md"
assert_contains "render empty: Changed none"    "$out" "Changed: none"
assert_contains "render empty: Decisions none"  "$out" "Decisions: none"
assert_contains "render empty: Warnings none"   "$out" "Warnings: none"
assert_contains "render empty: Downgrades none" "$out" "Downgrades: none"
assert_contains "render empty: Unverified none" "$out" "Unverified: none"

# --- 3. add: representative content in every area ---------------------------
run add --report "$R" --area changed \
  --entry "Applied the WordFlow standard style set" \
  --entry "Set A4 portrait, margins 2.54/3.17 cm"
assert_exit "add changed: exits 0" 0
run add --report "$R" --area decisions \
  --entry "Body 1.5 line spacing (default, nothing specified)"
assert_exit "add decisions (default): exits 0" 0
run add --report "$R" --area warnings \
  --entry "[D11-floating-image] a floating image may render in flow in LibreOffice"
assert_exit "add warnings (code prefix): exits 0" 0
run add --report "$R" --area downgrades \
  --entry "[D11-floating-image] anchored image centred inline instead"
assert_exit "add downgrades: exits 0" 0
run add --report "$R" --area unverified \
  --entry "TOC page numbers omitted — no application recalculates fields on open (D9)"
assert_exit "add unverified omission: exits 0" 0
assert_file_valid "add: report still valid" "$R"

assert_eq "add: changed count"       "$(jq -r '.changed | length' "$R")" "2"
assert_eq "add: default recorded"    "$(jq -r '.decisions[0] | contains("default")' "$R")" "true"
assert_eq "add: downgrade recorded"  "$(jq -r '.downgrades[0]' "$R")" "[D11-floating-image] anchored image centred inline instead"
assert_eq "add: warning code kept"   "$(jq -r '.warnings[0] | startswith("[D11-floating-image]")' "$R")" "true"
assert_eq "add: omission recorded"   "$(jq -r '.unverified[0] | contains("omitted")' "$R")" "true"

# --- 4. add preserves --entry order -----------------------------------------
R2="$TMP/order.json"
"$TOOL" new --source s --output o --out "$R2" >/dev/null
run add --report "$R2" --area changed --entry "first" --entry "second" --entry "third"
assert_exit "add multiple entries: exits 0" 0
assert_eq "add multiple entries: order preserved" "$(jq -c '.changed' "$R2")" '["first","second","third"]'

# --- 5. render text with content: downgrade and default appear --------------
run render --report "$R" --format text
assert_exit "render text: exits 0" 0
assert_contains "render text: downgrade entry shown" "$out" "- [D11-floating-image] anchored image centred inline instead"
assert_contains "render text: default decision shown" "$out" "Body 1.5 line spacing (default, nothing specified)"
assert_not_contains "render text: downgrades not reported empty" "$out" "Downgrades: none"

# --- 6. render markdown -----------------------------------------------------
run render --report "$R" --format markdown
assert_exit "render markdown: exits 0" 0
assert_contains "render markdown: title"    "$out" "# WordFlow change report"
assert_contains "render markdown: heading"  "$out" "### Downgrades"
assert_contains "render markdown: entry"    "$out" "- [D11-floating-image] anchored image centred inline instead"
run render --report "$TMP/order.json" --format markdown
assert_contains "render markdown: empty stated" "$out" "_none_"

# --- 7. special characters survive a round-trip -----------------------------
R3="$TMP/special.json"
"$TOOL" new --source s --output o --out "$R3" >/dev/null
run add --report "$R3" --area changed --entry 'He said "hi" — [x] 你好 & <ok>'
assert_exit "special chars: exits 0" 0
assert_eq "special chars: round-trip" "$(jq -r '.changed[0]' "$R3")" 'He said "hi" — [x] 你好 & <ok>'

# --- 8. new overwrites an existing report -----------------------------------
run new --source again --output again.docx --out "$R3"
assert_exit "new overwrite: exits 0" 0
assert_eq "new overwrite: emptied" "$(jq -c '[.changed,.decisions,.warnings,.downgrades,.unverified] | map(length) | add' "$R3")" "0"
assert_eq "new overwrite: new source" "$(jq -r '.source' "$R3")" "again"

# --- 9. unknown area is rejected with a clear error -------------------------
run add --report "$R" --area bogus --entry "x"
assert_exit "unknown area: exits 2" 2
assert_contains "unknown area: clear error" "$(errmsg)" "unknown area"

# --- 10. malformed reports are rejected -------------------------------------
echo 'not json' > "$TMP/notjson.json"
run validate --report "$TMP/notjson.json"
assert_exit "malformed: not JSON exits 1" 1

jq 'del(.unverified)' "$R" > "$TMP/missing.json"
run validate --report "$TMP/missing.json"
assert_exit "malformed: missing area exits 1" 1

jq '.changed=[1]' "$R" > "$TMP/wrongtype.json"
run validate --report "$TMP/wrongtype.json"
assert_exit "malformed: non-string entry exits 1" 1

jq '.decisions=["  "]' "$R" > "$TMP/blankentry.json"
run validate --report "$TMP/blankentry.json"
assert_exit "malformed: blank entry exits 1" 1

jq '.source="   "' "$R" > "$TMP/blanksource.json"
run validate --report "$TMP/blanksource.json"
assert_exit "malformed: blank source exits 1" 1

run validate --report "$TMP/does-not-exist.json"
assert_exit "malformed: missing file exits 1" 1

# adding to a malformed report must fail and not corrupt it
before="$(sha256sum "$TMP/wrongtype.json" | awk '{print $1}')"
run add --report "$TMP/wrongtype.json" --area changed --entry "x"
assert_exit "add to malformed: exits 1" 1
after="$(sha256sum "$TMP/wrongtype.json" | awk '{print $1}')"
assert_eq "add to malformed: file untouched" "$before" "$after"

# --- 11. render/add on a missing report -------------------------------------
run render --report "$TMP/nope.json"
assert_exit "render missing report: exits 1" 1
run add --report "$TMP/nope.json" --area changed --entry "x"
assert_exit "add missing report: exits 1" 1

# --- 12. usage errors -------------------------------------------------------
run
assert_exit "usage: no args exits 2" 2
run bogus-command
assert_exit "usage: unknown command exits 2" 2
run new --source s --output o
assert_exit "usage: new missing --out exits 2" 2
run add --report "$R" --area changed
assert_exit "usage: add missing --entry exits 2" 2
run add --report "$R" --area changed --entry "   "
assert_exit "usage: blank entry exits 2" 2
run render --report "$R" --format html
assert_exit "usage: unknown format exits 2" 2
run validate
assert_exit "usage: validate missing --report exits 2" 2
run new --source s --output o --out "$R" --bogus
assert_exit "usage: unknown option exits 2" 2
run add --report "$R" --entry "x"
assert_exit "usage: add missing --area exits 2" 2

echo
echo "Change report: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
