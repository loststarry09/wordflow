#!/usr/bin/env bash
#
# WordFlow image placement (#20).
#
# Places one image in the text flow of a document through OfficeCLI.
#
# Inline images are FULLY SUPPORTED (spec `docs/spec/v0.1.md` §D8, §D9): they sit
# in the text flow and render faithfully in Word, WPS Writer, and LibreOffice
# Writer. A floating (anchored, text-wrapped) image is LIMITED: LibreOffice
# renders it left-aligned and in flow rather than floating, so a request for
# `--anchor` is DOWNGRADED to the portable placement (a centred inline image)
# and the downgrade is recorded through the shared risk policy (#30, trigger
# `preferred-unavailable` with `fallback=exists`) in the report's `downgrades`
# area — never silently (spec §D11).
#
# The image width is constrained to the text column: the column is the section's
# page width minus its left and right margins, and a requested width wider than
# the column is clamped to it. A clamp is reported; a width over the column
# would overflow onto the page margin.
#
# Source protection (ADR-0003): the source bytes are copied to --out and every
# DOCX read/write happens on --out through OfficeCLI. The byte copy is a file
# duplication, not a DOCX read or write; the source is never modified.
#
# Usage:
#   scripts/wf-image.sh <source.docx> --image <img.png> --out <output.docx> \
#     [--para <path>] [--width <w>] [--alt <text>] [--anchor] \
#     [--report <report.json>] [--json]
#
# Exit codes: 0 = image placed; 1 = OfficeCLI could not read/write a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK_POLICY="$SCRIPT_DIR/wf-risk-policy.sh"

usage() {
  cat <<'EOF'
Usage: wf-image.sh <source.docx> --image <img.png> --out <output.docx> [options]

Place one image in the text flow of a document. Inline placement is fully
supported. A requested floating (anchored) image is downgraded to a centred
inline image and the downgrade is reported. The width is clamped to the text
column when it would overflow. The source is never modified; the result is
written to --out.

Arguments:
  --image <file>      The image to place (required; PNG/JPEG recommended).
  --out <file>        New output document (required; must differ from source).

Options:
  --para <path>       Paragraph to place the image in (default /body/p[1]).
  --width <length>    Image width, e.g. 3cm, 1.5in, 72pt (default 3cm).
  --alt <text>        Alternative text for accessibility.
  --anchor            Request a floating (anchored, top-and-bottom) image.
                      Downgraded to a centred inline image; reported.
  --report <file>     Change report to create or extend (spec §D12).
  --json              Emit the report as JSON instead of text.
  -h, --help          Show this help.

Lengths accept cm, in or pt (e.g. 3cm, 1.5in, 72pt), or a bare number in cm.
EOF
}

SRC=""; OUT=""; IMAGE=""; PARA=""; WIDTH=""; ALT=""
ANCHOR=0; WIDTH_SET=0; REPORT=""; JSON=0

