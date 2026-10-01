#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow headers/footers and page-numbers capability
# (#19, spec §D8/§D9/§D10).
#
# They exercise three things:
#
#   1. the committed fixtures tests/fixtures/headers/page-number-footer.docx and
#      tests/fixtures/headers/firstpage-oddeven.docx — they carry the portable
#      constructions (a live PAGE field; first/default/even parts);
#   2. the operation scripts/wf-headers.sh — given a source it builds the parts
#      on a new output, leaves the source untouched, is reproducible, records the
#      page-number-restart warning, and rejects bad usage;
#   3. the page number it produces is a non-placeholder PAGE field, and the
#      output opens without repair in LibreOffice when soffice is available.
#
# It asserts what OfficeCLI reports back, not the exact commands run. A
# LibreOffice repair-free open is read from the compatibility harness when
# soffice is present; otherwise the renderer is reported as unverified.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/headers.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_PAGENUM="$ROOT/tests/fixtures/headers/page-number-footer.docx"
FIX_ODDEVEN="$ROOT/tests/fixtures/headers/firstpage-oddeven.docx"
UNSTYLED="$ROOT/tests/fixtures/styles/unstyled.docx"
TOOL="$ROOT/scripts/wf-headers.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
for f in "$FIX_PAGENUM" "$FIX_ODDEVEN" "$UNSTYLED"; do
  [[ -f "$f" ]] || { echo "missing fixture: $f" >&2; exit 2; }
done

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/headers.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

TMO="timeout 60"

# --- OfficeCLI-observable helpers -------------------------------------------
part_types() { # part_types <file> <header|footer> -> sorted, comma-joined types
  $TMO officecli query "$1" "$2" --json 2>/dev/null \
    | jq -r '[.data.results[]?.format.type] | sort | join(",")' 2>/dev/null
}

part_text() { # part_text <file> <header|footer> <first|default|even>
  $TMO officecli query "$1" "$2" --json 2>/dev/null \
    | jq -r --arg t "$3" 'first(.data.results[]? | select(.format.type == $t) | .text) // ""' 2>/dev/null
}

field_count() { # field_count <file> <instruction>
  $TMO officecli query "$1" field --json 2>/dev/null \
    | jq -r --arg i "$2" '[.data.results[]? | select(.format.instruction == $i)] | length' 2>/dev/null
}

# No field cache may be a placeholder: the cached TEXT is what the reader sees.
placeholder_count() { # placeholder_count <file>
  $TMO officecli query "$1" field --json 2>/dev/null \
    | jq -r '[.data.results[]? | select((.text // "") | test("\u00ab|\u00bb|update field|placeholder|not evaluated"; "i"))] | length' 2>/dev/null
}

page_field_cached() { # page_field_cached <file> -> first PAGE field's cached text
  $TMO officecli query "$1" field --json 2>/dev/null \
    | jq -r 'first(.data.results[]? | select(.format.instruction == "PAGE") | .text) // ""' 2>/dev/null
}

section_value() { # section_value <file> <key> -> first non-null across sections
  $TMO officecli query "$1" section --json 2>/dev/null \
    | jq -r --arg k "$2" 'first(.data.results[]? | select(.format[$k] != null) | .format[$k]) // ""' 2>/dev/null
}

title_page() { # title_page <file>
  $TMO officecli query "$1" section --json 2>/dev/null \
    | jq -r 'any(.data.results[]?; .format.titlePage == true)' 2>/dev/null
}

odd_even() { # odd_even <file>
  $TMO officecli raw "$1" /settings 2>/dev/null | grep -q 'evenAndOddHeaders' && echo true || echo false
}

