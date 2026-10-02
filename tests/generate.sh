#!/usr/bin/env bash
#
# Acceptance tests for the generate-from-content workflow (#32, spec §D4).
#
# These tests exercise the *external behaviour* of scripts/wf-pipeline.sh in
# generate mode: given text/Markdown content (and optional template /
# formatting requirement), one run produces a complete, new .docx that:
#
#   - maps headings/body to WordFlow styles and creates heading bookmarks;
#   - composes the feature capabilities (headers/footers/page numbers, image,
#     table, caption, cross-reference, footnote, equation, TOC) rather than
#     reimplementing them;
#   - applies the D2 precedence (requirement > template > standard styles);
#   - leaves the content source byte-identical and writes a collision-safe name;
#   - passes the #31 Definition of Done (scripts/wf-qa.sh).
#
# They assert what a reader would see and what the report says, not the
# OfficeCLI commands the pipeline runs internally.
#
# Requirements: officecli >= 1.0.153, jq, sha256sum, cp on PATH; soffice +
# pdftoppm for the preview. Usage: tests/generate.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-pipeline.sh"
QA="$ROOT/scripts/wf-qa.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
IMG="$ROOT/tests/fixtures/assets/test-image.png"
TPL="$ROOT/tests/fixtures/styles/standard-style-set.docx"
OUTROOT="$ROOT/tests/.out/generate"

for bin in officecli jq sha256sum cp; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for t in "$TOOL" "$QA" "$CHANGE_REPORT"; do
  [[ -x "$t" ]] || { echo "missing or non-executable: $t" >&2; exit 2; }
done
[[ -f "$IMG" ]] || { echo "missing image asset: $IMG" >&2; exit 2; }
[[ -f "$TPL" ]] || { echo "missing template fixture: $TPL" >&2; exit 2; }

rm -rf "$OUTROOT"; mkdir -p "$OUTROOT" "$OUTROOT/work"

pass=0; fail=0
declare -a failures=()
report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "missing '$3' in '$2'"; fi
}
assert_nonzero() {
  if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 )); then report_ok "$1"; else report_fail "$1" "expected > 0, got '$2'"; fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }
close() { officecli close "$1" >/dev/null 2>&1 || true; }

# independent_dangling <docx> -> referenced styles with no definition (id OR name).
independent_dangling() {
  local doc="$1" styles stats defined referenced
  styles="$(officecli get "$doc" /styles --json 2>/dev/null || echo '{}')"
  stats="$(officecli view "$doc" stats --json 2>/dev/null || echo '{}')"
  defined="$(jq -r '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | .[] | ascii_downcase' <<<"$styles" 2>/dev/null || true)"
  referenced="$(jq -r '.data.styleDistribution // {} | keys[] | ascii_downcase' <<<"$stats" 2>/dev/null || true)"
  awk 'NR==FNR{if($0!="")d[$0]=1;next} $0!="" && !($0 in d){c++} END{print c+0}' \
    <(printf '%s\n' "$defined") <(printf '%s\n' "$referenced")
}
placeholder_fields() {
  officecli query "$1" field --json 2>/dev/null \
    | jq -r '[.data.results[]? | select((.format.instruction // "") | test("PAGE|NUMPAGES|PAGEREF"; "i") | not) | select((.text // "") | test("«|»|update field|placeholder"; "i"))] | length' 2>/dev/null || echo 0
}
layout_digest() {
  officecli get "$1" /styles --json 2>/dev/null \
    | jq -S '[.data.results[0].children[]? | select(.type=="style") | {id:.format.styleId, name:.format.name, format:.format}]'
  officecli query "$1" section --json 2>/dev/null | jq -S '[.data.results[]? | {format:.format}]'
}
field_by_instr() { # <docx> <regex> -> cached text of the last matching field
  officecli query "$1" field --json 2>/dev/null \
    | jq -r --arg re "$2" '[.data.results[]? | select((.format.instruction // "") | test($re))] | last | .text // ""'
}
para_style() { # <docx> <path> -> the paragraph's style
  officecli get "$1" "$2" --json 2>/dev/null \
    | jq -r '.data.results[0].format.style // .data.results[0].style // ""'
}

