#!/usr/bin/env bash
#
# WordFlow QA gate — the Definition-of-Done checklist (#31, spec §D14).
#
# One reproducible, executable gate over a *delivered* document and its job
# artifacts. It returns pass/fail per item and is non-zero if any item fails, so
# "done" is a check result, not a claim. It composes the existing capabilities;
# it reimplements none of them:
#
#   #28 scripts/wf-change-report.sh   report validity + warn/downgrade presence
#   #29 scripts/wf-render-preview.sh  preview-covers-the-final-output
#   #30 scripts/wf-risk-policy.sh     the expected risk codes for detected constructs
#   #2  scripts/wf-compat-harness.sh  the repair-free-open gate
#
# Checks (each pass / fail / skip):
#   schema                  officecli validate succeeds
#   no-dangling-styles      every referenced style is defined (styleId OR name)
#   fields-no-placeholder   no non-page field ships a placeholder cached result
#   toc-no-page-numbers     a TOC cache carries no page numbers (D9)
#   report-valid            the change report validates (five non-blank areas)
#   constructs-reported     every limited construction is in the report (D11)
#   preview-covers-output   the preview is of the final delivered output
#   source-unchanged        the plan proves the source bytes are unchanged
#   output-is-new-file      the output is a distinct new file
#   collision-safe-name     the output name is `-排版` / `-排版 (N)`
#   reproducible            a second run has an identical content digest
#   opens-without-repair    Word/WPS/LibreOffice open it repair-free (harness)
#
# Usage:
#   wf-qa.sh --output <docx> [--source <docx>] [--plan <json>] [--report <json>]
#            [--preview <json|file>] [--repro <docx>]
#            [--apps word,wps,libreoffice] [--no-compat] [--json]
#
# Exit codes: 0 = all applicable checks pass; 1 = one or more failed;
#             2 = usage / missing dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="$SCRIPT_DIR/wf-change-report.sh"
HARNESS="$SCRIPT_DIR/wf-compat-harness.sh"
RISK="$SCRIPT_DIR/wf-risk-policy.sh"
readonly TOOL="wf-qa.sh"
readonly TMO="timeout 60"

usage() {
  cat <<'EOF'
Usage: wf-qa.sh --output <docx> [options]

Run the WordFlow Definition-of-Done gate (spec D14) over a delivered document.

Arguments:
  --output <docx>            The delivered output to check (required).

Options:
  --source <docx>            The source document (cross-checked against --plan).
  --plan <json>              Job plan from scripts/wf-intake.sh (source protection,
                             output naming, collision).
  --report <json>            Change report from scripts/wf-change-report.sh.
  --preview <json|file>      Render-preview JSON (or a file containing it).
  --repro <docx>             A second run's output, to check reproducibility.
  --apps <list>              Applications for the repair-free gate
                             (default: word,wps,libreoffice; all requested apps required).
  --no-compat                Skip the repair-free-open gate.
  --json                     Emit a machine-readable result object.
  -h, --help                 Show this help.

Exit codes: 0 all applicable checks pass; 1 one or more failed; 2 usage/deps.
EOF
}

