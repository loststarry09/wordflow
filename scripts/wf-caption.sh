#!/usr/bin/env bash
#
# WordFlow caption primitive (#22).
#
# Adds one figure or table caption to a new output document, through OfficeCLI,
# using the frozen Caption style and an automatic numbering field (spec
# `docs/spec/v0.1.md` §D8 "Captions"):
#
#   * the Caption style — defined by the standard set (§D7); if the source does
#     not define it, the standard Caption definition is added and no other style
#     is defined or expanded;
#   * a SEQ field (`SEQ Figure` / `SEQ Table`) carrying an automatic number;
#   * a correct, non-placeholder cached result: `officecli set / --prop
#     recalcFields=seq` computes SEQ numbering in body document order and writes
#     it into the field's cached result run, which is what Word/WPS display
#     (they do not update fields on open — see
#     references/research/field-recalc-and-cross-app-verification.md).
#
# The caption paragraph is built as the fixture does
# (tests/generate-fixtures.sh, captions/caption-seq.docx), in document order:
#   "Figure "  ->  <SEQ Figure>  ->  ": <caption text>"
# i.e. render "Figure 1: <caption text>". The Caption style is applied, never
# expanded beyond the frozen set.
#
# No placeholder ever ships. After the recalc the field's cached TEXT is read
# back and asserted to be the resolved number; if it cannot be resolved, the
# number is omitted (the caption keeps its label and text without an automatic
# number) and the omission is reported through the shared risk policy
# (`unverifiable-field`, spec §D11) — never a placeholder.
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and every DOCX read/write is performed on --out through OfficeCLI.
# The byte copy is a file duplication, not a DOCX read or write.
#
# Usage:
#   scripts/wf-caption.sh <source.docx> --out <output.docx> --kind figure|table \
#     --text <caption text> [--para <path>] [--report <file>] [--json]
#
# Exit codes: 0 = caption added; 1 = OfficeCLI could not read/write a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

readonly TOOL="wf-caption.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"

usage() {
  cat <<'EOF'
Usage: wf-caption.sh <source.docx> --out <output.docx> --kind figure|table --text <caption text> [options]

Add one figure or table caption to a new output document. The caption uses the
frozen Caption style and an automatic numbering field (SEQ) whose cached result
is correct and never a placeholder. If the source does not define the Caption
style, the standard Caption definition is added; no other style is defined.

Options:
  --out <file>    New output document (required; must differ from the source).
  --kind <kind>   figure | table (required): selects the label and the SEQ
                  identifier (Figure / Table).
  --text <text>   The caption text after the label and number (required).
  --para <path>   Paragraph the caption follows; the caption paragraph is
                  inserted immediately after it. Default: append a new caption
                  paragraph at the end of the body.
  --report <file> Write the change report (#28) to this path. Optional; without
                  it a temporary report is used and embedded in the JSON output.
  --json          Emit the JSON report instead of text.
  -h, --help      Show this help.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die() { echo "$TOOL: $*" >&2; exit 1; }

SRC=""; OUT=""; KIND=""; TEXT=""
PARA=""; REPORT_OUT=""; JSON=0

while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --kind)    (($# >= 2)) || { echo "--kind requires a value" >&2; exit 2; }; KIND="$2"; shift 2 ;;
    --text)    (($# >= 2)) || { echo "--text requires a value" >&2; exit 2; }; TEXT="$2"; shift 2 ;;
    --para)    (($# >= 2)) || { echo "--para requires a path" >&2; exit 2; }; PARA="$2"; shift 2 ;;
    --report)  (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT_OUT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -n "$KIND" ]] || { echo "--kind is required (figure|table)" >&2; usage >&2; exit 2; }
[[ -n "$TEXT" ]] || { echo "--text is required" >&2; usage >&2; exit 2; }
case "$KIND" in
  figure) LABEL="Figure"; SEQID="Figure" ;;
  table)  LABEL="Table";  SEQID="Table"  ;;
  *) echo "invalid --kind: $KIND (figure|table)" >&2; exit 2 ;;