# The header/footer structure signature: part types and texts plus each field
# instruction (not its cache). Two runs of the same instructions must match.
structure_sig() { # structure_sig <file>
  local f="$1"
  {
    $TMO officecli query "$f" header --json 2>/dev/null \
      | jq -r '[.data.results[]? | {t: .format.type, x: .text}] | sort_by(.t) | .[] | "H:" + .t + ":" + .x'
    $TMO officecli query "$f" footer --json 2>/dev/null \
      | jq -r '[.data.results[]? | {t: .format.type, x: .text}] | sort_by(.t) | .[] | "F:" + .t + ":" + .x'
    $TMO officecli query "$f" field --json 2>/dev/null \
      | jq -r '[.data.results[]?.format.instruction] | sort | .[] | "FLD:" + .'
  } | paste -sd';' -
}

cleanup() {
  for f in "$WORK"/*.docx "$FIX_PAGENUM" "$FIX_ODDEVEN" "$UNSTYLED"; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

pagenum_before="$(sha256sum "$FIX_PAGENUM" | awk '{print $1}')"
oddeven_before="$(sha256sum "$FIX_ODDEVEN" | awk '{print $1}')"
unstyled_before="$(sha256sum "$UNSTYLED" | awk '{print $1}')"

echo "Headers/footers and page numbers (#19)"
echo

# ---------------------------------------------------------------------------
# 1. The committed fixtures carry the portable constructions
# ---------------------------------------------------------------------------
assert_eq "fixture page-number-footer: default footer part" "$(part_types "$FIX_PAGENUM" footer)" "default"
assert_eq "fixture page-number-footer: no header part"      "$(part_types "$FIX_PAGENUM" header)" ""
assert_eq "fixture page-number-footer: one PAGE field"      "$(field_count "$FIX_PAGENUM" PAGE)" "1"
assert_eq "fixture page-number-footer: PAGE cache present"  "$(page_field_cached "$FIX_PAGENUM")" "1"
assert_eq "fixture page-number-footer: no placeholder"      "$(placeholder_count "$FIX_PAGENUM")" "0"

assert_eq "fixture firstpage-oddeven: first/default/even headers" "$(part_types "$FIX_ODDEVEN" header)" "default,even,first"
assert_eq "fixture firstpage-oddeven: first/default/even footers" "$(part_types "$FIX_ODDEVEN" footer)" "default,even,first"
assert_eq "fixture firstpage-oddeven: three PAGE fields"          "$(field_count "$FIX_ODDEVEN" PAGE)" "3"
assert_eq "fixture firstpage-oddeven: titlePg"                    "$(title_page "$FIX_ODDEVEN")" "true"
assert_eq "fixture firstpage-oddeven: evenAndOddHeaders"          "$(odd_even "$FIX_ODDEVEN")" "true"
assert_eq "fixture firstpage-oddeven: no placeholder"             "$(placeholder_count "$FIX_ODDEVEN")" "0"

# ---------------------------------------------------------------------------
# 2. Operation on an arbitrary unstyled source: header + footer + page number
# ---------------------------------------------------------------------------
out="$WORK/unstyled-out.docx"
rep="$WORK/unstyled-report.json"
json="$("$TOOL" "$UNSTYLED" --out "$out" --header "页眉 Header" --footer "Page " \
        --page-number --report "$rep" --json)" || report_fail "operation: run" "exited non-zero"
assert_eq "operation: source_unchanged true" "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "operation: default header part"   "$(part_types "$out" header)" "default"
assert_eq "operation: default footer part"   "$(part_types "$out" footer)" "default"
assert_eq "operation: header text"           "$(part_text "$out" header default)" "页眉 Header"
assert_eq "operation: footer text"           "$(part_text "$out" footer default)" "Page 1 of 1"
assert_eq "operation: one PAGE field"        "$(field_count "$out" PAGE)" "1"
assert_eq "operation: one NUMPAGES field"    "$(field_count "$out" NUMPAGES)" "1"
assert_eq "operation: PAGE cache non-placeholder" "$(page_field_cached "$out")" "1"
assert_eq "operation: no placeholder fields" "$(placeholder_count "$out")" "0"
assert_eq "operation: no spurious warnings"  "$(jq -r '.warnings | length' <<<"$json")" "0"
assert_eq "operation: change_report present" "$(jq -r '[.change_report[] | select(test("header|footer"; "i"))] | length > 0' <<<"$json")" "true"

if $TMO officecli validate "$out" >/dev/null 2>&1; then
  report_ok "operation: output validates"
else
  report_fail "operation: output validates" "officecli validate failed"
fi

assert_eq "report file: warnings empty for supported features" \
  "$(jq -r '.warnings | length' "$rep" 2>/dev/null)" "0"

# ---------------------------------------------------------------------------
# 3. A first/even run yields first/default/even parts (no warning — §D9 full)
# ---------------------------------------------------------------------------
oe_out="$WORK/oddeven-out.docx"
oe_rep="$WORK/oddeven-report.json"
oe_json="$("$TOOL" "$UNSTYLED" --out "$oe_out" \
            --header "ODD" --footer "Page " \
            --header-first "FIRST H" --footer-first "FIRST F " \
            --header-even "EVEN H" --footer-even "EVEN F " \
            --page-number --report "$oe_rep" --json)" || report_fail "first/even: run" "exited non-zero"
assert_eq "first/even: first/default/even headers" "$(part_types "$oe_out" header)" "default,even,first"
assert_eq "first/even: first/default/even footers" "$(part_types "$oe_out" footer)" "default,even,first"
assert_eq "first/even: first header text"          "$(part_text "$oe_out" header first)" "FIRST H"
assert_eq "first/even: even header text"           "$(part_text "$oe_out" header even)" "EVEN H"
assert_eq "first/even: titlePg"                    "$(title_page "$oe_out")" "true"
assert_eq "first/even: evenAndOddHeaders"          "$(odd_even "$oe_out")" "true"
assert_eq "first/even: no first-odd-even warning" \
  "$(jq -r '[.warnings[] | select(test("first-odd-even|first page|odd/even"; "i"))] | length' <<<"$oe_json")" "0"
assert_eq "first/even: source_unchanged true"      "$(jq -r '.source_unchanged' <<<"$oe_json")" "true"

# ---------------------------------------------------------------------------
# 4. A --restart run records the page-number-restart warning (LIMITED)
# ---------------------------------------------------------------------------
rs_out="$WORK/restart-out.docx"
rs_rep="$WORK/restart-report.json"
rs_json="$("$TOOL" "$UNSTYLED" --out "$rs_out" --footer "Page " --page-number \
            --restart 5 --report "$rs_rep" --json)" || report_fail "restart: run" "exited non-zero"
assert_eq "restart: report warns page-number-restart" \
  "$(jq -r '[.warnings[] | select(test("D11-page-number-restart"))] | length' <<<"$rs_json")" "1"
assert_eq "restart: change_report carries the warning" \
  "$(jq -r '[.change_report[] | select(test("D11-page-number-restart"))] | length' <<<"$rs_json")" "1"
assert_eq "restart: warning also in the report file" \
  "$(jq -r '[.warnings[] | select(test("D11-page-number-restart"))] | length' "$rs_rep" 2>/dev/null)" "1"
assert_eq "restart: section pageStart applied" "$(section_value "$rs_out" pageStart)" "5"
assert_eq "restart: source_unchanged true"     "$(jq -r '.source_unchanged' <<<"$rs_json")" "true"

# ---------------------------------------------------------------------------
# 5. Fixture-driven runs: the script reproduces the committed constructions
# ---------------------------------------------------------------------------
pn_src="$WORK/pn-src.docx"; cp "$FIX_PAGENUM" "$pn_src"
pn_out="$WORK/pn-out.docx"
"$TOOL" "$pn_src" --out "$pn_out" --page-number --report "$WORK/pn-report.json" --json >/dev/null \
  || report_fail "fixture run: page-number-footer" "exited non-zero"
assert_eq "fixture run: PAGE not duplicated" "$(field_count "$pn_out" PAGE)" "1"
assert_eq "fixture run: page-number footer kept" "$(part_text "$pn_out" footer default)" "1"

oe_src="$WORK/oe-src.docx"; cp "$FIX_ODDEVEN" "$oe_src"
oe2_out="$WORK/oe2-out.docx"
"$TOOL" "$oe_src" --out "$oe2_out" --header-first "FIRST-PAGE HEADER" \
  --header "ODD-PAGE HEADER" --header-even "EVEN-PAGE HEADER" \
  --page-number --report "$WORK/oe2-report.json" --json >/dev/null \
  || report_fail "fixture run: firstpage-oddeven" "exited non-zero"
assert_eq "fixture run: headers preserved" "$(part_types "$oe2_out" header)" "default,even,first"
assert_eq "fixture run: three PAGE fields" "$(field_count "$oe2_out" PAGE)" "3"

# ---------------------------------------------------------------------------
# 6. Reproducibility: same source + same instructions -> same structure
# ---------------------------------------------------------------------------
a="$WORK/repro-a.docx"; b="$WORK/repro-b.docx"
"$TOOL" "$UNSTYLED" --out "$a" --header "页眉 Header" --footer "Page " --page-number \
  --report "$WORK/repro-a.json" --json >/dev/null
"$TOOL" "$UNSTYLED" --out "$b" --header "页眉 Header" --footer "Page " --page-number \
  --report "$WORK/repro-b.json" --json >/dev/null
assert_eq "reproducible: identical header/footer structure" "$(structure_sig "$a")" "$(structure_sig "$b")"

# ---------------------------------------------------------------------------
# 7. Open without repair in LibreOffice (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$oe_out" --apps libreoffice --out "$compat_out" --no-visual >/dev/null 2>&1 \
     && [[ -f "$compat_out/result.json" ]]; then
    # The harness schema has carried both shapes; read the issue's documented
    # path first, then the current records[] shape.
    owr="$(jq -r '
      ( (.documents[]?.applications.libreoffice.opensWithoutRepair) //
        (.records[]? | select(.app == "libreoffice") | .opens_without_repair) // empty )
    ' "$compat_out/result.json" 2>/dev/null | head -n1)"
    if [[ "$owr" == "true" ]]; then
      report_ok "compat: LibreOffice opensWithoutRepair"
    else
      report_fail "compat: LibreOffice opensWithoutRepair" "got '$owr'"
    fi
  else
    report_fail "compat: LibreOffice harness" "no result.json"
  fi
else
  report_info "compat: LibreOffice open verified — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 8. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$UNSTYLED" >/dev/null 2>&1;                                                   assert_eq "bad usage: missing --out exits 2" "$?" "2"
"$TOOL" "$UNSTYLED" --out "$UNSTYLED" >/dev/null 2>&1;                                 assert_eq "bad usage: --out == source exits 2" "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" --header X >/dev/null 2>&1;             assert_eq "bad usage: missing source exits 2" "$?" "2"
"$TOOL" "$UNSTYLED" --out "$WORK/x.docx" >/dev/null 2>&1;                              assert_eq "bad usage: no action exits 2" "$?" "2"
"$TOOL" "$UNSTYLED" --out "$WORK/x.docx" --footer F --restart 0 >/dev/null 2>&1;       assert_eq "bad usage: --restart 0 exits 2" "$?" "2"
"$TOOL" "$UNSTYLED" --out "$WORK/x.docx" --footer F --restart abc >/dev/null 2>&1;     assert_eq "bad usage: --restart abc exits 2" "$?" "2"

# ---------------------------------------------------------------------------
# 9. Source protection: every input is byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: fixture page-number-footer unchanged" "$(sha256sum "$FIX_PAGENUM" | awk '{print $1}')" "$pagenum_before"
assert_eq "source protection: fixture firstpage-oddeven unchanged"  "$(sha256sum "$FIX_ODDEVEN" | awk '{print $1}')" "$oddeven_before"
assert_eq "source protection: unstyled source unchanged"            "$(sha256sum "$UNSTYLED" | awk '{print $1}')" "$unstyled_before"

echo
echo "Headers: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
