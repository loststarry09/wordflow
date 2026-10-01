#!/usr/bin/env bash
#
# Acceptance tests for figure and table captions (#22, spec §D8).
#
# They exercise the operation scripts/wf-caption.sh end-to-end and the
# committed fixtures it targets:
#
#   * tests/fixtures/captions/caption-seq.docx — a defined Caption style and one
#     cached SEQ Figure field;
#   * tests/fixtures/styles/standard-style-set.docx — the frozen standard set
#     (its Caption style already defined).
#
# The tests assert what OfficeCLI reports back — the caption paragraph's applied
# style, each SEQ field's cached TEXT (never its evaluated flag), the absence of
# placeholders, no dangling style, source protection, and reproducibility — not
# the exact commands the tool runs. LibreOffice opens-without-repair is checked
# through scripts/wf-compat-harness.sh when soffice is available.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH. Usage:
# tests/caption.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_CAPTION="$ROOT/tests/fixtures/captions/caption-seq.docx"
FIX_STD="$ROOT/tests/fixtures/styles/standard-style-set.docx"
TOOL="$ROOT/scripts/wf-caption.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -f "$FIX_CAPTION" ]] || { echo "missing fixture: $FIX_CAPTION" >&2; exit 2; }
[[ -f "$FIX_STD" ]] || { echo "missing fixture: $FIX_STD" >&2; exit 2; }

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/caption.XXXXXX")"

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

# --- OfficeCLI reads ---------------------------------------------------------

