#!/usr/bin/env bash
#
# Acceptance tests for the cross-application compatibility harness (#2).
#
# These tests exercise the *external behaviour* of the reproducible operation
# scripts/wf-compat-harness.sh:
#   * it emits the documented machine-readable JSON schema;
#   * a missing driver is reported "unavailable", never a fake pass;
#   * field caches are reported by cached TEXT, so placeholders are detectable;
#   * the source document is never modified;
#   * Word and WPS are driven over COM when Windows interop is reachable.
#
# They deliberately assert the reported facts, not the OfficeCLI/COM commands
# the harness runs internally.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH.
# Usage: tests/compat-harness.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-compat-harness.sh"
OUTROOT="$ROOT/tests/.out/compat-test"
DEFAULT_PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
  exit 2
fi

rm -rf "$OUTROOT"; mkdir -p "$OUTROOT"

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

# run_run <label> <out-dir> <doc> [tool args...] -> echoes JSON on stdout
run_harness() {
  local doc="$1"; shift
  local out="$1"; shift
  "$TOOL" "$doc" --out "$out" --json "$@" 2>/dev/null
}

echo "Compatibility harness (#2) — $TOOL"

# ---------------------------------------------------------------------------
# 1. LibreOffice record: schema, opens-without-repair, render, field cache text
# ---------------------------------------------------------------------------
LO_FIX="$FIX/headers/page-number-footer.docx"
before="$(sha256sum "$LO_FIX" | awk '{print $1}')"
json="$(run_harness "$LO_FIX" "$OUTROOT/lo" --apps libreoffice --timeout 90)"
rc=$?
after="$(sha256sum "$LO_FIX" | awk '{print $1}')"

assert_eq "libreoffice run exits 0" "$rc" "0"
if jq -e . >/dev/null 2>&1 <<<"$json"; then report_ok "libreoffice: output is valid JSON"; else report_fail "libreoffice: output is valid JSON" "unparseable"; fi
assert_eq "libreoffice: schema id" "$(jq -r '.schema' <<<"$json")" "wordflow.compat-harness/v1"
assert_eq "libreoffice: one document" "$(jq -r '.summary.documents' <<<"$json")" "1"
assert_eq "libreoffice: status ok" "$(jq -r '.records[]|select(.app=="libreoffice")|.status' <<<"$json")" "ok"
assert_eq "libreoffice: opens without repair" "$(jq -r '.records[]|select(.app=="libreoffice")|.opens_without_repair' <<<"$json")" "true"
assert_eq "libreoffice: schema_valid" "$(jq -r '.records[]|select(.app=="libreoffice")|.schema_valid' <<<"$json")" "true"
assert_eq "libreoffice: schema_all_valid" "$(jq -r '.summary.schema_all_valid' <<<"$json")" "true"

pdf="$(jq -r '.records[]|select(.app=="libreoffice")|.render.pdf // empty' <<<"$json")"
if [[ -n "$pdf" && -s "$pdf" ]]; then report_ok "libreoffice: PDF render captured"; else report_fail "libreoffice: PDF render captured" "no non-empty pdf at '$pdf'"; fi

# field caches: each field's cached TEXT is present (here the PAGE field caches "1")
assert_eq "libreoffice: one field reported" "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.field_count' <<<"$json")" "1"
assert_eq "libreoffice: PAGE cached text" "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.fields[0].cached_text' <<<"$json")" "1"
assert_eq "libreoffice: PAGE not a placeholder" "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.fields[0].placeholder' <<<"$json")" "false"
assert_eq "libreoffice: placeholder_count 0" "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.placeholder_count' <<<"$json")" "0"

if command -v pdftoppm >/dev/null; then
  vis="$(jq -r '.records[]|select(.app=="libreoffice")|.render.visual // empty' <<<"$json")"
  if [[ -n "$vis" && -s "$vis" ]]; then report_ok "libreoffice: PNG visual captured"; else report_fail "libreoffice: PNG visual captured" "no non-empty png at '$vis'"; fi
else
  report_skip "libreoffice: PNG visual captured" "pdftoppm not on PATH"
fi

assert_eq "libreoffice: source unchanged" "$before" "$after"

# ---------------------------------------------------------------------------
# 2. Placeholder cache detection (REF caches the placeholder «target»)
# ---------------------------------------------------------------------------
PH_FIX="$FIX/fields/bookmark-ref-pageref.docx"
json="$(run_harness "$PH_FIX" "$OUTROOT/placeholder" --apps libreoffice --timeout 90)"
assert_true "placeholder: at least one placeholder detected" '.records[]|select(.app=="libreoffice")|.field_cache.placeholder_count >= 1' "$json"
assert_eq "placeholder: REF cached text is the placeholder" \
  "$(jq -r '.records[]|select(.app=="libreoffice")|.field_cache.fields[]|select(.field_type=="ref")|.cached_text' <<<"$json")" \
  "«target»"
assert_true "placeholder: REF flagged placeholder" \
  '.records[]|select(.app=="libreoffice")|.field_cache.fields[]|select(.field_type=="ref")|.placeholder' "$json"

