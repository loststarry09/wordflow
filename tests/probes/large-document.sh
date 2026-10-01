#!/usr/bin/env bash
#
# WordFlow large-document and missing-font probe (#9).
#
# Research probe, not a product capability. It measures how OfficeCLI and the
# renderers behave as a document grows, and what happens when a document names a
# font that is absent on the rendering host. It never reads or writes DOCX
# except through OfficeCLI (ADR-0001); fonts are only *named* via OfficeCLI
# properties, never embedded.
#
# Two sections:
#
#   1. LARGE DOCUMENTS. For each paragraph count it builds a document
#      (`create --locale zh-CN` + one `batch` of paragraph adds), then times
#      create+add, validate, `view stats`, `view issues`, `view text`, and a
#      LibreOffice headless PDF render; it records paragraphs, pages, bytes and
#      (optionally) peak RSS. It also times N isolated `add` invocations to show
#      the per-process overhead that makes `batch` mandatory on large documents.
#
#   2. MISSING FONTS. It builds a document naming `Microsoft YaHei` and
#      `方正书宋` (both absent on a stock Linux host) plus `Arial Black`, then
#      observes: `officecli validate` (schema pass/fail), `view issues`, the
#      LibreOffice substitution (fonts embedded in the PDF, host fonts present
#      and hidden), and Word/WPS open (read-only) + PDF export via COM when WSL
#      interop is available.
#
# Everything is written under tests/.out/ (git-ignored). The probe is bounded:
# sizes are small, each external render carries a timeout, and it targets well
# under two minutes on the reference host.
#
# Requirements (required): officecli >= 1.0.152, jq, coreutils on PATH.
# Optional: soffice (LibreOffice) for render/substitution timings; pdfinfo and
#   pdffonts (poppler-utils) for page counts and embedded-font readback;
#   /usr/bin/time for peak RSS; powershell.exe + Word/WPS for the COM open
#   records. Each optional tool is skipped, never required.
#
# Usage:
#   tests/probes/large-document.sh [options]
#
# Options:
#   --out <dir>        Output directory. Default: tests/.out/large-document.
#   --sizes "<a b c>"  Paragraph counts to test. Default: "250 1000 4000 16000".
#   --overhead <n>     Isolated `add` invocations for the overhead sample. Default: 20.
#   --no-render        Skip LibreOffice rendering.
#   --no-com           Skip the Word/WPS COM records.
#   --json             Print the JSON result to stdout instead of the summary.
#   -h, --help         Show this help.
#
# Exit codes: 0 = measurements produced; 1 = a hard invariant failed (validate
#   error or a paragraph-count mismatch); 2 = usage error or missing dependency.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="tests/probes/large-document.sh"
DEFAULT_OUT="$ROOT/tests/.out/large-document"
DEFAULT_SIZES="250 1000 4000 16000"
DEFAULT_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
DEFAULT_TMO=120
COM_LOCK=/tmp/wordflow-wincom.lock
STAGE_WSL=/mnt/c/temp/wordflow-large-doc

SENTENCE='第 N 段 WordFlow 大文档探针：这是一个用于测量吞吐、分页与内存的段落。'

