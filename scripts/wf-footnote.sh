#!/usr/bin/env bash
#
# WordFlow footnote primitive (#25) — spec §D8/§D9.
#
# Attaches one footnote to a body paragraph in a new output document, through
# OfficeCLI, and guarantees the two footnote styles the standard set defines are
# present, so the footnote text carries no dangling style:
#
#   FootnoteText       paragraph style — footnote text, 宋体 (SimSun) 9 pt (小五)
#   FootnoteReference  character style — reference mark, superscript
#
# Footnotes are fully supported (spec §D8/§D9): the portable construction is the
# standard OOXML one OfficeCLI emits — a `w:footnoteReference` run in the body
# and a `w:footnote` entry in the footnotes part — which Word, WPS Writer and
# LibreOffice Writer all open and render faithfully
# (references/fields/footnotes.md).
#
# Construction (the same one tests/generate-fixtures.sh uses):
#
#   officecli add F /body/p[N] --type footnote --prop text="…"
#
# which writes `w:rStyle FootnoteReference` + `w:footnoteReference w:id=N` in the
# body, and a `w:footnote w:id=N` whose paragraph carries `w:pStyle FootnoteText`
# followed by the footnote text.
#
# Style ownership (spec §D7): a document's own style set is preserved. The two
# footnote styles are added only when the source does not define them; the
# definitions are exactly the ones scripts/wf-standard-styles.sh writes. No other
# style is defined, added, or referenced.
#
# Source protection (ADR-0003): the source is sha256'd, its bytes are copied to
# --out, and every DOCX read/write is performed on --out through OfficeCLI, each
# call under `timeout 60`. The source is verified byte-identical before the job
# reports done.
#
# Risk (spec §D11): the script never hardcodes a D11 code. If it cannot confirm
# the footnote text style was applied it routes an `unverifiable-field` warn
# through scripts/wf-risk-policy.sh, which records it in the change report.
#
# Usage:
#   scripts/wf-footnote.sh <source.docx> --out <output.docx> --text <footnote text> \
#     [--para <paragraph path>] [--report <file>] [--json]
#
# Exit codes: 0 = footnote attached; 1 = OfficeCLI could not read/write a document,
#             or the output still has a dangling style; 2 = bad usage / missing
#             dependency.
#
set -euo pipefail

readonly TOOL="wf-footnote.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"

# The frozen standard footnote faces (spec §D6; confirmed by the CJK font
# research, #8). Written only when the source does not already define the style.
readonly EA_BODY="SimSun"          # 宋体
readonly LATIN_BODY="Times New Roman"
readonly HINT="eastAsia"

# The two footnote styles the standard set defines. Do not expand this list.
readonly FOOTNOTE_STYLES=(FootnoteText FootnoteReference)

