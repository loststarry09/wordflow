#!/usr/bin/env bash
#
# WordFlow standard styles and Simplified-Chinese typography (#17).
#
# Defines WordFlow's frozen standard style set (spec `docs/spec/v0.1.md` §D7)
# with the frozen Simplified-Chinese-first defaults (§D6) on a document, through
# OfficeCLI. It defines styles only — it never adds, edits, or restyles content.
# This is the implementation of the `rebuild-with-standard-styles` outcome of the
# style-ownership decision (#16).
#
# The style set (exactly this list; do not expand):
#
#   Normal / 正文            BodyNoIndent / 正文无缩进
#   Title / 标题             Heading 1..4 / 标题 1..4
#   Caption / 图注表注       Quote / 引用
#   ListParagraph / 列表段落  TOC 1..3
#   FootnoteText / FootnoteReference
#   Header / Footer          Hyperlink
#
# Frozen font strategy (spec §D6; confirmed by the CJK font research, #8):
# every style sets its fonts explicitly — `font.ea`, `font.latin`, and
# `font.hint=eastAsia` — and never inherits OfficeCLI's locale default
# (`等线`/DengXian) or the theme. Body is 宋体 (SimSun) + Times New Roman;
# headings/Title are 黑体 (SimHei) + Arial. The source is created with
# `--locale zh-CN` so docGrid/lang are Chinese, but those fonts are overridden.
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and only that new file is changed, through OfficeCLI. The byte copy is
# a file duplication, not a DOCX read or write; every DOCX operation still goes
# through OfficeCLI.
#
# Page geometry (spec §D6 page/margins) is a separate concern owned by
# scripts/wf-page-setup.sh (#18) and is not applied here.
#
# Usage:
#   scripts/wf-standard-styles.sh <source.docx> --out <output.docx> [--json]
#
# Exit codes: 0 = styles defined; 1 = OfficeCLI could not read/write a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: wf-standard-styles.sh <source.docx> --out <output.docx> [--json]

Define WordFlow's frozen standard style set (spec §D7) with the frozen
Simplified-Chinese-first typography defaults (spec §D6) on a document. Styles
only: no content is added or changed. The source is never modified; the result
is written to --out.

Options:
  --out <file>   New output document (required; must differ from the source).
  --json         Emit the report as JSON instead of text.
  -h, --help     Show this help.
EOF
}

SRC=""; OUT=""; JSON=0
while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
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
for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"
# shellcheck source=scripts/lib/source-protection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-protection.sh"
wf_guard_destination --out "$OUT" "$SRC"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# --- the frozen style set (spec §D6/§D7) -----------------------------------
readonly EA_BODY="SimSun"          # 宋体
readonly LATIN_BODY="Times New Roman"
readonly EA_HEAD="SimHei"          # 黑体
readonly LATIN_HEAD="Arial"
readonly HINT="eastAsia"

# Character-unit indents are Word's canonical form, but LibreOffice ignores
# `w:firstLineChars`/`w:leftChars`; write the em-equivalent absolute value too
# so both applications render the indent. 1 CJK char = 1 em = the font size, so
# 2 characters at the 12 pt body size are 24 pt.
readonly INDENT_2CHAR="24pt"
readonly INDENT_4CHAR="48pt"

# IDs and display names, in the frozen order.
readonly STYLE_IDS=(Normal BodyNoIndent Title Heading1 Heading2 Heading3 Heading4 \
  Caption Quote ListParagraph TOC1 TOC2 TOC3 FootnoteText FootnoteReference Header Footer Hyperlink)

# --- copy the bytes, then define styles through OfficeCLI -------------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

existing_styles="$($TMO officecli get "$out_abs" /styles --json)"
jq -e '.success == true' <<<"$existing_styles" >/dev/null || { echo "could not read existing styles" >&2; exit 1; }

add_style() { # add_style <styleId> <name> <type> <customStyle> <props...>
  local id="$1" name="$2" type="$3" custom="$4"; shift 4
  if jq -e --arg id "$id" \
      'any(.data.results[].children[]?; .type=="style" and .format.styleId==$id)' \
      <<<"$existing_styles" >/dev/null; then
    # Keep the style identity and its references; only update standard props.
    $TMO officecli set "$out_abs" "/styles/$id" --prop name="$name" "$@" >/dev/null
  else
    $TMO officecli add "$out_abs" /styles --type style \
      --prop styleId="$id" --prop name="$name" --prop type="$type" \
      --prop customStyle="$custom" "$@" >/dev/null
  fi
}

