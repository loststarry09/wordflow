#!/usr/bin/env bash
#
# Detect and print the versions of every application in WordFlow's committed
# compatibility matrix (#10):
#
#   * OfficeCLI          — `officecli --version`
#   * Microsoft Word     — COM `Word.Application`, `.Version` and `.Build`
#   * WPS Writer         — COM `KWPS.Application`, `.Version` and `.Build`
#   * LibreOffice Writer — `soffice --version`
#
# Word and WPS share one Windows COM automation server, so every COM call is
# serialised through the project-wide lock:
#
#   flock -w 1800 /tmp/wordflow-wincom.lock <command>
#
# A missing application is reported `unavailable`; the probe never invents or
# upgrades a version. This is detection, not a compatibility test.
#
# Requirements: officecli, jq on PATH; soffice for the LibreOffice row; WSL
# Windows interop + powershell.exe for Word/WPS (override with $WF_POWERSHELL).
#
# Usage:
#   tests/probes/detect-versions.sh           # human-readable matrix
#   tests/probes/detect-versions.sh --json    # machine-readable report on stdout
#
# Exit codes: 0 report produced (even when an application is unavailable);
#             2 bad usage or a missing required dependency.
#
set -euo pipefail

DEFAULT_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
COM_LOCK=/tmp/wordflow-wincom.lock
PS_BIN="${WF_POWERSHELL:-$DEFAULT_PS}"
TMO="${WF_VERSION_TIMEOUT:-90}"
JSON=0

usage() {
  cat <<'EOF'
usage: tests/probes/detect-versions.sh [--json]

  --json   print a `wordflow.version-probe/v1` report on stdout
  -h       show this help

Detects OfficeCLI, Microsoft Word (COM), WPS Writer (COM), and LibreOffice.
Word/WPS COM calls are serialised with:
  flock -w 1800 /tmp/wordflow-wincom.lock <command>
EOF
}

while (($#)); do
  case "$1" in
    --json)      JSON=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for bin in officecli jq; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

# --- OS facts --------------------------------------------------------------
KERNEL="$(uname -srm)"
DISTRO=""
if [[ -r /etc/os-release ]]; then
  DISTRO="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-}")"
fi

# --- OfficeCLI -------------------------------------------------------------
OCLI_RAW="$(officecli --version 2>/dev/null | head -1 || true)"
OCLI_VERSION="$(printf '%s' "$OCLI_RAW" | awk '{print $1}')"
OCLI_AVAILABLE=true
[[ -n "$OCLI_VERSION" ]] || OCLI_AVAILABLE=false

# --- LibreOffice -----------------------------------------------------------
LO_RAW=""
LO_VERSION=""
LO_BUILD=""
LO_AVAILABLE=false
if command -v soffice >/dev/null 2>&1; then
  LO_RAW="$(timeout "$TMO" soffice --version 2>/dev/null | head -1 || true)"
  LO_VERSION="$(printf '%s' "$LO_RAW" | awk '{print $2}')"
  LO_BUILD="$(printf '%s' "$LO_RAW" | awk '{print $3}')"
  if [[ -n "$LO_RAW" ]]; then LO_AVAILABLE=true; fi
fi

# --- Microsoft Word and WPS Writer (COM) -----------------------------------
WORD_AVAILABLE=false; WORD_VERSION=""; WORD_BUILD=""; WORD_ERROR="Windows COM interop unavailable"
WPS_AVAILABLE=false;  WPS_VERSION="";  WPS_BUILD="";  WPS_ERROR="Windows COM interop unavailable"
COM_OS=""
HAVE_WINDOWS=0
if [[ -x "$PS_BIN" ]]; then HAVE_WINDOWS=1; fi

STAGE_WSL=""
cleanup() { [[ -n "$STAGE_WSL" ]] && rm -rf "$STAGE_WSL" 2>/dev/null || true; return 0; }
trap cleanup EXIT