usage() {
  cat <<'EOF'
Usage: large-document.sh [options]

Measure large-document scaling and missing-font behaviour with OfficeCLI.

Options:
  --out <dir>        Output directory. Default: tests/.out/large-document.
  --sizes "<a b c>"  Paragraph counts to test. Default: "250 1000 4000 16000".
  --overhead <n>     Isolated add invocations for the overhead sample. Default: 20.
  --no-render        Skip LibreOffice rendering.
  --no-com           Skip the Word/WPS COM records.
  --json             Print the JSON result to stdout instead of the summary.
  -h, --help         Show this help.

Everything is written under tests/.out/ (git-ignored). External renders are
time-bounded (WF_SOFFICE_TIMEOUT, default 120s).

Exit codes: 0 measurements produced | 1 hard invariant failed | 2 usage/deps.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die_op()    { echo "$TOOL: $*" >&2; exit 1; }

OUT="$DEFAULT_OUT"
SIZES="$DEFAULT_SIZES"
OVERHEAD=20
DO_RENDER=1
DO_COM=1
JSON=0

while (($#)); do
  case "$1" in
    --out)        (($# >= 2)) || die_usage "--out requires a directory"; OUT="$2"; shift 2 ;;
    --sizes)      (($# >= 2)) || die_usage "--sizes requires a list"; SIZES="$2"; shift 2 ;;
    --overhead)   (($# >= 2)) || die_usage "--overhead requires a number"; OVERHEAD="$2"; shift 2 ;;
    --no-render)  DO_RENDER=0; shift ;;
    --no-com)     DO_COM=0; shift ;;
    --json)       JSON=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die_usage "unknown option: $1" ;;
  esac
done

for bin in officecli jq; do
  command -v "$bin" >/dev/null || die_usage "$bin not found on PATH"
done

mkdir -p -- "$OUT"
OUT="$(cd -- "$OUT" && pwd)"
rm -rf -- "$OUT/docs" "$OUT/pdf" "$OUT/parts" "$OUT/missing"
mkdir -p -- "$OUT/docs" "$OUT/pdf" "$OUT/parts" "$OUT/missing"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-large-doc.XXXXXX")"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# Time an argument vector in milliseconds; echoes the duration. Never fails the
# probe: a non-zero exit is swallowed.
time_it() { # <cmd...>
  local t0 t1
  t0="$(now_ms)"
  "$@" >/dev/null 2>&1 || true
  t1="$(now_ms)"
  echo $(( t1 - t0 ))
}

LO_PROFILE="$TMP/loprofile"

render_pdf() { # <docx> <outpdf> [extra env assignments...]
  local docx="$1" outpdf="$2"
  local stem dir
  stem="$(basename -- "${docx%.docx}")"
  dir="$(dirname -- "$outpdf")"
  rm -f -- "$outpdf"
  timeout "${WF_SOFFICE_TIMEOUT:-$DEFAULT_TMO}" soffice --headless --norestore --nolockcheck \
    -env:UserInstallation="file://$LO_PROFILE" \
    --convert-to pdf --outdir "$dir" "$docx" >/dev/null 2>&1 || true
  local produced="$dir/$stem.pdf"
  [[ -s "$produced" ]] && mv -f -- "$produced" "$outpdf"
  [[ -s "$outpdf" ]]
}

pdf_pages() { # <pdf>
  if command -v pdfinfo >/dev/null; then
    pdfinfo "$1" 2>/dev/null | awk '/^Pages:/{print $2}'
  fi
}

pdf_fonts() { # <pdf> -> newline-separated font names
  if command -v pdffonts >/dev/null; then
    pdffonts "$1" 2>/dev/null | awk 'NR>2 && $1!="" {print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Section 1: large documents
# ---------------------------------------------------------------------------
HARD_FAIL=0
RUNG_JSON_FILES=()

# Warm-up: pay the first-run cost once so the smallest measured rung is not a
# cold-start outlier (OfficeCLI's first invocation is noticeably slower).
warm="$TMP/warmup.docx"
rm -f -- "$warm"
officecli create "$warm" --locale zh-CN >/dev/null 2>&1
jq -n '[range(0;20)|{command:"add",parent:"/body",type:"paragraph",props:{text:"warmup"}}]' > "$TMP/warmup.json"
officecli batch "$warm" --input "$TMP/warmup.json" >/dev/null 2>&1 || true
officecli close "$warm" >/dev/null 2>&1 || true

# JSON per-size records.
for n in $SIZES; do
  [[ "$n" =~ ^[0-9]+$ ]] || die_usage "invalid size: '$n'"
  docx="$OUT/docs/large-$n.docx"
  batch="$TMP/batch-$n.json"
  pdf="$OUT/pdf/large-$n.pdf"

  jq -n --argjson n "$n" --arg s "$SENTENCE" \
    '[ range(0;$n) | { command:"add", parent:"/body", type:"paragraph",
        props:{ text: ($s + " 编号 " + (.|tostring) + "。") } } ]' > "$batch"

  rm -f -- "$docx"
  officecli create "$docx" --locale zh-CN >/dev/null 2>&1

  t0="$(now_ms)"
  if command -v /usr/bin/time >/dev/null; then
    /usr/bin/time -v officecli batch "$docx" --input "$batch" >/dev/null 2>"$TMP/time-$n.txt" || true
    rss="$(awk -F': ' '/Maximum resident/{print $2}' "$TMP/time-$n.txt" 2>/dev/null | head -1)"
  else
    officecli batch "$docx" --input "$batch" >/dev/null 2>&1 || true
    rss=""
  fi
  officecli close "$docx" >/dev/null 2>&1 || true
  t1="$(now_ms)"
  create_add_ms=$(( t1 - t0 ))

  bytes="$(stat -c%s "$docx" 2>/dev/null || echo 0)"

  stats_json="$(timeout "$DEFAULT_TMO" officecli view "$docx" stats --json 2>/dev/null || echo '{}')"
  paras="$(jq -r '.data.paragraphs // empty' <<<"$stats_json" 2>/dev/null || true)"
  chars="$(jq -r '.data.totalCharacters // empty' <<<"$stats_json" 2>/dev/null || true)"

  validate_ms=0
  validate_out=""
  validate_out="$(timeout "$DEFAULT_TMO" officecli validate "$docx" 2>&1)" || true
  validate_ok=false
  [[ "$validate_out" == *"no errors"* ]] && validate_ok=true
  [[ "$validate_ok" == false ]] && HARD_FAIL=1
  # Re-time validate specifically (the parse above is cheap but not timed).
  validate_ms="$(time_it timeout "$DEFAULT_TMO" officecli validate "$docx")"

  stats_ms="$(time_it timeout "$DEFAULT_TMO" officecli view "$docx" stats)"
  issues_ms="$(time_it timeout "$DEFAULT_TMO" officecli view "$docx" issues)"
  text_ms="$(time_it timeout "$DEFAULT_TMO" officecli view "$docx" text)"

  render_ms=""
  pages=""
  lo_fonts=""
  if ((DO_RENDER)) && command -v soffice >/dev/null; then
    render_ms="$(time_it render_pdf "$docx" "$pdf")"
    if [[ -s "$pdf" ]]; then
      pages="$(pdf_pages "$pdf")"
      lo_fonts="$(pdf_fonts "$pdf")"
    fi
  fi

  if [[ -n "$paras" && "$paras" != "$n" ]]; then
    echo "$TOOL: paragraph count mismatch: expected $n, got $paras" >&2
    HARD_FAIL=1
  fi

  rung="$OUT/parts/size-$n.json"
  jq -n \
    --argjson n "$n" \
    --argjson bytes "${bytes:-0}" \
    --argjson paragraphs "${paras:-null}" \
    --argjson chars "${chars:-null}" \
    --argjson create_add_ms "$create_add_ms" \
    --argjson validate_ms "$validate_ms" \
    --argjson validate_ok "$validate_ok" \
    --argjson stats_ms "$stats_ms" \
    --argjson issues_ms "$issues_ms" \
    --argjson text_ms "$text_ms" \
    --argjson render_ms "${render_ms:-null}" \
    --argjson pages "${pages:-null}" \
    --arg rss_kb "${rss:-}" \
    --arg lo_fonts "$lo_fonts" \
    '{paragraphs:$paragraphs, bytes:$bytes, total_characters:$chars,
      create_add_ms:$create_add_ms, validate_ms:$validate_ms, validate_ok:$validate_ok,
      stats_ms:$stats_ms, issues_ms:$issues_ms, text_ms:$text_ms,
      render_ms:$render_ms, pages:$pages,
      rss_kb:(if $rss_kb=="" then null else ($rss_kb|tonumber) end),
      ms_per_paragraph:(if $n>0 then ($create_add_ms/$n*100|round/100) else null end),
      lo_fonts:($lo_fonts|split("\n")|map(select(length>0)))}' > "$rung"
  RUNG_JSON_FILES+=("$rung")
  printf 'large-document: %s paragraphs -> create+add %sms, validate %sms, render %sms, %s bytes\n' \
    "$n" "$create_add_ms" "$validate_ms" "${render_ms:-n/a}" "$bytes" >&2
done

# CLI per-process overhead: N isolated adds vs one batch of N.
overhead_json='null'
if ((OVERHEAD > 0)); then
  odocx="$OUT/docs/overhead.docx"
  rm -f -- "$odocx"
  officecli create "$odocx" --locale zh-CN >/dev/null 2>&1
  t0="$(now_ms)"
  for i in $(seq 1 "$OVERHEAD"); do
    officecli add "$odocx" /body --type paragraph --prop "text=第 $i 段 isolated add。" >/dev/null 2>&1 || true
  done
  t1="$(now_ms)"
  officecli close "$odocx" >/dev/null 2>&1 || true
  single_total_ms=$(( t1 - t0 ))
  single_per_ms=$(( single_total_ms / OVERHEAD ))

  bdocx="$OUT/docs/overhead-batch.docx"
  rm -f -- "$bdocx"
  officecli create "$bdocx" --locale zh-CN >/dev/null 2>&1
  jq -n --argjson n "$OVERHEAD" \
    '[ range(0;$n)|{command:"add",parent:"/body",type:"paragraph",props:{text:("第 "+(.|tostring)+" 段 batch add。")}} ]' \
    > "$TMP/overhead-batch.json"
  t0="$(now_ms)"
  officecli batch "$bdocx" --input "$TMP/overhead-batch.json" >/dev/null 2>&1 || true
  officecli close "$bdocx" >/dev/null 2>&1 || true
  t1="$(now_ms)"
  batch_total_ms=$(( t1 - t0 ))

  overhead_json="$(jq -n \
    --argjson invocations "$OVERHEAD" \
    --argjson single_total_ms "$single_total_ms" \
    --argjson single_per_ms "$single_per_ms" \
    --argjson batch_total_ms "$batch_total_ms" \
    '{invocations:$invocations, isolated_total_ms:$single_total_ms,
      isolated_per_invocation_ms:$single_per_ms, batch_total_ms:$batch_total_ms,
      speedup:(if $batch_total_ms>0 then (($single_total_ms/$batch_total_ms*10|round)/10) else null end)}')"
