#!/usr/bin/env bash
#
# WordFlow walking-skeleton pipeline (#35).
#
# The smallest end-to-end restyle pipeline that proves WordFlow's full loop is
# real (spec `docs/spec/v0.1.md` §D3, §D4, §D5, §D12, §D13, §D14):
#
#   intake / inspect  ->  style-ownership decision  ->  apply layout
#                     ->  NEW output (collision-safe)  ->  validate
#                     ->  render preview of the final output  ->  change report
#                     ->  risk-policy hooks  ->  deliver
#
# It orchestrates only the merged capabilities; it reimplements none of them:
#
#   #15 scripts/wf-intake.sh           precedence, source protection, output plan
#   #16 scripts/wf-style-ownership.sh  the rebuild/preserve/template decision
#   #17 scripts/wf-standard-styles.sh  the rebuild outcome (standard style set)
#   #18 scripts/wf-page-setup.sh       page setup, applied on every path
#   #13 scripts/wf-output-name.sh      default naming + collision numbering
#   #28 scripts/wf-change-report.sh    the change report (five areas)
#   #29 scripts/wf-render-preview.sh   the preview of the delivered output
#   #30 scripts/wf-risk-policy.sh       warn / downgrade / stop hooks
#
# Scope of this slice: body/headings and page setup. The source is never modified
# (ADR-0003); the output is always a new file. The change report records every
# decision, every warning/downgrade, and every unverified item for its scope;
# see `references/workflow/pipeline.md`.
#
# Risk hooks are exercised against the *delivered output*, because that is what
# the reader opens: constructs that may render differently (floating images,
# nested tables, page-number restarts) are warned about through #30. A source
# that cannot be read stops through #30 and produces no output.
#
# Usage:
#   wf-pipeline.sh --source <docx> [--out-dir <dir> | --output <path>]
#                  [--template <docx>] [--requirement <file>]
#                  [--preview-format png|pdf] [--no-preview] [--json]
#
# Exit codes: 0 = delivered; 1 = runtime failure (apply/validate/QA/report);
#             2 = usage error / missing dependency; 3 = stop and ask.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTAKE="$SCRIPT_DIR/wf-intake.sh"
STYLE_OWNERSHIP="$SCRIPT_DIR/wf-style-ownership.sh"
PAGE_SETUP="$SCRIPT_DIR/wf-page-setup.sh"
STD_STYLES="$SCRIPT_DIR/wf-standard-styles.sh"
CHANGE_REPORT="$SCRIPT_DIR/wf-change-report.sh"
RENDER_PREVIEW="$SCRIPT_DIR/wf-render-preview.sh"
RISK="$SCRIPT_DIR/wf-risk-policy.sh"

readonly TOOL="wf-pipeline.sh"
readonly TMO="timeout 60"