# captured fields: one compact JSON array of {path,instruction,cached_text}
fields_json() { # <file>
  $TMO officecli query "$1" field --json 2>/dev/null | jq -c '[.data.results[]? | {
    path, instruction: (.format.instruction // ""), cached_text: (.text // "") }]'
}

# seq_fields <file> <identifier> -> sorted cached texts, comma-joined
seq_texts() { # <file> <Figure|Table>
  fields_json "$1" | jq -r --arg i "SEQ $2" \
    '[.[] | select(.instruction == $i) | .cached_text] | sort | join(",")'
}

seq_count() { # <file> <Figure|Table>
  fields_json "$1" | jq -r --arg i "SEQ $2" '[.[] | select(.instruction == $i)] | length'
}

# placeholder_count <file> — fields whose cached text is a placeholder / unresolved
placeholder_count() { # <file>
  fields_json "$1" | jq -r '
    [.[] | select((.cached_text | test("\u00ab|\u00bb|OCLI_NOTEVAL|not evaluated"; "i"))
                  or (.cached_text == "Update field to see table of contents"))] | length'
}

defined_ids() { # <file> -> sorted comma-joined styleIds
  $TMO officecli get "$1" /styles --json 2>/dev/null \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}

caption_style_count() { # <file>
  $TMO officecli get "$1" /styles --json 2>/dev/null \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId]
             | map(select(.=="Caption")) | length'
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

# para_style_of <file> <substring> -> styleId of the paragraph whose text contains it
para_style_of() { # <file> <text>
  $TMO officecli query "$1" paragraph --json 2>/dev/null \
    | jq -r --arg t "$2" '.data.results[] | select(.text | contains($t)) | (.format.styleId // "")' | head -n1
}

# layout_sig <file> — stable caption signature: SEQ fields + Caption paragraph styles
layout_sig() { # <file>
  local seq styles
  seq="$(fields_json "$1" | jq -r '[.[] | select(.instruction | startswith("SEQ ")) | (.instruction + "=" + .cached_text)] | sort | join(";")')"
  styles="$($TMO officecli query "$1" paragraph --json 2>/dev/null \
    | jq -r '[.data.results[]? | select(.format.styleId == "Caption") | .text] | sort | join("|")')"
  printf '%s#%s\n' "$seq" "$styles"
}

new_doc() { # <path>
  local f="$1"
  $TMO officecli close "$f" >/dev/null 2>&1 || true
  rm -f "$f"; mkdir -p "$(dirname "$f")"
  $TMO officecli create "$f" --locale en-US >/dev/null
}

cleanup() {
  for f in "$WORK"/*.docx; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

caption_before="$(sha256sum "$FIX_CAPTION" | awk '{print $1}')"
std_before="$(sha256sum "$FIX_STD" | awk '{print $1}')"

echo "Captions (#22) — $FIX_CAPTION"
echo

# ---------------------------------------------------------------------------
# 0. Preconditions: the fixture defines Caption and caches one SEQ Figure
# ---------------------------------------------------------------------------
assert_eq "fixture: Caption style defined" "$(caption_style_count "$FIX_CAPTION")" "1"
assert_eq "fixture: one SEQ Figure field"  "$(seq_count "$FIX_CAPTION" Figure)" "1"
assert_eq "fixture: SEQ Figure cached 1"   "$(seq_texts "$FIX_CAPTION" Figure)" "1"
assert_eq "fixture: no placeholder field"  "$(placeholder_count "$FIX_CAPTION")" "0"
assert_eq "fixture: no dangling style"     "$(dangling "$FIX_CAPTION")" ""
if $TMO officecli validate "$FIX_CAPTION" >/dev/null 2>&1; then
  report_ok "fixture validates"
else
  report_fail "fixture validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 1. A figure caption: correct cached number, Caption style, no placeholder
# ---------------------------------------------------------------------------
out_fig="$WORK/figure.docx"
json="$("$TOOL" "$FIX_CAPTION" --out "$out_fig" --kind figure --text "A second figure." --json || true)"
if jq -e . >/dev/null 2>&1 <<<"$json"; then report_ok "figure: tool emitted valid JSON"; else report_fail "figure: tool emitted valid JSON" "$json"; fi
assert_eq "figure: resolved"          "$(jq -r '.evidence.resolved' <<<"$json")" "true"
assert_eq "figure: placeholder false" "$(jq -r '.evidence.placeholder' <<<"$json")" "false"
assert_eq "figure: SEQ field ships"   "$(jq -r '.evidence.seq_field' <<<"$json")" "true"
assert_eq "figure: cached number 2"   "$(jq -r '.evidence.cached_number' <<<"$json")" "2"
assert_eq "figure: caption style"     "$(jq -r '.evidence.style' <<<"$json")" "Caption"
assert_eq "figure: source unchanged"  "$(jq -r '.source_unchanged' <<<"$json")" "true"
assert_eq "figure: no change_report risk downgrade reported as warnings" \
  "$(jq -r '[.change_report[]|select(test("unverifiable-field"))]|length' <<<"$json")" "0"

assert_eq "figure output: two SEQ Figure fields" "$(seq_count "$out_fig" Figure)" "2"
assert_eq "figure output: cached numbers 1 and 2" "$(seq_texts "$out_fig" Figure)" "1,2"
assert_eq "figure output: no placeholder field"  "$(placeholder_count "$out_fig")" "0"
assert_eq "figure output: Caption defined once"  "$(caption_style_count "$out_fig")" "1"
assert_eq "figure output: no dangling style"     "$(dangling "$out_fig")" ""
assert_eq "figure output: caption uses Caption style" \
  "$(para_style_of "$out_fig" "A second figure.")" "Caption"
if $TMO officecli validate "$out_fig" >/dev/null 2>&1; then
  report_ok "figure output validates"
else
  report_fail "figure output validates" "officecli validate failed"
fi

# ---------------------------------------------------------------------------
# 2. A table caption: its own SEQ Table sequence
# ---------------------------------------------------------------------------
out_tab="$WORK/table.docx"
json="$("$TOOL" "$FIX_CAPTION" --out "$out_tab" --kind table --text "A table caption." --json || true)"
assert_eq "table: cached number 1" "$(jq -r '.evidence.cached_number' <<<"$json")" "1"
assert_eq "table: instruction is SEQ Table" \
  "$(jq -r '.evidence.field_instruction' <<<"$json")" "SEQ Table"
assert_eq "table output: one SEQ Table field" "$(seq_count "$out_tab" Table)" "1"
assert_eq "table output: SEQ Table cached 1"  "$(seq_texts "$out_tab" Table)" "1"
assert_eq "table output: figure sequence untouched" "$(seq_texts "$out_tab" Figure)" "1"
assert_eq "table output: no placeholder field" "$(placeholder_count "$out_tab")" "0"
assert_eq "table: caption style" "$(para_style_of "$out_tab" "A table caption.")" "Caption"

# ---------------------------------------------------------------------------
# 3. A source without the Caption style gains exactly the standard definition
# ---------------------------------------------------------------------------
fresh="$WORK/fresh.docx"; new_doc "$fresh"
$TMO officecli add "$fresh" /body --type paragraph --prop text="Body text with no Caption style." >/dev/null
assert_eq "fresh source: Caption absent" "$(caption_style_count "$fresh")" "0"
out_fresh="$WORK/fresh-out.docx"
json="$("$TOOL" "$fresh" --out "$out_fresh" --kind table --text "Fresh table caption." --json || true)"
assert_eq "fresh: style not previously defined" "$(jq -r '.evidence.style_defined' <<<"$json")" "false"
assert_eq "fresh: standard Caption added"       "$(jq -r '.evidence.style_added' <<<"$json")" "true"
assert_eq "fresh: cached number 1"              "$(jq -r '.evidence.cached_number' <<<"$json")" "1"
assert_eq "fresh output: Caption defined once"  "$(caption_style_count "$out_fresh")" "1"
assert_eq "fresh output: no dangling style"     "$(dangling "$out_fresh")" ""
assert_eq "fresh output: caption uses Caption"  "$(para_style_of "$out_fresh" "Fresh table caption.")" "Caption"

# ---------------------------------------------------------------------------
# 4. A source that already defines Caption keeps it (no duplicate, no add)
# ---------------------------------------------------------------------------
out_std="$WORK/std-out.docx"
json="$("$TOOL" "$FIX_STD" --out "$out_std" --kind figure --text "Standard set figure." --json || true)"
assert_eq "standard set: Caption already defined" "$(jq -r '.evidence.style_defined' <<<"$json")" "true"
assert_eq "standard set: no style added"          "$(jq -r '.evidence.style_added' <<<"$json")" "false"
assert_eq "standard set: cached number 1"         "$(jq -r '.evidence.cached_number' <<<"$json")" "1"
assert_eq "standard set output: Caption defined once" "$(caption_style_count "$out_std")" "1"
assert_eq "standard set output: no dangling style"    "$(dangling "$out_std")" ""
assert_eq "standard set output: no placeholder field" "$(placeholder_count "$out_std")" "0"

# ---------------------------------------------------------------------------
# 5. --para inserts the caption immediately after the named paragraph, and the
#    recalc renumbers in body document order
# ---------------------------------------------------------------------------
out_para="$WORK/para.docx"
json="$("$TOOL" "$FIX_CAPTION" --out "$out_para" --kind figure --text "Inserted caption." \
        --para '/body/p[1]' --json || true)"
assert_eq "para: cached number 1 (inserted first)" "$(jq -r '.evidence.cached_number' <<<"$json")" "1"
mapfile -t paras < <($TMO officecli query "$out_para" paragraph --json 2>/dev/null | jq -r '.data.results[] | select(.path | test("^/body/")) | "\(.path)\t\(.text)"')
first_para="${paras[0]%%$'\t'*}"
second_para="${paras[1]%%$'\t'*}"
assert_eq "para: inserted caption follows p[1]" "$second_para" "$(jq -r '.evidence.paragraph' <<<"$json")"
assert_eq "para: p[1] is still first" "$first_para" "/body/p[@paraId=00100000]"
assert_eq "para output: existing Figure renumbered 2" "$(seq_texts "$out_para" Figure)" "1,2"

# ---------------------------------------------------------------------------
# 6. Reproducibility: same source + same instructions -> same caption layout
# ---------------------------------------------------------------------------
repro1="$WORK/repro1.docx"; repro2="$WORK/repro2.docx"
"$TOOL" "$FIX_CAPTION" --out "$repro1" --kind figure --text "Reproducible." --json >/dev/null
"$TOOL" "$FIX_CAPTION" --out "$repro2" --kind figure --text "Reproducible." --json >/dev/null
assert_eq "reproducible: identical caption layout" "$(layout_sig "$repro1")" "$(layout_sig "$repro2")"

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$FIX_CAPTION" >/dev/null 2>&1;                                                       assert_eq "bad usage: missing --out exits 2"    "$?" "2"
"$TOOL" "$FIX_CAPTION" --out "$WORK/x.docx" --kind figure >/dev/null 2>&1;                     assert_eq "bad usage: missing --text exits 2"   "$?" "2"
"$TOOL" "$FIX_CAPTION" --out "$WORK/x.docx" --text "hi" >/dev/null 2>&1;                       assert_eq "bad usage: missing --kind exits 2"   "$?" "2"
"$TOOL" "$FIX_CAPTION" --out "$WORK/x.docx" --kind bogus --text "hi" >/dev/null 2>&1;          assert_eq "bad usage: bad --kind exits 2"       "$?" "2"
"$TOOL" "$FIX_CAPTION" --out "$FIX_CAPTION" --kind figure --text "hi" >/dev/null 2>&1;         assert_eq "bad usage: --out == source exits 2"  "$?" "2"
"$TOOL" "$FIX_CAPTION" --out "$WORK/x.docx" --kind figure --text "hi" --para '/body/p[99]' >/dev/null 2>&1; assert_eq "bad usage: bad --para exits 2" "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" --kind figure --text "hi" >/dev/null 2>&1;      assert_eq "bad usage: missing source exits 2"   "$?" "2"

# ---------------------------------------------------------------------------
# 8. LibreOffice opens without repair (skipped if soffice is unavailable)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1 && [[ -x "$HARNESS" ]]; then
  lo_dir="$WORK/compat"
  rc=0
  timeout 300 "$HARNESS" "$out_fig" --apps libreoffice --out "$lo_dir" --no-visual >/dev/null 2>&1 || rc=$?
  assert_eq "libreoffice: harness ran" "$rc" "0"
  lo_result="$lo_dir/result.json"
  if [[ -s "$lo_result" ]]; then
    report_ok "libreoffice: result.json written"
    assert_eq "libreoffice: opens without repair" \
      "$(jq -r '.records[]|select(.app=="libreoffice")|.opens_without_repair' "$lo_result")" "true"
    assert_eq "libreoffice: status ok" \
      "$(jq -r '.records[]|select(.app=="libreoffice")|.status' "$lo_result")" "ok"
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
assert_eq "source protection: caption fixture unchanged" "$(sha256sum "$FIX_CAPTION" | awk '{print $1}')" "$caption_before"
assert_eq "source protection: standard fixture unchanged" "$(sha256sum "$FIX_STD" | awk '{print $1}')" "$std_before"

echo
echo "Caption: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