fi

# ---------------------------------------------------------------------------
# Section 2: missing fonts
# ---------------------------------------------------------------------------
MISSING_FONTS=("Microsoft YaHei" "方正书宋" "Arial Black")

font_presence_json='[]'
host_font_rows=()
for f in "${MISSING_FONTS[@]}"; do
  match_family=""
  if command -v fc-match >/dev/null; then
    match_family="$(fc-match "$f" -f '%{family}' 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$match_family" ]]; then
    status="unknown"
  elif [[ "${match_family,,}" == "${f,,}"* || "${match_family,,}" == *"${f,,}"* ]]; then
    status="present"
  else
    status="absent"
  fi
  host_font_rows+=("| \`$f\` | \`${match_family:-?}\` | $status |")
  font_presence_json="$(jq -c --arg f "$f" --arg m "$match_family" --arg s "$status" \
    '. + [{font:$f, fc_match:$m, status:$s}]' <<<"$font_presence_json")"
done

mfdoc="$OUT/missing/missing-font.docx"
rm -f -- "$mfdoc"
officecli create "$mfdoc" --locale en-US >/dev/null 2>&1
jq -n '[
  {command:"add",parent:"/body",type:"paragraph",
   props:{text:"YaHei 微软雅黑 中文 English 123", "font.ea":"Microsoft YaHei", "font.latin":"Arial Black", "font.hint":"eastAsia"}},
  {command:"add",parent:"/body",type:"paragraph",
   props:{text:"FZSong 方正书宋 中文 English 123", "font.ea":"方正书宋", "font.latin":"Arial Black", "font.hint":"eastAsia"}}
]' > "$TMP/missing-font.json"
officecli batch "$mfdoc" --input "$TMP/missing-font.json" >/dev/null 2>&1
officecli close "$mfdoc" >/dev/null 2>&1 || true