if ((HAVE_WINDOWS)); then
  STAGE_WSL="$(mktemp -d /mnt/c/temp/wordflow-version-probe.XXXXXX 2>/dev/null || true)"
  if [[ -z "$STAGE_WSL" ]]; then HAVE_WINDOWS=0; fi
fi

if ((HAVE_WINDOWS)); then
  p="${STAGE_WSL#/mnt/}"; drive="${p:0:1}"; rest="${p:1}"
  STAGE_WIN="${drive^^}:${rest//\//\\}"
  PS_WSL="$STAGE_WSL/versions.ps1"
  PS_WIN="$STAGE_WIN\\versions.ps1"

  cat >"$PS_WSL" <<'PS1'
$ErrorActionPreference = 'Continue'
$os = $null
try { $os = [string]([System.Environment]::OSVersion.VersionString) } catch {}
function Get-AppInfo([string]$progid) {
  $o = $null
  try {
    $o = New-Object -ComObject $progid
    $v = $null; $b = $null
    try { $v = [string]$o.Version } catch {}
    try { $b = [string]$o.Build } catch {}
    return [ordered]@{ available = $true; driver = $progid; version = $v; build = $b; error = $null }
  } catch {
    return [ordered]@{ available = $false; driver = $progid; version = $null; build = $null; error = $_.Exception.Message }
  } finally {
    if ($o -ne $null) {
      try { $o.Quit() } catch {}
      try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } catch {}
    }
  }
}
[ordered]@{
  os   = $os
  word = Get-AppInfo 'Word.Application'
  wps  = Get-AppInfo 'KWPS.Application'
} | ConvertTo-Json -Compress -Depth 6
PS1

  if COM_OUT="$(flock -w 1800 "$COM_LOCK" timeout "$TMO" "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS_WIN" 2>/dev/null)"; then
    COM_RC=0
  else
    COM_RC=$?
  fi
  COM_OUT="$(printf '%s' "$COM_OUT" | tr -d '\r')"
  COM_OS=""
  if ((COM_RC == 0)) && jq -e . >/dev/null 2>&1 <<<"$COM_OUT"; then
    COM_OS="$(jq -r '.os // empty' <<<"$COM_OUT")"
    WORD_AVAILABLE="$(jq -r '.word.available // false' <<<"$COM_OUT")"
    WORD_VERSION="$(jq -r '.word.version // ""' <<<"$COM_OUT")"
    WORD_BUILD="$(jq -r '.word.build // ""' <<<"$COM_OUT")"
    WORD_ERROR="$(jq -r '.word.error // ""' <<<"$COM_OUT")"
    WPS_AVAILABLE="$(jq -r '.wps.available // false' <<<"$COM_OUT")"
    WPS_VERSION="$(jq -r '.wps.version // ""' <<<"$COM_OUT")"
    WPS_BUILD="$(jq -r '.wps.build // ""' <<<"$COM_OUT")"
    WPS_ERROR="$(jq -r '.wps.error // ""' <<<"$COM_OUT")"
  else
    WORD_ERROR="COM probe failed or produced no JSON (exit ${COM_RC})"
    WPS_ERROR="$WORD_ERROR"
  fi
fi

