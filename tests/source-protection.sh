#!/usr/bin/env bash
# Shared public-CLI negative matrix: reject aliases before touching any input.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/source-protection.XXXXXX")"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }
alias_path() {
  local input="$1" kind="$2"
  case "$kind" in
    direct) ALIAS="$input" ;;
    dot) ALIAS="$(dirname "$input")/sub/../$(basename "$input")" ;;
    symlink) ALIAS="$CASE/alias"; ln -s "$input" "$ALIAS" ;;
    hardlink) ALIAS="$CASE/alias"; ln "$input" "$ALIAS" ;;
    parent-symlink) ln -s "$CASE" "$CASE/parent"; ALIAS="$CASE/parent/$(basename "$input")" ;;
  esac
}
run_case() {
  local tool="$1" flag="$2" kind="$3" expected="${4:-2}"
  [[ -z "${WF_PROTECTION_FILTER:-}" || "$tool" =~ $WF_PROTECTION_FILTER ]] || return 0
  CASE="$(mktemp -d "$WORK/case.XXXXXX")"; mkdir "$CASE/sub"
  SRC="$CASE/source file.docx"; cp "$ROOT/tests/fixtures/styles/unstyled.docx" "$SRC"
  TPL="$CASE/template.docx"; cp "$ROOT/tests/fixtures/styles/template.docx" "$TPL"
  REQ="$CASE/requirement.txt"; printf 'font: SimSun\n' > "$REQ"
  IMG="$CASE/image.png"; cp "$ROOT/tests/fixtures/assets/test-image.png" "$IMG"
  CONTENT="$CASE/content.md"; printf '# Title\n\nBody\n' > "$CONTENT"
  local target="$SRC"
  [[ "$flag" == *template ]] && target="$TPL"
  [[ "$flag" == *requirement ]] && target="$REQ"
  [[ "$flag" == *image ]] && target="$IMG"
  [[ "$flag" == *content ]] && target="$CONTENT"
  local -a args=()
  case "$tool" in
    wf-caption) args=("$SRC" --out "$CASE/out.docx" --kind figure --text Caption) ;;
    wf-crossref) args=("$SRC" --out "$CASE/out.docx" --bookmark target) ;;
    wf-equation) args=("$SRC" --out "$CASE/out.docx" --formula 'x=1') ;;
    wf-footnote) args=("$SRC" --out "$CASE/out.docx" --text Note) ;;
    wf-headers) args=("$SRC" --out "$CASE/out.docx" --header Header) ;;
    wf-image) args=("$SRC" --out "$CASE/out.docx" --image "$IMG") ;;
    wf-table) args=("$SRC" --out "$CASE/out.docx" --data 'A,B;1,2' --col-widths '1000,1000') ;;
    wf-template) args=("$SRC" --out "$CASE/out.docx" --template "$TPL") ;;
    wf-page-setup|wf-standard-styles|wf-tidy|wf-toc) args=("$SRC" --out "$CASE/out.docx") ;;
    wf-render-preview) args=("$SRC" --out "$CASE/preview" --format pdf) ;;
    wf-compat-harness) args=("$SRC" --out "$CASE/compat" --apps libreoffice --no-visual) ;;
    wf-intake|wf-pipeline) args=(--source "$SRC" --template "$TPL" --requirement "$REQ") ;;
    wf-output-name) args=("$SRC") ;;
    wf-change-report) args=(new --source "$SRC" --output "$CASE/out.docx") ;;
  esac
  [[ "$tool" == wf-pipeline ]] && args+=(--no-preview)
  if [[ "$flag" == *content ]]; then args=(--content "$CONTENT" --no-preview); fi
  if [[ "$flag" == *output-doc ]]; then target="$CASE/out.docx"; cp "$SRC" "$target"; fi
  # Reports can use arbitrary source names, including JSON; protect the file
  # identity even when the input is itself a valid change report.
  if [[ "$tool" == wf-change-report-add || "$tool" == wf-risk-policy ]]; then
    SRC="$CASE/source.json"; target="$SRC"
    jq -n --arg s "$SRC" --arg o "$CASE/out.docx" \
      '{source:$s,output:$o,changed:[],decisions:[],warnings:[],downgrades:[],unverified:[]}' > "$SRC"
    if [[ "$tool" == wf-change-report-add ]]; then
      args=(add --area changed --entry Test)
    else args=(emit --trigger columns); fi
  fi
  alias_path "$target" "$kind"
  local before identity rc script="${tool%-add}"
  before="$(sha "$target")"; identity="$(stat -c '%d:%i' "$target")"
  timeout 90 "$ROOT/scripts/$script.sh" "${args[@]}" "${flag%%:*}" "$ALIAS" > "$CASE/stdout" 2> "$CASE/stderr"
  rc=$?
  check "$tool $flag $kind exit" "$rc" "$expected"
  check "$tool $flag $kind source bytes" "$(sha "$target")" "$before"
  check "$tool $flag $kind source identity" "$(stat -c '%d:%i' "$target")" "$identity"
}

