#!/usr/bin/env bash
#
# WordFlow equation primitive (#26).
#
# Adds one equation to a document through OfficeCLI, as a real OMML equation
# (`m:oMath` inline, `m:oMathPara` display). It never changes the equation's
# content and never downgrades it: an image or plain-text fallback would require
# a renderer WordFlow does not have (ADR-0001) and would author content
# (ADR-0002).
#
# The judgement (spec `docs/spec/v0.1.md` §D8/§D9, R04
# `references/research/complex-equations.md`):
#
#   * simple inline and display equations are fully supported;
#   * matrices and equation arrays (`m:eqArr`) are faithful in all three
#     applications and produce NO warning;
#   * the FormulaParser's `\begin{aligned}` output and any formula containing the
#     absolute-value bar `|` are mis-rendered by LibreOffice 24.2. WordFlow keeps
#     the OMML and warns through the shared risk policy (#30) with the D11
#     trigger `complex-equation` (warn and continue); the warning is recorded in
#     the change report (#28) and returned in this script's JSON.
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and only that new file is changed, through OfficeCLI. The byte copy is
# a file duplication, not a DOCX read or write; every DOCX operation still goes
# through OfficeCLI.
#
# Usage:
#   scripts/wf-equation.sh <source.docx> --out <output.docx> --formula <formula>
#       [--mode inline|display] [--para <path>] [--report <report.json>] [--json]
#
# Exit codes: 0 = equation added; 1 = OfficeCLI could not read/write a document
#             or validation failed; 2 = bad usage / missing dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK="$SCRIPT_DIR/wf-risk-policy.sh"