usage() {
  cat <<'EOF'
Usage: wf-footnote.sh <source.docx> --out <output.docx> --text <footnote text> [options]

Attach one footnote to a body paragraph. The footnote text is placed in the
footnotes part by OfficeCLI; FootnoteText and FootnoteReference are defined (only
when the source lacks them) and the footnote text style is applied, so there is
no dangling style. The source is never modified; the result is written to --out.

Options:
  --text <text>     The footnote text (required).
  --para <path>     Paragraph to attach the footnote to, e.g. /body/p[1]. Default:
                    the last body paragraph.
  --report <file>   Write the JSON report to this path. Without it a temporary
                    report is used (the report is always embedded in the output).
  --json            Print the JSON report instead of text.
  -h, --help        Show this help.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die() { echo "$TOOL: $*" >&2; exit 1; }

SRC=""; OUT=""; TEXT=""; PARA=""; REPORT=""; JSON=0
PARA_SET=0

while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || die_usage "--out requires a file argument"; OUT="$2"; shift 2 ;;
    --text)    (($# >= 2)) || die_usage "--text requires a value"; TEXT="$2"; shift 2 ;;
    --para)    (($# >= 2)) || die_usage "--para requires a path"; PARA="$2"; PARA_SET=1; shift 2 ;;
    --report)  (($# >= 2)) || die_usage "--report requires a file argument"; REPORT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die_usage "unknown option: $1" ;;
    *)         [[ -z "$SRC" ]] || die_usage "unexpected argument: $1"; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || die_usage "--out is required (the source is never modified)"
[[ -n "$TEXT" ]] || die_usage "--text is required (the footnote text)"
[[ "$TEXT" == *[![:space:]]* ]] || die_usage "--text must not be blank"
[[ -f "$SRC" ]] || die_usage "source not found: $SRC"
[[ -d "$(dirname "$OUT")" ]] || die_usage "output directory not found: $(dirname "$OUT")"
if [[ -n "$REPORT" ]]; then
  [[ -d "$(dirname "$REPORT")" ]] || die_usage "report directory not found: $(dirname "$REPORT")"
fi

for bin in officecli jq cp sha256sum sed comm; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
[[ -x "$RISK" ]] || { echo "risk-policy tool not executable: $RISK" >&2; exit 2; }

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || die_usage "--out must differ from the source (ADR-0003: never modify the source)"

# --- report file (change-report contract, #28) ------------------------------
report_is_temp=0
if [[ -n "$REPORT" ]]; then
  report_path="$REPORT"
else
  report_path="$(mktemp "${TMPDIR:-/tmp}/wf-footnote-report.XXXXXX.json")"
  report_is_temp=1
fi

# --- copy the bytes, then change only the output through OfficeCLI ----------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  if [[ "$report_is_temp" == "1" && -f "$report_path" ]]; then rm -f "$report_path"; fi
  return 0
}
trap cleanup EXIT

"$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$report_path" >/dev/null

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

# --- 1. select the target paragraph -----------------------------------------
para_defaulted=0
if (( ! PARA_SET )); then
  para_defaulted=1
  PARA="$($TMO officecli get "$out_abs" /body --json 2>/dev/null \
    | jq -r '[.data.results[0].children[]? | select(.type=="paragraph")] | last | .path // ""')"
  [[ -n "$PARA" ]] || die "no body paragraph to attach a footnote to in $SRC"
fi

para_json="$($TMO officecli get "$out_abs" "$PARA" --json 2>/dev/null || true)"
if ! jq -e '.success == true and (.data.results[0].type == "paragraph")' <<<"$para_json" >/dev/null 2>&1; then
  if (( para_defaulted )); then
    die "could not resolve a body paragraph to attach the footnote to"
  fi
  rm -f "$out_abs"
  die_usage "--para is not a paragraph path in the document: $PARA"
fi

# --- 2. ensure the two footnote styles are defined (only if absent) ---------
styles_json="$($TMO officecli get "$out_abs" /styles --json 2>/dev/null || true)"
jq -e '.success == true' <<<"$styles_json" >/dev/null 2>&1 \
  || die "OfficeCLI could not read styles from $SRC"
defined_before="$(jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | sort | .[]' <<<"$styles_json")"

has_style() { grep -qx "$1" <<<"$defined_before"; }

add_style_def() { # add_style_def <styleId>
  case "$1" in
    FootnoteText)
      $TMO officecli add "$out_abs" /styles --type style \
        --prop styleId=FootnoteText --prop name="Footnote Text" --prop type=paragraph \
        --prop customStyle=false \
        --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
        --prop size=9 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
        --prop firstLineChars=0 --prop firstLineIndent=0pt >/dev/null ;;
    FootnoteReference)
      $TMO officecli add "$out_abs" /styles --type style \
        --prop styleId=FootnoteReference --prop name="Footnote Reference" --prop type=character \
        --prop customStyle=false \
        --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
        --prop vertAlign=superscript >/dev/null ;;
  esac
}

styles_added=()
styles_preserved=()
for id in "${FOOTNOTE_STYLES[@]}"; do
  if has_style "$id"; then
    styles_preserved+=("$id")
  else
    add_style_def "$id"
    styles_added+=("$id")
  fi
done

# --- 3. attach the footnote through OfficeCLI --------------------------------
add_out="$($TMO officecli add "$out_abs" "$PARA" --type footnote --prop text="$TEXT")"
fn_path="$(sed -n 's/^Added footnote at \(.*\)$/\1/p' <<<"$add_out" | head -n1)"

fn_json="$($TMO officecli get "$out_abs" "$fn_path" --json 2>/dev/null || true)"
if [[ -z "$fn_path" ]] || ! jq -e '.success == true and (.data.results[0].type == "footnote")' <<<"$fn_json" >/dev/null 2>&1; then
  # Fall back to the highest footnote id OfficeCLI now reports.
  fn_path="$($TMO officecli query "$out_abs" footnote --json 2>/dev/null \
    | jq -r '[.data.results[]?.format.id | tonumber] | max | "/footnote[@footnoteId=\(.)]"' 2>/dev/null || true)"
  fn_json="$($TMO officecli get "$out_abs" "$fn_path" --json 2>/dev/null || true)"
