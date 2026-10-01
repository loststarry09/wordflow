#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow footnote capability (#25, spec §D8/§D9).
#
# Footnotes are fully supported: the footnote text and reference styles are
# defined and applied, and the document opens without repair. The tests exercise:
#
#   1. the committed fixture tests/fixtures/notes/footnote-basic.docx — it carries
#      one footnote but references FootnoteText and FootnoteReference without
#      defining them (a dangling style the capability must repair);
#   2. the operation scripts/wf-footnote.sh on that fixture, on an unstyled
#      document (no style set), and on the standard style set (the source's own
#      footnote styles are preserved) — the output contains the footnote with the
#      given text, both footnote styles are defined and referenced (no dangling
#      style), the source is untouched, and the run is reproducible;
#   3. open-without-repair in LibreOffice through the compatibility harness when
#      soffice is available; otherwise the renderer is reported unverified.
#
# It asserts what OfficeCLI reports back, not the exact commands run.
#
# Requirements: officecli >= 1.0.152, jq, cp, sha256sum on PATH.
# Usage: tests/footnote.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_BASIC="$ROOT/tests/fixtures/notes/footnote-basic.docx"
FIX_UNSTYLED="$ROOT/tests/fixtures/styles/unstyled.docx"
FIX_STD="$ROOT/tests/fixtures/styles/standard-style-set.docx"
TOOL="$ROOT/scripts/wf-footnote.sh"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$TOOL" ]] || { echo "missing or non-executable operation: $TOOL" >&2; exit 2; }
[[ -x "$HARNESS" ]] || { echo "missing or non-executable harness: $HARNESS" >&2; exit 2; }
for f in "$FIX_BASIC" "$FIX_UNSTYLED" "$FIX_STD"; do
  [[ -f "$f" ]] || { echo "missing fixture: $f" >&2; exit 2; }
done

mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/footnote.XXXXXX")"

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
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "'$3' not found in '$2'"; fi
}

TMO="timeout 60"

# --- OfficeCLI-observable helpers -------------------------------------------
defined_ids() { # defined_ids <file> -> sorted, comma-joined styleIds
  $TMO officecli get "$1" /styles --json 2>/dev/null \
    | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | join(",")'
}

referenced_ids() { # referenced_ids <file> — pStyle/rStyle across every part
  local f="$1"
  { $TMO officecli raw "$f" /document 2>/dev/null
    $TMO officecli raw "$f" /footnotes 2>/dev/null
    $TMO officecli raw "$f" /header[1] 2>/dev/null
    $TMO officecli raw "$f" /footer[1] 2>/dev/null
  } | grep -oE 'w:(pStyle|rStyle) w:val="[^"]+"' \
    | sed -E 's/.*w:val="([^"]+)".*/\1/' | sort -u | paste -sd, -
}

dangling_styles() { # dangling_styles <file> — referenced but not defined
  comm -23 <(referenced_ids "$1" | tr ',' '\n' | sed '/^$/d' | sort -u) \
           <(defined_ids "$1" | tr ',' '\n' | sed '/^$/d' | sort -u) | paste -sd, -
}

fn_count() { # fn_count <file>
  $TMO officecli query "$1" footnote --json 2>/dev/null \
    | jq -r '(.data.results // []) | length'
}

fn_texts() { # fn_texts <file>
  $TMO officecli query "$1" footnote --json 2>/dev/null \
    | jq -r '[.data.results[]?.text // ""] | join(" | ")'
}

fn_sig() { # fn_sig <file> — id=text per footnote, for reproducibility
  $TMO officecli query "$1" footnote --json 2>/dev/null \
    | jq -r '[.data.results[]? | (.format.id | tostring) + "=" + (.text // "")] | sort | join(";")'
}

has_footnote_ref() { # has_footnote_ref <file> — a w:footnoteReference run in the body
  $TMO officecli raw "$1" /document 2>/dev/null | grep -q 'w:footnoteReference'
}

last_body_para() { # last_body_para <file>
  $TMO officecli get "$1" /body --json 2>/dev/null \
    | jq -r '[.data.results[0].children[]? | select(.type=="paragraph")] | last | .path // ""'
}

