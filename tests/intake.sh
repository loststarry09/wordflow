#!/usr/bin/env bash
#
# Acceptance tests for WordFlow intake, precedence, and source protection (#15).
#
# These tests exercise the *external behaviour* of scripts/wf-intake.sh (spec
# `docs/spec/v0.1.md` §D2, §D3, §D4.1, §D5.1): given a source (a .docx or a
# content file), an optional template, and/or a formatting requirement, it must
# resolve the precedence chain, delegate output naming, protect the source, and
# refuse when a source cannot be read safely — without producing an output file.
#
# They assert the job-plan contract and the refusal behaviour, not the internal
# OfficeCLI commands.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum on PATH. unzip/zip are used
# only for the optional schema-invalid case and are skipped when absent.
#
# Usage: tests/intake.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
TOOL="$ROOT/scripts/wf-intake.sh"

for bin in officecli jq sha256sum; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
  exit 2
fi

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_info() { printf '  \033[36mINFO\033[0m %s\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_true() {
  local label="$1"; shift
  if "$@"; then report_ok "$label"; else report_fail "$label" "condition false: $*"; fi
}
sha() { sha256sum -- "$1" | awk '{print $1}'; }

# --- sandbox ---------------------------------------------------------------
SB=""
cleanup() { [[ -n "$SB" && -d "$SB" ]] && rm -rf "$SB"; }
trap cleanup EXIT
SB="$(mktemp -d "${TMPDIR:-/tmp}/wf-intake.XXXXXX")"

# A restyle source with named styles, an unstyled source, and a template.
cp "$FIX/styles/heading-hierarchy.docx" "$SB/styled.docx"
cp "$FIX/styles/unstyled.docx"          "$SB/unstyled.docx"
cp "$FIX/styles/template.docx"          "$SB/tpl.docx"

# A formatting requirement: two overrides and one free-text note.
cat > "$SB/req.txt" <<'EOF'
# WordFlow formatting requirement (demo conflict)
font.ea = 楷体
page.margin.left: 2.5cm
Body text must be justified.
EOF

# A content file (generate mode).
printf '# A report\n\nSome body text.\n' > "$SB/content.md"

# Captures for a single invocation.
OUT=""; RC=0
run() { OUT="$("$TOOL" "$@" 2>"$SB/err")"; RC=$?; }

echo "Intake (#15) — $TOOL"

# ===========================================================================
# A. usage errors
# ===========================================================================
run;                         assert_eq "usage: no args exits 2" "$RC" "2"
run --source a --content b;  assert_eq "usage: source+content mutually exclusive" "$RC" "2"
run --source "$SB/styled.docx" --bogus; assert_eq "usage: unknown option exits 2" "$RC" "2"
run --source;                assert_eq "usage: --source without value exits 2" "$RC" "2"
run --source "$SB/styled.docx" --template; assert_eq "usage: --template without value exits 2" "$RC" "2"
run --content;               assert_eq "usage: --content without value exits 2" "$RC" "2"

# ===========================================================================
# B. precedence — restyle
# ===========================================================================
echo
echo "Precedence (restyle)"

# B1. no template, no requirement -> document styles win.
run --source "$SB/styled.docx" --json
P="$OUT"
assert_eq "restyle: planning exits 0" "$RC" "0"
assert_eq "restyle: status planned" "$(jq -r '.status' <<<"$P")" "planned"
assert_eq "restyle: mode" "$(jq -r '.mode' <<<"$P")" "restyle"
assert_eq "restyle: source kind" "$(jq -r '.source.kind' <<<"$P")" "docx"
assert_eq "restyle: style source is document styles" "$(jq -r '.style.source' <<<"$P")" "document-styles"
assert_eq "restyle: style set is document" "$(jq -r '.style.set' <<<"$P")" "document"
assert_eq "restyle: #16 ownership reused" "$(jq -r '.style.ownership' <<<"$P")" "preserve-and-tidy"
assert_eq "restyle: precedence ranks are 1..5" "$(jq -c '[.precedence[].rank]' <<<"$P")" "[1,2,3,4,5]"
assert_eq "restyle: precedence order frozen" \
  "$(jq -c '[.precedence[].layer]' <<<"$P")" \
  '["formatting-requirement","template","document-styles","standard-styles","defaults"]'
assert_eq "restyle: only document-styles authoritative" \
  "$(jq -c '[.precedence[] | select(.authoritative) | .layer]' <<<"$P")" '["document-styles"]'
assert_eq "restyle: template absent" "$(jq -r '.precedence[1].present' <<<"$P")" "false"

