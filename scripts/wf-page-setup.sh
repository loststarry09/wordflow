#!/usr/bin/env bash
#
# WordFlow page-setup primitive (#18).
#
# Applies a document's page setup through OfficeCLI: page size, orientation and
# the four page margins. The defaults are the D6 WordFlow defaults
# (spec `docs/spec/v0.1.md` §D6):
#
#   Page       A4, portrait
#   Margins    top/bottom 2.54 cm, left/right 3.17 cm
#
# Every setting may be overridden by an explicit input, which stands in for a
# formatting requirement (spec §D2 precedence: formatting requirement > template >
# defaults). The source document is never modified (ADR-0003): the operation
# copies the source bytes to --out and changes only that new file, through
# OfficeCLI. The byte copy is a file duplication, not a DOCX read or write; every
# DOCX operation still goes through OfficeCLI.
#
# Usage:
#   scripts/wf-page-setup.sh <source.docx> --out <output.docx> [options]
#
# Exit codes: 0 = applied; 1 = OfficeCLI could not read/write a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: wf-page-setup.sh <source.docx> --out <output.docx> [options]

Apply WordFlow default page setup (spec §D6: A4 portrait, margins top/bottom
2.54 cm and left/right 3.17 cm) to every section of a document, overridable by
explicit inputs. The source is never modified; the result is written to --out.

Options:
  --out <file>            New output document (required; must differ from source).
  --page-size <name>      A4 | A3 | A5 | Letter | Legal          (default A4)
  --page-width <length>   Custom page width, e.g. 21cm (requires --page-height).
  --page-height <length>  Custom page height, e.g. 29.7cm.
  --orientation <dir>     portrait | landscape                  (default portrait)
  --margin-top <length>   Top margin                            (default 2.54cm)
  --margin-bottom <len>   Bottom margin                         (default 2.54cm)
  --margin-left <length>  Left margin                           (default 3.17cm)
  --margin-right <length> Right margin                          (default 3.17cm)
  --section <all|N>       Apply to every section, or only /section[N] (default all)
  --json                  Emit the report as JSON instead of text.
  -h, --help              Show this help.

Lengths accept cm, in or pt (e.g. 2.54cm, 1in, 72pt), or a bare number in cm.
EOF
}

SRC=""; OUT=""
PAGE_SIZE="A4"; PAGE_SIZE_SET=0
WIDTH=""; HEIGHT=""
ORIENT="portrait"; ORIENT_SET=0
MT="2.54cm"; MB="2.54cm"; ML="3.17cm"; MR="3.17cm"
MT_SET=0; MB_SET=0; ML_SET=0; MR_SET=0
SECTION="all"
JSON=0

