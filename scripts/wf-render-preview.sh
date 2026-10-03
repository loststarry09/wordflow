#!/usr/bin/env bash
#
# WordFlow render preview (#29).
#
# Produce a visual preview of the *final delivered output* document (spec
# `docs/spec/v0.1.md` §D13). The preview exists so a person can inspect the
# result; it is **not** the QA checklist (§D14) and **not** a compatibility
# gate. Rendering is a read/export of the finished output, never a mutation --
# the output document is left byte-identical.
#
# Rendering is done once, here, for the whole project. By default a preview is
# produced for the `<output.docx>` passed in; `--disabled` suppresses it and
# records the omission in the change report through the shared contract
# (`scripts/wf-change-report.sh`), never by formatting a report here.
#
# Method: LibreOffice headless converts the final `.docx` to PDF, and (for PNG)
# poppler's `pdftoppm` rasterises every page. This covers the whole document,
# is page-accurate, and does not depend on OfficeCLI's screenshot grid or size
# cap. See `references/workflow/render-preview.md` for the rationale.
#
# Usage:
#   scripts/wf-render-preview.sh <output.docx> [options]
#
# Options:
#   --out <dir>       Directory for the preview artifact(s).
#                     Default: the directory containing <output.docx>.
#   --format <fmt>    png (default) or pdf.
#   --disabled        Do not render; require --report and note the omission.
#   --report <r>      Change report (JSON) to extend. Required with --disabled.
#   --json            Emit a JSON result object on stdout.
#   -h, --help        Show this help.
#
# Output on stdout (without --json): one artifact path per line, in page order;
# nothing when disabled. Diagnostics go to stderr.
#
# Exit codes: 0 = success; 1 = output missing or render/report failure;
#             2 = usage error or missing dependency.
#
set -euo pipefail

readonly TOOL="wf-render-preview.sh"
readonly DPI=96
readonly CODE_PREFIX='[D13-preview]'
readonly DEFAULT_TIMEOUT=120

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_TOOL="$SCRIPT_DIR/wf-change-report.sh"

