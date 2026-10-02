#!/usr/bin/env bash
#
# Acceptance tests for the tidy-existing-DOCX workflow (#33, spec §D5).
#
# These tests exercise the *external behaviour* of the tidy primitive
# (scripts/wf-tidy.sh) and of scripts/wf-pipeline.sh in restyle mode:
#
#   - a document that already uses named styles is preserved and tidied: a
#     referenced-but-undefined style is defined, so nothing dangles, while
#     content, existing definitions and unused styles are left intact;
#   - a document with no named styles is rebuilt with the standard set;
#   - restructuring never happens on its own: a request without per-item
#     confirmation stops and asks (exit 3, no output);
#   - the output passes #31's Definition of Done and delivers report + preview.
#
# Requirements: officecli, jq, sha256sum, cp on PATH. Usage: tests/tidy.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIDY="$ROOT/scripts/wf-tidy.sh"
PIPE="$ROOT/scripts/wf-pipeline.sh"
QA="$ROOT/scripts/wf-qa.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
FIX="$ROOT/tests/fixtures/styles"
OUTROOT="$ROOT/tests/.out/tidy"

for bin in officecli jq sha256sum cp diff; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for t in "$TIDY" "$PIPE" "$QA" "$CHANGE_REPORT"; do
  [[ -x "$t" ]] || { echo "missing or non-executable: $t" >&2; exit 2; }
done
for f in caption-dangling.docx heading-hierarchy.docx unstyled.docx; do
  [[ -f "$FIX/$f" ]] || { echo "missing fixture: $FIX/$f" >&2; exit 2; }
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
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "missing '$3' in '$2'"; fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }
close() { officecli close "$1" >/dev/null 2>&1 || true; }
text_of() { officecli view "$1" text 2>/dev/null; }

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
style_prop() { # <docx> <stylePath> <prop>
  officecli get "$1" "$2" --json 2>/dev/null | jq -r --arg p "$3" '.data.results[0].format[$p] // ""'
}

echo "Tidy-existing workflow (#33) — $TIDY"

# ===========================================================================
# A. The tidy primitive repairs a dangling reference, content untouched.
# ===========================================================================
A="$OUTROOT/primitive-dangling"; mkdir -p "$A"
SRC_A="$FIX/caption-dangling.docx"
A_SHA_BEFORE="$(sha "$SRC_A")"
"$TIDY" "$SRC_A" --out "$A/tidied.docx" --report "$A/report.json" --json > "$A/run.json" 2>"$A/run.err"
assert_eq "tidy: exit 0" "$?" "0"
aj="$(cat "$A/run.json")"
assert_eq "tidy: repaired Caption" "$(jq -r '.repaired_styles | join(",")' <<<"$aj")" "Caption"
assert_eq "tidy: repaired_count 1" "$(jq -r '.repaired_count' <<<"$aj")" "1"
assert_eq "tidy: source unchanged (JSON)" "$(jq -r '.source_unchanged' <<<"$aj")" "true"
assert_eq "tidy: source bytes unchanged" "$(sha "$SRC_A")" "$A_SHA_BEFORE"
assert_eq "tidy: default style Normal" "$(jq -r '.default_style' <<<"$aj")" "Normal"
assert_eq "tidy: Caption now defined" "$(style_prop "$A/tidied.docx" /styles/Caption id)" "Caption"
assert_eq "tidy: Caption is a paragraph style" "$(style_prop "$A/tidied.docx" /styles/Caption type)" "paragraph"
assert_eq "tidy: Caption has an explicit CJK font" "$(style_prop "$A/tidied.docx" /styles/Caption "font.ea")" "SimSun"
assert_eq "tidy: no dangling style remains" "$(independent_dangling "$A/tidied.docx")" "0"
assert_eq "tidy: output validates" "$(officecli validate "$A/tidied.docx" --json 2>/dev/null | jq -r '.success // false')" "true"
if diff -q <(text_of "$SRC_A") <(text_of "$A/tidied.docx") >/dev/null; then
  report_ok "tidy: content text unchanged"
else
  report_fail "tidy: content text unchanged" "text differs after tidy"
