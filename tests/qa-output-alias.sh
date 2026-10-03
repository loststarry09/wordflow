#!/usr/bin/env bash
# QA must prove the delivered file is distinct from every declared source.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/qa-output-alias.XXXXXX")"
SRC="$WORK/source.docx"; OUT="$WORK/source-排版.docx"
cp "$ROOT/tests/fixtures/styles/standard-style-set.docx" "$SRC"
"$ROOT/scripts/wf-intake.sh" --source "$SRC" --output "$OUT" --plan "$WORK/plan.json" --json > "$WORK/intake.json"
before="$(sha256sum "$SRC")"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
run() {
  local name="$1" expected="$2"; shift 2
  "$ROOT/scripts/wf-qa.sh" --output "$OUT" "$@" --no-compat --json > "$WORK/$name.json" 2> "$WORK/$name.err"
  local rc=$?
  check "$name exit" "$rc" "$([[ "$expected" == fail ]] && echo 1 || echo 0)"
  check "$name identity check" "$(jq -r '.checks[] | select(.id=="output-is-new-file") | .status' "$WORK/$name.json")" "$expected"
}
for alias in symlink hardlink; do
  rm -f "$OUT"
  if [[ "$alias" == symlink ]]; then ln -s "$SRC" "$OUT"; else ln "$SRC" "$OUT"; fi
  run "$alias-plan" fail --plan "$WORK/plan.json"
  run "$alias-source" fail --source "$SRC"
done
rm -f "$OUT"; cp "$SRC" "$OUT"
run distinct-copy pass --source "$SRC" --plan "$WORK/plan.json"
mkdir "$WORK/sub"; ln -s "$WORK" "$WORK/parent-link"
for variant in dot parent-symlink hardlink symlink; do
  case "$variant" in
    dot) declared="$WORK/sub/../source.docx" ;;
    parent-symlink) declared="$WORK/parent-link/source.docx" ;;
    hardlink) declared="$WORK/declared-hard.docx"; ln "$SRC" "$declared" ;;
    symlink) declared="$WORK/declared-sym.docx"; ln -s "$SRC" "$declared" ;;
  esac
  jq --arg p "$declared" '.output.output=$p' "$WORK/plan.json" > "$WORK/$variant-plan.json"
  run "$variant-declared-output" fail --plan "$WORK/$variant-plan.json"
done
# A forged plan pointing to a distinct copy cannot conceal the actual alias.
ln "$SRC" "$WORK/alternate-source.docx"
run explicit-source-alias fail --source "$OUT" --plan "$WORK/plan.json"
jq --arg p "$OUT" '.source.path=$p' "$WORK/plan.json" > "$WORK/forged-source.json"
run actual-vs-plan-source fail --plan "$WORK/forged-source.json"
check 'source bytes unchanged' "$(sha256sum "$SRC")" "$before"
printf 'qa-output-alias: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
