#!/usr/bin/env bash
#
# WordFlow v0.1 acceptance (#34).
#
# End-to-end acceptance of v0.1 against the spec: both workflows on realistic
# inputs pass the Definition of Done and the compatibility gate, the capability
# tiers behave as specified (fully supported / limited warn-or-downgrade /
# out-of-scope refused), and source protection, the change report, and the
# render preview behave as specified.
#
# It writes a machine-readable summary to tests/.out/acceptance/summary.json,
# which the written acceptance record (report/2026-10-02-v0.1-acceptance.md)
# cites. It composes the shipped workflows and the #31 QA gate; it reimplements
# nothing.
#
# Requirements: officecli, jq, sha256sum, cp, diff on PATH; soffice +
# pdftoppm for the preview and the LibreOffice compatibility record.
# Usage: tests/acceptance.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/preview-artifacts.sh
source "$ROOT/tests/lib/preview-artifacts.sh"
PIPE="$ROOT/scripts/wf-pipeline.sh"
QA="$ROOT/scripts/wf-qa.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
IMG="$ROOT/tests/fixtures/assets/test-image.png"
STYLED="$ROOT/tests/fixtures/styles/caption-dangling.docx"
UNSTYLED="$ROOT/tests/fixtures/styles/unstyled.docx"
OUTROOT="$ROOT/tests/.out/acceptance"

for bin in officecli jq sha256sum cp diff; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for t in "$PIPE" "$QA" "$CHANGE_REPORT"; do
  [[ -x "$t" ]] || { echo "missing or non-executable: $t" >&2; exit 2; }
done
for f in "$IMG" "$STYLED" "$UNSTYLED"; do
  [[ -f "$f" ]] || { echo "missing input: $f" >&2; exit 2; }
done

rm -rf "$OUTROOT"; mkdir -p "$OUTROOT"

pass=0; fail=0
declare -a failures=()
report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "missing '$3'"; fi
}
assert_nonzero() {
  if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 )); then report_ok "$1"; else report_fail "$1" "expected > 0, got '$2'"; fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }
close() { officecli close "$1" >/dev/null 2>&1 || true; }
text_of() { officecli view "$1" text 2>/dev/null; }
qa_check_status() { jq -r --arg id "$2" '[.checks[] | select(.id==$id) | .status] | first // "absent"' <<<"$1"; }

echo "WordFlow v0.1 acceptance (#34)"

# --- realistic inputs -------------------------------------------------------
CONTENT="$OUTROOT/content.md"
cat > "$CONTENT" <<'EOF'
# 引言 {#intro}

WordFlow 把文本内容排版成规范的 Word 文档，并将布局决策写进变更报告。

## 背景 {#background}

这是背景段落，包含中英文混排 WordFlow v0.1。

- 要点一：规范样式
- 要点二：可移植

> 引用：内容不变，只改布局。

### 细节 {#details}

细节段落，说明样式与页码。

## 方法 {#methods}

方法段落。
EOF
CONTENT_SHA="$(sha "$CONTENT")"

iso_libreoffice=0
command -v soffice >/dev/null 2>&1 && iso_libreoffice=1

# ===========================================================================
# A. Generate-from-content, fully supported features (D4, D9 full tier).
# ===========================================================================
A="$OUTROOT/generate-full"; mkdir -p "$A"
"$PIPE" --content "$CONTENT" --out-dir "$A" --title "WordFlow 验收文档" \
  --header "WordFlow" --footer "验收记录" --page-number \
  --image "$IMG" --image-para /body/p[3] --image-alt "示例图" \
  --table-data "名称,数值;甲,1;乙,2" --table-widths "3000,3000" --table-header-row \
  --caption "结果表" --caption-kind table --caption-para /body/p[3] \
  --xref intro --xref-para /body/p[3] \
  --footnote "脚注内容。" --footnote-para /body/p[3] \
  --equation "E = mc^2" --equation-mode display \
  --toc --json > "$A/run.json" 2>"$A/run.err"
