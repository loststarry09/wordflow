#!/usr/bin/env bash
#
# WordFlow style inspection and ownership decision (#16).
#
# Read-only: inspects a .docx through OfficeCLI and reports the style inventory
# plus one style-ownership decision (spec `docs/spec/v0.1.md` §D5, §D7):
#
#   use-template-styles          a template was supplied; it outranks the source.
#   preserve-and-tidy            the source uses its own named styles.
#   rebuild-with-standard-styles the source uses no named styles.
#
# It never modifies the source or the template. Every DOCX read goes through
# OfficeCLI; this operation owns only the judgement, not any parsing or writing.
#
# Usage:
#   scripts/wf-style-ownership.sh <source.docx> [--template <template.docx>] [--json]
#
# Exit codes: 0 = report produced; 1 = OfficeCLI could not read a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: wf-style-ownership.sh <source.docx> [--template <template.docx>] [--json]

Inspect a document's styles and decide the style-ownership strategy:
  use-template-styles | preserve-and-tidy | rebuild-with-standard-styles

Options:
  --template <file>  A template document that should outrank the source's styles.
  --json             Emit the report as JSON instead of text.
  -h, --help         Show this help.
EOF
}

SRC=""; TPL=""; JSON=0
while (($#)); do
  case "$1" in
    --template)
      (($# >= 2)) || { echo "--template requires a file argument" >&2; exit 2; }
      TPL="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)          SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -z "$TPL" || -f "$TPL" ]] || { echo "template not found: $TPL" >&2; exit 2; }
for bin in officecli jq; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"

# Release any resident so neither document is left pinned by OfficeCLI.
cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  if [[ -n "$TPL" ]]; then $TMO officecli close "$(abs "$TPL")" >/dev/null 2>&1 || true; fi
  return 0
}
trap cleanup EXIT

# --- gather facts through OfficeCLI (read-only) ----------------------------
styles_json="$($TMO officecli get "$src_abs" /styles --json)"
stats_json="$($TMO officecli view "$src_abs" stats --json)"

if ! jq -e '.success == true' <<<"$styles_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read styles from $SRC" >&2
  exit 1
fi
if ! jq -e '.success == true' <<<"$stats_json" >/dev/null 2>&1; then
  echo "OfficeCLI could not read statistics from $SRC" >&2
  exit 1
fi

template_json="{}"
if [[ -n "$TPL" ]]; then
  template_json="$($TMO officecli get "$(abs "$TPL")" /styles --json)"
  if ! jq -e '.success == true' <<<"$template_json" >/dev/null 2>&1; then
    echo "OfficeCLI could not read styles from template $TPL" >&2
    exit 1
  fi
fi

# --- decide (the judgement WordFlow owns) ----------------------------------
report="$(jq -nc \
  --argjson styles   "$styles_json" \
  --argjson stats    "$stats_json" \
  --argjson template_doc "$template_json" \
  --arg source "$SRC" \
  --arg template "$TPL" '
  def lc: ascii_downcase;
  def isin($arr): . as $v | ($arr | index($v)) != null;
  def skeys($o): [ ($o.id | lc), ($o.name | lc) ] | map(select(. != ""));

  [ $styles.data.results[]? | select(.type=="styles") | .children[]?
    | select(.type=="style")
    | { id:   (.format.styleId // ""),
        name: (.format.name // .format.styleId // ""),
        default: ((.format.default // "false") == "true") } ]
  | map(select(.name != "" or .id != ""))                 as $defined
  | ($defined | map(.name))                               as $defined_names
  | ([ $defined[] | skeys(.) ] | add // [] | unique)      as $defined_keys
  | ([ $defined[] | select(.default) | skeys(.) ] | add // [] | unique) as $default_keys
  | (($stats.data.styleDistribution // {}) | keys)        as $referenced_names
  | ($referenced_names | map(lc))                         as $referenced_lc

  | [$referenced_names[] | select((lc) as $n | ($n | isin($defined_keys)) | not)]           as $dangling
  | [$defined[] | select(.default | not)
        | select( ((.id   | lc) as $i | ($i | isin($referenced_lc)) | not)
              and ((.name | lc) as $n | ($n | isin($referenced_lc)) | not))
        | .name] | unique                                                                   as $unused
  | [$referenced_names[] | select((lc) as $n | ($n | isin($default_keys)) | not)]           as $named_in_use
  | [$referenced_names[] | select(test("^(heading|标题)[ _-]?[1-9]$"; "i"))]                as $heading_names
  | [$heading_names[] | capture("(?<l>[1-9])").l | tonumber] | unique | sort               as $heading_levels

  | ( [ $template_doc.data.results[]? | select(.type=="styles") | .children[]?
        | select(.type=="style") | (.format.name // .format.styleId // "") ]
      | map(select(. != "")) | sort ) as $template_style_names

  | (if ($template | length) > 0
       then ["use-template-styles",
             "A template was supplied; it outranks the document'"'"'s own styles."]
     elif ($named_in_use | length) > 0
       then ["preserve-and-tidy",
             "The document uses " + (($named_in_use | length) | tostring) + " named style(s); preserve and tidy them"
             + (if ($dangling | length) > 0
                then " (repair " + (($dangling | length) | tostring) + " dangling style reference(s))"
                else "" end) + "."]
     else ["rebuild-with-standard-styles",
           "No named styles are in use (every paragraph uses the default style); rebuild with WordFlow standard styles."]
     end) as $dec
  | $dec[0] as $decision
  | $dec[1] as $reason

  | { source: $source,
      template: (if ($template | length) > 0 then $template else null end),
      defined_styles: ($defined_names | sort),
      referenced_styles: ($stats.data.styleDistribution // {}),
      dangling_styles: ($dangling | sort),
      unused_styles: ($unused | sort),
      named_styles_in_use: ($named_in_use | sort),
      heading_levels: $heading_levels,
      has_heading_hierarchy: (($heading_levels | length) > 0),
      template_styles: $template_style_names,
      coherent: (($dangling | length) == 0),
      decision: $decision,
      reason: $reason,
      change_report: ["Style ownership: " + $decision + " — " + $reason] }
')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

# --- human-readable report -------------------------------------------------
jq -r '
  def list: if length == 0 then "(none)" else join(", ") end;
  "WordFlow style inspection",
  "  source:                 " + .source,
  "  template:               " + (.template // "(none)"),
  "  defined styles (" + ((.defined_styles | length) | tostring) + "): " + (.defined_styles | list),
  "  referenced styles:      " + ((.referenced_styles | keys) | list),
  "  dangling styles:        " + (.dangling_styles | list),
  "  unused defined styles:  " + (.unused_styles | list),
  "  heading levels:         " + (if (.heading_levels | length) == 0 then "(none)" else (.heading_levels | map(tostring) | join(", ")) end),
  "  template styles:        " + (if (.template_styles | length) == 0 then "(none)" else (.template_styles | list) end),
  "  coherent:               " + (if .coherent then "yes" else "no" end),
  "",
  "  decision: " + .decision,
  "  reason:   " + .reason,
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
