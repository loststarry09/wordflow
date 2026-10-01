#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow table primitive (#21).
#
# They exercise:
#
#   1. the committed fixtures tests/fixtures/tables/{fixed,merged,nested}-table.docx
#      — a regular fixed table, a merged-cell table (a horizontal span and a
#      vertical merge), and a nested table;
#   2. the operation scripts/wf-table.sh — it builds a regular, merged-cell, or
#      nested table into a new output, leaves the source untouched, is
#      reproducible, and rejects bad usage.
#
# It asserts what OfficeCLI reports back, not the exact commands run: grid and
# widths, the w:gridSpan / w:vMerge markers, the nested table's containment and
# tblW == sum(colWidths) (the portable construction), source protection, and
# reproducibility. A LibreOffice open-without-repair check runs through
# scripts/wf-compat-harness.sh when soffice is present; the renderer is reported
# as unverified when it is not.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/table.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLES="$ROOT/tests/fixtures/tables"
TOOL="$ROOT/scripts/wf-table.sh"
STYLES="$ROOT/scripts/wf-standard-styles.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -f "$TABLES/merged-table.docx" ]] || { echo "missing fixture: $TABLES/merged-table.docx" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/table.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() { # name haystack needle
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "'$2' does not contain '$3'"; fi
}

TMO="timeout 60"

tbl_field() { # tbl_field <file> <key>
  $TMO officecli get "$1" /body/tbl[1] --json | jq -r --arg k "$2" '.data.results[0].format[$k] // ""'
}
cell_field() { # cell_field <file> <path> <key>
  $TMO officecli get "$1" "$2" --json | jq -r --arg k "$3" '.data.results[0].format[$k] // ""'
}
sum_csv() { awk -F, '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%d", s}' <<<"$1"; }
no_dxa() { sed 's/dxa//g' <<<"$1"; }

defined_ids() {
  $TMO officecli get "$1" /styles --json \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}
referenced_ids() {
  $TMO officecli raw "$1" /document 2>/dev/null \
    | grep -oE 'w:(pStyle|rStyle) w:val="[^"]+"' \
    | sed -E 's/.*w:val="([^"]+)".*/\1/' | sort -u | paste -sd, -
}

new_doc() { # new_doc <path> <locale>
  local f="$1" loc="$2"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale "$loc" >/dev/null
}

