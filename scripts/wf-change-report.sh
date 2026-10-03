#!/usr/bin/env bash
#
# WordFlow change-report contract (#28).
#
# The one place a change report is created, extended, validated, and rendered.
# Every output document ships with a report carrying the five areas WordFlow
# reports (spec `docs/spec/v0.1.md` §D12):
#
#   changed     what changed (layout operations applied)
#   decisions   decisions made on the user's behalf, especially applied defaults
#   warnings    constructs that may render differently (D11)
#   downgrades  preferred construction replaced by a fallback, with the reason
#   unverified  anything WordFlow could not verify, and intentional omissions
#
# Features and workflows contribute *structured entries* through `add`; none
# formats its own report — `render` is the single formatter. Entries are plain
# strings; a warning or downgrade may prefix a stable code as `[CODE] text`.
#
# Contract and examples: references/workflow/change-report.md
#
# Usage:
#   wf-change-report.sh new      --source <s> --output <o> --out <report.json>
#   wf-change-report.sh add      --report <r> --area <area> --entry <text> [--entry <text> ...]
#   wf-change-report.sh render   --report <r> [--format text|markdown]
#   wf-change-report.sh validate --report <r>
#
# Areas: changed | decisions | warnings | downgrades | unverified
#
# Exit codes: 0 = success; 1 = report missing/unreadable/malformed or a write
#             failed; 2 = usage error (bad option, unknown area/format,
#             missing dependency, empty entry).
#
set -euo pipefail

readonly AREAS="changed decisions warnings downgrades unverified"
readonly TOOL="wf-change-report.sh"
# shellcheck source=scripts/lib/source-protection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-protection.sh"

# jq schema check for a well-formed report. Extra top-level keys are tolerated
# so sibling work can attach metadata without breaking older consumers; the
# two string fields and the five string arrays are required and non-blank.
readonly SCHEMA='
  def str: type == "string";
  def nonblank: str and (test("\\S"));
  def strarray: type == "array" and all(.[]; str and nonblank);
  type == "object"
  and (.source | nonblank)
  and (.output | nonblank)
  and (.changed    | strarray)
  and (.decisions  | strarray)
  and (.warnings   | strarray)
  and (.downgrades | strarray)
  and (.unverified | strarray)
'

# shellcheck disable=SC2016  # jq programs use $l/$xs literally; no shell expansion
readonly TEXT_FILTER='
  def bullet:
    split("\n") as $l
    | ("  - " + $l[0]),
      ($l[1:][] | "    " + .);
  def area($t; $xs):
    if (($xs | length) == 0)
    then $t + ": none"
    else ($t + ":", ($xs[] | bullet))
    end;
  "WordFlow change report",
  "  source: " + .source,
  "  output: " + .output,
  "",
  area("Changed"; .changed),
  "",
  area("Decisions"; .decisions),
  "",
  area("Warnings"; .warnings),
  "",
  area("Downgrades"; .downgrades),
  "",
  area("Unverified"; .unverified)
'

# shellcheck disable=SC2016
readonly MARKDOWN_FILTER='
  def bullet:
    split("\n") as $l
    | ("- " + $l[0]),
      ($l[1:][] | "  " + .);
  def area($t; $xs):
    "### " + $t,
    (if (($xs | length) == 0)
     then "_none_"
     else ($xs[] | bullet)
     end);
  "# WordFlow change report",
  "",
  "- **Source:** `" + .source + "`",
  "- **Output:** `" + .output + "`",
  "",
  area("Changed"; .changed),
  "",
  area("Decisions"; .decisions),
  "",
  area("Warnings"; .warnings),
  "",
  area("Downgrades"; .downgrades),
  "",
  area("Unverified"; .unverified)
'

