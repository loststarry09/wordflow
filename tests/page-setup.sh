#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow page-setup primitive (#18).
#
# They exercise the *external behaviour* of scripts/wf-page-setup.sh: given a
# source document it must write a new output with the WordFlow default page
# setup (spec §D6) or an explicit override, apply it across the document's
# sections, preserve the section-break model, and never modify the source.
#
# They assert what OfficeCLI reports back (page size, orientation, margins,
# sections), not the exact commands the operation runs internally.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH.
# Usage: tests/page-setup.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-page-setup.sh"
FIXTURE="$FIX/sections/page-setup-default.docx"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -f "$FIXTURE" ]] || { echo "missing fixture: $FIXTURE" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/page-setup.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

TMO="timeout 60"

# Read one property of one section back through OfficeCLI.
sec_field() { # sec_field <file> <section-path> <key>
  $TMO officecli query "$1" section --json \
    | jq -r --arg p "$2" --arg k "$3" '.data.results[] | select(.path==$p) | .format[$k] // ""'
}

section_paths() { # section_paths <file>
  $TMO officecli query "$1" section --json | jq -r '[.data.results[].path] | join(",")'
}

cleanup() {
  for f in "$WORK"/*.docx; do [[ -e "$f" ]] && $TMO officecli close "$f" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

fixture_before="$(sha256sum "$FIXTURE" | awk '{print $1}')"

echo "Page setup (#18) — $TOOL"

# ---------------------------------------------------------------------------
# 0. The fixture itself: default page setup across a section break
# ---------------------------------------------------------------------------
assert_eq "fixture: two sections"       "$(section_paths "$FIXTURE")" "/section[1],/section[2]"
assert_eq "fixture: [1] carries break"  "$(sec_field "$FIXTURE" /section[1] sectionType)" "nextPage"
assert_eq "fixture: [1] margin left"    "$(sec_field "$FIXTURE" /section[1] marginLeft)"  "3.17cm"
assert_eq "fixture: [1] margin right"   "$(sec_field "$FIXTURE" /section[1] marginRight)" "3.17cm"
assert_eq "fixture: [2] margin left"    "$(sec_field "$FIXTURE" /section[2] marginLeft)"  "3.17cm"
assert_eq "fixture: [2] width"          "$(sec_field "$FIXTURE" /section[2] pageWidth)"   "21cm"
assert_eq "fixture: [2] orientation"    "$(sec_field "$FIXTURE" /section[2] orientation)" "portrait"

# ---------------------------------------------------------------------------
# 1. Default page setup and the multi-section model
# ---------------------------------------------------------------------------
out="$WORK/default.docx"
json="$("$TOOL" "$FIXTURE" --out "$out" --json)" || report_fail "default: operation" "exited non-zero"

assert_eq "default: page size"        "$(jq -r '.page_setup.page_size'   <<<"$json")" "A4"
assert_eq "default: orientation"      "$(jq -r '.page_setup.orientation' <<<"$json")" "portrait"
assert_eq "default: page width"       "$(jq -r '.page_setup.page_width'  <<<"$json")" "21cm"
assert_eq "default: page height"      "$(jq -r '.page_setup.page_height' <<<"$json")" "29.7cm"
assert_eq "default: margin top"       "$(jq -r '.page_setup.margin_top'    <<<"$json")" "2.54cm"
assert_eq "default: margin bottom"    "$(jq -r '.page_setup.margin_bottom' <<<"$json")" "2.54cm"
assert_eq "default: margin left"      "$(jq -r '.page_setup.margin_left'   <<<"$json")" "3.17cm"
assert_eq "default: margin right"     "$(jq -r '.page_setup.margin_right'  <<<"$json")" "3.17cm"
assert_eq "default: no overrides"     "$(jq -r '.overrides | length'       <<<"$json")" "0"
assert_eq "default: source unchanged" "$(jq -r '.source_unchanged'         <<<"$json")" "true"

# The multi-section document keeps both sections, both at the D6 setup.
assert_eq "default: two sections"     "$(section_paths "$out")" "/section[1],/section[2]"
assert_eq "default: section[1] type"  "$(sec_field "$out" /section[1] sectionType)" "nextPage"
for s in /section[1] /section[2]; do
  assert_eq "default: $s width"       "$(sec_field "$out" "$s" pageWidth)"    "21cm"
  assert_eq "default: $s height"      "$(sec_field "$out" "$s" pageHeight)"   "29.7cm"
  assert_eq "default: $s orientation" "$(sec_field "$out" "$s" orientation)"  "portrait"
  assert_eq "default: $s margin left" "$(sec_field "$out" "$s" marginLeft)"   "3.17cm"
  assert_eq "default: $s margin right" "$(sec_field "$out" "$s" marginRight)" "3.17cm"
  assert_eq "default: $s margin top"  "$(sec_field "$out" "$s" marginTop)"    "2.54cm"
  assert_eq "default: $s margin bottom" "$(sec_field "$out" "$s" marginBottom)" "2.54cm"
done

# ---------------------------------------------------------------------------
# 2. An explicit override (a formatting requirement) wins over the default
# ---------------------------------------------------------------------------
out="$WORK/override.docx"
json="$("$TOOL" "$FIXTURE" --out "$out" \
  --page-size Letter --orientation landscape \
  --margin-top 1cm --margin-bottom 1cm --margin-left 1.5cm --margin-right 1.5cm --json)" \
  || report_fail "override: operation" "exited non-zero"

assert_eq "override: page size"     "$(jq -r '.page_setup.page_size'   <<<"$json")" "Letter"
assert_eq "override: orientation"   "$(jq -r '.page_setup.orientation' <<<"$json")" "landscape"
assert_eq "override: page width"    "$(jq -r '.page_setup.page_width'  <<<"$json")" "27.94cm"
assert_eq "override: page height"   "$(jq -r '.page_setup.page_height' <<<"$json")" "21.59cm"
assert_eq "override: overrides shown" "$(jq -r '.overrides | length'   <<<"$json")" "6"
assert_eq "override: section width" "$(sec_field "$out" /section[1] pageWidth)" "27.94cm"
assert_eq "override: section height" "$(sec_field "$out" /section[1] pageHeight)" "21.59cm"
assert_eq "override: orientation"   "$(sec_field "$out" /section[1] orientation)" "landscape"
assert_eq "override: margin top"    "$(sec_field "$out" /section[1] marginTop)" "1cm"
assert_eq "override: margin left"   "$(sec_field "$out" /section[1] marginLeft)" "1.5cm"

# ---------------------------------------------------------------------------
# 3. A custom page size, used as given
# ---------------------------------------------------------------------------
out="$WORK/custom.docx"
json="$("$TOOL" "$FIXTURE" --out "$out" --page-width 18cm --page-height 24cm --json)" \
  || report_fail "custom: operation" "exited non-zero"
assert_eq "custom: page size label" "$(jq -r '.page_setup.page_size' <<<"$json")" "custom"
assert_eq "custom: section width"   "$(sec_field "$out" /section[1] pageWidth)"  "18cm"
assert_eq "custom: section height"  "$(sec_field "$out" /section[1] pageHeight)" "24cm"

# ---------------------------------------------------------------------------
# 4. Per-section override: one section changes, the other keeps its setup
# ---------------------------------------------------------------------------
out="$WORK/per-section.docx"
json="$("$TOOL" "$FIXTURE" --out "$out" --section 2 --page-size A3 --orientation landscape --json)" \
  || report_fail "per-section: operation" "exited non-zero"
assert_eq "per-section: applied to [2]" "$(jq -r '.sections_applied | join(",")' <<<"$json")" "/section[2]"
assert_eq "per-section: [2] width"      "$(sec_field "$out" /section[2] pageWidth)"    "42cm"
assert_eq "per-section: [2] height"     "$(sec_field "$out" /section[2] pageHeight)"   "29.7cm"
assert_eq "per-section: [2] orient"     "$(sec_field "$out" /section[2] orientation)"  "landscape"
assert_eq "per-section: [1] width kept" "$(sec_field "$out" /section[1] pageWidth)"    "21cm"
assert_eq "per-section: [1] orient kept" "$(sec_field "$out" /section[1] orientation)" "portrait"
assert_eq "per-section: [1] type kept"  "$(sec_field "$out" /section[1] sectionType)"  "nextPage"
assert_eq "per-section: margin left not overridden" "$(sec_field "$out" /section[2] marginLeft)" "3.17cm"

# ---------------------------------------------------------------------------
# 5. Reproducibility: same source + same inputs -> same page setup
# ---------------------------------------------------------------------------
a="$WORK/repro-a.docx"; b="$WORK/repro-b.docx"
"$TOOL" "$FIXTURE" --out "$a" --json >/dev/null
"$TOOL" "$FIXTURE" --out "$b" --json >/dev/null
assert_eq "reproducible: page setup identical" "$(sec_field "$a" /section[1] pageWidth)/$(sec_field "$a" /section[1] marginLeft)" \
                                                "$(sec_field "$b" /section[1] pageWidth)/$(sec_field "$b" /section[1] marginLeft)"

# ---------------------------------------------------------------------------
# 6. Source protection: the committed fixture is byte-identical afterwards
# ---------------------------------------------------------------------------
fixture_after="$(sha256sum "$FIXTURE" | awk '{print $1}')"
assert_eq "source protection: fixture unchanged" "$fixture_after" "$fixture_before"

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$FIXTURE" >/dev/null 2>&1
assert_eq "bad usage: missing --out exits 2" "$?" "2"

"$TOOL" "$FIXTURE" --out "$FIXTURE" >/dev/null 2>&1
assert_eq "bad usage: --out == source exits 2" "$?" "2"

"$TOOL" "$FIXTURE" --out "$WORK/x.docx" --page-size Nope >/dev/null 2>&1
assert_eq "bad usage: unknown size exits 2" "$?" "2"

"$TOOL" "$FIXTURE" --out "$WORK/x.docx" --page-width 18cm >/dev/null 2>&1
assert_eq "bad usage: width without height exits 2" "$?" "2"

"$TOOL" "$FIXTURE" --out "$WORK/x.docx" --section 9 >/dev/null 2>&1
assert_eq "bad usage: out-of-range section exits 2" "$?" "2"

echo
echo "Page setup: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
