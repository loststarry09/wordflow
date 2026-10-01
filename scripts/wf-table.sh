#!/usr/bin/env bash
#
# WordFlow table primitive (#21).
#
# Builds one table in a new output document, through OfficeCLI, from
# CSV-ish `--data`. It covers the three table constructions the spec promotes
# to fully supported (spec `docs/spec/v0.1.md` §D8/§D9):
#
#   regular tables     fixed layout, explicit colWidths, direct borders;
#   merged-cell tables a horizontal span (colspan -> w:gridSpan) and a vertical
#                      merge (vmerge restart/continue -> w:vMerge);
#   nested tables      a table added inside a host cell, built with the portable
#                      construction measured in the #4 research
#                      (references/research/nested-tables.md).
#
# Portable construction (#4, spec §D8): fixed layout, explicit `colWidths`,
# direct borders, and `tblW == sum(colWidths)` at every nesting level. OfficeCLI
# exposes the merge semantics as native cell properties — `colspan` and `vmerge`
# — which emit standard `w:gridSpan` / `w:vMerge`; no `raw-set` is needed.
#
# Styling stays inside the frozen standard style set (spec §D7): when the output
# defines `BodyNoIndent` (the no-first-line-indent body style), every table cell
# paragraph is switched to it so table text is not indented. No new style is
# defined or referenced; a document without that style is left on its default.
#
# The source document is never modified (ADR-0003): the source bytes are copied
# to --out and every DOCX read/write is performed on --out through OfficeCLI.
#
# Usage:
#   scripts/wf-table.sh <source.docx> --out <output.docx> --data <cells> \
#     --col-widths W1,W2 [--width L] [--header-row] [--merge R,C,ROWS,COLS]... \
#     [--nested-cell R,C --nested-data <cells> --nested-col-widths W1,W2 ...] \
#     [--report <file>] [--json]
#
# Exit codes: 0 = table built; 1 = OfficeCLI could not read/write a document;
#             2 = bad usage / missing dependency.
#
set -euo pipefail

readonly TOOL="wf-table.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"

# A one-twip allowance absorbs cm/pt -> twips rounding; the #4 evidence shows
# WPS only diverges when tblW and the column sum disagree by more than this.
readonly TOL=2

