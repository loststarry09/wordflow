#!/usr/bin/env bash
#
# WordFlow tidy primitive (#33, spec §D5.3/§D7).
#
# Repairs a document's own style set without touching content: every referenced
# style must resolve to a definition (spec §D7, §D14 "no dangling style"). The
# style-ownership decision (#16) calls the `preserve-and-tidy` outcome when the
# document already uses named styles; this is the "tidy" half of that outcome.
#
# For each style the document references but does not define, tidy adds a
# definition with that exact name — a paragraph style based on the document's
# default style, with explicit East-Asian/Latin fonts (SimSun / Times New Roman,
# hint=eastAsia) so the repair never inherits OfficeCLI's unsafe locale default
# (`等线`/DengXian, no CJK coverage on Linux). Content, existing definitions, and
# unused styles are left intact: tidy is non-destructive.
#
# Scope note: style-ownership (#16) and `view stats` classify **paragraph**
# styles only, so every repair is a paragraph style. Character/table style
# classification is not part of v0.1 (see references/core/style-ownership.md).
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and every DOCX read/write is performed on --out through OfficeCLI.
#
# Usage:
#   scripts/wf-tidy.sh <source.docx> --out <output.docx> [--report <file>] [--json]
#
# Exit codes: 0 = tidied; 1 = OfficeCLI could not read/write a document, or a
#             dangling reference could not be repaired; 2 = bad usage.
#
set -euo pipefail

readonly TOOL="wf-tidy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"

