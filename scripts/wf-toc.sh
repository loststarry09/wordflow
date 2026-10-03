#!/usr/bin/env bash
#
# WordFlow table-of-contents primitive (#24).
#
# Builds a table of contents from a document's headings, through OfficeCLI,
# using the frozen v0.1 TOC decision (spec `docs/spec/v0.1.md` §D8/§D9):
#
#   * the TOC is a real, updatable complex field — never static text;
#   * its cached result lists the heading entries but carries **no page-number
#     references** (`PAGEREF`), because no application updates fields on open and
#     WordFlow has no layout engine, so any page number it produced would look
#     finished while being wrong;
#   * it never ships a placeholder (`Update field to see table of contents` / «»);
#   * the change report states that page numbers are omitted in v0.1 and that a
#     manual F9 / Update Table adds them.
#
# The construction is the #11 mechanism
# (`references/fields/table-of-contents.md`):
#
#   1. define the TOC entry styles (TOC 1..TOC 3; the standard set defines them —
#      add the standard definitions only when the source lacks them) so the
#      refreshed entries never reference a dangling style;
#   2. insert or configure the TOC field with `pageNumbers=false`, which makes
#      OfficeCLI emit the instruction `TOC \o "a-b" \h \z \u`;
#   3. run `officecli refresh` **last**, after all headings exist, so its cache
#      is filled with one TOC1/TOC2/… hyperlink paragraph per heading and no
#      `<w:tab>` / `PAGEREF` page-number reference.
#
# An existing TOC field is reused (set to the requested levels and
# `pageNumbers=false`) rather than duplicated; a document with no TOC gets one
# after its Title paragraph (or at the top of the body).
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and every DOCX read/write is performed on --out through OfficeCLI.
# The byte copy is a file duplication, not a DOCX read or write.
#
# Usage:
#   scripts/wf-toc.sh <source.docx> --out <output.docx>
#     [--levels <a-b>] [--title <text>] [--report <file>] [--json]
#
# Exit codes: 0 = TOC placed and verified; 1 = OfficeCLI could not read/write a
#              document or the cache failed verification; 2 = bad usage /
#              missing dependency.
#
set -euo pipefail

readonly TOOL="wf-toc.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"

# Frozen TOC entry styles (spec §D7: TOC 1..TOC 3). The set is not expanded.
readonly TOC_STYLE_IDS=(TOC1 TOC2 TOC3)
readonly MAX_LEVEL=3