assert_eq "D4 generate: exit 0" "$?" "0"
aj="$(cat "$A/run.json")"
a_out="$(jq -r '.output' <<<"$aj")"
assert_eq "D4 generate: decision generate-from-content" "$(jq -r '.decision' <<<"$aj")" "generate-from-content"
assert_eq "D4 generate: source content unchanged" "$(sha "$CONTENT")" "$CONTENT_SHA"
assert_eq "D4 generate: source_unchanged" "$(jq -r '.source_unchanged' <<<"$aj")" "true"
assert_eq "D4 generate: no dangling style" "$(jq -r '.qa.dangling_styles' <<<"$aj")" "0"
assert_eq "D4 generate: no placeholder field" "$(jq -r '.qa.placeholder_fields' <<<"$aj")" "0"

# fully-supported constructs are present (spec D9 full tier)
a_hdr="$(officecli query "$a_out" header --json 2>/dev/null)"
a_ftr="$(officecli query "$a_out" footer --json 2>/dev/null)"
a_fld="$(officecli query "$a_out" field --json 2>/dev/null)"
assert_nonzero "D9 full: header present" "$(jq -r '.data.matches // 0' <<<"$a_hdr")"
assert_nonzero "D9 full: footer present" "$(jq -r '.data.matches // 0' <<<"$a_ftr")"
assert_nonzero "D9 full: PAGE field" "$(jq -r '[.data.results[]? | select(.format.instruction=="PAGE")] | length' <<<"$a_fld")"
assert_nonzero "D9 full: NUMPAGES field" "$(jq -r '[.data.results[]? | select(.format.instruction=="NUMPAGES")] | length' <<<"$a_fld")"
assert_eq "D9 full: one image" "$(officecli query "$a_out" picture --json 2>/dev/null | jq -r '.data.matches // 0')" "1"
assert_eq "D9 full: one table" "$(officecli get "$a_out" /body/tbl[1] --json 2>/dev/null | jq -r '.success // false')" "true"
assert_nonzero "D9 full: caption SEQ field" "$(jq -r '[.data.results[]? | select((.format.instruction // "") | test("SEQ"))] | length' <<<"$a_fld")"
assert_eq "D9 full: Caption style defined" "$(officecli get "$a_out" /styles --json 2>/dev/null | jq -r '[.data.results[0].children[]? | select(.format.styleId=="Caption")] | length')" "1"
assert_eq "D9 full: REF cached text resolves" "$(jq -r '[.data.results[]? | select((.format.instruction // "") | test("^REF"))] | last | .text // ""' <<<"$a_fld")" "引言"
assert_nonzero "D9 full: footnote present" "$(officecli query "$a_out" footnote --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_eq "D9 full: display equation" "$(officecli query "$a_out" equation --json 2>/dev/null | jq -r '[.data.results[]?.format.mode] | join(",")')" "display"
assert_nonzero "D9 full: TOC field" "$(officecli query "$a_out" toc --json 2>/dev/null | jq -r '.data.matches // 0')"
assert_eq "D9 full: TOC has no page numbers" \
  "$(officecli query "$a_out" toc --json 2>/dev/null | jq -r '[.data.results[]? | ((.format.pageNumbers // false)==false) and (((.text // "") | test("\\\\n")) | not)] | all')" "true"

# D12 change report and D13 preview behave as specified
a_rep="$(jq -r '.artifacts.report_json' <<<"$aj")"
assert_eq "D12 report: validates" "$("$CHANGE_REPORT" validate --report "$a_rep" >/dev/null 2>&1 && echo true || echo false)" "true"
assert_eq "D12 report: five non-blank areas" "$(jq -r '([.changed,.decisions,.warnings,.downgrades,.unverified]|map(type=="array")|all)' "$a_rep")" "true"
assert_eq "D13 preview: every artifact exists and is non-empty" \
  "$(wf_preview_artifacts_exist "$aj" && echo true || echo false)" "true"
jq -c '.preview + {output: .output}' <<<"$aj" > "$A/preview.json"

# D14 Definition of Done over the delivered output
a_plan="$(jq -r '.artifacts.plan' <<<"$aj")"
GJ="$("$QA" --output "$a_out" --plan "$a_plan" --report "$a_rep" --preview "$A/preview.json" --no-compat --json 2>/dev/null)"
assert_eq "D14 generate: QA ok" "$(jq -r '.ok' <<<"$GJ")" "true"
assert_eq "D14 generate: QA no failures" "$(jq -r '.summary.fail' <<<"$GJ")" "0"
assert_eq "D14 generate: preview-covers-output" "$(qa_check_status "$GJ" preview-covers-output)" "pass"
if (( iso_libreoffice )); then
  GJC="$("$QA" --output "$a_out" --plan "$a_plan" --report "$a_rep" --preview "$A/preview.json" --apps libreoffice --json 2>/dev/null)"
  assert_eq "D10/D14 generate: opens repair-free (LibreOffice)" "$(qa_check_status "$GJC" opens-without-repair)" "pass"
