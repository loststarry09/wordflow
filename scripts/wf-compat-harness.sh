#!/usr/bin/env bash
#
# WordFlow cross-application compatibility harness (#2).
#
# Takes one or more .docx documents through Microsoft Word, WPS Writer, and
# LibreOffice Writer and reports, per document/application:
#
#   * opens-without-repair  (the ADR-0004 hard gate)
#   * a rendered artifact   (per-application PDF export)
#   * a visual              (PNG derived from that PDF)
#   * field-cache findings  (each field's cached TEXT, not just its evaluated flag)
#
# This is a *measurement* tool, not a layout tool: it never writes the source
# and never inspects OOXML itself. Document-level field caches are read through
# OfficeCLI (ADR-0001); per-application caches are read from the live object
# model (Word/WPS COM). Word/WPS are driven read-only over COM; LibreOffice is
# driven headless. Every application is closed on exit, and any process the
# harness spawned is force-killed so no orphan lock survives the run.
#
# The output is machine-readable JSON (always written to <out>/result.json;
# printed to stdout with --json) plus a human summary. Per-document facts are
# also written to <out>/<doc>/document.json and every render is kept under
# <out>/<doc>/.
#
# Requirements:
#   * officecli >= 1.0.152, jq, coreutils (sha256sum/stat/base64) on PATH.
#   * LibreOffice (soffice) on PATH for the LibreOffice record; absent -> "unavailable".
#   * WSL with Windows interop and Microsoft Word / WPS Writer for those records;
#     absent -> "unavailable". Override the interpreter with $WF_POWERSHELL.
#   * pdftoppm (poppler-utils) to derive PNG visuals from each PDF; absent ->
#     the PDF is still captured and "visual" is null.
#   * Microsoft Word, WPS Writer, and LibreOffice are external prerequisites and
#     are never installed by this harness. They are driven through COM/headless
#     only; nothing here needs a manual one-off step.
#
# Usage:
#   scripts/wf-compat-harness.sh [<docx|glob|dir> ...] [options]
#
# Examples:
#   scripts/wf-compat-harness.sh tests/fixtures/toc/toc-basic.docx
#   scripts/wf-compat-harness.sh 'tests/fixtures/**/*.docx' --json
#   scripts/wf-compat-harness.sh --list fixtures.txt --apps libreoffice
#   scripts/wf-compat-harness.sh --all-fixtures --apps word,libreoffice
#
# Exit codes: 0 = report produced (even if some applications were unavailable);
#             1 = no documents to run; 2 = bad usage or a missing required
#             dependency. A per-application failure is reported in the JSON,
#             not signalled through the exit code.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
DEFAULT_TMO=120
DEFAULT_MAX_FIELDS=200
DEFAULT_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