usage() {
  cat <<'EOF'
Usage: wf-equation.sh <source.docx> --out <output.docx> --formula <formula> [options]

Add one OMML equation to a document. The equation is kept as OMML; it is never
replaced by an image or plain text (ADR-0001/0002). A construct with a
construct-specific LibreOffice risk is kept and warned about through the shared
risk policy (`complex-equation`). The source is never modified; the result is
written to --out.

Options:
  --formula <formula>  LaTeX-ish formula (required), e.g. "E = mc^2".
  --mode <mode>        inline | display (default display).
  --para <path>        Parent path (default /body). For inline, the paragraph
                       that receives the equation; display always produces a
                       body-level /body/oMathPara[N].
  --report <file>      Change-report file to create/append (default: a temporary
                       report used only to build this run's JSON).
  --json               Emit the report as JSON instead of text.
  -h, --help           Show this help.

At-risk constructs (LibreOffice 24.2, R04): `\begin{aligned}`/`\begin{align}`/
`\begin{align*}` and any formula containing `|`. Matrices and equation arrays do
not warn.
EOF
}

SRC=""; OUT=""; FORMULA=""; MODE="display"; PARA="/body"; REPORT=""; JSON=0
while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --formula) (($# >= 2)) || { echo "--formula requires a value" >&2; exit 2; }; FORMULA="$2"; shift 2 ;;
    --mode)    (($# >= 2)) || { echo "--mode requires a value" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --para)    (($# >= 2)) || { echo "--para requires a path" >&2; exit 2; }; PARA="$2"; shift 2 ;;
    --report)  (($# >= 2)) || { echo "--report requires a file" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -n "$FORMULA" ]] || { echo "--formula is required" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
[[ "$MODE" == "inline" || "$MODE" == "display" ]] || { echo "invalid --mode: $MODE (inline|display)" >&2; exit 2; }
[[ "$PARA" == /* ]] || { echo "invalid --para: $PARA (an OfficeCLI path such as /body or /body/p[1])" >&2; exit 2; }

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for tool in "$CHANGE_REPORT" "$RISK"; do
  [[ -x "$tool" ]] || { echo "missing or non-executable dependency: $tool" >&2; exit 2; }
done

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# The construct-specific risk is judged on the INPUT formula: the parser rewrites
# an aligned environment before it is stored, so the read-back text cannot be
# used to detect it.
risky_formula=0
has_pipe=0
has_aligned=0
if [[ "$FORMULA" == *"|"* ]]; then has_pipe=1; fi
if [[ "$FORMULA" =~ \\begin\{(aligned|align|align\*)\} ]]; then has_aligned=1; fi
if (( has_pipe || has_aligned )); then risky_formula=1; fi

risk_constructs() {
  local parts=""
  if (( has_aligned )); then parts='\begin{aligned}'; fi
  if (( has_pipe )); then
    if [[ -n "$parts" ]]; then parts="$parts and the '|' character"; else parts="the '|' character"; fi
  fi
  printf '%s' "$parts"
}

# --- copy the bytes, then add the equation through OfficeCLI -----------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wf-equation.XXXXXX")"
cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

# --- change report: create it fresh, or append to a caller's valid report ----
REPORT_REF=""
if [[ -n "$REPORT" ]]; then
  [[ -d "$(dirname "$REPORT")" ]] || { echo "report directory not found: $(dirname "$REPORT")" >&2; exit 2; }
  REPORT_REF="$REPORT"
  REPORT_JSON="$REPORT"
  if [[ -f "$REPORT_JSON" ]]; then
    "$CHANGE_REPORT" validate --report "$REPORT_JSON" >/dev/null || { echo "malformed report: $REPORT" >&2; exit 1; }
  else
    "$CHANGE_REPORT" new --source "$src_abs" --output "$out_abs" --out "$REPORT_JSON" >/dev/null
  fi
else
  REPORT_JSON="$WORK/report.json"
  "$CHANGE_REPORT" new --source "$src_abs" --output "$out_abs" --out "$REPORT_JSON" >/dev/null
fi

# --- add the equation -------------------------------------------------------
before_json="$($TMO officecli query "$out_abs" equation --json)"
jq -e '.success == true' <<<"$before_json" >/dev/null 2>&1 \
  || { echo "OfficeCLI could not read equations from $OUT" >&2; exit 1; }
before_count="$(jq -r '.data.matches // 0' <<<"$before_json")"

add_json="$($TMO officecli add "$out_abs" "$PARA" --type equation --prop mode="$MODE" --prop formula="$FORMULA" --json)"
jq -e '.success == true' <<<"$add_json" >/dev/null 2>&1 \
  || { echo "OfficeCLI could not add the equation to $OUT" >&2; exit 1; }
new_path="$(jq -r '.data // ""' <<<"$add_json" | sed -E 's/^Added equation at //')"

# --- read the equation back (external behaviour, not the command run) -------
get_json="$($TMO officecli get "$out_abs" "$new_path" --json 2>/dev/null || true)"
if ! jq -e '.success == true and (.data.results | length) > 0' <<<"$get_json" >/dev/null 2>&1; then
  # Fall back to the last equation in document order.
  query_json="$($TMO officecli query "$out_abs" equation --json)"
  get_json="$(jq -c '.data.results[-1] as $r | {success:true, data:{results:[$r]}}' <<<"$query_json")"
fi
readback_mode="$(jq -r '.data.results[0].format.mode // ""' <<<"$get_json")"
readback_text="$(jq -r '.data.results[0].text // ""' <<<"$get_json")"

after_json="$($TMO officecli query "$out_abs" equation --json)"
jq -e '.success == true' <<<"$after_json" >/dev/null 2>&1 \
  || { echo "OfficeCLI could not read equations back from $OUT" >&2; exit 1; }
after_count="$(jq -r '.data.matches // 0' <<<"$after_json")"

(( after_count == before_count + 1 )) \
  || { echo "the equation was not added to $OUT ($before_count -> $after_count)" >&2; exit 1; }
[[ "$readback_mode" == "$MODE" ]] \
  || { echo "read-back mode '$readback_mode' does not match requested '$MODE'" >&2; exit 1; }
[[ -n "$readback_text" ]] \
  || { echo "read-back equation formula is empty" >&2; exit 1; }

# --- schema gate ------------------------------------------------------------
val_json="$($TMO officecli validate "$out_abs" --json 2>/dev/null || echo '{}')"
validate_ok=false
[[ "$(jq -r '.success // false' <<<"$val_json" 2>/dev/null)" == "true" ]] && validate_ok=true
if [[ "$validate_ok" != "true" ]]; then
  echo "officecli validate failed for $OUT" >&2
  exit 1
fi

# --- record the change; warn on a construct-specific risk -------------------
"$CHANGE_REPORT" add --report "$REPORT_JSON" --area changed \
  --entry "Equation: added a ${MODE} equation to ${PARA}; kept as OMML — no image or plain-text fallback (ADR-0001/0002)." \
  >/dev/null

if (( risky_formula )); then
  "$RISK" emit --report "$REPORT_JSON" --trigger complex-equation \
    --detail "equation $(risk_constructs) — LibreOffice 24.2 mis-renders it (references/research/complex-equations.md §2)"
fi

change_report="$(jq -c '[.changed[], .decisions[], .warnings[], .downgrades[], .unverified[]]' "$REPORT_JSON")"
warnings="$(jq -c '.warnings' "$REPORT_JSON")"

# --- verify the source is unchanged -----------------------------------------
src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

risky=false
(( risky_formula )) && risky=true

# --- report -----------------------------------------------------------------
evidence="$(jq -nc \
  --arg path "$new_path" --arg mode "$readback_mode" --arg text "$readback_text" \
  --argjson before "$before_count" --argjson after "$after_count" \
  --arg validate "$validate_ok" --arg report "$REPORT_REF" '
  { equation_path: $path,
    readback_mode: $mode,
    readback_text: $text,
    equations_before: $before,
    equations_after: $after,
    formula_non_empty: (($text | length) > 0),
    validate: ($validate == "true"),
    report: (if $report == "" then null else $report end) }')"

report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --arg mode "$MODE" --arg para "$PARA" \
  --arg formula_input "$FORMULA" --arg formula "$readback_text" \
  --argjson risky "$risky" --argjson source_unchanged "$source_unchanged" \
  --argjson change_report "$change_report" --argjson warnings "$warnings" \
  --argjson evidence "$evidence" '
  { source: $source,
    output: $output,
    mode: $mode,
    para: $para,
    formula_input: $formula_input,
    formula: $formula,
    risky: $risky,
    source_unchanged: $source_unchanged,
    change_report: $change_report,
    warnings: $warnings,
    evidence: $evidence }')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow equation",
  "  source:    " + .source,
  "  output:    " + .output,
  "  mode:      " + .mode,
  "  parent:    " + .para,
  "  formula:   " + .formula,
  "  risky:     " + (.risky | tostring),
  "  source unchanged: " + (.source_unchanged | tostring),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