mf_validate_ok=false
mf_validate_out="$(timeout "$DEFAULT_TMO" officecli validate "$mfdoc" 2>&1)" || true
[[ "$mf_validate_out" == *"no errors"* ]] && mf_validate_ok=true
mf_issues_count="$(timeout "$DEFAULT_TMO" officecli view "$mfdoc" issues --json 2>/dev/null | jq -r '.data.count // null' 2>/dev/null || echo null)"
# Any font-availability complaint? OfficeCLI models none; record the message set.
mf_issue_msgs="$(timeout "$DEFAULT_TMO" officecli view "$mfdoc" issues --json 2>/dev/null | jq -c '[.data.issues[]?.message] // []' 2>/dev/null || echo '[]')"

mf_lo_pdf="$OUT/missing/missing-font.lo.pdf"
mf_lo_fonts='[]'
if ((DO_RENDER)) && command -v soffice >/dev/null; then
  render_pdf "$mfdoc" "$mf_lo_pdf" || true
  if [[ -s "$mf_lo_pdf" ]]; then
    mf_lo_fonts="$(pdf_fonts "$mf_lo_pdf" | jq -R . | jq -s .)"
  fi
fi

# Same render with the user font directory hidden (simulates stock Linux, where
# the host's copied Windows fonts are not visible). System fonts still apply.
mf_lo_stock_pdf="$OUT/missing/missing-font.lo-stock.pdf"
mf_lo_stock_fonts='[]'
if ((DO_RENDER)) && command -v soffice >/dev/null; then
  empty_home="$TMP/empty-home"
  mkdir -p -- "$empty_home"
  XDG_DATA_HOME="$empty_home" render_pdf "$mfdoc" "$mf_lo_stock_pdf" || true
  if [[ -s "$mf_lo_stock_pdf" ]]; then
    mf_lo_stock_fonts="$(pdf_fonts "$mf_lo_stock_pdf" | jq -R . | jq -s .)"
  fi