fi
assert_eq "tidy: report validates" "$("$CHANGE_REPORT" validate --report "$A/report.json" >/dev/null 2>&1 && echo true || echo false)" "true"
assert_contains "tidy: report records the repair" "$(jq -r '.changed | join(" | ")' "$A/report.json")" "Tidy: defined missing style 'Caption'"
assert_contains "tidy: report states non-destructive" "$(jq -r '.decisions | join(" | ")' "$A/report.json")" "left intact"
close "$A/tidied.docx"

# ===========================================================================
# B. A coherent document is a tidy no-op (nothing falsely repaired).
# ===========================================================================
B="$OUTROOT/primitive-coherent"; mkdir -p "$B"
SRC_B="$FIX/heading-hierarchy.docx"
B_SHA_BEFORE="$(sha "$SRC_B")"
"$TIDY" "$SRC_B" --out "$B/tidied.docx" --report "$B/report.json" --json > "$B/run.json" 2>/dev/null
assert_eq "coherent: exit 0" "$?" "0"
bj="$(cat "$B/run.json")"
assert_eq "coherent: nothing repaired" "$(jq -r '.repaired_count' <<<"$bj")" "0"
assert_eq "coherent: no dangling style" "$(independent_dangling "$B/tidied.docx")" "0"
assert_contains "coherent: report says nothing to repair" "$(jq -r '.changed | join(" | ")' "$B/report.json")" "no dangling style reference to repair"
assert_eq "coherent: source unchanged" "$(sha "$SRC_B")" "$B_SHA_BEFORE"
if diff -q <(text_of "$SRC_B") <(text_of "$B/tidied.docx") >/dev/null; then
  report_ok "coherent: content text unchanged"
else
  report_fail "coherent: content text unchanged" "text differs"
fi
close "$B/tidied.docx"

# ===========================================================================
# C. Pipeline preserve path: a messy styled document is preserved + tidied.
# ===========================================================================
C="$OUTROOT/preserve"; mkdir -p "$C"
SRC_C="$FIX/caption-dangling.docx"
C_SHA_BEFORE="$(sha "$SRC_C")"
"$PIPE" --source "$SRC_C" --out-dir "$C" --no-preview --json > "$C/run.json" 2>"$C/run.err"
assert_eq "preserve: exit 0" "$?" "0"
cj="$(cat "$C/run.json")"
c_out="$(jq -r '.output' <<<"$cj")"
assert_eq "preserve: status delivered" "$(jq -r '.status' <<<"$cj")" "delivered"
assert_eq "preserve: mode restyle" "$(jq -r '.mode' <<<"$cj")" "restyle"
assert_eq "preserve: decision preserve-and-tidy" "$(jq -r '.decision' <<<"$cj")" "preserve-and-tidy"
assert_eq "preserve: no dangling style" "$(jq -r '.qa.dangling_styles' <<<"$cj")" "0"
assert_eq "preserve: no dangling (independent)" "$(independent_dangling "$c_out")" "0"
assert_eq "preserve: source unchanged" "$(jq -r '.source_unchanged' <<<"$cj")" "true"
assert_eq "preserve: source bytes unchanged" "$(sha "$SRC_C")" "$C_SHA_BEFORE"
if diff -q <(text_of "$SRC_C") <(text_of "$c_out") >/dev/null; then
  report_ok "preserve: content text unchanged"
else
  report_fail "preserve: content text unchanged" "text differs from source"
fi
assert_contains "preserve: report records the tidy repair" "$(jq -r '.report.changed | join(" | ")' <<<"$cj")" "Tidy: defined missing style 'Caption'"
assert_contains "preserve: report records the tidy step" "$(jq -r '.report.changed | join(" | ")' <<<"$cj")" "tidy (#33)"
assert_eq "preserve: output validates" "$(officecli validate "$c_out" --json 2>/dev/null | jq -r '.success // false')" "true"
close "$c_out"

# ===========================================================================
# D. Pipeline rebuild path: a document with no named styles is rebuilt.
# ===========================================================================
D="$OUTROOT/rebuild"; mkdir -p "$D"
SRC_D="$FIX/unstyled.docx"
"$PIPE" --source "$SRC_D" --out-dir "$D" --no-preview --json > "$D/run.json" 2>"$D/run.err"
assert_eq "rebuild: exit 0" "$?" "0"
dj="$(cat "$D/run.json")"
d_out="$(jq -r '.output' <<<"$dj")"
assert_eq "rebuild: decision rebuild-with-standard-styles" "$(jq -r '.decision' <<<"$dj")" "rebuild-with-standard-styles"
assert_eq "rebuild: no dangling style" "$(jq -r '.qa.dangling_styles' <<<"$dj")" "0"
assert_contains "rebuild: report records the standard set" "$(jq -r '.report.changed | join(" | ")' <<<"$dj")" "Standard styles"
assert_eq "rebuild: output validates" "$(officecli validate "$d_out" --json 2>/dev/null | jq -r '.success // false')" "true"
if diff -q <(text_of "$SRC_D") <(text_of "$d_out") >/dev/null; then
  report_ok "rebuild: content text unchanged"