# B2. template only -> template wins over document styles.
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --json
P2="$OUT"
assert_eq "template: style source is template" "$(jq -r '.style.source' <<<"$P2")" "template"
assert_eq "template: style set is template" "$(jq -r '.style.set' <<<"$P2")" "template"
assert_eq "template: ownership is use-template-styles" "$(jq -r '.style.ownership' <<<"$P2")" "use-template-styles"
assert_eq "template: template styles read" \
  "$(jq -c '.style.template_styles | (index("WF Body") != null) and (index("WF Quote") != null)' <<<"$P2")" "true"
assert_eq "template: template layer authoritative" "$(jq -r '.precedence[1].authoritative' <<<"$P2")" "true"

# B3. requirement only -> requirement wins, document styles preserved underneath.
run --source "$SB/styled.docx" --requirement "$SB/req.txt" --json
P3="$OUT"
assert_eq "requirement: style source is requirement" "$(jq -r '.style.source' <<<"$P3")" "formatting-requirement"
assert_eq "requirement: style set still document" "$(jq -r '.style.set' <<<"$P3")" "document"
assert_eq "requirement: override count" "$(jq -r '.inputs.requirement.overrides | length' <<<"$P3")" "2"
assert_eq "requirement: first override key" "$(jq -r '.inputs.requirement.overrides[0].key' <<<"$P3")" "font.ea"
assert_eq "requirement: first override value" "$(jq -r '.inputs.requirement.overrides[0].value' <<<"$P3")" "楷体"
assert_eq "requirement: free text kept as a note" "$(jq -r '.inputs.requirement.notes[0]' <<<"$P3")" "Body text must be justified."
assert_eq "requirement: requirement layer authoritative" "$(jq -r '.precedence[0].authoritative' <<<"$P3")" "true"

# B4. THE WORKED CONFLICT: requirement + template disagree; the requirement wins.
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --requirement "$SB/req.txt" --json
P4="$OUT"
assert_eq "conflict: requirement beats template (style source)" "$(jq -r '.style.source' <<<"$P4")" "formatting-requirement"
assert_eq "conflict: template still supplies definitions (style set)" "$(jq -r '.style.set' <<<"$P4")" "template"
assert_eq "conflict: template layer not authoritative" "$(jq -r '.precedence[1].authoritative' <<<"$P4")" "false"
assert_eq "conflict: requirement override shadows the template" \
  "$(jq -r '.inputs.requirement.overrides[0].shadowed | index("template") != null' <<<"$P4")" "true"
assert_eq "conflict: contrast — template alone would win" "$(jq -r '.style.source' <<<"$P2")" "template"
# The winning value is the requirement's, not the template's.
assert_eq "conflict: winning override value is the requirement's" \
  "$(jq -r '.inputs.requirement.overrides[] | select(.key=="font.ea") | .value' <<<"$P4")" "楷体"

# B4b. an empty requirement (comments/blank only) contributes nothing.
printf '# only a comment\n\n' > "$SB/empty-req.txt"
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --requirement "$SB/empty-req.txt" --json
assert_eq "empty requirement: template still wins" "$(jq -r '.style.source' <<<"$OUT")" "template"
assert_eq "empty requirement: layer supplied" "$(jq -r '.precedence[0].present' <<<"$OUT")" "true"
assert_eq "empty requirement: layer not authoritative" "$(jq -r '.precedence[0].authoritative' <<<"$OUT")" "false"

# B5. a source with no named styles -> rebuild with standard styles.
run --source "$SB/unstyled.docx" --json
P5="$OUT"
assert_eq "unstyled: style source is standard styles" "$(jq -r '.style.source' <<<"$P5")" "standard-styles"
assert_eq "unstyled: style set is standard" "$(jq -r '.style.set' <<<"$P5")" "standard"
assert_eq "unstyled: ownership is rebuild" "$(jq -r '.style.ownership' <<<"$P5")" "rebuild-with-standard-styles"

# ===========================================================================
# C. generate from content
# ===========================================================================
echo
echo "Generate from content"

run --content "$SB/content.md" --json
G="$OUT"
assert_eq "generate: mode" "$(jq -r '.mode' <<<"$G")" "generate"
assert_eq "generate: source kind is content" "$(jq -r '.source.kind' <<<"$G")" "content"
assert_eq "generate: style source is standard styles" "$(jq -r '.style.source' <<<"$G")" "standard-styles"
assert_eq "generate: ownership is null (not a restyle)" "$(jq -r '.style.ownership' <<<"$G")" "null"
assert_eq "generate: no document-styles layer" "$(jq -r '.precedence[2].present' <<<"$G")" "false"
assert_eq "generate: default output name from content stem" "$(jq -r '.output.output' <<<"$G")" "$SB/content-排版.docx"

