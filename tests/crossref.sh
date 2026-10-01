#!/usr/bin/env bash
#
# Acceptance tests for WordFlow cross-references (#23) — spec §D8, §D9.
#
# They exercise two things:
#
#   1. the committed fixture tests/fixtures/fields/cached-cross-ref.docx — its
#      content references already carry the resolved target text in their cached
#      result (the #12 mechanism) and no placeholder;
#   2. the operation scripts/wf-crossref.sh — given a source and a bookmark it
#      writes a new output whose content reference caches the bookmark's resolved
#      text; a requested page-number reference is downgraded to a content reference
#      and the downgrade is recorded; the source is untouched and the run is
#      reproducible.
#
# It asserts what OfficeCLI reports back — the cached TEXT of each field, the
# absence of a placeholder, the paragraph a reader sees, schema validity — not the
# exact commands run. When soffice is available the delivered output is driven
# through scripts/wf-compat-harness.sh and checked to open without repair in
# LibreOffice; otherwise that is reported as unverified.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/crossref.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-crossref.sh"
REPORT_TOOL="$ROOT/scripts/wf-change-report.sh"
RISK_TOOL="$ROOT/scripts/wf-risk-policy.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"
FIX_REF="$ROOT/tests/fixtures/fields/cached-cross-ref.docx"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -x "$REPORT_TOOL" ]] || { echo "missing: $REPORT_TOOL" >&2; exit 2; }
[[ -x "$RISK_TOOL" ]] || { echo "missing: $RISK_TOOL" >&2; exit 2; }
[[ -f "$FIX_REF" ]] || { echo "missing fixture: $FIX_REF" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/crossref.XXXXXX")"

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

TMO="timeout 60"

# --- OfficeCLI readback helpers ---------------------------------------------
# field_for <file> <bookmark> -> compact JSON of the last REF field to <bookmark>
field_for() { # <file> <bookmark>
  officecli query "$1" field --json 2>/dev/null | jq -c --arg b "$2" '
    [ .data.results[]?
      | select((.format.instruction // "")
          | split(" ") | map(select(length > 0))
          | (.[0] == "REF" and .[1] == $b)) ] | last // {}'
}
cached_text() { # <file> <bookmark>
  jq -r '.text // ""' <<<"$(field_for "$1" "$2")"
}
instructions() { # <file>
  officecli query "$1" field --json 2>/dev/null | jq -r '[.data.results[]?.format.instruction // ""] | join("|")'
}
placeholder_count() { # <file>
  officecli query "$1" field --json 2>/dev/null \
    | jq -r '[.data.results[]? | select((.text // "") | test("\u00ab|\u00bb"))] | length'
}
para_text() { # <file> <path>
  officecli get "$1" "$2" --json 2>/dev/null | jq -r '.data.results[0].text // ""'
}

new_src() { # new_src <path> — a bookmark "sec_intro" over "Introduction" + a reference paragraph
  local f="$1"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale en-US >/dev/null
  $TMO officecli add "$f" / --type bookmark --prop name=sec_intro --prop text="Introduction" >/dev/null
  $TMO officecli add "$f" /body --type paragraph --prop text="See section " >/dev/null
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

TOOL_OUT=""; TOOL_RC=0
run_tool() { TOOL_OUT="$("$TOOL" "$@" 2>"$WORK/tool.err")"; TOOL_RC=$?; }
json_out() { if [[ -n "${TOOL_OUT:-}" ]]; then printf '%s' "$TOOL_OUT"; else printf '{}'; fi; }

fixture_before="$(sha256sum "$FIX_REF" | awk '{print $1}')"

echo "Cross-references (#23) — $TOOL"
echo

# ---------------------------------------------------------------------------
# 1. The committed fixture's content references cache the resolved text
# ---------------------------------------------------------------------------
assert_eq "fixture: sec_intro bookmark text" \
  "$($TMO officecli get "$FIX_REF" '/bookmark[@name=sec_intro]' --json 2>/dev/null | jq -r '.data.results[0].text')" \
  "Introduction"
assert_eq "fixture: REF cache = resolved target" "$(cached_text "$FIX_REF" sec_intro)" "Introduction"
assert_eq "fixture: no placeholder field" "$(placeholder_count "$FIX_REF")" "0"
if $TMO officecli validate "$FIX_REF" >/dev/null 2>&1; then
  report_ok "fixture: validates"
else
  report_fail "fixture: validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 2. A content reference, end to end: cached text = bookmark's resolved text
# ---------------------------------------------------------------------------
src="$WORK/src.docx"; new_src "$src"
src_before="$(sha256sum "$src" | awk '{print $1}')"
out="$WORK/ref.docx"; rep="$WORK/ref-report.json"
run_tool "$src" --bookmark sec_intro --out "$out" --para /body/p[2] --report "$rep" --json
assert_eq "ref: run exits 0" "$TOOL_RC" "0"
rj="$(json_out)"
assert_eq "ref: requested kind"     "$(jq -r '.requested_kind' <<<"$rj")" "ref"
assert_eq "ref: applied kind"       "$(jq -r '.applied_kind' <<<"$rj")"   "ref"
assert_eq "ref: not downgraded"     "$(jq -r '.downgraded' <<<"$rj")"     "false"
assert_eq "ref: resolved text"      "$(jq -r '.reference.resolved_text' <<<"$rj")" "Introduction"
assert_eq "ref: source unchanged"   "$(jq -r '.source_unchanged' <<<"$rj")" "true"
assert_eq "ref: evidence cached text = resolved" "$(jq -r '.evidence.cached_text' <<<"$rj")" "Introduction"
assert_eq "ref: evidence not placeholder"        "$(jq -r '.evidence.placeholder' <<<"$rj")"  "false"

# what the reader sees: a REF field whose cached text is the resolved target
assert_eq "ref: field instruction is REF" "$(jq -r '.format.instruction' <<<"$(field_for "$out" sec_intro)")" "REF sec_intro"
assert_eq "ref: cached text = resolved target" "$(cached_text "$out" sec_intro)" "Introduction"
assert_eq "ref: no placeholder in output"      "$(placeholder_count "$out")" "0"
assert_contains "ref: paragraph shows resolved text" "$(para_text "$out" /body/p[2])" "See section Introduction"
assert_eq "ref: field is not dirty" "$(jq -r '(.format.dirty // false) | tostring' <<<"$(field_for "$out" sec_intro)")" "false"

if $TMO officecli validate "$out" >/dev/null 2>&1; then
  report_ok "ref: output validates"
else
  report_fail "ref: output validates" "officecli validate failed"
fi
if "$REPORT_TOOL" validate --report "$rep" >/dev/null 2>&1; then
  report_ok "ref: change report valid"
else
  report_fail "ref: change report valid" "$rep failed validation"
fi
assert_contains "ref: report records the cross-reference" \
  "$(jq -r '.changed | join("\n")' "$rep")" "content reference"
assert_eq "ref: source bytes unchanged" "$(sha256sum "$src" | awk '{print $1}')" "$src_before"

# ---------------------------------------------------------------------------
# 3. A requested pageref downgrades to a content reference, and is recorded
# ---------------------------------------------------------------------------
out_p="$WORK/pageref.docx"; rep_p="$WORK/pageref-report.json"
run_tool "$src" --bookmark sec_intro --out "$out_p" --para /body/p[2] --kind pageref --report "$rep_p" --json
assert_eq "pageref: run exits 0" "$TOOL_RC" "0"
pj="$(json_out)"
assert_eq "pageref: requested kind"  "$(jq -r '.requested_kind' <<<"$pj")" "pageref"
assert_eq "pageref: applied kind"    "$(jq -r '.applied_kind' <<<"$pj")"   "ref"
assert_eq "pageref: marked downgraded" "$(jq -r '.downgraded' <<<"$pj")"   "true"
assert_eq "pageref: resolved text"   "$(jq -r '.reference.resolved_text' <<<"$pj")" "Introduction"
assert_eq "pageref: no PAGEREF shipped" "$(instructions "$out_p" | grep -c 'PAGEREF')" "0"
assert_eq "pageref: content reference cached" "$(cached_text "$out_p" sec_intro)" "Introduction"
assert_eq "pageref: no placeholder in output" "$(placeholder_count "$out_p")" "0"
assert_eq "pageref: JSON records one downgrade" "$(jq -r '.downgrades | length' <<<"$pj")" "1"
assert_contains "pageref: downgrade uses the D11 code" "$(jq -r '.downgrades[0]' <<<"$pj")" "[D11-preferred-unavailable]"
assert_eq "pageref: report records one downgrade"   "$(jq -r '.downgrades | length' "$rep_p")" "1"
assert_contains "pageref: report names the downgrade" "$(jq -r '.downgrades[0]' "$rep_p")" "[D11-preferred-unavailable]"
if $TMO officecli validate "$out_p" >/dev/null 2>&1; then
  report_ok "pageref: output validates"
else
  report_fail "pageref: output validates" "officecli validate failed"
fi
assert_eq "pageref: source bytes unchanged" "$(sha256sum "$src" | awk '{print $1}')" "$src_before"

# ---------------------------------------------------------------------------
# 4. Reproducibility: same source + instruction -> same reference
# ---------------------------------------------------------------------------
repro_a="$WORK/repro-a.docx"; repro_b="$WORK/repro-b.docx"
run_tool "$src" --bookmark sec_intro --out "$repro_a" --para /body/p[2] --json
run_tool "$src" --bookmark sec_intro --out "$repro_b" --para /body/p[2] --json
sig() { printf '%s|%s|%s' "$(instructions "$1")" "$(cached_text "$1" sec_intro)" "$(para_text "$1" /body/p[2])"; }
assert_eq "reproducible: identical reference" "$(sig "$repro_a")" "$(sig "$repro_b")"

# ---------------------------------------------------------------------------
# 5. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
run_tool "$src" --out "$WORK/z.docx";                                       assert_eq "bad usage: missing --bookmark exits 2" "$TOOL_RC" "2"
run_tool "$src" --bookmark sec_intro;                                       assert_eq "bad usage: missing --out exits 2"      "$TOOL_RC" "2"
run_tool "$WORK/nope.docx" --bookmark sec_intro --out "$WORK/z.docx";       assert_eq "bad usage: missing source exits 2"     "$TOOL_RC" "2"
run_tool "$src" --bookmark sec_intro --out "$src";                          assert_eq "bad usage: --out == source exits 2"    "$TOOL_RC" "2"
run_tool "$src" --bookmark sec_intro --out "$WORK/z.docx" --kind footref;   assert_eq "bad usage: bad --kind exits 2"         "$TOOL_RC" "2"
run_tool "$src" --bookmark missing --out "$WORK/z.docx";                    assert_eq "unresolvable bookmark exits 1"         "$TOOL_RC" "1"

# ---------------------------------------------------------------------------
# 6. LibreOffice opens the delivered output without repair (skipped if absent)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$out" --apps libreoffice --out "$compat_out" >/dev/null 2>&1 \
     && [[ -f "$compat_out/result.json" ]]; then
    rv="$(jq -r '[.records[]? | select(.app=="libreoffice") | .opens_without_repair] | first // "missing"' "$compat_out/result.json")"
    assert_eq "compat: LibreOffice opens without repair" "$rv" "true"
    ph="$(jq -r '[.records[]? | select(.app=="libreoffice") | .field_cache.placeholder_count] | first // "missing"' "$compat_out/result.json")"
    assert_eq "compat: LibreOffice placeholder_count 0" "$ph" "0"
  else
    report_fail "compat: harness run" "no result.json under $compat_out"
  fi
else
  report_info "compat: LibreOffice open-without-repair — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 7. Source protection: the committed fixture is byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: fixture unchanged" "$(sha256sum "$FIX_REF" | awk '{print $1}')" "$fixture_before"

echo
echo "Cross-reference: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
