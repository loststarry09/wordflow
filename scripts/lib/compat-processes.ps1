# Native ownership ledger and supervisor. Never enumerate processes to kill.
param(
  [ValidateSet('Library','Supervise','Cleanup')][string]$Mode='Library',
  [string]$OwnerDir,[string]$Probe,[string]$ProgId,[string]$Path,[string]$Out,
  [int]$MaxFields=200,[int]$Timeout=120
)
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WordFlowProcess {
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
}
'@
function Save-Owner($Process,[string]$Role,[string]$Proof,[string]$ScriptPath='') {
  $r=[ordered]@{pid=$Process.Id;started_ticks=$Process.StartTime.ToUniversalTime().Ticks;
    name=$Process.ProcessName;role=$Role;proof=$Proof;script=$ScriptPath;owner_dir=$OwnerDir}
  $file=Join-Path $OwnerDir ("{0}.{1}.owner.json" -f $r.pid,$r.started_ticks)
  [IO.File]::WriteAllText(($file+'.tmp'),($r | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding $false))
  Move-Item -Force ($file+'.tmp') $file
}
function Own-ComApplication($App,$Doc,[string]$Image,$Before,[datetime]$Activation) {
  # Link the claim to this exact COM object, never to a process-list difference.
  [uint32]$appPid=0
  [void][WordFlowProcess]::GetWindowThreadProcessId([IntPtr][int64]$Doc.ActiveWindow.Hwnd,[ref]$appPid)
  if ($appPid -eq 0) { throw 'COM process identity unavailable' }
  $p=Get-Process -Id $appPid
  if ($p.ProcessName -ine $Image -or $Before -contains $appPid -or
      $p.StartTime.ToUniversalTime() -lt $Activation -or $App.Documents.Count -ne 1) {
    throw 'COM instance is shared or ownership cannot be established'
  }
  Save-Owner $p 'application' 'com-window'
}
function Clear-OwnedProcesses {
  $files=@(Get-ChildItem -LiteralPath $OwnerDir -Filter '*.owner.json')
  # Stop the application first; then the worker. The supervisor cleans itself
  # only after it exits, from the shell's final ledger sweep.
  foreach ($file in ($files | Sort-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).role })) {
    $r=Get-Content $file.FullName -Raw | ConvertFrom-Json
    if ($r.pid -eq $PID) { continue }
    $audit=$file.FullName.Replace('.owner.json','.cleanup.json')
    if (Test-Path $audit) { continue }
    $action='already-exited'
    $p=Get-Process -Id $r.pid -ErrorAction SilentlyContinue
    if ($null -ne $p) {
      # Pin a kernel handle before checking creation time. Terminate that handle
      # rather than issuing a PID-only taskkill vulnerable to PID reuse.
      $handle=$p.Handle
      if ($r.owner_dir -cne $OwnerDir -or $p.StartTime.ToUniversalTime().Ticks -ne $r.started_ticks -or
          $p.ProcessName -ine $r.name) { $action='identity-mismatch' }
      elseif ($r.role -in @('supervisor','worker')) {
        $cmd=(Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $r.pid)).CommandLine
        if ($r.proof -ne 'driver-script' -or -not $cmd.Contains($r.script) -or -not $cmd.Contains($OwnerDir)) {
          $action='ownership-refused'
        } elseif ([WordFlowProcess]::TerminateProcess($handle,1)) { $action='terminated' }
        else { $action='terminate-failed' }
      } elseif ($r.role -eq 'application' -and $r.proof -eq 'com-window' -and $r.name -in @('WINWORD','wps')) {
        if ([WordFlowProcess]::TerminateProcess($handle,1)) { $action='terminated' } else { $action='terminate-failed' }
      } else { $action='ownership-refused' }
      if ($action -eq 'terminated') { [void]$p.WaitForExit(10000) }
      $p.Dispose()
    }
    [IO.File]::WriteAllText($audit,(@{pid=$r.pid;role=$r.role;action=$action} | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding $false))
  }
}
if ($Mode -eq 'Cleanup') { Clear-OwnedProcesses; exit }
if ($Mode -eq 'Supervise') {
  Save-Owner (Get-Process -Id $PID) 'supervisor' 'driver-script' $PSCommandPath
  $stdout=Join-Path $OwnerDir 'worker.stdout'; $stderr=Join-Path $OwnerDir 'worker.stderr'
  # Start-Process returns the actual process created here. The worker registers
  # itself too, before COM activation; no unrelated PowerShell is claimed.
  $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Probe+'"'),
    '-OwnerDir',('"'+$OwnerDir+'"'),'-ProgId',$ProgId,'-Path',('"'+$Path+'"'),
    '-Out',('"'+$Out+'"'),'-MaxFields',$MaxFields)
  $worker=Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  Save-Owner $worker 'worker' 'driver-script' $Probe
  $timedOut=$false
  try { $timedOut=-not $worker.WaitForExit($Timeout*1000) }
  finally { Clear-OwnedProcesses; $worker.Dispose() }
  if ($timedOut) { exit 124 }
  if (Test-Path $stdout) { Get-Content $stdout -Raw }
}
