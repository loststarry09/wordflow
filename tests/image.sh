#!/usr/bin/env bash
#
# Acceptance tests for WordFlow image placement (#20).
#
# They exercise two things:
#
#   1. the committed fixtures tests/fixtures/images/inline-image.docx and
#      anchored-image.docx — they carry the exact OfficeCLI constructions from
#      tests/generate-fixtures.sh: inline is `wp:inline`, anchored is `wp:anchor`;
#   2. the operation scripts/wf-image.sh — given a source it writes a new output
#      with the image placed in the text flow, leaves the source untouched, is
#      reproducible, clamps an over-wide image to the text column, downgrades a
#      requested anchored image to a centred inline one and records the
#      downgrade in the change report, and rejects bad usage.
#
# It asserts what OfficeCLI reports back, not the exact commands run. When
# soffice is available the delivered output is driven through
# scripts/wf-compat-harness.sh and checked to open without repair in
# LibreOffice; otherwise that is reported as unverified.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/image.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-image.sh"
REPORT_TOOL="$ROOT/scripts/wf-change-report.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"
IMG="$ROOT/tests/fixtures/assets/test-image.png"
FIX_INLINE="$ROOT/tests/fixtures/images/inline-image.docx"
FIX_ANCHORED="$ROOT/tests/fixtures/images/anchored-image.docx"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -x "$REPORT_TOOL" ]] || { echo "missing: $REPORT_TOOL" >&2; exit 2; }
for f in "$IMG" "$FIX_INLINE" "$FIX_ANCHORED"; do
  [[ -f "$f" ]] || { echo "missing fixture/asset: $f" >&2; exit 2; }
done

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/image.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "missing '$3' in '$2'"; fi
}
assert_le() { # assert_le <name> <a> <b>  (a <= b, numeric)
  if awk -v a="$2" -v b="$3" 'BEGIN { exit !(a <= b) }'; then report_ok "$1"; else report_fail "$1" "$2 > $3"; fi
}
assert_approx() { # assert_approx <name> <value> <expected> <tolerance-cm>
  if awk -v a="$2" -v b="$3" -v t="$4" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; then
    report_ok "$1"
  else
    report_fail "$1" "expected ≈$3 (±$4), got $2"
  fi
}

TMO="timeout 60"

cm() { # cm <length> -> centimetres
  awk -v v="$1" 'BEGIN {
    if (v ~ /cm$/)      { sub(/cm$/, "", v) }
    else if (v ~ /in$/) { sub(/in$/, "", v); v = v * 2.54 }
    else if (v ~ /pt$/) { sub(/pt$/, "", v); v = v / 72 * 2.54 }
    printf "%.4f", v + 0
  }'
}

pics_json()       { $TMO officecli query "$1" picture --json; }
pics_count()      { pics_json "$1" | jq -r '.data.results | length'; }
anchored_count()  { pics_json "$1" | jq -r '[.data.results[]? | select((.format.anchor // false) == true or ((.format.wrap // "inline") != "inline"))] | length'; }
pic_field()       { pics_json "$1" | jq -r --arg k "$2" '.data.results[0].format[$k] // ""'; }

