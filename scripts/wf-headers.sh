#!/usr/bin/env bash
#
# WordFlow headers, footers and page numbers (#19) — spec §D8/§D9/§D10.
#
# Builds running headers/footers and live page-number fields on a document,
# through OfficeCLI. The judgement — which construction, what is portable, what
# is limited — is documented in references/objects/headers-footers.md.
#
# Capability tiers (spec §D9 as revised by #37):
#   Full    plain header/footer text; a footer PAGE and NUMPAGES field;
#           different first-page and odd/even header/footer parts.
#   Limited page-number restart — applied and always reported (D11).
# A footer PAGE/NUMPAGES field is a *layout-computed* field: Word, WPS Writer
# and LibreOffice Writer each resolve it per page without a manual update, so
# WordFlow never emits a warning for it. WordFlow never presents a page number
# it cannot guarantee: PAGEREF and TOC page numbers stay omitted/limited.
#
# Constructions (from tests/generate-fixtures.sh):
#   officecli add F / --type header --prop text=… --prop align=center
#   officecli add F / --type footer --prop text=… --prop align=center
#   officecli add F / --type footer|header --prop type=first|default|even …
#       (an `even` part auto-writes <w:evenAndOddHeaders/>; `first` sets
#        <w:titlePg/>; `default` is the ODD-page part when even/odd is on)
#   officecli add F "/footer[k]/p[1]" --type field --prop fieldType=page
#       (and fieldType=numpages)
#   officecli set F /section[N] --prop pageStart=<n>   (restart: LIMITED)
#
# The source is never modified (ADR-0003): the source bytes are copied to --out
# and only that new file is changed, through OfficeCLI. The byte copy is a file
# duplication, not a DOCX read or write; every DOCX operation still goes
# through OfficeCLI. If a requested header/footer would overwrite different
# existing text, that is a content change and WordFlow stops and asks (D11).
#
# Usage:
#   scripts/wf-headers.sh <source.docx> --out <output.docx> [options]
#
# Exit codes: 0 = applied; 1 = OfficeCLI could not read/write a document;
#             3 = stop/ask (content change); 2 = bad usage / missing dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISK="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"

usage() {
  cat <<'EOF'
Usage: wf-headers.sh <source.docx> --out <output.docx> [options]

Add running headers/footers and live page numbers to a document. The source is
never modified; the result is written to --out.

Options:
  --header <text>         Default (odd-page) header text.
  --footer <text>         Default (odd-page) footer text.
  --page-number           Put a live PAGE field, then "of <NUMPAGES>", in the
                          default footer (and in any first/even footer built).
  --header-first <text>   Different-first-page header text (sets titlePg).
  --footer-first <text>   Different-first-page footer text.
  --header-even <text>    Even-page header text (enables evenAndOddHeaders).
  --footer-even <text>    Even-page footer text.
  --restart <n>           Restart page numbering at n (LIMITED: warns; applied
                          to the last section).
  --report <file>         Write the JSON report (with its change report) here.
  --json                  Print the report as JSON instead of text.
  -h, --help              Show this help.

At least one of --header/--footer/--page-number/--header-first/--footer-first/
--header-even/--footer-even/--restart is required.
EOF
}

SRC=""; OUT=""; REPORT=""; JSON=0
HEADER=""; FOOTER=""; PAGE_NUMBER=0
HEADER_FIRST=""; FOOTER_FIRST=""; HEADER_EVEN=""; FOOTER_EVEN=""
RESTART=""

