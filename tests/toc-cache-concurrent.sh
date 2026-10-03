#!/usr/bin/env bash
# Two real TOC suites may run together without sharing artifacts or staging.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
mkdir -p "$ROOT/tests/.out"
WORK="$(mktemp -d "$ROOT/tests/.out/toc-concurrent.XXXXXX")"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[[ -x "$PS" ]] || { echo 'toc-cache-concurrent: native PowerShell required'; exit 1; }
cat > "$WORK/driver" <<'SH'
#!/usr/bin/env bash
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  if [[ "${args[i]}" == -File && "${args[i+1]}" == *wordflow-toc-test*probe.ps1 ]]; then
    dir="$(dirname "$(wslpath -u "${args[i+1]}")")"
    flock "$TOC_EVENTS.lock" bash -c 'printf "%s\n" "$1" >> "$2"' bash "$dir" "$TOC_EVENTS"
  fi
done
exec /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -WindowStyle Hidden "${args[@]}"
SH
chmod +x "$WORK/driver"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
pids=()
for run in 1 2; do
  TOC_EVENTS="$WORK/stages" WF_POWERSHELL="$WORK/driver" bash "$ROOT/tests/toc-cache.sh" > "$WORK/run-$run.log" 2>&1 & pids+=("$!")
done
for run in 1 2; do
  wait "${pids[run-1]}"; check "concurrent run $run succeeds" "$?" 0
  summary="$(sed -n 's/^TOC cache: .* | \([0-9]*\) skipped$/\1/p' "$WORK/run-$run.log")"
  check "concurrent run $run has zero native skips" "$summary" 0
done
check 'each invocation has its own Windows staging directory' "$(sort -u "$WORK/stages" | wc -l | tr -d ' ')" 2
outputs="$(sed -n 's/^Artifacts: //p' "$WORK"/run-*.log | sort -u | wc -l | tr -d ' ')"
check 'each invocation has its own artifact directory' "$outputs" 2
remaining=0
while IFS= read -r dir; do [[ ! -e "$dir" ]] || remaining=$((remaining+1)); done < <(sort -u "$WORK/stages")
check 'both invocations remove only their own staging' "$remaining" 0
printf 'toc-cache-concurrent: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
