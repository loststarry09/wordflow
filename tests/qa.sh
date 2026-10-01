#!/usr/bin/env bash
#
# Acceptance tests for the WordFlow QA / Definition-of-Done gate (#31, spec D14).
#
# These tests exercise the *external behaviour* of scripts/wf-qa.sh: it must pass
# a cleanly delivered document, and fail on every D14 defect — a dangling style,
# a placeholder field cache, a page-numbered TOC cache, an unreported limited
# construction, a preview of the wrong document, an unchanged-source/live-output
# violation, a non-reproducible run — and it must use the compatibility harness
# for the repair-free-open gate.
#
# They also assert the fixture suite covers each promised capability.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH; soffice + pdftoppm
# for the pipeline preview.
# Usage: tests/qa.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
QA="$ROOT/scripts/wf-qa.sh"
PIPELINE="$ROOT/scripts/wf-pipeline.sh"
STD_STYLES="$ROOT/scripts/wf-standard-styles.sh"
RENDER_PREVIEW="$ROOT/scripts/wf-render-preview.sh"
CHANGE_REPORT="$ROOT/scripts/wf-change-report.sh"
MANIFEST="$FIX/MANIFEST.md"
OUTROOT="$ROOT/tests/.out/qa-test"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
for t in "$QA" "$PIPELINE" "$STD_STYLES" "$RENDER_PREVIEW" "$CHANGE_REPORT"; do
  [[ -x "$t" ]] || { echo "missing or non-executable: $t" >&2; exit 2; }
done

rm -rf "$OUTROOT"; mkdir -p "$OUTROOT/main" "$OUTROOT/misc"

pass=0; fail=0
declare -a failures=()
report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_true() { # <label> <expr>
  if [[ "$2" == "1" ]]; then report_ok "$1"; else report_fail "$1" "false"; fi
}

# gate <args...> -> prints the gate JSON
gate() { "$QA" "$@" --json 2>/dev/null; }
# check_status <gate-json> <id>
check_status() { jq -r --arg id "$2" '.checks[] | select(.id == $id) | .status' <<<"$1"; }
# assert_check <label> <gate-json> <id> <expected-status>
assert_check() {
  local got; got="$(check_status "$2" "$3")"
  assert_eq "$1 ($3)" "$got" "$4"
}

echo "QA / Definition-of-Done (#31) — $QA"

# ===========================================================================
# 1. A cleanly delivered document passes the whole gate.
# ===========================================================================
"$PIPELINE" --source "$FIX/styles/unstyled.docx" --out-dir "$OUTROOT/main" --json > "$OUTROOT/main.json" 2>/dev/null
assert_eq "pipeline delivers the artifact" "$?" "0"
P_OUT="$(jq -r '.output' "$OUTROOT/main.json")"
P_PLAN="$(jq -r '.artifacts.plan' "$OUTROOT/main.json")"
P_REPORT="$(jq -r '.artifacts.report_json' "$OUTROOT/main.json")"
"$RENDER_PREVIEW" "$P_OUT" --out "$OUTROOT/misc" --format png --report "$P_REPORT" --json > "$OUTROOT/preview.json" 2>/dev/null

GJ="$(gate --output "$P_OUT" --source "$FIX/styles/unstyled.docx" --plan "$P_PLAN" --report "$P_REPORT" \
        --preview "$(cat "$OUTROOT/preview.json")" --apps libreoffice)"
assert_eq "clean output: gate passes" "$(jq -r '.ok' <<<"$GJ")" "true"
assert_eq "clean output: no failures" "$(jq -r '.summary.fail' <<<"$GJ")" "0"
assert_check "clean output" "$GJ" "schema" "pass"
assert_check "clean output" "$GJ" "no-dangling-styles" "pass"
assert_check "clean output" "$GJ" "fields-no-placeholder" "pass"
assert_check "clean output" "$GJ" "report-valid" "pass"
assert_check "clean output" "$GJ" "preview-covers-output" "pass"
assert_check "clean output" "$GJ" "source-unchanged" "pass"
assert_check "clean output" "$GJ" "output-is-new-file" "pass"
assert_check "clean output" "$GJ" "collision-safe-name" "pass"
assert_check "clean output" "$GJ" "opens-without-repair" "pass"