usage() {
  cat <<'EOF'
Usage: wf-change-report.sh <command> [options]

Commands:
  new      --source <s> --output <o> --out <report.json>
           Create (or overwrite) an empty report with all five areas.
  add      --report <r> --area <area> --entry <text> [--entry <text> ...]
           Append one or more plain-string entries to an area.
  render   --report <r> [--format text|markdown]
           Print the human-readable report; empty areas are stated explicitly.
  validate --report <r>
           Check the report against the contract; non-zero on malformed.

Areas: changed | decisions | warnings | downgrades | unverified

An entry may prefix a stable code as "[CODE] text" (warnings/downgrades).

Exit codes: 0 ok | 1 malformed / write failure | 2 usage.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die_report() { echo "$TOOL: $*" >&2; exit 1; }

is_area() {
  local a="$1" x
  for x in $AREAS; do [[ "$a" == "$x" ]] && return 0; done
  return 1
}

# require_value <option> <remaining-arg-count>
require_value() {
  (($2 >= 2)) || die_usage "$1 requires a value"
}

validate_file() {
  local f="$1"
  [[ -f "$f" ]] || die_report "report not found: $f"
  if ! jq -e "$SCHEMA" "$f" >/dev/null 2>&1; then
    die_report "malformed report: $f (expected object with non-blank string 'source'/'output' and five non-blank string arrays: changed, decisions, warnings, downgrades, unverified)"
  fi
}

cmd_new() {
  local src="" out="" dst=""
  while (($#)); do
    case "$1" in
      --source) require_value "$1" "$#"; src="$2"; shift 2 ;;
      --output) require_value "$1" "$#"; out="$2"; shift 2 ;;
      --out)    require_value "$1" "$#"; dst="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $1" ;;
      *)  die_usage "unexpected argument: $1" ;;
    esac
  done
  [[ -n "$src" ]] || die_usage "new requires --source"
  [[ -n "$out" ]] || die_usage "new requires --output"
  [[ -n "$dst" ]] || die_usage "new requires --out"
  wf_guard_destination --out "$dst" "$src" "$out"
  local dir; dir="$(dirname -- "$dst")"
  [[ -d "$dir" ]] || die_report "output directory does not exist: $dir"

  local tmp
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  if ! jq -n --arg source "$src" --arg output "$out" \
      '{source:$source, output:$output,
        changed:[], decisions:[], warnings:[], downgrades:[], unverified:[]}' >"$tmp"; then
    rm -f "$tmp"
    die_report "failed to write report: $dst"
  fi
  mv "$tmp" "$dst"
  validate_file "$dst"
  printf 'created: %s\n' "$dst"
}

cmd_add() {
  local report="" area="" e
  local -a entries=()
  while (($#)); do
    case "$1" in
      --report) require_value "$1" "$#"; report="$2"; shift 2 ;;
      --area)   require_value "$1" "$#"; area="$2"; shift 2 ;;
      --entry)  require_value "$1" "$#"; entries+=("$2"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $1" ;;
      *)  die_usage "unexpected argument: $1" ;;
    esac
  done
  [[ -n "$report" ]] || die_usage "add requires --report"
  [[ -n "$area" ]] || die_usage "add requires --area"
  ((${#entries[@]})) || die_usage "add requires at least one --entry"
  is_area "$area" || die_usage "unknown area: '$area' (expected one of: $AREAS)"
  for e in "${entries[@]}"; do
    [[ "$e" == *[![:space:]]* ]] || die_usage "--entry must not be blank"
  done
  validate_file "$report"
  wf_guard_destination --report "$report" "$(jq -r '.source' "$report")" "$(jq -r '.output' "$report")"

  local tmp="$report" next
  for e in "${entries[@]}"; do
    next="$(mktemp "${report}.tmp.XXXXXX")"
    if ! jq --arg area "$area" --arg entry "$e" '.[$area] += [$entry]' "$tmp" >"$next"; then
      rm -f "$next"
      die_report "failed to update report: $report"
    fi
    [[ "$tmp" != "$report" ]] && rm -f "$tmp"
    tmp="$next"
  done
  mv "$tmp" "$report"
}

cmd_render() {
  local report="" fmt="text"
  while (($#)); do
    case "$1" in
      --report) require_value "$1" "$#"; report="$2"; shift 2 ;;
      --format) require_value "$1" "$#"; fmt="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $1" ;;
      *)  die_usage "unexpected argument: $1" ;;
    esac
  done
  [[ -n "$report" ]] || die_usage "render requires --report"
  case "$fmt" in
    text)     validate_file "$report"; jq -r "$TEXT_FILTER" "$report" ;;
    markdown) validate_file "$report"; jq -r "$MARKDOWN_FILTER" "$report" ;;
    *) die_usage "unknown format: '$fmt' (expected text or markdown)" ;;
  esac
}

cmd_validate() {
  local report=""
  while (($#)); do
    case "$1" in
      --report) require_value "$1" "$#"; report="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $1" ;;
      *)  die_usage "unexpected argument: $1" ;;
    esac
  done
  [[ -n "$report" ]] || die_usage "validate requires --report"
  validate_file "$report"
  printf 'valid: %s\n' "$report"
}

main() {
  local cmd="${1:-}"
  if (($#)); then shift; fi
  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
  esac
  command -v jq >/dev/null || { echo "$TOOL: jq not found on PATH" >&2; exit 2; }
  case "$cmd" in
    new)      cmd_new "$@" ;;
    add)      cmd_add "$@" ;;
    render)   cmd_render "$@" ;;
    validate) cmd_validate "$@" ;;
    *) die_usage "unknown command: '$cmd'" ;;
  esac
}

main "$@"