fi
jq -e '.success == true and (.data.results[0].type == "footnote")' <<<"$fn_json" >/dev/null 2>&1 \
  || die "OfficeCLI did not create a readable footnote in $OUT"

fn_id="$(jq -r '.data.results[0].format.id | tostring' <<<"$fn_json")"
fn_text="$(jq -r '.data.results[0].text // ""' <<<"$fn_json")"

# Apply the footnote text style explicitly if OfficeCLI did not (it normally
# does, via the `w:pStyle FootnoteText` it writes), then read it back.
fn_p="$fn_path/p[1]"
fn_p_json="$($TMO officecli get "$out_abs" "$fn_p" --json 2>/dev/null || true)"
fn_style="$(jq -r '.data.results[0].format.styleId // ""' <<<"$fn_p_json")"
if [[ "$fn_style" != "FootnoteText" ]]; then
  $TMO officecli set "$out_abs" "$fn_p" --prop style=FootnoteText >/dev/null
  fn_p_json="$($TMO officecli get "$out_abs" "$fn_p" --json 2>/dev/null || true)"
  fn_style="$(jq -r '.data.results[0].format.styleId // ""' <<<"$fn_p_json")"
fi
style_applied=false
[[ "$fn_style" == "FootnoteText" ]] && style_applied=true

# --- 4. assert no dangling style and the two styles are defined + referenced -
styles_json="$($TMO officecli get "$out_abs" /styles --json 2>/dev/null || true)"
jq -e '.success == true' <<<"$styles_json" >/dev/null 2>&1 \
  || die "OfficeCLI could not read styles back from $OUT"

referenced="$( { $TMO officecli raw "$out_abs" /document 2>/dev/null || true
                $TMO officecli raw "$out_abs" /footnotes 2>/dev/null || true
                $TMO officecli raw "$out_abs" /header[1] 2>/dev/null || true
                $TMO officecli raw "$out_abs" /footer[1] 2>/dev/null || true
              } | grep -oE 'w:(pStyle|rStyle) w:val="[^"]+"' \
                | sed -E 's/.*w:val="([^"]+)".*/\1/' | sort -u || true )"
defined_after="$(jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | unique | .[]' <<<"$styles_json")"

dangling="$(comm -23 <(printf '%s\n' "$referenced" | sed '/^$/d' | sort -u) \
                     <(printf '%s\n' "$defined_after" | sed '/^$/d' | sort -u) || true)"
if [[ -n "$dangling" ]]; then
  die "output has a dangling style: $(tr '\n' ' ' <<<"$dangling")"
fi

missing_def=()
for id in "${FOOTNOTE_STYLES[@]}"; do
  grep -qx "$id" <<<"$defined_after" || missing_def+=("$id")
