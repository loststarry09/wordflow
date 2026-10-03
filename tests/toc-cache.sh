#!/usr/bin/env bash
#
# Acceptance tests for the TOC cached without page numbers (#11, spec D9).
#
# The frozen decision is that the TOC's *cached result* lists the heading entries
# with no page-number references, so no application ever shows a wrong number,
# while the field stays real and gains page numbers on a manual F9 / Update TOC.
#
# These tests assert the *external behaviour* of the committed fixture
# tests/fixtures/toc/toc-no-page-numbers.docx:
#   * it passes OfficeCLI schema validation;
#   * the TOC is a real complex field (begin/separate/end) with a cached result;
#   * the cached result carries the three heading entries and NO digits/tab/PAGEREF;
#   * TOC1-TOC3 are defined (no dangling style);
#   * Word, WPS, and LibreOffice each open it without repair and display the
#     entries with no page numbers;
#   * Word and WPS rebuild the field on update, gaining the correct page numbers.
#
# They deliberately assert the facts, not the OfficeCLI/COM commands used to
# rebuild the fixture.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum, grep, sed on PATH.
#   Word/WPS over COM require WSL Windows interop; absent -> those checks SKIP.
#   LibreOffice (soffice) is optional; absent -> that check SKIPs.
# Usage: tests/toc-cache.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
FIXTURE="$FIX/toc/toc-no-page-numbers.docx"
HARNESS="$ROOT/scripts/wf-compat-harness.sh"
OWNERSHIP="$ROOT/scripts/wf-style-ownership.sh"
mkdir -p "$ROOT/tests/.out"
OUTROOT="$(mktemp -d "$ROOT/tests/.out/toc-cache.XXXXXX")"
STAGE=""
LOCK=/tmp/wordflow-wincom.lock
DEFAULT_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
TMO=180

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -f "$FIXTURE" ]] || { echo "missing fixture: $FIXTURE" >&2; exit 2; }
[[ -x "$HARNESS" ]] || { echo "missing or non-executable: $HARNESS" >&2; exit 2; }

