#!/usr/bin/env bash
#
# WordFlow full workflows: generate-from-content (#32, spec §D4) and
# tidy-existing-DOCX (#33, spec §D5), on the walking-skeleton pipeline (#35).
#
# One run takes either raw content (a text/Markdown file) or an existing .docx
# through the whole loop:
#
#   intake / inspect  ->  style-ownership / precedence decision  ->  apply look
#                     ->  compose the feature capabilities  ->  NEW output
#                     ->  validate  ->  render preview of the final output
#                     ->  change report  ->  risk hooks  ->  deliver
#
# It orchestrates only the merged capabilities; it reimplements none of them:
#
#   #15 scripts/wf-intake.sh           precedence, source protection, output plan
#   #16 scripts/wf-style-ownership.sh  the rebuild/preserve/template decision
#   #17 scripts/wf-standard-styles.sh  the rebuild outcome (standard style set)
#   #33 scripts/wf-tidy.sh             the preserve outcome (repair dangling styles)
#   #18 scripts/wf-page-setup.sh       page setup, applied on every path
#   #27 scripts/wf-template.sh         adopt a template's look (never content)
#   #13 scripts/wf-output-name.sh      default naming + collision numbering
#   #19 scripts/wf-headers.sh          running headers/footers + live page numbers
#   #20 scripts/wf-image.sh            inline images (+ floating-image downgrade)
#   #21 scripts/wf-table.sh            regular / merged-cell / nested tables
#   #22 scripts/wf-caption.sh          figure/table captions (SEQ cache)
#   #23 scripts/wf-crossref.sh         content cross-references (cached REF)
#   #24 scripts/wf-toc.sh              table of contents without page numbers
#   #25 scripts/wf-footnote.sh         footnotes with defined styles
#   #26 scripts/wf-equation.sh         inline/display OMML equations
#   #28 scripts/wf-change-report.sh    the single change report (five areas)
#   #29 scripts/wf-render-preview.sh   the preview of the delivered output
#   #30 scripts/wf-risk-policy.sh       warn / downgrade / stop hooks
#
# The source is never modified (ADR-0003); the output is always a new file. The
# content build (mapping text/Markdown paragraphs to WordFlow styles) and the
# feature composition are orchestrations of OfficeCLI and the capabilities; no
# feature is reimplemented. The single change report records every decision,
# every warning/downgrade, and every unverified item.
#
# Content format (generate mode; frozen by #32): one construct per non-blank
# line — `# `..`#### ` atx headings map to Heading 1..4, other text is a body
# paragraph, and a trailing `{#name}` on a heading line creates a bookmark (for
# cross-references). `--title` adds the Title paragraph.
#
# Usage:
#   wf-pipeline.sh --source <docx> | --content <file> [options]
#                  [--out-dir <dir> | --output <path>]
#                  [--template <docx>] [--requirement <file>] [--locale <loc>]
#                  [--restructure <kind>] [--confirm-restructure <kind>]
#                  [--preview-format png|pdf] [--no-preview] [--json]
#                  [feature options]
#
# Exit codes: 0 = delivered; 1 = runtime failure (apply/validate/QA/report);
#             2 = usage error / missing dependency; 3 = stop and ask.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTAKE="$SCRIPT_DIR/wf-intake.sh"
STYLE_OWNERSHIP="$SCRIPT_DIR/wf-style-ownership.sh"
TIDY="$SCRIPT_DIR/wf-tidy.sh"
PAGE_SETUP="$SCRIPT_DIR/wf-page-setup.sh"
STD_STYLES="$SCRIPT_DIR/wf-standard-styles.sh"
TEMPLATE="$SCRIPT_DIR/wf-template.sh"
HEADERS="$SCRIPT_DIR/wf-headers.sh"
IMAGE="$SCRIPT_DIR/wf-image.sh"
TABLE="$SCRIPT_DIR/wf-table.sh"
CAPTION="$SCRIPT_DIR/wf-caption.sh"
CROSSREF="$SCRIPT_DIR/wf-crossref.sh"
TOC="$SCRIPT_DIR/wf-toc.sh"
FOOTNOTE="$SCRIPT_DIR/wf-footnote.sh"
EQUATION="$SCRIPT_DIR/wf-equation.sh"
CHANGE_REPORT="$SCRIPT_DIR/wf-change-report.sh"
RENDER_PREVIEW="$SCRIPT_DIR/wf-render-preview.sh"
RISK="$SCRIPT_DIR/wf-risk-policy.sh"

readonly TOOL="wf-pipeline.sh"
readonly TMO="timeout 60"

