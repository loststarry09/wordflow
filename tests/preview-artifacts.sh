#!/usr/bin/env bash
# Acceptance's filesystem assertion must reject invented/missing preview paths.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/preview-artifacts.sh
source "$ROOT/tests/lib/preview-artifacts.sh"
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/preview-artifacts.XXXXXX")"
printf 'page one\n' > "$WORK/one.png"; printf 'page two\n' > "$WORK/two with spaces.png"
touch "$WORK/empty.png"; mkdir "$WORK/directory"
pass=0; fail=0
check() {
  local got=false
  wf_preview_artifacts_exist "$2" && got=true
  if [[ "$got" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$got"; fail=$((fail+1))
  fi
}
metadata() { jq -nc --args '{preview:{disabled:false,artifacts:$ARGS.positional}}' "$@"; }
check 'every real non-empty artifact accepted' "$(metadata "$WORK/one.png" "$WORK/two with spaces.png")" true
check 'missing artifact rejected' "$(metadata "$WORK/missing.png")" false
check 'empty artifact rejected' "$(metadata "$WORK/empty.png")" false
check 'second missing artifact rejected' "$(metadata "$WORK/one.png" "$WORK/missing.png")" false
check 'empty list rejected' "$(metadata)" false
check 'directory is not an artifact' "$(metadata "$WORK/directory")" false
check 'invalid JSON rejected' 'not JSON' false
check 'non-string path rejected' '{"preview":{"artifacts":[true]}}' false
printf 'preview-artifacts: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