# picture signature for reproducibility: width|height|wrap|anchor|alt per image
pic_sig() {
  pics_json "$1" | jq -r '[.data.results[]? | (.format.width // "") + "|" + (.format.height // "")
    + "|" + (.format.wrap // "") + "|" + ((.format.anchor // false) | tostring)
    + "|" + (.format.alt // "")] | join(";")'
}

# lo_repair <result.json> — LibreOffice open-without-repair. The harness
# (wordflow.compat-harness/v1) reports per-document records; the documented
# `.documents[].applications.libreoffice.opensWithoutRepair` shape is accepted
# too, should the harness expose it.
lo_repair() {
  jq -r '
    if (.documents? | type == "array") then
      ([.documents[].applications?.libreoffice?.opensWithoutRepair] | first // "missing")
    else
      ([.records[]? | select(.app == "libreoffice") | .opens_without_repair] | first // "missing")
    end
  ' "$1" 2>/dev/null || echo "missing"
}

new_doc() { # new_doc <path>
  local f="$1"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale en-US >/dev/null
  $TMO officecli add "$f" /body --type paragraph --prop text="Figure placeholder." >/dev/null
  $TMO officecli close "$f" >/dev/null 2>&1 || true
}

cleanup() {
  for f in "$WORK"/*.docx; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

inline_fixture_before="$(sha256sum "$FIX_INLINE" | awk '{print $1}')"
anchored_fixture_before="$(sha256sum "$FIX_ANCHORED" | awk '{print $1}')"

TOOL_OUT=""; TOOL_RC=0
run_tool() { TOOL_OUT="$("$TOOL" "$@" 2>"$WORK/tool.err")"; TOOL_RC=$?; }
json_out() { if [[ -n "${TOOL_OUT:-}" ]]; then printf '%s' "$TOOL_OUT"; else printf '{}'; fi; }

echo "Images (#20) — $TOOL"
echo

# ---------------------------------------------------------------------------
# 1. The fixtures carry the exact constructions (inline vs anchored)
# ---------------------------------------------------------------------------
assert_eq "fixture inline: one picture"      "$(pics_count "$FIX_INLINE")" "1"
assert_eq "fixture inline: wrap is inline"   "$(pic_field "$FIX_INLINE" wrap)" "inline"
assert_eq "fixture inline: not anchored"     "$(pic_field "$FIX_INLINE" anchor)" ""
assert_eq "fixture anchored: one picture"    "$(pics_count "$FIX_ANCHORED")" "1"
assert_eq "fixture anchored: is anchored"    "$(anchored_count "$FIX_ANCHORED")" "1"
assert_eq "fixture anchored: wrap"           "$(pic_field "$FIX_ANCHORED" wrap)" "topandbottom"

# ---------------------------------------------------------------------------
# 2. Inline placement: present, requested width, source untouched
# ---------------------------------------------------------------------------
src="$WORK/src.docx"; new_doc "$src"
src_before="$(sha256sum "$src" | awk '{print $1}')"
out="$WORK/inline.docx"; rep="$WORK/inline-report.json"
run_tool "$src" --image "$IMG" --out "$out" --width 3cm --alt "Test image" --report "$rep" --json
assert_eq "inline: run exits 0" "$TOOL_RC" "0"
ij="$(json_out)"
assert_eq "inline: placement is inline"     "$(jq -r '.placement // ""' <<<"$ij")" "inline"
assert_eq "inline: no anchored requested"   "$(jq -r '.anchored_requested' <<<"$ij")" "false"
assert_eq "inline: no anchored in output"   "$(jq -r '.anchored_present' <<<"$ij")" "0"
assert_eq "inline: source unchanged flag"   "$(jq -r '.source_unchanged' <<<"$ij")" "true"
assert_eq "inline: one picture in output"   "$(pics_count "$out")" "1"
assert_eq "inline: output wrap inline"      "$(pic_field "$out" wrap)" "inline"
assert_eq "inline: output not anchored"     "$(pic_field "$out" anchor)" ""
assert_approx "inline: requested width"     "$(cm "$(pic_field "$out" width)")" "3.0" "0.06"
assert_eq "inline: alt text"                "$(pic_field "$out" alt)" "Test image"
assert_eq "inline: source bytes unchanged"  "$(sha256sum "$src" | awk '{print $1}')" "$src_before"
if $TMO officecli validate "$out" >/dev/null 2>&1; then
  report_ok "inline: output validates"
else
  report_fail "inline: output validates" "officecli validate failed"
fi
if "$REPORT_TOOL" validate --report "$rep" >/dev/null 2>&1; then
  report_ok "inline: change report valid"
else
  report_fail "inline: change report valid" "$rep failed validation"
fi
assert_eq "inline: report records the placement" \
  "$(jq -r '[.changed[]? | select(test("placed an inline image"; "i"))] | length' "$rep")" "1"
# The default target is the existing /body/p[1]; no paragraph may be injected.
assert_eq "inline: no extra paragraph injected (default path)" \
  "$(officecli query "$out" paragraph --json 2>/dev/null | jq -r '.data.results | length')" \
  "$(officecli query "$src" paragraph --json 2>/dev/null | jq -r '.data.results | length')"

# ---------------------------------------------------------------------------
# 2b. An explicit --para places the image in that paragraph, with no extra
#     paragraph injected (regression guard).
# ---------------------------------------------------------------------------
para_src="$WORK/para-src.docx"
$TMO officecli close "$para_src" >/dev/null 2>&1 || true
rm -f "$para_src"
$TMO officecli create "$para_src" --locale en-US >/dev/null
$TMO officecli add "$para_src" /body --type paragraph --prop text="First paragraph." >/dev/null
$TMO officecli add "$para_src" /body --type paragraph --prop text="Second paragraph (image target)." >/dev/null
$TMO officecli add "$para_src" /body --type paragraph --prop text="Third paragraph." >/dev/null
$TMO officecli close "$para_src" >/dev/null 2>&1 || true
para_before="$(officecli query "$para_src" paragraph --json 2>/dev/null | jq -r '.data.results | length')"
p2_pid="$(officecli get "$para_src" /body/p[2] --json 2>/dev/null | jq -r '.data.results[0].format.paraId // ""')"

outp="$WORK/explicit-para.docx"
run_tool "$para_src" --image "$IMG" --out "$outp" --para /body/p[2] --width 2cm --json
assert_eq "explicit --para: run exits 0" "$TOOL_RC" "0"
assert_eq "explicit --para: one picture" "$(pics_count "$outp")" "1"
assert_eq "explicit --para: no extra paragraph" \
  "$(officecli query "$outp" paragraph --json 2>/dev/null | jq -r '.data.results | length')" "$para_before"
assert_eq "explicit --para: image is in p[2]" \
  "$(pics_json "$outp" | jq -r --arg pid "$p2_pid" '[.data.results[]? | select((.path // "") | contains("paraId=" + $pid))] | length')" "1"

# ---------------------------------------------------------------------------
# 3. A requested anchored image is downgraded, and the downgrade is recorded
# ---------------------------------------------------------------------------
out2="$WORK/anchored.docx"; rep2="$WORK/anchored-report.json"
run_tool "$src" --image "$IMG" --out "$out2" --width 3cm --alt "Anchored test" --anchor --report "$rep2" --json
assert_eq "anchored: run exits 0" "$TOOL_RC" "0"
aj="$(json_out)"
assert_eq "anchored: placement downgraded"   "$(jq -r '.placement // ""' <<<"$aj")" "inline-downgraded"
assert_eq "anchored: anchor was requested"   "$(jq -r '.anchored_requested' <<<"$aj")" "true"
assert_eq "anchored: no anchored in output"  "$(anchored_count "$out2")" "0"
assert_eq "anchored: one inline picture"     "$(pics_count "$out2")" "1"
assert_eq "anchored: output wrap inline"     "$(pic_field "$out2" wrap)" "inline"
assert_eq "anchored: JSON records downgrade" "$(jq -r '.downgrades | length' <<<"$aj")" "1"
assert_eq "anchored: report has downgrade"   "$(jq -r '.downgrades | length' "$rep2")" "1"
assert_contains "anchored: downgrade uses D11 code" \
  "$(jq -r '.downgrades[0]' "$rep2")" "[D11-preferred-unavailable]"
assert_eq "anchored: source bytes unchanged" "$(sha256sum "$src" | awk '{print $1}')" "$src_before"

# ---------------------------------------------------------------------------
# 4. Width is constrained to the text column
# ---------------------------------------------------------------------------
out3="$WORK/wide.docx"; rep3="$WORK/wide-report.json"
run_tool "$src" --image "$IMG" --out "$out3" --width 40cm --report "$rep3" --json
assert_eq "wide: run exits 0" "$TOOL_RC" "0"
wj="$(json_out)"
assert_eq "wide: clamp recorded"     "$(jq -r '.image.clamped' <<<"$wj")" "true"
assert_le "wide: applied <= column"  "$(jq -r '.image.applied_width_cm' <<<"$wj")" "$(jq -r '.image.text_column_cm' <<<"$wj")"
assert_le "wide: output <= column"   "$(cm "$(pic_field "$out3" width)")" "$(jq -r '.image.text_column_cm' <<<"$wj")"
assert_eq "wide: clamp is reported" \
  "$(jq -r '[.change_report[]? | select(test("clamp"; "i"))] | length' <<<"$wj")" "1"
assert_contains "wide: overflow is noted" \
  "$(jq -r '.change_report[]' <<<"$wj")" "overflow"

out4="$WORK/narrow.docx"
run_tool "$src" --image "$IMG" --out "$out4" --width 2cm --json
nj="$(json_out)"
assert_eq "narrow: not clamped" "$(jq -r '.image.clamped' <<<"$nj")" "false"
assert_approx "narrow: applied width" "$(cm "$(pic_field "$out4" width)")" "2.0" "0.06"

out5="$WORK/default-width.docx"
run_tool "$src" --image "$IMG" --out "$out5" --json
dj="$(json_out)"
assert_eq "default width: recorded decision" "$(jq -r '[.decisions[]? | select(test("default"; "i"))] | length' <<<"$dj")" "1"
assert_approx "default width: applied" "$(cm "$(pic_field "$out5" width)")" "3.0" "0.06"

# ---------------------------------------------------------------------------
# 5. Reproducibility: same source + instructions -> identical picture structure
# ---------------------------------------------------------------------------
rep_a="$WORK/repro-a.docx"; rep_b="$WORK/repro-b.docx"
run_tool "$src" --image "$IMG" --out "$rep_a" --width 3cm --alt "Repro" --json
run_tool "$src" --image "$IMG" --out "$rep_b" --width 3cm --alt "Repro" --json
assert_eq "reproducible: identical picture structure" "$(pic_sig "$rep_a")" "$(pic_sig "$rep_b")"

# ---------------------------------------------------------------------------
# 6. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
run_tool "$src" --image "$IMG";                                      assert_eq "bad usage: missing --out exits 2"     "$TOOL_RC" "2"
run_tool "$src" --image "$IMG" --out "$src";                         assert_eq "bad usage: --out == source exits 2"   "$TOOL_RC" "2"
run_tool "$WORK/nope.docx" --image "$IMG" --out "$WORK/x.docx";      assert_eq "bad usage: missing source exits 2"    "$TOOL_RC" "2"
run_tool "$src" --image "$WORK/nope.png" --out "$WORK/x.docx";       assert_eq "bad usage: missing image exits 2"     "$TOOL_RC" "2"
run_tool "$src" --image "$IMG" --out "$WORK/x.docx" --width 5mm;     assert_eq "bad usage: bad width exits 2"         "$TOOL_RC" "2"
run_tool "$src" --image "$IMG" --out "$WORK/x.docx" --para /body/p[9]; assert_eq "bad usage: missing paragraph exits 2" "$TOOL_RC" "2"

# ---------------------------------------------------------------------------
# 7. LibreOffice opens the downgraded output without repair (skipped if absent)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$out2" --apps libreoffice --out "$compat_out" >/dev/null 2>&1 \
     && [[ -f "$compat_out/result.json" ]]; then
    rv="$(lo_repair "$compat_out/result.json")"
    assert_eq "compat: LibreOffice opens without repair" "$rv" "true"
  else
    report_fail "compat: harness run" "no result.json under $compat_out"
  fi
else
  report_info "compat: LibreOffice open-without-repair — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 8. Source protection: the committed fixtures are byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: inline fixture unchanged"   "$(sha256sum "$FIX_INLINE" | awk '{print $1}')"   "$inline_fixture_before"
assert_eq "source protection: anchored fixture unchanged" "$(sha256sum "$FIX_ANCHORED" | awk '{print $1}')" "$anchored_fixture_before"

echo
echo "Image: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