# Normal is the document's default style (`w:default`). `set` preserves that
# flag; if the source has no Normal, add it as the default.
if jq -e --arg id Normal \
    '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | index($id) != null' \
    <<<"$($TMO officecli get "$out_abs" /styles --json)" >/dev/null 2>&1; then
  $TMO officecli set "$out_abs" /styles/Normal --prop name="正文" \
    --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
    --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=justify \
    --prop firstLineChars=200 --prop firstLineIndent="$INDENT_2CHAR" \
    --prop spaceBefore=0pt --prop spaceAfter=0pt \
    --prop qFormat=true >/dev/null
else
  add_style Normal "正文" paragraph false --prop default=true \
    --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
    --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=justify \
    --prop firstLineChars=200 --prop firstLineIndent="$INDENT_2CHAR" \
    --prop spaceBefore=0pt --prop spaceAfter=0pt --prop qFormat=true
fi

# Body paragraphs that must not indent (spec §D6) keep the body look but drop
# the first-line indent.
add_style BodyNoIndent "正文无缩进" paragraph true \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=justify \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop spaceBefore=0pt --prop spaceAfter=0pt

# Title: 黑体 22 pt (二号), centred, no first-line indent.
add_style Title "标题" paragraph false \
  --prop font.ea="$EA_HEAD" --prop font.latin="$LATIN_HEAD" --prop font.hint="$HINT" \
  --prop size=22 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=center \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop spaceBefore=0pt --prop spaceAfter=18pt

# Headings 1-4: 黑体 16/14/13/12 pt, no first-line indent, space before/after,
# outline level 0-3 so the heading hierarchy drives the TOC.
add_style Heading1 "标题 1" paragraph false \
  --prop font.ea="$EA_HEAD" --prop font.latin="$LATIN_HEAD" --prop font.hint="$HINT" \
  --prop size=16 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt \
  --prop spaceBefore=18pt --prop spaceAfter=12pt \
  --prop outlineLvl=0 --prop keepNext=true
add_style Heading2 "标题 2" paragraph false \
  --prop font.ea="$EA_HEAD" --prop font.latin="$LATIN_HEAD" --prop font.hint="$HINT" \
  --prop size=14 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt \
  --prop spaceBefore=12pt --prop spaceAfter=6pt \
  --prop outlineLvl=1 --prop keepNext=true
add_style Heading3 "标题 3" paragraph false \
  --prop font.ea="$EA_HEAD" --prop font.latin="$LATIN_HEAD" --prop font.hint="$HINT" \
  --prop size=13 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt \
  --prop spaceBefore=12pt --prop spaceAfter=6pt \
  --prop outlineLvl=2 --prop keepNext=true
add_style Heading4 "标题 4" paragraph false \
  --prop font.ea="$EA_HEAD" --prop font.latin="$LATIN_HEAD" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt \
  --prop spaceBefore=6pt --prop spaceAfter=6pt \
  --prop outlineLvl=3 --prop keepNext=true

# Captions: 宋体 10.5 pt (五号), centred, no first-line indent.
add_style Caption "图注表注" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=10.5 --prop lineSpacing=1x --prop lineRule=auto --prop align=center \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop spaceBefore=6pt --prop spaceAfter=6pt

# Quote: body face, no first-line indent, indented block.
add_style Quote "引用" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop leftChars=200 --prop leftIndent="$INDENT_2CHAR" \
  --prop spaceBefore=6pt --prop spaceAfter=6pt

# ListParagraph: body face, no first-line indent, hanging list indent.
add_style ListParagraph "列表段落" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1.5x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop leftChars=200 --prop leftIndent="$INDENT_2CHAR" \
  --prop contextualSpacing=true

# TOC 1-3: body face, nested indent, single spacing.
add_style TOC1 "TOC 1" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt
add_style TOC2 "TOC 2" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop leftChars=200 --prop leftIndent="$INDENT_2CHAR"
add_style TOC3 "TOC 3" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=12 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt --prop leftChars=400 --prop leftIndent="$INDENT_4CHAR"

# Footnotes: 宋体 9 pt (小五), no first-line indent.
add_style FootnoteText "Footnote Text" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=9 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt

# Running header / footer: 宋体 9 pt (小五).
add_style Header "Header" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=9 --prop lineSpacing=1x --prop lineRule=auto --prop align=left \
  --prop firstLineChars=0 --prop firstLineIndent=0pt
