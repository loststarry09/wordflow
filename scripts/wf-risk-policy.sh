#!/usr/bin/env bash
#
# WordFlow risk policy (#30) — the single implementation of the D11 triggers.
#
# Spec `docs/spec/v0.1.md` §D11 names seven warn / downgrade / stop triggers.
# Every feature routes its risk decision through this one policy; none invents
# its own warn/downgrade/stop logic. The policy is **data + a pure decision
# function**: the trigger table lives in `$TRIGGERS` and `decide` is a `jq`
# expression over it, so it is fully testable with no DOCX and no OfficeCLI.
#
# Decisions (§D11, CONTEXT.md "Behaviour under risk"):
#   warn       ship now and report a known risk; a construction may render
#              differently in Word, WPS Writer, or LibreOffice Writer.
#   downgrade  ship a portable fallback instead of the preferred construction;
#              never silent — the replacement is reported.
#   stop       produce nothing and ask the user — content change, unconfirmed
#              restructure, unreadable source, or no safe alternative.
#
# "Never ship silently" (D11, last row): a placeholder field cache or an
# unguaranteed page number must be omitted or stated. The policy resolves this
# to a downgrade (omit), a warn (ship but mark unverified), or a stop when the
# caller says neither is possible.
#
# Usage:
#   wf-risk-policy.sh list   [--json]
#   wf-risk-policy.sh decide --trigger <id> [--fact k=v ...] [--detail <text>] [--json]
#   wf-risk-policy.sh classify ...        # alias for decide
#   wf-risk-policy.sh emit   --report <r> --trigger <id> [--fact k=v ...] [--detail <text>]
#
# Facts (known keys, per trigger):
#   preferred-unavailable   fallback=exists|none      exists -> downgrade; none -> stop
#   unverifiable-field      resolution=omit|state|none omit -> downgrade; state -> warn; none -> stop
#
# A non-stop decision yields an entry of the form `[CODE] text`, written through
# the shared change-report contract (#28):
#   warn      -> wf-change-report.sh add --area warnings
#   downgrade -> wf-change-report.sh add --area downgrades   (or unverified when omitting)
# A stop decision writes **no** report entry, prints nothing on stdout, prints
# the ask on stderr, and exits 3. `decide` still returns the structured ask so a
# caller can put the question to the user.
#
# Requirements: bash, jq, coreutils. The change-report tool is invoked for
# `emit`; override it with WF_CHANGE_REPORT (used by tests).
#
# Exit codes: 0 = proceed (warn/downgrade) or list ok; 3 = stop/ask;
#             1 = report error; 2 = usage / unknown trigger.
#
set -euo pipefail

readonly TOOL="wf-risk-policy.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"

# --- the policy: data -------------------------------------------------------
# Decision `area` is where a non-stop entry belongs in the change report; `none`
# marks a stop. `facts` documents the conditional keys a trigger understands.
readonly TRIGGERS='[
  {
    "id": "floating-image", "family": "render-differs",
    "code": "D11-floating-image", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "a floating (anchored) image may render in flow rather than floating in LibreOffice Writer"
  },
  {
    "id": "nested-table", "family": "render-differs",
    "code": "D11-nested-table", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "a nested table is untested across Word, WPS Writer, and LibreOffice Writer and may render differently"
  },
  {
    "id": "columns", "family": "render-differs",
    "code": "D11-columns", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "a multi-column layout may render differently across Word, WPS Writer, and LibreOffice Writer"
  },
  {
    "id": "first-odd-even-headers", "family": "render-differs",
    "code": "D11-first-odd-even-headers", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "different first-page or odd/even headers may render differently across applications"
  },
  {
    "id": "page-number-restart", "family": "render-differs",
    "code": "D11-page-number-restart", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "a page-number restart may renumber differently across applications"
  },
  {
    "id": "complex-equation", "family": "render-differs",
    "code": "D11-complex-equation", "decision": "warn", "area": "warnings", "facts": [],
    "rationale": "a complex equation may render differently across applications"
  },
  {
    "id": "preferred-unavailable", "family": "downgrade",
    "code": "D11-preferred-unavailable", "decision": "downgrade", "area": "downgrades",
    "facts": ["fallback: exists|none"],
    "rationale": "the preferred construction is unavailable, unsafe, or known-unfaithful and a portable fallback exists, so the fallback is used",
    "ask": "No portable fallback exists for the preferred construction; ask the user how to proceed."
  },
  {
    "id": "content-change", "family": "stop",
    "code": "D11-content-change", "decision": "stop", "area": "none", "facts": [],
    "ask": "This would require changing the user'"'"'s content, which WordFlow never does; ask the user before changing any content."
  },
  {
    "id": "restructure-unconfirmed", "family": "stop",
    "code": "D11-restructure-unconfirmed", "decision": "stop", "area": "none", "facts": [],
    "ask": "Restructuring is never automatic; ask the user to confirm each structural change item by item."
  },
  {
    "id": "source-unreadable", "family": "stop",
    "code": "D11-source-unreadable", "decision": "stop", "area": "none", "facts": [],
    "ask": "The source cannot be read or fails validation; ask the user for a readable, valid source."
  },
  {
    "id": "portability-no-alternative", "family": "stop",
    "code": "D11-portability-no-alternative", "decision": "stop", "area": "none", "facts": [],
    "ask": "The requested construction would sacrifice portability and no safe alternative exists; ask the user how to proceed."
  },
  {
    "id": "unverifiable-field", "family": "never-silent",
    "code": "D11-unverifiable-field", "decision": "stop", "area": "none",
    "facts": ["resolution: omit|state|none"],
    "ask": "A field would be a placeholder or a page number cannot be guaranteed and it can be neither safely omitted nor stated; ask the user.",
    "rationale": "a field cache would be a placeholder or a page number cannot be guaranteed"
  }
]'