usage() {
  cat <<'EOF'
Usage: wf-table.sh <source.docx> --out <output.docx> --data <cells> [options]

Build one table in a new output document from CSV-ish data. The source is never
modified; the result is written to --out. The table uses the portable
construction: fixed layout, explicit colWidths, direct borders, and
tblW == sum(colWidths).

Data:
  --data <cells>            Semicolon-separated rows, comma-separated cells,
                            e.g. "H1,H2;R1C1,R1C2". Required.
  --col-widths <w1,w2,...>  Per-column widths in twips. Required; one per column.
  --width <length>          Table width (twips, or cm/in/pt). Optional; defaults
                            to the sum of --col-widths, which is the portable
                            value. A supplied width that disagrees with the sum
                            (beyond one twip) is rejected.
  --header-row              Repeat the first row as a header on every page.
  --border <spec>           Direct cell borders, default "single;8;000000".
  --merge <R,C,ROWS,COLS>   Merge a rectangle of grid cells, 1-based, starting at
                            row R and column C and spanning ROWS rows and COLS
                            columns. Repeatable. Examples: --merge 1,1,1,2 joins
                            columns 1-2 of row 1; --merge 2,1,2,1 joins rows 2-3
                            of column 1; --merge 1,1,2,2 joins a 2x2 block. Leave
                            the cells a vertical span covers empty in --data.

Nested table (optional):
  --nested-cell <R,C>       Host cell (1-based grid row, column) for a nested table.
  --nested-data <cells>     Nested table data (required with --nested-cell).
  --nested-col-widths <..>  Nested per-column widths in twips (required).
  --nested-width <length>   Nested width; defaults to the sum of the nested widths.
  --nested-layout <mode>    fixed | autofit (default fixed). Autofit is unverified
                            for nested tables and emits the nested-table warning.
  --nested-border <spec>    Nested direct borders, default "single;8;C00000".

Report:
  --report <file>           Write the change report (#28) to this path. Optional;
                            without it a temporary report is used and embedded in
                            the JSON output.
  --json                    Emit the JSON report instead of text.
  -h, --help                Show this help.
EOF
}

die_usage() { echo "$TOOL: $*" >&2; usage >&2; exit 2; }
die() { echo "$TOOL: $*" >&2; exit 1; }

SRC=""; OUT=""; DATA=""; COLW=""
WIDTH=""; WIDTH_SET=0
HEADER_ROW=0
BORDER="single;8;000000"
REPORT_OUT=""
JSON=0
declare -a MERGE_SPECS=()
NESTED_CELL=""; NESTED_DATA=""; NESTED_COLW=""; NESTED_WIDTH=""
NESTED_LAYOUT="fixed"; NESTED_BORDER="single;8;C00000"

while (($#)); do
  case "$1" in
    --out)               (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --data)              (($# >= 2)) || { echo "--data requires a value" >&2; exit 2; }; DATA="$2"; shift 2 ;;
    --col-widths)        (($# >= 2)) || { echo "--col-widths requires a value" >&2; exit 2; }; COLW="$2"; shift 2 ;;
    --width)             (($# >= 2)) || { echo "--width requires a value" >&2; exit 2; }; WIDTH="$2"; WIDTH_SET=1; shift 2 ;;
    --header-row)        HEADER_ROW=1; shift ;;
    --border)            (($# >= 2)) || { echo "--border requires a value" >&2; exit 2; }; BORDER="$2"; shift 2 ;;
    --merge)             (($# >= 2)) || { echo "--merge requires a value" >&2; exit 2; }; MERGE_SPECS+=("$2"); shift 2 ;;
    --nested-cell)       (($# >= 2)) || { echo "--nested-cell requires a value" >&2; exit 2; }; NESTED_CELL="$2"; shift 2 ;;
    --nested-data)       (($# >= 2)) || { echo "--nested-data requires a value" >&2; exit 2; }; NESTED_DATA="$2"; shift 2 ;;
    --nested-col-widths) (($# >= 2)) || { echo "--nested-col-widths requires a value" >&2; exit 2; }; NESTED_COLW="$2"; shift 2 ;;
    --nested-width)      (($# >= 2)) || { echo "--nested-width requires a value" >&2; exit 2; }; NESTED_WIDTH="$2"; shift 2 ;;
    --nested-layout)     (($# >= 2)) || { echo "--nested-layout requires a value" >&2; exit 2; }; NESTED_LAYOUT="$2"; shift 2 ;;
    --nested-border)     (($# >= 2)) || { echo "--nested-border requires a value" >&2; exit 2; }; NESTED_BORDER="$2"; shift 2 ;;
    --report)            (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT_OUT="$2"; shift 2 ;;
    --json)              JSON=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)                   [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]] || { usage >&2; exit 2; }
[[ -n "$OUT" ]] || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -n "$DATA" ]] || { echo "--data is required" >&2; usage >&2; exit 2; }
[[ -n "$COLW" ]] || { echo "--col-widths is required" >&2; usage >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq sha256sum cp awk; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
[[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
[[ -x "$RISK" ]] || { echo "risk-policy tool not executable: $RISK" >&2; exit 2; }

# --- validate the numeric inputs (the judgement WordFlow owns) --------------
[[ "$COLW" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "invalid --col-widths: $COLW (comma-separated twips)" >&2; exit 2; }
len_re='^[0-9]+([.][0-9]+)?(cm|in|pt)?$'
if ((WIDTH_SET)); then
  [[ "$WIDTH" =~ $len_re ]] || { echo "invalid --width: $WIDTH (twips, or cm/in/pt)" >&2; exit 2; }
fi
for spec in "${MERGE_SPECS[@]+"${MERGE_SPECS[@]}"}"; do
  [[ "$spec" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] || { echo "invalid --merge: $spec (R,C,ROWS,COLS)" >&2; exit 2; }
done
if [[ -n "$NESTED_CELL" ]]; then
  [[ "$NESTED_CELL" =~ ^[0-9]+,[0-9]+$ ]] || { echo "invalid --nested-cell: $NESTED_CELL (R,C)" >&2; exit 2; }
  [[ -n "$NESTED_DATA" ]] || { echo "--nested-cell requires --nested-data" >&2; exit 2; }
  [[ -n "$NESTED_COLW" ]] || { echo "--nested-cell requires --nested-col-widths" >&2; exit 2; }
  [[ "$NESTED_COLW" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "invalid --nested-col-widths: $NESTED_COLW" >&2; exit 2; }
  case "$NESTED_LAYOUT" in fixed|autofit) ;; *) echo "invalid --nested-layout: $NESTED_LAYOUT (fixed|autofit)" >&2; exit 2 ;; esac
  if [[ -n "$NESTED_WIDTH" ]]; then
    [[ "$NESTED_WIDTH" =~ $len_re ]] || { echo "invalid --nested-width: $NESTED_WIDTH" >&2; exit 2; }
  fi
else
  [[ -z "$NESTED_DATA$NESTED_COLW$NESTED_WIDTH" ]] || { echo "--nested-* requires --nested-cell" >&2; exit 2; }
fi

TMO="timeout 60"
abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"

[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

# twips_of <length> — cm/in/pt/bare-twips to integer twips; 1 if unparseable.
twips_of() {
  local v="$1"
  case "$v" in
    *cm) awk -v n="${v%cm}" 'BEGIN{printf "%.0f", n*1440/2.54}' ;;
    *in) awk -v n="${v%in}" 'BEGIN{printf "%.0f", n*1440}' ;;
    *pt) awk -v n="${v%pt}" 'BEGIN{printf "%.0f", n*20}' ;;
    *[!0-9]*) return 1 ;;
    *) printf '%s' "$v" ;;
  esac
}

sum_csv() { awk -F, '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%d", s}' <<<"$1"; }

create_report() {
  local dst="$1"
  "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$dst" >/dev/null
}
report_add() { "$CHANGE_REPORT" add --report "$1" --area "$2" --entry "$3" >/dev/null; }

# --- copy the bytes, then build through OfficeCLI ---------------------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

TMP_REPORT=""
cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  [[ -n "$TMP_REPORT" ]] && rm -f "$TMP_REPORT"
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

REPORT_FILE="$REPORT_OUT"
if [[ -z "$REPORT_FILE" ]]; then
  TMP_REPORT="$(mktemp)"
  REPORT_FILE="$TMP_REPORT"
fi
create_report "$REPORT_FILE"

col_sum="$(sum_csv "$COLW")"
if ((WIDTH_SET)); then
  width_tw="$(twips_of "$WIDTH")" || { echo "invalid --width: $WIDTH" >&2; exit 2; }
  diff=$(( width_tw - col_sum )); if ((diff < 0)); then diff=$(( -diff )); fi
  if ((diff > TOL)); then
    echo "--width ($WIDTH = ${width_tw} twips) must equal sum(--col-widths) (${col_sum} twips):" >&2
    echo "the portable construction requires tblW == sum(colWidths) (see references/research/nested-tables.md)" >&2
    exit 2
  fi
  eff_width="$WIDTH"
else
  eff_width="$col_sum"
fi

# --- 1. the outer table -----------------------------------------------------
$TMO officecli add "$out_abs" /body --type table \
  --prop data="$DATA" --prop layout=fixed \
  --prop colWidths="$COLW" --prop width="$eff_width" \
  --prop border.all="$BORDER" >/dev/null

tbl_json="$($TMO officecli get "$out_abs" /body/tbl[1] --json)"
jq -e '.success == true' <<<"$tbl_json" >/dev/null 2>&1 || { die "OfficeCLI could not read the built table"; }
grid_cols="$(jq -r '.data.results[0].format._gridCols // .data.results[0].format.cols' <<<"$tbl_json")"
table_rows="$(jq -r '.data.results[0].format.rows' <<<"$tbl_json")"
[[ "$grid_cols" =~ ^[0-9]+$ && "$table_rows" =~ ^[0-9]+$ ]] || { echo "could not determine table dimensions" >&2; exit 1; }

# --- 2. merges (horizontal span, then vertical merge markers) ---------------
declare -a M_R=() M_C=() M_RS=() M_CS=()
declare -A CELL_OWNER=()
merge_idx=0
for spec in "${MERGE_SPECS[@]+"${MERGE_SPECS[@]}"}"; do
  IFS=, read -r mr mc mrs mcs <<<"$spec"
  (( mr >= 1 && mr <= table_rows )) || { echo "--merge $spec: row $mr out of range (1..$table_rows)" >&2; exit 2; }
  (( mc >= 1 && mc <= grid_cols )) || { echo "--merge $spec: column $mc out of range (1..$grid_cols)" >&2; exit 2; }
  (( mrs >= 1 )) || { echo "--merge $spec: ROWS must be >= 1" >&2; exit 2; }
  (( mcs >= 1 )) || { echo "--merge $spec: COLS must be >= 1" >&2; exit 2; }
  (( mrs > 1 || mcs > 1 )) || { echo "--merge $spec: a merge must span more than one cell" >&2; exit 2; }
  (( mr + mrs - 1 <= table_rows )) || { echo "--merge $spec: vertical span exceeds the table" >&2; exit 2; }
  (( mc + mcs - 1 <= grid_cols )) || { echo "--merge $spec: horizontal span exceeds the table" >&2; exit 2; }
  for ((rr=mr; rr<mr+mrs; rr++)); do
    for ((cc=mc; cc<mc+mcs; cc++)); do
      key="$rr,$cc"
      if [[ -n "${CELL_OWNER[$key]:-}" ]]; then
        echo "--merge $spec overlaps an earlier merge at cell $rr,$cc" >&2; exit 2
      fi
      CELL_OWNER[$key]=1
    done
  done
  M_R[$merge_idx]="$mr"; M_C[$merge_idx]="$mc"; M_RS[$merge_idx]="$mrs"; M_CS[$merge_idx]="$mcs"
  merge_idx=$((merge_idx + 1))
done

# shift_for <row> <col> — grid columns consumed by horizontal spans that start
# before <col> in <row>; the DOM cell index is col - shift.
shift_for() {
  local row="$1" col="$2" i sh=0
  for i in "${!M_R[@]}"; do
    if [[ "${M_R[$i]}" == "$row" ]] && (( ${M_CS[$i]} > 1 )) && (( ${M_C[$i]} < col )); then
      sh=$(( sh + ${M_CS[$i]} - 1 ))
    fi
  done
  printf '%s' "$sh"
}
dom_index() { local row="$1" col="$2"; printf '%s' "$(( col - $(shift_for "$row" "$col") ))"; }

# 2a. horizontal spans, in increasing (row, col)
if ((${#M_R[@]})); then
  mapfile -t _order < <(
    for i in "${!M_R[@]}"; do printf '%s %s %s\n' "${M_R[$i]}" "${M_C[$i]}" "$i"; done \
      | sort -k1,1n -k2,2n | awk '{print $3}'
  )
  for i in "${_order[@]}"; do
    (( ${M_CS[$i]} > 1 )) || continue
    di="$(dom_index "${M_R[$i]}" "${M_C[$i]}")"
    $TMO officecli set "$out_abs" "/body/tbl[1]/tr[${M_R[$i]}]/tc[$di]" --prop colspan="${M_CS[$i]}" >/dev/null
  done
fi

# 2b. vertical merges: restart on the top cell, continue below
if ((${#M_R[@]})); then
  for i in "${!M_R[@]}"; do
    (( ${M_RS[$i]} > 1 )) || continue
    di="$(dom_index "${M_R[$i]}" "${M_C[$i]}")"
    $TMO officecli set "$out_abs" "/body/tbl[1]/tr[${M_R[$i]}]/tc[$di]" --prop vmerge=restart >/dev/null
    for ((rr=${M_R[$i]}+1; rr<${M_R[$i]}+${M_RS[$i]}; rr++)); do
      dj="$(dom_index "$rr" "${M_C[$i]}")"
      $TMO officecli set "$out_abs" "/body/tbl[1]/tr[$rr]/tc[$dj]" --prop vmerge=continue >/dev/null
    done
  done
fi

# --- 3. repeating header row ------------------------------------------------
if ((HEADER_ROW)); then
  $TMO officecli set "$out_abs" /body/tbl[1]/tr[1] --prop header=true >/dev/null
fi

# --- 4. optional nested table ----------------------------------------------
nested_path=""
nested_requested=0
if [[ -n "$NESTED_CELL" ]]; then
  nested_requested=1
  IFS=, read -r nc nr <<<"$NESTED_CELL"
  (( nc >= 1 && nc <= table_rows )) || { echo "--nested-cell row $nc out of range (1..$table_rows)" >&2; exit 2; }
  (( nr >= 1 && nr <= grid_cols )) || { echo "--nested-cell column $nr out of range (1..$grid_cols)" >&2; exit 2; }
  # The host must be the leading cell of its rectangle (not a consumed cell).
  for i in "${!M_R[@]}"; do
    if (( nc >= ${M_R[$i]} && nc < ${M_R[$i]}+${M_RS[$i]} && nr >= ${M_C[$i]} && nr < ${M_C[$i]}+${M_CS[$i]} )); then
      (( nc == ${M_R[$i]} && nr == ${M_C[$i]} )) || { echo "--nested-cell $NESTED_CELL is inside a merged cell; host the nested table on the merge's leading cell" >&2; exit 2; }
    fi
  done
  nested_sum="$(sum_csv "$NESTED_COLW")"
  if [[ -n "$NESTED_WIDTH" ]]; then
    nw_tw="$(twips_of "$NESTED_WIDTH")" || { echo "invalid --nested-width: $NESTED_WIDTH" >&2; exit 2; }
    ndiff=$(( nw_tw - nested_sum )); if ((ndiff < 0)); then ndiff=$(( -ndiff )); fi
    (( ndiff <= TOL )) || { echo "--nested-width must equal sum(--nested-col-widths) (${nested_sum} twips)" >&2; exit 2; }
    nested_eff="$NESTED_WIDTH"
  else
    nested_eff="$nested_sum"
  fi
  ndom="$(dom_index "$nc" "$nr")"
  nested_path="/body/tbl[1]/tr[$nc]/tc[$ndom]/tbl[1]"
  $TMO officecli add "$out_abs" "/body/tbl[1]/tr[$nc]/tc[$ndom]" --type table \
    --prop data="$NESTED_DATA" --prop layout="$NESTED_LAYOUT" \
    --prop colWidths="$NESTED_COLW" --prop width="$nested_eff" \
    --prop border.all="$NESTED_BORDER" >/dev/null
fi

# --- 5. standard-set styling of table text (no new style is defined) --------
declare -a style_entries=()
style_applied=false
if $TMO officecli get "$out_abs" /styles --json 2>/dev/null \
     | jq -e '[.data.results[].children[]? | select(.type=="style") | .format.styleId] | index("BodyNoIndent") != null' >/dev/null 2>&1; then
  mapfile -t cell_paras < <(
    $TMO officecli query "$out_abs" paragraph --json 2>/dev/null \
      | jq -r '.data.results[].path | select(test("/tbl\\["))'
  )
  if ((${#cell_paras[@]} > 0)); then
    cmds="$(printf '%s\n' "${cell_paras[@]}" | jq -R . \
      | jq -sc '[.[] | {command:"set", path:., props:{style:"BodyNoIndent"}}]')"
    $TMO officecli batch "$out_abs" --commands "$cmds" >/dev/null
    style_applied=true
    style_entries=("Table text: applied the standard BodyNoIndent style (no first-line indent) to ${#cell_paras[@]} table cell paragraph(s); no new style defined.")
  fi
fi

# --- 6. read the result back (evidence) ------------------------------------
tbl_json="$($TMO officecli get "$out_abs" /body/tbl[1] --json)"
jq -e '.success == true' <<<"$tbl_json" >/dev/null 2>&1 || { die "OfficeCLI could not read the table back"; }
obs_first_colwidth="$(jq -r '.data.results[0].format.colWidths // ""' <<<"$tbl_json" | sed 's/dxa//g')"
obs_width="$(jq -r '.data.results[0].format.width // ""' <<<"$tbl_json")"
obs_layout="$(jq -r '.data.results[0].format.layout // ""' <<<"$tbl_json")"
obs_rows="$(jq -r '.data.results[0].format.rows // ""' <<<"$tbl_json")"
obs_gridcols="$(jq -r '.data.results[0].format._gridCols // .data.results[0].format.cols // ""' <<<"$tbl_json")"

header_obs=false
if ((HEADER_ROW)); then
  hdr="$($TMO officecli get "$out_abs" /body/tbl[1]/tr[1] --json | jq -r '.data.results[0].format.header // false')"
  [[ "$hdr" == "true" ]] && header_obs=true
fi

# observed merges: [{row,col,rowspan,colspan,gridspan,vmerge}]
merges_obs="[]"
if ((${#M_R[@]})); then
  merges_obs="$(
    for i in "${!M_R[@]}"; do
      di="$(dom_index "${M_R[$i]}" "${M_C[$i]}")"
      fmt="$($TMO officecli get "$out_abs" "/body/tbl[1]/tr[${M_R[$i]}]/tc[$di]" --json | jq -c '.data.results[0].format')"
      jq -nc --argjson fmt "$fmt" --argjson row "${M_R[$i]}" --argjson col "${M_C[$i]}" \
        --argjson rs "${M_RS[$i]}" --argjson cs "${M_CS[$i]}" \
        '{row:$row, col:$col, rowspan:$rs, colspan:$cs,
          observed_colspan: ($fmt.colspan // 1),
          observed_vmerge: ($fmt.vmerge // null)}'
    done | jq -sc .
  )"
fi

# nested evidence + portable check
nested_json="null"
nested_portable=true
nested_reason=""
if ((nested_requested)); then
  nj="$($TMO officecli get "$out_abs" "$nested_path" --json)"
  if ! jq -e '.success == true' <<<"$nj" >/dev/null 2>&1; then
    die "OfficeCLI could not read the nested table back at $nested_path"
  fi
  n_width="$(jq -r '.data.results[0].format.width // ""' <<<"$nj")"
  n_colw_raw="$(jq -r '.data.results[0].format.colWidths // ""' <<<"$nj" | sed 's/dxa//g')"
  n_layout="$(jq -r '.data.results[0].format.layout // ""' <<<"$nj")"
  n_colw_sum="$(sum_csv "$n_colw_raw")"
  n_border="$(jq -r '.data.results[0].format["border.top"] // ""' <<<"$nj")"
  n_diff=$(( n_width - n_colw_sum )); if ((n_diff < 0)); then n_diff=$(( -n_diff )); fi
  if [[ "$n_layout" != "fixed" ]]; then nested_portable=false; nested_reason="layout is '$n_layout', not 'fixed'"; fi
  if (( n_diff > TOL )); then nested_portable=false; nested_reason="tblW=$n_width differs from sum(colWidths)=$n_colw_sum"; fi
  if [[ -z "$n_border" ]]; then nested_portable=false; nested_reason="direct borders are missing"; fi
  nested_json="$(jq -nc \
    --arg path "$nested_path" --argjson width "$n_width" --arg colw "$n_colw_raw" \
    --argjson colw_sum "$n_colw_sum" --arg layout "$n_layout" --arg border "$n_border" \
    --argjson portable "$nested_portable" \
    '{path:$path, width:$width, col_widths:($colw|split(",")), col_widths_sum:$colw_sum,
      layout:$layout, border:$border, portable:$portable}')"
fi

# --- 7. change report (risk routed through the shared policy) ---------------
report_add "$REPORT_FILE" changed \
  "Table: built a ${obs_rows} x ${obs_gridcols} fixed-layout table (colWidths $COLW; width $eff_width; borders $BORDER)."
((HEADER_ROW)) && report_add "$REPORT_FILE" changed "Table: first row repeats as a header on every page."
if ((${#M_R[@]})); then
  report_add "$REPORT_FILE" changed "Table: applied ${#M_R[@]} merged-cell rectangle(s) (colspan -> w:gridSpan, vmerge restart/continue -> w:vMerge)."
fi
if ((nested_requested)); then
  report_add "$REPORT_FILE" changed "Table: added a nested table in cell $NESTED_CELL ($nested_path)."
fi
report_add "$REPORT_FILE" decisions \
  "Table portability: fixed layout, explicit colWidths, direct borders, and tblW == sum(colWidths) (spec D8; references/research/nested-tables.md)."
if [[ "$style_applied" == "true" ]]; then report_add "$REPORT_FILE" changed "${style_entries[0]}"; fi

if ((nested_requested)) && [[ "$nested_portable" != "true" ]]; then
  "$RISK" emit --report "$REPORT_FILE" --trigger nested-table \
    --detail "nested table at $nested_path is not built with the portable construction ($nested_reason)"
fi

"$CHANGE_REPORT" validate --report "$REPORT_FILE" >/dev/null

# --- 8. source protection ---------------------------------------------------
src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- 9. report --------------------------------------------------------------
report_json="$(jq -c '.' "$REPORT_FILE")"
table_evidence="$(jq -nc \
  --argjson rows "$obs_rows" --argjson grid_cols "$obs_gridcols" --arg layout "$obs_layout" \
  --argjson width "$obs_width" --arg colw "$obs_first_colwidth" --argjson header "$header_obs" \
  --argjson merges "$merges_obs" \
  '{rows:$rows, grid_cols:$grid_cols, layout:$layout, width:$width,
    col_widths:($colw|split(",")), header_row:$header, merges:$merges}')"

report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson report "$report_json" \
  --arg report_file "$REPORT_OUT" \
  --argjson table "$table_evidence" \
  --argjson nested "$nested_json" '
  { source: $source,
    output: $output,
    source_unchanged: $source_unchanged,
    change_report: ([$report.changed[], $report.decisions[], $report.warnings[], $report.downgrades[], $report.unverified[]]),
    table: $table,
    nested_table: $nested,
    report_file: (if $report_file == "" then null else $report_file end),
    report: $report }')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow table",
  "  source:      " + .source,
  "  output:      " + .output,
  "  table:       " + (.table.rows|tostring) + " x " + (.table.grid_cols|tostring)
                    + " " + .table.layout + ", width " + (.table.width|tostring)
                    + ", colWidths " + (.table.col_widths|join(",")),
  "  header row:  " + (.table.header_row|tostring),
  "  merges:      " + ((.table.merges|length)|tostring),
  ( if .nested_table == null then "  nested:      none"
    else "  nested:      " + .nested_table.path + " (portable=" + (.nested_table.portable|tostring) + ")" end ),
  "  source kept: " + (.source_unchanged|tostring),
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