usage() {
  cat <<'EOF'
Usage: wf-pipeline.sh --source <docx> | --content <file> [options]

Run a full WordFlow workflow over content (generate, spec D4) or an existing
.docx (tidy/restyle, spec D5): inspect -> decision -> apply look -> compose
features -> new output -> validate -> preview -> change report -> risk hooks
-> deliver. The source is never modified; the output is a new, collision-numbered
file.

Source (exactly one):
  --source <docx>            Tidy/restyle an existing document (read-only).
  --content <file>           Generate from a text/Markdown content file.

Restructuring (spec D5.5; never automatic):
  --restructure <kind>       Request a structural change, repeatable. Kinds:
                             heading-levels | section-order | paragraph-grouping.
  --confirm-restructure <kind>
                             Confirm one requested change item by item. A
                             request with no matching confirmation stops and asks.

Look:
  --out-dir <dir>            Directory for output, preview, and report.
  --output <path>            Exact output path (refuses to overwrite) or a dir.
  --template <docx>          Source of look only (adopted via #27).
  --requirement <file>       Written formatting requirement (D2 precedence).
  --title <text>             Generate mode: the document's Title paragraph.
  --locale <loc>             Generate mode creation locale (default zh-CN).

Headers / footers / page numbers (#19):
  --header <text>            Default (odd-page) header text.
  --footer <text>            Default (odd-page) footer text.
  --page-number              Live PAGE/NUMPAGES field in the default footer.
  --header-first/--footer-first <text>   Different-first-page parts.
  --header-even/--footer-even <text>     Even-page parts.
  --restart <n>              Restart page numbering (LIMITED: warns).

Images (#20):
  --image <file>             Place one image (inline; floating is downgraded).
  --image-para <path>        Paragraph to place it in (default /body/p[1]).
  --image-width <length>     e.g. 3cm (default 3cm).
  --image-alt <text>         Alternative text.
  --anchor                   Request floating placement (downgraded + reported).

Tables (#21):
  --table-data <cells>       "H1,H2;R1C1,R1C2".
  --table-widths <w1,w2,...> Per-column widths in twips (required with a table).
  --table-width <length>     Table width (default: sum of widths — portable).
  --table-header-row         Repeat the first row as a header.
  --merge <R,C,ROWS,COLS>    Merge a cell rectangle (repeatable).
  --nested-cell <R,C>        Host cell for a nested table.
  --nested-data <cells>      Nested table data.
  --nested-col-widths <...>  Nested per-column widths in twips.
  --nested-layout <mode>     fixed | autofit.
  --nested-border <spec>     Nested direct borders.

Captions (#22):
  --caption <text>           Caption text (after the automatic number).
  --caption-kind <kind>      figure | table (default figure).
  --caption-para <path>      Paragraph the caption follows (default: append).

Cross-references (#23):
  --xref <bookmark>          Bookmark to reference (created by {#name} content).
  --xref-kind <kind>         ref (default) | pageref (downgraded + reported).
  --xref-para <path>         Paragraph to place the reference in.

Table of contents (#24):
  --toc                      Insert a TOC (cached, no page numbers).
  --toc-levels <a-b>         Heading levels, e.g. 1-3 (default 1-3).
  --toc-title <text>         Title above the TOC.

Footnotes (#25):
  --footnote <text>          Attach a footnote to a paragraph.
  --footnote-para <path>     Paragraph to attach it to (default: last).

Equations (#26):
  --equation <formula>       LaTeX-ish formula.
  --equation-mode <mode>     inline | display (default display).
  --equation-para <path>     Parent/paragraph path.

Preview:
  --preview-format <fmt>     png (default) or pdf.
  --no-preview               Do not render; record the omission in the report.
  --json                     Print a machine-readable result summary.
  -h, --help                 Show this help.

Exit codes: 0 delivered; 1 runtime failure; 2 usage/dependency; 3 stop and ask.
EOF
}

# --- argument parsing -------------------------------------------------------
SRC=""; CONTENT=""; OUT_DIR=""; OUT_PATH=""; TPL=""; REQ=""
LOCALE="zh-CN"; TITLE=""
PREVIEW_FMT="png"; PREVIEW=1; JSON=0

HDR=""; FTR=""; HDR_FIRST=""; FTR_FIRST=""; HDR_EVEN=""; FTR_EVEN=""
PAGE_NUMBER=0; RESTART=""
IMG=""; IMG_PARA=""; IMG_WIDTH=""; IMG_ALT=""; IMG_ANCHOR=0
TBL_DATA=""; TBL_WIDTHS=""; TBL_WIDTH=""; TBL_HEADER=0; NESTED_CELL=""; NESTED_DATA=""
NESTED_COLS=""; NESTED_LAYOUT=""; NESTED_BORDER=""
CAP_TEXT=""; CAP_KIND=""; CAP_PARA=""
XREF_BM=""; XREF_KIND=""; XREF_PARA=""
TOC_ON=0; TOC_LEVELS=""; TOC_TITLE=""
FN_TEXT=""; FN_PARA=""
EQ_FORMULA=""; EQ_MODE=""; EQ_PARA=""
declare -a MERGES=()
declare -a RESTRUCTURE=()
declare -a CONFIRM_RESTRUCTURE=()

require_val() { (($# >= 2)) || { echo "$TOOL: $1 requires a value" >&2; exit 2; }; }

while (($#)); do
  case "$1" in
    --source)       require_val "$@"; SRC="$2"; shift 2 ;;
    --content)      require_val "$@"; CONTENT="$2"; shift 2 ;;
    --out-dir)      require_val "$@"; OUT_DIR="$2"; shift 2 ;;
    --output)       require_val "$@"; OUT_PATH="$2"; shift 2 ;;
    --template)     require_val "$@"; TPL="$2"; shift 2 ;;
    --requirement)  require_val "$@"; REQ="$2"; shift 2 ;;
    --locale)       require_val "$@"; LOCALE="$2"; shift 2 ;;
    --title)        require_val "$@"; TITLE="$2"; shift 2 ;;
    --header)       require_val "$@"; HDR="$2"; shift 2 ;;
    --footer)       require_val "$@"; FTR="$2"; shift 2 ;;
    --page-number)  PAGE_NUMBER=1; shift ;;
    --header-first) require_val "$@"; HDR_FIRST="$2"; shift 2 ;;
    --footer-first) require_val "$@"; FTR_FIRST="$2"; shift 2 ;;
    --header-even)  require_val "$@"; HDR_EVEN="$2"; shift 2 ;;
    --footer-even)  require_val "$@"; FTR_EVEN="$2"; shift 2 ;;
    --restart)      require_val "$@"; RESTART="$2"; shift 2 ;;
    --image)        require_val "$@"; IMG="$2"; shift 2 ;;
    --image-para)   require_val "$@"; IMG_PARA="$2"; shift 2 ;;
    --image-width)  require_val "$@"; IMG_WIDTH="$2"; shift 2 ;;
    --image-alt)    require_val "$@"; IMG_ALT="$2"; shift 2 ;;
    --anchor)       IMG_ANCHOR=1; shift ;;
    --table-data)   require_val "$@"; TBL_DATA="$2"; shift 2 ;;
    --table-widths) require_val "$@"; TBL_WIDTHS="$2"; shift 2 ;;
    --table-width)  require_val "$@"; TBL_WIDTH="$2"; shift 2 ;;
    --table-header-row) TBL_HEADER=1; shift ;;
    --merge)        require_val "$@"; MERGES+=("$2"); shift 2 ;;
    --nested-cell)  require_val "$@"; NESTED_CELL="$2"; shift 2 ;;
    --nested-data)  require_val "$@"; NESTED_DATA="$2"; shift 2 ;;
    --nested-col-widths) require_val "$@"; NESTED_COLS="$2"; shift 2 ;;
    --nested-layout) require_val "$@"; NESTED_LAYOUT="$2"; shift 2 ;;
    --nested-border) require_val "$@"; NESTED_BORDER="$2"; shift 2 ;;
    --caption)      require_val "$@"; CAP_TEXT="$2"; shift 2 ;;
    --caption-kind) require_val "$@"; CAP_KIND="$2"; shift 2 ;;
    --caption-para) require_val "$@"; CAP_PARA="$2"; shift 2 ;;
    --xref)         require_val "$@"; XREF_BM="$2"; shift 2 ;;
    --xref-kind)    require_val "$@"; XREF_KIND="$2"; shift 2 ;;
    --xref-para)    require_val "$@"; XREF_PARA="$2"; shift 2 ;;
    --toc)          TOC_ON=1; shift ;;
    --toc-levels)   require_val "$@"; TOC_LEVELS="$2"; shift 2 ;;
    --toc-title)    require_val "$@"; TOC_TITLE="$2"; shift 2 ;;
    --footnote)     require_val "$@"; FN_TEXT="$2"; shift 2 ;;
    --footnote-para) require_val "$@"; FN_PARA="$2"; shift 2 ;;
    --equation)     require_val "$@"; EQ_FORMULA="$2"; shift 2 ;;
    --equation-mode) require_val "$@"; EQ_MODE="$2"; shift 2 ;;
    --equation-para) require_val "$@"; EQ_PARA="$2"; shift 2 ;;
    --preview-format) require_val "$@"; PREVIEW_FMT="$2"; shift 2 ;;
    --restructure)  require_val "$@"; RESTRUCTURE+=("$2"); shift 2 ;;
    --confirm-restructure) require_val "$@"; CONFIRM_RESTRUCTURE+=("$2"); shift 2 ;;
    --no-preview)   PREVIEW=0; shift ;;
    --json)         JSON=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "$TOOL: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)              echo "$TOOL: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die_usage() { echo "$TOOL: $*" >&2; exit 2; }

