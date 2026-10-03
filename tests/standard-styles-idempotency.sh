#!/usr/bin/env bash
# Existing standard styleIds and the tool's own output are valid rebuild inputs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/styles-idempotency.XXXXXX")"
SRC="$WORK/source.docx"; cp "$ROOT/tests/fixtures/styles/standard-style-set.docx" "$SRC"
TOOL="$ROOT/scripts/wf-standard-styles.sh"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
styles() {
  officecli get "$1" /styles --json | jq -Sc '[.data.results[].children[]? | select(.type=="style") | .format] | sort_by(.styleId)'
}
officecli add "$SRC" /styles --type style --prop styleId=CustomLayout --prop name=CustomLayout --prop size=11 --prop color=AA1122 >/dev/null
officecli set "$SRC" /styles/Heading1 --prop size=9 --prop font.ea=SimSun >/dev/null
custom_before="$(officecli get "$SRC" /styles/CustomLayout --json | jq -Sc '.data.results[0].format')"
source_before="$(sha256sum "$SRC")"
text_before="$(officecli view "$SRC" text)"
"$TOOL" "$SRC" --out "$WORK/first.docx" --json > "$WORK/first.json" 2> "$WORK/first.err"; rc=$?
check 'existing standard IDs rebuild succeeds' "$rc" 0
first_before="$(sha256sum "$WORK/first.docx")"
"$TOOL" "$WORK/first.docx" --out "$WORK/second.docx" --json > "$WORK/second.json" 2> "$WORK/second.err"; rc=$?
check 'own output rebuild succeeds' "$rc" 0
check 'styles unchanged on second run' "$(styles "$WORK/second.docx")" "$(styles "$WORK/first.docx")"
check 'standard IDs appear exactly once' "$(officecli get "$WORK/second.docx" /styles --json | jq -r '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | length == (unique | length)')" true
check 'existing Heading1 receives standard size' "$(officecli get "$WORK/second.docx" /styles/Heading1 --json | jq -r '.data.results[0].format.size')" 16pt
check 'unrelated style properties preserved' "$(officecli get "$WORK/second.docx" /styles/CustomLayout --json | jq -Sc '.data.results[0].format')" "$custom_before"
check 'content preserved' "$(officecli view "$WORK/second.docx" text)" "$text_before"
check 'source byte-identical' "$(sha256sum "$SRC")" "$source_before"
check 'first output byte-identical after rerun' "$(sha256sum "$WORK/first.docx")" "$first_before"
check 'second output schema valid' "$(officecli validate "$WORK/second.docx" --json | jq -r .success)" true
printf 'styles-idempotency: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