# ---------------------------------------------------------------------------
# 3. A missing driver is reported "unavailable" — never a fake pass
# ---------------------------------------------------------------------------
json="$(WF_POWERSHELL=/nonexistent/powershell.exe "$TOOL" "$LO_FIX" --out "$OUTROOT/unavailable" --json --apps word,wps --timeout 60 2>/dev/null)"
assert_eq "unavailable: windows_interop false" "$(jq -r '.environment.windows_interop' <<<"$json")" "false"
assert_true "unavailable: word status unavailable" '.records[]|select(.app=="word")|.status=="unavailable"' "$json"
assert_true "unavailable: wps status unavailable" '.records[]|select(.app=="wps")|.status=="unavailable"' "$json"
assert_true "unavailable: word owr is the string unavailable, not true" '.records[]|select(.app=="word")|.opens_without_repair=="unavailable"' "$json"
assert_true "unavailable: no render claimed" '[.records[].render.pdf]|all(.==null)' "$json"

# ---------------------------------------------------------------------------
# 4. --list input and bad-usage handling
# ---------------------------------------------------------------------------
printf '%s\n' "$LO_FIX" > "$OUTROOT/list.txt"
json="$("$TOOL" --list "$OUTROOT/list.txt" --apps libreoffice --out "$OUTROOT/list" --json 2>/dev/null)"
assert_eq "list: one document" "$(jq -r '.summary.documents' <<<"$json")" "1"
"$TOOL" "$LO_FIX" --apps bogus >/dev/null 2>&1
assert_eq "bad usage: unknown app exits 2" "$?" "2"
"$TOOL" "$LO_FIX" --timeout abc >/dev/null 2>&1
assert_eq "bad usage: non-integer timeout exits 2" "$?" "2"

# ---------------------------------------------------------------------------
# 5. Word and WPS over COM (when Windows interop is reachable)
# ---------------------------------------------------------------------------
PS_BIN="${WF_POWERSHELL:-$DEFAULT_PS}"
if [[ -x "$PS_BIN" ]]; then
  TOC_FIX="$FIX/toc/toc-basic.docx"
  tbefore="$(sha256sum "$TOC_FIX" | awk '{print $1}')"
  json="$(run_harness "$TOC_FIX" "$OUTROOT/com" --apps word,wps --timeout 90)"
  tafter="$(sha256sum "$TOC_FIX" | awk '{print $1}')"

  for app in word wps; do
    status="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.status' <<<"$json")"
    if [[ "$status" == "unavailable" ]]; then
      report_skip "$app: COM engine available" "engine did not start (app not installed here)"
      continue
    fi
    assert_eq "$app: status ok" "$status" "ok"
    assert_eq "$app: opens without repair" "$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.opens_without_repair' <<<"$json")" "true"
    apdf="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.render.pdf // empty' <<<"$json")"
    if [[ -n "$apdf" && -s "$apdf" ]]; then report_ok "$app: PDF render captured"; else report_fail "$app: PDF render captured" "no non-empty pdf"; fi
    # per-application field cache: real cached TEXT, not just a count
    cnt="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.app_field_cache.field_count // 0' <<<"$json")"
    if [[ "$cnt" =~ ^[0-9]+$ ]] && (( cnt >= 1 )); then
      report_ok "$app: live field cache captured ($cnt fields)"
    else
      report_fail "$app: live field cache captured" "app_field_cache empty"
    fi
    if jq -e --arg a "$app" '(.records[]|select(.app==$a)|.app_field_cache != null) and ([.records[]|select(.app==$a)|.app_field_cache.fields[]|has("cached_text")]|all)' >/dev/null 2>&1 <<<"$json"; then
      report_ok "$app: every live field reports cached_text"
    else
      report_fail "$app: every live field reports cached_text" "missing cached_text in app_field_cache"
    fi
    if jq -e --arg a "$app" '.records[]|select(.app==$a)|.app_field_cache.toc_text? // "" | contains("Introduction")' >/dev/null 2>&1 <<<"$json"; then
      report_ok "$app: live TOC cache text captured"
    else
      report_fail "$app: live TOC cache text captured" "toc_text missing expected entry"
    fi
  done
  assert_eq "word/wps: source unchanged" "$tbefore" "$tafter"
else
  report_skip "word/wps over COM" "Windows interop not reachable ($PS_BIN)"
fi

# ---------------------------------------------------------------------------
# 6. A relative --out must be absolutised, not fed to LibreOffice as file:// (#38)
# ---------------------------------------------------------------------------
relroot="tests/.out/compat-rel"
rm -rf "${ROOT:?}/$relroot"
( cd "$ROOT" && timeout 120 "$TOOL" "$LO_FIX" --out "$relroot" --apps libreoffice --timeout 90 --json > "$OUTROOT/rel.json" 2>/dev/null )
rc=$?
assert_eq "relative --out: harness exits (no hang)" "$rc" "0"
assert_true "relative --out: LibreOffice record repair-free" \
  '.records[]|select(.app=="libreoffice")|.opens_without_repair==true' \
  "$(cat "$OUTROOT/rel.json" 2>/dev/null || echo '{}')"
if [[ -s "$ROOT/$relroot/result.json" ]]; then
  report_ok "relative --out: artifacts written under the resolved directory"
else
  report_fail "relative --out: artifacts written under the resolved directory" "no result.json at $relroot"
fi

echo
echo "Compatibility harness: $((pass + fail)) checks run | $pass passed | $fail failed | $skip skipped"
echo "Artifacts: $OUTROOT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