cleanup() {
  for f in "$WORK"/*.docx; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

fixture_before_merged="$(sha256sum "$TABLES/merged-table.docx" | awk '{print $1}')"
fixture_before_nested="$(sha256sum "$TABLES/nested-table.docx" | awk '{print $1}')"

echo "Tables (#21) — $TABLES"
echo

# ---------------------------------------------------------------------------
# 1. The committed fixtures
# ---------------------------------------------------------------------------
assert_eq "fixture merged: layout fixed"    "$(tbl_field "$TABLES/merged-table.docx" layout)" "fixed"
assert_eq "fixture merged: colWidths"       "$(no_dxa "$(tbl_field "$TABLES/merged-table.docx" colWidths)")" "1701,1701,1700"
assert_eq "fixture merged: header-span gridSpan" "$(cell_field "$TABLES/merged-table.docx" /body/tbl[1]/tr[1]/tc[1] colspan)" "2"
assert_eq "fixture merged: vMerge restart"  "$(cell_field "$TABLES/merged-table.docx" /body/tbl[1]/tr[2]/tc[1] vmerge)" "restart"
assert_eq "fixture merged: vMerge continue" "$(cell_field "$TABLES/merged-table.docx" /body/tbl[1]/tr[3]/tc[1] vmerge)" "continue"
merged_raw="$($TMO officecli raw "$TABLES/merged-table.docx" /document 2>/dev/null)"
assert_contains "fixture merged: w:gridSpan in part" "$merged_raw" '<w:gridSpan w:val="2"'
assert_contains "fixture merged: w:vMerge in part"    "$merged_raw" '<w:vMerge w:val="restart"'

# Nested fixture: portable construction at both levels. cm->twips rounding is
# worth up to one twip, so the outer 12 cm table is compared with a small slack.
n_outer_w="$(tbl_field "$TABLES/nested-table.docx" width)"
n_outer_c="$(sum_csv "$(no_dxa "$(tbl_field "$TABLES/nested-table.docx" colWidths)")")"
n_outer_diff=$(( n_outer_w - n_outer_c )); if (( n_outer_diff < 0 )); then n_outer_diff=$(( -n_outer_diff )); fi
if (( n_outer_diff <= 2 )); then
  report_ok "fixture nested: outer tblW == sum(colWidths) ($n_outer_w ~ $n_outer_c)"
else
  report_fail "fixture nested: outer tblW == sum(colWidths)" "expected ~$n_outer_c, got $n_outer_w"
fi
assert_eq "fixture nested: inner path present" "$(cell_field "$TABLES/nested-table.docx" /body/tbl[1]/tr[2]/tc[1]/tbl[1] layout)" "fixed"
n_inner_w="$(cell_field "$TABLES/nested-table.docx" /body/tbl[1]/tr[2]/tc[1]/tbl[1] width)"
n_inner_c="$(sum_csv "$(no_dxa "$(cell_field "$TABLES/nested-table.docx" /body/tbl[1]/tr[2]/tc[1]/tbl[1] colWidths)")")"
assert_eq "fixture nested: inner tblW == sum(colWidths)" "$n_inner_w" "$n_inner_c"

# ---------------------------------------------------------------------------
# 2. Build a source document that defines the standard style set (#17)
# ---------------------------------------------------------------------------
base_src="$WORK/base-src.docx"; new_doc "$base_src" zh-CN
base="$WORK/base.docx"
"$STYLES" "$base_src" --out "$base" --json >/dev/null || report_fail "setup: standard styles" "wf-standard-styles.sh exited non-zero"
base_before="$(sha256sum "$base" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 3. Regular table through the operation
# ---------------------------------------------------------------------------
reg_out="$WORK/regular.docx"; reg_report="$WORK/regular-report.json"
reg_json="$("$TOOL" "$base" --out "$reg_out" \
  --data "Column A,Column B,Column C;A1,B1,C1;A2,B2,C2;A3,B3,C3" \
  --col-widths 1701,1701,1700 --width 9cm --header-row \
  --report "$reg_report" --json)" || report_fail "regular: run" "exited non-zero"
assert_eq "regular: source unchanged (report)" "$(jq -r '.source_unchanged' <<<"$reg_json")" "true"
assert_eq "regular: output grid cols"  "$(tbl_field "$reg_out" _gridCols)" "3"
assert_eq "regular: output rows"       "$(tbl_field "$reg_out" rows)" "4"
assert_eq "regular: output layout"     "$(tbl_field "$reg_out" layout)" "fixed"
assert_eq "regular: tblW == sum(colWidths)" "$(tbl_field "$reg_out" width)" "$(sum_csv "$(no_dxa "$(tbl_field "$reg_out" colWidths)")")"
assert_eq "regular: colWidths match request" "$(no_dxa "$(tbl_field "$reg_out" colWidths)")" "1701,1701,1700"
assert_eq "regular: header row repeats" "$(cell_field "$reg_out" /body/tbl[1]/tr[1] header)" "true"
if $TMO officecli validate "$reg_out" >/dev/null 2>&1; then
  report_ok "regular: output validates"
else
  report_fail "regular: output validates" "officecli validate failed"
fi
assert_eq "regular: change report valid" "$("$CHANGE_REPORT" validate --report "$reg_report" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
assert_eq "regular: no warnings" "$(jq -r '.warnings | length' "$reg_report")" "0"
assert_eq "regular: source bytes unchanged" "$(sha256sum "$base" | awk '{print $1}')" "$base_before"

# Standard-set styling: the table text carries BodyNoIndent, which is defined.
assert_contains "regular: cells use BodyNoIndent" "$($TMO officecli raw "$reg_out" /document 2>/dev/null)" 'w:pStyle w:val="BodyNoIndent"'
dangling="$(comm -23 <(referenced_ids "$reg_out" | tr ',' '\n' | sort -u) \
                     <(defined_ids "$reg_out" | tr ',' '\n' | sort -u) | paste -sd, -)"
assert_eq "regular: no dangling style" "$dangling" ""

# ---------------------------------------------------------------------------
# 4. Merged-cell table through the operation
# ---------------------------------------------------------------------------
mrg_out="$WORK/merged.docx"; mrg_report="$WORK/merged-report.json"
"$TOOL" "$base" --out "$mrg_out" \
  --data "Region,Quarter,Sales;North,Q1,100;,Q2,120;South,Q1,90" \
  --col-widths 1701,1701,1700 --merge 1,1,1,2 --merge 2,1,2,1 \
  --report "$mrg_report" --json >/dev/null || report_fail "merged: run" "exited non-zero"
assert_eq "merged: horizontal span kept"  "$(cell_field "$mrg_out" /body/tbl[1]/tr[1]/tc[1] colspan)" "2"
assert_eq "merged: vertical restart kept" "$(cell_field "$mrg_out" /body/tbl[1]/tr[2]/tc[1] vmerge)" "restart"
assert_eq "merged: vertical continue kept" "$(cell_field "$mrg_out" /body/tbl[1]/tr[3]/tc[1] vmerge)" "continue"
mrg_raw="$($TMO officecli raw "$mrg_out" /document 2>/dev/null)"
assert_contains "merged: w:gridSpan written" "$mrg_raw" '<w:gridSpan w:val="2"'
assert_contains "merged: w:vMerge written"   "$mrg_raw" '<w:vMerge w:val="restart"'
assert_eq "merged: tblW == sum(colWidths)" "$(tbl_field "$mrg_out" width)" "$(sum_csv "$(no_dxa "$(tbl_field "$mrg_out" colWidths)")")"
assert_eq "merged: source bytes unchanged" "$(sha256sum "$base" | awk '{print $1}')" "$base_before"

# ---------------------------------------------------------------------------
# 5. Nested table through the operation (portable) and the warning path
# ---------------------------------------------------------------------------
nst_out="$WORK/nested.docx"; nst_report="$WORK/nested-report.json"
nst_json="$("$TOOL" "$base" --out "$nst_out" \
  --data "Outer A,Outer B;nested cell,outer right;outer bottom 1,outer bottom 2" \
  --col-widths 3402,3402 --nested-cell 2,1 \
  --nested-data "Inner 1,Inner 2;Inner 3,Inner 4" --nested-col-widths 1418,1417 \
  --report "$nst_report" --json)" || report_fail "nested: run" "exited non-zero"
assert_eq "nested: present" "$(cell_field "$nst_out" /body/tbl[1]/tr[2]/tc[1]/tbl[1] layout)" "fixed"
assert_eq "nested: portable flag" "$(jq -r '.nested_table.portable' <<<"$nst_json")" "true"
assert_eq "nested: tblW == sum(colWidths)" \
  "$(cell_field "$nst_out" /body/tbl[1]/tr[2]/tc[1]/tbl[1] width)" \
  "$(sum_csv "$(no_dxa "$(cell_field "$nst_out" /body/tbl[1]/tr[2]/tc[1]/tbl[1] colWidths)")")"
assert_eq "nested: no warning when portable" "$(jq -r '.warnings | length' "$nst_report")" "0"
if $TMO officecli validate "$nst_out" >/dev/null 2>&1; then
  report_ok "nested: output validates"
else
  report_fail "nested: output validates" "officecli validate failed"
fi

# Autofit nesting cannot meet the portable construction -> D11 warning via the policy.
auto_out="$WORK/nested-autofit.docx"; auto_report="$WORK/nested-autofit-report.json"
"$TOOL" "$base" --out "$auto_out" \
  --data "Outer A,Outer B;nested cell,outer right" --col-widths 3402,3402 \
  --nested-cell 2,1 --nested-data "Inner 1,Inner 2" --nested-col-widths 1418,1417 \
  --nested-layout autofit --report "$auto_report" --json >/dev/null || report_fail "nested autofit: run" "exited non-zero"
assert_eq "nested autofit: not portable" "$(cell_field "$auto_out" /body/tbl[1]/tr[2]/tc[1]/tbl[1] layout)" "autofit"
auto_warn="$(jq -r '.warnings[0] // ""' "$auto_report")"
assert_contains "nested autofit: nested-table warning" "$auto_warn" "D11-nested-table"
assert_eq "nested autofit: report still valid" "$("$CHANGE_REPORT" validate --report "$auto_report" >/dev/null 2>&1 && echo ok || echo bad)" "ok"

# ---------------------------------------------------------------------------
# 6. Reproducibility: same source + instructions -> identical structure
# ---------------------------------------------------------------------------
sig() { # sig <file>
  { $TMO officecli get "$1" /body/tbl[1]
    $TMO officecli get "$1" /body/tbl[1]/tr[2]/tc[1]/tbl[1]
  } 2>/dev/null
}
rep_a="$WORK/repro-a.docx"; rep_b="$WORK/repro-b.docx"
for out in "$rep_a" "$rep_b"; do
  "$TOOL" "$base" --out "$out" \
    --data "Region,Quarter,Sales;North,Q1,100;,Q2,120;South,Q1,90" \
    --col-widths 1701,1701,1700 --merge 1,1,1,2 --merge 2,1,2,1 \
    --nested-cell 4,1 --nested-data "I1,I2;I3,I4" --nested-col-widths 1701,1700 >/dev/null \
    || report_fail "repro: build $out" "exited non-zero"
done
if diff <(sig "$rep_a") <(sig "$rep_b") >/dev/null 2>&1; then
  report_ok "reproducible: identical table structure"
else
  report_fail "reproducible: identical table structure" "two runs differ"
fi

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$base" >/dev/null 2>&1;                                             assert_eq "bad usage: missing --out exits 2"   "$?" "2"
"$TOOL" "$base" --out "$WORK/x.docx" >/dev/null 2>&1;                        assert_eq "bad usage: missing --data exits 2"  "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" --data "a,b" --col-widths 1,1 >/dev/null 2>&1; assert_eq "bad usage: missing source exits 2" "$?" "2"
"$TOOL" "$base" --out "$base" --data "a,b" --col-widths 1,1 >/dev/null 2>&1; assert_eq "bad usage: --out == source exits 2" "$?" "2"
"$TOOL" "$base" --out "$WORK/x.docx" --data "a,b" --col-widths 1,1 --width 9cm >/dev/null 2>&1; assert_eq "bad usage: width != sum(colWidths) exits 2" "$?" "2"
"$TOOL" "$base" --out "$WORK/x.docx" --data "a,b" --col-widths 1,1 --merge 1,1,9,1 >/dev/null 2>&1; assert_eq "bad usage: merge out of range exits 2" "$?" "2"

# ---------------------------------------------------------------------------
# 8. LibreOffice opens without repair (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$nst_out" --apps libreoffice --out "$compat_out" --no-visual >/dev/null 2>&1; then
    lo="$(jq -r '
      ( [ .records[]? | select(.app == "libreoffice") | .opens_without_repair ] | first )
      // ( [ .documents[]?.applications.libreoffice.opensWithoutRepair ] | first )
      // "unavailable"' "$compat_out/result.json" 2>/dev/null)"
    assert_eq "compat: LibreOffice opens without repair" "$lo" "true"
  else
    report_fail "compat: LibreOffice harness" "wf-compat-harness.sh did not produce a report"
  fi
else
  report_info "compat: LibreOffice verified — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 9. Source and fixture protection
# ---------------------------------------------------------------------------
assert_eq "source protection: style base unchanged" "$(sha256sum "$base" | awk '{print $1}')" "$base_before"
assert_eq "source protection: merged fixture unchanged" "$(sha256sum "$TABLES/merged-table.docx" | awk '{print $1}')" "$fixture_before_merged"
assert_eq "source protection: nested fixture unchanged" "$(sha256sum "$TABLES/nested-table.docx" | awk '{print $1}')" "$fixture_before_nested"

echo
echo "Table: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