cleanup() {
  local f
  for f in "$WORK"/*.docx "$FIX_BASIC" "$FIX_UNSTYLED" "$FIX_STD"; do
    if [[ -e "$f" ]]; then $TMO officecli close "$f" >/dev/null 2>&1 || true; fi
  done
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

basic_before="$(sha256sum "$FIX_BASIC" | awk '{print $1}')"
unstyled_before="$(sha256sum "$FIX_UNSTYLED" | awk '{print $1}')"
std_before="$(sha256sum "$FIX_STD" | awk '{print $1}')"

echo "Footnotes (#25) — $FIX_BASIC"
echo

# ---------------------------------------------------------------------------
# 1. The committed fixture: one footnote whose styles are dangling
# ---------------------------------------------------------------------------
assert_eq "fixture: one footnote"                  "$(fn_count "$FIX_BASIC")" "1"
assert_contains "fixture: footnote text"           "$(fn_texts "$FIX_BASIC")" "This is the footnote text."
assert_eq "fixture: only Normal is defined"        "$(defined_ids "$FIX_BASIC")" "Normal"
assert_contains "fixture: FootnoteText referenced"     "$(referenced_ids "$FIX_BASIC")" "FootnoteText"
assert_contains "fixture: FootnoteReference referenced" "$(referenced_ids "$FIX_BASIC")" "FootnoteReference"
assert_eq "fixture: footnote styles dangling before the operation" \
  "$(dangling_styles "$FIX_BASIC")" "FootnoteReference,FootnoteText"

# ---------------------------------------------------------------------------
# 2. The operation on the fixture: styles defined, footnote attached
# ---------------------------------------------------------------------------
basic_src="$WORK/basic-src.docx"; cp "$FIX_BASIC" "$basic_src"
base_out="$WORK/baseline-out.docx"
base_rep="$WORK/baseline-report.json"
base_json="$("$TOOL" "$basic_src" --out "$base_out" \
  --text "A WordFlow footnote." --report "$base_rep" --json)" \
  || report_fail "operation: run" "exited non-zero"

assert_eq "operation: source_unchanged"        "$(jq -r '.source_unchanged' <<<"$base_json")" "true"
assert_eq "operation: two footnotes"           "$(fn_count "$base_out")" "2"
assert_contains "operation: original footnote kept" "$(fn_texts "$base_out")" "This is the footnote text."
assert_contains "operation: new footnote text"      "$(fn_texts "$base_out")" "A WordFlow footnote."
assert_eq "operation: footnote text evidence"  "$(jq -r '.evidence.footnote_text' <<<"$base_json")" "A WordFlow footnote."
assert_eq "operation: footnote reference in the body" "$(has_footnote_ref "$base_out" && echo yes || echo no)" "yes"

assert_contains "operation: FootnoteText defined"      "$(defined_ids "$base_out")" "FootnoteText"
assert_contains "operation: FootnoteReference defined" "$(defined_ids "$base_out")" "FootnoteReference"
assert_contains "operation: FootnoteText referenced"      "$(referenced_ids "$base_out")" "FootnoteText"
assert_contains "operation: FootnoteReference referenced" "$(referenced_ids "$base_out")" "FootnoteReference"
assert_eq "operation: no dangling style" "$(dangling_styles "$base_out")" ""
assert_eq "operation: evidence dangling empty" "$(jq -r '.evidence.dangling_styles | length' <<<"$base_json")" "0"

assert_eq "operation: styles added"       "$(jq -r '.evidence.styles_added | sort | join(",")' <<<"$base_json")" "FootnoteReference,FootnoteText"
assert_eq "operation: footnote text style" "$(jq -r '.evidence.footnote_paragraph_style' <<<"$base_json")" "FootnoteText"
assert_eq "operation: style applied"       "$(jq -r '.evidence.style_applied' <<<"$base_json")" "true"
assert_eq "operation: validated"           "$(jq -r '.evidence.validated' <<<"$base_json")" "true"

if $TMO officecli validate "$base_out" >/dev/null 2>&1; then
  report_ok "operation: output validates"
else
  report_fail "operation: output validates" "officecli validate failed"
fi

if "$CHANGE_REPORT" validate --report "$base_rep" >/dev/null 2>&1; then
  report_ok "operation: report file is a valid change report"
else
  report_fail "operation: report file is a valid change report" "validate failed"
fi
assert_eq "operation: no warnings (fully supported)" "$(jq -r '.warnings | length' "$base_rep" 2>/dev/null)" "0"
assert_eq "operation: changed recorded"              "$(jq -r '.changed | length > 0' "$base_rep" 2>/dev/null)" "true"

# ---------------------------------------------------------------------------
# 3. An unstyled source: default target is the last body paragraph
# ---------------------------------------------------------------------------
un_src="$WORK/unstyled-src.docx"; cp "$FIX_UNSTYLED" "$un_src"
un_out="$WORK/unstyled-out.docx"
un_json="$("$TOOL" "$un_src" --out "$un_out" --text "A note on the last paragraph." --json)" \
  || report_fail "unstyled: run" "exited non-zero"

assert_eq "unstyled: one footnote"        "$(fn_count "$un_out")" "1"
assert_contains "unstyled: footnote text" "$(fn_texts "$un_out")" "A note on the last paragraph."
assert_eq "unstyled: default paragraph"   "$(jq -r '.evidence.paragraph_defaulted' <<<"$un_json")" "true"
assert_eq "unstyled: target is last body paragraph" \
  "$(jq -r '.evidence.target_paragraph' <<<"$un_json")" "$(last_body_para "$un_out")"
assert_eq "unstyled: both styles added" \
  "$(jq -r '.evidence.styles_added | sort | join(",")' <<<"$un_json")" "FootnoteReference,FootnoteText"
assert_eq "unstyled: no dangling style"   "$(dangling_styles "$un_out")" ""
assert_eq "unstyled: source_unchanged"    "$(jq -r '.source_unchanged' <<<"$un_json")" "true"

# ---------------------------------------------------------------------------
# 4. A standard-style-set source: its own footnote styles are preserved
# ---------------------------------------------------------------------------
std_src="$WORK/std-src.docx"; cp "$FIX_STD" "$std_src"
std_out="$WORK/std-out.docx"
std_json="$("$TOOL" "$std_src" --out "$std_out" --para /body/p[1] \
  --text "脚注新增 Footnote added." --json)" \
  || report_fail "standard set: run" "exited non-zero"

assert_eq "standard set: no style added"       "$(jq -r '.evidence.styles_added | length' <<<"$std_json")" "0"
assert_eq "standard set: footnote styles kept" \
  "$(jq -r '.evidence.styles_preserved | sort | join(",")' <<<"$std_json")" "FootnoteReference,FootnoteText"
assert_eq "standard set: style set unchanged"  "$(defined_ids "$std_out")" "$(defined_ids "$std_src")"
assert_eq "standard set: two footnotes"        "$(fn_count "$std_out")" "2"
assert_contains "standard set: existing footnote kept" "$(fn_texts "$std_out")" "脚注文本 Footnote text."
assert_contains "standard set: new footnote text"      "$(fn_texts "$std_out")" "脚注新增 Footnote added."
assert_eq "standard set: no dangling style"    "$(dangling_styles "$std_out")" ""
assert_eq "standard set: source_unchanged"     "$(jq -r '.source_unchanged' <<<"$std_json")" "true"

# ---------------------------------------------------------------------------
# 5. Reproducibility: same source + same instructions -> same structure
# ---------------------------------------------------------------------------
r1="$WORK/repro-1.docx"; r2="$WORK/repro-2.docx"
r1_src="$WORK/repro-src.docx"; cp "$FIX_BASIC" "$r1_src"
"$TOOL" "$r1_src" --out "$r1" --text "Reproducible note." --json >/dev/null
"$TOOL" "$r1_src" --out "$r2" --text "Reproducible note." --json >/dev/null
assert_eq "reproducible: identical footnotes"  "$(fn_sig "$r1")" "$(fn_sig "$r2")"
assert_eq "reproducible: identical style set"  "$(defined_ids "$r1")" "$(defined_ids "$r2")"
assert_eq "reproducible: identical references" "$(referenced_ids "$r1")" "$(referenced_ids "$r2")"

# ---------------------------------------------------------------------------
# 6. Open without repair in LibreOffice (skipped without soffice)
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null 2>&1; then
  compat_out="$WORK/compat"
  if $TMO "$HARNESS" "$base_out" --apps libreoffice --out "$compat_out" --no-visual >/dev/null 2>&1 \
     && [[ -f "$compat_out/result.json" ]]; then
    lo="$(jq -r '([.records[]? | select(.app == "libreoffice") | .opens_without_repair] | first) // "unavailable"' \
      "$compat_out/result.json" 2>/dev/null)"
    assert_eq "compat: LibreOffice opens without repair" "$lo" "true"
  else
    report_fail "compat: LibreOffice harness" "did not produce a result.json"
  fi
else
  report_info "compat: LibreOffice open verified — SKIPPED (soffice not on PATH; unverified)"
fi

# ---------------------------------------------------------------------------
# 7. Bad usage is rejected, not silently accepted
# ---------------------------------------------------------------------------
"$TOOL" "$un_src" >/dev/null 2>&1;                                   assert_eq "bad usage: missing --out/--text exits 2" "$?" "2"
"$TOOL" "$un_src" --out "$un_src" --text x >/dev/null 2>&1;          assert_eq "bad usage: --out == source exits 2"     "$?" "2"
"$TOOL" "$un_src" --out "$WORK/x.docx" >/dev/null 2>&1;              assert_eq "bad usage: missing --text exits 2"      "$?" "2"
"$TOOL" "$un_src" --out "$WORK/x.docx" --text "   " >/dev/null 2>&1; assert_eq "bad usage: blank --text exits 2"        "$?" "2"
"$TOOL" "$WORK/nope.docx" --out "$WORK/x.docx" --text x >/dev/null 2>&1; assert_eq "bad usage: missing source exits 2" "$?" "2"
"$TOOL" "$un_src" --out "$WORK/x.docx" --text x --para /body/p[99] >/dev/null 2>&1; assert_eq "bad usage: bad --para exits 2" "$?" "2"

# ---------------------------------------------------------------------------
# 8. Source protection: every fixture is byte-identical afterwards
# ---------------------------------------------------------------------------
assert_eq "source protection: footnote fixture unchanged"   "$(sha256sum "$FIX_BASIC" | awk '{print $1}')"    "$basic_before"
assert_eq "source protection: unstyled fixture unchanged"   "$(sha256sum "$FIX_UNSTYLED" | awk '{print $1}')" "$unstyled_before"
assert_eq "source protection: standard-set fixture unchanged" "$(sha256sum "$FIX_STD" | awk '{print $1}')"   "$std_before"

echo
echo "Footnote: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
