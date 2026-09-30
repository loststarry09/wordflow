#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow standard styles and Simplified-Chinese
# typography (#17).
#
# They exercise two things:
#
#   1. the committed fixture tests/fixtures/styles/standard-style-set.docx —
#      it defines the frozen standard style set (spec §D7), uses every style,
#      has no dangling reference, and carries the frozen §D6 typography;
#   2. the operation scripts/wf-standard-styles.sh — given a source it writes a
#      new output defining the same set, leaves the source untouched, is
#      reproducible, and rejects bad usage.
#
# It asserts what OfficeCLI reports back, not the exact commands run. A
# LibreOffice PDF render is checked when soffice is available; the renderer is
# reported as unverified when it is not.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/standard-styles.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/styles/standard-style-set.docx"
TEMPLATE="$ROOT/tests/fixtures/styles/template.docx"
TOOL="$ROOT/scripts/wf-standard-styles.sh"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -f "$FIX" ]] || { echo "missing fixture: $FIX" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/standard-styles.XXXXXX")"

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

# The frozen style set, sorted (spec §D7).
readonly EXPECTED_IDS="BodyNoIndent,Caption,Footer,FootnoteReference,FootnoteText,Header,Heading1,Heading2,Heading3,Heading4,Hyperlink,ListParagraph,Normal,Quote,TOC1,TOC2,TOC3,Title"

defined_ids() { # defined_ids <file>
  $TMO officecli get "$1" /styles --json \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}

# Full props of one style, cached per (file, styleId): `officecli get` spawns a
# process, so read each style once and reuse it across assertions.
STYLE_CACHE="$WORK/.style-cache"; mkdir -p "$STYLE_CACHE"
style_field() { # style_field <file> <styleId> <key>
  local f="$1" id="$2" k="$3" safe cache
  safe="$(printf '%s' "$f" | md5sum | cut -c1-8)_$id"
  cache="$STYLE_CACHE/$safe.json"
  [[ -f "$cache" ]] || $TMO officecli get "$f" "/styles/$id" --json >"$cache" 2>/dev/null || true
  jq -r --arg k "$k" '.data.results[0].format[$k] // ""' "$cache"
}

referenced_ids() { # referenced_ids <file> — pStyle/rStyle across every part
  local f="$1"
  { $TMO officecli raw "$f" /document
    $TMO officecli raw "$f" /footnotes
    $TMO officecli raw "$f" /header[1]
    $TMO officecli raw "$f" /footer[1]
  } 2>/dev/null \
    | grep -oE 'w:(pStyle|rStyle) w:val="[^"]+"' \
    | sed -E 's/.*w:val="([^"]+)".*/\1/' | sort -u | paste -sd, -
}

hint_count() { # hint_count <file> — explicit eastAsia hints in styles.xml
  $TMO officecli raw "$1" /styles 2>/dev/null | grep -o 'w:hint="eastAsia"' | wc -l | tr -d ' '
}

font_slots_ok() { # font_slots_ok <file> <styleId> — non-empty, never 等线
  local ea latin; ea="$(style_field "$1" "$2" font.ea)"; latin="$(style_field "$1" "$2" font.ascii)"
  [[ -n "$ea" && "$ea" != "等线" && -n "$latin" ]]
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

fixture_before="$(sha256sum "$FIX" | awk '{print $1}')"

echo "Standard styles (#17) — $FIX"
echo

# ---------------------------------------------------------------------------
# 1. The fixture defines exactly the frozen set, each style used, nothing dangling
# ---------------------------------------------------------------------------
assert_eq "fixture: exact frozen style set" "$(defined_ids "$FIX")" "$EXPECTED_IDS"
assert_eq "fixture: every style referenced"  "$(referenced_ids "$FIX")" "$EXPECTED_IDS"

dangling="$(comm -23 <(referenced_ids "$FIX" | tr ',' '\n' | sort -u) \
                     <(defined_ids "$FIX" | tr ',' '\n' | sort -u) | paste -sd, -)"
assert_eq "fixture: no dangling style" "$dangling" ""

assert_eq "fixture: Normal is the default" "$(style_field "$FIX" Normal default)" "true"

# ---------------------------------------------------------------------------
# 2. The frozen §D6 typography
# ---------------------------------------------------------------------------
assert_eq "Normal: CJK face"        "$(style_field "$FIX" Normal font.ea)"     "SimSun"
assert_eq "Normal: Latin face"      "$(style_field "$FIX" Normal font.ascii)"  "Times New Roman"
assert_eq "Normal: size"            "$(style_field "$FIX" Normal size)"        "12pt"
assert_eq "Normal: line spacing"    "$(style_field "$FIX" Normal lineSpacing)" "1.5x"
assert_eq "Normal: justified"       "$(style_field "$FIX" Normal align)"       "both"
assert_eq "Normal: first-line chars" "$(style_field "$FIX" Normal firstLineChars)" "200"
assert_eq "Normal: first-line length" "$(style_field "$FIX" Normal firstLineIndent)" "24pt"

assert_eq "BodyNoIndent: CJK face"  "$(style_field "$FIX" BodyNoIndent font.ea)" "SimSun"
assert_eq "BodyNoIndent: size"      "$(style_field "$FIX" BodyNoIndent size)"   "12pt"
assert_eq "BodyNoIndent: justified" "$(style_field "$FIX" BodyNoIndent align)"  "both"
assert_eq "BodyNoIndent: no indent" "$(style_field "$FIX" BodyNoIndent firstLineIndent)" "0pt"

assert_eq "Title: CJK face"    "$(style_field "$FIX" Title font.ea)"     "SimHei"
assert_eq "Title: Latin face"  "$(style_field "$FIX" Title font.ascii)"  "Arial"
assert_eq "Title: size"        "$(style_field "$FIX" Title size)"        "22pt"
assert_eq "Title: centred"     "$(style_field "$FIX" Title align)"       "center"
assert_eq "Title: no indent"   "$(style_field "$FIX" Title firstLineIndent)" "0pt"

# Headings: 黑体 sizes 16/14/13/12, Arial Latin, no indent, outline levels 0-3.
h_sizes=(16 14 13 12)
for i in 1 2 3 4; do
  assert_eq "Heading$i: CJK face"   "$(style_field "$FIX" "Heading$i" font.ea)"    "SimHei"
  assert_eq "Heading$i: Latin face" "$(style_field "$FIX" "Heading$i" font.ascii)" "Arial"
  assert_eq "Heading$i: size"       "$(style_field "$FIX" "Heading$i" size)"       "${h_sizes[$((i-1))]}pt"
  assert_eq "Heading$i: no indent"  "$(style_field "$FIX" "Heading$i" firstLineIndent)" "0pt"
  assert_eq "Heading$i: outline"    "$(style_field "$FIX" "Heading$i" outlineLvl)" "$((i-1))"
done

assert_eq "Caption: CJK face"  "$(style_field "$FIX" Caption font.ea)" "SimSun"
assert_eq "Caption: size"      "$(style_field "$FIX" Caption size)"    "10.5pt"
assert_eq "Caption: centred"   "$(style_field "$FIX" Caption align)"   "center"
assert_eq "FootnoteText: size" "$(style_field "$FIX" FootnoteText size)" "9pt"
assert_eq "FootnoteText: face" "$(style_field "$FIX" FootnoteText font.ea)" "SimSun"
assert_eq "Header: size"       "$(style_field "$FIX" Header size)"     "9pt"
assert_eq "Header: face"       "$(style_field "$FIX" Header font.ea)"  "SimSun"
assert_eq "Footer: size"       "$(style_field "$FIX" Footer size)"     "9pt"
assert_eq "Footer: face"       "$(style_field "$FIX" Footer font.ea)"  "SimSun"

assert_eq "Hyperlink: character style" "$(style_field "$FIX" Hyperlink type)"     "character"
assert_eq "Hyperlink: colour"          "$(style_field "$FIX" Hyperlink color)"    "#0563C1"
assert_eq "Hyperlink: underline"       "$(style_field "$FIX" Hyperlink underline)" "single"
assert_eq "FootnoteReference: character style" "$(style_field "$FIX" FootnoteReference type)" "character"
assert_eq "FootnoteReference: superscript"     "$(style_field "$FIX" FootnoteReference vertAlign)" "superscript"

# Every style sets its own font slots (never inherit docDefaults 等线).
font_fail=""
for id in $(printf '%s' "$EXPECTED_IDS" | tr ',' ' '); do
  font_slots_ok "$FIX" "$id" || font_fail+="$id "
done
assert_eq "fixture: explicit fonts on every style" "$font_fail" ""
assert_eq "fixture: eastAsia hint on every style"  "$(hint_count "$FIX")" "18"

# ---------------------------------------------------------------------------
# 3. LibreOffice render fidelity (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1 && command -v pdffonts >/dev/null 2>&1 \
   && command -v pdftotext >/dev/null 2>&1; then
  pdfdir="$WORK/pdf"; mkdir -p "$pdfdir"
  if $TMO soffice --headless "-env:UserInstallation=file://$WORK/lo" \
        --convert-to pdf --outdir "$pdfdir" "$FIX" >/dev/null 2>&1 && [[ -s "$pdfdir/standard-style-set.pdf" ]]; then
    report_ok "render: LibreOffice produced a PDF"
    fonts="$(pdffonts "$pdfdir/standard-style-set.pdf" 2>/dev/null)"
    if grep -q 'SimSun' <<<"$fonts"; then report_ok "render: body SimSun embedded"; else report_fail "render: body SimSun" "not embedded"; fi
    if grep -q 'SimHei' <<<"$fonts"; then report_ok "render: heading SimHei embedded"; else report_fail "render: heading SimHei" "not embedded"; fi
    # first-line indent must render: body starts right of the no-indent style
    bx="$(pdftotext -bbox "$pdfdir/standard-style-set.pdf" - 2>/dev/null | grep -m1 '正文段落' | sed -E 's/.*xMin="([0-9.]+)".*/\1/')"
    nx="$(pdftotext -bbox "$pdfdir/standard-style-set.pdf" - 2>/dev/null | grep -m1 '正文无缩进样式' | sed -E 's/.*xMin="([0-9.]+)".*/\1/')"
    if [[ -n "$bx" && -n "$nx" ]] && awk -v b="$bx" -v n="$nx" 'BEGIN { exit !(b >= n + 20) }'; then
      report_ok "render: body first-line indent ($bx > $nx)"
    else
      report_fail "render: body first-line indent" "body x='$bx', no-indent x='$nx'"
    fi
  else
    report_fail "render: LibreOffice" "soffice did not produce a PDF"
  fi
else
  report_info "render: LibreOffice verified — SKIPPED (soffice/pdftools not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 4. The operation: defines the set on a new output, source untouched
# ---------------------------------------------------------------------------
src="$WORK/src.docx"; new_doc "$src" zh-CN
src_before="$(sha256sum "$src" | awk '{print $1}')"
out="$WORK/out.docx"
json="$("$TOOL" "$src" --out "$out" --json)" || report_fail "operation: run" "exited non-zero"
assert_eq "operation: styles defined"  "$(jq -r '.styles_defined' <<<"$json")" "18"
assert_eq "operation: default style"   "$(jq -r '.default_style'  <<<"$json")" "Normal"
assert_eq "operation: source unchanged" "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "operation: output style set" "$(defined_ids "$out")" "$EXPECTED_IDS"
assert_eq "operation: Normal is default" "$(style_field "$out" Normal default)" "true"
assert_eq "operation: body face"        "$(style_field "$out" Normal font.ea)" "SimSun"

if $TMO officecli validate "$out" >/dev/null 2>&1; then
  report_ok "operation: output validates"
else
  report_fail "operation: output validates" "officecli validate failed"
fi

# source protection
assert_eq "operation: source bytes unchanged" "$(sha256sum "$src" | awk '{print $1}')" "$src_before"

# ---------------------------------------------------------------------------
# 5. The operation over an existing document (foreign styles are kept)
# ---------------------------------------------------------------------------
tpl_out="$WORK/from-template.docx"
"$TOOL" "$TEMPLATE" --out "$tpl_out" --json >/dev/null || report_fail "template: run" "exited non-zero"
missing="$(comm -23 <(printf '%s' "$EXPECTED_IDS" | tr ',' '\n' | sort) \
                     <(defined_ids "$tpl_out" | tr ',' '\n' | sort) | paste -sd, -)"
assert_eq "template: standard set present" "$missing" ""
assert_eq "template: body face overridden" "$(style_field "$tpl_out" Normal font.ea)" "SimSun"

# ---------------------------------------------------------------------------
# 6. Reproducibility: same source -> same style definitions
# ---------------------------------------------------------------------------
b="$WORK/repro-b.docx"
"$TOOL" "$src" --out "$b" --json >/dev/null
sig() { local f="$1" id; for id in Normal Title Heading1 Caption; do
  printf '%s=%s/%s/%s/%s;' "$id" "$(style_field "$f" "$id" font.ea)" "$(style_field "$f" "$id" size)" \
    "$(style_field "$f" "$id" lineSpacing)" "$(style_field "$f" "$id" firstLineIndent)"; done; }
assert_eq "reproducible: identical typography" "$(sig "$out")" "$(sig "$b")"

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$src" >/dev/null 2>&1;                                      assert_eq "bad usage: missing --out exits 2"     "$?" "2"
"$TOOL" "$src" --out "$src" >/dev/null 2>&1;                          assert_eq "bad usage: --out == source exits 2"   "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" >/dev/null 2>&1;       assert_eq "bad usage: missing source exits 2"    "$?" "2"

# ---------------------------------------------------------------------------
# 8. Source protection: the committed fixture is byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: fixture unchanged" "$(sha256sum "$FIX" | awk '{print $1}')" "$fixture_before"

echo
echo "Standard styles: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
