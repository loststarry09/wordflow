#!/usr/bin/env bash
# A newly resolved REF must not certify unrelated stale fields as current.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/crossref-isolation.XXXXXX")"
SRC="$WORK/source.docx"; cp "$ROOT/tests/fixtures/fields/cached-cross-ref.docx" "$SRC"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
officecli add "$SRC" /body/p[1] --type field --prop fieldType=seq --prop name=Figure >/dev/null
officecli raw-set "$SRC" /document --xpath '//w:fldChar[@w:fldCharType="begin"]' \
  --action replace --xml '<w:fldChar w:fldCharType="begin" w:dirty="true" w:fldLock="true"/>' >/dev/null
original="$(officecli query "$SRC" field --json | jq -Sc '[.data.results[] | {instruction:.format.instruction,cache:.text}]')"
before="$(sha256sum "$SRC")"
stable="$(officecli get "$SRC" /body/p[3] --json | jq -r '.data.results[0].path')"
i=0
for para in /body/p[1] /body/p[3] "$stable"; do
  i=$((i+1)); out="$WORK/output-$i.docx"
  "$ROOT/scripts/wf-crossref.sh" "$SRC" --out "$out" --bookmark sec_intro --para "$para" --json \
    > "$WORK/run-$i.json" 2> "$WORK/run-$i.err"; rc=$?
  check "$para run succeeds" "$rc" 0
  fields="$(officecli query "$out" field --json)"
  check "$para unrelated caches and dirty flags preserved" \
    "$(jq -Sc '[.data.results[] | select(.format.dirty==true) | {instruction:.format.instruction,cache:.text}]' <<<"$fields")" "$original"
  check "$para only new REF is clean and resolved" \
    "$(jq -r '[.data.results[] | select(.format.instruction=="REF sec_intro" and .text=="Introduction" and (.format.dirty // false)==false)] | length' <<<"$fields")" 1
  check "$para unrelated lock flags preserved" \
    "$(officecli raw "$out" /document | grep -o 'w:fldLock="true"' | wc -l | tr -d ' ')" 3
  check "$para schema valid" "$(officecli validate "$out" --json | jq -r .success)" true
done
check 'source byte-identical' "$(sha256sum "$SRC")" "$before"
printf 'crossref-isolation: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