# ===========================================================================
# 2. schema failure.
# ===========================================================================
printf 'not a docx\n' > "$OUTROOT/misc/notdocx.txt"
GJ="$(gate --output "$OUTROOT/misc/notdocx.txt" --no-compat)"; rc=$?
assert_eq "non-docx: gate exits non-zero" "$rc" "1"
assert_check "non-docx" "$GJ" "schema" "fail"

# ===========================================================================
# 3. dangling style fails; a real dangling is detected, a translated default is not.
# ===========================================================================
GJ="$(gate --output "$FIX/styles/caption-dangling.docx" --no-compat)"
assert_check "dangling" "$GJ" "no-dangling-styles" "fail"
GJ="$(gate --output "$FIX/styles/standard-style-set.docx" --no-compat)"
assert_check "standard set (id/name)" "$GJ" "no-dangling-styles" "pass"

# ===========================================================================
# 4. placeholder field cache fails; page-dependent fields are exempt.
# ===========================================================================
GJ="$(gate --output "$FIX/fields/bookmark-ref-pageref.docx" --no-compat)"
assert_check "placeholder REF" "$GJ" "fields-no-placeholder" "fail"
GJ="$(gate --output "$FIX/multipage/page-fields.docx" --no-compat)"
assert_check "page fields exempt" "$GJ" "fields-no-placeholder" "pass"

# ===========================================================================
# 5. TOC cache: page-numbered fails; number-free passes.
# ===========================================================================
GJ="$(gate --output "$FIX/toc/toc-basic.docx" --no-compat)"
assert_check "TOC with page numbers" "$GJ" "toc-no-page-numbers" "fail"
GJ="$(gate --output "$FIX/toc/toc-no-page-numbers.docx" --no-compat)"
assert_check "TOC without page numbers" "$GJ" "toc-no-page-numbers" "pass"

# ===========================================================================
# 6. limited constructions must be reported (no silent downgrade).
# ===========================================================================
"$PIPELINE" --source "$FIX/images/anchored-image.docx" --out-dir "$OUTROOT/main" --no-preview --json > "$OUTROOT/risk.json" 2>/dev/null
R_OUT="$(jq -r '.output' "$OUTROOT/risk.json")"
R_REPORT="$(jq -r '.artifacts.report_json' "$OUTROOT/risk.json")"
GJ="$(gate --output "$R_OUT" --report "$R_REPORT" --no-compat)"
assert_check "construct reported" "$GJ" "constructs-reported" "pass"
"$CHANGE_REPORT" new --source "$FIX/images/anchored-image.docx" --output "$R_OUT" --out "$OUTROOT/misc/empty-report.json" >/dev/null
GJ="$(gate --output "$R_OUT" --report "$OUTROOT/misc/empty-report.json" --no-compat)"
assert_check "construct silent" "$GJ" "constructs-reported" "fail"
GJ="$(gate --output "$R_OUT" --no-compat)"
assert_check "construct without report" "$GJ" "constructs-reported" "fail"

# ===========================================================================
# 7. preview must cover the final output.
# ===========================================================================
"$STD_STYLES" "$FIX/styles/heading-hierarchy.docx" --out "$OUTROOT/misc/other-排版.docx" --json >/dev/null 2>&1
GJ="$(gate --output "$OUTROOT/misc/other-排版.docx" --preview "$(cat "$OUTROOT/preview.json")" --no-compat)"
assert_check "preview of wrong doc" "$GJ" "preview-covers-output" "fail"