done
((${#missing_def[@]} == 0)) || die "footnote style(s) not defined: ${missing_def[*]}"

ref_names="$(printf '%s\n' "$referenced" | sed '/^$/d')"
legal_ref=0
for id in "${FOOTNOTE_STYLES[@]}"; do
  grep -qx "$id" <<<"$ref_names" && legal_ref=$((legal_ref + 1))
done
(( legal_ref == 2 )) || die "footnote reference(s) do not use both FootnoteText and FootnoteReference"

# --- 5. change report (risk routed through the shared policy) ---------------
joined_styles() { local out="" s; for s in "$@"; do out="${out:+$out, }$s"; done; printf '%s' "$out"; }
"$CHANGE_REPORT" add --report "$report_path" --area changed \
  --entry "Footnote: attached footnote $fn_id to $PARA — \"$fn_text\"." >/dev/null

if ((${#styles_added[@]} > 0)); then
  "$CHANGE_REPORT" add --report "$report_path" --area changed \
    --entry "Footnote styles: defined $(joined_styles "${styles_added[@]}") from the standard set (FootnoteText 宋体 9pt; FootnoteReference superscript)." >/dev/null
fi
if ((${#styles_preserved[@]} > 0)); then
  "$CHANGE_REPORT" add --report "$report_path" --area decisions \
    --entry "Footnote styles: kept the source's existing $(joined_styles "${styles_preserved[@]}") definitions (style ownership, spec D7)." >/dev/null
fi
if (( para_defaulted )); then
  "$CHANGE_REPORT" add --report "$report_path" --area decisions \
    --entry "Footnote target: defaulted to the last body paragraph $PARA." >/dev/null
else
  "$CHANGE_REPORT" add --report "$report_path" --area decisions \
    --entry "Footnote target: used the supplied paragraph $PARA." >/dev/null
fi

if [[ "$style_applied" != "true" ]]; then
  "$RISK" emit --report "$report_path" --trigger unverifiable-field --resolution state \
    --detail "the footnote text style could not be confirmed as FootnoteText" >/dev/null
fi

"$CHANGE_REPORT" validate --report "$report_path" >/dev/null

# --- 6. read the result back (external evidence) -----------------------------
footnotes_json="$($TMO officecli query "$out_abs" footnote --json 2>/dev/null || echo '{}')"
footnote_count="$(jq -r '(.data.results // []) | length' <<<"$footnotes_json" 2>/dev/null || echo 0)"
validated=false
if $TMO officecli validate "$out_abs" >/dev/null 2>&1; then validated=true; fi
[[ "$validated" == "true" ]] || die "output does not validate: $OUT"

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

json_array() { if (($# == 0)); then printf '[]'; else printf '%s\n' "$@" | jq -R . | jq -sc .; fi; }
json_lines() { if [[ -z "$1" ]]; then printf '[]'; else printf '%s\n' "$1" | sed '/^$/d' | jq -R . | jq -sc .; fi; }

evidence_json="$(jq -nc \
  --arg target_paragraph "$PARA" --argjson paragraph_defaulted "$para_defaulted" \
  --arg footnote_path "$fn_path" --arg footnote_id "$fn_id" --arg footnote_text "$fn_text" \
  --arg footnote_paragraph_style "$fn_style" --argjson style_applied "$style_applied" \
  --argjson footnote_count "$footnote_count" \
  --argjson styles_added "$(json_array ${styles_added[@]+"${styles_added[@]}"})" \
  --argjson styles_preserved "$(json_array ${styles_preserved[@]+"${styles_preserved[@]}"})" \
  --argjson styles_defined "$(json_lines "$defined_after")" \
  --argjson referenced_styles "$(json_lines "$referenced")" \
  --argjson dangling_styles "$(json_lines "$dangling")" \
  --argjson validated "$validated" '
  { target_paragraph: $target_paragraph,
    paragraph_defaulted: ($paragraph_defaulted == 1),
    footnote_path: $footnote_path,
    footnote_id: $footnote_id,
    footnote_text: $footnote_text,
    footnote_paragraph_style: $footnote_paragraph_style,
    style_applied: $style_applied,
    footnote_count: $footnote_count,
    styles_added: $styles_added,
    styles_preserved: $styles_preserved,
    styles_defined: $styles_defined,
    referenced_styles: $referenced_styles,
    dangling_styles: $dangling_styles,
    validated: $validated }')"

report_json="$(jq -c '.' "$report_path")"
report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --argjson source_unchanged "$source_unchanged" \
  --arg report_file "$REPORT" \
  --argjson report "$report_json" \
  --argjson evidence "$evidence_json" '
  { source: $source,
    output: $output,
    source_unchanged: $source_unchanged,
    changed: $report.changed,
    decisions: $report.decisions,
    warnings: $report.warnings,
    downgrades: $report.downgrades,
    unverified: $report.unverified,
    change_report: ([$report.changed[], $report.decisions[], $report.warnings[], $report.downgrades[], $report.unverified[]]),
    evidence: $evidence,
    report_file: (if $report_file == "" then null else $report_file end) }')"

printf '%s\n' "$report" > "$report_path"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow footnote",
  "  source:      " + .source,
  "  output:      " + .output,
  "  target:      " + .evidence.target_paragraph
                    + (if .evidence.paragraph_defaulted then " (default)" else "" end),
  "  footnote:    id " + (.evidence.footnote_id|tostring)
                    + " => \"" + .evidence.footnote_text + "\"",
  "  text style:  " + .evidence.footnote_paragraph_style
                    + " (applied=" + (.evidence.style_applied|tostring) + ")",
  "  styles added: " + (if (.evidence.styles_added|length) == 0 then "none"
                       else (.evidence.styles_added|join(", ")) end),
  "  dangling:    " + (if (.evidence.dangling_styles|length) == 0 then "none"
                       else (.evidence.dangling_styles|join(", ")) end),
  "  source kept: " + (.source_unchanged|tostring),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