while (($#)); do
  case "$1" in
    --image)   (($# >= 2)) || { echo "--image requires a file argument" >&2; exit 2; }; IMAGE="$2"; shift 2 ;;
    --out)     (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --para)    (($# >= 2)) || { echo "--para requires a value" >&2; exit 2; }; PARA="$2"; shift 2 ;;
    --width)   (($# >= 2)) || { echo "--width requires a value" >&2; exit 2; }; WIDTH="$2"; WIDTH_SET=1; shift 2 ;;
    --alt)     (($# >= 2)) || { echo "--alt requires a value" >&2; exit 2; }; ALT="$2"; shift 2 ;;
    --anchor)  ANCHOR=1; shift ;;
    --report)  (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)         [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]]   || { usage >&2; exit 2; }
[[ -n "$OUT" ]]   || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -n "$IMAGE" ]] || { echo "--image is required" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]]   || { echo "source not found: $SRC" >&2; exit 2; }
[[ -f "$IMAGE" ]] || { echo "image not found: $IMAGE" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"
img_abs="$(abs "$IMAGE")"
[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# --- the width decision (the judgement WordFlow owns) -----------------------
readonly DEFAULT_WIDTH="3cm"
if (( WIDTH_SET == 0 )); then WIDTH="$DEFAULT_WIDTH"; fi
len_re='^[0-9]+([.][0-9]+)?(cm|in|pt)?$'
[[ "$WIDTH" =~ $len_re ]] || { echo "invalid --width: $WIDTH (cm|in|pt)" >&2; exit 2; }

# len_cm <length> -> centimetres (cm|in|pt, or a bare number as cm)
len_cm() {
  awk -v v="$1" 'BEGIN {
    n = v
    if (n ~ /cm$/)      { sub(/cm$/, "", n); printf "%.4f\n", n + 0 }
    else if (n ~ /in$/) { sub(/in$/, "", n); printf "%.4f\n", (n + 0) * 2.54 }
    else if (n ~ /pt$/) { sub(/pt$/, "", n); printf "%.4f\n", (n + 0) / 72 * 2.54 }
    else                { printf "%.4f\n", n + 0 }
  }'
}

# --- copy the bytes, then place the image through OfficeCLI -----------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

cleanup() {
  timeout 60 officecli close "$src_abs" >/dev/null 2>&1 || true
  timeout 60 officecli close "$out_abs" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

timeout 60 officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

# Target paragraph: an explicit --para must exist; the default /body/p[1] is
# created (empty) when the document has no paragraph yet.
PARA="${PARA:-/body/p[1]}"
para_json="$(timeout 60 officecli get "$out_abs" "$PARA" --json 2>/dev/null || true)"
para_ok="$(jq -r '(.success // false) and (.data.results[0].type // "") == "paragraph"' <<<"${para_json:-{}}" 2>/dev/null || echo false)"
if [[ "$para_ok" != "true" ]]; then
  if [[ "$PARA" == "/body/p[1]" ]]; then
    timeout 60 officecli add "$out_abs" /body --type paragraph >/dev/null
    para_json="$(timeout 60 officecli get "$out_abs" "$PARA" --json)"
  else
    echo "target paragraph not found: $PARA" >&2
    exit 2
  fi
fi
target_para_id="$(jq -r '.data.results[0].format.paraId // ""' <<<"$para_json")"

# Text column = page width minus left/right margins, from the section model.
sections_json="$(timeout 60 officecli query "$out_abs" section --json)"
if ! jq -e '.success == true and (.data.results | length) > 0' <<<"$sections_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read sections from $OUT" >&2
  exit 1
fi
page_w="$(jq -r '.data.results[0].format.pageWidth // ""' <<<"$sections_json")"
ml="$(jq -r '.data.results[0].format.marginLeft // ""' <<<"$sections_json")"
mr="$(jq -r '.data.results[0].format.marginRight // ""' <<<"$sections_json")"
page_w_cm="$(len_cm "$page_w")"
ml_cm="$(len_cm "$ml")"
mr_cm="$(len_cm "$mr")"
column_cm="$(awk -v w="$page_w_cm" -v l="$ml_cm" -v r="$mr_cm" 'BEGIN { printf "%.4f\n", w - l - r }')"

req_cm="$(len_cm "$WIDTH")"
norm_width="$WIDTH"
[[ "$norm_width" =~ ^[0-9]+([.][0-9]+)?$ ]] && norm_width="${norm_width}cm"
applied_width="$norm_width"
applied_cm="$req_cm"
clamped=false
if awk -v r="$req_cm" -v c="$column_cm" 'BEGIN { exit !(r > c) }'; then
  clamped=true
  applied_cm="$column_cm"
  applied_width="${column_cm}cm"
fi

picture_args=(--type picture --prop "src=$img_abs" --prop "width=$applied_width")
[[ -n "$ALT" ]] && picture_args+=(--prop "alt=$ALT")
if ! timeout 60 officecli add "$out_abs" "$PARA" "${picture_args[@]}" >/dev/null; then
  echo "OfficeCLI could not place the image in $OUT" >&2
  exit 1
fi

# A requested anchored image is downgraded to the portable centred inline form.
if (( ANCHOR == 1 )); then
  timeout 60 officecli set "$out_abs" "$PARA" --prop align=center >/dev/null
fi

# --- read the external behaviour back through OfficeCLI ---------------------
pics_json="$(timeout 60 officecli query "$out_abs" picture --json)"
if ! jq -e '.success == true' <<<"$pics_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read pictures back from $OUT" >&2
  exit 1
fi
anchored_present="$(jq -r '[.data.results[]? | select((.format.anchor // false) == true or ((.format.wrap // "inline") != "inline"))] | length' <<<"$pics_json")"
our_picture="$(jq -c --arg pid "$target_para_id" \
  '[.data.results[]? | select($pid != "" and ((.path // "") | contains("paraId=" + $pid)))] | last // {}' \
  <<<"$pics_json")"
picture_json="$(jq -c '{path:(.path // ""), width:(.format.width // ""), height:(.format.height // ""),
  alt:(.format.alt // ""), wrap:(.format.wrap // "inline"), anchor:(.format.anchor // false),
  relId:(.format.relId // "")}' <<<"$our_picture")"
readback_width="$(jq -r '.width // ""' <<<"$picture_json")"
[[ -n "$readback_width" ]] && applied_width="$readback_width"

placement="inline"
(( ANCHOR == 1 )) && placement="inline-downgraded"

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- assemble the change-report entries -------------------------------------
changed_entries=(); decisions_entries=(); warnings_entries=(); downgrades_entries=(); unverified_entries=()
add_entry() {
  local area="$1" e="$2"
  case "$area" in
    changed)    changed_entries+=("$e") ;;
    decisions)  decisions_entries+=("$e") ;;
    warnings)   warnings_entries+=("$e") ;;
    downgrades) downgrades_entries+=("$e") ;;
    unverified) unverified_entries+=("$e") ;;
  esac
}