run --content "$SB/content.md" --template "$SB/tpl.docx" --json
assert_eq "generate+template: template wins the set" "$(jq -r '.style.set' <<<"$OUT")" "template"
run --content "$SB/content.md" --template "$SB/tpl.docx" --requirement "$SB/req.txt" --json
assert_eq "generate+template+requirement: requirement wins" "$(jq -r '.style.source' <<<"$OUT")" "formatting-requirement"
assert_eq "generate+template+requirement: set stays template" "$(jq -r '.style.set' <<<"$OUT")" "template"

# ===========================================================================
# D. output naming is delegated (#13): default, collision, specified
# ===========================================================================
echo
echo "Output naming (delegated)"

# D1. collision numbering.
SB2="$(mktemp -d "${TMPDIR:-/tmp}/wf-intake-name.XXXXXX")"
cp "$FIX/styles/heading-hierarchy.docx" "$SB2/report.docx"
printf 'existing' > "$SB2/report-排版.docx"
existing_hash="$(sha "$SB2/report-排版.docx")"
run --source "$SB2/report.docx" --json
assert_eq "naming: collision numbered (2)" "$(jq -r '.output.output' <<<"$OUT")" "$SB2/report-排版 (2).docx"
assert_eq "naming: collision_index" "$(jq -r '.output.collision_index' <<<"$OUT")" "2"
assert_eq "naming: numbered flag" "$(jq -r '.output.numbered' <<<"$OUT")" "true"
assert_eq "naming: existing output untouched" "$(sha "$SB2/report-排版.docx")" "$existing_hash"
assert_true "naming: intake creates no output file" test ! -e "$SB2/report-排版 (2).docx"

# D2. user-specified file is honoured and not created.
run --source "$SB2/report.docx" --output "$SB2/chosen name.docx" --json
assert_eq "naming: specified path honoured" "$(jq -r '.output.output' <<<"$OUT")" "$SB2/chosen name.docx"
assert_true "naming: specified output not created" test ! -e "$SB2/chosen name.docx"

# D3. user-specified existing file -> refusal, no overwrite.
printf 'keep me' > "$SB2/taken.docx"
taken_hash="$(sha "$SB2/taken.docx")"
run --source "$SB2/report.docx" --output "$SB2/taken.docx" --json
assert_eq "naming: existing specified target refuses (exit 3)" "$RC" "3"
assert_eq "naming: refusal reason" "$(jq -r '.reason_code' <<<"$OUT")" "output-exists"
assert_eq "naming: existing specified target untouched" "$(sha "$SB2/taken.docx")" "$taken_hash"

# D4. user-specified directory -> default name inside.
mkdir -p "$SB2/dest"
run --source "$SB2/report.docx" --output "$SB2/dest" --json
assert_eq "naming: directory target" "$(jq -r '.output.output' <<<"$OUT")" "$SB2/dest/report-排版.docx"
rm -rf "$SB2"

# ===========================================================================
# E. source protection
# ===========================================================================
echo
echo "Source protection"

before="$(sha "$SB/styled.docx")"
tpl_before="$(sha "$SB/tpl.docx")"
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --requirement "$SB/req.txt" --json
after="$(sha "$SB/styled.docx")"
tpl_after="$(sha "$SB/tpl.docx")"
assert_eq "protection: source unchanged (hash before == after)" "$before" "$after"
assert_eq "protection: template unchanged" "$tpl_before" "$tpl_after"
assert_eq "protection: plan records source hash" "$(jq -r '.source.sha256' <<<"$OUT")" "$before"
assert_eq "protection: plan records unchanged" "$(jq -r '.source.unchanged' <<<"$OUT")" "true"
assert_eq "protection: read-only flag" "$(jq -r '.protection.read_only' <<<"$OUT")" "true"
assert_eq "protection: template hash recorded" "$(jq -r '.inputs.template.sha256' <<<"$OUT")" "$tpl_before"

# Reproducibility: identical inputs -> byte-identical plan.
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --requirement "$SB/req.txt" --json
first="$OUT"
run --source "$SB/styled.docx" --template "$SB/tpl.docx" --requirement "$SB/req.txt" --json
assert_eq "reproducibility: same inputs produce identical plan" "$OUT" "$first"

# ===========================================================================
# F. refusals — unreadable / invalid sources and inputs stop and ask
# ===========================================================================
echo
echo "Refusals"

