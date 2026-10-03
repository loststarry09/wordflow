#!/usr/bin/env bash
# Requested compatibility is a requirement; unavailable cannot become pass/skip.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/compat-required.XXXXXX")"
DOC="$ROOT/tests/fixtures/styles/standard-style-set.docx"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
for apps in word,wps libreoffice,word,wps; do
  name="${apps//,/__}"
  WF_POWERSHELL=/nonexistent/powershell.exe "$ROOT/scripts/wf-qa.sh" --output "$DOC" --apps "$apps" --json \
    > "$WORK/$name.json" 2> "$WORK/$name.err"; rc=$?
  check "$apps required: gate fails" "$rc" 1
  check "$apps required: compatibility fails rather than skips" \
    "$(jq -r '.checks[] | select(.id=="opens-without-repair") | .status' "$WORK/$name.json")" fail
done
WF_POWERSHELL=/nonexistent/powershell.exe "$ROOT/scripts/wf-qa.sh" --output "$DOC" --no-compat --json \
  > "$WORK/disabled.json" 2> "$WORK/disabled.err"; rc=$?
check 'explicit no-compat remains allowed' "$rc" 0
check 'explicit no-compat reports skip' "$(jq -r '.checks[] | select(.id=="opens-without-repair") | .status' "$WORK/disabled.json")" skip
WF_POWERSHELL=/nonexistent/powershell.exe "$ROOT/scripts/wf-compat-harness.sh" "$DOC" --apps word,wps --out "$WORK/measurement" --json \
  > "$WORK/measurement.json" 2> "$WORK/measurement.err"; rc=$?
check 'diagnostic harness still emits unavailable measurements' "$rc" 0
check 'diagnostic unavailable records are truthful' "$(jq -r '[.records[] | select(.status=="unavailable")] | length' "$WORK/measurement.json")" 2
WF_REQUIRE_COMPAT=1 WF_POWERSHELL=/nonexistent/powershell.exe bash "$ROOT/tests/compat-harness.sh" \
  > "$WORK/required-suite.log" 2>&1; rc=$?
check 'required acceptance suite fails without Word/WPS' "$rc" 1
printf 'compat-required: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