add_entry changed "Image: placed an inline image $(basename "$IMAGE") in $PARA at width $applied_width."

if (( WIDTH_SET == 0 )); then
  add_entry decisions "Image width: WordFlow default $DEFAULT_WIDTH applied because none was specified (spec §D8)."
fi

if [[ "$clamped" == "true" ]]; then
  add_entry changed "Image width: requested $WIDTH exceeds the text column ${column_cm}cm; clamped to ${column_cm}cm (a width over the column would overflow onto the page margin)."
fi

risk_detail=""
if (( ANCHOR == 1 )); then
  add_entry changed "Image placement: requested a floating (anchored) image; downgraded to a centred inline image."
  risk_detail="anchored (floating) image requested; downgraded to a centred inline image (LibreOffice Writer renders anchored images in flow, spec §D8/D9)"
  risk_json="$(timeout 60 "$RISK_POLICY" decide --trigger preferred-unavailable --fallback exists --detail "$risk_detail" --json)"
  downgrades_entries+=("$(jq -r '.entry' <<<"$risk_json")")
fi

if [[ -n "$REPORT" ]]; then
  [[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
  [[ -x "$RISK_POLICY" ]]   || { echo "risk-policy tool not executable: $RISK_POLICY" >&2; exit 2; }
  if [[ ! -f "$REPORT" ]]; then
    timeout 60 "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$REPORT" >/dev/null
  fi
  for e in ${changed_entries[@]+"${changed_entries[@]}"}; do
    timeout 60 "$CHANGE_REPORT" add --report "$REPORT" --area changed --entry "$e" >/dev/null
  done
  for e in ${decisions_entries[@]+"${decisions_entries[@]}"}; do
    timeout 60 "$CHANGE_REPORT" add --report "$REPORT" --area decisions --entry "$e" >/dev/null
  done
  if (( ANCHOR == 1 )); then
    timeout 60 "$RISK_POLICY" emit --report "$REPORT" --trigger preferred-unavailable --fallback exists --detail "$risk_detail" >/dev/null
  fi
fi

json_array() { if (($# == 0)); then printf '[]'; else jq -nc --args '$ARGS.positional' "$@"; fi; }
changed_json="$(json_array ${changed_entries[@]+"${changed_entries[@]}"})"
decisions_json="$(json_array ${decisions_entries[@]+"${decisions_entries[@]}"})"
warnings_json="$(json_array ${warnings_entries[@]+"${warnings_entries[@]}"})"
downgrades_json="$(json_array ${downgrades_entries[@]+"${downgrades_entries[@]}"})"
unverified_json="$(json_array ${unverified_entries[@]+"${unverified_entries[@]}"})"

report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" --arg image "$IMAGE" --arg target "$PARA" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson requested "$req_cm" --argjson applied "$applied_cm" --argjson column "$column_cm" \
  --argjson clamped "$clamped" \
  --argjson anchor_requested "$([[ $ANCHOR == 1 ]] && echo true || echo false)" \
  --arg placement "$placement" --argjson anchored_present "$anchored_present" \
  --argjson picture "$picture_json" \
  --argjson changed "$changed_json" --argjson decisions "$decisions_json" \
  --argjson warnings "$warnings_json" --argjson downgrades "$downgrades_json" \
  --argjson unverified "$unverified_json" --arg report_path "$REPORT" '
  { source:$source, output:$output, source_unchanged:$source_unchanged,
    image:{ path:$image, target_paragraph:$target,
            requested_width_cm:$requested, applied_width_cm:$applied,
            text_column_cm:$column, clamped:$clamped },
    placement:$placement, anchored_requested:$anchor_requested,
    anchored_present:$anchored_present,
    picture:$picture,
    changed:$changed, decisions:$decisions, warnings:$warnings,
    downgrades:$downgrades, unverified:$unverified,
    change_report:($changed + $decisions + $warnings + $downgrades + $unverified),
    report:(if $report_path != "" then $report_path else null end) }
')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow image placement",
  "  source:      " + .source + "  (unchanged: " + (.source_unchanged | tostring) + ")",
  "  output:      " + .output,
  "  image:       " + .image.path,
  "  placed in:   " + .image.target_paragraph,
  "  placement:   " + .placement,
  "  width:       " + (.image.applied_width_cm | tostring) + "cm (requested "
                     + (.image.requested_width_cm | tostring) + "cm, column "
                     + (.image.text_column_cm | tostring) + "cm"
                     + (if .image.clamped then ", clamped" else "" end) + ")",
  "  picture:     " + (.picture.width // "?") + " x " + (.picture.height // "?")
                     + " wrap=" + (.picture.wrap // "inline"),
  "  anchored:    " + (.anchored_present | tostring) + " in output",
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
