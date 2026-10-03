#!/usr/bin/env bash
# Table correctness at the CLI + independently observed DOCX boundary.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/table-correctness.XXXXXX")"
SRC="$WORK/source.docx"; cp "$ROOT/tests/fixtures/styles/unstyled.docx" "$SRC"
TOOL="$ROOT/scripts/wf-table.sh"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
widths() {
  officecli get "$1" "$2" --json | jq -r '.data.results[0].format | [.width, (.colWidths | gsub("dxa";"") | split(",") | map(tonumber) | add)] | @tsv'
}
before="$(sha256sum "$SRC")"
for sample in mismatch-too-few mismatch-too-many ragged trailing-row embedded-comma nested-mismatch nested-ragged; do
  args=(--data 'A,B;1,2' --col-widths '1000,1000')
  case "$sample" in
    mismatch-too-few) args=(--data 'A,B,C;1,2,3' --col-widths '1000,1000' --width 2000) ;;
    mismatch-too-many) args=(--data 'A,B;1,2' --col-widths '1000,1000,1000') ;;
    ragged) args=(--data 'A,B;1' --col-widths '1000,1000') ;;
    trailing-row) args=(--data 'A,B;1,2;' --col-widths '1000,1000') ;;
    embedded-comma) args=(--data 'Smith, John' --col-widths 2000) ;;
    nested-mismatch) args+=(--nested-cell '1,1' --nested-data 'x,y,z' --nested-col-widths '500,500') ;;
    nested-ragged) args+=(--nested-cell '1,1' --nested-data 'x,y;z' --nested-col-widths '500,500') ;;
  esac
  "$TOOL" "$SRC" --out "$WORK/$sample.docx" --report "$WORK/$sample.json" "${args[@]}" > "$WORK/$sample.stdout" 2> "$WORK/$sample.stderr"; rc=$?
  check "$sample rejected" "$rc" 2
  check "$sample no output" "$([[ -e "$WORK/$sample.docx" ]] && echo exists || echo absent)" absent
  check "$sample no report" "$([[ -e "$WORK/$sample.json" ]] && echo exists || echo absent)" absent
done

# Permitted rounding of a requested length must still yield exact actual widths.
"$TOOL" "$SRC" --out "$WORK/rounded.docx" --data 'A,B;1,2' --col-widths '1000,1000' --width 2001 \
  --nested-cell 1,1 --nested-data 'x,y' --nested-col-widths '500,500' --nested-width 1001 > "$WORK/rounded.stdout" 2> "$WORK/rounded.stderr"; rc=$?
check 'rounding run succeeds' "$rc" 0
check 'outer actual width equals actual column sum' "$(widths "$WORK/rounded.docx" /body/tbl[1])" $'2000\t2000'
check 'nested actual width equals actual column sum' "$(widths "$WORK/rounded.docx" /body/tbl[1]/tr[1]/tc[1]/tbl[1])" $'1000\t1000'

# Fault injection at the external OfficeCLI boundary changes the actual DOCX,
# rather than faking its evidence. A successful add cannot substitute for QA.
mkdir "$WORK/bin"
export WF_REAL_OFFICECLI; WF_REAL_OFFICECLI="$(command -v officecli)"
cat > "$WORK/bin/officecli" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$WF_REAL_OFFICECLI" "$@"
if [[ "$1" == add && " $* " == *' --type table '* ]]; then
  if [[ "$WF_TABLE_FAULT" == outer && "$3" == /body || "$WF_TABLE_FAULT" == nested && "$3" != /body ]]; then
    "$WF_REAL_OFFICECLI" raw-set "$2" /document --xpath '(//w:tbl)[last()]/w:tblPr/w:tblW' \
      --action replace --xml '<w:tblW w:w="9999" w:type="dxa"/>' >/dev/null
  fi
fi
SH
chmod +x "$WORK/bin/officecli"
for level in outer nested existing; do
  args=(--data 'A,B' --col-widths '1000,1000')
  [[ "$level" == nested ]] && args+=(--nested-cell '1,1' --nested-data 'x,y' --nested-col-widths '500,500')
  input="$SRC"; fault="$level"
  if [[ "$level" == existing ]]; then input="$ROOT/tests/fixtures/tables/fixed-table.docx"; fault=outer; fi
  WF_TABLE_FAULT="$fault" PATH="$WORK/bin:$PATH" "$TOOL" "$input" --out "$WORK/fault-$level.docx" \
    --report "$WORK/fault-$level.json" --json "${args[@]}" > "$WORK/fault-$level.stdout" 2> "$WORK/fault-$level.stderr"; rc=$?
  check "$level actual mismatch fails the job" "$rc" 1
  check "$level no success JSON" "$([[ -s "$WORK/fault-$level.stdout" ]] && echo emitted || echo absent)" absent
  check "$level no false equality claim" "$(jq -r '[.changed[],.decisions[]] | any(contains("tblW =="))' "$WORK/fault-$level.json")" false
done
"$TOOL" "$ROOT/tests/fixtures/tables/fixed-table.docx" --out "$WORK/existing.docx" --data 'A,B;1,2' \
  --col-widths '1000,1000' --header-row --json > "$WORK/existing.json" 2> "$WORK/existing.err"; rc=$?
check 'existing source table: run succeeds' "$rc" 0
check 'report describes newly built table' "$(jq -r '.table | [.rows,.grid_cols,.width] | @tsv' "$WORK/existing.json")" $'2\t2\t2000'
check 'new table gets requested header' "$(officecli get "$WORK/existing.docx" /body/tbl[2]/tr[1] --json | jq -r '.data.results[0].format.header // false')" true
check 'source byte-identical' "$(sha256sum "$SRC")" "$before"
printf 'table-correctness: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