add_style Footer "Footer" paragraph false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop size=9 --prop lineSpacing=1x --prop lineRule=auto --prop align=center \
  --prop firstLineChars=0 --prop firstLineIndent=0pt

# Character styles: explicit fonts, like every other style.
add_style Hyperlink "Hyperlink" character false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop color=#0563C1 --prop underline=single
add_style FootnoteReference "Footnote Reference" character false \
  --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
  --prop vertAlign=superscript

# --- verify what OfficeCLI now reports (the judgement WordFlow owns) --------
styles_json="$($TMO officecli get "$out_abs" /styles --json)"
if ! jq -e '.success == true' <<<"$styles_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read styles back from $OUT" >&2
  exit 1
fi

defined_json="$(jq -c \
  '[.data.results[].children[]? | select(.type=="style") | {style_id: .format.styleId, name: .format.name, type: .format.type, default: ((.format.default // "false") == "true")}]' \
  <<<"$styles_json")"
defined_ids="$(jq -r '.[].style_id' <<<"$defined_json" | sort)"
EXPECTED_IDS="$(printf '%s\n' "${STYLE_IDS[@]}" | sort)"
readonly EXPECTED_IDS

missing="$(comm -23 <(printf '%s\n' "$EXPECTED_IDS") <(printf '%s\n' "$defined_ids"))"
if [[ -n "$missing" ]]; then
  echo "OfficeCLI did not define these standard styles: $missing" >&2
  exit 1
fi

# Every standard style must set its fonts explicitly; read each one back and
# confirm both the East-Asian and Latin slots (a style that inherited 等线 from
# docDefaults would surface dot-fontless or as 等线).
font_fail=""
for id in "${STYLE_IDS[@]}"; do
  sj="$($TMO officecli get "$out_abs" "/styles/$id" --json)"
  ea="$(jq -r '.data.results[0].format["font.ea"] // ""' <<<"$sj")"
  latin="$(jq -r '.data.results[0].format["font.ascii"] // ""' <<<"$sj")"
  if [[ -z "$ea" || "$ea" == "等线" || -z "$latin" ]]; then
    font_fail+="$id (ea='$ea' latin='$latin') "
  fi
done
if [[ -n "$font_fail" ]]; then
  echo "standard styles with missing or docDefaults CJK font: $font_fail" >&2
  exit 1
fi

# `font.hint` is write-only (Get does not surface it); confirm it on the raw
# styles part — one eastAsia hint per standard style.
hints="$($TMO officecli raw "$out_abs" /styles 2>/dev/null | grep -o 'w:hint="eastAsia"' | wc -l | tr -d ' ')"
if (( hints < ${#STYLE_IDS[@]} )); then
  echo "standard styles missing the eastAsia hint ($hints of ${#STYLE_IDS[@]})" >&2
  exit 1
fi

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- report -----------------------------------------------------------------
report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --argjson styles "$defined_json" \
  --argjson source_unchanged "$source_unchanged" '
  { source: $source,
    output: $output,
    style_set: ($styles | map({style_id, name, type, default})),
    styles_defined: ($styles | length),
    default_style: ($styles | map(select(.default)) | .[0].style_id // "Normal"),
    font_defaults: {
      body_east_asia: "SimSun", body_latin: "Times New Roman",
      heading_east_asia: "SimHei", heading_latin: "Arial",
      hint: "eastAsia"
    },
    source_unchanged: $source_unchanged,
    change_report: [
      "Standard styles: defined " + (($styles | length) | tostring)
      + " style(s) — " + ($styles | map(.style_id) | join(", "))
      + " — with explicit fonts (body SimSun/Times New Roman, headings SimHei/Arial, hint eastAsia);"
      + " Simplified-Chinese body default (宋体 12pt, 1.5 line spacing, 2-character first-line indent, justified)."
    ] }
')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow standard styles",
  "  source:         " + .source,
  "  output:         " + .output,
  "  default style:  " + .default_style,
  "  styles defined: " + (.styles_defined | tostring),
  "  fonts:          body " + .font_defaults.body_east_asia + " / " + .font_defaults.body_latin
                     + "; headings " + .font_defaults.heading_east_asia + " / " + .font_defaults.heading_latin
                     + "; hint " + .font_defaults.hint,
  "  styles:         " + (.style_set | map(.style_id) | join(", ")),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
