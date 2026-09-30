#!/usr/bin/env bash
#
# Acceptance tests for the shared render-preview capability (#29).
#
# These tests exercise the *external behaviour* of
# scripts/wf-render-preview.sh: given the final delivered output document it must
# produce a visual preview artifact by default, produce none and note the
# omission when disabled, cover the final output (not an intermediate), never
# mutate the output, and never act as a compatibility gate.
#
# Requirements: soffice (LibreOffice), pdftoppm (poppler-utils), jq on PATH.
# Usage: tests/render-preview.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-render-preview.sh"
REPORT_TOOL="$ROOT/scripts/wf-change-report.sh"

for bin in soffice pdftoppm jq; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
  exit 2
fi
if [[ ! -x "$REPORT_TOOL" ]]; then
  echo "missing or non-executable operation: $REPORT_TOOL" >&2
  exit 2
fi

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

# assert_eq <label> <actual> <expected>
assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/wf-render-preview.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FINAL="$TMP/final-排版.docx"
cp "$FIX/styles/heading-hierarchy.docx" "$FINAL"
SRC_SHA="$(sha256sum "$FINAL" | awk '{print $1}')"

echo "Render preview (#29) — $TOOL"

# ---------------------------------------------------------------------------
# 1. default run produces a non-empty visual artifact, and does not mutate the
#    output document.
# ---------------------------------------------------------------------------
OUT1="$TMP/out1"
json="$(timeout 180 "$TOOL" "$FINAL" --out "$OUT1" --json)"
rc=$?
assert_eq "default run: exit 0" "$rc" "0"
assert_eq "default run: not disabled"        "$(jq -r '.disabled' <<<"$json")" "false"
assert_eq "default run: format defaults png" "$(jq -r '.format' <<<"$json")" "png"
assert_eq "default run: preview is not the compatibility gate" \
  "$(jq -r '.compatibility_gate' <<<"$json")" "false"

n_art="$(jq -c '.artifacts | length' <<<"$json")"
if [[ "$n_art" -ge 1 ]]; then report_ok "default run: produced >=1 artifact ($n_art)"; else report_fail "default run: produced >=1 artifact" "got $n_art"; fi

all_nonempty=1
while IFS= read -r a; do
  [[ -s "$a" ]] || all_nonempty=0
done < <(jq -r '.artifacts[]' <<<"$json")
assert_eq "default run: every artifact exists and is non-empty" "$all_nonempty" "1"

first_art="$(jq -r '.artifacts[0]' <<<"$json")"
case "$first_art" in
  *final-排版-preview-1.png) report_ok "default run: artifact name derives from the final output" ;;
  *) report_fail "default run: artifact name derives from the final output" "got '$first_art'" ;;
esac

assert_eq "default run: pages >= 1" "$(jq -r '.pages >= 1' <<<"$json")" "true"
assert_eq "default run: output field is the passed document" \
  "$(jq -r '.output' <<<"$json")" "$(readlink -f "$FINAL")"

now_sha="$(sha256sum "$FINAL" | awk '{print $1}')"
assert_eq "default run: output document unchanged" "$now_sha" "$SRC_SHA"

# ---------------------------------------------------------------------------
# 2. no --out: the preview lands beside the output document by default.
# ---------------------------------------------------------------------------
FINAL2="$TMP/dir2/final-排版.docx"
mkdir -p "$TMP/dir2"
cp "$FIX/styles/heading-hierarchy.docx" "$FINAL2"
json="$(timeout 180 "$TOOL" "$FINAL2" --json)"
assert_eq "default dir: exit 0" "$?" "0"
art="$(jq -r '.artifacts[0]' <<<"$json")"
assert_eq "default dir: preview is beside the output" "$(dirname "$art")" "$TMP/dir2"

# ---------------------------------------------------------------------------
# 3. --format pdf produces a PDF artifact.
# ---------------------------------------------------------------------------
OUT3="$TMP/out3"
json="$(timeout 180 "$TOOL" "$FINAL" --out "$OUT3" --format pdf --json)"
assert_eq "pdf: exit 0" "$?" "0"
assert_eq "pdf: format echoed" "$(jq -r '.format' <<<"$json")" "pdf"
pdf_art="$(jq -r '.artifacts[0]' <<<"$json")"
case "$pdf_art" in
  *.pdf) report_ok "pdf: artifact is a .pdf" ;;
  *) report_fail "pdf: artifact is a .pdf" "got '$pdf_art'" ;;
