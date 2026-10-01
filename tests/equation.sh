#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow equation primitive (#26).
#
# They exercise two things:
#
#   1. the committed fixtures tests/fixtures/equations/*.docx — simple inline and
#      display equations, and the four complex constructs measured in R04
#      (matrix, aligned, cases with `|`, equation array);
#   2. the operation scripts/wf-equation.sh — it adds an OMML equation with the
#      right mode and a non-empty formula, warns through the shared risk policy
#      for the construct-specific LibreOffice risks only (matrix/eqArr do not
#      warn), never downgrades to an image, leaves the source untouched, and is
#      reproducible.
#
# It asserts what OfficeCLI reports back, not the exact commands run. A
# LibreOffice open-without-repair check runs through the compatibility harness
# when soffice is available; the renderer is reported unverified when it is not.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/equation.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EQFIX="$ROOT/tests/fixtures/equations"
TOOL="$ROOT/scripts/wf-equation.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
for f in inline-equation display-equation matrix-equation aligned-equations cases-equation equation-array; do
  [[ -f "$EQFIX/$f.docx" ]] || { echo "missing fixture: $EQFIX/$f.docx" >&2; exit 2; }
done

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/equation.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_jq() { # assert_jq <name> <jq-filter> <json>
  if jq -e "$2" <<<"$3" >/dev/null 2>&1; then report_ok "$1"; else report_fail "$1" "jq filter false: $2"; fi
}
assert_contains() { # assert_contains <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "'$3' not present"; fi
}

TMO="timeout 60"