echo "Generate-from-content (#32) — $TOOL"

CONTENT="$OUTROOT/work/doc.md"
cat > "$CONTENT" <<'EOF'
# Introduction {#intro}

This is the first body paragraph of the document.

## Methods {#methods}

The methods section body text.

### Details {#details}

A details paragraph.
EOF
CONTENT_SHA_BEFORE="$(sha "$CONTENT")"

# ===========================================================================
# A. Baseline: content -> a styled, bookmarked document.
# ===========================================================================
A="$OUTROOT/baseline"; mkdir -p "$A"
"$TOOL" --content "$CONTENT" --out-dir "$A" --title "WordFlow Generate" --no-preview --json > "$A/run.json" 2>"$A/run.err"
assert_eq "baseline: exit 0" "$?" "0"
aj="$(cat "$A/run.json")"
assert_eq "baseline: status delivered" "$(jq -r '.status' <<<"$aj")" "delivered"
assert_eq "baseline: mode generate"    "$(jq -r '.mode' <<<"$aj")" "generate"
assert_eq "baseline: decision"         "$(jq -r '.decision' <<<"$aj")" "generate-from-content"
a_out="$(jq -r '.output' <<<"$aj")"
assert_eq "baseline: default name"     "$(basename "$a_out")" "doc-排版.docx"
assert_eq "baseline: source unchanged" "$(jq -r '.source_unchanged' <<<"$aj")" "true"
assert_eq "baseline: content bytes unchanged" "$(sha "$CONTENT")" "$CONTENT_SHA_BEFORE"

# styles: Title on p[1], headings on the heading paragraphs.
assert_eq "baseline: Title on p[1]"    "$(para_style "$a_out" /body/p[1])" "Title"
assert_eq "baseline: Heading1 on p[2]" "$(para_style "$a_out" /body/p[2])" "Heading1"
assert_eq "baseline: Heading2 on p[4]" "$(para_style "$a_out" /body/p[4])" "Heading2"
assert_eq "baseline: Heading3 on p[6]" "$(para_style "$a_out" /body/p[6])" "Heading3"
a_bm="$(officecli query "$a_out" bookmark --json 2>/dev/null)"
assert_eq "baseline: three heading bookmarks" "$(jq -r '.data.matches // 0' <<<"$a_bm")" "3"
for name in intro methods details; do
  assert_eq "baseline: bookmark $name" "$(jq -r --arg n "$name" '[.data.results[]? | select(.format.name == $n or (.path | test($n)))] | length' <<<"$a_bm")" "1"
done
assert_eq "baseline: no dangling style"    "$(independent_dangling "$a_out")" "0"
assert_eq "baseline: no placeholder field" "$(placeholder_fields "$a_out")" "0"
assert_eq "baseline: validates" "$(officecli validate "$a_out" --json 2>/dev/null | jq -r '.success // false')" "true"
a_plan="$(jq -r '.artifacts.plan' <<<"$aj")"
assert_eq "baseline: plan mode generate" "$(jq -r '.mode' "$a_plan")" "generate"
assert_eq "baseline: plan style set standard" "$(jq -r '.style.set' "$a_plan")" "standard"
assert_eq "baseline: plan authority standard-styles" "$(jq -r '.style.source' "$a_plan")" "standard-styles"
a_rep="$(jq -r '.artifacts.report_json' <<<"$aj")"
assert_eq "baseline: report validates" "$("$CHANGE_REPORT" validate --report "$a_rep" >/dev/null 2>&1 && echo true || echo false)" "true"
assert_eq "baseline: report has five areas" "$(jq -r '([.changed,.decisions,.warnings,.downgrades,.unverified]|map(type=="array")|all)' "$a_rep")" "true"
close "$a_out"