esac
if [[ -s "$pdf_art" ]]; then report_ok "pdf: artifact non-empty"; else report_fail "pdf: artifact non-empty" "empty or missing"; fi

# ---------------------------------------------------------------------------
# 4. --disabled produces no artifact and notes the omission in the report.
# ---------------------------------------------------------------------------
OUT4="$TMP/out4"
REPORT="$TMP/report.json"
"$REPORT_TOOL" new --source "$FINAL" --output "$FINAL" --out "$REPORT" >/dev/null
json="$(timeout 60 "$TOOL" "$FINAL" --out "$OUT4" --disabled --report "$REPORT" --json)"
rc=$?
assert_eq "disabled: exit 0" "$rc" "0"
assert_eq "disabled: disabled true" "$(jq -r '.disabled' <<<"$json")" "true"
assert_eq "disabled: no artifacts" "$(jq -c '.artifacts | length' <<<"$json")" "0"
assert_eq "disabled: report updated" "$(jq -r '.report_updated' <<<"$json")" "true"

if [[ -d "$OUT4" ]] && find "$OUT4" -type f -name '*preview*' | grep -q .; then
  report_fail "disabled: no preview artifact written" "found a preview file in $OUT4"
else
  report_ok "disabled: no preview artifact written"
fi

"$REPORT_TOOL" validate --report "$REPORT" >/dev/null 2>&1
assert_eq "disabled: report still valid" "$?" "0"
n_note="$(jq -r '[.unverified[] | select(test("preview"; "i"))] | length' "$REPORT")"
if [[ "$n_note" -ge 1 ]]; then report_ok "disabled: omission noted in report (unverified)"; else report_fail "disabled: omission noted in report (unverified)" "no preview entry"; fi
assert_eq "disabled: omission carries a stable code" \
  "$(jq -r '[.unverified[] | select(test("\\[D13"; ""))] | length >= 1' "$REPORT")" "true"

# ---------------------------------------------------------------------------
# 5. --disabled without --report is a usage error (the omission can never be
#    silent).
# ---------------------------------------------------------------------------
timeout 60 "$TOOL" "$FINAL" --disabled >/dev/null 2>&1
assert_eq "disabled without report: usage error (exit 2)" "$?" "2"

# ---------------------------------------------------------------------------
# 6. determinism / repeatability: a second run is idempotent and yields the
#    same artifact set and page count.
# ---------------------------------------------------------------------------
OUT6="$TMP/out6"
j1="$(timeout 180 "$TOOL" "$FINAL" --out "$OUT6" --json)"
j2="$(timeout 180 "$TOOL" "$FINAL" --out "$OUT6" --json)"
assert_eq "repeat: second run exit 0" "$?" "0"
assert_eq "repeat: same artifact set" \
  "$(jq -c '.artifacts | sort' <<<"$j1")" "$(jq -c '.artifacts | sort' <<<"$j2")"
assert_eq "repeat: same page count" "$(jq -r '.pages' <<<"$j1")" "$(jq -r '.pages' <<<"$j2")"
assert_eq "repeat: still exactly one artifact" "$(jq -c '.artifacts | length' <<<"$j2")" "1"

# A shorter document rendered into the same directory must not leave stale
# pages from a longer previous render behind.
assert_eq "repeat: no stale pages" "$(find "$OUT6" -type f -name '*-preview-*' | wc -l | tr -d ' ')" "$(jq -r '.pages' <<<"$j2")"

# ---------------------------------------------------------------------------
# 7. the preview covers the final delivered output, not an intermediate:
#    the script renders whatever path it is given.
# ---------------------------------------------------------------------------
json="$(timeout 180 "$TOOL" "$FINAL2" --out "$TMP/out7" --json)"
art="$(jq -r '.artifacts[0]' <<<"$json")"
assert_eq "final output: artifact stem follows the passed document" "$(basename "$art")" "final-排版-preview-1.png"

# ---------------------------------------------------------------------------
# 8. bad usage is rejected cleanly.
# ---------------------------------------------------------------------------
timeout 60 "$TOOL" "$FINAL" --format tiff >/dev/null 2>&1
assert_eq "bad usage: unknown format exits 2" "$?" "2"
timeout 60 "$TOOL" "$TMP/does-not-exist.docx" --json >/dev/null 2>&1
assert_eq "bad input: missing output document exits 1" "$?" "1"

echo
echo "Render preview: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