# --- the policy: a pure decision function -----------------------------------
# Input is the facts object; $trigger/$triggers/$detail come in as arguments.
# Emits a decision object: {trigger,code,family,decision,area,rationale,entry,ask}.
# shellcheck disable=SC2016  # jq program uses $facts/$trigger literally
readonly DECIDE_FILTER='
  $facts as $f
  | ($f.fallback   // "none") as $fallback
  | ($f.resolution // "none") as $resolution
  | ($triggers[] | select(.id == $trigger)) as $r
  | ( if $r.id == "preferred-unavailable" then
        ( if $fallback == "exists"
          then $r + {decision: "downgrade", area: "downgrades"}
          else $r + {decision: "stop", area: "none",
                     rationale: "the preferred construction is unavailable, unsafe, or known-unfaithful and no portable fallback exists"}
          end )
      elif $r.id == "unverifiable-field" then
        ( if   $resolution == "omit"
          then $r + {decision: "downgrade", area: "unverified",
                     rationale: "automatic content is omitted rather than ship a placeholder"}
          elif $resolution == "state"
          then $r + {decision: "warn", area: "unverified",
                     rationale: "the item is shipped but explicitly marked unverified; its value cannot be guaranteed"}
          else $r + {decision: "stop", area: "none",
                     rationale: "a field cache would be a placeholder or a page number cannot be guaranteed"}
          end )
      else $r
      end ) as $r
  | ( if $r.decision == "stop" then null
      else "[" + $r.code + "]"
           + ( if ($detail | length) > 0
               then " " + $detail + " — " + $r.rationale
               else " " + $r.rationale
               end )
      end ) as $entry
  | ( if $r.decision == "stop"
      then ( if ($detail | length) > 0 then $detail + " " + $r.ask else $r.ask end )
      else null
      end ) as $ask
  | {trigger: $r.id, code: $r.code, family: $r.family, decision: $r.decision,
     area: $r.area, rationale: ($r.rationale // null), entry: $entry, ask: $ask}
'

usage() {
  cat <<'EOF'
Usage: wf-risk-policy.sh <command> [options]

Commands:
  list      [--json]                       List the D11 trigger table.
  decide    --trigger <id> [options]       Return the decision (warn|downgrade|stop).
  classify  ...                            Alias for decide.
  emit      --report <r> --trigger <id> [options]
                                           Decide and, unless the decision is
                                           stop, append the entry to a change
                                           report (#28). On stop writes nothing
                                           and prints the ask to stderr.

Options:
  --trigger <id>       A trigger id from `list` (required for decide/emit).
  --fact <key=value>   A situation fact; repeatable. Known keys:
                         preferred-unavailable  fallback=exists|none
                         unverifiable-field     resolution=omit|state|none
  --detail <text>      Caller-specific specifics woven into the entry/ask.
  --report <path>      The change report (emit only).
  --json               Print decide/list output as JSON.
  -h, --help           Show this help.

Exit codes: 0 proceed (warn/downgrade) or list ok | 3 stop/ask |
            1 report error | 2 usage / unknown trigger.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die_report() { echo "$TOOL: $*" >&2; exit 1; }

require_value() { (($2 >= 2)) || die_usage "$1 requires a value"; }

known_trigger() {
  jq -ne --arg t "$1" --argjson ts "$TRIGGERS" 'any($ts[]; .id == $t)' >/dev/null 2>&1
}

# build_facts <k=v ...>  -> prints an object
build_facts() {
  if (($# == 0)); then printf '{}'; return 0; fi
  jq -nc --args '
    $ARGS.positional
    | map(split("="))
    | map({(.[0]): (.[1:] | join("="))})
    | add // {}
  ' "$@"
}

# run_decide <trigger> <facts-json> <detail>  -> prints the decision object
run_decide() {
  jq -nc \
    --argjson triggers "$TRIGGERS" \
    --arg trigger "$1" \
    --argjson facts "$2" \
    --arg detail "$3" \
    "$DECIDE_FILTER"
}

print_decision() {
  local json="$1" as_json="$2"
  if [[ "$as_json" == "1" ]]; then
    jq . <<<"$json"
    return 0
  fi
  jq -r '
    "decision: " + .decision,
    "area:     " + .area,
    ( if .decision == "stop"
      then "ask:      " + .ask
      else "entry:    " + .entry
      end )
  ' <<<"$json"
}

cmd_list() {
  local as_json=0
  while (($#)); do
    case "$1" in
      --json) as_json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $1" ;;
      *)  die_usage "unexpected argument: $1" ;;
    esac
  done
  if [[ "$as_json" == "1" ]]; then
    jq . <<<"$TRIGGERS"
    return 0
  fi
  jq -r '
    "WordFlow risk policy — D11 triggers",
    ( .[] | "  " + (.id + "                                        ")[0:34]
            + (.decision + "          ")[0:10]
            + (.area + "          ")[0:11]
            + "[" + .code + "]" )
  ' <<<"$TRIGGERS"
}

# parse_common <args...>; sets: TRIGGER, DETAIL, JSON_OUT, REPORT, FACT_PAIRS[]
parse_common() {
  TRIGGER=""; DETAIL=""; JSON_OUT=0; REPORT=""
  declare -g -a FACT_PAIRS=()
  while (($#)); do
    case "$1" in
      --trigger) require_value "$1" "$#"; TRIGGER="$2"; shift 2 ;;
      --fact)    require_value "$1" "$#"; FACT_PAIRS+=("$2"); shift 2 ;;
      --fallback)   require_value "$1" "$#"; FACT_PAIRS+=("fallback=$2"); shift 2 ;;
      --resolution) require_value "$1" "$#"; FACT_PAIRS+=("resolution=$2"); shift 2 ;;
      --detail)  require_value "$1" "$#"; DETAIL="$2"; shift 2 ;;
      --report)  require_value "$1" "$#"; REPORT="$2"; shift 2 ;;
      --json)    JSON_OUT=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*)        die_usage "unknown option: $1" ;;
      *)         die_usage "unexpected argument: $1" ;;
    esac
  done
}

cmd_decide() {
  parse_common "$@"
  [[ -n "$TRIGGER" ]] || die_usage "decide requires --trigger"
  known_trigger "$TRIGGER" || die_usage "unknown trigger: $TRIGGER"
  local facts; facts="$(build_facts ${FACT_PAIRS[@]+"${FACT_PAIRS[@]}"})"
  local decision; decision="$(run_decide "$TRIGGER" "$facts" "$DETAIL")"
  print_decision "$decision" "$JSON_OUT"
  if [[ "$(jq -r '.decision' <<<"$decision")" == "stop" ]]; then exit 3; fi
  return 0
}

cmd_emit() {
  parse_common "$@"
  [[ -n "$TRIGGER" ]] || die_usage "emit requires --trigger"
  [[ -n "$REPORT" ]] || die_usage "emit requires --report"
  known_trigger "$TRIGGER" || die_usage "unknown trigger: $TRIGGER"
  [[ -x "$CHANGE_REPORT" ]] || die_report "change-report tool not executable: $CHANGE_REPORT"

  local facts decision
  facts="$(build_facts ${FACT_PAIRS[@]+"${FACT_PAIRS[@]}"})"
  decision="$(run_decide "$TRIGGER" "$facts" "$DETAIL")"

  local kind area entry ask
  kind="$(jq -r '.decision' <<<"$decision")"
  if [[ "$kind" == "stop" ]]; then
    # Stop path: no report entry, no stdout, only the ask for the caller.
    ask="$(jq -r '.ask' <<<"$decision")"
    printf '%s\n' "$ask" >&2
    exit 3
  fi

  area="$(jq -r '.area' <<<"$decision")"
  entry="$(jq -r '.entry' <<<"$decision")"
  "$CHANGE_REPORT" add --report "$REPORT" --area "$area" --entry "$entry"
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
    list)              cmd_list "$@" ;;
    decide|classify)   cmd_decide "$@" ;;
    emit)              cmd_emit "$@" ;;
    *) die_usage "unknown command: '$cmd'" ;;
  esac
}

main "$@"
