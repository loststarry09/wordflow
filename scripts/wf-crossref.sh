#!/usr/bin/env bash
#
# WordFlow cross-references (#23) — spec `docs/spec/v0.1.md` §D8 (cross-references),
# §D9 (capability tiers).
#
# Adds one cross-reference to a document through OfficeCLI. A content reference
# (`REF`) to a bookmark is FULLY SUPPORTED: it resolves to the target's text, and
# that resolved text is written into the field's **cached result** so the reader
# never sees a placeholder. No application updates fields on open, so the cache is
# what the user sees (spec §D8; references/fields/cross-references.md).
#
# A page-number reference (`PAGEREF`, "see page N") is LIMITED: WordFlow has no
# layout engine and cannot guarantee a page number, so it is DOWNGRADED to a
# content reference and the downgrade is recorded through the shared risk policy
# (#30, trigger `preferred-unavailable` with `fallback=exists`) and in the change
# report — never silently (spec §D9, §D11).
#
# Mechanism (the #12 recipe, references/fields/cross-references.md):
#   1. the target already exists as a bookmark covering exactly the text to insert;
#   2. add the REF field: `officecli add F <para> --type field --prop fieldType=ref`;
#   3. write the resolved target text into the field's result run (the run after
#      the `separate` fldChar);
#   4. clear the `w:dirty` marker OfficeCLI adds (raw-set: the field element has no
#      `dirty` property). A placeholder cache must never ship (spec §D11/§D14).
#
# The resolved target text is read back from the bookmark through OfficeCLI and,
# after the write, re-read from the field; both must agree and contain no `«`/`»`.
#
# Source protection (ADR-0003): the source bytes are copied to --out and every
# DOCX read/write happens on --out through OfficeCLI. The byte copy is a file
# duplication, not a DOCX read or write; the source is never modified.
#
# Usage:
#   scripts/wf-crossref.sh <source.docx> --bookmark <name> --out <output.docx> \
#     [--kind ref|pageref] [--para <path>] [--report <report.json>] [--json]
#
# Exit codes: 0 = reference added; 1 = OfficeCLI could not read/write a document,
#             or the bookmark could not be resolved; 2 = bad usage / missing
#             dependency.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGE_REPORT="${WF_CHANGE_REPORT:-$SCRIPT_DIR/wf-change-report.sh}"
RISK_POLICY="${WF_RISK_POLICY:-$SCRIPT_DIR/wf-risk-policy.sh}"

usage() {
  cat <<'EOF'
Usage: wf-crossref.sh <source.docx> --bookmark <name> --out <output.docx> [options]

Add one cross-reference to a document. A content reference (ref) is fully
supported and carries the resolved target text in its cached result, so the
placeholder never ships. A page-number reference (pageref) is limited and is
downgraded to a content reference; the downgrade is reported. The source is
never modified; the result is written to --out.

Options:
  --bookmark <name>  Bookmark covering the target text (required).
  --out <file>       New output document (required; must differ from the source).
  --kind <kind>      ref (content reference, default) or pageref (page-number
                     reference; downgraded to a content reference).
  --para <path>      Paragraph to place the reference in (default /body/p[1]).
  --report <file>    Change report to create or extend (spec §D12).
  --json             Emit the report as JSON instead of text.
  -h, --help         Show this help.
EOF
}

SRC=""; BOOKMARK=""; OUT=""; KIND="ref"; PARA=""; REPORT=""; JSON=0