# ===========================================================================
# B. Composition: one run composes every feature capability.
# ===========================================================================
B="$OUTROOT/composed"; mkdir -p "$B"
"$TOOL" --content "$CONTENT" --out-dir "$B" --title "WordFlow Compose" \
  --header "WF Header" --footer "WF Footer" --page-number \
  --image "$IMG" --image-para /body/p[3] --image-alt "figure" \
  --table-data "Name,Value;Alpha,1;Beta,2" --table-widths "3000,3000" --table-header-row \
  --caption "Results table" --caption-kind table --caption-para /body/p[3] \
  --xref intro --xref-para /body/p[3] \
  --footnote "A footnote on the body." --footnote-para /body/p[3] \
  --equation "E = mc^2" --equation-mode display \
  --toc --no-preview --json > "$B/run.json" 2>"$B/run.err"
assert_eq "compose: exit 0" "$?" "0"
bj="$(cat "$B/run.json")"
b_out="$(jq -r '.output' <<<"$bj")"
assert_eq "compose: source unchanged" "$(jq -r '.source_unchanged' <<<"$bj")" "true"
assert_eq "compose: no dangling style"    "$(independent_dangling "$b_out")" "0"
assert_eq "compose: no placeholder field" "$(placeholder_fields "$b_out")" "0"

