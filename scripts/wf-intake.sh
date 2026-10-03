#!/usr/bin/env bash
#
# WordFlow intake, precedence resolution, and source protection (#15).
#
# The front door of both workflows (spec `docs/spec/v0.1.md` §D2, §D3, §D4.1,
# §D5.1). It accepts either an existing .docx (--source, a restyle) or raw
# content (--content, a generate), plus an optional template and/or written
# formatting requirement; resolves the precedence chain
#
#   formatting requirement > template > document styles > standard styles > defaults
#
# protects the source (read-only, hash-verified unchanged), refuses when a source
# cannot be read safely, and emits a machine-readable job plan (JSON) that the
# downstream workflows (#32, #33, #35) consume.
#
# It does NOT lay anything out: it resolves authority and the output path only.
# Every DOCX read goes through OfficeCLI (ADR-0001); it never writes or copies a
# DOCX, and it never modifies the source or the template.
#
# It reuses, and does not reimplement, the merged contracts:
#   #13 scripts/wf-output-name.sh      output naming + collision numbering
#   #16 scripts/wf-style-ownership.sh  document-styles ownership decision
#   #28 scripts/wf-change-report.sh    the report contract (entries only)
#
# Normative rules: references/core/intake.md
#
# Usage:
#   wf-intake.sh --source <docx> | --content <file>
#                [--template <docx>] [--requirement <file>]
#                [--output <path>] [--plan <path>] [--json]
#
# Exit codes: 0 = plan produced; 2 = bad usage / missing dependency;
#             3 = refused (stop and ask; see the JSON reason_code).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME_TOOL="$ROOT/scripts/wf-output-name.sh"
STYLE_TOOL="$ROOT/scripts/wf-style-ownership.sh"
TOOL='wf-intake.sh'
VERSION=1
TMO='timeout 60'