usage() {
  cat <<'EOF'
Usage: wf-compat-harness.sh [<docx|glob|dir> ...] [options]

Run .docx documents through Word, WPS Writer, and LibreOffice Writer and report,
per document/application: opens-without-repair, a PDF render, a PNG visual, and
field-cache findings. Output is JSON (result.json) plus a human summary.

Arguments:
  <docx|glob|dir>   One or more documents. A directory expands to its *.docx
                    files; a quoted glob is expanded. Default: a small
                    representative fixture set.

Options:
  --list <file>       Read document paths from <file> (one per line, # comments).
  --all-fixtures      Run every .docx under tests/fixtures/ (bounded but larger).
  --apps <a,b,...>    Applications to drive. Subset of word,wps,libreoffice.
                      Default: all three.
  --out <dir>         Artifact directory. Default: tests/.out/compat/<timestamp>.
  --timeout <secs>    Per-application wall-clock bound. Default: 120.
  --max-fields <n>    Cap on per-application fields read via COM. Default: 200.
  --json              Print the JSON report to stdout instead of the summary.
  --no-visual         Do not derive PNG visuals (PDFs are still captured).
  --keep-staging      Keep the Windows staging directory (debugging).
  -h, --help          Show this help.

Environments:
  WF_POWERSHELL       Absolute path to powershell.exe. Default: the WSL path
                      /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe.

Status values (machine-readable):
  opens_without_repair : true | false | "unavailable" | "timeout"
  status               : ok | failed | unavailable | timeout
    ok          the application opened/rendered the document without an error
    failed      the application rejected the document (repair prompt / error)
    unavailable the application or its driver is not installed/reachable here
    timeout     the application did not finish within --timeout (e.g. a modal
                repair dialog on a corrupt file); it is reported, never guessed
EOF
}

# --- dependencies ----------------------------------------------------------
for bin in officecli jq base64 sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

PS_BIN="${WF_POWERSHELL:-$DEFAULT_PS}"
HAVE_WINDOWS=0
[[ -x "$PS_BIN" ]] && HAVE_WINDOWS=1
HAVE_SOFFICE=0
command -v soffice >/dev/null && HAVE_SOFFICE=1
HAVE_PDFTOPPM=0
command -v pdftoppm >/dev/null && HAVE_PDFTOPPM=1

# --- arguments -------------------------------------------------------------
APPS_RAW="word,wps,libreoffice"
OUT=""
TMO="$DEFAULT_TMO"
MAX_FIELDS="$DEFAULT_MAX_FIELDS"
JSON=0
VISUAL=1
KEEP_STAGING=0
ALL_FIXTURES=0
LIST_FILE=""
ARGS=()

while (($#)); do
  case "$1" in
    --list)       (($# >= 2)) || { echo "--list requires a file" >&2; exit 2; }; LIST_FILE="$2"; shift 2 ;;
    --all-fixtures) ALL_FIXTURES=1; shift ;;
    --apps)       (($# >= 2)) || { echo "--apps requires a value" >&2; exit 2; }; APPS_RAW="$2"; shift 2 ;;
    --out)        (($# >= 2)) || { echo "--out requires a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --timeout)    (($# >= 2)) || { echo "--timeout requires seconds" >&2; exit 2; }; TMO="$2"; shift 2 ;;
    --max-fields) (($# >= 2)) || { echo "--max-fields requires a number" >&2; exit 2; }; MAX_FIELDS="$2"; shift 2 ;;
    --json)       JSON=1; shift ;;
    --no-visual)  VISUAL=0; shift ;;
    --keep-staging) KEEP_STAGING=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done

# validate + dedupe the application selection, preserving request order
_apps=()
IFS=',' read -r -a _apps_in <<<"$APPS_RAW"
for a in "${_apps_in[@]}"; do
  a="${a//[[:space:]]/}"
  [[ -n "$a" ]] || { echo "empty application in --apps" >&2; exit 2; }
  case "$a" in
    word|wps|libreoffice) ;;
    *) echo "unknown application: $a (expected word,wps,libreoffice)" >&2; exit 2 ;;
  esac
  dup=0
  for seen in "${_apps[@]:-}"; do [[ "$seen" == "$a" ]] && dup=1; done
  (( dup )) || _apps+=("$a")
done
[[ "$TMO" =~ ^[0-9]+$ ]] || { echo "--timeout must be an integer" >&2; exit 2; }
[[ "$MAX_FIELDS" =~ ^[0-9]+$ ]] || { echo "--max-fields must be an integer" >&2; exit 2; }

# --- resolve documents -----------------------------------------------------
FILES=()
add_file() {
  local a="$1"
  if [[ -d "$a" ]]; then
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$a" -name '*.docx' -print0 | sort -z)
  elif [[ -f "$a" ]]; then
    FILES+=("$a")
  elif [[ "$a" == *'*'* || "$a" == *'?'* || "$a" == *'['* ]]; then
    local g
    while IFS= read -r g; do [[ -f "$g" ]] && FILES+=("$g"); done < <(compgen -G "$a" || true)
  else
    echo "no such file or directory: $a" >&2
    exit 2
  fi
}

if ((${#ARGS[@]})); then
  for a in "${ARGS[@]}"; do add_file "$a"; done
fi
if [[ -n "$LIST_FILE" ]]; then
  [[ -f "$LIST_FILE" ]] || { echo "--list file not found: $LIST_FILE" >&2; exit 2; }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$line" ]] && add_file "$line"
  done < "$LIST_FILE"
fi
if ((ALL_FIXTURES)); then
  while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$FIXTURES" -name '*.docx' -print0 | sort -z)
fi
if ((${#FILES[@]} == 0)); then
  add_file "$FIXTURES/headers/page-number-footer.docx"
  add_file "$FIXTURES/toc/toc-basic.docx"
  add_file "$FIXTURES/fields/bookmark-ref-pageref.docx"
fi

# absolutise + require .docx + dedupe (preserving order)
DOCS=()
declare -A _seen_doc=()
for f in "${FILES[@]}"; do
  [[ "$f" == *.docx ]] || { echo "not a .docx: $f" >&2; exit 2; }
  d="$(cd "$(dirname "$f")" && pwd)"
  abs="$d/$(basename "$f")"
  [[ -n "${_seen_doc[$abs]:-}" ]] && continue
  _seen_doc[$abs]=1
  DOCS+=("$abs")
done
if ((${#DOCS[@]} == 0)); then
  echo "no documents to run" >&2
  exit 1
fi

rel() { local p="$1"; case "$p" in "$ROOT"/*) printf '%s\n' "${p#"$ROOT"/}" ;; *) printf '%s\n' "$p" ;; esac; }

# --- output + staging ------------------------------------------------------
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT="${OUT:-$ROOT/tests/.out/compat/$RUN_ID}"
# shellcheck source=scripts/lib/source-protection.sh
source "$ROOT/scripts/lib/source-protection.sh"
wf_guard_destination --out "$OUT" "${DOCS[@]}" "$LIST_FILE"
wf_guard_destination 'compat result' "$OUT/result.json" "${DOCS[@]}" "$LIST_FILE"
for src in "${DOCS[@]}"; do
  rel_src="$(rel "$src")"
  name="$(printf '%s' "$rel_src" | sed 's#[/.]#_#g')"
  wf_guard_destination 'compat work copy' "$OUT/work/$(basename "$src")" "${DOCS[@]}" "$LIST_FILE"
  for artifact in officecli.png word.pdf word.png wps.pdf wps.png libreoffice.pdf libreoffice.png; do
    wf_guard_destination 'compat artifact' "$OUT/$name/$artifact" "${DOCS[@]}" "$LIST_FILE"
  done
  # soffice names its intermediate PDF after the work document.
  wf_guard_destination 'compat PDF' "$OUT/$name/$(basename "${src%.docx}").pdf" "${DOCS[@]}" "$LIST_FILE"
done
mkdir -p "$OUT"
# Absolutise: LibreOffice's -env:UserInstallation needs a valid file:// URI, and a
# relative path would parse as a URI host and hang the conversion.
OUT="$(cd "$OUT" && pwd)"
mkdir -p "$OUT/work"

STAGE_WSL=""
STAGE_WIN=""
USE_COM=0
for app in "${_apps[@]}"; do [[ "$app" != word && "$app" != wps ]] || USE_COM=1; done
if ((HAVE_WINDOWS && USE_COM)); then
  STAGE_WSL="/mnt/c/temp/wordflow-compat/$RUN_ID"
  if ! mkdir -p "$STAGE_WSL" 2>/dev/null; then
    STAGE_WSL=""; HAVE_WINDOWS=0
  else
    p="${STAGE_WSL#/mnt/}"; drive="${p:0:1}"; rest="${p:1}"
    STAGE_WIN="${drive^^}:${rest//\//\\}"
  fi
fi

# --- process bookkeeping (only explicit, creation-time-pinned owners) -------
cleanup_owners() {
  local dir win_dir
  [[ -n "$STAGE_WSL" ]] || return 0
  for dir in "$STAGE_WSL"/owners-*; do
    [[ -d "$dir" ]] || continue
    win_dir="$STAGE_WIN\\$(basename "$dir")"
    timeout 30 "$PS_BIN" -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "$STAGE_WIN\\compat-processes.ps1" \
      -Mode Cleanup -OwnerDir "$win_dir" >/dev/null 2>&1 || true
    mkdir -p "$OUT/processes"
    cp -f "$dir"/*.json "$OUT/processes/" 2>/dev/null || true
  done
}

CLEANED=0
cleanup() {
  ((CLEANED)) && return 0
  CLEANED=1
  for d in "${DOCS[@]:-}"; do timeout 60 officecli close "$d" >/dev/null 2>&1 || true; done
  for d in "${DOCS[@]:-}"; do
    w="$OUT/work/$(basename "$d")"
    if [[ -e "$w" ]]; then timeout 60 officecli close "$w" >/dev/null 2>&1 || true; fi
  done
  cleanup_owners
  if ((KEEP_STAGING == 0)) && [[ -n "$STAGE_WSL" ]]; then rm -rf "$STAGE_WSL" 2>/dev/null || true; fi
  return 0
}
trap cleanup EXIT

# --- helpers ---------------------------------------------------------------
pdf_size() { stat -c '%s' "$1" 2>/dev/null || printf 'null'; }

check_schema() { # <abs> -> true|false
  if timeout 60 officecli validate "$1" >/dev/null 2>&1; then printf 'true'; else printf 'false'; fi
}

# Run a command that must emit JSON; fall back to a safe error object if it
# errors or emits anything unparseable (e.g. a broken document).
fetch_json() {
  local s
  s="$(timeout 60 "$@" 2>/dev/null || true)"
  if jq -e . >/dev/null 2>&1 <<<"$s"; then printf '%s' "$s"; else printf '{"success":false}'; fi
}

# Document-level field caches via OfficeCLI (the only DOCX reader; ADR-0001).
# Reports every field's cached TEXT, not merely its evaluated flag, so a
# placeholder cache is detectable. -> compact JSON on stdout
inspect_field_cache() { # <abs>
  local abs="$1" fields toc text ine ics
  fields="$(fetch_json officecli query "$abs" field --json)"
  toc="$(fetch_json officecli query "$abs" toc --json)"
  text="$(timeout 60 officecli view "$abs" text 2>/dev/null || true)"
  ine="$(fetch_json officecli view "$abs" issues --type field_not_evaluated --json)"
  ics="$(fetch_json officecli view "$abs" issues --type field_cache_stale --json)"
  jq -nc \
    --argjson fields "$fields" --argjson tocs "$toc" --arg text "$text" \
    --argjson ine "$ine" --argjson ics "$ics" '
    def ph($s):
      ($s // "" | tostring) as $t
      | ($t | test("\u00ab|\u00bb"))
        or ($t == "Update field to see table of contents")
        or ($t | test("OCLI_NOTEVAL"))
        or ($t | test("not evaluated"; "i"));
    (($fields.data.results // []) | map({
        path: .path, type: .type,
        instruction: (.format.instruction // null),
        field_type: (.format.fieldType // null),
        cached_text: (.text // ""),
        evaluated: (.format.evaluated // null),
        placeholder: ph(.text)
      })) as $f
    | (($tocs.data.results // []) | map({
        path: .path,
        instruction: (.text // null),
        levels: (.format.levels // null),
        page_numbers: (.format.pageNumbers // null)
      })) as $t
    | (if (($t | length) > 0) and ($text | test("Update field to see table of contents"))
         then true else false end) as $toc_text_ph
    | ([ $f[] | select(.placeholder) ]) as $fph
    | { fields: $f,
        field_count: ($f | length),
        toc: $t,
        toc_placeholder_text: $toc_text_ph,
        placeholder_fields: ([ $fph[].path ]),
        placeholder_count: (($fph | length) + (if $toc_text_ph then 1 else 0 end)),
        checks: {
          field_not_evaluated: ($ine.data.count // null),
          field_cache_stale: ($ics.data.count // null)
        }
      }'
}

# Embedded Windows COM probe. Emits one compact JSON object; never throws to the
# shell. Base64 error text keeps the JSON ASCII regardless of console codepage.
# It enumerates per-application cached field TEXT (body plus every header/footer
# story) so the harness can report what each application will actually display.
write_probe_ps() {
  cat > "$STAGE_WSL/probe.ps1" <<'PS1'
param(
  [Parameter(Mandatory=$true)][string]$ProgId,
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$OwnerDir,
  [int]$MaxFields = 200
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'compat-processes.ps1') -Mode Library -OwnerDir $OwnerDir -ProgId $ProgId -Path $Path -Out $Out -MaxFields $MaxFields
Save-Owner (Get-Process -Id $PID) 'worker' 'driver-script' $PSCommandPath
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
function B64([string]$s) { if ([string]::IsNullOrEmpty($s)) { return $null }; return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

$script:fields = New-Object System.Collections.Generic.List[object]
$script:truncated = $false

function Add-FieldRange($range, [string]$scope, $section, [string]$story) {
  if ($null -eq $range) { return }
  try { $n = [int]$range.Fields.Count } catch { return }
  for ($i = 1; $i -le $n; $i++) {
    if ($script:fields.Count -ge $MaxFields) { $script:truncated = $true; return }
    $code = $null; $result = $null
    try { $code = [string]$range.Fields.Item($i).Code.Text } catch {}
    try { $result = [string]$range.Fields.Item($i).Result.Text } catch {}
    $script:fields.Add([pscustomobject]@{
      scope = $scope; section = $section; story = $story; index = $i;
      code = $code; result = $result
    })
  }
}

$r = [ordered]@{
  progid = $ProgId; engine_started = $false; error_stage = $null; opened = $false;
  error_b64 = $null; error_code = $null; version = $null; pages = $null;
  field_count = 0; fields = @(); fields_truncated = $false;
  toc_count = 0; toc_text = $null;
  pdf = $false; pdf_error_b64 = $null
}
$app = $null; $doc = $null; $owned = $false
$image=if ($ProgId -eq 'Word.Application') { 'WINWORD' } else { 'wps' }
$before=@(Get-Process -Name $image -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$activation=[datetime]::UtcNow
try {
  $app = New-Object -ComObject $ProgId
  if ($app.Documents.Count -ne 0) { throw 'COM instance already has documents; ownership refused' }
  # A hidden application without a document has no HWND. Open only our read-only
  # document to obtain the exact window identity; close it even if ownership fails.
  $doc = $app.Documents.Open($Path, $false, $true)
  Own-ComApplication $app $doc $image $before $activation
  $owned = $true
  $r.engine_started = $true
  try { $app.Visible = $false } catch {}
  try { $app.DisplayAlerts = 0 } catch {}
  try { $app.AutomationSecurity = 1 } catch {}
  try { $r.version = [string]$app.Version } catch {}
  $r.opened = $true
  Add-FieldRange $doc.Content 'body' $null 'main'
  try {
    $sc = [int]$doc.Sections.Count
    for ($s = 1; $s -le $sc; $s++) {
      $sec = $doc.Sections.Item($s)
      for ($h = 1; $h -le 3; $h++) {
        try { if ($sec.Headers.Item($h).Exists) { Add-FieldRange $sec.Headers.Item($h).Range 'header' $s ("h" + $h) } } catch {}
      }
      for ($f = 1; $f -le 3; $f++) {
        try { if ($sec.Footers.Item($f).Exists) { Add-FieldRange $sec.Footers.Item($f).Range 'footer' $s ("f" + $f) } } catch {}
      }
    }
  } catch {}
  $r.field_count = $script:fields.Count
  $r.fields = @($script:fields.ToArray())
  $r.fields_truncated = $script:truncated
  try { $r.toc_count = [int]$doc.TablesOfContents.Count } catch {}
  try { if ($r.toc_count -gt 0) { $r.toc_text = [string]$doc.TablesOfContents.Item(1).Range.Text } } catch {}
  try { $r.pages = [int]$doc.ComputeStatistics(2) } catch {}
  try {
    $doc.ExportAsFixedFormat($Out, 17)
    for ($i = 0; $i -lt 40 -and -not (Test-Path $Out); $i++) { Start-Sleep -Milliseconds 250 }
    $r.pdf = (Test-Path $Out)
  } catch { $r.pdf_error_b64 = B64 $_.Exception.Message }
} catch {
  if (-not $r.engine_started) { $r.error_stage = 'engine' } else { $r.error_stage = 'open' }
  $r.error_b64 = B64 $_.Exception.Message
  try { $r.error_code = [int64]$_.Exception.HResult } catch {}
} finally {
  if ($app -ne $null) {
    if ($doc -ne $null) { try { $doc.Close($false) } catch {} }
    if ($owned) { try { $app.Quit() } catch {} }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null } catch {}
  }
}
try { $r | ConvertTo-Json -Compress -Depth 6 } catch { @{ error_b64 = (B64 "ConvertTo-Json failed") } | ConvertTo-Json -Compress }
PS1
}

# run a COM application for one document. echoes compact JSON:
# {status, owr, detail, version, pdf_source, pdf_error, pages, app_field_cache}
com_app() { # <progid> <image> <win_source> <win_pdf> <wsl_pdf> <max_fields>
  local prog="$1" img="$2" wsrc="$3" wpdf="$4" wsl_pdf="$5" maxf="$6" out rc owners
  owners="owners-$img-$BASHPID"
  mkdir -p "$STAGE_WSL/$owners"
  if out="$(timeout "$((TMO + 45))" "$PS_BIN" -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "$STAGE_WIN\\compat-processes.ps1" \
        -Mode Supervise -Probe "$STAGE_WIN\\probe.ps1" -OwnerDir "$STAGE_WIN\\$owners" -Timeout "$TMO" \
        -ProgId "$prog" -Path "$wsrc" -Out "$wpdf" -MaxFields "$maxf" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  cleanup_owners

  out="$(printf '%s' "$out" | tr -d '\r')"
  if ((rc == 124 || rc == 137)); then
    jq -nc --argjson t "$TMO" '{status:"timeout", owr:"timeout", detail:("exceeded --timeout of " + ($t|tostring) + "s (likely a modal dialog)"), version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}'
    return 0
  fi
  if [[ -z "$out" ]] || ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    jq -nc --arg d "powershell/com probe produced no result (exit $rc)" '{status:"unavailable", owr:"unavailable", detail:$d, version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}'
    return 0
  fi
  jq -nc --argjson r "$out" --arg pdf "$wsl_pdf" '
    def ph($s):
      ($s // "" | tostring) as $t
      | ($t | test("\u00ab|\u00bb"))
        or ($t == "Update field to see table of contents")
        or ($t | test("OCLI_NOTEVAL"))
        or ($t | test("not evaluated"; "i"));
    (if ($r.error_b64 // null) != null then ($r.error_b64 | @base64d) else null end) as $err
    | (if ($r.pdf_error_b64 // null) != null then ($r.pdf_error_b64 | @base64d) else null end) as $perr
    | ([ ($r.fields // [])[] | {
          scope: (.scope // "body"),
          story: (.story // null),
          section: (.section // null),
          index: (.index // null),
          instruction: (.code // null),
          cached_text: (.result // ""),
          placeholder: ph(.result)
        } ]) as $fields
    | ([ $fields[] | select(.placeholder) | .instruction ]) as $phf
    | { source: "com",
        field_count: ($r.field_count // ($fields | length)),
        truncated: ($r.fields_truncated // false),
        fields: $fields,
        placeholder_fields: $phf,
        placeholder_count: ($phf | length),
        toc_count: ($r.toc_count // null),
        toc_text: (if ($r.toc_text // null) != null
                     then ($r.toc_text | gsub("\r"; "\n") | gsub("\n+$"; ""))
                     else null end)
      } as $afc
    | if ($r.engine_started | not)
        then {status:"unavailable", owr:"unavailable",
              detail:("engine did not start: " + ($err // "unknown")), version:null,
              pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}
      elif ($r.opened | not)
        then {status:"failed", owr:false,
              detail:("open failed: " + ($err // "unknown")), version:$r.version,
              pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}
      else {status:"ok", owr:true, detail:null, version:$r.version,
            pdf_source:(if ($r.pdf // false) then $pdf else null end),
            pdf_error:$perr, pages:($r.pages // null), app_field_cache:$afc}
      end'
}

# run LibreOffice headless for one document. echoes compact JSON.
lo_app() { # <work_docx> <dest_pdf>
  local work="$1" dest="$2" out rc produced
  rm -f "$dest"
  if out="$(timeout "$TMO" soffice --headless --norestore --invisible \
        -env:UserInstallation="file://$OUT/work/loprofile" \
        --convert-to pdf --outdir "$(dirname "$dest")" "$work" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if ((rc == 124 || rc == 137)); then
    jq -nc '{status:"timeout", owr:"timeout", detail:"libreoffice conversion timed out", version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}'
    return 0
  fi
  produced="$(dirname "$dest")/$(basename "${work%.docx}").pdf"
  if [[ -s "$produced" ]]; then
    [[ "$produced" != "$dest" ]] && mv -f "$produced" "$dest"
    jq -nc --arg p "$dest" '{status:"ok", owr:true, detail:null, version:null, pdf_source:$p, pdf_error:null, pages:null, app_field_cache:null}'
  else
    jq -nc --arg d "libreoffice could not produce a PDF (exit $rc)" '{status:"failed", owr:false, detail:$d, version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}'
  fi
}

# --- version strings -------------------------------------------------------
LO_VERSION="unavailable"
if ((HAVE_SOFFICE)); then
  LO_VERSION="$(timeout 60 soffice --version 2>/dev/null | head -1 | sed -e 's/^LibreOffice //' -e 's/ 420.*$//' || true)"
fi
OCLI_VERSION="$(officecli --version 2>/dev/null | head -1 || true)"

# --- run -------------------------------------------------------------------
if [[ -n "$STAGE_WSL" ]]; then
  cp "$ROOT/scripts/lib/compat-processes.ps1" "$STAGE_WSL/compat-processes.ps1"
  write_probe_ps
fi

RECORDS=()
doc_count=0
placeholder_docs=0

for src in "${DOCS[@]}"; do
  doc_count=$((doc_count + 1))
  rel_src="$(rel "$src")"
  name="$(printf '%s' "$rel_src" | sed 's#[/.]#_#g')"
  docdir="$OUT/$name"
  mkdir -p "$docdir"

  sha_before="$(sha256sum "$src" | awk '{print $1}')"
  work="$OUT/work/$(basename "$src")"
  cp -f "$src" "$work"

  # field caches + schema through OfficeCLI (the only DOCX reader; ADR-0001)
  fc="$(inspect_field_cache "$work")"
  sv="$(check_schema "$work")"

  # OfficeCLI baseline visual
  ref_visual=null
  if ((VISUAL)); then
    if timeout 60 officecli view "$work" screenshot --grid auto -o "$docdir/officecli.png" >/dev/null 2>&1 \
       && [[ -s "$docdir/officecli.png" ]]; then
      ref_visual="$(jq -nc --arg p "$(rel "$docdir/officecli.png")" '$p')"
    fi
  fi

  # Windows staging copy for COM applications
  win_src=""
  if [[ -n "$STAGE_WSL" ]]; then
    cp -f "$src" "$STAGE_WSL/$name"
    win_src="$STAGE_WIN\\$name"
  fi

  for app in "${_apps[@]}"; do
    pdf=null; visual=null; pages=null
    case "$app" in
      libreoffice)
        if ((!HAVE_SOFFICE)); then
          res="$(jq -nc '{status:"unavailable", owr:"unavailable", detail:"soffice not on PATH", version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}')"
        else
          res="$(lo_app "$work" "$docdir/libreoffice.pdf")"
          res="$(jq -c --arg v "$LO_VERSION" '.version = (if .status=="ok" then $v else null end)' <<<"$res")"
        fi
        ;;
      word)
        if ((!HAVE_WINDOWS)); then
          res="$(jq -nc '{status:"unavailable", owr:"unavailable", detail:"Windows interop (powershell.exe) not reachable", version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}')"
        else
          res="$(com_app Word.Application WINWORD.EXE "$win_src" "$STAGE_WIN\\$name.word.pdf" "$STAGE_WSL/$name.word.pdf" "$MAX_FIELDS")"
        fi
        ;;
      wps)
        if ((!HAVE_WINDOWS)); then
          res="$(jq -nc '{status:"unavailable", owr:"unavailable", detail:"Windows interop (powershell.exe) not reachable", version:null, pdf_source:null, pdf_error:null, pages:null, app_field_cache:null}')"
        else
          res="$(com_app KWPS.Application wps.exe "$win_src" "$STAGE_WIN\\$name.wps.pdf" "$STAGE_WSL/$name.wps.pdf" "$MAX_FIELDS")"
        fi
        ;;
    esac

    pdf_src="$(jq -r '.pdf_source // empty' <<<"$res")"
    pdf_error="$(jq -r '.pdf_error // empty' <<<"$res")"
    pages="$(jq -r '.pages // empty' <<<"$res")"
    afc="$(jq -c '.app_field_cache // null' <<<"$res")"
    # Defensive: if the probe reported success but raced the async export, pick
    # up the staged PDF that is nonetheless on disk.
    if [[ -z "$pdf_src" && ( "$app" == "word" || "$app" == "wps" ) && -s "$STAGE_WSL/$name.$app.pdf" ]]; then
      pdf_src="$STAGE_WSL/$name.$app.pdf"
    fi
    pdf_bytes=null
    if [[ -n "$pdf_src" && -s "$pdf_src" ]]; then
      [[ "$pdf_src" != "$docdir/$app.pdf" ]] && cp -f "$pdf_src" "$docdir/$app.pdf"
      pdf="$(jq -nc --arg p "$(rel "$docdir/$app.pdf")" '$p')"
      pdf_bytes="$(pdf_size "$docdir/$app.pdf")"
      [[ "$pdf_bytes" =~ ^[0-9]+$ ]] || pdf_bytes=null
      if ((VISUAL)) && ((HAVE_PDFTOPPM)); then
        if timeout 60 pdftoppm -png -r 96 -f 1 -l 1 -singlefile "$docdir/$app.pdf" "$docdir/$app" >/dev/null 2>&1 \
           && [[ -s "$docdir/$app.png" ]]; then
          visual="$(jq -nc --arg p "$(rel "$docdir/$app.png")" '$p')"
        fi
      fi
    fi
    [[ -z "$pages" ]] && pages=null

    status="$(jq -r '.status' <<<"$res")"
    owr="$(jq -c '.owr' <<<"$res")"
    detail="$(jq -r '.detail // ""' <<<"$res")"
    appver="$(jq -r '.version // empty' <<<"$res")"
    [[ -z "$appver" ]] && appver=null

    rec="$(jq -nc \
      --arg source "$rel_src" \
      --arg sha "$sha_before" \
      --arg app "$app" \
      --arg status "$status" \
      --argjson owr "$owr" \
      --arg detail "$detail" \
      --arg appver "$appver" \
      --argjson pdf "$pdf" \
      --argjson visual "$visual" \
      --argjson pdf_bytes "$pdf_bytes" \
      --argjson pages "$pages" \
      --arg pdf_error "$pdf_error" \
      --argjson field_cache "$fc" \
      --argjson app_field_cache "$afc" \
      --argjson schema_valid "$sv" \
      --argjson reference_visual "$ref_visual" \
      '{
        source:$source, source_sha256:$sha, app:$app, status:$status,
        opens_without_repair:$owr, detail:$detail,
        application_version:(if $appver=="" then null else $appver end),
        render:{ pdf:$pdf, visual:$visual, pdf_bytes:$pdf_bytes, pages:$pages,
                 pdf_error:(if $pdf_error=="" then null else $pdf_error end) },
        field_cache:$field_cache,
        app_field_cache:$app_field_cache,
        schema_valid:$schema_valid,
        reference_visual:$reference_visual
      }')"
    RECORDS+=("$rec")
  done

  # source protection
  sha_after="$(sha256sum "$src" | awk '{print $1}')"
  unchanged=false; [[ "$sha_before" == "$sha_after" ]] && unchanged=true
  [[ "$unchanged" != "true" ]] && echo "WARNING: source changed during run: $rel_src" >&2

  ph_count="$(jq -r '.placeholder_count' <<<"$fc")"
  (( ph_count > 0 )) && placeholder_docs=$((placeholder_docs + 1))

  jq -nc --arg source "$rel_src" --arg sha "$sha_before" \
    --argjson unchanged "$unchanged" --argjson schema_valid "$sv" \
    --argjson field_cache "$fc" --argjson reference_visual "$ref_visual" \
    '{source:$source, source_sha256:$sha, source_unchanged:$unchanged,
      schema_valid:$schema_valid, field_cache:$field_cache, reference_visual:$reference_visual}' \
    > "$docdir/document.json"

  timeout 60 officecli close "$src" >/dev/null 2>&1 || true
  timeout 60 officecli close "$work" >/dev/null 2>&1 || true
done

# --- assemble report -------------------------------------------------------
report="$(jq -n \
  --arg schema "wordflow.compat-harness/v1" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg artifacts_dir "$(rel "$OUT")" \
  --arg officecli "$OCLI_VERSION" \
  --arg libreoffice "$LO_VERSION" \
  --arg powershell "$PS_BIN" \
  --argjson have_win "$([ "$HAVE_WINDOWS" == 1 ] && echo true || echo false)" \
  --argjson have_lo "$([ "$HAVE_SOFFICE" == 1 ] && echo true || echo false)" \
  --argjson have_pp "$([ "$HAVE_PDFTOPPM" == 1 ] && echo true || echo false)" \
  --argjson apps "$(printf '%s\n' "${_apps[@]}" | jq -R . | jq -s .)" \
  --slurpfile records <(printf '%s\n' "${RECORDS[@]}") \
  --argjson placeholder_docs "$placeholder_docs" '
  ($records // []) as $recs
  | ($recs | group_by(.app) | map({key: .[0].app, value: {
        ok: (map(select(.status=="ok")) | length),
        failed: (map(select(.status=="failed")) | length),
        unavailable: (map(select(.status=="unavailable")) | length),
        timeout: (map(select(.status=="timeout")) | length),
        opens_without_repair_true: (map(select(.opens_without_repair==true)) | length)
      }}) | from_entries) as $by_app
  | { schema:$schema, generated_at:$generated_at, tool:"scripts/wf-compat-harness.sh",
      artifacts_dir:$artifacts_dir,
      environment:{
        officecli:$officecli,
        powershell:$powershell,
        windows_interop:$have_win,
        libreoffice:{ available:$have_lo, version:$libreoffice },
        word:{ driver:"Word.Application", available:$have_win,
               note:"available means Windows interop is reachable; Microsoft Word must also be installed." },
        wps:{ driver:"KWPS.Application", available:$have_win,
              note:"WPS conclusions are best-effort (closed source, no format documentation)." },
        visual:{ tool:"pdftoppm", available:$have_pp,
                 note:"PDF render is captured regardless; the PNG visual needs poppler-utils." }
      },
      manual_prerequisites:[
        "Microsoft Word (target 2016+) installed with the Word.Application COM ProgID registered; it is opened read-only and quit by the harness.",
        "WPS Writer installed with the KWPS.Application COM ProgID registered; opened read-only and quit by the harness.",
        "LibreOffice on PATH (soffice), driven headless with an isolated user profile.",
        "WSL Windows interop enabled so powershell.exe runs; appendWindowsPath may be false because the harness invokes powershell.exe by absolute path.",
        "poppler-utils (pdftoppm) to derive PNG visuals; without it the per-application PDF is still captured."
      ],
      apps_requested:$apps,
      records:$recs,
      summary:{ documents:($recs | map(.source) | unique | length),
                records:($recs | length),
                placeholder_documents:$placeholder_docs,
                schema_all_valid:($recs | map(.schema_valid) | all),
                by_app:$by_app } }
')"

mkdir -p "$OUT"
printf '%s' "$report" > "$OUT/result.json"

if ((JSON)); then
  printf '%s\n' "$report"
  exit 0
fi

# --- human summary ---------------------------------------------------------
{
  printf 'WordFlow cross-application compatibility harness\n'
  printf '  run:          %s\n' "$(rel "$OUT")"
  printf '  officecli:    %s\n' "$OCLI_VERSION"
  printf '  LibreOffice:  %s\n' "$LO_VERSION"
  printf '  Windows COM:  %s\n' "$([ "$HAVE_WINDOWS" == 1 ] && echo reachable || echo unavailable)"
  printf '\n'
  printf '%s\n' "$report" | jq -r '
    def mark($o):
      if $o == true then "opens ok"
      elif $o == false then "REPAIR/FAIL"
      else ($o | tostring) end;
    def phnote($d):
      "  fields: " + (($d.field_cache.field_count) | tostring)
      + ", placeholders: " + (($d.field_cache.placeholder_count) | tostring)
      + (if (($d.field_cache.placeholder_fields // []) | length) > 0
           then " (" + ($d.field_cache.placeholder_fields | join(", ")) + ")" else "" end)
      + (if $d.field_cache.toc_placeholder_text then "  [TOC placeholder cache]" else "" end);
    def appph($r):
      if ($r.app_field_cache == null) then ""
      else "   fields(com): " + (($r.app_field_cache.field_count) | tostring)
           + (if (($r.app_field_cache.placeholder_fields // []) | length) > 0
                then ", placeholders: " + (($r.app_field_cache.placeholder_count) | tostring)
                     + " (" + ($r.app_field_cache.placeholder_fields | join(", ")) + ")"
                else "" end)
      end;
    .records
    | group_by(.source)
    | .[]
    | (.[0]) as $d
    | ($d.source),
      ( .[] | "  " + ((.app + "            ")[0:12]) + " " + mark(.opens_without_repair)
              + "   pdf: " + (if .render.pdf then .render.pdf else "-" end)
              + (if .render.visual then "   visual: " + .render.visual else "" end)
              + (if .application_version then "   v" + .application_version else "" end)
              + (if (.detail // "") != "" then "\n                 " + .detail + " (status: " + .status + ")" else "" end)
              + appph(.) ),
      phnote($d),
      ""
  '
  printf '\n'
  printf 'Machine-readable: %s\n' "$(rel "$OUT/result.json")"
  printf 'Artifacts:        %s\n' "$(rel "$OUT")"
}

exit 0