# headers / footers / page numbers (#19)
assert_nonzero "compose: header present" "$(officecli query "$b_out" header --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_nonzero "compose: footer present" "$(officecli query "$b_out" footer --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_nonzero "compose: PAGE field" "$(officecli query "$b_out" field --json 2>/dev/null | jq -r '[.data.results[]? | select(.format.instruction == "PAGE")] | length')"
assert_nonzero "compose: NUMPAGES field" "$(officecli query "$b_out" field --json 2>/dev/null | jq -r '[.data.results[]? | select(.format.instruction == "NUMPAGES")] | length')"
assert_contains "compose: header text" "$(officecli query "$b_out" header --json 2>/dev/null | jq -r '[.data.results[]?.text] | join(" ")')" "WF Header"
assert_contains "compose: footer text" "$(officecli query "$b_out" footer --json 2>/dev/null | jq -r '[.data.results[]?.text] | join(" ")')" "WF Footer"

# image (#20), table (#21)
assert_eq "compose: one image" "$(officecli query "$b_out" picture --json 2>/dev/null | jq -r '.data.matches // 0')" "1"
assert_eq "compose: one table" "$(officecli get "$b_out" /body/tbl[1] --json 2>/dev/null | jq -r '(.success // false)')" "true"

# caption (#22): a SEQ field with a correct, non-placeholder cached number.
assert_nonzero "compose: caption SEQ field" "$(officecli query "$b_out" field --json 2>/dev/null | jq -r '[.data.results[]? | select((.format.instruction // "") | test("SEQ"))] | length')"
assert_eq "compose: Caption style defined" "$(officecli get "$b_out" /styles --json 2>/dev/null | jq -r '[.data.results[0].children[]? | select(.format.styleId=="Caption" or .format.name=="Caption")] | length')" "1"

# cross-reference (#23): a REF field cached with the resolved target text.
assert_eq "compose: REF cached text resolves" "$(field_by_instr "$b_out" '^REF')" "Introduction"
assert_eq "compose: no placeholder REF" "$(field_by_instr "$b_out" '^REF' | grep -c '«\|»' || true)" "0"

# footnote (#25), equation (#26), TOC (#24)
assert_nonzero "compose: footnote present" "$(officecli query "$b_out" footnote --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_nonzero "compose: equation present" "$(officecli query "$b_out" equation --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_eq "compose: equation is a display equation" "$(officecli query "$b_out" equation --json 2>/dev/null | jq -r '[.data.results[]?.format.mode] | join(",")')" "display"
assert_nonzero "compose: TOC field" "$(officecli query "$b_out" toc --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_eq "compose: TOC has no page numbers" \
  "$(officecli query "$b_out" toc --json 2>/dev/null | jq -r '[.data.results[]? | ((.format.pageNumbers // false) == false) and (((.text // "") | test("\\\\n")) | not)] | all')" "true"

# The single report folds in every feature's entries.
b_rep="$(jq -r '.artifacts.report_json' <<<"$bj")"
assert_eq "compose: report validates" "$("$CHANGE_REPORT" validate --report "$b_rep" >/dev/null 2>&1 && echo true || echo false)" "true"
assert_nonzero "compose: report notes feature composition" "$(jq -r '[.changed[]? | select(test("Feature composition"))] | length' "$b_rep")"
assert_nonzero "compose: report states TOC page numbers omitted" "$(jq -r '[.unverified[]? | select(test("page numbers are intentionally omitted"))] | length' "$b_rep")"
assert_eq "compose: source unchanged (JSON)" "$(jq -r '.source_unchanged' <<<"$bj")" "true"

# Definition of Done (D14) over the composed output.
b_plan="$(jq -r '.artifacts.plan' <<<"$bj")"
GJ="$("$QA" --output "$b_out" --plan "$b_plan" --report "$b_rep" --no-compat --json 2>/dev/null)"
assert_eq "compose: QA ok (D14)" "$(jq -r '.ok' <<<"$GJ")" "true"
assert_eq "compose: QA no failures" "$(jq -r '.summary.fail' <<<"$GJ")" "0"
if command -v soffice >/dev/null 2>&1; then
  GJC="$("$QA" --output "$b_out" --plan "$b_plan" --report "$b_rep" --apps libreoffice --json 2>/dev/null)"
  assert_eq "compose: opens without repair (LibreOffice)" \
    "$(jq -r '[.checks[] | select(.id=="opens-without-repair") | .status] | first' <<<"$GJC")" "pass"
else
  report_ok "compose: LibreOffice compat skipped (soffice absent)"
fi
close "$b_out"

# ===========================================================================
# C. Precedence: a template outranks the standard styles; a requirement
#    outranks both (spec §D2).
# ===========================================================================
C="$OUTROOT/template"; mkdir -p "$C"
REQ="$C/req.txt"
printf 'body.size = 14pt\nmarginTop = 3cm\n' > "$REQ"
"$TOOL" --content "$CONTENT" --out-dir "$C" --template "$TPL" --requirement "$REQ" --no-preview --json > "$C/run.json" 2>"$C/run.err"
assert_eq "template: exit 0" "$?" "0"
cj="$(cat "$C/run.json")"
c_out="$(jq -r '.output' <<<"$cj")"
c_plan="$(jq -r '.artifacts.plan' <<<"$cj")"
c_rep="$(jq -r '.artifacts.report_json' <<<"$cj")"
assert_eq "template: plan style set template" "$(jq -r '.style.set' "$c_plan")" "template"
assert_eq "template: requirement is authoritative" "$(jq -r '.style.source' "$c_plan")" "formatting-requirement"
# template content must never leak into a generate job.
assert_eq "template: template content absent" "$(officecli view "$c_out" text 2>/dev/null | grep -c '标准样式集' || true)" "0"
assert_contains "template: content preserved" "$(officecli view "$c_out" text 2>/dev/null)" "Introduction"
assert_nonzero "template: report records template adoption" "$(jq -r '[.decisions[]? | select(test("template"; "i"))] | length' "$c_rep")"
assert_nonzero "template: report records the requirement override" "$(jq -r '[.decisions[]? | select(test("Formatting requirement"))] | length' "$c_rep")"
assert_eq "template: source unchanged" "$(jq -r '.source_unchanged' <<<"$cj")" "true"
assert_eq "template: validates" "$(officecli validate "$c_out" --json 2>/dev/null | jq -r '.success // false')" "true"
close "$c_out"

# A requirement without a template is recorded, never silently dropped.
D="$OUTROOT/requirement"; mkdir -p "$D"
"$TOOL" --content "$CONTENT" --out-dir "$D" --requirement "$REQ" --no-preview --json > "$D/run.json" 2>"$D/run.err"; d_rc=$?
dj="$(cat "$D/run.json")"
d_rep="$(jq -r '.artifacts.report_json' <<<"$dj")"
assert_eq "requirement: exit 0" "$d_rc" "0"
assert_nonzero "requirement: no template path records it unverified" "$(jq -r '[.unverified[]? | select(test("formatting-requirement"))] | length' "$d_rep")"
close "$(jq -r '.output' <<<"$dj")"

# ===========================================================================
# E. Collision numbering: a second run in the same directory is numbered.
# ===========================================================================
"$TOOL" --content "$CONTENT" --out-dir "$A" --title "WordFlow Generate" --no-preview --json > "$A/run2.json" 2>/dev/null; e2_rc=$?
e2="$(cat "$A/run2.json")"
assert_eq "collision: exit 0" "$e2_rc" "0"
assert_eq "collision: numbered name" "$(basename "$(jq -r '.output' <<<"$e2")")" "doc-排版 (2).docx"
assert_eq "collision: collision_index" "$(jq -r '.collision.collision_index' <<<"$e2")" "2"
assert_eq "collision: content still unchanged" "$(sha "$CONTENT")" "$CONTENT_SHA_BEFORE"
close "$(jq -r '.output' <<<"$e2")"

# ===========================================================================
# F. Refusals: an unreadable content source stops and asks (D11).
# ===========================================================================
F="$OUTROOT/stop"; mkdir -p "$F"
f_err="$("$TOOL" --content "$F/missing.md" --out-dir "$F" 2>&1 >/dev/null)"; f_rc=$?
assert_eq "stop: missing content is a usage error (2)" "$f_rc" "2"
assert_contains "stop: missing content names the file" "$f_err" "content not found"
printf 'content\n' > "$F/unreadable.md"; chmod 000 "$F/unreadable.md"
f2_err="$("$TOOL" --content "$F/unreadable.md" --out-dir "$F" 2>&1 >/dev/null)"; f2_rc=$?
chmod 644 "$F/unreadable.md"
assert_eq "stop: unreadable content exits 3" "$f2_rc" "3"
assert_contains "stop: unreadable content asks the user" "$f2_err" "ask the user"
assert_eq "stop: no output produced" "$(find "$F" -name '*-排版*.docx' | wc -l | tr -d ' ')" "0"

# ===========================================================================
# G. Reproducibility: same content + instructions -> same layout.
# ===========================================================================
for n in 1 2; do
  R="$OUTROOT/repro$n"; mkdir -p "$R"
  "$TOOL" --content "$CONTENT" --out-dir "$R" --title "Repro" --no-preview --json > "$R/run.json" 2>/dev/null
  layout_digest "$(jq -r '.output' "$R/run.json")" > "$R/digest.txt"
  jq -S '.report | {changed,decisions,warnings,downgrades,unverified}' "$(jq -r '.artifacts.report_json' "$R/run.json")" > "$R/areas.json"
  close "$(jq -r '.output' "$R/run.json")"
done
if diff -q "$OUTROOT/repro1/digest.txt" "$OUTROOT/repro2/digest.txt" >/dev/null 2>&1; then
  report_ok "reproducible: identical layout digest"
else
  report_fail "reproducible: identical layout digest" "style/section digests differ"
fi
if diff -q "$OUTROOT/repro1/areas.json" "$OUTROOT/repro2/areas.json" >/dev/null 2>&1; then
  report_ok "reproducible: identical report areas"
else
  report_fail "reproducible: identical report areas" "report areas differ"
fi

echo
echo "Generate: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Artifacts: $OUTROOT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