while (($#)); do
  case "$1" in
    --bookmark) (($# >= 2)) || { echo "--bookmark requires a value" >&2; exit 2; }; BOOKMARK="$2"; shift 2 ;;
    --out)      (($# >= 2)) || { echo "--out requires a file argument" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --kind)     (($# >= 2)) || { echo "--kind requires a value" >&2; exit 2; }; KIND="$2"; shift 2 ;;
    --para)     (($# >= 2)) || { echo "--para requires a value" >&2; exit 2; }; PARA="$2"; shift 2 ;;
    --report)   (($# >= 2)) || { echo "--report requires a file argument" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)          [[ -z "$SRC" ]] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }; SRC="$1"; shift ;;
  esac
done

[[ -n "$SRC" ]]      || { usage >&2; exit 2; }
[[ -n "$OUT" ]]      || { echo "--out is required (the source is never modified)" >&2; usage >&2; exit 2; }
[[ -n "$BOOKMARK" ]] || { echo "--bookmark is required" >&2; usage >&2; exit 2; }
case "$KIND" in
  ref|pageref) ;;
  *) echo "invalid --kind: $KIND (ref|pageref)" >&2; exit 2 ;;
esac
[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 2; }
[[ -d "$(dirname "$OUT")" ]] || { echo "output directory not found: $(dirname "$OUT")" >&2; exit 2; }
for bin in officecli jq cp sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done

abs() { local d; d="$(cd "$(dirname "$1")" && pwd)"; printf '%s/%s\n' "$d" "$(basename "$1")"; }
src_abs="$(abs "$SRC")"
out_abs="$(abs "$OUT")"
[[ "$src_abs" != "$out_abs" ]] || { echo "--out must differ from the source (ADR-0003: never modify the source)" >&2; exit 2; }

TMO="timeout 60"

# --- copy the bytes, then add the reference through OfficeCLI ----------------
src_sum_before="$(sha256sum "$src_abs" | awk '{print $1}')"

cleanup() {
  $TMO officecli close "$src_abs" >/dev/null 2>&1 || true
  $TMO officecli close "$out_abs" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT

$TMO officecli close "$out_abs" >/dev/null 2>&1 || true
cp -f "$src_abs" "$out_abs"

# Target paragraph: an explicit --para must exist; the default /body/p[1] is
# created (empty) when the document has no paragraph yet.
PARA="${PARA:-/body/p[1]}"
para_json="$($TMO officecli get "$out_abs" "$PARA" --json 2>/dev/null || true)"
[[ -n "$para_json" ]] || para_json='{}'
para_ok="$(jq -r '(.success // false) and (.data.results[0].type // "") == "paragraph"' <<<"$para_json" 2>/dev/null || echo false)"
if [[ "$para_ok" != "true" ]]; then
  if [[ "$PARA" == "/body/p[1]" ]]; then
    $TMO officecli add "$out_abs" /body --type paragraph >/dev/null
  else
    echo "target paragraph not found: $PARA" >&2
    exit 2
  fi
fi

# 1. Resolve the target text by reading the bookmark through OfficeCLI.
bm_json="$($TMO officecli get "$out_abs" "/bookmark[@name=$BOOKMARK]" --json 2>/dev/null || true)"
[[ -n "$bm_json" ]] || bm_json='{}'
resolved="$(jq -r '.data.results[0].text // ""' <<<"$bm_json" 2>/dev/null || true)"
if ! jq -e '.success == true and ((.data.results | length) > 0) and ((.data.results[0].text // "") | length > 0)' \
     >/dev/null 2>&1 <<<"$bm_json"; then
  echo "could not resolve bookmark '$BOOKMARK' in $OUT" >&2
  exit 1
fi

# 2. Add the REF field. A requested page-number reference is downgraded here:
#    WordFlow never ships a PAGEREF it cannot guarantee.
if ! $TMO officecli add "$out_abs" "$PARA" --type field --prop fieldType=ref --prop name="$BOOKMARK" >/dev/null; then
  echo "OfficeCLI could not add the reference in $OUT" >&2
  exit 1
fi

# 3. Locate the field's cached-result run: the child right after the last
#    `separate` fldChar in the paragraph (the run OfficeCLI appended for us).
result_path="$($TMO officecli get "$out_abs" "$PARA" --json 2>/dev/null | jq -r '
  .data.results[0].children as $c
  | ($c | to_entries
         | map(select(.value.type=="fieldChar" and .value.format.fieldCharType=="separate"))
         | .[-1].key) as $s
  | if ($s // null) == null then "" else ($c[$s+1].path // "") end
' 2>/dev/null || true)"
if [[ -z "$result_path" || "$result_path" == "null" ]]; then
  echo "could not locate the reference result run in $OUT" >&2
  exit 1
fi

# 4. Write the resolved target text into the cached result.
if ! $TMO officecli set "$out_abs" "$result_path" --prop text="$resolved" >/dev/null; then
  echo "OfficeCLI could not write the cached cross-reference text in $OUT" >&2
  exit 1
fi

# 5. Clear the w:dirty marker OfficeCLI adds when the cached result changes, so
#    the field is not reported as a stale cache. The field element exposes no
#    `dirty` property, so this single step is raw-set (the recorded fallback).
$TMO officecli raw-set "$out_abs" /document \
  --xpath '//w:fldChar[@w:fldCharType="begin" and @w:dirty="true"]' \
  --action replace --xml '<w:fldChar w:fldCharType="begin"/>' >/dev/null 2>&1 || true

# --- read the external behaviour back through OfficeCLI ----------------------
fields_json="$($TMO officecli query "$out_abs" field --json 2>/dev/null || true)"
[[ -n "$fields_json" ]] || fields_json='{}'
if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$fields_json"; then
  echo "OfficeCLI could not read fields back from $OUT" >&2
  exit 1
fi
field_json="$(jq -c --arg b "$BOOKMARK" '
  [ .data.results[]?
    | select((.format.instruction // "")
        | split(" ") | map(select(length > 0))
        | (.[0] == "REF" and .[1] == $b)) ] | last // {}' <<<"$fields_json")"
instruction="$(jq -r '.format.instruction // ""' <<<"$field_json")"
cached_text="$(jq -r '.text // ""' <<<"$field_json")"
dirty="$(jq -r '(.format.dirty // false) | tostring' <<<"$field_json")"

placeholder=false
[[ "$cached_text" == *"«"* || "$cached_text" == *"»"* ]] && placeholder=true

if [[ "$cached_text" != "$resolved" || "$placeholder" == "true" ]]; then
  echo "cached cross-reference text '$cached_text' does not match resolved target '$resolved' (placeholder=$placeholder)" >&2
  exit 1
fi
if [[ "$instruction" != REF* ]]; then
  echo "the reference instruction was not written: '$instruction'" >&2
  exit 1
fi

para_text="$($TMO officecli get "$out_abs" "$PARA" --json 2>/dev/null | jq -r '.data.results[0].text // ""')"
if $TMO officecli validate "$out_abs" >/dev/null 2>&1; then validates=true; else validates=false; fi

src_sum_after="$(sha256sum "$src_abs" | awk '{print $1}')"
source_unchanged=false
[[ "$src_sum_before" == "$src_sum_after" ]] && source_unchanged=true

# --- assemble the change-report entries --------------------------------------
changed_entries=(); decisions_entries=(); warnings_entries=(); downgrades_entries=(); unverified_entries=()

downgraded=false
if [[ "$KIND" == "pageref" ]]; then
  downgraded=true
  changed_entries+=("Cross-reference: requested a page-number reference to bookmark '$BOOKMARK'; added a content reference instead, cached as '$resolved'.")
  risk_detail="page-number reference to '$BOOKMARK' requested; downgraded to a content reference (WordFlow cannot guarantee a page number, spec §D9)"
  risk_json="$($TMO "$RISK_POLICY" decide --trigger preferred-unavailable --fallback exists --detail "$risk_detail" --json)"
  downgrades_entries+=("$(jq -r '.entry' <<<"$risk_json")")
else
  changed_entries+=("Cross-reference: added a content reference to bookmark '$BOOKMARK', cached as the resolved target text '$resolved'.")
fi

if [[ -n "$REPORT" ]]; then
  [[ -x "$CHANGE_REPORT" ]] || { echo "change-report tool not executable: $CHANGE_REPORT" >&2; exit 2; }
  [[ -x "$RISK_POLICY" ]]   || { echo "risk-policy tool not executable: $RISK_POLICY" >&2; exit 2; }
  if [[ ! -f "$REPORT" ]]; then
    $TMO "$CHANGE_REPORT" new --source "$SRC" --output "$OUT" --out "$REPORT" >/dev/null
  fi
  for e in ${changed_entries[@]+"${changed_entries[@]}"}; do
    $TMO "$CHANGE_REPORT" add --report "$REPORT" --area changed --entry "$e" >/dev/null
  done
  if [[ "$downgraded" == "true" ]]; then
    $TMO "$RISK_POLICY" emit --report "$REPORT" --trigger preferred-unavailable --fallback exists --detail "$risk_detail" >/dev/null
  fi
fi

json_array() { if (($# == 0)); then printf '[]'; else jq -nc --args '$ARGS.positional' "$@"; fi; }
changed_json="$(json_array ${changed_entries[@]+"${changed_entries[@]}"})"
decisions_json="$(json_array ${decisions_entries[@]+"${decisions_entries[@]}"})"
warnings_json="$(json_array ${warnings_entries[@]+"${warnings_entries[@]}"})"
downgrades_json="$(json_array ${downgrades_entries[@]+"${downgrades_entries[@]}"})"
unverified_json="$(json_array ${unverified_entries[@]+"${unverified_entries[@]}"})"

report="$(jq -nc \
  --arg source "$SRC" --arg output "$OUT" --arg bookmark "$BOOKMARK" \
  --arg requested_kind "$KIND" --arg applied_kind "ref" \
  --arg resolved "$resolved" --arg instruction "$instruction" --arg result_path "$result_path" \
  --arg para_text "$para_text" --argjson dirty "$dirty" \
  --argjson source_unchanged "$source_unchanged" \
  --argjson downgraded "$downgraded" --argjson placeholder "$placeholder" \
  --argjson validates "$validates" \
  --arg report_path "$REPORT" \
  --argjson changed "$changed_json" --argjson decisions "$decisions_json" \
  --argjson warnings "$warnings_json" --argjson downgrades "$downgrades_json" \
  --argjson unverified "$unverified_json" '
  { source: $source, output: $output,
    bookmark: $bookmark,
    requested_kind: $requested_kind, applied_kind: $applied_kind,
    downgraded: $downgraded,
    reference: { bookmark: $bookmark, instruction: $instruction,
                 resolved_text: $resolved, result_path: $result_path },
    source_unchanged: $source_unchanged,
    changed: $changed, decisions: $decisions, warnings: $warnings,
    downgrades: $downgrades, unverified: $unverified,
    change_report: ($changed + $decisions + $warnings + $downgrades + $unverified),
    evidence: { field_instruction: $instruction, cached_text: $resolved,
                placeholder: $placeholder, dirty: $dirty,
                paragraph_text: $para_text, result_path: $result_path,
                validates: $validates },
    report: (if $report_path != "" then $report_path else null end) }
')"

if [[ "$JSON" == "1" ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "WordFlow cross-reference",
  "  source:       " + .source + "  (unchanged: " + (.source_unchanged | tostring) + ")",
  "  output:       " + .output,
  "  bookmark:     " + .bookmark,
  "  kind:         " + .requested_kind + " -> " + .applied_kind
                     + (if .downgraded then " (downgraded)" else "" end),
  "  instruction:  " + .reference.instruction,
  "  cached text:  " + .reference.resolved_text,
  "  placeholder:  " + (.evidence.placeholder | tostring),
  "  paragraph:    " + .evidence.paragraph_text,
  "",
  "Change report:",
  (.change_report[] | "  - " + .)
' <<<"$report"