usage() {
  cat <<'EOF'
Usage: wf-render-preview.sh <output.docx> [options]

Produce a visual preview of the final delivered output document (D13).

Options:
  --out <dir>      Directory for the preview artifact(s).
                   Default: the directory containing <output.docx>.
  --format <fmt>   png (default) or pdf.
  --disabled       Do not render; require --report and note the omission.
  --report <r>     Change report (JSON) to extend. Required with --disabled.
  --json           Emit a JSON result object on stdout.
  -h, --help       Show this help.

The preview is for inspection only: it is not the QA checklist (D14) and not a
compatibility gate. Rendering never modifies the output document.

Exit codes: 0 ok | 1 output missing / render or report failure | 2 usage.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die_op()    { echo "$TOOL: $*" >&2; exit 1; }

OUTPUT=''
OUT_DIR=''
FORMAT='png'
DISABLED=0
REPORT=''
JSON=0

while (($#)); do
  case "$1" in
    --out)      (($# >= 2)) || die_usage "--out requires a directory"; OUT_DIR="$2"; shift 2 ;;
    --format)   (($# >= 2)) || die_usage "--format requires a value"; FORMAT="$2"; shift 2 ;;
    --disabled) DISABLED=1; shift ;;
    --report)   (($# >= 2)) || die_usage "--report requires a path"; REPORT="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die_usage "unknown option: $1" ;;
    *)
      if [[ -n "$OUTPUT" ]]; then die_usage "unexpected argument: $1"; fi
      OUTPUT="$1"; shift ;;
  esac
done

[[ -n "$OUTPUT" ]] || die_usage "a final output document is required"
case "$FORMAT" in
  png|pdf) ;;
  *) die_usage "unknown format: '$FORMAT' (expected png or pdf)" ;;
esac
if ((DISABLED)); then
  [[ -n "$REPORT" ]] || die_usage "--disabled requires --report (the omission must be recorded)"
fi

command -v jq >/dev/null || die_usage "jq not found on PATH"

OUTPUT_ABS="$(readlink -f -- "$OUTPUT")"
[[ -f "$OUTPUT_ABS" && -s "$OUTPUT_ABS" ]] || die_op "output document not found or empty: $OUTPUT"

if [[ -n "$OUT_DIR" ]]; then
  DIR_TARGET="$OUT_DIR"
else
  DIR_TARGET="$(dirname -- "$OUTPUT_ABS")"
fi

# shellcheck source=scripts/lib/source-protection.sh
source "$SCRIPT_DIR/lib/source-protection.sh"
wf_guard_destination --report "$REPORT" "$OUTPUT_ABS"
wf_guard_destination --out "$DIR_TARGET" "$OUTPUT_ABS" "$REPORT"

stem="$(basename -- "$OUTPUT_ABS")"
stem="${stem%.*}"

# --- JSON helpers -----------------------------------------------------------
json_array() {
  if (($# == 0)); then printf '[]'; return; fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

report_json='null'
warnings_json='[]'
artifacts_json='[]'
pages_json='null'
method_json='null'
directory_json='null'

emit_json() {
  jq -n \
    --arg     output          "$OUTPUT_ABS" \
    --argjson directory       "$directory_json" \
    --arg     format          "$FORMAT" \
    --argjson disabled        "$([ "$DISABLED" -eq 1 ] && echo true || echo false)" \
    --argjson method          "$method_json" \
    --argjson dpi             "$DPI" \
    --argjson pages           "$pages_json" \
    --argjson artifacts       "$artifacts_json" \
    --argjson report          "$report_json" \
    --argjson report_updated  "$([ "$report_updated" -eq 1 ] && echo true || echo false)" \
    --argjson warnings        "$warnings_json" \
    '{output:$output, directory:$directory, format:$format, disabled:$disabled,
      method:$method, dpi:$dpi, pages:$pages, artifacts:$artifacts,
      report:$report, report_updated:$report_updated,
      compatibility_gate:false, warnings:$warnings}'
}

report_updated=0

# --- disabled: no artifact, note the omission -------------------------------
if ((DISABLED)); then
  [[ -f "$REPORT" ]] || die_op "report not found: $REPORT"
  if [[ -x "$REPORT_TOOL" ]]; then
    "$REPORT_TOOL" add --report "$REPORT" --area unverified \
      --entry "$CODE_PREFIX render preview disabled on request; the output was not visually inspected" \
      >/dev/null || die_op "failed to note the disabled preview in $REPORT"
  else
    die_op "change-report tool not found: $REPORT_TOOL"
  fi
  report_updated=1
  report_json="$(jq -n --arg r "$REPORT" '$r')"
  if ((JSON)); then emit_json; else echo "preview: disabled (noted in $REPORT)" >&2; fi
  exit 0
fi

# --- render: final .docx -> PDF (-> PNG) ------------------------------------
command -v soffice >/dev/null || die_usage "soffice (LibreOffice) not found on PATH"
if [[ "$FORMAT" == png ]]; then
  command -v pdftoppm >/dev/null || die_usage "pdftoppm (poppler-utils) not found on PATH"
fi

mkdir -p -- "$DIR_TARGET" || die_op "cannot create output directory: $DIR_TARGET"
OUT_DIR_ABS="$(cd -- "$DIR_TARGET" && pwd)"
directory_json="$(jq -n --arg d "$OUT_DIR_ABS" '$d')"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wf-render-preview.XXXXXX")"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

mkdir -p -- "$tmp/pdf" "$tmp/profile"

timeout "${WF_SOFFICE_TIMEOUT:-$DEFAULT_TIMEOUT}" soffice --headless --norestore --nolockcheck \
  -env:UserInstallation="file://$tmp/profile" \
  --convert-to pdf --outdir "$tmp/pdf" "$OUTPUT_ABS" >/dev/null 2>"$tmp/soffice.err" \
  || die_op "soffice conversion failed for $OUTPUT_ABS: $(tr '\n' ' ' <"$tmp/soffice.err")"

pdf="$tmp/pdf/$stem.pdf"
[[ -s "$pdf" ]] || die_op "soffice produced no PDF for $OUTPUT_ABS"

declare -a artifacts=()

if [[ "$FORMAT" == pdf ]]; then
  dest="$OUT_DIR_ABS/$stem-preview.pdf"
  wf_guard_destination "preview artifact" "$dest" "$OUTPUT_ABS" "$REPORT"
  mv -f -- "$pdf" "$dest" || die_op "failed to write $dest"
  artifacts=("$dest")
  method_json='"soffice"'
else
  # Clear stale pages from a previous, longer render so the artifact set is
  # exactly this document's pages.
  for frame in "$OUT_DIR_ABS/$stem-preview-"*.png; do
    wf_guard_destination "preview artifact" "$frame" "$OUTPUT_ABS" "$REPORT"
  done
  rm -f -- "$OUT_DIR_ABS/$stem-preview-"*.png
  prefix="$OUT_DIR_ABS/$stem-preview"
  timeout "${WF_SOFFICE_TIMEOUT:-$DEFAULT_TIMEOUT}" pdftoppm -png -r "$DPI" "$pdf" "$prefix" \
    >/dev/null 2>&1 || die_op "pdftoppm rasterisation failed for $OUTPUT_ABS"
  mapfile -t artifacts < <(find "$OUT_DIR_ABS" -maxdepth 1 -type f -name "$stem-preview-*.png" -print | LC_ALL=C sort)
  ((${#artifacts[@]})) || die_op "no PNG frames were produced for $OUTPUT_ABS"
  method_json='"soffice+pdftoppm"'
fi

artifacts_json="$(json_array "${artifacts[@]}")"

# Page count: exact for PNG; from pdfinfo for PDF when available.
if [[ "$FORMAT" == png ]]; then
  pages_json="${#artifacts[@]}"
elif command -v pdfinfo >/dev/null; then
  p="$(pdfinfo "${artifacts[0]}" 2>/dev/null | awk '/^Pages:/{print $2}')" || p=""
  if [[ -n "$p" ]]; then pages_json="$p"; fi
fi

if ((JSON)); then
  emit_json
else
  printf '%s\n' "${artifacts[@]}"
fi