while (($#)); do
  case "$1" in
    --out)          (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --page-size)    (($# >= 2)) || { echo "--page-size requires a value" >&2; exit 2; }; PAGE_SIZE="$2"; PAGE_SIZE_SET=1; shift 2 ;;
    --page-width)   (($# >= 2)) || { echo "--page-width requires a value" >&2; exit 2; }; WIDTH="$2"; shift 2 ;;
    --page-height)  (($# >= 2)) || { echo "--page-height requires a value" >&2; exit 2; }; HEIGHT="$2"; shift 2 ;;
    --orientation)  (($# >= 2)) || { echo "--orientation requires a value" >&2; exit 2; }; ORIENT="$2"; ORIENT_SET=1; shift 2 ;;
    --margin-top)   (($# >= 2)) || { echo "--margin-top requires a value" >&2; exit 2; }; MT="$2"; MT_SET=1; shift 2 ;;
    --margin-bottom)(($# >= 2)) || { echo "--margin-bottom requires a value" >&2; exit 2; }; MB="$2"; MB_SET=1; shift 2 ;;
    --margin-left)  (($# >= 2)) || { echo "--margin-left requires a value" >&2; exit 2; }; ML="$2"; ML_SET=1; shift 2 ;;
    --margin-right) (($# >= 2)) || { echo "--margin-right requires a value" >&2; exit 2; }; MR="$2"; MR_SET=1; shift 2 ;;
    --section)      (($# >= 2)) || { echo "--section requires a value" >&2; exit 2; }; SECTION="$2"; shift 2 ;;
    --json)         JSON=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)              [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq sha256sum cp; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# --- validate inputs (the judgement WordFlow owns) -------------------------
len_re='^[0-9]+([.][0-9]+)?(cm|in|pt)?$'
for pair in "margin-top:$MT" "margin-bottom:$MB" "margin-left:$ML" "margin-right:$MR" \
            "page-width:$WIDTH" "page-height:$HEIGHT"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [[ -n "$val" ]] || continue
  [[ "$val" =~ $len_re ]] || { echo "invalid length for --$name: $val" >&2; exit 2; }
done

[[ "$ORIENT" == "portrait" || "$ORIENT" == "landscape" ]] || { echo "invalid --orientation: $ORIENT (portrait|landscape)" >&2; exit 2; }

if [[ -n "$WIDTH" || -n "$HEIGHT" ]]; then
  [[ -n "$WIDTH" && -n "$HEIGHT" ]] || { echo "custom size needs both --page-width and --page-height" >&2; exit 2; }
  [[ "$PAGE_SIZE_SET" == "0" ]] || { echo "--page-size and --page-width/--page-height are mutually exclusive" >&2; exit 2; }
  SIZE_LABEL="custom"
  eff_w="$WIDTH"; eff_h="$HEIGHT"
else
  case "$PAGE_SIZE" in
    A4)     pw=21;    ph=29.7 ;;
    A3)     pw=29.7;  ph=42 ;;
    A5)     pw=14.8;  ph=21 ;;
    Letter) pw=21.59; ph=27.94 ;;
    Legal)  pw=21.59; ph=35.56 ;;
    *) echo "unknown --page-size: $PAGE_SIZE (A4|A3|A5|Letter|Legal)" >&2; exit 2 ;;
  esac
  SIZE_LABEL="$PAGE_SIZE"
  if [[ "$ORIENT" == "landscape" ]]; then
    eff_w="${ph}cm"; eff_h="${pw}cm"
  else
    eff_w="${pw}cm"; eff_h="${ph}cm"
  fi
fi

# --- copy the bytes, then apply through OfficeCLI --------------------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

sections_json="$($TMO officecli query "$out_abs" section --json)"
if ! jq -e '.success == true' <<<"$sections_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read sections from $SRC" >&2
  exit 1
fi

mapfile -t all_sections < <(jq -r '.data.results[].path' <<<"$sections_json")
((${#all_sections[@]} > 0)) || { echo "no sections found in $SRC" >&2; exit 1; }

declare -a targets=()
if [[ "$SECTION" == "all" ]]; then
  targets=("${all_sections[@]}")
else
  [[ "$SECTION" =~ ^[0-9]+$ ]] || { echo "invalid --section: $SECTION (all|N)" >&2; exit 2; }
  (("$SECTION" >= 1 && "$SECTION" <= ${#all_sections[@]})) || { echo "--section $SECTION out of range (1..${#all_sections[@]})" >&2; exit 2; }
  targets=("/section[$SECTION]")
fi

for p in "${targets[@]}"; do
  $TMO officecli set "$out_abs" "$p" \
    --prop pageWidth="$eff_w"   --prop pageHeight="$eff_h" \
    --prop orientation="$ORIENT" \
    --prop marginTop="$MT"      --prop marginBottom="$MB" \
    --prop marginLeft="$ML"     --prop marginRight="$MR" >/dev/null
done

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# confirm what OfficeCLI now reports
final_json="$($TMO officecli query "$out_abs" section --json)"
if ! jq -e '.success == true' <<<"$final_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read back page setup from $OUT" >&2
  exit 1
fi

overrides="$(jq -nc \
  --argjson size "$PAGE_SIZE_SET" --argjson orient "$ORIENT_SET" \
  --argjson mt "$MT_SET" --argjson mb "$MB_SET" --argjson ml "$ML_SET" --argjson mr "$MR_SET" \
  --arg width "$WIDTH" --arg height "$HEIGHT" '
  [ (if $width != "" then "page size (custom)" elif $size == 1 then "page size" else empty end),
    (if $orient == 1 then "orientation" else empty end),
    (if $mt == 1 then "margin-top" else empty end),
    (if $mb == 1 then "margin-bottom" else empty end),
    (if $ml == 1 then "margin-left" else empty end),
    (if $mr == 1 then "margin-right" else empty end) ]
')"

targets_json="$(printf '%s\n' "${targets[@]}" | jq -R . | jq -sc .)"

report="$(jq -nc \
  --argjson final "$final_json" \
  --arg source "$SRC" --arg output "$OUT" \
  --arg size_label "$SIZE_LABEL" --arg width "$eff_w" --arg height "$eff_h" --arg orient "$ORIENT" \
  --arg mt "$MT" --arg mb "$MB" --arg ml "$ML" --arg mr "$MR" \
  --argjson targets "$targets_json" --argjson overrides "$overrides" \
  --argjson source_unchanged "$source_unchanged" '
  ($final.data.results | map({path, format})) as $sections
  | { source: $source,
      output: $output,
      page_setup: {
        page_size: $size_label,
        page_width: $width,
        page_height: $height,
        orientation: $orient,
        margin_top: $mt,
        margin_bottom: $mb,
        margin_left: $ml,
        margin_right: $mr
      },
      sections_applied: $targets,
      sections: $sections,
      overrides: $overrides,
      source_unchanged: $source_unchanged,
      change_report: (
        [ "Page setup: " + $size_label + " " + $orient
          + ", margins top/bottom " + $mt + " / " + $mb
          + ", left/right " + $ml + " / " + $mr
          + " applied to " + (($targets | length) | tostring) + " section(s): "
          + ($targets | join(", "))
          + (if ($overrides | length) > 0
             then " (overrides from explicit input: " + ($overrides | join(", ")) + ")"
             else " (WordFlow default, spec §D6)" end) ]
      ) }
')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow page setup",
  "  source:    " + .source,
  "  output:    " + .output,
  "  page:      " + .page_setup.page_size + " " + .page_setup.orientation
                 + " (" + .page_setup.page_width + " x " + .page_setup.page_height + ")",
  "  margins:   top " + .page_setup.margin_top + " / bottom " + .page_setup.margin_bottom
                 + " / left " + .page_setup.margin_left + " / right " + .page_setup.margin_right,
  "  sections:  " + (.sections_applied | join(", ")),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