esac
[[ -z "$PARA" || "$PARA" == /* ]] || { echo "invalid --para: $PARA (a document path such as /body/p[2])" >&2; exit 2; }

[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq sha256sum cp sed; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
[[ -x "$RISK" ]] || { echo "risk-policy tool not executable: $RISK" >&2; exit 2; }

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

create_report() {
  "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$1" >/dev/null
}
report_add() { "$CHANGE_REPORT" add --report "$1" --area "$2" --entry "$3" >/dev/null; }

# caption_num <file> <para-path> -> "instruction<TAB>cached-result"
# The caption is a paragraph WordFlow builds, so its SEQ field's runs are
# deterministic: the result run is the first run after the field's instruction
# text. Read that cached TEXT back (never judge a field by its evaluated flag).
caption_num() {
  $TMO officecli get "$1" "$2" --json 2>/dev/null | jq -r '
    (.data.results[0].children // []) as $c
    | ($c | to_entries | map(select(.value.type=="instrText")) | .[0].key) as $i
    | if $i == null then "NA\tNA"
      else ($c[$i+1:] | map(select(.type=="run")) | .[0].text // "") as $res
      | [ ($c[$i].text // "" | gsub("^\\s+|\\s+$"; "")), $res ]
      | @tsv
      end'
}

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

# --- 1. the Caption style must be defined before it is referenced (spec D7/D14)
style_defined=false
style_added=false
if $TMO officecli get "$out_abs" /styles --json 2>/dev/null \
   | jq -e '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | index("Caption") != null' >/dev/null 2>&1; then
  style_defined=true
else
  $TMO officecli add "$out_abs" /styles --type style \
    --prop styleId=Caption --prop name="caption" --prop type=paragraph \
    --prop basedOn=Normal --prop qFormat=true --prop align=center >/dev/null
  style_added=true
fi

# --- 2. where the caption paragraph goes ------------------------------------
anchor_args=()
if [[ -n "$PARA" ]]; then
  pj="$($TMO officecli get "$out_abs" "$PARA" --json 2>&1 || true)"
  if ! jq -e '.success == true and .data.results[0].type == "paragraph"' >/dev/null 2>&1 <<<"$pj"; then
    die_usage "--para $PARA is not a paragraph in the document"
  fi
  anchor_args=(--after "$PARA")
fi

add_caption_para() { # <text> -> new paragraph path
  local text="$1" j p
  j="$($TMO officecli add "$out_abs" /body --type paragraph \
        --prop style=Caption --prop text="$text" \
        "${anchor_args[@]+"${anchor_args[@]}"}" --json)"
  jq -e '.success == true' >/dev/null 2>&1 <<<"$j" || die "OfficeCLI could not add the caption paragraph"
  p="$(jq -r '.data' <<<"$j" | sed -E 's/^.* at //')"
  [[ "$p" == /body/p* ]] || die "could not determine the new caption paragraph path ('$p')"
  printf '%s\n' "$p"
}

# --- 3. build "Figure " + SEQ + ": text" ------------------------------------
para_path="$(add_caption_para "$LABEL ")"
$TMO officecli add "$out_abs" "$para_path" --type field --prop fieldType=seq --prop id="$SEQID" >/dev/null
$TMO officecli add "$out_abs" "$para_path" --type run --prop text=": $TEXT" >/dev/null

# --- 4. make the cached number correct (SEQ numbering in body document order)
$TMO officecli set "$out_abs" / --prop recalcFields=seq >/dev/null

# --- 5. verify the cached TEXT, not the flag --------------------------------
IFS=$'\t' read -r field_instr cached_num < <(caption_num "$out_abs" "$para_path")
seq_field=true
resolved=false
if [[ "$cached_num" =~ ^[0-9]+$ ]]; then
  resolved=true
fi

if [[ "$resolved" != "true" ]]; then
  # Never ship a placeholder (spec D11): omit the automatic number instead. The
  # caption keeps its label and text; the omission is reported through the
  # shared risk policy.
  "$RISK" emit --report "$REPORT_FILE" --trigger unverifiable-field --resolution omit \
    --detail "caption SEQ $SEQID number could not be resolved (cached text: '${cached_num:-<empty>}')" >/dev/null
  $TMO officecli remove "$out_abs" "$para_path" >/dev/null
  para_path="$(add_caption_para "$LABEL: $TEXT")"
  seq_field=false; cached_num=""; field_instr=""
fi

# The final document never ships a placeholder: either the cache was resolved,
# or the numbering field was omitted (number_omitted).
placeholder=false
number_omitted=false
[[ "$seq_field" != "true" ]] && number_omitted=true

# --- 6. read the applied style back (evidence) ------------------------------
style_applied="$($TMO officecli get "$out_abs" "$para_path" --json 2>/dev/null | jq -r '.data.results[0].format.styleId // ""')"

# --- 7. change report --------------------------------------------------------
report_add "$REPORT_FILE" changed \
  "Caption: added a $LABEL caption with the Caption style and an automatic numbering field (SEQ $SEQID); rendered \"$LABEL${cached_num:+ $cached_num}: $TEXT\"."
if [[ "$style_added" == "true" ]]; then
  report_add "$REPORT_FILE" changed \
    "Caption: added the standard Caption style definition (styleId=Caption, basedOn Normal, centred); no other style was defined."
fi
report_add "$REPORT_FILE" decisions \
  "Caption numbering: the SEQ $SEQID field's cached result was computed in body document order (recalcFields=seq) and verified by reading the cached text back — never a placeholder (spec D8/D14)."
if [[ "$seq_field" != "true" ]]; then
  report_add "$REPORT_FILE" unverified \
    "Caption numbering: omitted the automatic $LABEL number because a correct cached result could not be produced; the caption keeps its label and text (spec D11)."
fi

"$CHANGE_REPORT" validate --report "$REPORT_FILE" >/dev/null

# --- 8. source protection ---------------------------------------------------
src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- 9. report ---------------------------------------------------------------
report_json="$(jq -c '.' "$REPORT_FILE")"
report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson report "$report_json" \
  --arg report_file "$REPORT_OUT" \
  --arg kind "$KIND" --arg label "$LABEL" --arg seqid "$SEQID" --arg text "$TEXT" \
  --arg para "$para_path" --arg style "$style_applied" \
  --argjson style_defined "$style_defined" --argjson style_added "$style_added" \
  --argjson seq_field "$seq_field" --argjson resolved "$resolved" \
  --argjson placeholder "$placeholder" --argjson number_omitted "$number_omitted" \
  --arg instr "$field_instr" --arg cached "$cached_num" '
  { source: $source,
    output: $output,
    source_unchanged: $source_unchanged,
    change_report: ([$report.changed[], $report.decisions[], $report.warnings[], $report.downgrades[], $report.unverified[]]),
    evidence: {
      kind: $kind,
      label: $label,
      seq_identifier: $seqid,
      caption_text: $text,
      paragraph: $para,
      style: $style,
      style_defined: $style_defined,
      style_added: $style_added,
      seq_field: $seq_field,
      field_instruction: (if $instr == "" then null else $instr end),
      cached_number: (if $cached == "" then null else ($cached | tonumber? // $cached) end),
      resolved: $resolved,
      number_omitted: $number_omitted,
      placeholder: $placeholder
    },
    report_file: (if $report_file == "" then null else $report_file end),
    report: $report }')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow caption",
  "  source:      " + .source,
  "  output:      " + .output,
  "  kind:        " + .evidence.kind + " (" + .evidence.label + ")",
  "  caption:     " + .evidence.label
                    + (if .evidence.cached_number == null then "" else " " + (.evidence.cached_number|tostring) end)
                    + ": " + .evidence.caption_text,
  "  style:       " + (if .evidence.style == "" then "(none)" else .evidence.style end)
                    + (if .evidence.style_added then " (standard Caption definition added)" else "" end),
  "  SEQ field:   " + (.evidence.seq_field|tostring)
                    + " (cached " + (if .evidence.cached_number == null then "n/a" else (.evidence.cached_number|tostring) end)
                    + ", resolved " + (.evidence.resolved|tostring) + ")",
  "  source kept: " + (.source_unchanged|tostring),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