usage() {
  cat <<'EOF'
Usage: wf-pipeline.sh --source <docx> [options]

Run the WordFlow walking skeleton over one existing .docx (restyle):
inspect -> style-ownership decision -> apply layout -> new output -> validate
-> preview -> change report -> risk hooks -> deliver. The source is never
modified; the output is a new, collision-numbered file.

Arguments:
  --source <docx>            The source document to restyle (required).

Options:
  --out-dir <dir>            Directory for the output, preview, and report
                             (default: the source's directory).
  --output <path>            Exact output path (refuses to overwrite) or a
                             directory. Mutually exclusive with --out-dir.
  --template <docx>          Source of look only (resolved by intake; adopting
                             it is #27, not in this slice).
  --requirement <file>       Written formatting requirement (resolved by intake;
                             applying its overrides is a later feature).
  --preview-format <fmt>     png (default) or pdf.
  --no-preview               Do not render; record the omission in the report.
  --json                     Print a machine-readable result summary.
  -h, --help                 Show this help.

Exit codes: 0 delivered; 1 runtime failure; 2 usage/dependency; 3 stop and ask.
EOF
}

SRC=""; OUT_DIR=""; OUT_PATH=""; TPL=""; REQ=""
PREVIEW_FMT="png"; PREVIEW=1; JSON=0
while (($#)); do
  case "$1" in
    --source)       (($# >= 2)) || { echo "--source requires a value" >&2; exit 2; }; SRC="$2"; shift 2 ;;
    --out-dir)      (($# >= 2)) || { echo "--out-dir requires a value" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --output)       (($# >= 2)) || { echo "--output requires a value" >&2; exit 2; }; OUT_PATH="$2"; shift 2 ;;
    --template)     (($# >= 2)) || { echo "--template requires a value" >&2; exit 2; }; TPL="$2"; shift 2 ;;
    --requirement)  (($# >= 2)) || { echo "--requirement requires a value" >&2; exit 2; }; REQ="$2"; shift 2 ;;
    --preview-format) (($# >= 2)) || { echo "--preview-format requires a value" >&2; exit 2; }; PREVIEW_FMT="$2"; shift 2 ;;
    --no-preview)   PREVIEW=0; shift ;;
    --json)         JSON=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)              echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die_usage() { echo "$TOOL: $*" >&2; exit 2; }

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -f "$SRC" ]] || die_usage "source not found: $SRC"
[[ -z "$TPL" || -f "$TPL" ]] || die_usage "template not found: $TPL"
[[ -z "$REQ" || -f "$REQ" ]] || die_usage "requirement not found: $REQ"
[[ -n "$OUT_DIR" && -n "$OUT_PATH" ]] && die_usage "--out-dir and --output are mutually exclusive"
[[ "$PREVIEW_FMT" == "png" || "$PREVIEW_FMT" == "pdf" ]] || die_usage "unsupported preview format: $PREVIEW_FMT"

for bin in officecli jq sha256sum cp; do
  command -v "$bin" >/dev/null || die_usage "$bin not found on PATH"
done
for tool in "$INTAKE" "$STYLE_OWNERSHIP" "$PAGE_SETUP" "$STD_STYLES" "$CHANGE_REPORT" "$RENDER_PREVIEW" "$RISK"; do
  [[ -x "$tool" ]] || die_usage "missing or non-executable capability: $tool"
done
if (( PREVIEW )); then
  for bin in soffice pdftoppm; do
    command -v "$bin" >/dev/null || die_usage "$bin not found on PATH (needed for the preview)"
  done
fi

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# qa_dangling <docx> -> number of referenced styles that are not defined.
#
# D14 requires that every referenced style is defined. OfficeCLI's `view stats`
# reports referenced styles by the name it resolves, which is the style's
# display name for explicitly referenced styles and its styleId for the default
# style; definitions carry both a styleId and a name. A reference is therefore
# satisfied by either. (scripts/wf-style-ownership.sh #16 matches display names
# only, which false-positives on #17 output whose display names are translated —
# reported as an upstream gap, not patched here.)
qa_dangling() {
  local doc="$1" styles stats defined referenced
  styles="$($TMO officecli get "$doc" /styles --json 2>/dev/null || echo '{}')"
  stats="$($TMO officecli view "$doc" stats --json 2>/dev/null || echo '{}')"
  defined="$(jq -r '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | .[] | ascii_downcase' <<<"$styles" 2>/dev/null || true)"
  referenced="$(jq -r '.data.styleDistribution // {} | keys[] | ascii_downcase' <<<"$stats" 2>/dev/null || true)"
  awk 'NR==FNR { if ($0 != "") def[$0]=1; next } $0 != "" && !($0 in def) { c++ } END { print c+0 }' \
    <(printf '%s\n' "$defined") <(printf '%s\n' "$referenced")
}

# Resolve the artifact directory before running intake (the plan resolves the
# exact output path, but not the directory we place preview/report artifacts in).
if [[ -n "$OUT_DIR" ]]; then
  ART_DIR="$OUT_DIR"
elif [[ -n "$OUT_PATH" ]]; then
  if [[ -d "$OUT_PATH" || "$OUT_PATH" == */ ]]; then ART_DIR="$OUT_PATH"; else ART_DIR="$(dirname "$OUT_PATH")"; fi
else
  ART_DIR="$(dirname "$src_abs")"
fi
mkdir -p "$ART_DIR"
ART_DIR="$(cd "$ART_DIR" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wf-pipeline.XXXXXX")"
cleanup() {
  officecli close "$src_abs" >/dev/null 2>&1 || true
  if [[ -n "${FINAL:-}" ]]; then officecli close "$FINAL" >/dev/null 2>&1 || true; fi
  if [[ -f "${WORK:-}/page.docx" ]]; then officecli close "$WORK/page.docx" >/dev/null 2>&1 || true; fi
  if [[ -n "${WORK:-}" && -d "${WORK:-}" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

SRC_SHA_BEFORE="$(sha_of "$src_abs")"

# --- 1. intake / inspect ----------------------------------------------------
# intake owns precedence, source protection, and the collision-safe output path.
set +e
intake_args=("--source" "$src_abs" "--json")
[[ -n "$TPL" ]] && intake_args+=("--template" "$(abs "$TPL")")
[[ -n "$REQ" ]] && intake_args+=("--requirement" "$(abs "$REQ")")
if [[ -n "$OUT_DIR" ]]; then intake_args+=("--output" "$ART_DIR")
elif [[ -n "$OUT_PATH" ]]; then intake_args+=("--output" "$(abs "$OUT_PATH")"); fi
plan="$("$INTAKE" "${intake_args[@]}" 2>"$WORK/intake.err")"
rc=$?
set -e

if (( rc != 0 )); then
  reason="$(jq -r '.reason_code // ""' <<<"$plan" 2>/dev/null || echo "")"
  msg="$(jq -r '.message // ""' <<<"$plan" 2>/dev/null || echo "")"
  case "$reason" in
    source-unreadable|source-invalid)
      # Route the stop through the shared policy (#30): stop means no output.
      ask="$("$RISK" decide --trigger source-unreadable --json 2>/dev/null | jq -r '.ask // empty' || true)"
      echo "$TOOL: STOP — ${msg:-source cannot be read safely}" >&2
      [[ -n "$ask" ]] && echo "$TOOL: ask the user — $ask" >&2
      exit 3 ;;
    *)
      echo "$TOOL: intake refused (${reason:-unknown}): ${msg:-see stderr}" >&2
      [[ -s "$WORK/intake.err" ]] && cat "$WORK/intake.err" >&2
      exit 3 ;;
  esac
fi

status="$(jq -r '.status // ""' <<<"$plan")"
[[ "$status" == "planned" ]] || { echo "$TOOL: intake did not produce a plan" >&2; exit 1; }

FINAL="$(jq -r '.output.output' <<<"$plan")"
DECISION="$(jq -r '.style.ownership // "rebuild-with-standard-styles"' <<<"$plan")"
STYLE_SOURCE="$(jq -r '.style.source // ""' <<<"$plan")"
ENGINE_SHA="$(jq -r '.source.sha256' <<<"$plan")"
[[ -n "$FINAL" && "$FINAL" != "null" ]] || { echo "$TOOL: no output path in the plan" >&2; exit 1; }
out_base="$(basename "$FINAL")"; out_stem="${out_base%.docx}"
REPORT_JSON="$ART_DIR/$out_stem-report.json"
REPORT_MD="$ART_DIR/$out_stem-report.md"
PLAN_ART="$ART_DIR/$out_stem-plan.json"
INPUT_COPY="$ART_DIR/input-$(basename "$src_abs")"

# A self-contained artifact set: keep a copy of the input beside the output.
if [[ "$src_abs" != "$INPUT_COPY" ]]; then cp -f "$src_abs" "$INPUT_COPY"; fi
printf '%s' "$plan" > "$PLAN_ART"

# --- 2. apply layout -> NEW output ------------------------------------------
# Both outcomes go through #18 page setup; the rebuild outcome additionally
# applies the standard style set (#17). Preserve keeps the source style set.
page_json=""
case "$DECISION" in
  rebuild-with-standard-styles)
    "$PAGE_SETUP" "$src_abs" --out "$WORK/page.docx" --json > "$WORK/page.json"
    "$STD_STYLES" "$WORK/page.docx" --out "$FINAL" --json > "$WORK/styles.json"
    page_json="$(cat "$WORK/page.json")" ;;
  preserve-and-tidy|use-template-styles)
    "$PAGE_SETUP" "$src_abs" --out "$FINAL" --json > "$WORK/page.json"
    page_json="$(cat "$WORK/page.json")" ;;
  *)
    echo "$TOOL: unknown style-ownership decision: $DECISION" >&2; exit 1 ;;
esac

[[ -f "$FINAL" && -s "$FINAL" ]] || { echo "$TOOL: no output produced at $FINAL" >&2; exit 1; }
[[ "$(abs "$FINAL")" != "$src_abs" ]] || { echo "$TOOL: output equals source; refusing" >&2; exit 1; }

# --- 3. validate the output (schema gate) -----------------------------------
set +e
val_json="$($TMO officecli validate "$FINAL" --json 2>/dev/null)"
set -e
val_ok="$(jq -r '.success // false' <<<"$val_json" 2>/dev/null || echo false)"
[[ "$val_ok" == "true" ]] || { echo "$TOOL: officecli validate failed for $FINAL" >&2; exit 1; }

# --- 4. change report (created empty, then filled) --------------------------
"$CHANGE_REPORT" new --source "$src_abs" --output "$FINAL" --out "$REPORT_JSON" >/dev/null
add() { local area="$1"; shift; "$CHANGE_REPORT" add --report "$REPORT_JSON" --area "$area" "$@"; }

# --- 5. render preview of the FINAL output ----------------------------------
preview_json=""
if (( PREVIEW )); then
  preview_json="$("$RENDER_PREVIEW" "$FINAL" --out "$ART_DIR" --format "$PREVIEW_FMT" --report "$REPORT_JSON" --json)"
else
  preview_json="$("$RENDER_PREVIEW" "$FINAL" --disabled --report "$REPORT_JSON" --json)"
fi

# --- 6. assemble the report entries -----------------------------------------
mapfile -t intake_entries < <(jq -r '.change_report[]?' <<<"$plan")
for e in "${intake_entries[@]}"; do add changed --entry "$e"; done

if [[ -n "$(jq -r '.change_report[0]? // empty' <<<"$page_json")" ]]; then
  add changed --entry "$(jq -r '.change_report[0]' <<<"$page_json")"
fi

case "$DECISION" in
  rebuild-with-standard-styles)
    add changed --entry "$(jq -r '.change_report[0]' "$WORK/styles.json")"
    add decisions --entry "Style ownership: rebuild-with-standard-styles — the source uses no named styles, so the WordFlow standard set (#17) defines the look."
    add decisions --entry "Page setup: WordFlow default (A4 portrait, margins top/bottom 2.54cm, left/right 3.17cm; spec D6) applied because nothing specified otherwise." ;;
  preserve-and-tidy)
    add changed --entry "Style ownership: preserved the source's own named style set; no rebuild applied."
    add decisions --entry "Style ownership: preserve-and-tidy — the source already uses named styles, so they are kept (spec D5.3)."
    add decisions --entry "Page setup: WordFlow default (A4 portrait, margins top/bottom 2.54cm, left/right 3.17cm; spec D6) applied because nothing specified otherwise." ;;
  use-template-styles)
    add changed --entry "A template was supplied; its adoption is #27 and is not part of this slice, so the source's own styles are preserved in this run."
    add unverified --entry "[template-adoption] A template was supplied but template look adoption (#27) is not implemented in the walking skeleton; the source's styles were kept." ;;