usage() {
  cat <<'EOF'
Usage: wf-toc.sh <source.docx> --out <output.docx> [options]

Build a table of contents from the document's headings as a real, updatable
field whose cached result lists the entries with NO page numbers (spec D9).
The source is never modified; the result is written to --out. An existing TOC
is reused; a document without one gets the TOC after its Title paragraph.

Options:
  --out <file>     New output document (required; must differ from the source).
  --levels <a-b>   Heading levels to include, e.g. 1-3. Both in 1..3 and a<=b
                   (default 1-3). The TOC 1..TOC 3 entry styles are the frozen
                   set (spec D7); levels beyond 3 are out of scope.
  --title <text>   Optional title above the TOC (defines the TOCHeading style).
  --report <file>  Write the change report (#28) to this path. Optional; without
                   it a temporary report is used and embedded in the JSON output.
  --json           Emit the JSON report instead of text.
  -h, --help       Show this help.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die() { echo "$TOOL: $*" >&2; exit 1; }

SRC=""; OUT=""; LEVELS="1-3"; TITLE=""; REPORT_OUT=""; JSON=0

while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || die_usage "--out requires a file argument"; OUT="$2"; shift 2 ;;
    --levels)  (($# >= 2)) || die_usage "--levels requires a value"; LEVELS="$2"; shift 2 ;;
    --title)   (($# >= 2)) || die_usage "--title requires a value"; TITLE="$2"; shift 2 ;;
    --report)  (($# >= 2)) || die_usage "--report requires a file argument"; REPORT_OUT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }

# --levels: a-b, both in 1..MAX_LEVEL, a<=b (the frozen TOC 1..3 styles).
if [[ ! "$LEVELS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  die_usage "invalid --levels: $LEVELS (expected a-b, e.g. 1-3)"
fi
LO="${BASH_REMATCH[1]}"; HI="${BASH_REMATCH[2]}"
(( LO >= 1 && HI <= MAX_LEVEL )) || die_usage "--levels $LEVELS out of range (1..$MAX_LEVEL)"
(( LO <= HI )) || die_usage "--levels $LEVELS has an empty range (a must be <= b)"

for bin in officecli jq sha256sum cp; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
[[ -x "$RISK" ]] || { echo "risk-policy tool not executable: $RISK" >&2; exit 2; }

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"
# shellcheck source=scripts/lib/source-protection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-protection.sh"
wf_guard_destination --out "$OUT" "$SRC"
wf_guard_destination --report "$REPORT_OUT" "$SRC" "$OUT"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

create_report() { "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$1" >/dev/null; }
report_add() { "$CHANGE_REPORT" add --report "$1" --area "$2" --entry "$3" >/dev/null; }

# --- copy the bytes, then build through OfficeCLI ---------------------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

TMP_REPORT=""
cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  [[ -n "$TMP_REPORT" ]] && rm -f "$TMP_REPORT"
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

REPORT_FILE="$REPORT_OUT"
if [[ -z "$REPORT_FILE" ]]; then
  TMP_REPORT="$(mktemp)"
  REPORT_FILE="$TMP_REPORT"
fi
create_report "$REPORT_FILE"

# --- 1. entry styles must be defined before refresh references them (D7/D14)
styles_json="$($TMO officecli get "$out_abs" /styles --json)"
jq -e '.success == true' >/dev/null 2>&1 <<<"$styles_json" || die "OfficeCLI could not read styles from $SRC"

declare -a styles_added=()
style_defined() { # <styleId>
  jq -e --arg id "$1" \
    '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | index($id) != null' \
    >/dev/null 2>&1 <<<"$styles_json"
}
add_toc_style() { # <styleId> <name>
  $TMO officecli add "$out_abs" /styles --type style \
    --prop styleId="$1" --prop name="$2" --prop type=paragraph \
    --prop basedOn=Normal --prop qFormat=true --prop align=left >/dev/null
  styles_added+=("$1")
}

for id in "${TOC_STYLE_IDS[@]}"; do
  if ! style_defined "$id"; then
    add_toc_style "$id" "TOC ${id#TOC}"
  fi
done

# A titled TOC references the built-in TOCHeading style; define it explicitly
# when a title is requested so the entry is never a dangling reference.
if [[ -n "$TITLE" ]] && ! style_defined "TOCHeading"; then
  $TMO officecli add "$out_abs" /styles --type style \
    --prop styleId=TOCHeading --prop name="TOC Heading" --prop type=paragraph \
    --prop basedOn=Normal --prop qFormat=true --prop align=left \
    --prop firstLineChars=0 --prop firstLineIndent=0pt >/dev/null
  styles_added+=("TOCHeading")
fi

# --- 2. place or reuse the TOC field ----------------------------------------
toc_json="$($TMO officecli query "$out_abs" toc --json 2>/dev/null || echo '{}')"
toc_count="$(jq -r '[.data.results[]?] | length' <<<"$toc_json" 2>/dev/null || echo 0)"

toc_created=false
toc_reused=false
toc_path=""
declare -a toc_paths=()

if (( toc_count == 0 )); then
  # Insert after a Title paragraph if one exists, else at the top of the body.
  para_json="$($TMO officecli query "$out_abs" paragraph --json 2>/dev/null || echo '{}')"
  title_para="$(jq -r '[.data.results[]? | select((.format.styleId // "") == "Title")][0].path // ""' <<<"$para_json")"
  first_para="$(jq -r '[.data.results[]?][0].path // ""' <<<"$para_json")"
  anchor=()
  if [[ -n "$title_para" ]]; then anchor=(--after "$title_para")
  elif [[ -n "$first_para" ]]; then anchor=(--before "$first_para")
  fi
  toc_args=(--type toc --prop levels="$LEVELS" --prop hyperlinks=true --prop pageNumbers=false)
  [[ -n "$TITLE" ]] && toc_args+=(--prop title="$TITLE")
  add_json="$($TMO officecli add "$out_abs" /body "${toc_args[@]}" "${anchor[@]+"${anchor[@]}"}" --json)"
  jq -e '.success == true' >/dev/null 2>&1 <<<"$add_json" || die "OfficeCLI could not add the TOC field"
  toc_created=true
  toc_path="$(jq -r '.data | capture(" at (?<p>/[^ ]+)").p // ""' <<<"$add_json" 2>/dev/null || echo "")"
else
  # Reuse every existing TOC so none is left carrying page numbers. Normally
  # there is exactly one.
  mapfile -t toc_paths < <(jq -r '.data.results[]?.path' <<<"$toc_json")
  for p in "${toc_paths[@]}"; do
    $TMO officecli set "$out_abs" "$p" \
      --prop levels="$LEVELS" --prop hyperlinks=true --prop pageNumbers=false >/dev/null
    if [[ -n "$TITLE" ]]; then
      $TMO officecli set "$out_abs" "$p" --prop title="$TITLE" >/dev/null
    fi
  done
  toc_reused=true
  toc_path="${toc_paths[0]}"
fi

# --- 3. refresh LAST so the cache is filled from the current headings --------
$TMO officecli refresh "$out_abs" >/dev/null 2>&1 || true

# --- 4. verify the external behaviour OfficeCLI reports ----------------------
field_json="$($TMO officecli query "$out_abs" field --json 2>/dev/null || echo '{}')"
para_json="$($TMO officecli query "$out_abs" paragraph --json 2>/dev/null || echo '{}')"
raw_doc="$($TMO officecli raw "$out_abs" /document 2>/dev/null || true)"

toc_fields="$(jq -c '[.data.results[]? | select((.format.instruction // "") | startswith("TOC"))]' <<<"$field_json" 2>/dev/null || echo '[]')"
toc_field_count="$(jq -r 'length' <<<"$toc_fields")"
toc_instruction="$(jq -r '.[0].format.instruction // ""' <<<"$toc_fields")"
cache_text="$(jq -r '.[0].text // ""' <<<"$toc_fields")"

# The entries refresh wrote: cached paragraphs carrying a TOC1/TOC2/… style.
entries_json="$(jq -c --argjson lo "$LO" --argjson hi "$HI" '
  [ .data.results[]?
    | select((.format.styleId // "") | test("^TOC[1-9]$"))
    | (.format.styleId | capture("^TOC(?<n>[1-9])$").n | tonumber) as $lvl
    | select($lvl >= $lo and $lvl <= $hi)
    | {level: $lvl, style: .format.styleId, text: (.text // ""), path} ]' <<<"$para_json" 2>/dev/null || echo '[]')"

# The headings the TOC must list, restricted to the requested level range.
headings_json="$(jq -c --argjson lo "$LO" --argjson hi "$HI" '
  [ .data.results[]?
    | select((.format.styleId // "") | test("^Heading[1-9]$"))
    | (.format.styleId | capture("^Heading(?<n>[1-9])$").n | tonumber) as $lvl
    | select($lvl >= $lo and $lvl <= $hi)
    | {level: $lvl, text: (.text // "")} ]' <<<"$para_json" 2>/dev/null || echo '[]')"

entry_count="$(jq -r 'length' <<<"$entries_json")"
heading_count="$(jq -r 'length' <<<"$headings_json")"
pageref_count="$(printf '%s' "$raw_doc" | grep -o 'PAGEREF' | wc -l | tr -d ' ' || true)"
fldchar_begin="$(printf '%s' "$raw_doc" | grep -o 'w:fldCharType="begin"' | wc -l | tr -d ' ' || true)"
fldchar_end="$(printf '%s' "$raw_doc" | grep -o 'w:fldCharType="end"' | wc -l | tr -d ' ' || true)"

# A placeholder is the unresolved wording or the «…» marker. An empty cache is
# only acceptable when the document has no headings in the requested range.
placeholder=false
if [[ "$cache_text" == *"«"* || "$cache_text" == *"»"* || "$cache_text" == "Update field to see table of contents" ]]; then
  placeholder=true
elif [[ -z "$cache_text" && "$heading_count" != "0" ]]; then
  placeholder=true
fi

# Each in-range heading text must appear in the cached entries.
missing=""
while IFS= read -r htext; do
  [[ -n "$htext" ]] || continue
  if ! jq -e --arg t "$htext" 'any(.[]; .text == $t or (.text | contains($t)))' >/dev/null 2>&1 <<<"$entries_json"; then
    missing+="$htext; "
  fi
done < <(jq -r '.[].text' <<<"$headings_json")

verify_ok=true
verify_reasons=()
[[ "$toc_field_count" == "1" ]] || { verify_ok=false; verify_reasons+=("expected exactly one TOC field, found $toc_field_count"); }
[[ "$toc_instruction" == *"\\o \"$LEVELS\""* ]] || { verify_ok=false; verify_reasons+=("instruction lacks levels $LEVELS: '$toc_instruction'"); }
[[ "$toc_instruction" == *"\\h"* ]] || { verify_ok=false; verify_reasons+=("instruction lacks hyperlinks (\\h)"); }
[[ "$toc_instruction" == *"\\z"* && "$toc_instruction" != *"\\n"* ]] || { verify_ok=false; verify_reasons+=("instruction must use \\z (pageNumbers=false), not \\n: '$toc_instruction'"); }
(( pageref_count == 0 )) || { verify_ok=false; verify_reasons+=("$pageref_count PAGEREF page-number reference(s) present"); }
[[ "$placeholder" == "false" ]] || { verify_ok=false; verify_reasons+=("TOC cache is a placeholder or unresolved: '$cache_text'"); }
[[ -z "$missing" ]] || { verify_ok=false; verify_reasons+=("cached entries miss heading(s): $missing"); }
(( entry_count == heading_count )) || { verify_ok=false; verify_reasons+=("$entry_count cached entries for $heading_count heading(s) in levels $LEVELS"); }
(( fldchar_begin >= 1 && fldchar_end >= 1 )) || { verify_ok=false; verify_reasons+=("TOC is not a complex field (begin=$fldchar_begin end=$fldchar_end)"); }

if [[ "$verify_ok" != "true" ]]; then
  {
    echo "$TOOL: TOC cache failed verification in $OUT"
    printf '  - %s\n' "${verify_reasons[@]}"
  } >&2
  exit 1
fi

# --- 5. change report -------------------------------------------------------
report_add "$REPORT_FILE" changed \
  "Table of contents: $([[ "$toc_created" == "true" ]] && echo built || echo reused) a TOC field (levels $LEVELS) from the document's headings — $entry_count entr$([[ "$entry_count" == "1" ]] && echo y || echo ies), cached and verified through OfficeCLI."
if ((${#styles_added[@]} > 0)); then
  report_add "$REPORT_FILE" changed \
    "Table of contents: defined the standard entry style definitions (${styles_added[*]}); no other style was defined."
fi
report_add "$REPORT_FILE" decisions \
  "Table of contents: page numbers are intentionally omitted in v0.1 (spec D9). The TOC is a real field; the cached entries carry no PAGEREF reference, so no application ever shows a wrong number."

# Route the omitted-page-number risk through the shared D11 policy (never hard-
# code a code): shipped but explicitly marked unverified.
"$RISK" emit --report "$REPORT_FILE" --trigger unverifiable-field --resolution state \
  --detail "table of contents page numbers are intentionally omitted in v0.1 (spec D9); update the TOC (Word/WPS: click it and press F9, or Update Table) to add page numbers" >/dev/null

"$CHANGE_REPORT" validate --report "$REPORT_FILE" >/dev/null

# --- 6. source protection ---------------------------------------------------
src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- 7. report --------------------------------------------------------------
report_json="$(jq -c '.' "$REPORT_FILE")"
final_json="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson report "$report_json" \
  --arg report_file "$REPORT_OUT" \
  --arg levels "$LEVELS" --arg title "$TITLE" \
  --arg toc_path "$toc_path" --arg toc_instruction "$toc_instruction" \
  --argjson toc_created "$toc_created" --argjson toc_reused "$toc_reused" \
  --argjson styles_added "$(printf '%s\n' "${styles_added[@]:-}" | jq -R . | jq -sc '[.[] | select(length > 0)]')" \
  --argjson entries "$entries_json" \
  --argjson entry_count "$entry_count" --argjson heading_count "$heading_count" \
  --argjson pageref_count "$pageref_count" \
  --argjson toc_field_count "$toc_field_count" \
  --argjson placeholder "$placeholder" '
  { source: $source,
    output: $output,
    source_unchanged: $source_unchanged,
    change_report: ([$report.changed[], $report.decisions[], $report.warnings[], $report.downgrades[], $report.unverified[]]),
    evidence: {
      levels: $levels,
      title: (if $title == "" then null else $title end),
      toc_path: (if $toc_path == "" then null else $toc_path end),
      toc_created: $toc_created,
      toc_reused: $toc_reused,
      toc_field_count: $toc_field_count,
      field_instruction: (if $toc_instruction == "" then null else $toc_instruction end),
      entry_count: $entry_count,
      heading_count: $heading_count,
      entries: $entries,
      page_numbers: false,
      pageref_count: $pageref_count,
      placeholder: $placeholder,
      styles_added: $styles_added
    },
    report_file: (if $report_file == "" then null else $report_file end),
    report: $report }')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$final_json"
  exit 0
fi

jq -r '
  "WordFlow table of contents",
  "  source:       " + .source,
  "  output:       " + .output,
  "  TOC:          " + (if .evidence.toc_reused then "reused" else "created" end)
                     + " " + (.evidence.toc_path // "(unknown)")
                     + " levels " + .evidence.levels
                     + (if .evidence.title == null then "" else " title \"" + .evidence.title + "\"" end),
  "  entries:      " + (.evidence.entry_count | tostring)
                     + " (from " + (.evidence.heading_count | tostring) + " heading(s))",
  "  page numbers: omitted (no PAGEREF); cached entries list the headings",
  "  source kept:  " + (.source_unchanged | tostring),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$final_json"