# F1. missing source.
run --source "$SB/does-not-exist.docx" --json
assert_eq "refusal: missing source exits 3" "$RC" "3"
assert_eq "refusal: missing source status" "$(jq -r '.status' <<<"$OUT")" "refused"
assert_eq "refusal: missing source reason" "$(jq -r '.reason_code' <<<"$OUT")" "source-unreadable"
assert_eq "refusal: no output written" "$(jq -r '.output_written' <<<"$OUT")" "false"

# F2. corrupt (unreadable) .docx.
printf 'this is not a docx' > "$SB/corrupt.docx"
run --source "$SB/corrupt.docx" --json
assert_eq "refusal: corrupt source exits 3" "$RC" "3"
assert_eq "refusal: corrupt source reason" "$(jq -r '.reason_code' <<<"$OUT")" "source-unreadable"

# F3. unreadable by permission.
printf 'x' > "$SB/noperm.docx"; chmod 000 "$SB/noperm.docx"
run --source "$SB/noperm.docx" --json
assert_eq "refusal: unreadable source exits 3" "$RC" "3"
assert_eq "refusal: unreadable source reason" "$(jq -r '.reason_code' <<<"$OUT")" "source-unreadable"
chmod 644 "$SB/noperm.docx"

# F4. schema-invalid but readable .docx (OfficeCLI validate fails).
if command -v unzip >/dev/null && command -v zip >/dev/null; then
  work="$SB/invalid"; mkdir -p "$work"
  ( cd "$work" && unzip -q "$FIX/styles/unstyled.docx" && \
    sed -i 's#</w:body>#<w:bogusElement/></w:body>#' word/document.xml && \
    rm -f ../invalid.docx && zip -q -r ../invalid.docx . )
  if [[ -f "$SB/invalid.docx" ]]; then
    run --source "$SB/invalid.docx" --json
    assert_eq "refusal: schema-invalid source exits 3" "$RC" "3"
    assert_eq "refusal: schema-invalid source reason" "$(jq -r '.reason_code' <<<"$OUT")" "source-invalid"
  else
    report_info "schema-invalid fixture could not be built; skipped"
  fi
else
  report_info "unzip/zip unavailable; schema-invalid case skipped"
fi

# F5. missing / corrupt template.
run --source "$SB/styled.docx" --template "$SB/no-tpl.docx" --json
assert_eq "refusal: missing template reason" "$(jq -r '.reason_code' <<<"$OUT")" "template-unreadable"
run --source "$SB/styled.docx" --template "$SB/corrupt.docx" --json
assert_eq "refusal: corrupt template reason" "$(jq -r '.reason_code' <<<"$OUT")" "template-unreadable"

# F6. missing requirement.
run --source "$SB/styled.docx" --requirement "$SB/no-req.txt" --json
assert_eq "refusal: missing requirement reason" "$(jq -r '.reason_code' <<<"$OUT")" "requirement-unreadable"

# F7. a refusal writes no output document and no --plan file; asks on stderr.
printf 'not a docx' > "$SB/corrupt2.docx"
run --source "$SB/corrupt2.docx" --plan "$SB/refused-plan.json"
assert_eq "refusal: human refusal exits 3" "$RC" "3"
assert_true "refusal: clear ask on stderr" grep -q "stop and ask" "$SB/err"
assert_true "refusal: no plan file written" test ! -e "$SB/refused-plan.json"

# ===========================================================================
# G. --plan / --json / human summary contracts
# ===========================================================================
echo
echo "Plan I/O"

run --source "$SB/styled.docx" --plan "$SB/plan.json" --json
assert_eq "plan: exit 0" "$RC" "0"
assert_true "plan: file written" test -s "$SB/plan.json"
assert_eq "plan: file matches stdout" "$(cat "$SB/plan.json" 2>/dev/null || true)" "$OUT"
assert_eq "plan: stable top-level key set" \
  "$(jq -c 'keys' "$SB/plan.json")" \
  '["change_report","inputs","mode","output","precedence","protection","source","status","style","tool","version"]'

run --source "$SB/styled.docx"
# shellcheck disable=SC2016  # $1 is for the inner bash, not this shell
assert_true "summary: human output is not JSON" bash -c '! jq -e . >/dev/null 2>&1 <<<"$1"' _ "$OUT"
assert_true "summary: names the precedence chain" \
  grep -q "formatting-requirement > template > document-styles > standard-styles > defaults" <<<"$OUT"
assert_true "summary: names the output path" grep -q -- "-排版.docx" <<<"$OUT"

echo
echo "Intake: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