# --- report ----------------------------------------------------------------
REPORT="$(jq -n \
  --arg schema "wordflow.version-probe/v1" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg kernel "$KERNEL" --arg distro "$DISTRO" \
  --arg ps "${PS_BIN}" --arg lock "$COM_LOCK" --arg com_os "$COM_OS" \
  --arg ocli_raw "$OCLI_RAW" --arg ocli "$OCLI_VERSION" --argjson ocli_avail "$OCLI_AVAILABLE" \
  --arg lo_raw "$LO_RAW" --arg lo "$LO_VERSION" --arg lo_b "$LO_BUILD" --argjson lo_avail "$LO_AVAILABLE" \
  --arg word_v "$WORD_VERSION" --arg word_b "$WORD_BUILD" --arg word_err "$WORD_ERROR" --argjson word_avail "$WORD_AVAILABLE" \
  --arg wps_v "$WPS_VERSION" --arg wps_b "$WPS_BUILD" --arg wps_err "$WPS_ERROR" --argjson wps_avail "$WPS_AVAILABLE" \
  '{
    schema: $schema,
    detected_utc: $date,
    environment: {
      kernel: $kernel,
      distro: (if $distro == "" then null else $distro end),
      windows: (if $com_os == "" then null else $com_os end),
      com_lock: $lock,
      powershell: (if $word_avail or $wps_avail then $ps else null end)
    },
    apps: {
      officecli: {
        available: $ocli_avail,
        version: (if $ocli == "" then null else $ocli end),
        raw: (if $ocli_raw == "" then null else $ocli_raw end),
        source: "officecli --version"
      },
      word: {
        available: $word_avail,
        version: (if $word_v == "" then null else $word_v end),
        build: (if $word_b == "" then null else $word_b end),
        error: (if $word_err == "" then null else $word_err end),
        driver: "Word.Application",
        source: "COM Word.Application .Version / .Build"
      },
      wps: {
        available: $wps_avail,
        version: (if $wps_v == "" then null else $wps_v end),
        build: (if $wps_b == "" then null else $wps_b end),
        error: (if $wps_err == "" then null else $wps_err end),
        driver: "KWPS.Application",
        source: "COM KWPS.Application .Version / .Build (best-effort; closed source)"
      },
      libreoffice: {
        available: $lo_avail,
        version: (if $lo == "" then null else $lo end),
        build: (if $lo_b == "" then null else $lo_b end),
        raw: (if $lo_raw == "" then null else $lo_raw end),
        source: "soffice --version"
      }
    }
  }')"

if ((JSON)); then
  printf '%s\n' "$REPORT"
  exit 0
fi

printf 'WordFlow version probe — %s\n' "$(jq -r '.detected_utc' <<<"$REPORT")"
printf '  %s\n  %s\n\n' "$KERNEL" "${DISTRO:-unknown distro}"

printf '%-15s %-14s %-18s %-6s %s\n' "APPLICATION" "VERSION" "BUILD" "AVAIL" "SOURCE"
printf '%-15s %-14s %-18s %-6s %s\n' "---------------" "--------------" "------------------" "-----" "------------------------------------------"
printf '%-15s %-14s %-18s %-6s %s\n' "OfficeCLI" \
  "$(jq -r '.apps.officecli.version // "unavailable"' <<<"$REPORT")" \
  "-" \
  "$(jq -r '.apps.officecli.available' <<<"$REPORT")" \
  "officecli --version"
printf '%-15s %-14s %-18s %-6s %s\n' "Microsoft Word" \
  "$(jq -r '.apps.word.version // "unavailable"' <<<"$REPORT")" \
  "$(jq -r '.apps.word.build // "-"' <<<"$REPORT")" \
  "$(jq -r '.apps.word.available' <<<"$REPORT")" \
  "COM Word.Application"
printf '%-15s %-14s %-18s %-6s %s\n' "WPS Writer" \
  "$(jq -r '.apps.wps.version // "unavailable"' <<<"$REPORT")" \
  "$(jq -r '.apps.wps.build // "-"' <<<"$REPORT")" \
  "$(jq -r '.apps.wps.available' <<<"$REPORT")" \
  "COM KWPS.Application (best-effort)"
printf '%-15s %-14s %-18s %-6s %s\n' "LibreOffice" \
  "$(jq -r '.apps.libreoffice.version // "unavailable"' <<<"$REPORT")" \
  "$(jq -r '.apps.libreoffice.build // "-"' <<<"$REPORT")" \
  "$(jq -r '.apps.libreoffice.available' <<<"$REPORT")" \
  "soffice --version"

printf '\nUnavailable detail:\n'
jq -r '.apps | to_entries[] | select(.value.available == false) | "  \(.key): \(.value.error // "not found")"' <<<"$REPORT"
printf '\nCOM lock: %s\n' "$COM_LOCK"
