#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow walking-skeleton pipeline (#35).
#
# These tests exercise the *external behaviour* of scripts/wf-pipeline.sh: one run
# takes a simple input through inspect -> decision -> apply -> new output ->
# validate -> preview -> change report -> risk hooks -> deliver, and it must:
#
#   - leave the source byte-identical;
#   - write a NEW output with the default name and collision numbering;
#   - validate the output and render a preview of the FINAL output;
#   - emit a change report with all five areas;
#   - exercise the #30 warn path (floating image) and stop path (unreadable source);
#   - satisfy the D14 checklist for its scope (no dangling style, no placeholder
#     field, every warning recorded, source unchanged);
#   - be reproducible (same input + instructions -> same layout).
#
# They assert what a reader would see and what the report says, not the OfficeCLI
# commands the pipeline runs internally.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum, soffice, pdftoppm on PATH.
# Usage: tests/pipeline.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-pipeline.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
OUT="$ROOT/tests/.out/walking-skeleton"

for bin in officecli jq sha256sum soffice pdftoppm; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

sha() { sha256sum "$1" | awk '{print $1}'; }
close() { officecli close "$1" >/dev/null 2>&1 || true; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_neq() {
  if [[ "$2" != "$3" ]]; then report_ok "$1"; else report_fail "$1" "values must differ (both '$2')"; fi
}
assert_file() {
  if [[ -s "$2" ]]; then report_ok "$1"; else report_fail "$1" "missing or empty: $2"; fi
}
assert_absent() {
  if [[ ! -e "$2" ]]; then report_ok "$1"; else report_fail "$1" "expected absent: $2"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "'$3' not found in '$2'"; fi
}

# independent_dangling <docx> -> count of referenced styles with no definition.
# Matches a reference against a style's styleId OR display name (see pipeline.md).
independent_dangling() {
  local doc="$1" styles stats defined referenced
  styles="$(officecli get "$doc" /styles --json 2>/dev/null || echo '{}')"
  stats="$(officecli view "$doc" stats --json 2>/dev/null || echo '{}')"
  defined="$(jq -r '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | .[] | ascii_downcase' <<<"$styles" 2>/dev/null || true)"
  referenced="$(jq -r '.data.styleDistribution // {} | keys[] | ascii_downcase' <<<"$stats" 2>/dev/null || true)"
  awk 'NR==FNR{if($0!="")d[$0]=1;next} $0!="" && !($0 in d){c++} END{print c+0}' \
    <(printf '%s\n' "$defined") <(printf '%s\n' "$referenced")
}

# independent_placeholder_fields <docx> -> count of fields whose CACHED TEXT is a placeholder.
independent_placeholder_fields() {
  local doc="$1"
  officecli query "$doc" field --json 2>/dev/null \
    | jq -r '[.data.results[]? | select((.text // "") | test("«|»|update field|placeholder"; "i"))] | length' 2>/dev/null || echo 0
}

# layout_digest <docx> -> a canonical string of the style set and section geometry.
layout_digest() {
  local doc="$1"
  officecli get "$doc" /styles --json 2>/dev/null \
    | jq -S '[.data.results[0].children[]? | select(.type=="style") | {id:.format.styleId, name:.format.name, type:.type, format:.format}]'
  officecli query "$doc" section --json 2>/dev/null \
    | jq -S '[.data.results[]? | {format:.format}]'
}

# assert_report <label> <report.json> <expect_warning_code_or_empty>
assert_report() {
  local label="$1" report="$2"
  assert_file "$label: report json exists" "$report"
  if "$CHANGE_REPORT" validate --report "$report" >/dev/null 2>&1; then
    report_ok "$label: report validates"
  else
    report_fail "$label: report validates" "wf-change-report.sh validate failed"
  fi
  assert_eq "$label: report has five areas" \
    "$(jq -r '([.changed,.decisions,.warnings,.downgrades,.unverified]|map(type=="array")|all)' "$report")" "true"
}

echo "Walking skeleton (#35) — $TOOL"
rm -rf "$OUT"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# A. Rebuild path: a document with no named styles -> standard style set.
# ---------------------------------------------------------------------------
echo
echo "A. rebuild path (styles/unstyled.docx)"
A="$OUT/rebuild"; mkdir -p "$A"
A_SRC="$FIX/styles/unstyled.docx"
A_SHA_BEFORE="$(sha "$A_SRC")"

a_json="$("$TOOL" --source "$A_SRC" --out-dir "$A" --json)"; a_rc=$?
assert_eq "rebuild: exit 0" "$a_rc" "0"
assert_eq "rebuild: decision" "$(jq -r '.decision' <<<"$a_json")" "rebuild-with-standard-styles"
a_out="$(jq -r '.output' <<<"$a_json")"
assert_eq "rebuild: default name" "$(basename "$a_out")" "unstyled-排版.docx"
assert_file "rebuild: output exists" "$a_out"
assert_neq "rebuild: output is a NEW file" "$(readlink -f "$a_out")" "$(readlink -f "$A_SRC")"
assert_eq "rebuild: source unchanged (test)" "$(sha "$A_SRC")" "$A_SHA_BEFORE"
assert_eq "rebuild: source unchanged (pipeline)" "$(jq -r '.source_unchanged' <<<"$a_json")" "true"

# artifacts required for human inspection
a_report="$(jq -r '.artifacts.report_json' <<<"$a_json")"
a_report_md="$(jq -r '.artifacts.report_md' <<<"$a_json")"
a_plan="$(jq -r '.artifacts.plan' <<<"$a_json")"
a_input="$(jq -r '.artifacts.input' <<<"$a_json")"
a_preview="$(jq -r '.preview.artifacts[0] // empty' <<<"$a_json")"
assert_file "rebuild: input copy exists" "$a_input"
assert_file "rebuild: plan artifact exists" "$a_plan"
assert_file "rebuild: preview artifact exists" "$a_preview"
assert_contains "rebuild: preview named from the output stem" "$a_preview" "unstyled-排版-preview"
assert_report "rebuild" "$a_report"
assert_file "rebuild: report markdown exists" "$a_report_md"

# output validates (schema gate)
a_val="$(officecli validate "$a_out" --json 2>/dev/null | jq -r '.success // false')"
assert_eq "rebuild: officecli validate passes" "$a_val" "true"

# the standard style set was applied (18 styles, Normal default)
a_styles="$(officecli get "$a_out" /styles --json 2>/dev/null)"
assert_eq "rebuild: 18 styles defined" \
  "$(jq -r '[.data.results[0].children[]?|select(.type=="style")]|length' <<<"$a_styles")" "18"
assert_eq "rebuild: Normal is the default style" \
  "$(jq -r '.data.results[0].children[]?|select(.format.default=="true")|.format.styleId' <<<"$a_styles")" "Normal"
assert_eq "rebuild: decision recorded in report" \
  "$(jq -r '[.decisions[]|select(test("rebuild-with-standard-styles"))]|length>=1' "$a_report")" "true"
assert_eq "rebuild: page setup recorded in report" \
  "$(jq -r '[.changed[]|select(test("Page setup: A4 portrait"))]|length>=1' "$a_report")" "true"
assert_eq "rebuild: no dangling style (independent)" "$(independent_dangling "$a_out")" "0"
assert_eq "rebuild: no placeholder field (independent)" "$(independent_placeholder_fields "$a_out")" "0"
assert_eq "rebuild: no warnings for this fixture" "$(jq -r '.warnings|length' "$a_report")" "0"
close "$a_out"

# ---------------------------------------------------------------------------
# A2. Collision numbering: a second run in the same directory.
# ---------------------------------------------------------------------------
echo
echo "A2. collision numbering"
a2_json="$("$TOOL" --source "$A_SRC" --out-dir "$A" --json)"; a2_rc=$?
assert_eq "collision: exit 0" "$a2_rc" "0"
a2_out="$(jq -r '.output' <<<"$a2_json")"
assert_eq "collision: numbered name" "$(basename "$a2_out")" "unstyled-排版 (2).docx"
assert_eq "collision: collision_index == 2" "$(jq -r '.collision.collision_index' <<<"$a2_json")" "2"
assert_eq "collision: numbered flag" "$(jq -r '.collision.numbered' <<<"$a2_json")" "true"
assert_file "collision: numbered output exists" "$a2_out"
assert_file "collision: original output still exists" "$a_out"
assert_eq "collision: source still unchanged" "$(sha "$A_SRC")" "$A_SHA_BEFORE"
close "$a2_out"

# ---------------------------------------------------------------------------
# B. Preserve path: a document with a coherent named style set is kept.
# ---------------------------------------------------------------------------
echo
echo "B. preserve path (styles/heading-hierarchy.docx)"
B="$OUT/preserve"; mkdir -p "$B"
B_SRC="$FIX/styles/heading-hierarchy.docx"
B_SHA_BEFORE="$(sha "$B_SRC")"

b_json="$("$TOOL" --source "$B_SRC" --out-dir "$B" --json)"; b_rc=$?
assert_eq "preserve: exit 0" "$b_rc" "0"
assert_eq "preserve: decision" "$(jq -r '.decision' <<<"$b_json")" "preserve-and-tidy"
b_out="$(jq -r '.output' <<<"$b_json")"
assert_eq "preserve: default name" "$(basename "$b_out")" "heading-hierarchy-排版.docx"
assert_eq "preserve: source unchanged" "$(sha "$B_SRC")" "$B_SHA_BEFORE"
assert_eq "preserve: officecli validate passes" \
  "$(officecli validate "$b_out" --json 2>/dev/null | jq -r '.success // false')" "true"
b_report="$(jq -r '.artifacts.report_json' <<<"$b_json")"
assert_report "preserve" "$b_report"
assert_eq "preserve: report says the style set was preserved" \
  "$(jq -r '[.changed[]|select(test("preserved the source"; "i"))]|length>=1' "$b_report")" "true"

# the source style set is kept, and the standard set was NOT added
b_styles="$(officecli get "$b_out" /styles --json 2>/dev/null)"
assert_eq "preserve: Heading1 style kept" \
  "$(jq -r '[.data.results[0].children[]?|select(.format.styleId=="Heading1")]|length' <<<"$b_styles")" "1"
assert_eq "preserve: Title style kept" \
  "$(jq -r '[.data.results[0].children[]?|select(.format.styleId=="Title")]|length' <<<"$b_styles")" "1"
assert_eq "preserve: standard set not applied (no TOC1)" \
  "$(jq -r '[.data.results[0].children[]?|select(.format.styleId=="TOC1")]|length' <<<"$b_styles")" "0"
assert_eq "preserve: no dangling style (independent)" "$(independent_dangling "$b_out")" "0"
close "$b_out"

# ---------------------------------------------------------------------------
# B2. Preview can be switched off, and the omission is recorded.
# ---------------------------------------------------------------------------
echo
echo "B2. --no-preview"
B2="$OUT/nopreview"; mkdir -p "$B2"
b2_json="$("$TOOL" --source "$B_SRC" --out-dir "$B2" --no-preview --json)"
assert_eq "no-preview: disabled" "$(jq -r '.preview.disabled' <<<"$b2_json")" "true"
assert_eq "no-preview: no artifacts" "$(jq -r '.preview.artifacts|length' <<<"$b2_json")" "0"
b2_report="$(jq -r '.artifacts.report_json' <<<"$b2_json")"
assert_eq "no-preview: omission recorded in unverified" \
  "$(jq -r '[.unverified[]|select(test("D13-preview"))]|length>=1' "$b2_report")" "true"
assert_eq "no-preview: no preview file written" \
  "$(find "$B2" -name '*-preview*' | wc -l | tr -d ' ')" "0"
assert_file "no-preview: output still delivered" "$(jq -r '.output' <<<"$b2_json")"

# ---------------------------------------------------------------------------
# C. Risk path: a floating image warns through #30 and is recorded.
# ---------------------------------------------------------------------------
echo
echo "C. risk path (images/anchored-image.docx)"
C="$OUT/risk"; mkdir -p "$C"
C_SRC="$FIX/images/anchored-image.docx"
c_json="$("$TOOL" --source "$C_SRC" --out-dir "$C" --json)"; c_rc=$?
assert_eq "risk: exit 0" "$c_rc" "0"
c_out="$(jq -r '.output' <<<"$c_json")"
c_report="$(jq -r '.artifacts.report_json' <<<"$c_json")"
assert_report "risk" "$c_report"
assert_eq "risk: floating-image warning recorded" \
  "$(jq -r '[.warnings[]|select(test("D11-floating-image"))]|length>=1' "$c_report")" "true"
assert_eq "risk: warning also in pipeline summary" \
  "$(jq -r '[.report.warnings[]|select(test("D11-floating-image"))]|length>=1' <<<"$c_json")" "true"
# the warning is about content that is really still there
assert_eq "risk: output still contains the anchored image" \
  "$(officecli query "$c_out" 'picture[anchor=true]' --json 2>/dev/null | jq -r '.data.matches')" "1"
assert_file "risk: preview of the final output exists" "$(jq -r '.preview.artifacts[0] // empty' <<<"$c_json")"
assert_eq "risk: source unchanged" "$(jq -r '.source_unchanged' <<<"$c_json")" "true"
close "$c_out"

# ---------------------------------------------------------------------------
# D. Stop path: an unreadable source stops and produces no output.
# ---------------------------------------------------------------------------
echo
echo "D. stop path (unreadable source)"
D="$OUT/stop"; mkdir -p "$D"
printf 'this is not a valid docx package\n' > "$D/broken.docx"
d_err="$("$TOOL" --source "$D/broken.docx" --out-dir "$D" 2>&1 >/dev/null)"; d_rc=$?
assert_eq "stop: exit 3" "$d_rc" "3"
assert_contains "stop: asks the user" "$d_err" "ask the user"
assert_eq "stop: no output document produced" "$(find "$D" -name '*-排版*.docx' | wc -l | tr -d ' ')" "0"
assert_absent "stop: no report produced" "$D/broken-排版-report.json"

# ---------------------------------------------------------------------------
# E. Reproducibility: same input + same instructions -> same layout.
# ---------------------------------------------------------------------------
echo
echo "E. reproducibility"
for n in 1 2; do
  R="$OUT/repro$n"; mkdir -p "$R"
  r_json="$("$TOOL" --source "$A_SRC" --out-dir "$R" --json)"
  layout_digest "$(jq -r '.output' <<<"$r_json")" > "$R/digest.txt"
  jq -S '{changed,decisions,warnings,downgrades,unverified}' "$(jq -r '.artifacts.report_json' <<<"$r_json")" > "$R/report-areas.json"
  close "$(jq -r '.output' <<<"$r_json")"
done
if diff -q "$OUT/repro1/digest.txt" "$OUT/repro2/digest.txt" >/dev/null 2>&1; then
  report_ok "reproducible: identical layout digest"
else
  report_fail "reproducible: identical layout digest" "style/section digests differ"
fi
if diff -q "$OUT/repro1/report-areas.json" "$OUT/repro2/report-areas.json" >/dev/null 2>&1; then
  report_ok "reproducible: identical report areas"
else
  report_fail "reproducible: identical report areas" "report areas differ"
fi

echo
echo "Pipeline: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Artifacts: $OUT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