cleanup() {
  [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"
}
trap cleanup EXIT

pass=0
fail=0
skip=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_skip() { printf '  \033[33mSKIP\033[0m %s — %s\n' "$1" "$2"; skip=$((skip + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_true() { # <label> <jq-expr> <json>
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then report_ok "$1"; else report_fail "$1" "assertion failed: $2"; fi
}
assert_no_digits() { # <label> <text>
  if [[ "$2" == *[0-9]* ]]; then report_fail "$1" "unexpected digit in '$2'"; else report_ok "$1"; fi
}
assert_no_tab() { # <label> <text>
  if [[ "$2" == *$'\t'* ]]; then report_fail "$1" "unexpected tab in '$2'"; else report_ok "$1"; fi
}

echo "TOC cached without page numbers (#11) — $FIXTURE"

src_before="$(sha256sum "$FIXTURE" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 1. Schema and field structure (OfficeCLI)
# ---------------------------------------------------------------------------
if officecli validate "$FIXTURE" >/dev/null 2>&1; then
  report_ok "officecli validate passes"
else
  report_fail "officecli validate passes" "validate failed"
fi

toc="$(officecli query "$FIXTURE" toc --json 2>/dev/null || echo '{}')"
# A concurrent officecli resident can transiently return no result on the first
# read; re-read once from a closed file before judging the document.
if [[ "$(jq -r '.data.results[0]? // "absent"' <<<"$toc")" == "absent" ]]; then
  officecli close "$FIXTURE" >/dev/null 2>&1 || true
  toc="$(officecli query "$FIXTURE" toc --json 2>/dev/null || echo '{}')"
fi
# The instruction is the stable, document-level fact. The web-layout \z switch
# means "page numbers off" for OfficeCLI; \n would omit them permanently and
# break the F9 path, so it must be absent.
toc_instr="$(jq -r '.data.results[0].text // ""' <<<"$toc")"
assert_eq "TOC selects levels 1-3"   "$(jq -rn --arg s "$toc_instr" '$s|contains("\\o \"1-3\"")')" "true"
assert_eq "TOC has hyperlinks (\\h)" "$(jq -rn --arg s "$toc_instr" '$s|contains("\\h")')" "true"
assert_eq "TOC instruction uses \\z, not \\n" \
  "$(jq -rn --arg s "$toc_instr" '$s|(contains("\\z") and (contains("\\n")|not))')" "true"

field="$(officecli query "$FIXTURE" field --json 2>/dev/null || echo '{}')"
assert_eq "one field, of type toc" "$(jq -r '[.data.results[]|select(.format.fieldType=="toc")]|length' <<<"$field")" "1"
assert_eq "TOC field is cached (evaluated)" "$(jq -r '.data.results[0].format.evaluated // false' <<<"$field")" "true"

cache="$(jq -r '.data.results[0].text // ""' <<<"$field")"
assert_eq "cache lists heading entry 1" "$(jq -rn --arg s "$cache" '$s|contains("Alpha Section")')" "true"
assert_eq "cache lists heading entry 2" "$(jq -rn --arg s "$cache" '$s|contains("Beta Section")')" "true"
assert_eq "cache lists heading entry 3" "$(jq -rn --arg s "$cache" '$s|contains("Gamma Subsection")')" "true"
assert_no_digits "cache carries no page number" "$cache"
assert_no_tab    "cache carries no tab leader"  "$cache"
assert_eq "cache is not the placeholder" "$(jq -rn --arg s "$cache" '$s==("Update field to see table of contents")')" "false"

raw="$(officecli raw "$FIXTURE" /document 2>/dev/null || echo '')"
assert_eq "field has begin fldChar"     "$(printf '%s' "$raw" | grep -o 'w:fldCharType="begin"' | wc -l | tr -d ' ')" "1"
assert_eq "field has separate fldChar"  "$(printf '%s' "$raw" | grep -o 'w:fldCharType="separate"' | wc -l | tr -d ' ')" "1"
assert_eq "field has end fldChar"       "$(printf '%s' "$raw" | grep -o 'w:fldCharType="end"' | wc -l | tr -d ' ')" "1"
assert_eq "no PAGEREF anywhere in the body" "$(printf '%s' "$raw" | grep -o 'PAGEREF' | wc -l | tr -d ' ')" "0"
assert_eq "no tab inside the TOC cache"     "$(printf '%s' "$raw" | grep -o '<w:tab' | wc -l | tr -d ' ')" "0"
assert_eq "headings forced onto three pages" "$(printf '%s' "$raw" | grep -o 'w:type="page"' | wc -l | tr -d ' ')" "2"

# ---------------------------------------------------------------------------
# 2. Styles: the refreshed TOC entries reference only defined styles
# ---------------------------------------------------------------------------
if [[ -x "$OWNERSHIP" ]]; then
  own="$("$OWNERSHIP" "$FIXTURE" --json 2>/dev/null || echo '{}')"
  assert_eq "no dangling style" "$(jq -r '.coherent // false' <<<"$own")" "true"
  assert_eq "dangling_styles is empty" "$(jq -c '[.dangling_styles[]?]|length' <<<"$own")" "0"
else
  report_skip "no dangling style" "wf-style-ownership.sh not executable"
fi

# ---------------------------------------------------------------------------
# 3. LibreOffice: opens repair-free, renders entries with no page numbers
# ---------------------------------------------------------------------------
if command -v soffice >/dev/null; then
  lo="$(timeout $((TMO * 3)) "$HARNESS" "$FIXTURE" --apps libreoffice \
        --out "$OUTROOT/libreoffice" --no-visual --json 2>/dev/null || echo '{}')"
  assert_eq "libreoffice: opens without repair" \
    "$(jq -r '.records[]|select(.app=="libreoffice")|.opens_without_repair' <<<"$lo")" "true"
  lopdf="$(jq -r '.records[]|select(.app=="libreoffice")|.render.pdf // empty' <<<"$lo")"
  if [[ -s "$lopdf" ]] && command -v pdftotext >/dev/null; then
    lotxt="$(pdftotext "$lopdf" - 2>/dev/null || true)"
    assert_eq "libreoffice: render lists entry 1" "$(jq -rn --arg s "$lotxt" '$s|contains("Alpha Section")')" "true"
    assert_no_digits "libreoffice: render shows no page numbers" "$lotxt"
  else
    if [[ -s "$lopdf" ]]; then
      report_skip "libreoffice: render text checks" "pdftotext not on PATH"
    else
      report_fail "libreoffice: PDF render captured" "no non-empty PDF"
    fi
  fi
else
  report_skip "libreoffice: opens without repair" "soffice not on PATH"
fi

# ---------------------------------------------------------------------------
# 4. Word and WPS over COM: open repair-free, entries without page numbers,
#    and the field gains page numbers on update (F9)
# ---------------------------------------------------------------------------
PS_BIN="${WF_POWERSHELL:-$DEFAULT_PS}"
if [[ -x "$PS_BIN" ]]; then
  win="$(flock -w 1800 "$LOCK" timeout $((TMO * 4)) "$HARNESS" "$FIXTURE" \
          --apps word,wps --out "$OUTROOT/wordwps" --no-visual --json 2>/dev/null || echo '{}')"
  for app in word wps; do
    status="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.status' <<<"$win")"
    if [[ "$status" == "unavailable" ]]; then
      report_skip "$app: opens without repair" "COM engine unavailable"
      continue
    fi
    assert_eq "$app: opens without repair" \
      "$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.opens_without_repair' <<<"$win")" "true"
    ttext="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.app_field_cache.toc_text // ""' <<<"$win")"
    assert_eq "$app: TOC on open lists entry 1" "$(jq -rn --arg s "$ttext" '$s|contains("Alpha Section")')" "true"
    assert_no_digits "$app: TOC on open has no page numbers" "$ttext"
    assert_no_tab    "$app: TOC on open has no tab leader"   "$ttext"
  done

  # F9 / Update TOC probe: rebuild the field and read the TOC text again.
  mkdir -p /mnt/c/temp
  if STAGE="$(mktemp -d /mnt/c/temp/wordflow-toc-test.XXXXXX)" && cp "$FIXTURE" "$STAGE/fixture.docx"; then
    stage_win="C:${STAGE#/mnt/c}"
    stage_win="${stage_win//\//\\}"
    cat > "$STAGE/probe.ps1" <<'PS1'
param([Parameter(Mandatory=$true)][string]$ProgId,[Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$r = [ordered]@{ opened=$false; error=$null; toc_count=0; before=$null; after=$null }
$app = $null
try {
  $app = New-Object -ComObject $ProgId
  try { $app.Visible = $false } catch {}
  try { $app.DisplayAlerts = 0 } catch {}
  $doc = $app.Documents.Open($Path, $false, $true)
  $r.opened = $true
  try { $r.toc_count = [int]$doc.TablesOfContents.Count } catch {}
  if ($r.toc_count -gt 0) {
    try { $r.before = [string]$doc.TablesOfContents.Item(1).Range.Text } catch {}
    try { $doc.Fields.Update() } catch {}
    try { $doc.TablesOfContents.Item(1).Update() } catch { $r.error = $_.Exception.Message }
    try { $r.after = [string]$doc.TablesOfContents.Item(1).Range.Text } catch {}
  }
  try { $doc.Close($false) } catch {}
} catch {
  $r.error = $_.Exception.Message
} finally {
  if ($app -ne $null) {
    try { $app.Quit() } catch {}
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) | Out-Null } catch {}
  }
}
$r | ConvertTo-Json -Compress
PS1
    for pair in "word:Word.Application" "wps:KWPS.Application"; do
      app="${pair%%:*}"; prog="${pair#*:}"
      st="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.status' <<<"$win")"
      [[ "$st" == "ok" ]] || continue
      # COM/powershell can emit a stray non-JSON line before the object; keep the
      # last line, which is the compact JSON the probe prints.
      out="$(flock -w 1800 "$LOCK" timeout "$TMO" "$PS_BIN" -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass \
             -File "$stage_win\\probe.ps1" -ProgId "$prog" \
             -Path "$stage_win\\fixture.docx" 2>/dev/null | tr -d '\r' | tail -n1)"
      if ! jq -e '.opened==true and .toc_count>=1' >/dev/null 2>&1 <<<"$out"; then
        report_fail "$app: F9 probe ran" "probe output: ${out:-<empty>}"
        continue
      fi
      before="$(jq -r '.before // ""' <<<"$out")"
      after="$(jq -r '.after // ""' <<<"$out")"
      assert_no_digits "$app: F9 before-update has no page numbers" "$before"
      assert_eq "$app: F9 after-update adds page number 1" "$(jq -rn --arg s "$after" '$s|test("Alpha Section\\t1")')" "true"
      assert_eq "$app: F9 after-update adds page number 2" "$(jq -rn --arg s "$after" '$s|test("Beta Section\\t2")')" "true"
      assert_eq "$app: F9 after-update adds page number 3" "$(jq -rn --arg s "$after" '$s|test("Gamma Subsection\\t3")')" "true"
    done
  else
    report_skip "word/wps: F9 update probe" "no writable Windows staging dir ($STAGE)"
  fi
else
  report_skip "word/wps over COM" "Windows interop not reachable ($PS_BIN)"
fi

# ---------------------------------------------------------------------------
# 5. Source protection
# ---------------------------------------------------------------------------
src_after="$(sha256sum "$FIXTURE" | awk '{print $1}')"
assert_eq "fixture source unchanged" "$src_before" "$src_after"

echo
echo "TOC cache: $((pass + fail)) checks run | $pass passed | $fail failed | $skip skipped"
echo "Artifacts: $OUTROOT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