usage() {
  cat <<'EOF'
Usage: wf-intake.sh --source <docx> | --content <file>
                    [--template <docx>] [--requirement <file>]
                    [--output <path>] [--plan <path>] [--json]

Resolve a WordFlow job: precedence, source protection, and the output path.

Source (exactly one):
  --source <docx>       Restyle an existing .docx (read-only).
  --content <file>      Generate from a text/Markdown content file.

Optional inputs:
  --template <docx>     A source of look (styles/page setup); never content.
  --requirement <file>  A written formatting requirement. Lines "key = value"
                        or "key: value" are overrides; other non-blank lines are
                        notes (see references/core/intake.md).

Output:
  --output, -o <path>   User-specified output file or directory. Default naming,
                        collision numbering, and never-overwrite are delegated
                        to scripts/wf-output-name.sh (#13).
  --plan <path>         Also write the job plan JSON to this file (success only).
  --json                Print the job plan as JSON instead of a summary.
  -h, --help            Show this help.

Precedence (highest first):
  formatting requirement > template > document styles > standard styles > defaults

Exit codes: 0 plan produced; 2 bad usage/dependency; 3 refused (stop and ask).
EOF
}

die_usage() { printf '%s: %s\n' "$TOOL" "$*" >&2; usage >&2; exit 2; }

# --- arguments -------------------------------------------------------------
SRC=''; CONTENT=''; TPL=''; REQ=''; OUT=''; OUT_SET=0; PLAN=''; JSON=0
while (($#)); do
  case "$1" in
    --source)      (($# >= 2)) || die_usage "--source requires a path"; SRC="$2"; shift 2 ;;
    --content)     (($# >= 2)) || die_usage "--content requires a path"; CONTENT="$2"; shift 2 ;;
    --template)    (($# >= 2)) || die_usage "--template requires a path"; TPL="$2"; shift 2 ;;
    --requirement) (($# >= 2)) || die_usage "--requirement requires a path"; REQ="$2"; shift 2 ;;
    --output|-o)   (($# >= 2)) || die_usage "$1 requires a path"; OUT="$2"; OUT_SET=1; shift 2 ;;
    --plan)        (($# >= 2)) || die_usage "--plan requires a path"; PLAN="$2"; shift 2 ;;
    --json)        JSON=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die_usage "unknown option: $1" ;;
    *)             die_usage "unexpected argument: $1" ;;
  esac
done

[[ -n "$SRC" || -n "$CONTENT" ]] || die_usage "exactly one of --source or --content is required"
[[ -z "$SRC" || -z "$CONTENT" ]] || die_usage "--source and --content are mutually exclusive"
[[ "$OUT_SET" == 0 || -n "$OUT" ]] || die_usage "--output requires a non-empty path"

command -v jq        >/dev/null || die_usage "jq not found on PATH"
command -v sha256sum >/dev/null || die_usage "sha256sum not found on PATH"

abs() {
  if [[ -d "$1" ]]; then (cd -- "$1" && pwd)
  elif [[ "$1" = /* ]]; then printf '%s\n' "${1%/}"
  else printf '%s/%s\n' "${PWD%/}" "${1#./}"; fi
}
sha() { sha256sum -- "$1" | awk '{print $1}'; }
jstr() { jq -Rn --arg s "$1" '$s'; }

MODE='restyle'; KIND='docx'; SRC_UNREADABLE='source-unreadable'
if [[ -n "$CONTENT" ]]; then MODE='generate'; KIND='content'; SRC_UNREADABLE='content-unreadable'; fi

# --- refusal ---------------------------------------------------------------
KIND_STATE="$KIND"; SRC_STATE=''
refuse() { # refuse <reason_code> <message>
  local code="$1" msg="$2"
  if [[ "$JSON" == 1 ]]; then
    jq -n --arg tool "$TOOL" --argjson v "$VERSION" --arg code "$code" --arg msg "$msg" \
      --arg kind "$KIND_STATE" --arg path "$SRC_STATE" '
      {status:"refused", tool:$tool, version:$v, reason_code:$code,
       message:("stop and ask: " + $msg),
       source:{ kind:(if $kind=="" then null else $kind end),
                path:(if $path=="" then null else $path end) },
       output_written:false,
       change_report:["Intake refused: " + $code + " — " + $msg]}
    '
  else
    printf '%s: stop and ask: %s\n' "$TOOL" "$msg" >&2
  fi
  exit 3
}

# --- resolve the source -----------------------------------------------------
if [[ -n "$SRC" ]]; then
  SRC_PATH="$(abs "$SRC")"
else
  SRC_PATH="$(abs "$CONTENT")"
fi
SRC_STATE="$SRC_PATH"

if [[ ! -e "$SRC_PATH" ]]; then
  refuse "$SRC_UNREADABLE" "source file does not exist: $SRC_PATH"
fi
[[ -f "$SRC_PATH" ]] || refuse "$SRC_UNREADABLE" "source is not a regular file: $SRC_PATH"
[[ -r "$SRC_PATH" ]] || refuse "$SRC_UNREADABLE" "source is not readable: $SRC_PATH"

if [[ "$MODE" == 'generate' && ! -s "$SRC_PATH" ]]; then
  echo "$TOOL: warning: content file is empty: $SRC_PATH" >&2
fi

# Source protection: hash before ANY read and verify after every read.
src_before="$(sha "$SRC_PATH")"

# --- resolve template / requirement paths ----------------------------------
TPL_PATH=''; REQ_PATH=''
[[ -n "$TPL" ]] && TPL_PATH="$(abs "$TPL")"
[[ -n "$REQ" ]] && REQ_PATH="$(abs "$REQ")"

# shellcheck source=scripts/lib/source-protection.sh
source "$ROOT/scripts/lib/source-protection.sh"
wf_guard_destination --plan "$PLAN" "$SRC_PATH" "$TPL_PATH" "$REQ_PATH"
wf_guard_destination --output "$OUT" "$SRC_PATH" "$TPL_PATH" "$REQ_PATH"

# --plan must never point at an input document.
if [[ -n "$PLAN" ]]; then
  PLAN_ABS="$(abs "$PLAN")"
  [[ "$PLAN_ABS" != "$SRC_PATH" ]] || die_usage "--plan must not overwrite the source"
  [[ -z "$TPL_PATH" || "$PLAN_ABS" != "$TPL_PATH" ]] || die_usage "--plan must not overwrite the template"
fi

# --- read DOCX inputs through OfficeCLI (read-only) ------------------------
# Source protection: close anything we open, then hash-verify at the end.
cleanup() {
  $TMO officecli close "$SRC_PATH" >/dev/null 2>&1 || true
  if [[ -n "$TPL_PATH" ]]; then $TMO officecli close "$TPL_PATH" >/dev/null 2>&1 || true; fi
  return 0
}
trap cleanup EXIT

# officecli_validate <path> <reason-invalid-prefix>
# Returns nothing; refuses (stop and ask) on failure.
validate_docx() {
  local p="$1" what="$2" vjson code err
  command -v officecli >/dev/null || die_usage "officecli not found on PATH"
  vjson="$($TMO officecli validate "$p" --json 2>/dev/null || true)"
  if jq -e '.success == true' <<<"$vjson" >/dev/null 2>&1; then return 0; fi
  code="$(jq -r '.error.code // "invalid"' <<<"$vjson" 2>/dev/null || echo invalid)"
  err="$(jq -r '.error.error // "failed OfficeCLI validation"' <<<"$vjson" 2>/dev/null || echo 'failed OfficeCLI validation')"
  case "$code" in
    file_not_found|io_error|corrupt_file)
      refuse "${what}-unreadable" "$what cannot be read safely (${code}): ${err}" ;;
    *)
      refuse "${what}-invalid" "$what failed OfficeCLI validation (${code}): ${err}" ;;
  esac
}

template_styles_json='[]'
if [[ "$MODE" == 'restyle' ]]; then
  validate_docx "$SRC_PATH" source
fi
if [[ -n "$TPL_PATH" ]]; then
  [[ -e "$TPL_PATH" ]] || refuse "template-unreadable" "template file does not exist: $TPL_PATH"
  [[ -r "$TPL_PATH" ]] || refuse "template-unreadable" "template is not readable: $TPL_PATH"
  validate_docx "$TPL_PATH" template
  tjson="$($TMO officecli get "$TPL_PATH" /styles --json 2>/dev/null || true)"
  if jq -e '.success == true' <<<"$tjson" >/dev/null 2>&1; then
    template_styles_json="$(jq -c '
      [ .data.results[]? | select(.type=="styles") | .children[]?
        | select(.type=="style") | (.format.name // .format.styleId // "") ]
      | map(select(. != "")) | sort' <<<"$tjson")"
  fi
fi

# --- parse the formatting requirement --------------------------------------
overrides_json='[]'; notes_json='[]'
if [[ -n "$REQ_PATH" ]]; then
  [[ -e "$REQ_PATH" ]] || refuse "requirement-unreadable" "requirement file does not exist: $REQ_PATH"
  [[ -r "$REQ_PATH" ]] || refuse "requirement-unreadable" "requirement file is not readable: $REQ_PATH"
  parsed="$(jq -R -s '
    split("\n")
    | map(sub("\r$"; ""))
    | map(sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | map(select((. == "") or startswith("#") | not))
    | map( . as $line
           | (($line | capture("^(?<key>[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*)[[:space:]]*[:=][[:space:]]*(?<value>.*)$")) // null) as $c
           | if $c == null then {note:$line}
             else {key:$c.key, value:($c.value | sub("[[:space:]]+$"; ""))} end)
    | { overrides: [ .[] | select(has("key")) ],
        notes:     [ .[] | select(has("note")) | .note ] }
  ' "$REQ_PATH")"
  overrides_json="$(jq -c '.overrides' <<<"$parsed")"
  notes_json="$(jq -c '.notes' <<<"$parsed")"
fi

# --- document-styles decision (restyle only; reuse #16) --------------------
ownership_json='{}'
if [[ "$MODE" == 'restyle' ]]; then
  st_args=("$SRC_PATH")
  [[ -n "$TPL_PATH" ]] && st_args=(--template "$TPL_PATH" "$SRC_PATH")
  rc=0
  ownership_json="$($TMO "$STYLE_TOOL" "${st_args[@]}" --json 2>/dev/null)" || rc=$?
  if [[ "$rc" != 0 ]] || ! jq -e '.decision' <<<"$ownership_json" >/dev/null 2>&1; then
    refuse "source-unreadable" "OfficeCLI could not read the source document's styles: $SRC_PATH"
  fi
fi

# --- output naming (reuse #13) ---------------------------------------------
name_args=("$SRC_PATH")
[[ "$OUT_SET" == 1 ]] && name_args+=(--output "$OUT")
rc=0
output_json="$($TMO "$NAME_TOOL" "${name_args[@]}" --json 2>/dev/null)" || rc=$?
case "$rc" in
  0) ;;
  3) refuse "output-exists" "the specified output already exists; refusing to overwrite (choose another --output)" ;;
  4) refuse "output-unavailable" "no free output name could be found; specify --output" ;;
  *) die_usage "output naming failed (wf-output-name.sh exit $rc)" ;;
esac
jq -e '.output' <<<"$output_json" >/dev/null 2>&1 || die_usage "output naming produced no path"

# --- source protection: verify unchanged across every read ------------------
# src_before was taken before the first OfficeCLI read; this is after the last.
src_after="$(sha "$SRC_PATH")"
if [[ "$src_before" != "$src_after" ]]; then
  refuse "source-changed" "the source changed during the job; refusing to produce output"
fi

tpl_sha='null'
if [[ -n "$TPL_PATH" ]]; then tpl_sha="$(jstr "$(sha "$TPL_PATH")")"; fi

# --- assemble the job plan --------------------------------------------------
src_info="$(jq -nc \
  --arg kind "$KIND" --arg path "$SRC_PATH" \
  --arg h "$src_before" --arg ha "$src_after" \
  '{kind:$kind, path:$path, sha256:$h, sha256_after:$ha, unchanged:($h==$ha)}')"

if [[ -n "$TPL_PATH" ]]; then
  tpl_info="$(jq -nc --arg path "$TPL_PATH" --argjson sha "$tpl_sha" \
    --argjson styles "$template_styles_json" '{path:$path, sha256:$sha, styles:$styles}')"
else
  tpl_info='null'
fi
if [[ -n "$REQ_PATH" ]]; then
  req_info="$(jq -nc --arg path "$REQ_PATH" \
    --argjson overrides "$overrides_json" --argjson notes "$notes_json" \
    '{path:$path, overrides:$overrides, notes:$notes}')"
else
  req_info='null'
fi

plan="$(jq -nc \
  --arg tool "$TOOL" --argjson v "$VERSION" --arg mode "$MODE" \
  --argjson src "$src_info" --argjson tpl "$tpl_info" --argjson req "$req_info" \
  --argjson own "$ownership_json" \
  --argjson tpl_styles "$template_styles_json" \
  --argjson out "$output_json" '
  ($mode == "restyle") as $restyle
  | ([ $own.named_styles_in_use[]? ] | map(select(. != "")))      as $named
  | ([ $own.defined_styles[]? ] | map(select(. != "")))           as $defined
  | ([ $own.dangling_styles[]? ] | map(select(. != "")))          as $dangling
  | ([ $own.heading_levels[]? ])                                  as $levels
  | ($own.coherent // null)                                       as $coherent
  | ($named | length > 0)                                         as $doc_styles
  | ([ $req.overrides[]? ] | length > 0)                          as $has_overrides
  | ([ $req.notes[]? ] | length > 0)                              as $has_notes
  | ($req != null)                                                as $req_given
  | ($req_given and ($has_overrides or $has_notes))               as $has_req
  | ($tpl != null)                                                as $has_tpl

  | (if $has_tpl then "template"
     elif ($restyle and $doc_styles) then "document"
     else "standard" end)                                         as $style_set
  | (if $has_req then "formatting-requirement"
     elif $has_tpl then "template"
     elif ($restyle and $doc_styles) then "document-styles"
     else "standard-styles" end)                                  as $style_source

  | [ (if $has_tpl then "template" else empty end),
      (if ($restyle and $doc_styles) then "document-styles" else empty end),
      (if $style_set == "standard" then "standard-styles" else empty end),
      "defaults" ]                                                as $shadowed
  | ($req.overrides // [] | map(. + {shadowed:$shadowed}))        as $ov

  | { status:"planned", tool:$tool, version:$v, mode:$mode,
      source:$src,
      inputs:{ template:$tpl,
               requirement:(if $req == null then null
                            else {path:$req.path, overrides:$ov, notes:($req.notes // [])} end) },
      precedence:[
        {layer:"formatting-requirement", rank:1, present:$req_given,
         authoritative:($style_source=="formatting-requirement"),
         note:(if $has_req then
                 ("Formatting requirement supplied; it outranks the template, document styles, standard styles, and defaults."
                  + (if $has_overrides then " " + (($ov|length)|tostring) + " override(s)." else "" end)
                  + (if $has_notes then " " + (($req.notes|length)|tostring) + " free-text note(s)." else "" end))
               elif $req_given then "Formatting requirement supplied but empty (no overrides or notes); it contributes nothing."
               else "No formatting requirement supplied." end)},
        {layer:"template", rank:2, present:$has_tpl,
         authoritative:($style_source=="template"),
         note:(if $has_tpl then "Template supplied; its look outranks document styles but not the formatting requirement."
               else "No template supplied." end)},
        {layer:"document-styles", rank:3, present:($restyle and $doc_styles),
         authoritative:($style_source=="document-styles"),
         note:(if ($restyle and $doc_styles) then "Source uses named styles; preserve and tidy them (#16)."
               elif $restyle then "Source uses no named styles; nothing to preserve (#16)."
               else "Generate job: no source document styles." end)},
        {layer:"standard-styles", rank:4, present:($style_set=="standard"),
         authoritative:($style_source=="standard-styles"),
         note:(if $style_set=="standard" then "WordFlow standard style set supplies the definitions (#17)."
               else "Not used: higher-precedence style definitions are present." end)},
        {layer:"defaults", rank:5, present:true, authoritative:($style_source=="defaults"),
         note:"WordFlow defaults fill anything no higher layer specifies (spec D6)."}],
      style:{ source:$style_source, set:$style_set,
              ownership:(if $restyle then ($own.decision // null) else null end),
              coherent:$coherent,
              named_styles_in_use:$named, defined_styles:$defined,
              dangling_styles:$dangling, heading_levels:$levels,
              template_styles:$tpl_styles },
      output:$out,
      protection:{ read_only:true, verified_unchanged:true },
      change_report:(
        ["Intake: " + $mode + " job; source " + $src.path + "."]
        + ["Intake: style source " + $style_source
           + " (precedence: formatting requirement > template > document styles > standard styles > defaults)."]
        + (if $has_tpl then
             ["Intake: template supplied (" + $tpl.path + "); its styles outrank the document'"'"'s own styles but not the formatting requirement."]
           else [] end)
        + [ $ov[] | "Intake: formatting-requirement override '"'"'" + .key + " = " + .value
                    + "'"'"' outranks " + (.shadowed | join(", ")) + "." ]
        + ["Intake: source opened read-only; sha256 " + $src.sha256 + " verified unchanged."]
      )
    }')"

# --- emit -------------------------------------------------------------------
if [[ -n "$PLAN" ]]; then
  plan_dir="$(dirname -- "$PLAN_ABS")"
  [[ -d "$plan_dir" ]] || die_usage "plan directory does not exist: $plan_dir"
  tmp="$(mktemp "${PLAN_ABS}.tmp.XXXXXX")"
  printf '%s\n' "$plan" > "$tmp"
  mv -- "$tmp" "$PLAN_ABS"
fi

if [[ "$JSON" == 1 ]]; then
  printf '%s\n' "$plan"
  exit 0
fi

# --- human summary ----------------------------------------------------------
jq -r '
  def list: if length == 0 then "(none)" else join(", ") end;
  "WordFlow intake plan",
  "  mode:         " + .mode,
  "  source:       " + .source.path + " (" + .source.kind + ", sha256 " + (.source.sha256[0:12]) + "…)",
  "  template:     " + (if .inputs.template == null then "(none)" else .inputs.template.path end),
  "  requirement:  " + (if .inputs.requirement == null then "(none)"
                       else .inputs.requirement.path
                            + " (" + ((.inputs.requirement.overrides | length) | tostring) + " override(s), "
                            + ((.inputs.requirement.notes | length) | tostring) + " note(s))" end),
  "  style source: " + .style.source,
  "  style set:    " + .style.set,
  "  ownership:    " + (.style.ownership // "(not a restyle)"),
  "  output:       " + .output.output,
  "  precedence:   " + ([.precedence[] | .layer] | join(" > ")),
  (if (.inputs.requirement != null and (.inputs.requirement.overrides | length) > 0)
     then "  overrides:",
          (.inputs.requirement.overrides[] | "    - " + .key + " = " + .value + "  (outranks " + (.shadowed | join(", ")) + ")")
     else empty end),
  "  protected:    source verified unchanged (" + .source.sha256[0:12] + "…)"
' <<<"$plan"