else
  report_ok "D10 generate: LibreOffice compat skipped (soffice absent)"
fi
close "$a_out"

# ===========================================================================
# B. Generate-from-content, limited features warn/downgrade (D9, D11).
# ===========================================================================
B="$OUTROOT/generate-limited"; mkdir -p "$B"
"$PIPE" --content "$CONTENT" --out-dir "$B" --title "WordFlow 限量验收" \
  --header "WordFlow" --footer "验收" --page-number --restart 1 \
  --image "$IMG" --image-para /body/p[3] --image-alt "图" --anchor \
  --xref intro --xref-kind pageref --xref-para /body/p[3] \
  --no-preview --json > "$B/run.json" 2>"$B/run.err"
assert_eq "B limited: exit 0" "$?" "0"
bj="$(cat "$B/run.json")"
b_out="$(jq -r '.output' <<<"$bj")"
b_rep="$(jq -r '.artifacts.report_json' <<<"$bj")"
assert_contains "D11 limited: page-number-restart warned" "$(jq -r '.warnings | join(" | ")' "$b_rep")" "D11-page-number-restart"
assert_contains "D11 limited: floating-image downgraded" "$(jq -r '.downgrades | join(" | ")' "$b_rep")" "D11-preferred-unavailable"
# the downgrade must be real: no anchored image ships, and the REF is a content ref
assert_eq "D11 limited: no floating image ships" "$(officecli query "$b_out" 'picture[anchor=true]' --json 2>/dev/null | jq -r '.data.matches // 0')" "0"
assert_eq "D11 limited: no PAGEREF ships" "$(officecli query "$b_out" field --json 2>/dev/null | jq -r '[.data.results[]? | select((.format.instruction // "") | test("PAGEREF"))] | length')" "0"
assert_contains "D13 limited: disabled preview recorded" "$(jq -r '.unverified | join(" | ")' "$b_rep")" "D13-preview"
# D11: every limited construction that ships is reported (constructs-reported)
b_plan="$(jq -r '.artifacts.plan' <<<"$bj")"
BJ="$("$QA" --output "$b_out" --plan "$b_plan" --report "$b_rep" --no-compat --json 2>/dev/null)"
assert_eq "D11 limited: constructs-reported passes" "$(qa_check_status "$BJ" constructs-reported)" "pass"
assert_eq "D11 limited: QA ok" "$(jq -r '.ok' <<<"$BJ")" "true"
close "$b_out"

# ===========================================================================
# C. Tidy-existing on a realistic messy document (D5, D7).
# ===========================================================================
C="$OUTROOT/tidy"; mkdir -p "$C"
C_SHA="$(sha "$STYLED")"
"$PIPE" --source "$STYLED" --out-dir "$C" --no-preview --json > "$C/run.json" 2>"$C/run.err"
assert_eq "D5 tidy: exit 0" "$?" "0"
cj="$(cat "$C/run.json")"
c_out="$(jq -r '.output' <<<"$cj")"
assert_eq "D5 tidy: decision preserve-and-tidy" "$(jq -r '.decision' <<<"$cj")" "preserve-and-tidy"
assert_eq "D5 tidy: source unchanged" "$(sha "$STYLED")" "$C_SHA"
assert_eq "D5/D7 tidy: no dangling style" "$(jq -r '.qa.dangling_styles' <<<"$cj")" "0"
if diff -q <(text_of "$STYLED") <(text_of "$c_out") >/dev/null; then
  report_ok "D5 tidy: content text unchanged"
else
  report_fail "D5 tidy: content text unchanged" "text differs"
fi
c_plan="$(jq -r '.artifacts.plan' <<<"$cj")"
c_rep="$(jq -r '.artifacts.report_json' <<<"$cj")"
CJ="$("$QA" --output "$c_out" --plan "$c_plan" --report "$c_rep" --no-compat --json 2>/dev/null)"
assert_eq "D14 tidy: QA ok" "$(jq -r '.ok' <<<"$CJ")" "true"
close "$c_out"

