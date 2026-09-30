#!/usr/bin/env bash
#
# Acceptance tests for WordFlow output-name resolution (#13).
#
# These tests exercise the *external behaviour* of the reproducible primitive
# scripts/wf-output-name.sh (spec `docs/spec/v0.1.md` §D2, §D3): given a source
# path and an optional user-specified path it must resolve the output path using
# the frozen default name and collision numbering, localise nothing, never
# overwrite an existing file, and never mutate the source.
#
# The primitive is pure path logic (no DOCX I/O), so these tests need no DOCX
# fixture and no OfficeCLI: the "documents" are empty placeholder files.
#
# Usage: tests/output-naming.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/wf-output-name.sh"

if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
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

# assert_true <label> <command...>
assert_true() {
  local label="$1"; shift
  if "$@"; then report_ok "$label"; else report_fail "$label" "condition false: $*"; fi
}

# resolve <source> [args...] -> prints the resolved path; warnings still go to stderr
resolve() { "$TOOL" "$@"; }

# sha <file>
sha() { sha256sum "$1" | awk '{print $1}'; }

sandboxes=()
new_sandbox() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/wf-output-name.XXXXXX")"
  sandboxes+=("$d")
  printf '%s\n' "$d"
}
cleanup() { local d; for d in "${sandboxes[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

echo "Output naming (#13) — $TOOL"

# --- 1. first run: no collision -> <stem>-排版.docx ------------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
src_hash="$(sha "$SB/report.docx")"
out="$(resolve "$SB/report.docx")"
assert_eq "first run: default suffix" "$out" "$SB/report-排版.docx"
if [[ ! -e "$out" ]]; then report_ok "first run: primitive creates no file"; else report_fail "first run: primitive creates no file" "output appeared on disk"; fi
assert_eq "first run: source unchanged" "$(sha "$SB/report.docx")" "$src_hash"

# --- 2. collision (2) ------------------------------------------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
printf 'base' > "$SB/report-排版.docx"
base_hash="$(sha "$SB/report-排版.docx")"
out="$(resolve "$SB/report.docx")"
assert_eq "collision: first collision is (2)" "$out" "$SB/report-排版 (2).docx"
assert_eq "collision: existing file untouched" "$(sha "$SB/report-排版.docx")" "$base_hash"

# --- 3. collision (3) ------------------------------------------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
printf 'base' > "$SB/report-排版.docx"
printf 'two'  > "$SB/report-排版 (2).docx"
out="$(resolve "$SB/report.docx")"
assert_eq "collision: second collision is (3)" "$out" "$SB/report-排版 (3).docx"

# --- 4. collision numbering fills the lowest free gap ----------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
printf 'base' > "$SB/report-排版.docx"
printf 'three' > "$SB/report-排版 (3).docx"
out="$(resolve "$SB/report.docx")"
assert_eq "collision: gap (2) before (4)" "$out" "$SB/report-排版 (2).docx"

# --- 5. user-specified path is honoured exactly ----------------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
out="$(resolve "$SB/report.docx" --output "$SB/chosen/name.docx")"
assert_eq "user path: honoured exactly" "$out" "$SB/chosen/name.docx"

SB="$(new_sandbox)"
touch "$SB/report.docx"
out="$(resolve "$SB/report.docx" -o "$SB/renamed.docx")"
assert_eq "user path: short flag honoured" "$out" "$SB/renamed.docx"

# --- 6. user-specified path already exists -> refuse, never overwrite ------
SB="$(new_sandbox)"
touch "$SB/report.docx"
printf 'keep me' > "$SB/taken.docx"
taken_hash="$(sha "$SB/taken.docx")"
if resolve "$SB/report.docx" --output "$SB/taken.docx" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_eq "user path: existing target refuses (exit 3)" "$rc" "3"
assert_eq "user path: existing target untouched" "$(sha "$SB/taken.docx")" "$taken_hash"

# --- 7. source name with spaces and non-ASCII ------------------------------
SB="$(new_sandbox)"
touch "$SB/会议 纪要.docx"
out="$(resolve "$SB/会议 纪要.docx")"
assert_eq "non-ASCII+spaces: default suffix" "$out" "$SB/会议 纪要-排版.docx"
printf 'x' > "$SB/会议 纪要-排版.docx"
out="$(resolve "$SB/会议 纪要.docx")"
assert_eq "non-ASCII+spaces: collision (2)" "$out" "$SB/会议 纪要-排版 (2).docx"

# --- 8. extension handling -------------------------------------------------
SB="$(new_sandbox)"
touch "$SB/notes"
out="$(resolve "$SB/notes")"
assert_eq "no extension: appends -排版.docx" "$out" "$SB/notes-排版.docx"

SB="$(new_sandbox)"
touch "$SB/archive.tar.gz"
out="$(resolve "$SB/archive.tar.gz")"
assert_eq "multi-dot: strips last extension only" "$out" "$SB/archive.tar-排版.docx"

# --- 9. output goes next to the source, including a subdirectory -----------
SB="$(new_sandbox)"
mkdir -p "$SB/sub/dir"
touch "$SB/sub/dir/x.docx"
out="$(resolve "$SB/sub/dir/x.docx")"
assert_eq "subdir: output beside source" "$out" "$SB/sub/dir/x-排版.docx"

# --- 10. user-specified existing directory -> default name inside ----------
SB="$(new_sandbox)"
touch "$SB/report.docx"
mkdir -p "$SB/dest"
out="$(resolve "$SB/report.docx" --output "$SB/dest")"
assert_eq "user dir: default name inside" "$out" "$SB/dest/report-排版.docx"
printf 'x' > "$SB/dest/report-排版.docx"
out="$(resolve "$SB/report.docx" --output "$SB/dest")"
assert_eq "user dir: collision numbered inside" "$out" "$SB/dest/report-排版 (2).docx"

# --- 11. --json contract ---------------------------------------------------
SB="$(new_sandbox)"
touch "$SB/report.docx"
json="$(resolve "$SB/report.docx" --json)"
assert_eq "json: output field" "$(printf '%s' "$json" | jq -r '.output')" "$SB/report-排版.docx"
assert_eq "json: mode default" "$(printf '%s' "$json" | jq -r '.mode')" "default"
assert_eq "json: numbered false" "$(printf '%s' "$json" | jq -r '.numbered')" "false"
assert_eq "json: collision_index 0" "$(printf '%s' "$json" | jq -r '.collision_index')" "0"
assert_eq "json: localised false" "$(printf '%s' "$json" | jq -r '.localised')" "false"
assert_eq "json: suffix frozen" "$(printf '%s' "$json" | jq -r '.suffix')" "-排版"
assert_eq "json: extension docx" "$(printf '%s' "$json" | jq -r '.extension')" ".docx"

SB="$(new_sandbox)"
touch "$SB/report.docx"
printf 'x' > "$SB/report-排版.docx"
json="$(resolve "$SB/report.docx" --json)"
assert_eq "json: numbered true on collision" "$(printf '%s' "$json" | jq -r '.numbered')" "true"
assert_eq "json: collision_index 2" "$(printf '%s' "$json" | jq -r '.collision_index')" "2"
assert_eq "json: last component is filename" "$(printf '%s' "$json" | jq -r '.filename')" "report-排版 (2).docx"

# --- 12. portability warning for a Windows-illegal source name -------------
SB="$(new_sandbox)"
touch "$SB/a:b.docx"
json="$(resolve "$SB/a:b.docx" --json)"
assert_eq "warning: Windows-illegal char flagged" "$(printf '%s' "$json" | jq -r '.warnings | length > 0')" "true"
assert_eq "warning: path still resolved" "$(printf '%s' "$json" | jq -r '.output')" "$SB/a:b-排版.docx"

# --- 13. bad usage ---------------------------------------------------------
if "$TOOL" >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_eq "bad usage: missing source exits 2" "$rc" "2"
if "$TOOL" "$SB/report.docx" --output >/dev/null 2>&1; then rc=0; else rc=$?; fi
assert_eq "bad usage: --output without value exits 2" "$rc" "2"

echo
echo "Output naming: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
