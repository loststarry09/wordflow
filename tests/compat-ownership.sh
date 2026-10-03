#!/usr/bin/env bash
# Observe real process survival and cleanup through the harness/driver boundary.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OFFICECLI_NO_AUTO_RESIDENT=1
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[[ -x "$PS" ]] || { echo 'compat-ownership: native PowerShell required'; exit 1; }
mkdir -p "$ROOT/tests/.out" /mnt/c/temp
WORK="$(mktemp -d "$ROOT/tests/.out/compat-ownership.XXXXXX")"
STAGE="$(mktemp -d /mnt/c/temp/wordflow-ownership-test.XXXXXX)"
WIN="$(wslpath -w "$STAGE")"
DOC="$ROOT/tests/fixtures/styles/standard-style-set.docx"
OCLI="$(command -v officecli)"
pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else
    printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; fail=$((fail+1))
  fi
}
cp "$DOC" "$STAGE/fixture.docx"
cat > "$STAGE/sleeper.ps1" <<'PS1'
$ErrorActionPreference='Stop'
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class SentinelWindow {
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
}
'@
$apps=@();$docs=@();$records=@()
try {
  foreach ($prog in @('Word.Application','KWPS.Application')) {
    $a=New-Object -ComObject $prog
    $d=$a.Documents.Open((Join-Path $PSScriptRoot 'fixture.docx'),$false,$true)
    [uint32]$id=0
    [void][SentinelWindow]::GetWindowThreadProcessId([IntPtr][int64]$d.ActiveWindow.Hwnd,[ref]$id)
    $p=Get-Process -Id $id
    $apps+=,$a;$docs+=,$d
    $records+=@{pid=$id;ticks=$p.StartTime.ToUniversalTime().Ticks}
  }
  $records | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'apps.json')
  for ($i=0;$i -lt 600 -and -not (Test-Path (Join-Path $PSScriptRoot 'stop'));$i++) { Start-Sleep -Seconds 1 }
} finally {
  foreach ($d in $docs) { try { $d.Close($false) } catch {} }
  foreach ($a in $apps) { try { $a.Quit() } catch {} }
}
PS1
cat > "$STAGE/sentinel.ps1" <<'PS1'
param([string]$Action,[string]$Root,[string]$Ledger)
$ErrorActionPreference='Stop'
$file=Join-Path $Root 'sentinel.json'
if ($Action -eq 'start') {
  $p=Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File',(Join-Path $Root 'sleeper.ps1')) -PassThru
  @{pid=$p.Id;ticks=$p.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content $file
  for ($i=0;$i -lt 60 -and -not (Test-Path (Join-Path $Root 'apps.json'));$i++) { Start-Sleep -Seconds 1 }
} else {
  $r=Get-Content $file -Raw | ConvertFrom-Json
  $p=Get-Process -Id $r.pid -ErrorAction SilentlyContinue
  $alive=($null -ne $p -and $p.StartTime.ToUniversalTime().Ticks -eq $r.ticks)
  if ($Action -eq 'stop' -and $alive) { New-Item (Join-Path $Root 'stop') -ItemType File -Force | Out-Null; if (-not $p.WaitForExit(15000)) { $p.Kill() } }
  $appAlive=0
  if (Test-Path (Join-Path $Root 'apps.json')) {
    foreach ($r in (Get-Content (Join-Path $Root 'apps.json') -Raw | ConvertFrom-Json)) {
      $a=Get-Process -Id $r.pid -ErrorAction SilentlyContinue
      if ($null -ne $a -and $a.StartTime.ToUniversalTime().Ticks -eq $r.ticks) { $appAlive++ }
    }
  }
  $ownedAlive=0
  if ($Ledger) {
    foreach ($f in Get-ChildItem $Ledger -Filter '*.owner.json') {
      if ($f.Name -like 'unrelated*') { continue }
      $r=Get-Content $f.FullName -Raw | ConvertFrom-Json
      $o=Get-Process -Id $r.pid -ErrorAction SilentlyContinue
      if ($null -ne $o -and $o.StartTime.ToUniversalTime().Ticks -eq $r.started_ticks) { $ownedAlive++ }
    }
  }
  @{alive=$alive;app_alive=$appAlive;owned_alive=$ownedAlive} | ConvertTo-Json -Compress
}
PS1
sentinel() { "$PS" -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "$WIN\sentinel.ps1" -Action "$1" -Root "$WIN" "${@:2}" | tr -d '\r'; }
trap 'sentinel stop >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/officecli" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == query && "$3" == field && ! -e "$OWNER_BARRIER" ]]; then
  touch "$OWNER_BARRIER"
  while [[ ! -e "$OWNER_RELEASE" ]]; do sleep .1; done
fi
exec "$OWNER_OFFICECLI" "$@"
SH
chmod +x "$WORK/bin/officecli"
# Launch the sentinel AFTER the old PID baseline, BEFORE the actual measurement.
PATH="$WORK/bin:$PATH" OWNER_OFFICECLI="$OCLI" OWNER_BARRIER="$WORK/barrier" OWNER_RELEASE="$WORK/release" \
  WF_POWERSHELL="$PS" "$ROOT/scripts/wf-compat-harness.sh" "$DOC" --apps libreoffice --no-visual \
    --out "$WORK/lo" --json > "$WORK/lo.json" 2> "$WORK/lo.err" & job=$!
for _ in {1..300}; do [[ -f "$WORK/barrier" ]] && break; sleep .1; done
check 'LO harness reached measurement barrier' "$([[ -f "$WORK/barrier" ]] && echo yes)" yes
sentinel start >/dev/null
touch "$WORK/release"
wait "$job"; check 'LO harness exits normally' "$?" 0
check 'independent late PowerShell survives LO cleanup' "$(sentinel status | jq -r .alive)" true
check 'independent late Word and WPS survive LO cleanup' "$(sentinel status | jq -r .app_alive)" 2

# The driver may stall after acquiring COM; owned identities must still be reaped.
cat > "$WORK/stall-driver" <<'SH'
#!/usr/bin/env bash
args=("$@")
mode=""; owner_dir=""
for ((i=0;i<${#args[@]};i++)); do
  [[ "${args[i]}" != -Mode ]] || mode="${args[i+1]}"
  [[ "${args[i]}" != -OwnerDir ]] || owner_dir="${args[i+1]}"
done
if [[ "$mode" == Cleanup ]]; then
  dir="$(wslpath -u "$owner_dir")"
  # Stale PID identity and an unrelated process with the right PID/time both
  # must be refused. The actual sentinel process remains alive throughout.
  python3 - "$dir" "$OWNER_SENTINEL" "$owner_dir" <<'PY'
import json,sys
from pathlib import Path
directory,source,native=sys.argv[1:]
r=json.loads(Path(source).read_text(encoding='utf-8-sig'))
for kind,ticks in [('stale',r['ticks']-1),('unowned',r['ticks'])]:
    row=dict(pid=r['pid'],started_ticks=ticks,name='powershell',role='worker',proof='driver-script',script='not-the-sentinel.ps1',owner_dir=native)
    Path(directory,f'unrelated-{kind}.owner.json').write_text(json.dumps(row))
PY
fi
for ((i=0;i<${#args[@]};i++)); do
  if [[ "${args[i]}" == -File ]]; then
    file="$(wslpath -u "${args[i+1]}")"
    # Fault injection at the public driver boundary, after app ownership is saved.
    if [[ "$file" == */compat-processes.ps1 || "$file" == */probe.ps1 ]]; then
      sed -i '/\$owned = \$true/a\  Start-Sleep -Seconds 600' "$(dirname "$file")/probe.ps1"
    fi
  fi
done
exec "$OWNER_PS" "${args[@]}"
SH
chmod +x "$WORK/stall-driver"
for app in word wps; do
  OWNER_PS="$PS" OWNER_SENTINEL="$STAGE/sentinel.json" WF_POWERSHELL="$WORK/stall-driver" "$ROOT/scripts/wf-compat-harness.sh" "$DOC" --apps "$app" \
    --timeout 15 --no-visual --out "$WORK/$app" --json > "$WORK/$app.json" 2> "$WORK/$app.err"
  check "$app stalled call reports timeout" "$(jq -r '.records[0].status' "$WORK/$app.json")" timeout
  check "$app cleanup keeps independent PowerShell" "$(sentinel status | jq -r .alive)" true
  check "$app cleanup keeps independent Word and WPS" "$(sentinel status | jq -r .app_alive)" 2
  # Ownership and cleanup are persisted even when the worker never returns JSON.
  ledger="$WORK/$app/processes"
  claims="$(jq -s '[.[] | select(.role=="application")] | length' "$ledger"/*.owner.json 2>/dev/null)"
  check "$app has exactly one identified COM process" "$claims" 1
  check "$app owned processes all gone" "$(jq -s '[.[] | select(.action=="terminated" or .action=="already-exited")] | length' "$ledger"/*.cleanup.json 2>/dev/null)" 3
  cp -r "$ledger" "$STAGE/$app-owners"
  check "$app owned identities actually exited" "$(sentinel status -Ledger "$WIN/${app}-owners" | jq -r .owned_alive)" 0
  check "$app rejects stale PID identity" "$(jq -r .action "$ledger/unrelated-stale.cleanup.json" 2>/dev/null)" identity-mismatch
  check "$app refuses an unrelated exact PID/time" "$(jq -r .action "$ledger/unrelated-unowned.cleanup.json" 2>/dev/null)" ownership-refused
done
sentinel stop >/dev/null
printf 'compat-ownership: %d passed, %d failed; evidence: %s\n' "$pass" "$fail" "$WORK"
((fail == 0))