usage() {
  cat <<'EOF'
Usage: wf-tidy.sh <source.docx> --out <output.docx> [options]

Repair a document's style set without touching content: define every style the
document references but does not define, so no style reference dangles (spec
D5.3/D7/D14). Existing definitions and unused styles are left intact.

Options:
  --out <file>    New output document (required; must differ from the source).
  --report <file> Write the change report (#28) to this path. Optional.
  --json          Emit the report as JSON instead of text.
  -h, --help      Show this help.
EOF
}

SRC=""; OUT=""; REPORT_OUT=""; JSON=0
while (($#)); do
  case "$1" in
    --out)     (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --report)  (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT_OUT="$2"; shift 2 ;;
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
[[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"
# shellcheck source=scripts/lib/source-protection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-protection.sh"
wf_guard_destination --out "$OUT" "$SRC"
wf_guard_destination --report "$REPORT_OUT" "$SRC" "$OUT"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# The frozen body fonts (spec §D6): a repaired style must not inherit 等线.
readonly EA_BODY="SimSun"
readonly LATIN_BODY="Times New Roman"
readonly HINT="eastAsia"

create_report() { "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$1" >/dev/null; }
report_add()    { "$CHANGE_REPORT" add --report "$1" --area "$2" --entry "$3" >/dev/null; }

# dangling_names <docx> -> one referenced-but-undefined style name per line,
# original case, in the order OfficeCLI reports. A reference is satisfied by a
# definition's styleId OR display name, case-insensitively (matches the pipeline
# D14 check; #16 matches names only and false-positives on translated output).
dangling_names() {
  local doc="$1" styles stats defined
  styles="$($TMO officecli get "$doc" /styles --json 2>/dev/null || echo '{}')"
  stats="$($TMO officecli view "$doc" stats --json 2>/dev/null || echo '{}')"
  defined="$(jq -c '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | map(ascii_downcase)' <<<"$styles" 2>/dev/null || echo '[]')"
  jq -r --argjson defined "$defined" \
    '.data.styleDistribution // {} | keys[] | select((ascii_downcase) as $k | ($defined | index($k)) | not)' \
    <<<"$stats" 2>/dev/null || true
}

# sanitize_id <name> -> a styleId with no spaces/punctuation; the display name
# keeps the exact referenced string, which is what resolves the reference.
sanitize_id() { printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_-]+//g'; }

# --- copy the bytes, then repair through OfficeCLI --------------------------
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

styles_json="$($TMO officecli get "$out_abs" /styles --json 2>/dev/null)"
jq -e '.success == true' >/dev/null 2>&1 <<<"$styles_json" \
  || { echo "OfficeCLI could not read styles from $SRC" >&2; exit 1; }

default_id="$(jq -r '[.data.results[].children[]? | select(.type=="style") | select((.format.default // "false") == "true") | .format.styleId] | first // "Normal"' <<<"$styles_json")"
existing_ids="$(jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | .[]' <<<"$styles_json")"

# How many defined styles are not referenced (left intact by tidy, not dropped).
stats_json="$($TMO officecli view "$out_abs" stats --json 2>/dev/null || echo '{}')"
defined_lc="$(jq -c '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | map(ascii_downcase) | unique' <<<"$styles_json")"
referenced_lc="$(jq -c '.data.styleDistribution // {} | keys | map(ascii_downcase)' <<<"$stats_json")"
unused_count="$(jq -n --argjson d "$defined_lc" --argjson r "$referenced_lc" '[ $d[] | select(. as $x | ($r | index($x)) | not) ] | length')"

mapfile -t dangling < <(dangling_names "$out_abs")

declare -A REPAIR_ID=()
repaired=()
for name in ${dangling[@]+"${dangling[@]}"}; do
  id="$(sanitize_id "$name")"
  [[ -n "$id" ]] || id="WFRepair"
  # Keep styleIds unique.
  base="$id"; n=1
  while grep -qxF "$id" <<<"$existing_ids"; do id="${base}${n}"; n=$((n + 1)); done
  if ! $TMO officecli add "$out_abs" /styles --type style \
      --prop styleId="$id" --prop name="$name" --prop type=paragraph \
      --prop basedOn="$default_id" --prop customStyle=true \
      --prop font.ea="$EA_BODY" --prop font.latin="$LATIN_BODY" --prop font.hint="$HINT" \
      >/dev/null 2>&1; then
    echo "$TOOL: could not define the missing style '$name'" >&2
    exit 1
  fi
  existing_ids+=$'\n'"$id"
  REPAIR_ID["$name"]="$id"
  repaired+=("$name")
  report_add "$REPORT_FILE" changed \
    "Tidy: defined missing style '$name' (styleId=$id, paragraph, based on '$default_id', explicit $EA_BODY/$LATIN_BODY fonts) so its reference resolves."
done

# Verify: after the repairs, nothing is dangling.
remaining="$(dangling_names "$out_abs")"
if [[ -n "$remaining" ]]; then
  echo "$TOOL: dangling style reference(s) remain: $(tr '\n' ' ' <<<"$remaining")" >&2
  exit 1
fi

# Fonts are write-only for the default face, so read each repaired style's
# East-Asian font back and confirm the repair did not inherit 等线.
font_fail=""
for name in ${repaired[@]+"${repaired[@]}"}; do
  id="${REPAIR_ID[$name]}"
  sj="$($TMO officecli get "$out_abs" "/styles/$id" --json 2>/dev/null || echo '{}')"
  ea="$(jq -r '.data.results[0].format["font.ea"] // ""' <<<"$sj" 2>/dev/null || echo "")"
  [[ -n "$ea" && "$ea" != "等线" ]] || font_fail+="$name (ea='$ea') "
done
if [[ -n "$font_fail" ]]; then
  echo "$TOOL: repaired styles with a missing/unsafe CJK font: $font_fail" >&2
  exit 1
fi

if (( ${#repaired[@]} == 0 )); then
  report_add "$REPORT_FILE" changed "Tidy: no dangling style reference to repair."
else
  report_add "$REPORT_FILE" decisions \
    "Tidy: repaired ${#repaired[@]} dangling style reference(s) by defining the referenced style; existing definitions and unused styles were left intact (non-destructive, spec D5.3)."
fi

if (( unused_count > 0 )); then
  report_add "$REPORT_FILE" decisions \
    "Tidy: unused style definitions were left intact rather than dropped, so no basedOn chain or latent reference is broken."
fi

"$CHANGE_REPORT" validate --report "$REPORT_FILE" >/dev/null

# --- source protection ------------------------------------------------------
src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- report -----------------------------------------------------------------
report_json="$(jq -c '.' "$REPORT_FILE")"
repaired_json="$(printf '%s\n' ${repaired[@]+"${repaired[@]}"} | jq -Rsc 'split("\n") | map(select(length>0))')"
report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --arg default_id "$default_id" \
  --argjson repaired "$repaired_json" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson report "$report_json" '
  { source: $source,
    output: $output,
    default_style: $default_id,
    repaired_styles: $repaired,
    repaired_count: ($repaired | length),
    source_unchanged: $source_unchanged,
    report: $report }')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow tidy",
  "  source:          " + .source,
  "  output:          " + .output,
  "  default style:   " + .default_style,
  "  repaired styles: " + (.repaired_count | tostring)
                        + (if (.repaired_styles | length) > 0 then " — " + (.repaired_styles | join(", ")) else "" end),
  "",
  "Change report:",
  ((.report.changed // []) | if length > 0 then (.[] | "  changed:    " + .) else empty end),
  ((.report.decisions // []) | if length > 0 then (.[] | "  decision:   " + .) else empty end)
' <<<"$report"