else
  report_fail "rebuild: content text unchanged" "text differs from source"
fi
close "$d_out"

# ===========================================================================
# E. Restructure guard (spec D5.5, D11): never automatic.
# ===========================================================================
E="$OUTROOT/restructure-unconfirmed"; mkdir -p "$E"
"$PIPE" --source "$SRC_C" --out-dir "$E" --restructure heading-levels --no-preview --json > "$E/run.json" 2>"$E/run.err"; e_rc=$?
assert_eq "guard: unconfirmed request exits 3" "$e_rc" "3"
assert_eq "guard: no delivered output" "$(find "$E" -name '*-排版*.docx' | wc -l | tr -d ' ')" "0"
assert_contains "guard: asks for per-item confirmation" "$(cat "$E/run.err")" "per-item confirmation"
assert_contains "guard: routes through the stop policy" "$(cat "$E/run.err")" "confirm each structural change item by item"

E2="$OUTROOT/restructure-confirmed"; mkdir -p "$E2"
"$PIPE" --source "$SRC_C" --out-dir "$E2" --restructure heading-levels --confirm-restructure heading-levels --no-preview --json > "$E2/run.json" 2>"$E2/run.err"; e2_rc=$?
assert_eq "guard: confirmed request exits 0" "$e2_rc" "0"
e2j="$(cat "$E2/run.json")"
assert_eq "guard: request recorded" "$(jq -r '.restructure.requested | join(",")' <<<"$e2j")" "heading-levels"
assert_eq "guard: confirmation recorded" "$(jq -r '.restructure.confirmed | join(",")' <<<"$e2j")" "heading-levels"
assert_contains "guard: confirmed-but-unavailable is a reported downgrade" "$(jq -r '.report.downgrades | join(" | ")' <<<"$e2j")" "D11-preferred-unavailable"
assert_contains "guard: report states structure left unchanged" "$(jq -r '.report.decisions | join(" | ")' <<<"$e2j")" "left unchanged"
if diff -q <(text_of "$SRC_C") <(text_of "$(jq -r '.output' <<<"$e2j")") >/dev/null; then
  report_ok "guard: content text unchanged after confirmed request"
else
  report_fail "guard: content text unchanged after confirmed request" "text differs"
fi
close "$(jq -r '.output' <<<"$e2j")"

# Generate mode cannot restructure.
G="$OUTROOT/restructure-generate"; mkdir -p "$G"
printf '# Title\n\nBody.\n' > "$G/content.md"
"$PIPE" --content "$G/content.md" --out-dir "$G" --restructure heading-levels --no-preview --json > "$G/run.json" 2>"$G/run.err"; g_rc=$?
assert_eq "guard: restructure rejected for generated content" "$g_rc" "2"
assert_contains "guard: usage names --restructure" "$(cat "$G/run.err")" "--restructure applies to an existing document"

# ===========================================================================
# F. Definition of Done over the preserved+tidied output (#31, D14).
# ===========================================================================
c_plan="$(jq -r '.artifacts.plan' <<<"$cj")"
c_rep="$(jq -r '.artifacts.report_json' <<<"$cj")"
GJ="$("$QA" --output "$c_out" --plan "$c_plan" --report "$c_rep" --no-compat --json 2>/dev/null)"
assert_eq "DoD: QA ok" "$(jq -r '.ok' <<<"$GJ")" "true"
assert_eq "DoD: no QA failures" "$(jq -r '.summary.fail' <<<"$GJ")" "0"
assert_eq "DoD: no-dangling-styles check passes" \
  "$(jq -r '[.checks[] | select(.id=="no-dangling-styles") | .status] | first' <<<"$GJ")" "pass"

echo
echo "Tidy: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Artifacts: $OUTROOT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