esac

# Preserve path: the tidy step is not yet available; surface repair items.
mapfile -t dangling < <(jq -r '.style.dangling_styles[]?' <<<"$plan")
if [[ ${#dangling[@]} -gt 0 ]]; then
  add unverified --entry "[tidy-pending] The source references undefined style(s): ${dangling[*]}. Repairing them is the tidy step's job and is not part of the walking skeleton."
fi

# Requirement supplied: its machine-applicable overrides are not applied here.
if [[ "$(jq -r '.inputs.requirement.overrides | length' <<<"$plan" 2>/dev/null || echo 0)" -gt 0 ]]; then
  add unverified --entry "[formatting-requirement] A formatting requirement with machine-applicable overrides was supplied; applying them is a later feature, so the WordFlow defaults were used."
fi

# --- 7. risk-policy hooks over the delivered output -------------------------
emit_risk() { "$RISK" emit --report "$REPORT_JSON" "$@"; }

anchored="$($TMO officecli query "$FINAL" 'picture[anchor=true]' --json 2>/dev/null | jq -r '.data.matches // 0' || echo 0)"
if [[ "$anchored" =~ ^[0-9]+$ ]] && (( anchored > 0 )); then
  emit_risk --trigger floating-image --detail "$anchored anchored (floating) image(s) present in the delivered output"
fi
nested="$($TMO officecli query "$FINAL" 'table table' --json 2>/dev/null | jq -r '.data.matches // 0' || echo 0)"
if [[ "$nested" =~ ^[0-9]+$ ]] && (( nested > 0 )); then
  emit_risk --trigger nested-table --detail "$nested nested table(s) present in the delivered output"
fi
sec_json="$($TMO officecli query "$FINAL" section --json 2>/dev/null || echo '{}')"
restart="$(jq -r '[.data.results[]? | select(.format.pageStart != null)] | length' <<<"$sec_json" 2>/dev/null || echo 0)"
if [[ "$restart" =~ ^[0-9]+$ ]] && (( restart > 0 )); then
  emit_risk --trigger page-number-restart --detail "a page-number restart is present in $restart section(s)"
fi

# --- 8. QA checklist for this slice (D14) -----------------------------------
# Source unchanged.
set +e
src_sha_after="$(sha_of "$src_abs")"
dangling_count="$(qa_dangling "$FINAL")"
field_json="$($TMO officecli query "$FINAL" field --json 2>/dev/null || echo '{}')"
field_count="$(jq -r '.data.matches // 0' <<<"$field_json" 2>/dev/null || echo 0)"
placeholder_count="$(jq -r '[.data.results[]? | select((.text // "") | test("«|»|update field|placeholder"; "i"))] | length' <<<"$field_json" 2>/dev/null || echo 0)"
set -e

if (( placeholder_count > 0 )); then
  # Never ship a placeholder silently: state it (D11 row 7, resolution=state).
  emit_risk --trigger unverifiable-field --resolution state --detail "$placeholder_count field(s) carry a placeholder cached result in the delivered output"
fi

src_unchanged=0; [[ "$src_sha_after" == "$SRC_SHA_BEFORE" && "$SRC_SHA_BEFORE" == "$ENGINE_SHA" ]] && src_unchanged=1

# --- 9. render and validate the report --------------------------------------
"$CHANGE_REPORT" validate --report "$REPORT_JSON" >/dev/null
"$CHANGE_REPORT" render --report "$REPORT_JSON" --format markdown > "$REPORT_MD"

# --- 10. deliver ------------------------------------------------------------
if (( JSON )); then
  jq -nc \
    --arg tool "$TOOL" \
    --arg source "$src_abs" \
    --arg output "$FINAL" \
    --arg decision "$DECISION" \
    --arg style_source "$STYLE_SOURCE" \
    --argjson collision "$(jq -c '.output | {collision_index, numbered, mode}' <<<"$plan")" \
    --arg report_json "$REPORT_JSON" \
    --arg report_md "$REPORT_MD" \
    --arg plan "$PLAN_ART" \
    --arg input_copy "$INPUT_COPY" \
    --argjson preview "$(jq -c '{format,disabled,pages,artifacts}' <<<"$preview_json")" \
    --argjson qa "$(jq -nc --argjson d "$dangling_count" --argjson f "$field_count" --argjson p "$placeholder_count" \
        '{dangling_styles: $d, fields: $f, placeholder_fields: $p}')" \
    --argjson source_unchanged "$([[ $src_unchanged == 1 ]] && echo true || echo false)" \
    --argjson report "$(cat "$REPORT_JSON")" \
    '{status:"delivered", tool:$tool, source:$source, output:$output, decision:$decision,
      style_source:$style_source, collision:$collision,
      preview:$preview, qa:$qa, source_unchanged:$source_unchanged,
      artifacts:{output:$output, input:$input_copy, plan:$plan, report_json:$report_json, report_md:$report_md},
      report:$report}'
else
  cat <<EOF
$TOOL: delivered
  source        $src_abs  (unchanged)
  decision      $DECISION
  output        $FINAL
  report        $REPORT_JSON
                $REPORT_MD
  preview       $(jq -r '(.artifacts // []) | join("\n                ")' <<<"$preview_json")
  QA            dangling styles: $dangling_count | fields: $field_count | placeholders: $placeholder_count
EOF
fi
