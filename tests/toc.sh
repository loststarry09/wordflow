#!/usr/bin/env bash
#
# Acceptance tests for the table of contents (#24, spec §D8/§D9).
#
# They exercise the operation scripts/wf-toc.sh end-to-end and the committed
# fixtures it targets:
#
#   * tests/fixtures/toc/toc-no-page-numbers.docx — a real TOC field with a
#     number-free cache and three headings on three pages;
#   * tests/fixtures/styles/standard-style-set.docx — the frozen standard set
#     (its TOC 1..TOC 3 styles already defined) and headings 1..4.
#
# The tests assert what OfficeCLI reports back — the TOC field instruction, the
# cached entry text (never its evaluated flag), no PAGEREF / tab page-number
# reference, no placeholder, no dangling style, source protection, and
# reproducibility — not the exact commands the tool runs. They also prove the
# TOC is a live field by turning page numbers on in a scratch copy and
# refreshing. LibreOffice opens-without-repair is checked through
# scripts/wf-compat-harness.sh when soffice is available.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH. Usage:
# tests/toc.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_TOC="$ROOT/tests/fixtures/toc/toc-no-page-numbers.docx"
FIX_STD="$ROOT/tests/fixtures/styles/standard-style-set.docx"
TOOL="$ROOT/scripts/wf-toc.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -f "$FIX_TOC" ]] || { echo "missing fixture: $FIX_TOC" >&2; exit 2; }
[[ -f "$FIX_STD" ]] || { echo "missing fixture: $FIX_STD" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/toc.XXXXXX")"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_gt0() { # <label> <value>
  if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 )); then report_ok "$1"; else report_fail "$1" "expected > 0, got '$2'"; fi
}

TMO="timeout 60"

# --- OfficeCLI reads ---------------------------------------------------------

raw_doc() { $TMO officecli raw "$1" /document 2>/dev/null || true; }

toc_fields() { # <file> — compact array of TOC fields
  $TMO officecli query "$1" field --json 2>/dev/null \
    | jq -c '[.data.results[]? | select((.format.instruction // "") | startswith("TOC"))]'
}
toc_count() { toc_fields "$1" | jq 'length'; }
toc_instr() { toc_fields "$1" | jq -r '.[0].format.instruction // ""'; }
toc_cache() { toc_fields "$1" | jq -r '.[0].text // ""'; }