cleanup() {
  for f in "$WORK"/*.docx; do
    [[ -e "$f" ]] && $TMO officecli close "$f" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# --- OfficeCLI read-back helpers --------------------------------------------
eq_count()  { $TMO officecli query "$1" equation --json | jq -r '.data.matches // 0'; }
eq_modes()  { $TMO officecli query "$1" equation --json | jq -r '[.data.results[].format.mode] | sort | join(",")'; }
eq_texts()  { $TMO officecli query "$1" equation --json | jq -r '[.data.results[].text] | join("|")'; }
# Signature: mode + formula per equation, order-independent — the observable
# equation content, used to compare two runs for reproducibility.
eq_sig()    { $TMO officecli query "$1" equation --json | jq -r '[.data.results[] | .format.mode + ":" + .text] | sort | join(";")'; }
img_count() { $TMO officecli query "$1" picture --json | jq -r '.data.matches // 0'; }

SRC_IN="$EQFIX/inline-equation.docx"
SRC_DISP="$EQFIX/display-equation.docx"

# Captured before any operation so section 10 can prove the committed source is
# byte-identical after every run.
FIX_SHA_BEFORE="$(sha256sum "$SRC_IN" | awk '{print $1}')"

echo "Equations (#26) — $EQFIX"
echo

# ---------------------------------------------------------------------------
# 1. Committed fixtures: simple equations carry the right mode and a formula
# ---------------------------------------------------------------------------
assert_eq "fixture inline: one equation"    "$(eq_count "$EQFIX/inline-equation.docx")" "1"
assert_eq "fixture inline: mode"            "$(eq_modes "$EQFIX/inline-equation.docx")" "inline"
assert_eq "fixture inline: formula"         "$(eq_texts "$EQFIX/inline-equation.docx")" "E = mc^2"
assert_eq "fixture display: one equation"   "$(eq_count "$EQFIX/display-equation.docx")" "1"
assert_eq "fixture display: mode"           "$(eq_modes "$EQFIX/display-equation.docx")" "display"

# The four complex constructs (R04): each is a single display equation with a
# non-empty formula, and all open repair-free (checked through the harness below
# for the operation output; these are the evidence targets).
for f in matrix-equation aligned-equations cases-equation equation-array; do
  assert_eq "fixture $f: single display equation" "$(eq_modes "$EQFIX/$f.docx")" "display"
  assert_jq "fixture $f: non-empty formula" '([.data.results[].text] | all(length > 0))' \
    "$($TMO officecli query "$EQFIX/$f.docx" equation --json)"
done

# ---------------------------------------------------------------------------
# 2. The operation — inline: right mode, non-empty formula, source untouched
# ---------------------------------------------------------------------------
out_inline="$WORK/inline.docx"
json="$("$TOOL" "$SRC_IN" --out "$out_inline" --mode inline --para '/body/p[1]' --formula 'E = mc^2' --json)" \
  || report_fail "inline: run" "exited non-zero"
assert_eq "inline: source unchanged" "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "inline: read-back mode"   "$(jq -r '.evidence.readback_mode' <<<"$json")" "inline"
assert_eq "inline: formula non-empty" "$(jq -r '.evidence.formula_non_empty' <<<"$json")" "true"
assert_eq "inline: validates"        "$(jq -r '.evidence.validate' <<<"$json")" "true"
assert_eq "inline: no risk warned"   "$(jq -r '.risky' <<<"$json")" "false"
# External check: the output itself now holds two inline equations.
assert_eq "inline: output has 2 inline equations" "$(eq_modes "$out_inline")" "inline,inline"
assert_jq "inline: every formula non-empty" '([.data.results[].text] | all(length > 0))' \
  "$($TMO officecli query "$out_inline" equation --json)"

# ---------------------------------------------------------------------------
# 3. The operation — display (default mode)
# ---------------------------------------------------------------------------
out_disp="$WORK/display.docx"
json="$("$TOOL" "$SRC_DISP" --out "$out_disp" --formula '\\frac{a}{b} = c' --json)" \
  || report_fail "display: run" "exited non-zero"
assert_eq "display: default mode"     "$(jq -r '.mode' <<<"$json")" "display"
assert_eq "display: read-back mode"   "$(jq -r '.evidence.readback_mode' <<<"$json")" "display"
assert_eq "display: formula non-empty" "$(jq -r '.evidence.formula_non_empty' <<<"$json")" "true"
assert_eq "display: no risk warned"   "$(jq -r '.risky' <<<"$json")" "false"
assert_eq "display: output has 2 display equations" "$(eq_modes "$out_disp")" "display,display"

# ---------------------------------------------------------------------------
# 4. A matrix must NOT warn; it is kept as OMML, never an image
# ---------------------------------------------------------------------------
out_matrix="$WORK/matrix.docx"
json="$("$TOOL" "$SRC_IN" --out "$out_matrix" \
  --formula '\\begin{bmatrix} a & b \\\\ c & d \\end{bmatrix}' --json)" \
  || report_fail "matrix: run" "exited non-zero"
assert_eq "matrix: not risky"        "$(jq -r '.risky' <<<"$json")" "false"
assert_eq "matrix: no warnings"      "$(jq -r '.warnings | length' <<<"$json")" "0"
assert_jq "matrix: no complex-equation entry" '([.change_report[] | test("complex-equation")] | any) | not' "$json"
assert_eq "matrix: equation present" "$(eq_count "$out_matrix")" "2"
assert_eq "matrix: no image fallback" "$(img_count "$out_matrix")" "0"

# ---------------------------------------------------------------------------
# 5. An aligned formula DOES warn (construct-specific LibreOffice risk)
# ---------------------------------------------------------------------------
out_aligned="$WORK/aligned.docx"
report_aligned="$WORK/aligned-report.json"
json="$("$TOOL" "$SRC_IN" --out "$out_aligned" --report "$report_aligned" \
  --formula '\\begin{aligned} (a+b)^2 &= a^2 + 2ab + b^2 \\\\ (a-b)^2 &= a^2 - 2ab + b^2 \\end{aligned}' --json)" \
  || report_fail "aligned: run" "exited non-zero"
assert_eq "aligned: risky"     "$(jq -r '.risky' <<<"$json")" "true"
assert_jq "aligned: complex-equation in JSON report" '([.change_report[] | test("complex-equation")] | any)' "$json"
assert_jq "aligned: warning names LibreOffice" '([.warnings[] | test("LibreOffice")] | any)' "$json"
assert_eq "aligned: equation present" "$(eq_count "$out_aligned")" "2"
assert_eq "aligned: no image fallback" "$(img_count "$out_aligned")" "0"
if "$ROOT/scripts/wf-change-report.sh" validate --report "$report_aligned" >/dev/null 2>&1; then
  assert_jq "aligned: written report carries the warning" \
    '([.warnings[] | test("D11-complex-equation")] | any)' "$(cat "$report_aligned")"
else
  report_fail "aligned: written report validates" "wf-change-report validate failed"
fi

# ---------------------------------------------------------------------------
# 6. A formula using the absolute-value bar `|` DOES warn
# ---------------------------------------------------------------------------
out_pipe="$WORK/pipe.docx"
json="$("$TOOL" "$SRC_IN" --out "$out_pipe" \
  --formula '|x| = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}' --json)" \
  || report_fail "pipe: run" "exited non-zero"
assert_eq "pipe: risky" "$(jq -r '.risky' <<<"$json")" "true"
assert_jq "pipe: complex-equation reported" '([.change_report[] | test("complex-equation")] | any)' "$json"
assert_eq "pipe: no image fallback" "$(img_count "$out_pipe")" "0"

# ---------------------------------------------------------------------------
# 7. Reproducibility: same source + formula -> same observable equations
# ---------------------------------------------------------------------------
out_a="$WORK/repro-a.docx"; out_b="$WORK/repro-b.docx"
"$TOOL" "$SRC_IN" --out "$out_a" --formula '\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}' --json >/dev/null
"$TOOL" "$SRC_IN" --out "$out_b" --formula '\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}' --json >/dev/null
assert_eq "reproducible: identical equation signature" "$(eq_sig "$out_a")" "$(eq_sig "$out_b")"

# ---------------------------------------------------------------------------
# 8. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$SRC_IN" --out "$WORK/x.docx" >/dev/null 2>&1;                         assert_eq "bad usage: missing --formula exits 2" "$?" "2"
"$TOOL" "$SRC_IN" --formula 'x' >/dev/null 2>&1;                                assert_eq "bad usage: missing --out exits 2"     "$?" "2"
"$TOOL" "$SRC_IN" --out "$SRC_IN" --formula 'x' >/dev/null 2>&1;                assert_eq "bad usage: --out == source exits 2"   "$?" "2"
"$TOOL" "$SRC_IN" --out "$WORK/x.docx" --mode bogus --formula 'x' >/dev/null 2>&1; assert_eq "bad usage: bad --mode exits 2"      "$?" "2"
"$TOOL" "$SRC_IN" --out "$WORK/x.docx" --para 'body' --formula 'x' >/dev/null 2>&1; assert_eq "bad usage: bad --para exits 2"      "$?" "2"

# ---------------------------------------------------------------------------
# 9. LibreOffice open-without-repair (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1 && [[ -x "$HARNESS" ]]; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$out_disp" --apps libreoffice --out "$compat_out" --timeout 90 >/dev/null 2>&1 \
     && [[ -f "$compat_out/result.json" ]]; then
    # wordflow.compat-harness/v1: one record per (document, application).
    result="$compat_out/result.json"
    assert_eq "compat: libreoffice status" "$(jq -r '.records[] | select(.app=="libreoffice") | .status' "$result")" "ok"
    assert_eq "compat: opens without repair" "$(jq -r '.records[] | select(.app=="libreoffice") | .opens_without_repair' "$result")" "true"
    assert_eq "compat: schema valid" "$(jq -r '.records[] | select(.app=="libreoffice") | .schema_valid' "$result")" "true"
  else
    report_fail "compat: harness produced result.json" "no result.json under $compat_out"
  fi
else
  report_info "compat: LibreOffice verified — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 10. Source protection: the committed fixture is byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: fixture unchanged" "$(sha256sum "$SRC_IN" | awk '{print $1}')" "$FIX_SHA_BEFORE"

echo
echo "Equation: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