OUT=""; SRC=""; PLAN=""; REPORT=""; PREVIEW=""; REPRO=""
APPS="word,wps,libreoffice"; COMPAT=1; JSON=0
while (($#)); do
  case "$1" in
    --output)   (($# >= 2)) || { echo "--output requires a value" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --source)   (($# >= 2)) || { echo "--source requires a value" >&2; exit 2; }; SRC="$2"; shift 2 ;;
    --plan)     (($# >= 2)) || { echo "--plan requires a value" >&2; exit 2; }; PLAN="$2"; shift 2 ;;
    --report)   (($# >= 2)) || { echo "--report requires a value" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --preview)  (($# >= 2)) || { echo "--preview requires a value" >&2; exit 2; }; PREVIEW="$2"; shift 2 ;;
    --repro)    (($# >= 2)) || { echo "--repro requires a value" >&2; exit 2; }; REPRO="$2"; shift 2 ;;
    --apps)     (($# >= 2)) || { echo "--apps requires a value" >&2; exit 2; }; APPS="$2"; shift 2 ;;
    --no-compat) COMPAT=0; shift ;;
    --json)     JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)          echo "unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die_usage() { echo "$TOOL: $*" >&2; exit 2; }
[[ -n "$OUT" ]] || { usage >&2; exit 2; }
for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || die_usage "$bin not found on PATH"
done
[[ -f "$OUT" ]] || die_usage "output not found: $OUT"
[[ -z "$SRC" || -f "$SRC" ]] || die_usage "source not found: $SRC"
[[ -z "$PLAN" || -f "$PLAN" ]] || die_usage "plan not found: $PLAN"
[[ -z "$REPORT" || -f "$REPORT" ]] || die_usage "report not found: $REPORT"
[[ -z "$REPRO" || -f "$REPRO" ]] || die_usage "repro output not found: $REPRO"

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
out_abs="$(abs "$OUT")"
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# Release residents so the gate leaves no OfficeCLI process holding a document.
cleanup() {
  officecli close "$out_abs" >/dev/null 2>&1 || true
  [[ -n "$REPRO" ]] && officecli close "$(abs "$REPRO")" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

# --- result collection ------------------------------------------------------
declare -a R_ID R_STATUS R_DETAIL
pass_n=0; fail_n=0; skip_n=0
record() { # <id> <status> <detail>
  R_ID+=("$1"); R_STATUS+=("$2"); R_DETAIL+=("$3")
  case "$2" in
    pass) pass_n=$((pass_n + 1)) ;;
    fail) fail_n=$((fail_n + 1)) ;;
    skip) skip_n=$((skip_n + 1)) ;;
  esac
}
check() { # <id> <desc> <0|1> <detail>
  if [[ "$3" == "1" ]]; then record "$1" pass "$4"; else record "$1" fail "$4"; fi
}

# --- 1. schema --------------------------------------------------------------
val="$(  $TMO officecli validate "$out_abs" --json 2>/dev/null || echo '{}')"
if [[ "$(jq -r '.success // false' <<<"$val" 2>/dev/null || echo false)" == "true" ]]; then
  check schema "officecli validate" 1 "schema valid"
else
  check schema "officecli validate" 0 "officecli validate failed"
fi

# --- 2. dangling styles (styleId OR display name) ---------------------------
styles="$(  $TMO officecli get "$out_abs" /styles --json 2>/dev/null || echo '{}')"
stats="$(   $TMO officecli view "$out_abs" stats  --json 2>/dev/null || echo '{}')"
defined="$(jq -r '[.data.results[0].children[]? | select(.type=="style") | .format.styleId, .format.name] | .[] | ascii_downcase' <<<"$styles" 2>/dev/null || true)"
referenced="$(jq -r '.data.styleDistribution // {} | keys[] | ascii_downcase' <<<"$stats" 2>/dev/null || true)"
dangling_count="$(awk 'NR==FNR { if ($0 != "") def[$0]=1; next } $0 != "" && !($0 in def) { c++ } END { print c+0 }' \
  <(printf '%s\n' "$defined") <(printf '%s\n' "$referenced"))"
check no-dangling-styles "every referenced style is defined" \
  "$([[ "$dangling_count" == "0" ]] && echo 1 || echo 0)" "$dangling_count dangling style reference(s)"

# --- 3. field caches: no placeholder, judged by cached TEXT -----------------
field_json="$( $TMO officecli query "$out_abs" field --json 2>/dev/null || echo '{}')"
# page-dependent fields are layout-computed by the reader (D8/D14 carve-out)
placeholder_count="$(jq -r '
  [ .data.results[]?
    | select((.format.instruction // "") | test("PAGE|NUMPAGES|PAGEREF"; "i") | not)
    | select((.text // "") | test("«|»|update field|placeholder"; "i")) ]
  | length' <<<"$field_json" 2>/dev/null || echo 0)"
check fields-no-placeholder "no field ships a placeholder cache" \
  "$([[ "$placeholder_count" == "0" ]] && echo 1 || echo 0)" "$placeholder_count placeholder field(s)"

# --- 4. TOC carries no page numbers (frozen D9) -----------------------------
toc_json="$(  $TMO officecli query "$out_abs" toc --json 2>/dev/null || echo '{}')"
toc_count="$(jq -r '.data.matches // 0' <<<"$toc_json" 2>/dev/null || echo 0)"
if ! [[ "$toc_count" =~ ^[0-9]+$ ]] || (( toc_count == 0 )); then
  record toc-no-page-numbers skip "no TOC field present"
else
  # the field must be built without page numbers: `\z` (not `\n`) and format.pageNumbers=false
  toc_ok="$(jq -r '
    [ .data.results[]?
      | ((.format.pageNumbers // false) == false)
        and (((.text // "") | test("\\\\n")) | not) ]
    | all' <<<"$toc_json" 2>/dev/null || echo false)"
  check toc-no-page-numbers "TOC cache carries no page numbers" \
    "$([[ "$toc_ok" == "true" ]] && echo 1 || echo 0)" "$toc_count TOC field(s)"
fi

# --- 5. change report validates ---------------------------------------------
if [[ -n "$REPORT" ]]; then
  if "$CHANGE_REPORT" validate --report "$REPORT" >/dev/null 2>&1; then
    record report-valid pass "change report validates"
  else
    record report-valid fail "change report is missing or malformed"
  fi
fi

# --- 6. every limited construct is reported (no silent downgrade) -----------
# Codes come from the risk policy (#30) — never hardcoded here — so the trigger
# table stays defined once (see references/workflow/risk-policy.md).
risk_code() { "$RISK" decide --trigger "$1" "${@:2}" --json 2>/dev/null | jq -r '.code // ""' 2>/dev/null || true; }
detected=()
anchored="$($TMO officecli query "$out_abs" 'picture[anchor=true]' --json 2>/dev/null | jq -r '.data.matches // 0' 2>/dev/null || echo 0)"
if [[ "$anchored" =~ ^[0-9]+$ ]] && (( anchored > 0 )); then detected+=("$(risk_code floating-image)"); fi
# The semantic table selector omits nested tables in the verified OfficeCLI.
# tblPr gives every actual table path; read each table without a depth cutoff.
table_paths="$($TMO officecli query "$out_abs" tblPr --json 2>/dev/null \
  | jq -r '.data.results[]? | .path | select(contains("/tbl[")) | sub("/tblPr\\[[0-9]+\\]$"; "")' 2>/dev/null || true)"
tables_json="$(while IFS= read -r table_path; do
  [[ -n "$table_path" ]] || continue
  $TMO officecli get "$out_abs" "$table_path" --json 2>/dev/null \
    | jq -c '.data.results[]? | select(.type=="table")'
done <<<"$table_paths" | jq -sc '.')"
# A promoted nested construction needs the measured portable subset at every
# nesting level; do not invent a warning for the fully supported construction.
nested="$(jq -r '
  def portable:
    try (.format as $f
      | $f.layout=="fixed"
        and ($f.colWidths | length)>0
        and (($f.width | tonumber)==($f.colWidths | gsub("dxa";"") | split(",") | map(tonumber) | add))
        and (($f["border.top"] // "") | length)>0) catch false;
  . as $tables
  | [$tables[] | select(((.path // "") | split("/tbl[") | length)>2)
     | . as $nested
     | select(any($tables[];
         . as $table | ($nested.path==$table.path or ($nested.path | startswith($table.path+"/")))
         and (portable | not)))] | length
' <<<"$tables_json" 2>/dev/null || echo 0)"
if [[ "$nested" =~ ^[0-9]+$ ]] && (( nested > 0 )); then detected+=("$(risk_code nested-table)"); fi
sec_json="$($TMO officecli query "$out_abs" section --json 2>/dev/null || echo '{}')"
restart="$(jq -r '[.data.results[]? | select(.format.pageStart != null)] | length' <<<"$sec_json" 2>/dev/null || echo 0)"
if [[ "$restart" =~ ^[0-9]+$ ]] && (( restart > 0 )); then detected+=("$(risk_code page-number-restart)"); fi
columns="$(jq -r '[.data.results[]? | select(((.format.columns // 1) | tonumber)>1)] | length' <<<"$sec_json" 2>/dev/null || echo 0)"
if [[ "$columns" =~ ^[0-9]+$ ]] && (( columns > 0 )); then detected+=("$(risk_code columns)"); fi
pageref="$(jq -r '[.data.results[]? | select((.format.instruction // "") | test("^\\s*PAGEREF(\\s|$)"; "i"))] | length' <<<"$field_json" 2>/dev/null || echo 0)"
if [[ "$pageref" =~ ^[0-9]+$ ]] && (( pageref > 0 )); then
  detected+=("$(risk_code unverifiable-field --resolution state)")
fi

# Construct-specific equation risks: a bar survives in the read-back formula;
# parser-aligned matrices survive as the right/left pair of column justifications.
# Faithful matrices, true eqArr and promoted first/odd/even headers need no warning.
equations="$($TMO officecli query "$out_abs" equation --json 2>/dev/null || echo '{}')"
pipe_count="$(jq -r '[.data.results[]? | select((.text // "") | contains("|"))] | length' <<<"$equations" 2>/dev/null || echo 0)"
justifications="$($TMO officecli query "$out_abs" mcJc --json 2>/dev/null || echo '{}')"
aligned="$(jq -r '[.data.results[]?] | group_by(.path | split("/mc[")[0]) | any(.[]; [.[].format.val]==["right","left"])' <<<"$justifications" 2>/dev/null || echo false)"
if [[ "$aligned" == true ]] || { [[ "$pipe_count" =~ ^[0-9]+$ ]] && ((pipe_count > 0)); }; then
  detected+=("$(risk_code complex-equation)")
fi

if (( ${#detected[@]} == 0 )); then
  record constructs-reported skip "no limited construction detected in the output"
elif [[ -z "$REPORT" ]]; then
  record constructs-reported fail "detected ${detected[*]} but no --report was supplied (cannot prove it is reported)"
else
  missing=()
  for code in "${detected[@]}"; do
    if ! jq -e --arg c "$code" '((.warnings // []) + (.downgrades // []) + (.unverified // [])) | any(contains($c))' "$REPORT" >/dev/null 2>&1; then
      missing+=("$code")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    record constructs-reported pass "reported: ${detected[*]}"
  else
    record constructs-reported fail "silent construct(s): ${missing[*]}"
  fi
fi

# --- 7. preview covers the final output -------------------------------------
if [[ -n "$PREVIEW" ]]; then
  if [[ -f "$PREVIEW" ]]; then pj="$(cat "$PREVIEW")"; else pj="$PREVIEW"; fi
  if [[ "$(jq -r '.disabled // false' <<<"$pj" 2>/dev/null || echo false)" == "true" ]]; then
    record preview-covers-output skip "preview disabled by request"
  else
    pv_out="$(jq -r '.output // ""' <<<"$pj" 2>/dev/null || echo "")"
    check preview-covers-output "preview is of the delivered output" \
      "$([[ -n "$pv_out" && "$(abs "$pv_out")" == "$out_abs" ]] && echo 1 || echo 0)" \
      "preview output: ${pv_out:-<none>}"
  fi
fi

# --- 8. job-plan facts: source protection, new file, collision-safe name ----
if [[ -n "$PLAN" ]]; then
  unchanged="$(jq -r '.source.unchanged // false' "$PLAN" 2>/dev/null || echo false)"
  sb="$(jq -r '.source.sha256 // ""' "$PLAN" 2>/dev/null || echo "")"
  sa="$(jq -r '.source.sha256_after // ""' "$PLAN" 2>/dev/null || echo "")"
  plan_src="$(jq -r '.source.path // ""' "$PLAN" 2>/dev/null || echo "")"
  plan_out="$(jq -r '.output.output // ""' "$PLAN" 2>/dev/null || echo "")"
  src_ok=1; [[ "$unchanged" == "true" && -n "$sb" && "$sb" == "$sa" ]] || src_ok=0
  if [[ -n "$SRC" && "$(sha_of "$SRC")" != "$sb" ]]; then src_ok=0; fi
  check source-unchanged "the source bytes are unchanged" "$src_ok" "plan source.unchanged=$unchanged"
  base="$(basename "$plan_out")"
  name_ok=0; [[ "$base" =~ ^.+-排版( \([0-9]+\))?\.docx$ ]] && name_ok=1
  check collision-safe-name "output name is -排版 / -排版 (N)" "$name_ok" "name: ${base:-<none>}"
fi

# Inspect filesystem identity, including the real delivered file. Plan strings
# alone cannot prove ADR-0003, and --source also applies without a job plan.
if [[ -n "$PLAN" || -n "$SRC" ]]; then
  # shellcheck source=scripts/lib/source-protection.sh
  source "$SCRIPT_DIR/lib/source-protection.sh"
  new_ok=1
  if [[ -n "$PLAN" ]]; then
    [[ -n "$plan_src" && -f "$plan_src" && -n "$plan_out" ]] || new_ok=0
    wf_paths_alias "$OUT" "$plan_out" || new_ok=0
  fi
  for source_path in "${plan_src:-}" "$SRC"; do
    [[ -n "$source_path" ]] || continue
    if wf_paths_alias "$OUT" "$source_path" || wf_paths_alias "${plan_out:-}" "$source_path"; then
      new_ok=0
    fi
  done
  check output-is-new-file "the output is a distinct new file" "$new_ok" "output: $OUT"
fi

# --- 9. reproducibility -----------------------------------------------------
if [[ -n "$REPRO" ]]; then
  digest_of() {
    { $TMO officecli view "$1" text 2>/dev/null || true
      $TMO officecli view "$1" stats --json 2>/dev/null | jq -cS '.data.styleDistribution // {}' 2>/dev/null || true
    } | sha256sum | awk '{print $1}'
  }
  check reproducible "same instructions reproduce the same layout" \
    "$([[ "$(digest_of "$out_abs")" == "$(digest_of "$(abs "$REPRO")")" ]] && echo 1 || echo 0)" \
    "content digest comparison"
fi

# --- 10. repair-free open (harness #2) --------------------------------------
if (( COMPAT )); then
  hdir="$(mktemp -d "${TMPDIR:-/tmp}/wf-qa-compat.XXXXXX")"
  hj="$(  $TMO "$HARNESS" "$out_abs" --apps "$APPS" --out "$hdir" --timeout 90 --json 2>/dev/null || echo '{}')"
  rm -rf "$hdir"
  compat_fail=()
  IFS=',' read -r -a requested_apps <<<"$APPS"
  (( ${#requested_apps[@]} > 0 )) || compat_fail+=("<empty application list>")
  for app in "${requested_apps[@]}"; do
    app="${app//[[:space:]]/}"
    if ! jq -e --arg app "$app" '
        [.records[]? | select(.app==$app)]
        | length==1 and .[0].status=="ok" and .[0].opens_without_repair==true
      ' <<<"$hj" >/dev/null 2>&1; then
      compat_fail+=("${app:-<empty application>}")
    fi
  done
  if (( ${#compat_fail[@]} > 0 )); then
    record opens-without-repair fail "required application unavailable or not repair-free: ${compat_fail[*]}"
  else
    record opens-without-repair pass "repair-free in every requested app: $APPS"
  fi
else
  record opens-without-repair skip "compat gate disabled (--no-compat)"
fi

# --- report -----------------------------------------------------------------
ok=true; (( fail_n == 0 )) || ok=false

if (( JSON )); then
  jq -nc \
    --arg output "$out_abs" \
    --argjson ok "$ok" \
    --argjson pass "$pass_n" --argjson fail "$fail_n" --argjson skip "$skip_n" \
    --argjson checks "$(for i in "${!R_ID[@]}"; do
        jq -nc --arg id "${R_ID[$i]}" --arg status "${R_STATUS[$i]}" --arg detail "${R_DETAIL[$i]}" \
          '{id:$id,status:$status,detail:$detail}'; done | jq -sc '.')" \
    '{tool:"wf-qa.sh", output:$output, ok:$ok,
      summary:{pass:$pass, fail:$fail, skip:$skip}, checks:$checks}'
else
  echo "$TOOL — Definition of Done for $(basename "$out_abs")"
  for i in "${!R_ID[@]}"; do
    case "${R_STATUS[$i]}" in
      pass) printf '  \033[32mPASS\033[0m %-22s %s\n' "${R_ID[$i]}" "${R_DETAIL[$i]}" ;;
      fail) printf '  \033[31mFAIL\033[0m %-22s %s\n' "${R_ID[$i]}" "${R_DETAIL[$i]}" ;;
      skip) printf '  \033[33mSKIP\033[0m %-22s %s\n' "${R_ID[$i]}" "${R_DETAIL[$i]}" ;;
    esac
  done
  echo
  echo "QA: $((pass_n + fail_n + skip_n)) checks run | $pass_n passed | $fail_n failed | $skip_n skipped"
fi

(( fail_n == 0 )) || exit 1