fi

# Word / WPS COM open (read-only) + PDF export, serialized with flock.
mf_com_json='[]'
PS_BIN="${WF_POWERSHELL:-$DEFAULT_PS}"
HAVE_WINDOWS=0
if ((DO_COM)) && [[ -x "$PS_BIN" ]] && [[ -d /mnt/c/Windows ]]; then HAVE_WINDOWS=1; fi
if ((HAVE_WINDOWS)); then
  RUN_ID="$(date +%s)-$$"
  STAGE="$STAGE_WSL/$RUN_ID"
  if mkdir -p "$STAGE" 2>/dev/null; then
    cp -f -- "$mfdoc" "$STAGE/missing-font.docx"
    p="${STAGE#/mnt/}"; drive="${p:0:1}"; rest="${p:1}"
    STAGE_WIN="${drive^^}:${rest//\//\\}"
    cat > "$STAGE/com.ps1" <<'PS1'
param([string]$ProgId,[string]$Path,[string]$Out)
$ErrorActionPreference='Stop'
try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}
function B64([string]$s){ if([string]::IsNullOrEmpty($s)){return $null}; return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
$r=[ordered]@{progid=$ProgId;started=$false;opened=$false;version=$null;pages=$null;pdf=$false;error_b64=$null}
$app=$null
try{
  $app=New-Object -ComObject $ProgId
  $r.started=$true
  try{$app.Visible=$false}catch{}
  try{$app.DisplayAlerts=0}catch{}
  try{$app.AutomationSecurity=1}catch{}
  try{$r.version=[string]$app.Version}catch{}
  $doc=$app.Documents.Open($Path,$false,$true)
  $r.opened=$true
  try{$r.pages=[int]$doc.ComputeStatistics(2)}catch{}
  try{$doc.ExportAsFixedFormat($Out,17); for($i=0;$i -lt 40 -and -not (Test-Path $Out);$i++){Start-Sleep -Milliseconds 250}; $r.pdf=(Test-Path $Out)}catch{$r.error_b64=(B64 $_.Exception.Message)}
  try{$doc.Close($false)}catch{}
}catch{ $r.error_b64=(B64 $_.Exception.Message) }
finally{ if($app -ne $null){ try{$app.Quit()}catch{}; try{[System.Runtime.InteropServices.Marshal]::ReleaseComObject($app)|Out-Null}catch{} } }
$r|ConvertTo-Json -Compress -Depth 5
PS1
    com_records='[]'
    for spec in "word:Word.Application:WINWORD.EXE" "wps:KWPS.Application:wps.exe"; do
      app="${spec%%:*}"; rest="${spec#*:}"; prog="${rest%%:*}"; img="${rest##*:}"
      win_pdf="$STAGE_WIN\\missing-font.$app.pdf"
      wsl_pdf="$STAGE/missing-font.$app.pdf"
      out=""
      if out="$(flock -w 1800 "$COM_LOCK" timeout "$DEFAULT_TMO" "$PS_BIN" -NoProfile -ExecutionPolicy Bypass \
            -File "$STAGE_WIN\\com.ps1" -ProgId "$prog" -Path "$STAGE_WIN\\missing-font.docx" -Out "$win_pdf" 2>/dev/null)"; then :; fi
      out="$(tr -d '\r' <<<"$out")"
      if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
        out='{"started":false,"opened":false,"error_b64":null}'
      fi
      fonts='[]'
      [[ -s "$wsl_pdf" ]] && fonts="$(pdf_fonts "$wsl_pdf" | jq -R . | jq -s .)"
      rec="$(jq -nc --arg app "$app" --argjson r "$out" --argjson fonts "$fonts" '
        {app:$app,
         available:($r.started//false),
         opens_without_repair:($r.opened//false),
         version:($r.version//null),
         pages:($r.pages//null),
         pdf_exported:($r.pdf//false),
         error:(if ($r.error_b64//null)!=null then ($r.error_b64|@base64d) else null end),
         fonts:$fonts}')"
      com_records="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$com_records")"
      # The PS1 quits the application in its finally block. Do not taskkill by
      # image name: that would close a user's own open Word/WPS window.
      : "$img"
    done
    mf_com_json="$com_records"
    rm -rf -- "$STAGE" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
rungs_json="$(jq -s '.' "${RUNG_JSON_FILES[@]}")"

# Degradation: does per-paragraph cost rise with document size? A sub-linear or
# flat curve is fine; `degrading` is true only when the largest rung costs more
# than twice per paragraph than the smallest.
degradation_json="$(jq '
  (sort_by(.paragraphs)) as $s
  | (if ($s|length)>0 then $s[0].ms_per_paragraph else null end) as $first
  | (if ($s|length)>0 then $s[-1].ms_per_paragraph else null end) as $last
  | {smallest_ms_per_paragraph:$first, largest_ms_per_paragraph:$last,
     per_paragraph_trend:(if ($first!=null and $first>0) then ((($last/$first)*100|round)/100) else null end),
     degrading:(if ($first!=null and $first>0) then ($last > 2*$first) else false end),
     growth:{ validate_ms:(if $s[0].validate_ms>0 then (($s[-1].validate_ms/$s[0].validate_ms*100|round)/100) else null end),
              render_ms:(if (($s[0].render_ms//0)>0) then ((($s[-1].render_ms//0)/($s[0].render_ms)*100|round)/100) else null end),
              bytes:(if $s[0].bytes>0 then (($s[-1].bytes/$s[0].bytes*100|round)/100) else null end) },
     rungs:[$s[]|{paragraphs,ms_per_paragraph,bytes,validate_ms,render_ms,pages}]}' <<<"$rungs_json")"

result="$(jq -n \
  --arg tool "$TOOL" \
  --arg version "$(officecli --version 2>/dev/null | head -1)" \
  --arg host "$(uname -srmo 2>/dev/null || uname -a)" \
  --arg sizes "$SIZES" \
  --argjson rungs "$rungs_json" \
  --argjson degradation "$degradation_json" \
  --argjson overhead "$overhead_json" \
  --argjson font_presence "$font_presence_json" \
  --argjson mf_validate_ok "$mf_validate_ok" \
  --argjson mf_issues_count "${mf_issues_count:-null}" \
  --argjson mf_issue_msgs "$mf_issue_msgs" \
  --argjson mf_lo_fonts "$mf_lo_fonts" \
  --argjson mf_lo_stock_fonts "$mf_lo_stock_fonts" \
  --argjson mf_com "$mf_com_json" \
  '{tool:$tool, officecli:$version, host:$host, sizes:$sizes,
    large_documents:{rungs:$rungs, degradation:$degradation, cli_overhead:$overhead},
    missing_fonts:{named_fonts:[$font_presence[].font],
      font_presence:$font_presence,
      validate_ok:$mf_validate_ok, issues_count:$mf_issues_count, issue_messages:$mf_issue_msgs,
      libreoffice_fonts:$mf_lo_fonts, libreoffice_stock_fonts:$mf_lo_stock_fonts,
      com:$mf_com}}')"
printf '%s\n' "$result" > "$OUT/result.json"

# Human summary.
{
  echo "# Large-document / missing-font probe — observed results"
  echo
  echo "- OfficeCLI: \`$(officecli --version 2>/dev/null | head -1)\`"
  echo "- Host: \`$(uname -srmo 2>/dev/null || uname -a)\`"
  echo
  echo "## Large documents"
  echo
  echo "| paragraphs | bytes | create+add ms | validate ms | stats ms | issues ms | text ms | render ms | pages | peak RSS KB | ms/para |"
  echo "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  jq -r '.large_documents.rungs[] | "| \(.paragraphs) | \(.bytes) | \(.create_add_ms) | \(.validate_ms) | \(.stats_ms) | \(.issues_ms) | \(.text_ms) | \(.render_ms // "-") | \(.pages // "-") | \(.rss_kb // "-") | \(.ms_per_paragraph) |"' <<<"$result"
  echo
  echo "- create+add per-paragraph trend (largest/smallest): \`$(jq -c '.large_documents.degradation | {smallest_ms_per_paragraph, largest_ms_per_paragraph, per_paragraph_trend, degrading, growth}' <<<"$result")\`"
  echo "- CLI overhead: \`$(jq -c '.large_documents.cli_overhead' <<<"$result")\`"
  echo
  echo "## Missing fonts"
  echo
  echo "| named font | fc-match family | status on this host |"
  echo "|---|---|---|"
  printf '%s\n' "${host_font_rows[@]}"
  echo
  echo "- officecli validate: \`$(jq -r '.missing_fonts.validate_ok' <<<"$result")\`; issues: \`$(jq -r '.missing_fonts.issues_count' <<<"$result")\`"
  echo "- LibreOffice embedded fonts (host fonts visible): \`$(jq -c '.missing_fonts.libreoffice_fonts' <<<"$result")\`"
  echo "- LibreOffice embedded fonts (user fonts hidden): \`$(jq -c '.missing_fonts.libreoffice_stock_fonts' <<<"$result")\`"
  echo "- Word/WPS COM: \`$(jq -c '.missing_fonts.com' <<<"$result")\`"
} > "$OUT/summary.md"

if ((HARD_FAIL)); then
  echo "$TOOL: a hard invariant failed (see stderr)" >&2
  exit 1
fi

if ((JSON)); then
  printf '%s\n' "$result"
else
  cat "$OUT/summary.md"
  echo
  echo "wrote $OUT/result.json and $OUT/summary.md" >&2
fi
