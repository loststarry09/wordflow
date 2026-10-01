#!/usr/bin/env bash
#
# Acceptance tests for template adoption (#27).
#
# They exercise the *external behaviour* of scripts/wf-template.sh against the
# committed template fixture tests/fixtures/styles/template.docx:
#
#   * the output adopts the template's style definitions and page setup (read
#     back through OfficeCLI), and the template outranks the source's own styles;
#   * the template's body and header/footer content never appears in the output
#     while the source's own content stays intact;
#   * a formatting requirement's overrides beat the template;
#   * the source is byte-identical afterwards and the result is reproducible;
#   * the output opens without repair in LibreOffice when soffice is present.
#
# The tests assert what OfficeCLI reports back, not the exact commands run.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/template.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures/styles"
TOOL="$ROOT/scripts/wf-template.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
COMPAT="$ROOT/scripts/wf-compat-harness.sh"
TEMPLATE="$FIX/template.docx"
UNSTYLED="$FIX/unstyled.docx"
STYLED="$FIX/standard-style-set.docx"
IMAGE="$ROOT/tests/fixtures/assets/test-image.png"

# The committed template's sentinels (tests/generate-fixtures.sh).
TPL_SENTINEL_BODY='Template body sample.'
TPL_SENTINEL_QUOTE='Template quote sample.'

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
for f in "$TEMPLATE" "$UNSTYLED" "$STYLED"; do
  [[ -f "$f" ]] || { echo "missing fixture: $f" >&2; exit 2; }
done

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/template.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

TMO="timeout 60"

# --- OfficeCLI read helpers (cached where repeated) -------------------------
STYLE_CACHE="$WORK/.style-cache"; mkdir -p "$STYLE_CACHE"
style_json() { # style_json <file> <styleId> — canonical compact format
  local f="$1" id="$2" safe cache
  safe="$(printf '%s' "$f" | md5sum | cut -c1-8)_$id"
  cache="$STYLE_CACHE/$safe.json"
  [[ -f "$cache" ]] || $TMO officecli get "$f" "/styles/$id" --json >"$cache" 2>/dev/null || true
  jq -Sc '.data.results[0].format // {}' "$cache"
}
style_field() { # style_field <file> <styleId> <key>
  style_json "$1" "$2" | jq -r --arg k "$3" '.[$k] // ""'
}
defined_ids() { # defined_ids <file>
  $TMO officecli get "$1" /styles --json \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}
sec_field() { # sec_field <file> <path> <key>
  $TMO officecli query "$1" section --json \
    | jq -r --arg p "$2" --arg k "$3" '.data.results[] | select(.path==$p) | .format[$k] // ""'
}
body_text() { $TMO officecli view "$1" text 2>/dev/null; }
hf_text() { # hf_text <file> <header|footer> — one text per part
  $TMO officecli query "$1" "$2" --json 2>/dev/null | jq -r '[.data.results[]?.text // ""] | join("|")'
}
hf_matches() { $TMO officecli query "$1" "$2" --json 2>/dev/null | jq -r '.data.matches // 0'; }

# Every property the template defines must read back equal on the output.
template_props_match() { # <template> <output> <styleId> — prints mismatched keys
  local tf of
  tf="$(style_json "$1" "$3")"; of="$(style_json "$2" "$3")"
  jq -rn --argjson t "$tf" --argjson o "$of" '
    [ $t | to_entries[]
      | select(.key | test("(^|\\.)path$") | not)
      | select(.key | startswith("effective.") | not)
      | select($o[.key] != .value) | .key ] | join(",")'
}

new_doc() { # new_doc <path> <locale>
  local f="$1" loc="$2"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale "$loc" >/dev/null
}