for tool in wf-caption wf-crossref wf-equation wf-footnote wf-headers wf-image wf-table wf-template wf-tidy wf-toc; do
  for flag in --out --report --report:output-doc; do
    for kind in direct dot symlink hardlink parent-symlink; do run_case "$tool" "$flag" "$kind"; done
  done
done

# --out directories contain actual write targets; checking the directory alone
# cannot protect a source aliased by an existing work copy or preview/report.
if [[ -z "${WF_PROTECTION_FILTER:-}" ]]; then
  for writer in preview-pdf preview-png compat-work compat-result pipeline-report-json pipeline-report-md pipeline-plan pipeline-input; do
    for kind in symlink hardlink; do
      CASE="$(mktemp -d "$WORK/artifact.XXXXXX")"; mkdir -p "$CASE/out/work"
      SRC="$CASE/source.docx"; cp "$ROOT/tests/fixtures/styles/unstyled.docx" "$SRC"
      args=(); tool=''
      case "$writer" in
        preview-pdf) destination="$CASE/out/source-preview.pdf"; tool=wf-render-preview; args=("$SRC" --out "$CASE/out" --format pdf) ;;
        preview-png) destination="$CASE/out/source-preview-1.png"; tool=wf-render-preview; args=("$SRC" --out "$CASE/out") ;;
        compat-work) destination="$CASE/out/work/source.docx"; tool=wf-compat-harness; args=("$SRC" --out "$CASE/out" --apps libreoffice --no-visual) ;;
        compat-result) destination="$CASE/out/result.json"; tool=wf-compat-harness; args=("$SRC" --out "$CASE/out" --apps libreoffice --no-visual) ;;
        pipeline-*)
          tool=wf-pipeline; args=(--source "$SRC" --output "$CASE/out/laid.docx" --no-preview)
          case "$writer" in
            pipeline-report-json) destination="$CASE/out/laid-report.json" ;;
            pipeline-report-md) destination="$CASE/out/laid-report.md" ;;
            pipeline-plan) destination="$CASE/out/laid-plan.json" ;;
            pipeline-input) destination="$CASE/out/input-source.docx" ;;
          esac ;;
      esac
      if [[ "$kind" == symlink ]]; then ln -s "$SRC" "$destination"; else ln "$SRC" "$destination"; fi
      before="$(sha "$SRC")"; identity="$(stat -c '%d:%i' "$SRC")"
      timeout 90 "$ROOT/scripts/$tool.sh" "${args[@]}" > "$CASE/stdout" 2> "$CASE/stderr"; rc=$?
      check "$writer $kind exit" "$rc" 2
      check "$writer $kind source bytes" "$(sha "$SRC")" "$before"
      check "$writer $kind source identity" "$(stat -c '%d:%i' "$SRC")" "$identity"
    done
  done
fi
for tool in wf-standard-styles wf-page-setup wf-render-preview wf-compat-harness wf-change-report; do
  for kind in direct dot symlink hardlink parent-symlink; do run_case "$tool" --out "$kind"; done
done
for tool in wf-render-preview wf-change-report-add wf-risk-policy; do
  for kind in direct dot symlink hardlink parent-symlink; do run_case "$tool" --report "$kind"; done
done
for kind in direct dot symlink hardlink parent-symlink; do
  run_case wf-intake --plan "$kind"
  run_case wf-intake --plan:template "$kind"
  run_case wf-intake --plan:requirement "$kind"
  run_case wf-pipeline --output "$kind"
  run_case wf-pipeline --output:template "$kind"
  run_case wf-pipeline --output:requirement "$kind"
  run_case wf-pipeline --output:content "$kind"
  run_case wf-template --out:template "$kind"
  run_case wf-template --report:template "$kind"
  run_case wf-image --out:image "$kind"
  run_case wf-image --report:image "$kind"
  run_case wf-output-name --output "$kind" 3
done
printf 'source-protection: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