while (($#)); do
  case "$1" in
    --out)          (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --header)       (($# >= 2)) || { echo "--header requires a value" >&2; exit 2; }; HEADER="$2"; shift 2 ;;
    --footer)       (($# >= 2)) || { echo "--footer requires a value" >&2; exit 2; }; FOOTER="$2"; shift 2 ;;
    --page-number)  PAGE_NUMBER=1; shift ;;
    --header-first) (($# >= 2)) || { echo "--header-first requires a value" >&2; exit 2; }; HEADER_FIRST="$2"; shift 2 ;;
    --footer-first) (($# >= 2)) || { echo "--footer-first requires a value" >&2; exit 2; }; FOOTER_FIRST="$2"; shift 2 ;;
    --header-even)  (($# >= 2)) || { echo "--header-even requires a value" >&2; exit 2; }; HEADER_EVEN="$2"; shift 2 ;;
    --footer-even)  (($# >= 2)) || { echo "--footer-even requires a value" >&2; exit 2; }; FOOTER_EVEN="$2"; shift 2 ;;
    --restart)      (($# >= 2)) || { echo "--restart requires a value" >&2; exit 2; }; RESTART="$2"; shift 2 ;;
    --report)       (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
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

if [[ -z "$HEADER$FOOTER$HEADER_FIRST$FOOTER_FIRST$HEADER_EVEN$FOOTER_EVEN$RESTART" && "$PAGE_NUMBER" == "0" ]]; then
  echo "nothing to do: pass --header/--footer/--page-number/--restart" >&2
  usage >&2; exit 2
fi

if [[ -n "$RESTART" ]]; then
  [[ "$RESTART" =~ ^[0-9]+$ ]] && (( RESTART >= 1 )) \
    || { echo "invalid --restart: $RESTART (a positive integer)" >&2; exit 2; }
fi

if [[ -n "$REPORT" ]]; then
  [[ -d "$(dirname "$REPORT")" ]] || { echo "report directory not found: $(dirname "$REPORT")" >&2; exit 2; }
fi

for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$RISK" ]] || { echo "risk policy not executable: $RISK" >&2; exit 2; }
[[ -x "$CHANGE_REPORT" ]] || { echo "change report tool not executable: $CHANGE_REPORT" >&2; exit 2; }

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# --- report file (change-report contract, #28) ------------------------------
report_is_temp=0
if [[ -n "$REPORT" ]]; then
  report_path="$REPORT"
else
  report_path="$(mktemp "${TMPDIR:-/tmp}/wf-headers-report.XXXXXX.json")"
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

# --- small OfficeCLI helpers ------------------------------------------------
find_part() { # find_part <header|footer> <first|default|even> -> path or ""
  $TMO officecli query "$out_abs" "$1" --json 2>/dev/null \
    | jq -r --arg t "$2" 'first(.data.results[]? | select(.format.type == $t) | .path) // ""' 2>/dev/null \
    || printf ''
}

part_text() { # part_text <part-path>
  $TMO officecli get "$out_abs" "$1" --json 2>/dev/null \
    | jq -r '.data.results[0].text // ""' 2>/dev/null || printf ''
}

part_has_instr() { # part_has_instr <part-path> <PAGE|NUMPAGES>
  $TMO officecli raw "$out_abs" "$1" 2>/dev/null | grep -qE "instrText[^>]*>[^<]*\\b$2\\b"
}

ensure_part() { # ensure_part <header|footer> <type> <text> -> prints path
  local kind="$1" type="$2" text="$3" path cur
  path="$(find_part "$kind" "$type")"
  if [[ -z "$path" ]]; then
    if [[ -n "$text" ]]; then
      $TMO officecli add "$out_abs" / --type "$kind" --prop type="$type" --prop text="$text" --prop align=center >/dev/null
    else
      $TMO officecli add "$out_abs" / --type "$kind" --prop type="$type" --prop align=center >/dev/null
    fi
    path="$(find_part "$kind" "$type")"
  elif [[ -n "$text" ]]; then
    cur="$(part_text "$path")"
    if [[ -z "$cur" || "$cur" == "$text" ]]; then
      $TMO officecli set "$out_abs" "$path" --prop text="$text" >/dev/null
    fi
  fi
  printf '%s\n' "$path"
}

add_page_number() { # add_page_number <footer-path>
  local p="$1"
  if part_has_instr "$p" "PAGE" || part_has_instr "$p" "NUMPAGES"; then return 0; fi
  $TMO officecli add "$out_abs" "$p/p[1]" --type field --prop fieldType=page >/dev/null
  $TMO officecli add "$out_abs" "$p/p[1]" --type run   --prop text=" of " >/dev/null
  $TMO officecli add "$out_abs" "$p/p[1]" --type field --prop fieldType=numpages >/dev/null
}

# --- refuse to overwrite different existing text (content change, D11) ------
conflicts=()
for triple in "header:first:$HEADER_FIRST" "header:default:$HEADER" "header:even:$HEADER_EVEN" \
              "footer:first:$FOOTER_FIRST" "footer:default:$FOOTER" "footer:even:$FOOTER_EVEN"; do
  kind="${triple%%:*}"; rest="${triple#*:}"; type="${rest%%:*}"; text="${rest#*:}"
  [[ -n "$text" ]] || continue
  p="$(find_part "$kind" "$type")"
  [[ -n "$p" ]] || continue
  cur="$(part_text "$p")"
  if [[ -n "$cur" && "$cur" != "$text" ]]; then
    conflicts+=("${kind}[${type}] ('$cur' != '$text')")
  fi
done

if (( ${#conflicts[@]} > 0 )); then
  rm -f "$out_abs"
  "$RISK" emit --report "$report_path" --trigger content-change \
    --detail "existing header/footer text differs: ${conflicts[*]}" >/dev/null || true
  exit 3
fi

# --- build the parts (default = odd page; first/even as requested) ----------
declare -a created=()
declare -a first_footer_paths=() even_footer_paths=()
default_footer_path=""

if [[ -n "$HEADER" ]]; then p="$(ensure_part header default "$HEADER")"; created+=("header[default]=$p"); fi
if [[ -n "$HEADER_FIRST" ]]; then p="$(ensure_part header first "$HEADER_FIRST")"; created+=("header[first]=$p"); fi
if [[ -n "$HEADER_EVEN" ]]; then p="$(ensure_part header even "$HEADER_EVEN")"; created+=("header[even]=$p"); fi

if [[ -n "$FOOTER" || "$PAGE_NUMBER" == "1" ]]; then
  default_footer_path="$(ensure_part footer default "$FOOTER")"
  created+=("footer[default]=$default_footer_path")
  [[ "$PAGE_NUMBER" == "1" ]] && add_page_number "$default_footer_path"
fi
if [[ -n "$FOOTER_FIRST" ]]; then
  p="$(ensure_part footer first "$FOOTER_FIRST")"; created+=("footer[first]=$p")
  first_footer_paths+=("$p")
  [[ "$PAGE_NUMBER" == "1" ]] && add_page_number "$p"
fi
if [[ -n "$FOOTER_EVEN" ]]; then
  p="$(ensure_part footer even "$FOOTER_EVEN")"; created+=("footer[even]=$p")
  even_footer_paths+=("$p")
  [[ "$PAGE_NUMBER" == "1" ]] && add_page_number "$p"
fi

# --- page-number restart (LIMITED; applied to the last section) -------------
declare -a restart_sections=()
if [[ -n "$RESTART" ]]; then
  mapfile -t secs < <($TMO officecli query "$out_abs" section --json 2>/dev/null | jq -r '.data.results[].path')
  (( ${#secs[@]} > 0 )) || { echo "no sections found in $SRC" >&2; exit 1; }
  last_sec="${secs[${#secs[@]}-1]}"
  $TMO officecli set "$out_abs" "$last_sec" --prop pageStart="$RESTART" >/dev/null
  restart_sections+=("$last_sec")
fi

# --- change report entries --------------------------------------------------
"$CHANGE_REPORT" add --report "$report_path" --area changed \
  --entry "Headers/footers: built ${#created[@]} part(s): ${created[*]}." >/dev/null

if [[ "$PAGE_NUMBER" == "1" ]]; then
  "$CHANGE_REPORT" add --report "$report_path" --area changed \
    --entry "Page numbers: added live PAGE and NUMPAGES fields to the default footer (fully supported, layout-computed)." >/dev/null
  "$CHANGE_REPORT" add --report "$report_path" --area decisions \
    --entry "Page numbers use a footer PAGE/NUMPAGES field; Word/WPS/LibreOffice compute it per page, so no manual update is needed." >/dev/null
fi

if [[ -n "$RESTART" ]]; then
  "$RISK" emit --report "$report_path" --trigger page-number-restart \
    --detail "page numbering restarted at $RESTART in $last_sec (LIMITED)" >/dev/null
fi

# --- read the result back through OfficeCLI and record evidence -------------
headers_json="$($TMO officecli query "$out_abs" header --json 2>/dev/null || echo '{}')"
footers_json="$($TMO officecli query "$out_abs" footer --json 2>/dev/null || echo '{}')"
section_json="$($TMO officecli query "$out_abs" section --json 2>/dev/null || echo '{}')"
field_json="$($TMO officecli query "$out_abs" field --json 2>/dev/null || echo '{}')"
settings_raw="$($TMO officecli raw "$out_abs" /settings 2>/dev/null || true)"

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

odd_even=false
grep -q 'evenAndOddHeaders' <<<"$settings_raw" && odd_even=true
first_page=false
[[ "$(jq -r '[.data.results[]? | select(.format.titlePage == true)] | length' <<<"$section_json" 2>/dev/null || echo 0)" != "0" ]] && first_page=true

placeholder_count="$(jq -r '[.data.results[]? | select((.text // "") | test("\u00ab|\u00bb|update field|placeholder"; "i"))] | length' <<<"$field_json" 2>/dev/null || echo 0)"
if (( placeholder_count > 0 )); then
  "$RISK" emit --report "$report_path" --trigger unverifiable-field --resolution state \
    --detail "$placeholder_count page field(s) carry a placeholder cached result" >/dev/null
fi

page_field_count="$(jq -r '[.data.results[]? | select(.format.instruction == "PAGE")] | length' <<<"$field_json" 2>/dev/null || echo 0)"
numpages_field_count="$(jq -r '[.data.results[]? | select(.format.instruction == "NUMPAGES")] | length' <<<"$field_json" 2>/dev/null || echo 0)"

# --- assemble the JSON report ----------------------------------------------
final_json="$(jq -nc \
  --slurpfile rep "$report_path" \
  --argjson headers "$headers_json" --argjson footers "$footers_json" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson odd_even "$odd_even" --argjson first_page "$first_page" \
  --argjson fields "$field_json" \
  --argjson page_fields "$page_field_count" --argjson numpages_fields "$numpages_field_count" \
  --argjson restart_value "${RESTART:-0}" \
  --argjson restart_sections "$(printf '%s\n' "${restart_sections[@]:-}" | jq -R . | jq -sc '[.[] | select(length > 0)]')" \
  --argjson has_restart "$([[ -n "$RESTART" ]] && echo true || echo false)" '
  ($rep[0]) as $r
  | (($headers.data.results // []) | map({path, type: .format.type, text})) as $hs
  | (($footers.data.results // []) | map({path, type: .format.type, text})) as $fs
  | (($fields.data.results // []) | map({
        path, instruction: .format.instruction,
        cached_text: (.text // ""),
        placeholder: ((.text // "") | test("\u00ab|\u00bb|update field|placeholder"; "i"))
      })) as $fd
  | {
      source: $r.source,
      output: $r.output,
      source_unchanged: $source_unchanged,
      headers: $hs,
      footers: $fs,
      first_page: $first_page,
      odd_even: $odd_even,
      page_numbers: {
        field_count: ($fd | length),
        page_fields: $page_fields,
        numpages_fields: $numpages_fields,
        fields: $fd
      },
      restart: (if $has_restart then {value: $restart_value, sections: $restart_sections, limited: true} else null end),
      changed: $r.changed,
      decisions: $r.decisions,
      warnings: $r.warnings,
      downgrades: $r.downgrades,
      unverified: $r.unverified,
      change_report: ($r.changed + $r.decisions + $r.warnings + $r.downgrades + $r.unverified)
    }
')"

printf '%s\n' "$final_json" > "$report_path"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$final_json"
else
  jq -r '
    "WordFlow headers/footers",
    "  source:         " + .source,
    "  output:         " + .output,
    "  source unchanged: " + (.source_unchanged | tostring),
    "  headers:        " + ((.headers | map(.type)) | join(", ")),
    "  footers:        " + ((.footers | map(.type)) | join(", ")),
    "  first-page:     " + (.first_page | tostring),
    "  odd/even:       " + (.odd_even | tostring),
    "  PAGE fields:    " + (.page_numbers.page_fields | tostring)
                          + "   NUMPAGES fields: " + (.page_numbers.numpages_fields | tostring),
    "  restart:        " + (if .restart then (.restart.value | tostring) + " @ " + (.restart.sections | join(", ")) else "none" end),
    "",
    "Change report:",
    (.change_report[] | "  - " + .)
  ' <<<"$final_json"
fi