cleanup() {
  local f
  for f in "$WORK"/*.docx; do [[ -e "$f" ]] && $TMO officecli close "$f" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# Source-protection baselines.
tpl_before="$(sha256sum "$TEMPLATE" | awk '{print $1}')"
unstyled_before="$(sha256sum "$UNSTYLED" | awk '{print $1}')"
styled_before="$(sha256sum "$STYLED" | awk '{print $1}')"

echo "Template adoption (#27) — $TOOL"
echo

# ---------------------------------------------------------------------------
# 0. The committed template fixture carries the sentinels
# ---------------------------------------------------------------------------
tpl_text="$(body_text "$TEMPLATE")"
if grep -qF "$TPL_SENTINEL_BODY" <<<"$tpl_text"; then report_ok "fixture: template body sentinel present"; else report_fail "fixture: template body sentinel present" "not found"; fi
if grep -qF "$TPL_SENTINEL_QUOTE" <<<"$tpl_text"; then report_ok "fixture: template quote sentinel present"; else report_fail "fixture: template quote sentinel present" "not found"; fi

# ---------------------------------------------------------------------------
# 1. Adopt the template's look on a document that has no named styles
# ---------------------------------------------------------------------------
out1="$WORK/adopt.docx"
json1="$("$TOOL" "$UNSTYLED" --template "$TEMPLATE" --out "$out1" --json)" \
  || report_fail "adopt: operation" "exited non-zero"

assert_eq "adopt: styles adopted count"  "$(jq -r '.styles_adopted_count' <<<"$json1")" "3"
assert_eq "adopt: source unchanged"      "$(jq -r '.source_unchanged' <<<"$json1")" "true"
assert_eq "adopt: template content absent" "$(jq -r '.verification.template_content_absent' <<<"$json1")" "true"
assert_eq "adopt: source content intact" "$(jq -r '.verification.source_content_intact' <<<"$json1")" "true"

if $TMO officecli validate "$out1" >/dev/null 2>&1; then report_ok "adopt: output validates"; else report_fail "adopt: output validates" "officecli validate failed"; fi

# The output's named styles must read back exactly as the template's.
for id in Normal WFBody WFQuote; do
  assert_eq "adopt: style '$id' matches template" "$(style_json "$out1" "$id")" "$(style_json "$TEMPLATE" "$id")"
done
assert_eq "adopt: Normal stays the default" "$(style_field "$out1" Normal default)" "true"

# Page setup reads back as the template's on every section.
assert_eq "adopt: page width"    "$(sec_field "$out1" /section[1] pageWidth)"    "$(sec_field "$TEMPLATE" /section[1] pageWidth)"
assert_eq "adopt: page height"   "$(sec_field "$out1" /section[1] pageHeight)"   "$(sec_field "$TEMPLATE" /section[1] pageHeight)"
assert_eq "adopt: margin top"    "$(sec_field "$out1" /section[1] marginTop)"    "$(sec_field "$TEMPLATE" /section[1] marginTop)"
assert_eq "adopt: margin bottom" "$(sec_field "$out1" /section[1] marginBottom)" "$(sec_field "$TEMPLATE" /section[1] marginBottom)"
assert_eq "adopt: margin left"   "$(sec_field "$out1" /section[1] marginLeft)"   "$(sec_field "$TEMPLATE" /section[1] marginLeft)"
assert_eq "adopt: margin right"  "$(sec_field "$out1" /section[1] marginRight)"  "$(sec_field "$TEMPLATE" /section[1] marginRight)"

# Content isolation: the template's body text never appears, the source's does.
out1_text="$(body_text "$out1")"
if grep -qF "$TPL_SENTINEL_BODY" <<<"$out1_text"; then report_fail "adopt: no template body text" "leaked '$TPL_SENTINEL_BODY'"; else report_ok "adopt: no template body text"; fi
if grep -qF "$TPL_SENTINEL_QUOTE" <<<"$out1_text"; then report_fail "adopt: no template quote text" "leaked '$TPL_SENTINEL_QUOTE'"; else report_ok "adopt: no template quote text"; fi
assert_eq "adopt: source body text intact" "$out1_text" "$(body_text "$UNSTYLED")"
assert_eq "adopt: no header leaked" "$(hf_matches "$out1" header)" "0"
assert_eq "adopt: no footer leaked" "$(hf_matches "$out1" footer)" "0"

# Source protection.
assert_eq "adopt: source bytes unchanged" "$(sha256sum "$UNSTYLED" | awk '{print $1}')" "$unstyled_before"

# ---------------------------------------------------------------------------
# 2. The template outranks the source document's own styles
# ---------------------------------------------------------------------------
out2="$WORK/from-styled.docx"
"$TOOL" "$STYLED" --template "$TEMPLATE" --out "$out2" --json >/dev/null \
  || report_fail "precedence: operation" "exited non-zero"

# The source's Normal is 1.5x; the template's is 1.0792x, so the template wins.
assert_eq "precedence: source Normal line spacing" "$(style_field "$STYLED" Normal lineSpacing)" "1.5x"
assert_eq "precedence: template Normal line spacing" "$(style_field "$TEMPLATE" Normal lineSpacing)" "1.0792x"
assert_eq "precedence: output adopts template spacing" "$(style_field "$out2" Normal lineSpacing)" "1.0792x"

for id in Normal WFBody WFQuote; do
  assert_eq "precedence: template-defined props on '$id'" "$(template_props_match "$TEMPLATE" "$out2" "$id")" ""
done
assert_eq "precedence: source body text intact" "$(body_text "$out2")" "$(body_text "$STYLED")"
assert_eq "precedence: source header intact" "$(hf_text "$out2" header)" "$(hf_text "$STYLED" header)"
assert_eq "precedence: source footer intact" "$(hf_text "$out2" footer)" "$(hf_text "$STYLED" footer)"
assert_eq "precedence: source bytes unchanged" "$(sha256sum "$STYLED" | awk '{print $1}')" "$styled_before"

# ---------------------------------------------------------------------------
# 3. A formatting requirement's overrides beat the template
# ---------------------------------------------------------------------------
req="$WORK/requirement.txt"
printf '# formatting requirement\nmarginTop = 1cm\nlineSpacing = 2x\n' > "$req"
out3="$WORK/override.docx"
report3="$WORK/override-report.json"
json3="$("$TOOL" "$UNSTYLED" --template "$TEMPLATE" --out "$out3" --requirement "$req" --report "$report3" --json)" \
  || report_fail "requirement: operation" "exited non-zero"

assert_eq "requirement: two overrides applied" "$(jq -r '.requirement.applied | length' <<<"$json3")" "2"
assert_eq "requirement: margin beats template" "$(sec_field "$out3" /section[1] marginTop)" "1cm"
assert_eq "requirement: spacing beats template" "$(style_field "$out3" Normal lineSpacing)" "2x"
assert_eq "requirement: template margin was 2.54cm" "$(sec_field "$TEMPLATE" /section[1] marginTop)" "2.54cm"
assert_eq "requirement: source body intact" "$(body_text "$out3")" "$(body_text "$UNSTYLED")"

if [[ -f "$report3" ]] && "$CHANGE_REPORT" validate --report "$report3" >/dev/null 2>&1; then
  report_ok "requirement: change report is valid"
else
  report_fail "requirement: change report is valid" "missing or malformed: $report3"
fi
if jq -e '[.decisions[] | select(test("Formatting requirement"))] | length >= 1' "$report3" >/dev/null 2>&1; then
  report_ok "requirement: decision recorded"
else
  report_fail "requirement: decision recorded" "no formatting-requirement decision"
fi

# ---------------------------------------------------------------------------
# 4. Reproducibility: the same inputs produce the same look
# ---------------------------------------------------------------------------
out4="$WORK/adopt-again.docx"
"$TOOL" "$UNSTYLED" --template "$TEMPLATE" --out "$out4" --json >/dev/null
sig() { # sig <file> — a style + page-setup signature
  local f="$1" id
  for id in Normal WFBody WFQuote; do
    printf '%s=%s;' "$id" "$(style_json "$f" "$id" | jq -c .)"
  done
  printf 'page=%s/%s/%s;' "$(sec_field "$f" /section[1] pageWidth)" "$(sec_field "$f" /section[1] pageHeight)" "$(sec_field "$f" /section[1] marginLeft)"
}
assert_eq "reproducible: identical styles and page setup" "$(sig "$out1")" "$(sig "$out4")"

# ---------------------------------------------------------------------------
# 5. A template with body, table, image, and header/footer content is look-only
# ---------------------------------------------------------------------------
iso_tpl="$WORK/isolated-template.docx"
new_doc "$iso_tpl" en-US
$TMO officecli add "$iso_tpl" /styles --type style --prop styleId=WFTwo --prop name="WF Two" \
  --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=left >/dev/null
$TMO officecli add "$iso_tpl" /body --type paragraph --prop style=WFTwo --prop text="TEMPLATE-BODY-SENTINEL" >/dev/null
$TMO officecli add "$iso_tpl" /body --type table --prop data="TEMPLATE-CELL-A,TEMPLATE-CELL-B" >/dev/null
if [[ -f "$IMAGE" ]]; then
  $TMO officecli add "$iso_tpl" /body --type paragraph --prop text="TEMPLATE-IMAGE-PARA" >/dev/null
  $TMO officecli add "$iso_tpl" /body/p[3] --type picture --prop src="$IMAGE" --prop width=2cm >/dev/null 2>&1 || true
fi
$TMO officecli add "$iso_tpl" / --type header --prop text="TEMPLATE-HEADER-SENTINEL" --prop align=center >/dev/null
$TMO officecli add "$iso_tpl" / --type footer --prop text="TEMPLATE-FOOTER-SENTINEL" --prop align=center >/dev/null
$TMO officecli close "$iso_tpl" >/dev/null 2>&1 || true

out5="$WORK/isolated.docx"
"$TOOL" "$UNSTYLED" --template "$iso_tpl" --out "$out5" --json >/dev/null \
  || report_fail "isolation: operation" "exited non-zero"

out5_text="$(body_text "$out5")"
assert_eq "isolation: source body intact" "$out5_text" "$(body_text "$UNSTYLED")"
if grep -qF 'TEMPLATE-' <<<"$out5_text"; then report_fail "isolation: no template body content" "leaked template text"; else report_ok "isolation: no template body content"; fi
assert_eq "isolation: no header leaked" "$(hf_matches "$out5" header)" "0"
assert_eq "isolation: no footer leaked" "$(hf_matches "$out5" footer)" "0"
assert_eq "isolation: no table leaked"  "$(hf_matches "$out5" table)" "0"
assert_eq "isolation: no picture leaked" "$(hf_matches "$out5" picture)" "0"

# The template's style definition *is* adopted (look), even though its content is not.
if grep -q 'WFTwo' <<<"$(defined_ids "$out5")"; then report_ok "isolation: template style adopted"; else report_fail "isolation: template style adopted" "WFTwo not defined"; fi

# ---------------------------------------------------------------------------
# 6. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$UNSTYLED" --out "$WORK/x.docx" >/dev/null 2>&1;                          assert_eq "bad usage: missing --template exits 2" "$?" "2"
"$TOOL" "$UNSTYLED" --template "$TEMPLATE" >/dev/null 2>&1;                        assert_eq "bad usage: missing --out exits 2"      "$?" "2"
"$TOOL" "$UNSTYLED" --template "$TEMPLATE" --out "$UNSTYLED" >/dev/null 2>&1;      assert_eq "bad usage: --out == source exits 2"    "$?" "2"
"$TOOL" "$WORK/nope.docx" --template "$TEMPLATE" --out "$WORK/y.docx" >/dev/null 2>&1; assert_eq "bad usage: missing source exits 2"   "$?" "2"

# ---------------------------------------------------------------------------
# 7. The output opens without repair in LibreOffice (skipped without soffice)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1 && [[ -x "$COMPAT" ]]; then
  compat_out="$WORK/compat"
  compat_json="$("$COMPAT" "$out1" --apps libreoffice --out "$compat_out" --json 2>/dev/null)"
  if jq -e '.records[] | select(.app=="libreoffice") | .opens_without_repair == true' >/dev/null 2>&1 <<<"$compat_json"; then
    report_ok "compat: LibreOffice opens without repair"
  else
    report_fail "compat: LibreOffice opens without repair" "harness did not report true"
  fi
else
  report_info "compat: LibreOffice verified — SKIPPED (soffice/four harness not available; unverified)"
fi

# ---------------------------------------------------------------------------
# 8. Source protection: the committed fixtures are byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: template unchanged"     "$(sha256sum "$TEMPLATE" | awk '{print $1}')" "$tpl_before"
assert_eq "source protection: unstyled unchanged"     "$(sha256sum "$UNSTYLED" | awk '{print $1}')" "$unstyled_before"
assert_eq "source protection: styled source unchanged" "$(sha256sum "$STYLED" | awk '{print $1}')" "$styled_before"

echo
echo "Template: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