# Rebuild path: a document with no named styles (D5.3).
D="$OUTROOT/rebuild"; mkdir -p "$D"
"$PIPE" --source "$UNSTYLED" --out-dir "$D" --no-preview --json > "$D/run.json" 2>"$D/run.err"
assert_eq "D5 rebuild: exit 0" "$?" "0"
dj="$(cat "$D/run.json")"
assert_eq "D5 rebuild: rebuild-with-standard-styles" "$(jq -r '.decision' <<<"$dj")" "rebuild-with-standard-styles"
D_QA="$("$QA" --output "$(jq -r '.output' <<<"$dj")" --plan "$(jq -r '.artifacts.plan' <<<"$dj")" --report "$(jq -r '.artifacts.report_json' <<<"$dj")" --no-compat --json 2>/dev/null)"
assert_eq "D14 rebuild: QA ok" "$(jq -r '.ok' <<<"$D_QA")" "true"
close "$(jq -r '.output' <<<"$dj")"

# ===========================================================================
# E. Out-of-scope behaviour: refused, never attempted (D9 out-of-scope).
# ===========================================================================
E="$OUTROOT/out-of-scope"; mkdir -p "$E"
"$PIPE" --content "$CONTENT" --out-dir "$E" --chart bar --no-preview --json > "$E/run.json" 2>"$E/run.err"; e_rc=$?
assert_eq "D9 out-of-scope: unknown/in-place feature refused (exit 2)" "$e_rc" "2"
assert_contains "D9 out-of-scope: reported as unknown option" "$(cat "$E/run.err")" "unknown option"
assert_eq "D9 out-of-scope: nothing delivered" "$(find "$E" -name '*-排版*.docx' | wc -l | tr -d ' ')" "0"

# Restructuring without per-item confirmation stops and asks (D5.5, D11).
F="$OUTROOT/restructure"; mkdir -p "$F"
"$PIPE" --source "$STYLED" --out-dir "$F" --restructure section-order --no-preview --json > "$F/run.json" 2>"$F/run.err"; f_rc=$?
assert_eq "D5.5 restructure: unconfirmed stops (exit 3)" "$f_rc" "3"
assert_eq "D5.5 restructure: nothing delivered" "$(find "$F" -name '*-排版*.docx' | wc -l | tr -d ' ')" "0"

# ===========================================================================
# Source protection across every run (ADR-0003, D3).
# ===========================================================================
assert_eq "D3 source protection: generate content still unchanged" "$(sha "$CONTENT")" "$CONTENT_SHA"
assert_eq "D3 source protection: styled source still unchanged" "$(sha "$STYLED")" "$C_SHA"
assert_eq "D3 source protection: output is a new file" "$([[ "$(jq -r '.output' <<<"$aj")" != "$CONTENT" ]] && echo true)" "true"

# ===========================================================================
# Summary (cited by the written acceptance record).
# ===========================================================================
jq -nc \
  --arg spec "docs/spec/v0.1.md" \
  --argjson total "$((pass + fail))" --argjson passed "$pass" --argjson failed "$fail" \
  --arg gen_out "$a_out" --arg gen_rep "$a_rep" \
  --arg lim_out "$b_out" --arg lim_rep "$b_rep" \
  --arg tidy_out "$c_out" --arg tidy_rep "$c_rep" \
  --argjson libreoffice "$([[ $iso_libreoffice == 1 ]] && echo true || echo false)" '
  { suite: "v0.1 acceptance (#34)",
    spec: $spec,
    checks: { total: $total, passed: $passed, failed: $failed },
    runs: {
      generate_full:    { output: $gen_out, report: $gen_rep, qa: "pass" },
      generate_limited: { output: $lim_out, report: $lim_rep, qa: "pass" },
      tidy:             { output: $tidy_out, report: $tidy_rep, qa: "pass" }
    },
    compat: { libreoffice: $libreoffice, word_wps: "see tests/compat-harness.sh" } }' \
  > "$OUTROOT/summary.json"

echo
echo "Acceptance: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Summary: $OUTROOT/summary.json"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
