#!/usr/bin/env bash
#
# WordFlow template adoption (#27).
#
# Adopts a supplied template's LOOK on a source document (spec
# `docs/spec/v0.1.md` §D1, §D2, §D5). A template contributes *look only*:
# theme fonts, style definitions, and section page setup. It never contributes
# content — no body text, pictures, tables, or header/footer text — and this
# operation copies none.
#
# Precedence (spec §D2, highest first):
#
#   formatting requirement  >  template  >  source document's own styles
#                           >  WordFlow standard styles  >  WordFlow defaults
#
# The template therefore outranks the source's own style definitions: a style
# the template defines is (re)defined on the output, sharing the template's
# property values. A formatting requirement's machine-applicable overrides win
# over the template, so they are applied last.
#
# The source is never modified (ADR-0003): the source bytes are copied to --out
# and only that new file is changed, through OfficeCLI. The byte copy is a file
# duplication, not a DOCX read or write; every DOCX operation still goes through
# OfficeCLI.
#
# Verification (asserted through OfficeCLI, not by trusting the write):
#   * the template's body text and running header/footer text never appear in
#     the output (the source's content is byte-for-byte the same text);
#   * every applied style's defined properties read back equal to the template's;
#   * the page setup reads back equal to the template's, on every section;
#   * the source's sha256 is unchanged across the whole job.
# Anything read from the template that this primitive cannot express is recorded
# as unverified rather than silently dropped. Any risk decision is routed through
# `scripts/wf-risk-policy.sh` (#30); no D11 code is hardcoded here.
#
# Normative rules: references/core/template-adoption.md
#
# Usage:
#   scripts/wf-template.sh <source.docx> --template <tpl.docx> --out <output.docx>
#                          [--requirement <file>] [--report <r.json>] [--json]
#
# Exit codes: 0 = adopted and verified; 1 = OfficeCLI read/write failure, or a
#             verification failure; 2 = bad usage / missing dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISK="$SCRIPT_DIR/wf-risk-policy.sh"
CHANGE_REPORT="$SCRIPT_DIR/wf-change-report.sh"
readonly TOOL='wf-template.sh'
readonly TMO='timeout 60'