[[ -n "$SRC" || -n "$CONTENT" ]] || { usage >&2; exit 2; }
[[ -z "$SRC" || -z "$CONTENT" ]] || die_usage "--source and --content are mutually exclusive"
[[ -z "$SRC" || -f "$SRC" ]] || die_usage "source not found: $SRC"
[[ -z "$CONTENT" || -f "$CONTENT" ]] || die_usage "content not found: $CONTENT"
[[ -z "$TPL" || -f "$TPL" ]] || die_usage "template not found: $TPL"
[[ -z "$REQ" || -f "$REQ" ]] || die_usage "requirement not found: $REQ"
(( ${#RESTRUCTURE[@]} == 0 )) || [[ -n "$SRC" ]] || die_usage "--restructure applies to an existing document (--source), not generated content"
[[ -n "$OUT_DIR" && -n "$OUT_PATH" ]] && die_usage "--out-dir and --output are mutually exclusive"
[[ "$PREVIEW_FMT" == "png" || "$PREVIEW_FMT" == "pdf" ]] || die_usage "unsupported preview format: $PREVIEW_FMT"
[[ -z "$IMG" || -f "$IMG" ]] || die_usage "image not found: $IMG"
[[ -z "$TBL_DATA" || -n "$TBL_WIDTHS" ]] || die_usage "--table-widths is required with --table-data"

for bin in officecli jq sha256sum cp; do
  command -v "$bin" >/dev/null || die_usage "$bin not found on PATH"
done
for tool in "$INTAKE" "$STYLE_OWNERSHIP" "$TIDY" "$PAGE_SETUP" "$STD_STYLES" "$TEMPLATE" \
            "$HEADERS" "$IMAGE" "$TABLE" "$CAPTION" "$CROSSREF" "$TOC" "$FOOTNOTE" \
            "$EQUATION" "$CHANGE_REPORT" "$RENDER_PREVIEW" "$RISK"; do
  [[ -x "$tool" ]] || die_usage "missing or non-executable capability: $tool"
done
if (( PREVIEW )); then
  for bin in soffice pdftoppm; do
    command -v "$bin" >/dev/null || die_usage "$bin not found on PATH (needed for the preview)"
  done
fi

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
[[ -n "$SRC" ]] && src_abs="$(abs "$SRC")" || src_abs=""
[[ -n "$CONTENT" ]] && content_abs="$(abs "$CONTENT")" || content_abs=""
IN_ABS="${src_abs:-$content_abs}"
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

# Resolve the artifact directory before running intake.
if [[ -n "$OUT_DIR" ]]; then
  ART_DIR="$OUT_DIR"
elif [[ -n "$OUT_PATH" ]]; then
  if [[ -d "$OUT_PATH" || "$OUT_PATH" == */ ]]; then ART_DIR="$OUT_PATH"; else ART_DIR="$(dirname "$OUT_PATH")"; fi
else
  ART_DIR="$(dirname "$IN_ABS")"
fi
mkdir -p "$ART_DIR"
ART_DIR="$(cd "$ART_DIR" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wf-pipeline.XXXXXX")"
cleanup() {
  officecli close "$IN_ABS" >/dev/null 2>&1 || true
  if [[ -n "${TPL_ABS:-}" ]]; then officecli close "$TPL_ABS" >/dev/null 2>&1 || true; fi
  if [[ -n "${FINAL:-}" ]]; then officecli close "$FINAL" >/dev/null 2>&1 || true; fi
  if [[ -n "${CURRENT:-}" ]]; then officecli close "$CURRENT" >/dev/null 2>&1 || true; fi
  if [[ -d "${WORK:-}" ]]; then
    while IFS= read -r d; do officecli close "$d" >/dev/null 2>&1 || true; done \
      < <(find "$WORK" -name '*.docx' 2>/dev/null || true)
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- 1. intake / inspect ----------------------------------------------------
set +e
intake_args=("--json")
if [[ -n "$SRC" ]]; then intake_args+=("--source" "$src_abs"); else intake_args+=("--content" "$content_abs"); fi
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
    source-unreadable|source-invalid|content-unreadable)
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

MODE="$(jq -r '.mode // "restyle"' <<<"$plan")"
FINAL="$(jq -r '.output.output' <<<"$plan")"
DECISION="$(jq -r '.style.ownership // "rebuild-with-standard-styles"' <<<"$plan")"
STYLE_SOURCE="$(jq -r '.style.source // ""' <<<"$plan")"
STYLE_SET="$(jq -r '.style.set // ""' <<<"$plan")"
ENGINE_SHA="$(jq -r '.source.sha256' <<<"$plan")"
[[ -n "$FINAL" && "$FINAL" != "null" ]] || { echo "$TOOL: no output path in the plan" >&2; exit 1; }
# Hash the source only after intake has validated it (an unreadable source must
# be refused by intake, not fail here under `set -e`).
IN_SHA_BEFORE="$(sha_of "$IN_ABS")"
[[ "$MODE" == "generate" ]] && DECISION="generate-from-content"
out_base="$(basename "$FINAL")"; out_stem="${out_base%.docx}"
REPORT_JSON="$ART_DIR/$out_stem-report.json"
REPORT_MD="$ART_DIR/$out_stem-report.md"
PLAN_ART="$ART_DIR/$out_stem-plan.json"
INPUT_COPY="$ART_DIR/input-$(basename "$IN_ABS")"

if [[ "$IN_ABS" != "$INPUT_COPY" ]]; then cp -f "$IN_ABS" "$INPUT_COPY"; fi
printf '%s' "$plan" > "$PLAN_ART"

# --- 2. the single change report (created empty, then filled) ---------------
"$CHANGE_REPORT" new --source "$IN_ABS" --output "$FINAL" --out "$REPORT_JSON" >/dev/null
add() { local area="$1"; shift; "$CHANGE_REPORT" add --report "$REPORT_JSON" --area "$area" "$@"; }

# --- 2b. restructure guard (spec D5.5, D11) ---------------------------------
# Restructuring is never automatic: it needs an explicit request AND per-item
# confirmation. Without both, WordFlow stops and asks; it never restructures a
# document on its own. Automated restructuring is not part of v0.1, so a fully
# confirmed request is reported as a downgrade (structure/content unchanged)
# rather than silently ignored.
if (( ${#RESTRUCTURE[@]} > 0 )); then
  missing=()
  for k in "${RESTRUCTURE[@]}"; do
    confirmed=0
    for c in ${CONFIRM_RESTRUCTURE[@]+"${CONFIRM_RESTRUCTURE[@]}"}; do
      [[ "$c" == "$k" ]] && confirmed=1
    done
    (( confirmed )) || missing+=("$k")
  done
  if (( ${#missing[@]} > 0 )); then
    ask="$("$RISK" decide --trigger restructure-unconfirmed --json 2>/dev/null | jq -r '.ask // empty' || true)"
    echo "$TOOL: STOP — restructuring was requested without per-item confirmation: ${missing[*]}" >&2
    [[ -n "$ask" ]] && echo "$TOOL: ask the user — $ask" >&2
    exit 3
  fi
  "$RISK" emit --report "$REPORT_JSON" --trigger preferred-unavailable --fact fallback=exists \
    --detail "restructuring was requested and confirmed (${RESTRUCTURE[*]}), but automated restructuring is not part of v0.1; the document's structure and content are left unchanged" >/dev/null
  add decisions --entry "Restructuring: confirmed item by item (${RESTRUCTURE[*]}); automated restructuring is not part of v0.1, so content and structure were left unchanged (spec D5.5)."
fi

# merge_report <feature-report.json>: fold a feature's five areas into the one
# report. Every capability writes the #28 contract, so the areas translate 1:1.
merge_report() {
  local f="$1" area e
  [[ -f "$f" ]] || return 0
  for area in changed decisions warnings downgrades unverified; do
    while IFS= read -r e; do
      [[ -n "$e" ]] && add "$area" --entry "$e"
    done < <(jq -r --arg a "$area" '.[$a][]?' "$f" 2>/dev/null || true)
  done
}

# run_cap <capability> <args...>: consume $CURRENT, produce the next step, fold
# its report. The capability is used as-is; nothing is reimplemented here.
declare -a FEATURE_STEPS=()
STEP=0
run_cap() {
  local label="$1"; shift
  local script="$1"; shift
  local next frep err rc
  STEP=$((STEP + 1))
  next="$WORK/step-$STEP.docx"; frep="$WORK/step-$STEP-report.json"; err="$WORK/step-$STEP.err"
  # Release any resident of the input so a stale handle cannot leak into the
  # capability's own reads (OfficeCLI resident state is per-file but sticky).
  $TMO officecli close "$CURRENT" >/dev/null 2>&1 || true
  set +e
  "$script" "$CURRENT" --out "$next" --report "$frep" "$@" >/dev/null 2>"$err"
  rc=$?
  set -e
  if (( rc == 3 )); then
    echo "$TOOL: STOP — $label stopped and asks" >&2
    [[ -s "$err" ]] && cat "$err" >&2
    exit 3
  elif (( rc != 0 )); then
    echo "$TOOL: $label failed (exit $rc)" >&2
    [[ -s "$err" ]] && cat "$err" >&2
    exit 1
  fi
  [[ -f "$next" && -s "$next" ]] || { echo "$TOOL: $label produced no output" >&2; exit 1; }
  merge_report "$frep"
  FEATURE_STEPS+=("$label")
  CURRENT="$next"
}

# --- 3. content build (generate mode) ---------------------------------------
# Map text/Markdown to WordFlow styles through OfficeCLI. A trailing `{#name}`
# on a heading line strips off and creates a bookmark of that name.
build_content() {
  local doc="$1" line text bm style n=0
  $TMO officecli close "$doc" >/dev/null 2>&1 || true
  rm -f "$doc"
  $TMO officecli create "$doc" --locale "$LOCALE" >/dev/null
  if [[ -n "$TITLE" ]]; then
    $TMO officecli add "$doc" /body --type paragraph --prop style=Title --prop text="$TITLE" >/dev/null
    n=$((n + 1))
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" == *[![:space:]]* ]] || continue
    style=""
    text="$line"
    case "$line" in
      '#### '*) style=Heading4; text="${line#\#\#\#\# }" ;;
      '### '*)  style=Heading3; text="${line#\#\#\# }" ;;
      '## '*)   style=Heading2; text="${line#\#\# }" ;;
      '# '*)    style=Heading1; text="${line#\# }" ;;
      '- '*)    style=ListParagraph; text="${line#- }" ;;
      '> '*)    style=Quote; text="${line#> }" ;;
    esac
    bm=""
    if [[ "$text" =~ ^(.*[^[:space:]])[[:space:]]*\{\#([A-Za-z0-9._-]+)\}[[:space:]]*$ ]]; then
      text="${BASH_REMATCH[1]}"; bm="${BASH_REMATCH[2]}"
    fi
    local pidx=$((n + 1))
    if [[ -n "$bm" ]]; then
      # A bookmark added at the body creates the paragraph and covers its text;
      # the paragraph is then styled. This is the #12 cached-cross-ref pattern.
      $TMO officecli add "$doc" / --type bookmark --prop "name=$bm" --prop "text=$text" >/dev/null
      [[ -n "$style" ]] && $TMO officecli set "$doc" "/body/p[$pidx]" --prop "style=$style" >/dev/null
    elif [[ -n "$style" ]]; then
      $TMO officecli add "$doc" /body --type paragraph --prop "style=$style" --prop "text=$text" >/dev/null
    else
      $TMO officecli add "$doc" /body --type paragraph --prop "text=$text" >/dev/null
    fi
    n=$((n + 1))
  done < "$content_abs"
  printf '%s\n' "$n"
}

# --- 4. apply the look -> a new output --------------------------------------
# Every path goes through #18 page setup; the rebuild/generate path additionally
# applies the standard style set (#17); a supplied template is adopted through
# #27. The source is never opened for writing (ADR-0003).
apply_page_setup() { # apply_page_setup <in> <out>
  "$PAGE_SETUP" "$1" --out "$2" --json > "$WORK/page.json"
}
apply_standard() { # apply_standard <in> <out>
  "$STD_STYLES" "$1" --out "$2" --json > "$WORK/styles.json"
}

CURRENT=""
if [[ "$MODE" == "generate" ]]; then
  paragraphs="$(build_content "$WORK/base.docx")"
  officecli close "$WORK/base.docx" >/dev/null 2>&1 || true
  CURRENT="$WORK/base.docx"
  add changed --entry "Generate: built a base document from $(basename "$content_abs") through OfficeCLI ($paragraphs paragraph(s), locale $LOCALE)."

  if [[ "$STYLE_SET" == "template" ]]; then
    # A template outranks the defaults for both styles and page setup (D2); it
    # is adopted through #27 and page setup is NOT re-applied over it.
    tpl_args=("--template" "$(abs "$TPL")")
    [[ -n "$REQ" ]] && tpl_args+=("--requirement" "$(abs "$REQ")")
    run_cap "template adoption (#27)" "$TEMPLATE" "${tpl_args[@]}"
    add decisions --entry "Style source: template — the supplied template's look outranks the content defaults, for styles and page setup (spec D2)."
  else
    apply_standard "$CURRENT" "$WORK/gen-styles.docx"
    add changed --entry "$(jq -r '.change_report[0] // "Standard style set applied."' "$WORK/styles.json")"
    add decisions --entry "Style ownership: rebuild-with-standard-styles — generated content has no document style set, so the WordFlow standard set (#17) defines the look."
    CURRENT="$WORK/gen-styles.docx"
    apply_page_setup "$CURRENT" "$WORK/gen-setup.docx"
    add changed --entry "$(jq -r '.change_report[0] // "Page setup applied."' "$WORK/page.json")"
    add decisions --entry "Page setup: WordFlow default (A4 portrait, margins top/bottom 2.54cm, left/right 3.17cm; spec D6) applied because nothing specified otherwise."
    CURRENT="$WORK/gen-setup.docx"
  fi
else
  # Restyle (tidy) workflow.
  case "$DECISION" in
    rebuild-with-standard-styles)
      apply_page_setup "$src_abs" "$WORK/page.docx"
      apply_standard "$WORK/page.docx" "$WORK/styles.docx"
      add changed --entry "$(jq -r '.change_report[0] // "Page setup applied."' "$WORK/page.json")"
      add changed --entry "$(jq -r '.change_report[0] // "Standard style set applied."' "$WORK/styles.json")"
      add decisions --entry "Style ownership: rebuild-with-standard-styles — the source uses no named styles, so the WordFlow standard set (#17) defines the look."
      add decisions --entry "Page setup: WordFlow default (A4 portrait, margins top/bottom 2.54cm, left/right 3.17cm; spec D6) applied because nothing specified otherwise."
      CURRENT="$WORK/styles.docx" ;;
    preserve-and-tidy)
      apply_page_setup "$src_abs" "$WORK/setup.docx"
      add changed --entry "$(jq -r '.change_report[0] // "Page setup applied."' "$WORK/page.json")"
      add changed --entry "Style ownership: preserved the source's own named style set; no rebuild applied."
      add decisions --entry "Style ownership: preserve-and-tidy — the source already uses named styles, so they are kept (spec D5.3)."
      add decisions --entry "Page setup: WordFlow default (A4 portrait, margins top/bottom 2.54cm, left/right 3.17cm; spec D6) applied because nothing specified otherwise."
      CURRENT="$WORK/setup.docx"
      # Tidy the preserved set: define any referenced-but-undefined style so no
      # reference dangles (spec D5.3, D7, D14).
      run_cap "tidy (#33)" "$TIDY"
      add decisions --entry "Tidy: repaired the source's own style set (spec D5.3) — see the tidy entries above; no content was changed." ;;
    use-template-styles)
      tpl_args=("--template" "$(abs "$TPL")")
      [[ -n "$REQ" ]] && tpl_args+=("--requirement" "$(abs "$REQ")")
      run_cap "template adoption (#27)" "$TEMPLATE" "${tpl_args[@]}"
      add decisions --entry "Style ownership: use-template-styles — the supplied template's look outranks the source's own styles (spec D5.3)." ;;
    *)
      echo "$TOOL: unknown style-ownership decision: $DECISION" >&2; exit 1 ;;
  esac
fi

[[ -f "$CURRENT" && -s "$CURRENT" ]] || { echo "$TOOL: no output produced" >&2; exit 1; }

# --- 4. compose the feature capabilities ------------------------------------
# A supplied formatting requirement that no path could apply is stated, never
# silently dropped (D11). Template adoption applies it when a template exists.
if [[ -n "$REQ" && "$STYLE_SET" != "template" ]]; then
  add unverified --entry "[formatting-requirement] A formatting requirement was supplied but no template path could apply its machine-applicable overrides; the WordFlow defaults were used. Requirement application without a template is not implemented in this slice."
fi

if [[ "$MODE" != "generate" && "$DECISION" != "preserve-and-tidy" ]]; then
  mapfile -t dangling < <(jq -r '.style.dangling_styles[]?' <<<"$plan")
  if [[ ${#dangling[@]} -gt 0 ]]; then
    add unverified --entry "[tidy-pending] The source references undefined style(s): ${dangling[*]}. The tidy step repairs the preserve path; on this path the reference is left as-is and reported."
  fi
fi

# headers/footers/page numbers (#19)
if [[ -n "$HDR$FTR$HDR_FIRST$FTR_FIRST$HDR_EVEN$FTR_EVEN$RESTART" || "$PAGE_NUMBER" == 1 ]]; then
  hargs=()
  [[ -n "$HDR" ]] && hargs+=("--header" "$HDR")
  [[ -n "$FTR" ]] && hargs+=("--footer" "$FTR")
  [[ "$PAGE_NUMBER" == 1 ]] && hargs+=("--page-number")
  [[ -n "$HDR_FIRST" ]] && hargs+=("--header-first" "$HDR_FIRST")
  [[ -n "$FTR_FIRST" ]] && hargs+=("--footer-first" "$FTR_FIRST")
  [[ -n "$HDR_EVEN" ]] && hargs+=("--header-even" "$HDR_EVEN")
  [[ -n "$FTR_EVEN" ]] && hargs+=("--footer-even" "$FTR_EVEN")
  [[ -n "$RESTART" ]] && hargs+=("--restart" "$RESTART")
  run_cap "headers/footers (#19)" "$HEADERS" "${hargs[@]}"
fi

# image (#20)
if [[ -n "$IMG" ]]; then
  iargs=("--image" "$(abs "$IMG")")
  [[ -n "$IMG_PARA" ]] && iargs+=("--para" "$IMG_PARA")
  [[ -n "$IMG_WIDTH" ]] && iargs+=("--width" "$IMG_WIDTH")
  [[ -n "$IMG_ALT" ]] && iargs+=("--alt" "$IMG_ALT")
  [[ "$IMG_ANCHOR" == 1 ]] && iargs+=("--anchor")
  run_cap "image (#20)" "$IMAGE" "${iargs[@]}"
fi

# table (#21)
if [[ -n "$TBL_DATA" ]]; then
  targs=("--data" "$TBL_DATA" "--col-widths" "$TBL_WIDTHS")
  [[ -n "$TBL_WIDTH" ]] && targs+=("--width" "$TBL_WIDTH")
  [[ "$TBL_HEADER" == 1 ]] && targs+=("--header-row")
  for m in ${MERGES[@]+"${MERGES[@]}"}; do targs+=("--merge" "$m"); done
  [[ -n "$NESTED_CELL" ]] && targs+=("--nested-cell" "$NESTED_CELL")
  [[ -n "$NESTED_DATA" ]] && targs+=("--nested-data" "$NESTED_DATA")
  [[ -n "$NESTED_COLS" ]] && targs+=("--nested-col-widths" "$NESTED_COLS")
  [[ -n "$NESTED_LAYOUT" ]] && targs+=("--nested-layout" "$NESTED_LAYOUT")
  [[ -n "$NESTED_BORDER" ]] && targs+=("--nested-border" "$NESTED_BORDER")
  run_cap "table (#21)" "$TABLE" "${targs[@]}"
fi

# caption (#22)
if [[ -n "$CAP_TEXT" ]]; then
  cargs=("--kind" "${CAP_KIND:-figure}" "--text" "$CAP_TEXT")
  [[ -n "$CAP_PARA" ]] && cargs+=("--para" "$CAP_PARA")
  run_cap "caption (#22)" "$CAPTION" "${cargs[@]}"
fi

# cross-reference (#23)
if [[ -n "$XREF_BM" ]]; then
  xargs=("--bookmark" "$XREF_BM")
  [[ -n "$XREF_KIND" ]] && xargs+=("--kind" "$XREF_KIND")
  [[ -n "$XREF_PARA" ]] && xargs+=("--para" "$XREF_PARA")
  run_cap "cross-reference (#23)" "$CROSSREF" "${xargs[@]}"
fi

# footnote (#25)
if [[ -n "$FN_TEXT" ]]; then
  fargs=("--text" "$FN_TEXT")
  [[ -n "$FN_PARA" ]] && fargs+=("--para" "$FN_PARA")
  run_cap "footnote (#25)" "$FOOTNOTE" "${fargs[@]}"
fi

# equation (#26)
if [[ -n "$EQ_FORMULA" ]]; then
  eargs=("--formula" "$EQ_FORMULA")
  [[ -n "$EQ_MODE" ]] && eargs+=("--mode" "$EQ_MODE")
  [[ -n "$EQ_PARA" ]] && eargs+=("--para" "$EQ_PARA")
  run_cap "equation (#26)" "$EQUATION" "${eargs[@]}"
fi

# table of contents (#24) last: it should see every heading.
if [[ "$TOC_ON" == 1 ]]; then
  tocargs=()
  [[ -n "$TOC_LEVELS" ]] && tocargs+=("--levels" "$TOC_LEVELS")
  [[ -n "$TOC_TITLE" ]] && tocargs+=("--title" "$TOC_TITLE")
  run_cap "table of contents (#24)" "$TOC" "${tocargs[@]}"
fi

# --- 5. deliver the composed output to the planned new path -----------------
cp -f "$CURRENT" "$FINAL"
[[ -f "$FINAL" && -s "$FINAL" ]] || { echo "$TOOL: no output produced at $FINAL" >&2; exit 1; }
[[ "$(abs "$FINAL")" != "$IN_ABS" ]] || { echo "$TOOL: output equals source; refusing" >&2; exit 1; }

mapfile -t intake_entries < <(jq -r '.change_report[]?' <<<"$plan")
for e in "${intake_entries[@]}"; do add changed --entry "$e"; done
if ((${#FEATURE_STEPS[@]} > 0)); then
  add changed --entry "Feature composition: applied ${#FEATURE_STEPS[@]} capability step(s) — ${FEATURE_STEPS[*]}."
fi

# --- 6. validate the output (schema gate) -----------------------------------
set +e
val_json="$($TMO officecli validate "$FINAL" --json 2>/dev/null)"
set -e
val_ok="$(jq -r '.success // false' <<<"$val_json" 2>/dev/null || echo false)"
[[ "$val_ok" == "true" ]] || { echo "$TOOL: officecli validate failed for $FINAL" >&2; exit 1; }

# --- 7. render preview of the FINAL output ----------------------------------
preview_json=""
if (( PREVIEW )); then
  preview_json="$("$RENDER_PREVIEW" "$FINAL" --out "$ART_DIR" --format "$PREVIEW_FMT" --report "$REPORT_JSON" --json)"
else
  preview_json="$("$RENDER_PREVIEW" "$FINAL" --disabled --report "$REPORT_JSON" --json)"
fi

# --- 8. risk-policy hooks over the delivered output -------------------------
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
wc_json="$($TMO officecli query "$FINAL" section --json 2>/dev/null || echo '{}')"
cols="$(jq -r '[.data.results[]? | select((.format.columns // 1) > 1)] | length' <<<"$wc_json" 2>/dev/null || echo 0)"
if [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )); then
  emit_risk --trigger columns --detail "a multi-column layout is present in $cols section(s)"
fi

# --- 9. QA checklist for the delivered output (D14) -------------------------
set +e
src_sha_after="$(sha_of "$IN_ABS")"
dangling_count="$(qa_dangling "$FINAL")"
field_json="$($TMO officecli query "$FINAL" field --json 2>/dev/null || echo '{}')"
field_count="$(jq -r '.data.matches // 0' <<<"$field_json" 2>/dev/null || echo 0)"
placeholder_count="$(jq -r '[.data.results[]? | select((.format.instruction // "") | test("PAGE|NUMPAGES|PAGEREF"; "i") | not) | select((.text // "") | test("«|»|update field|placeholder"; "i"))] | length' <<<"$field_json" 2>/dev/null || echo 0)"
set -e

if (( placeholder_count > 0 )); then
  emit_risk --trigger unverifiable-field --resolution state --detail "$placeholder_count field(s) carry a placeholder cached result in the delivered output"
fi

src_unchanged=0; [[ "$src_sha_after" == "$IN_SHA_BEFORE" && "$IN_SHA_BEFORE" == "$ENGINE_SHA" ]] && src_unchanged=1

# --- 10. render and validate the report -------------------------------------
"$CHANGE_REPORT" validate --report "$REPORT_JSON" >/dev/null
"$CHANGE_REPORT" render --report "$REPORT_JSON" --format markdown > "$REPORT_MD"

# --- 11. deliver ------------------------------------------------------------
restructure_json="$(jq -nc \
  --argjson requested "$(printf '%s\n' ${RESTRUCTURE[@]+"${RESTRUCTURE[@]}"} | jq -Rsc 'split("\n") | map(select(length>0))')" \
  --argjson confirmed "$(printf '%s\n' ${CONFIRM_RESTRUCTURE[@]+"${CONFIRM_RESTRUCTURE[@]}"} | jq -Rsc 'split("\n") | map(select(length>0))')" \
  '{requested: $requested, confirmed: $confirmed}')"
if (( JSON )); then
  jq -nc \
    --arg tool "$TOOL" \
    --arg mode "$MODE" \
    --arg source "$IN_ABS" \
    --arg output "$FINAL" \
    --arg decision "$DECISION" \
    --arg style_source "$STYLE_SOURCE" \
    --argjson restructure "$restructure_json" \
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
    '{status:"delivered", tool:$tool, mode:$mode, source:$source, output:$output, decision:$decision,
      style_source:$style_source, restructure:$restructure, collision:$collision,
      preview:$preview, qa:$qa, source_unchanged:$source_unchanged,
      artifacts:{output:$output, input:$input_copy, plan:$plan, report_json:$report_json, report_md:$report_md},
      report:$report}'
else
  cat <<EOF
$TOOL: delivered ($MODE)
  source        $IN_ABS  (unchanged)
  decision      $DECISION
  output        $FINAL
  report        $REPORT_JSON
                $REPORT_MD
  preview       $(jq -r '(.artifacts // []) | join("\n                ")' <<<"$preview_json")
  QA            dangling styles: $dangling_count | fields: $field_count | placeholders: $placeholder_count
EOF
fi
