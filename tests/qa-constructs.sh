#!/usr/bin/env bash
# The gate detects current limited constructs independently of report metadata.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${WF_QA_TOOL:-$ROOT/scripts/wf-qa.sh}"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/qa-constructs.XXXXXX")"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
status() {
  "$TOOL" --output "$1" --no-compat --json "${@:2}" \
    | jq -r '.checks[] | select(.id=="constructs-reported") | .status'
}
for construct in floating-image nested-table nested-deep nested-parent-mismatch page-number-restart columns aligned pipe pageref; do
  [[ -z "${WF_CONSTRUCT_FILTER:-}" || "$construct" =~ $WF_CONSTRUCT_FILTER ]] || continue
  case "$construct" in
    floating-image) fixture=images/anchored-image.docx; trigger=floating-image ;;
    nested-table|nested-deep|nested-parent-mismatch) fixture=tables/nested-table.docx; trigger=nested-table ;;
    page-number-restart) fixture=sections/page-number-restart.docx; trigger=page-number-restart ;;
    columns) fixture=styles/unstyled.docx; trigger=columns ;;
    aligned) fixture=equations/aligned-equations.docx; trigger=complex-equation ;;
    pipe) fixture=equations/cases-equation.docx; trigger=complex-equation ;;
    pageref) fixture=fields/bookmark-ref-pageref.docx; trigger=unverifiable-field ;;
  esac
  doc="$WORK/$construct.docx"; cp "$ROOT/tests/fixtures/$fixture" "$doc"
  [[ "$construct" != columns ]] || officecli set "$doc" /section[1] --prop columns=2 >/dev/null
  if [[ "$construct" == nested-table ]]; then
    officecli set "$doc" /body/tbl[1]/tr[2]/tc[1]/tbl[1] --prop layout=autofit >/dev/null
  fi
  [[ "$construct" != nested-parent-mismatch ]] || officecli set "$doc" /body/tbl[1] --prop width=6803 >/dev/null
  if [[ "$construct" == nested-deep ]]; then
    host="/body/tbl[1]/tr[2]/tc[1]/tbl[1]/tr[1]/tc[1]"
    for level in 3 4; do
      officecli add "$doc" "$host" --type table --prop data="Deep $level" --prop colWidths=1000 \
        --prop width=1000 --prop layout=fixed --prop border.all='single;8;C00000' >/dev/null
      deep="$host/tbl[1]"; host="$deep/tr[1]/tc[1]"
    done
    check 'deep fully portable nested table needs no warning' "$(status "$doc")" skip
    officecli set "$doc" "$deep" --prop layout=autofit >/dev/null
  fi
  report="$WORK/$construct.json"
  "$ROOT/scripts/wf-change-report.sh" new --source original --output "$doc" --out "$report" >/dev/null
  check "$construct without report fails" "$(status "$doc")" fail
  check "$construct with empty report fails" "$(status "$doc" --report "$report")" fail
  args=(--trigger "$trigger" --detail "Construct-specific risk is stated")
  [[ "$construct" != pageref ]] || args+=(--resolution state)
  "$ROOT/scripts/wf-risk-policy.sh" emit --report "$report" "${args[@]}" >/dev/null
  check "$construct with risk entry passes" "$(status "$doc" --report "$report")" pass
done
# Promoted/safe constructions must retain their measured no-warning behavior.
for fixture in headers/firstpage-oddeven.docx equations/matrix-equation.docx equations/equation-array.docx equations/inline-equation.docx; do
  check "$fixture does not require an invented risk" "$(status "$ROOT/tests/fixtures/$fixture")" skip
done
check 'fully portable nested fixture does not require an invented risk' "$(status "$ROOT/tests/fixtures/tables/nested-table.docx")" skip
printf 'qa-constructs: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