# Cached entry paragraphs: the TOC1/TOC2/… styled paragraphs refresh writes.
entries_json() { # <file>
  $TMO officecli query "$1" paragraph --json 2>/dev/null \
    | jq -c '[.data.results[]? | select((.format.styleId // "") | test("^TOC[1-9]$"))
              | {level: (.format.styleId | capture("TOC(?<n>[1-9])").n | tonumber), text: (.text // "")}]'
}
entry_count() { entries_json "$1" | jq 'length'; }
entry_texts() { entries_json "$1" | jq -r '[.[].text] | join("|")'; }
entry_levels() { entries_json "$1" | jq -r '[.[].level] | join(",")'; }

pageref_count() { raw_doc "$1" | grep -o 'PAGEREF' | wc -l | tr -d ' '; }
tab_count() { raw_doc "$1" | grep -o '<w:tab' | wc -l | tr -d ' '; }
fldchar_begin_count() { raw_doc "$1" | grep -o 'w:fldCharType="begin"' | wc -l | tr -d ' '; }
fldchar_end_count() { raw_doc "$1" | grep -o 'w:fldCharType="end"' | wc -l | tr -d ' '; }

placeholder_count() { # <file> — TOC caches that are the unresolved wording or «»
  toc_fields "$1" | jq -r '
    [.[] | select((.text // "") | test("\u00ab|\u00bb|Update field to see table of contents"; "i"))] | length'
}

# A heading text appears in the cache (refresh concatenates the entries).
cache_has() { jq -rn --arg s "$(toc_cache "$1")" --arg t "$2" '$s | contains($t)'; }

defined_ids() { # <file> -> sorted comma-joined styleIds
  $TMO officecli get "$1" /styles --json 2>/dev/null \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}
style_defined() { # <file> <styleId>
  grep -qx "$2" <(defined_ids "$1" | tr ',' '\n')
}
referenced_ids() { # <file> — pStyle/rStyle across every part
  { $TMO officecli raw "$1" /document
    $TMO officecli raw "$1" /footnotes
    $TMO officecli raw "$1" /header[1]
    $TMO officecli raw "$1" /footer[1]
  } 2>/dev/null \
    | grep -oE 'w:(pStyle|rStyle) w:val="[^"]+"' \
    | sed -E 's/.*w:val="([^"]+)".*/\1/' | sort -u | paste -sd, -
}
dangling() { # <file> -> comma-joined referenced-but-undefined styles
  comm -23 <(referenced_ids "$1" | tr ',' '\n' | sort -u) \
           <(defined_ids "$1" | tr ',' '\n' | sort -u) | paste -sd, -
}

new_doc() { # <path>
  local f="$1"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale en-US >/dev/null
}

# Stable layout signature: instruction + entry texts + cache text.
layout_sig() { printf '%s#%s#%s\n' "$(toc_instr "$1")" "$(entry_texts "$1")" "$(toc_cache "$1")"; }

cleanup() {
  for f in "$WORK"/*.docx; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

toc_before="$(sha256sum "$FIX_TOC" | awk '{print $1}')"
std_before="$(sha256sum "$FIX_STD" | awk '{print $1}')"

echo "Table of contents (#24) — $FIX_TOC"
echo

# ---------------------------------------------------------------------------
# 0. Preconditions: the fixtures carry a real, number-free TOC
# ---------------------------------------------------------------------------
assert_eq "fixture: one TOC field"          "$(toc_count "$FIX_TOC")" "1"
assert_eq "fixture: cache lists entry 1"    "$(cache_has "$FIX_TOC" "Alpha Section")" "true"
assert_eq "fixture: cache lists entry 2"    "$(cache_has "$FIX_TOC" "Beta Section")" "true"
assert_eq "fixture: cache lists entry 3"    "$(cache_has "$FIX_TOC" "Gamma Subsection")" "true"
assert_eq "fixture: no PAGEREF"             "$(pageref_count "$FIX_TOC")" "0"
assert_eq "fixture: no placeholder"         "$(placeholder_count "$FIX_TOC")" "0"
assert_eq "fixture: no dangling style"      "$(dangling "$FIX_TOC")" ""
if $TMO officecli validate "$FIX_TOC" >/dev/null 2>&1; then
  report_ok "fixture validates"
else
  report_fail "fixture validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 1. End-to-end on the number-free fixture: entries, no page numbers, no placeholder
# ---------------------------------------------------------------------------
out1="$WORK/out-toc.docx"
json="$("$TOOL" "$FIX_TOC" --out "$out1" --json || true)"
if jq -e . >/dev/null 2>&1 <<<"$json"; then report_ok "tool emitted valid JSON"; else report_fail "tool emitted valid JSON" "$json"; fi
assert_eq "run: source unchanged"     "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "run: one TOC field"        "$(jq -r '.evidence.toc_field_count' <<<"$json")" "1"
assert_eq "run: entry count 3"        "$(jq -r '.evidence.entry_count' <<<"$json")" "3"
assert_eq "run: heading count 3"      "$(jq -r '.evidence.heading_count' <<<"$json")" "3"
assert_eq "run: no PAGEREF"           "$(jq -r '.evidence.pageref_count' <<<"$json")" "0"
assert_eq "run: not a placeholder"    "$(jq -r '.evidence.placeholder' <<<"$json")" "false"
assert_eq "run: page numbers omitted" "$(jq -r '.evidence.page_numbers' <<<"$json")" "false"

assert_eq "output: one TOC field"     "$(toc_count "$out1")" "1"
assert_eq "output: instruction levels" "$(jq -rn --arg s "$(toc_instr "$out1")" '$s | contains("\\o \"1-3\"")')" "true"
assert_eq "output: instruction has \\h" "$(jq -rn --arg s "$(toc_instr "$out1")" '$s | contains("\\h")')" "true"
assert_eq "output: instruction uses \\z not \\n" \
  "$(jq -rn --arg s "$(toc_instr "$out1")" '$s | (contains("\\z") and (contains("\\n") | not))')" "true"
assert_eq "output: cache lists entry 1" "$(cache_has "$out1" "Alpha Section")" "true"
assert_eq "output: cache lists entry 2" "$(cache_has "$out1" "Beta Section")" "true"
assert_eq "output: cache lists entry 3" "$(cache_has "$out1" "Gamma Subsection")" "true"
assert_eq "output: entry count 3"      "$(entry_count "$out1")" "3"
assert_eq "output: entry levels 1,1,2" "$(entry_levels "$out1")" "1,1,2"
assert_eq "output: no PAGEREF"         "$(pageref_count "$out1")" "0"
assert_eq "output: no tab page-number reference" "$(tab_count "$out1")" "0"
assert_eq "output: no placeholder"     "$(placeholder_count "$out1")" "0"
assert_eq "output: no dangling style"  "$(dangling "$out1")" ""
assert_eq "output: is a complex field (begin)" "$(fldchar_begin_count "$out1")" "1"
assert_eq "output: is a complex field (end)"   "$(fldchar_end_count "$out1")" "1"
if $TMO officecli validate "$out1" >/dev/null 2>&1; then
  report_ok "output validates"
else
  report_fail "output validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 2. The TOC is a live field: page numbers can be turned back on by refresh
#    (a scratch copy, never the delivered output)
# ---------------------------------------------------------------------------
pc="$WORK/positive-control.docx"
cp -f "$out1" "$pc"
$TMO officecli set "$pc" /toc --prop pageNumbers=true >/dev/null 2>&1
$TMO officecli refresh "$pc" >/dev/null 2>&1 || true
assert_gt0 "live field: pageNumbers=true refresh writes PAGEREF" "$(pageref_count "$pc")"
assert_eq "live field: instruction drops \\z when page numbers on" \
  "$(jq -rn --arg s "$(toc_instr "$pc")" '$s | (contains("\\z") | not)')" "true"

# ---------------------------------------------------------------------------
# 3. A source whose TOC defines the standard set: entries from its headings
# ---------------------------------------------------------------------------
out2="$WORK/out-std.docx"
json="$("$TOOL" "$FIX_STD" --out "$out2" --json || true)"
assert_eq "standard set: source unchanged" "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "standard set: one TOC field"    "$(jq -r '.evidence.toc_field_count' <<<"$json")" "1"
assert_eq "standard set: entry count 3"    "$(jq -r '.evidence.entry_count' <<<"$json")" "3"
assert_eq "standard set: no style added"   "$(jq -c '.evidence.styles_added' <<<"$json")" "[]"
assert_eq "standard set: cache lists Heading 1" "$(cache_has "$out2" "一级标题 Heading 1")" "true"
assert_eq "standard set: cache lists Heading 2" "$(cache_has "$out2" "二级标题 Heading 2")" "true"
assert_eq "standard set: cache lists Heading 3" "$(cache_has "$out2" "三级标题 Heading 3")" "true"
assert_eq "standard set: no PAGEREF"       "$(pageref_count "$out2")" "0"
assert_eq "standard set: no placeholder"   "$(placeholder_count "$out2")" "0"
assert_eq "standard set: no dangling style" "$(dangling "$out2")" ""

# ---------------------------------------------------------------------------
# 4. --levels narrows the range: only headings in range are cached
# ---------------------------------------------------------------------------
out_lv="$WORK/out-levels.docx"
json="$("$TOOL" "$FIX_TOC" --out "$out_lv" --levels 2-3 --json || true)"
assert_eq "levels 2-3: entry count 1"   "$(jq -r '.evidence.entry_count' <<<"$json")" "1"
assert_eq "levels 2-3: cache lists Gamma" "$(cache_has "$out_lv" "Gamma Subsection")" "true"
assert_eq "levels 2-3: cache omits Alpha" "$(cache_has "$out_lv" "Alpha Section")" "false"
assert_eq "levels 2-3: instruction levels" "$(jq -rn --arg s "$(toc_instr "$out_lv")" '$s | contains("\\o \"2-3\"")')" "true"
assert_eq "levels 2-3: no PAGEREF"      "$(pageref_count "$out_lv")" "0"

# ---------------------------------------------------------------------------
# 5. A source with no TOC gets one, after its Title; --title defines TOCHeading
# ---------------------------------------------------------------------------
fresh="$WORK/fresh-src.docx"; new_doc "$fresh"
$TMO officecli add "$fresh" /body --type paragraph --prop style=Title    --prop text="Fresh Document" >/dev/null 2>&1
$TMO officecli add "$fresh" /body --type paragraph --prop style=Heading1 --prop text="First Section"  >/dev/null 2>&1
$TMO officecli add "$fresh" /body --type paragraph --prop text="Body text." >/dev/null 2>&1
$TMO officecli add "$fresh" /body --type paragraph --prop style=Heading2 --prop text="Second Section" >/dev/null 2>&1
out_fresh="$WORK/fresh-out.docx"
json="$("$TOOL" "$fresh" --out "$out_fresh" --title "Contents" --json || true)"
assert_eq "fresh: TOC created"        "$(jq -r '.evidence.toc_created' <<<"$json")" "true"
assert_eq "fresh: TOC not reused"     "$(jq -r '.evidence.toc_reused' <<<"$json")" "false"
assert_eq "fresh: title recorded"     "$(jq -r '.evidence.title' <<<"$json")" "Contents"
assert_eq "fresh: entry count 2"      "$(jq -r '.evidence.entry_count' <<<"$json")" "2"
assert_eq "fresh: standard TOC styles added" "$(jq -c '.evidence.styles_added' <<<"$json")" '["TOC1","TOC2","TOC3","TOCHeading"]'
assert_eq "fresh: cache lists First"  "$(cache_has "$out_fresh" "First Section")" "true"
assert_eq "fresh: cache lists Second" "$(cache_has "$out_fresh" "Second Section")" "true"
assert_eq "fresh: no placeholder"     "$(placeholder_count "$out_fresh")" "0"
assert_eq "fresh: no PAGEREF"         "$(pageref_count "$out_fresh")" "0"
assert_eq "fresh: TOCHeading defined" "$(style_defined "$out_fresh" TOCHeading && echo true || echo false)" "true"
assert_eq "fresh: no dangling style"  "$(dangling "$out_fresh")" ""
assert_eq "fresh: TOC follows the Title" \
  "$(jq -r '.evidence.toc_path' <<<"$json")" "/toc[1]"
if $TMO officecli validate "$out_fresh" >/dev/null 2>&1; then
  report_ok "fresh output validates"
else
  report_fail "fresh output validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 6. Reproducibility: same source + same instructions -> same TOC layout
# ---------------------------------------------------------------------------
repro1="$WORK/repro1.docx"; repro2="$WORK/repro2.docx"
"$TOOL" "$FIX_TOC" --out "$repro1" --json >/dev/null
"$TOOL" "$FIX_TOC" --out "$repro2" --json >/dev/null
assert_eq "reproducible: identical TOC layout" "$(layout_sig "$repro1")" "$(layout_sig "$repro2")"

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$FIX_TOC" >/dev/null 2>&1;                                                   assert_eq "bad usage: missing --out exits 2"      "$?" "2"
"$TOOL" "$FIX_TOC" --out "$FIX_TOC" >/dev/null 2>&1;                                  assert_eq "bad usage: --out == source exits 2"    "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" >/dev/null 2>&1;                       assert_eq "bad usage: missing source exits 2"     "$?" "2"
"$TOOL" "$FIX_TOC" --out "$WORK/x.docx" --levels 1-4 >/dev/null 2>&1;                 assert_eq "bad usage: levels > 3 exits 2"         "$?" "2"
"$TOOL" "$FIX_TOC" --out "$WORK/x.docx" --levels 3-1 >/dev/null 2>&1;                 assert_eq "bad usage: empty levels range exits 2" "$?" "2"
"$TOOL" "$FIX_TOC" --out "$WORK/x.docx" --levels nope >/dev/null 2>&1;                assert_eq "bad usage: malformed levels exits 2"   "$?" "2"

# ---------------------------------------------------------------------------
# 8. LibreOffice opens without repair (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1 && [[ -x "$HARNESS" ]]; then
  lo_dir="$WORK/compat"
  rc=0
  timeout 300 "$HARNESS" "$out1" --apps libreoffice --out "$lo_dir" --no-visual >/dev/null 2>&1 || rc=$?
  assert_eq "libreoffice: harness ran" "$rc" "0"
  lo_result="$lo_dir/result.json"
  if [[ -s "$lo_result" ]]; then
    report_ok "libreoffice: result.json written"
    assert_eq "libreoffice: opens without repair" \
      "$(jq -r '.records[]|select(.app=="libreoffice")|.opens_without_repair' "$lo_result")" "true"
    assert_eq "libreoffice: no placeholder field" \
      "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.placeholder_count' "$lo_result")" "0"
  else
    report_fail "libreoffice: result.json written" "no non-empty result.json at $lo_result"
  fi
else
  report_info "libreoffice: opens without repair — SKIPPED (soffice/harness unavailable)"
fi

# ---------------------------------------------------------------------------
# 9. Source protection: both committed fixtures are byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: TOC fixture unchanged" "$(sha256sum "$FIX_TOC" | awk '{print $1}')" "$toc_before"
assert_eq "source protection: standard fixture unchanged" "$(sha256sum "$FIX_STD" | awk '{print $1}')" "$std_before"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
fi

echo
echo "TOC: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  exit 1
fi