# ===========================================================================
# 8. plan facts: source protection, new file, collision-safe name.
# ===========================================================================
jq '.output.output = .source.path' "$P_PLAN" > "$OUTROOT/misc/plan-same-path.json"
GJ="$(gate --output "$P_OUT" --plan "$OUTROOT/misc/plan-same-path.json" --no-compat)"
assert_check "output equals source" "$GJ" "output-is-new-file" "fail"
jq '.output.output = (.output.directory + "/custom.docx")' "$P_PLAN" > "$OUTROOT/misc/plan-bad-name.json"
GJ="$(gate --output "$P_OUT" --plan "$OUTROOT/misc/plan-bad-name.json" --no-compat)"
assert_check "non-standard name" "$GJ" "collision-safe-name" "fail"
jq '.source.unchanged = false' "$P_PLAN" > "$OUTROOT/misc/plan-changed.json"
GJ="$(gate --output "$P_OUT" --plan "$OUTROOT/misc/plan-changed.json" --no-compat)"
assert_check "source changed" "$GJ" "source-unchanged" "fail"

# ===========================================================================
# 9. reproducibility.
# ===========================================================================
"$STD_STYLES" "$FIX/styles/heading-hierarchy.docx" --out "$OUTROOT/misc/r1-排版.docx" --json >/dev/null 2>&1
"$STD_STYLES" "$FIX/styles/heading-hierarchy.docx" --out "$OUTROOT/misc/r2-排版.docx" --json >/dev/null 2>&1
GJ="$(gate --output "$OUTROOT/misc/r1-排版.docx" --repro "$OUTROOT/misc/r2-排版.docx" --no-compat)"
assert_check "same input reproduces" "$GJ" "reproducible" "pass"
GJ="$(gate --output "$OUTROOT/misc/r1-排版.docx" --repro "$FIX/styles/unstyled.docx" --no-compat)"
assert_check "different input diverges" "$GJ" "reproducible" "fail"

# ===========================================================================
# 10. fixture suite covers each promised capability and is documented.
# ===========================================================================
if [[ ! -f "$MANIFEST" ]]; then
  report_fail "manifest present" "missing $MANIFEST"
else
  report_ok "manifest present"
fi

missing_manifest=()
while IFS= read -r f; do
  b="$(basename "$f")"
  grep -qF "$b" "$MANIFEST" || missing_manifest+=("$b")
done < <(find "$FIX" -name '*.docx' | sort)
assert_true "every fixture is in the manifest" \
  "$(( ${#missing_manifest[@]} == 0 ? 1 : 0 ))"
if (( ${#missing_manifest[@]} > 0 )); then
  report_fail "manifest coverage" "missing: ${missing_manifest[*]}"
fi

declare -A CAP=(
  [styles]="styles/heading-hierarchy.docx"
  [standard-styles]="styles/standard-style-set.docx"
  [page-setup]="sections/page-setup-default.docx"
  [sections-restart]="sections/page-number-restart.docx"
  [toc]="toc/toc-basic.docx"
  [toc-no-pages]="toc/toc-no-page-numbers.docx"
  [fields]="fields/bookmark-ref-pageref.docx"
  [cached-cross-ref]="fields/cached-cross-ref.docx"
  [images-inline]="images/inline-image.docx"
  [images-floating]="images/anchored-image.docx"
  [tables]="tables/fixed-table.docx"
  [tables-nested]="tables/nested-table.docx"
  [headers-page-numbers]="headers/page-number-footer.docx"
  [headers-firstpage-oddeven]="headers/firstpage-oddeven.docx"
  [equations]="equations/display-equation.docx"
  [footnotes]="notes/footnote-basic.docx"
  [captions]="captions/caption-seq.docx"
  [cjk-fonts]="cjk/cjk-fonts-indent.docx"
  [cjk-punctuation]="cjk/cjk-punctuation-kinsoku.docx"
  [multipage]="multipage/page-fields.docx"
)
cap_missing=()
for cap in "${!CAP[@]}"; do
  [[ -f "$FIX/${CAP[$cap]}" ]] || cap_missing+=("$cap=${CAP[$cap]}")
done
assert_true "each promised capability has a fixture" \
  "$(( ${#cap_missing[@]} == 0 ? 1 : 0 ))"
if (( ${#cap_missing[@]} > 0 )); then
  report_fail "capability coverage" "missing: ${cap_missing[*]}"
fi

assert_true "fixture generator is locale-deterministic" \
  "$(grep -q -- '--locale' "$ROOT/tests/generate-fixtures.sh" && echo 1 || echo 0)"

echo
echo "QA gate: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