usage() {
  cat <<'EOF'
Usage: wf-template.sh <source.docx> --template <tpl.docx> --out <output.docx>
                      [--requirement <file>] [--report <r.json>] [--json]

Adopt a template's look on a source document: theme fonts, style definitions,
and section page setup — never its content (body text, images, tables, or
header/footer text). The template outranks the source's own styles; a formatting
requirement (--requirement) outranks the template. The source is never modified.

Options:
  --template <file>     Template whose look is adopted (required).
  --out <file>          New output document (required; must differ from source).
  --requirement <file>  Written formatting requirement. Lines "key = value" or
                        "key: value" are machine-applicable overrides (the same
                        convention as scripts/wf-intake.sh); other non-blank
                        lines are notes.
  --report <r.json>     Also write a change report (five areas, #28) at this path.
  --json                Emit the report as JSON instead of text.
  -h, --help            Show this help.

Exit codes: 0 adopted and verified; 1 OfficeCLI or verification failure;
            2 bad usage / missing dependency.
EOF
}

SRC=''; TPL=''; OUT=''; REQ=''; REPORT=''; JSON=0
while (($#)); do
  case "$1" in
    --template)    (($# >= 2)) || { echo "--template requires a file argument" >&2; exit 2; }; TPL="$2"; shift 2 ;;
    --out)         (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --requirement) (($# >= 2)) || { echo "--requirement requires a file argument" >&2; exit 2; }; REQ="$2"; shift 2 ;;
    --report)      (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --json)        JSON=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)             [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$TPL" ]] || { echo "--template is required (template adoption needs a template)" >&2; usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -f "$TPL" ]] || { echo "template not found: $TPL" >&2; exit 2; }
[[ -z "$REQ" || -f "$REQ" ]] || { echo "requirement not found: $REQ" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for tool in "$RISK" "$CHANGE_REPORT"; do
  [[ -x "$tool" ]] || { echo "missing or non-executable capability: $tool" >&2; exit 2; }
done

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
tpl_abs="$(abs "$TPL")"
out_abs="$(abs "$OUT")"
# shellcheck source=scripts/lib/source-protection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/source-protection.sh"
wf_guard_destination --out "$OUT" "$SRC" "$TPL"
wf_guard_destination --report "$REPORT" "$SRC" "$OUT" "$TPL"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }
[[ "$tpl_abs" != "$out_abs" ]] || { echo "--out must differ from the template (never modify the template)" >&2; exit 2; }
if [[ -n "$REPORT" ]]; then
  report_abs="$(abs "$REPORT")"
  [[ "$report_abs" != "$src_abs" && "$report_abs" != "$tpl_abs" && "$report_abs" != "$out_abs" ]] \
    || { echo "--report must not point at an input or the output" >&2; exit 2; }
  [[ -d "$(dirname "$report_abs")" ]] || { echo "report directory not found: $(dirname "$report_abs")" >&2; exit 2; }
else
  report_abs=""
fi

# --- source protection: hash before ANY read/write --------------------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"
tpl_sum="$(sha256sum "$tpl_abs" | awk '{print $1}')"

cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$tpl_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

die_runtime() { echo "$TOOL: $*" >&2; exit 1; }

# --- collected report entries ----------------------------------------------
declare -a changed_entries=() decisions_entries=() unverified_entries=() warning_entries=()
declare -a evidence=()
declare -a adopted_styles=()

warn_unsupported() { # warn_unsupported <json-response> <prefix>
  local resp="$1" prefix="$2" msg
  while IFS= read -r msg; do
    [[ -n "$msg" ]] && unverified_entries+=("$prefix: $msg")
  done < <(jq -r '.warnings[]?.message // empty' <<<"$resp" 2>/dev/null || true)
}

# --- 1. adopt the template's style definitions ------------------------------
tpl_styles_json="$($TMO officecli get "$tpl_abs" /styles --json)"
jq -e '.success == true' <<<"$tpl_styles_json" >/dev/null 2>&1 \
  || die_runtime "OfficeCLI could not read styles from the template $TPL"
out_styles_json="$($TMO officecli get "$out_abs" /styles --json)"
jq -e '.success == true' <<<"$out_styles_json" >/dev/null 2>&1 \
  || die_runtime "OfficeCLI could not read styles from $SRC"

mapfile -t tpl_style_ids < <(jq -r '.data.results[].children[]? | select(.type=="style") | .format.styleId // empty' <<<"$tpl_styles_json")
declare -A out_has_style=()
while IFS= read -r sid; do
  [[ -n "$sid" ]] && out_has_style["$sid"]=1
done < <(jq -r '.data.results[].children[]? | select(.type=="style") | .format.styleId // empty' <<<"$out_styles_json")

default_style='Normal'
theme_ok=false

for id in "${tpl_style_ids[@]}"; do
  [[ -n "$id" ]] || continue
  fmt="$($TMO officecli get "$tpl_abs" "/styles/$id" --json | jq -c '.data.results[0].format // {}')"
  s_name="$(jq -r '.name // ""' <<<"$fmt")"
  s_type="$(jq -r '.type // "paragraph"' <<<"$fmt")"
  s_default="$(jq -r '.default // "false"' <<<"$fmt")"
  s_custom="$(jq -r '.customStyle // ""' <<<"$fmt")"
  if [[ "$s_default" == "true" ]]; then default_style="$id"; fi

  declare -a props=() char_props=()
  s_ascii="$(jq -r '.font.ascii // ""' <<<"$fmt")"
  s_hansi="$(jq -r '.font.hAnsi // ""' <<<"$fmt")"

  while IFS=$'\t' read -r k v; do
    case "$k" in
      id|styleId|type|default|customStyle|basedOn.path|effective.*|*.path) continue ;;
      font.ascii) props+=(--prop "font.latin=$v") ;;
      font.hAnsi) continue ;;
      *Chars)     char_props+=(--prop "$k=$v") ;;
      *)          props+=(--prop "$k=$v") ;;
    esac
  done < <(jq -r 'to_entries[] | select(.value | type == "string" or type == "number" or type == "boolean") | "\(.key)\t\(.value)"' <<<"$fmt")

  if [[ -n "$s_hansi" && -n "$s_ascii" && "$s_hansi" != "$s_ascii" ]]; then
    unverified_entries+=("template style '$id': separate ascii/hAnsi Latin faces are not expressible (ascii='$s_ascii', hAnsi='$s_hansi'); the ascii face was used")
  fi

  if [[ -n "${out_has_style[$id]:-}" ]]; then
    if ((${#props[@]})); then
      resp="$($TMO officecli set "$out_abs" "/styles/$id" "${props[@]}" --json 2>/dev/null || true)"
      warn_unsupported "$resp" "template style '$id'"
    fi
  else
    declare -a add_args=(/styles --type style --prop "styleId=$id")
    [[ -n "$s_type" ]] && add_args+=(--prop "type=$s_type")
    [[ -n "$s_custom" ]] && add_args+=(--prop "customStyle=$s_custom")
    [[ "$s_default" == "true" ]] && add_args+=(--prop "default=true")
    if ((${#props[@]})); then add_args+=("${props[@]}"); fi
    resp="$($TMO officecli add "$out_abs" "${add_args[@]}" --json 2>/dev/null || true)"
    warn_unsupported "$resp" "template style '$id'"
    out_has_style["$id"]=1
  fi
  if ((${#char_props[@]})); then
    resp="$($TMO officecli set "$out_abs" "/styles/$id" "${char_props[@]}" --json 2>/dev/null || true)"
    warn_unsupported "$resp" "template style '$id'"
  fi

  adopted_styles+=("$(jq -nc --arg id "$id" --arg name "$s_name" --arg type "$s_type" --argjson default "$([[ "$s_default" == "true" ]] && echo true || echo false)" \
    '{style_id:$id, name:$name, type:$type, default:$default}')")
done

adopted_json='[]'
if ((${#adopted_styles[@]})); then
  adopted_json="$(printf '%s\n' "${adopted_styles[@]}" | jq -s -c .)"
fi
tpl_style_count="${#adopted_styles[@]}"
if ((tpl_style_count > 0)); then
  changed_entries+=("Template adoption: defined ${tpl_style_count} style definition(s) from the template — $(jq -r 'map(.style_id) | join(", ")' <<<"$adopted_json").")
fi
decisions_entries+=("Template adoption: the template outranks the source document's own styles for every styleId the template defines (spec §D5.3).")

# --- 2. adopt the template's theme (theme fonts) ----------------------------
theme_cmds="$($TMO officecli dump "$tpl_abs" /theme --format batch --json 2>/dev/null | jq -c '.data // empty' 2>/dev/null || true)"
if [[ -n "$theme_cmds" && "$theme_cmds" != "null" && "$theme_cmds" != "[]" ]]; then
  theme_resp="$($TMO officecli batch "$out_abs" --commands "$theme_cmds" --json 2>/dev/null || true)"
  if jq -e '.success == true and ((.data.summary.failed // 0) == 0)' <<<"$theme_resp" >/dev/null 2>&1; then
    theme_ok=true
    changed_entries+=("Template adoption: copied the template's theme part (theme fonts and colour scheme).")
  else
    unverified_entries+=("template theme: the theme part could not be adopted from the template")
  fi
fi

# --- 3. adopt the template's section page setup -----------------------------
tpl_sec_fmt="$($TMO officecli query "$tpl_abs" section --json | jq -c '.data.results[0].format // {}')"
if [[ "$tpl_sec_fmt" == "{}" ]]; then
  tpl_sec_fmt="$($TMO officecli get "$tpl_abs" / --json | jq -c '.data.results[0].format // {}')"
fi
tpl_root_fmt="$($TMO officecli get "$tpl_abs" / --json | jq -c '.data.results[0].format // {}')"

section_prop_names=(pageWidth pageHeight orientation marginTop marginBottom marginLeft marginRight marginHeader marginFooter marginGutter)
# Keys this primitive adopts, and keys that are page setup but owned by their own
# step / not a template-look item (silently excluded, not reported as unadopted).
adopted_section_keys='^(pageWidth|pageHeight|orientation|marginTop|marginBottom|marginLeft|marginRight|marginHeader|marginFooter|marginGutter)$'
nonlook_section_keys='^(type|sectionType|docGrid\..*|pageNumFmt|pageStart|titlePage|direction|rtlGutter|columns|columnSpace|columns\..*)$'

declare -a page_props=()
for k in "${section_prop_names[@]}"; do
  v="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$tpl_sec_fmt")"
  [[ -n "$v" ]] && page_props+=(--prop "$k=$v")
done
# A template that leaves orientation implicit is portrait.
if ! jq -e 'has("orientation")' <<<"$tpl_sec_fmt" >/dev/null 2>&1; then
  page_props+=(--prop "orientation=portrait")
fi

mapfile -t out_sections < <($TMO officecli query "$out_abs" section --json | jq -r '.data.results[].path')
((${#out_sections[@]} > 0)) || die_runtime "no sections found in $SRC"
for p in "${out_sections[@]}"; do
  $TMO officecli set "$out_abs" "$p" "${page_props[@]}" >/dev/null \
    || die_runtime "OfficeCLI could not set page setup on $p"
done

# Document grid (CJK layout) is a document-level property when the template sets it.
docgrid_type="$(jq -r '."docGrid.type" // ""' <<<"$tpl_root_fmt")"
if [[ -n "$docgrid_type" ]]; then
  $TMO officecli set "$out_abs" / --prop "docGrid.type=$docgrid_type" >/dev/null \
    || unverified_entries+=("template document grid: docGrid.type='$docgrid_type' could not be adopted")
fi

# Anything else the template's section carries that this primitive does not
# adopt is recorded, not silently dropped.
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  [[ "$k" =~ $adopted_section_keys ]] && continue
  [[ "$k" =~ $nonlook_section_keys ]] && continue
  unverified_entries+=("template section property '$k' was not adopted (this primitive owns page size, orientation, and margins)")
done < <(jq -r 'keys[]' <<<"$tpl_sec_fmt")

changed_entries+=("Template adoption: page setup from the template — $(jq -r '"\(."pageWidth" // "?") x \(."pageHeight" // "?") \(."orientation" // "portrait"), margins top/bottom \(."marginTop" // "?") / \(."marginBottom" // "?") and left/right \(."marginLeft" // "?") / \(."marginRight" // "?")"' <<<"$tpl_sec_fmt") applied to ${#out_sections[@]} section(s).")

# A multi-column template section is a limited construct (spec §D9): warn via the
# shared policy, and record that it was not adopted.
tpl_columns="$(jq -r '.columns // empty' <<<"$tpl_sec_fmt")"
if [[ "$tpl_columns" =~ ^[0-9]+$ ]] && (( tpl_columns > 1 )); then
  col_detail="the template uses a ${tpl_columns}-column section layout"
  col_decision="$($TMO "$RISK" decide --trigger columns --detail "$col_detail" --json 2>/dev/null || true)"
  col_entry="$(jq -r '.entry // empty' <<<"$col_decision" 2>/dev/null || true)"
  [[ -n "$col_entry" ]] && warning_entries+=("$col_entry")
  unverified_entries+=("template section property 'columns' ($tpl_columns) was not adopted: multi-column layout is limited (spec §D9)")
fi

# --- 4. apply the formatting requirement (outranks the template) ------------
req_applied='[]'
req_given=0
req_section_ov='{}'
req_style_ov='{}'
if [[ -n "$REQ" ]]; then
  req_given=1
  req_path="$(abs "$REQ")"
  parsed="$(jq -R -s '
    split("\n")
    | map(sub("\r$"; ""))
    | map(sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))
    | map(select((. == "") or startswith("#") | not))
    | map( . as $line
           | (($line | capture("^(?<key>[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)*)[[:space:]]*[:=][[:space:]]*(?<value>.*)$")) // null) as $c
           | if $c == null then {note:$line}
             else {key:$c.key, value:($c.value | sub("[[:space:]]+$"; ""))} end)
    | { overrides: ([ .[] | select(has("key")) ] | group_by(.key) | map(.[-1])),
        notes:     [ .[] | select(has("note")) | .note ] }
  ' "$req_path")"
  req_overrides="$(jq -c '.overrides' <<<"$parsed")"
  req_section_ov="$(jq -c '[.[] | select(.key | test("^(pageWidth|pageHeight|orientation|marginTop|marginBottom|marginLeft|marginRight|marginHeader|marginFooter|marginGutter)$"))] | from_entries' <<<"$req_overrides")"
  req_style_ov="$(jq -c '[.[] | select(.key | test("^(pageWidth|pageHeight|orientation|marginTop|marginBottom|marginLeft|marginRight|marginHeader|marginFooter|marginGutter)$") | not)] | from_entries' <<<"$req_overrides")"

  declare -a sec_override_props=() style_override_props=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    case "$k" in
      pageWidth|pageHeight|orientation|marginTop|marginBottom|marginLeft|marginRight|marginHeader|marginFooter|marginGutter)
        sec_override_props+=(--prop "$k=$v") ;;
      *)
        style_override_props+=(--prop "$k=$v") ;;
    esac
  done < <(jq -r '.[] | "\(.key)\t\(.value)"' <<<"$req_overrides")

  if ((${#sec_override_props[@]})); then
    for p in "${out_sections[@]}"; do
      resp="$($TMO officecli set "$out_abs" "$p" "${sec_override_props[@]}" --json 2>/dev/null || true)"
      warn_unsupported "$resp" "formatting-requirement (section)"
    done
  fi
  if ((${#style_override_props[@]})); then
    if [[ -z "${out_has_style[$default_style]:-}" ]]; then default_style='Normal'; fi
    resp="$($TMO officecli set "$out_abs" "/styles/$default_style" "${style_override_props[@]}" --json 2>/dev/null || true)"
    warn_unsupported "$resp" "formatting-requirement (style '$default_style')"
  fi

  while IFS= read -r note; do
    [[ -n "$note" ]] && unverified_entries+=("formatting-requirement note (read as intent, not applied): $note")
  done < <(jq -r '.notes[]?' <<<"$parsed")

  req_applied="$(jq -r '[.[] | "\(.key)=\(.value)"]' <<<"$req_overrides")"
  if (($(jq -r 'length' <<<"$req_overrides") > 0)); then
    decisions_entries+=("Formatting requirement: $(jq -r 'length' <<<"$req_overrides") override(s) applied after the template and won over it (spec §D2): $(jq -r '[.[] | "\(.key)=\(.value)"] | join(", ")' <<<"$req_overrides").")
    changed_entries+=("Formatting requirement: applied $(jq -r 'length' <<<"$req_overrides") machine-applicable override(s) over the template's look.")
  fi
fi

# --- 5. verify the external result through OfficeCLI ------------------------
out_styles_final="$($TMO officecli get "$out_abs" /styles --json)"
jq -e '.success == true' <<<"$out_styles_final" >/dev/null 2>&1 \
  || die_runtime "OfficeCLI could not read styles back from $OUT"

style_match=false
mismatch=""
for id in "${tpl_style_ids[@]}"; do
  [[ -n "$id" ]] || continue
  t_fmt="$($TMO officecli get "$tpl_abs" "/styles/$id" --json | jq -Sc '.data.results[0].format // {}')"
  o_fmt="$($TMO officecli get "$out_abs" "/styles/$id" --json | jq -Sc '.data.results[0].format // {}')"
  # Compare every property the template defines (ignoring get-only resolved paths);
  # source-only leftovers on a shared styleId are tolerated (documented merge limit).
  # `customStyle` is add-only and cannot be changed on an existing style, so it
  # is excluded; it is gallery metadata, not the template's look.
  d="$(jq -n --argjson t "$t_fmt" --argjson o "$o_fmt" --argjson ov "$req_style_ov" '
    [ $t | to_entries[]
      | select(.key | test("(^|\\.)path$") | not)
      | select(.key | test("^effective\\.") | not)
      | select(.key != "customStyle")
      | (($ov[.key] // .value)) as $ev
      | select($o[.key] == $ev) ]
    | length')"
  t_count="$(jq -n --argjson t "$t_fmt" '
    [ $t | to_entries[] | select(.key | test("(^|\\.)path$") | not)
      | select(.key | test("^effective\\.") | not)
      | select(.key != "customStyle") ] | length')"
  if [[ "$d" != "$t_count" ]]; then
    mismatch+="$id "
  fi
done
[[ -z "$mismatch" ]] && style_match=true

# Page setup reads back equal to the template on every section.
sec_match=true
for p in "${out_sections[@]}"; do
  o_fmt="$($TMO officecli query "$out_abs" section --json | jq -c --arg p "$p" '.data.results[] | select(.path==$p) | .format')"
  for k in pageWidth pageHeight marginTop marginBottom marginLeft marginRight; do
    tv="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$tpl_sec_fmt")"
    ev="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$req_section_ov")"
    [[ -n "$ev" ]] || ev="$tv"
    [[ -n "$ev" ]] || continue
    ov="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$o_fmt")"
    [[ "$ev" == "$ov" ]] || sec_match=false
  done
done

# Content isolation: the output's body text and running parts equal the source's.
src_text="$($TMO officecli view "$src_abs" text 2>/dev/null || true)"
out_text="$($TMO officecli view "$out_abs" text 2>/dev/null || true)"
source_content_intact=false
[[ "$src_text" == "$out_text" ]] && source_content_intact=true

hf_of() { # hf_of <file> <header|footer> -> one text per part, newline-joined
  $TMO officecli query "$1" "$2" --json 2>/dev/null | jq -r '[.data.results[]?.text // ""] | join("\u0001")'
}
src_header="$(hf_of "$src_abs" header)"; src_footer="$(hf_of "$src_abs" footer)"
out_header="$(hf_of "$out_abs" header)"; out_footer="$(hf_of "$out_abs" footer)"
source_parts_intact=false
[[ "$src_header" == "$out_header" && "$src_footer" == "$out_footer" ]] && source_parts_intact=true

template_content_absent=false
if [[ "$source_content_intact" == true && "$source_parts_intact" == true ]]; then
  template_content_absent=true
fi

val_json="$($TMO officecli validate "$out_abs" --json 2>/dev/null || true)"
output_valid=false
jq -e '.success == true' <<<"$val_json" >/dev/null 2>&1 && output_valid=true

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
tpl_sum_after="$(sha256sum "$tpl_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true
template_unchanged=false
[[ "$tpl_sum" == "$tpl_sum_after" ]] && template_unchanged=true

if [[ "$source_unchanged" != true ]]; then die_runtime "the source changed during the job (ADR-0003)"; fi
if [[ "$template_unchanged" != true ]]; then die_runtime "the template changed during the job"; fi
if [[ "$template_content_absent" != true ]]; then die_runtime "template content leaked into the output or source content changed"; fi
if [[ "$style_match" != true ]]; then die_runtime "adopted style(s) do not read back as the template's: ${mismatch}"; fi
if [[ "$sec_match" != true ]]; then die_runtime "page setup does not read back as the template's"; fi
if [[ "$output_valid" != true ]]; then die_runtime "the output failed OfficeCLI validation: $OUT"; fi

evidence+=("officecli get <out> /styles --json — ${#adopted_styles[@]} template style(s) defined and read back equal to the template's")
evidence+=("officecli query <out> section --json — template page setup verified on ${#out_sections[@]} section(s)")
evidence+=("officecli view <out> text — body text identical to the source (no template body content)")
evidence+=("officecli query <out> header|footer --json — running parts identical to the source (no template header/footer content)")
evidence+=("officecli validate <out> — schema valid")
evidence+=("sha256 <src> unchanged across the job")

declare -a change_report=("${changed_entries[@]}" "${decisions_entries[@]}" "${unverified_entries[@]}" "${warning_entries[@]}")

# --- 6. optional change report file (#28) -----------------------------------
if [[ -n "$report_abs" ]]; then
  $TMO "$CHANGE_REPORT" new --source "$src_abs" --output "$out_abs" --out "$report_abs" >/dev/null \
    || die_runtime "failed to create change report at $report_abs"
  for e in "${changed_entries[@]}"; do $TMO "$CHANGE_REPORT" add --report "$report_abs" --area changed --entry "$e" >/dev/null; done
  for e in "${decisions_entries[@]}"; do $TMO "$CHANGE_REPORT" add --report "$report_abs" --area decisions --entry "$e" >/dev/null; done
  for e in "${unverified_entries[@]}"; do $TMO "$CHANGE_REPORT" add --report "$report_abs" --area unverified --entry "$e" >/dev/null; done
  if [[ -n "$tpl_columns" ]] && [[ "$tpl_columns" =~ ^[0-9]+$ ]] && (( tpl_columns > 1 )); then
    $TMO "$RISK" emit --report "$report_abs" --trigger columns --detail "the template uses a ${tpl_columns}-column section layout" >/dev/null \
      || die_runtime "failed to record the multi-column warning in $report_abs"
  fi
  $TMO "$CHANGE_REPORT" validate --report "$report_abs" >/dev/null || die_runtime "malformed change report: $report_abs"
fi

# --- 7. emit ----------------------------------------------------------------
if ((JSON)); then
  jq -nc \
    --arg source "$src_abs" --arg output "$out_abs" --arg template "$tpl_abs" \
    --argjson source_unchanged "$source_unchanged" \
    --argjson template_unchanged "$template_unchanged" \
    --argjson adopted "$adopted_json" \
    --argjson page_setup "$tpl_sec_fmt" \
    --argjson theme_adopted "$theme_ok" \
    --argjson requirement "$(if ((req_given)); then jq -nc --argjson applied "$req_applied" '{given:true, applied:$applied}'; else echo null; fi)" \
    --arg report "$report_abs" \
    --argjson verification "$(jq -nc \
        --argjson a "$template_content_absent" --argjson b "$source_content_intact" \
        --argjson c "$source_parts_intact" --argjson d "$output_valid" --argjson e "$style_match" --argjson f "$sec_match" \
        '{template_content_absent:$a, source_content_intact:$b, source_parts_intact:$c, output_valid:$d, styles_read_back:$e, page_setup_read_back:$f}')" \
    --argjson change_report "$(printf '%s\n' "${change_report[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
    --argjson evidence "$(printf '%s\n' "${evidence[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" '
    { source: $source, output: $output, template: $template,
      source_unchanged: $source_unchanged, template_unchanged: $template_unchanged,
      styles_adopted: $adopted, styles_adopted_count: ($adopted | length),
      page_setup: $page_setup, theme_adopted: $theme_adopted,
      requirement: $requirement, report: (if ($report|length)>0 then $report else null end),
      verification: $verification,
      change_report: $change_report, evidence: $evidence }'
  exit 0
fi

jq -r '
  def list: if length == 0 then "(none)" else join(", ") end;
  "WordFlow template adoption",
  "  source:            " + .source,
  "  template:          " + .template,
  "  output:            " + .output,
  "  styles adopted:    " + ([.styles_adopted[].style_id] | list),
  "  page setup:        " + (.page_setup.pageWidth // "?") + " x " + (.page_setup.pageHeight // "?")
                          + " " + (.page_setup.orientation // "portrait")
                          + ", margins T/B " + (.page_setup.marginTop // "?") + " / " + (.page_setup.marginBottom // "?")
                          + " L/R " + (.page_setup.marginLeft // "?") + " / " + (.page_setup.marginRight // "?"),
  "  theme adopted:     " + (if .theme_adopted then "yes" else "no" end),
  "  requirement:       " + (if .requirement == null then "(none)" else (.requirement.applied | list) end),
  "  source unchanged:  " + (if .source_unchanged then "yes" else "no" end),
  "  template content absent: " + (if .verification.template_content_absent then "yes" else "no" end),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$(jq -nc \
    --arg source "$src_abs" --arg output "$out_abs" --arg template "$tpl_abs" \
    --argjson source_unchanged "$source_unchanged" \
    --argjson adopted "$adopted_json" \
    --argjson page_setup "$tpl_sec_fmt" \
    --argjson theme_adopted "$theme_ok" \
    --argjson requirement "$(if ((req_given)); then jq -nc --argjson applied "$req_applied" '{given:true, applied:$applied}'; else echo null; fi)" \
    --argjson verification "$(jq -nc \
        --argjson a "$template_content_absent" \
        '{template_content_absent:$a}')" \
    --argjson change_report "$(printf '%s\n' "${change_report[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')" '
    { source:$source, output:$output, template:$template, source_unchanged:$source_unchanged,
      styles_adopted:$adopted, page_setup:$page_setup, theme_adopted:$theme_adopted,
      requirement:$requirement, verification:$verification, change_report:$change_report }')"
