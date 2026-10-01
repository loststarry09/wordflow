#!/usr/bin/env bash
#
# Verification that a fresh agent session discovers the WordFlow skill (#14).
#
# WordFlow is a skill installed into a coding agent (spec
# `docs/spec/v0.1.md` §Further Notes: distribution). Every supported agent
# discovers a skill as `<skills-dir>/<name>/SKILL.md`:
#
#   opencode  project: .opencode/skills, .claude/skills, .agents/skills
#             global:  ~/.config/opencode/skills, ~/.claude/skills, ~/.agents/skills
#   Claude    project: .claude/skills      global: ~/.claude/skills
#   Codex     project: .codex/skills, .agents/skills
#             global:  $CODEX_HOME/skills, ~/.agents/skills
#
# This test checks the committed packaging and, where the agent CLI is
# installed, drives that CLI's own discovery surface:
#
#   opencode debug skill         lists every skill opencode discovered
#   codex debug prompt-input     renders the skill catalog Codex injects
#
# Claude Code has no CLI installed here, so its check is documented manual.
# See `docs/distribution.md` for the mechanism, evidence, and [V]/[S]/[?] tags.
#
# Usage: tests/skill-discovery.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="wordflow"
ENTRY_DIRS=(".agents/skills" ".claude/skills")

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }
report_skip() { printf '  \033[33mSKIP\033[0m %s — %s\n' "$1" "$2"; }

assert_true() {
  local label="$1"; shift
  if "$@"; then report_ok "$label"; else report_fail "$label" "condition false: $*"; fi
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}

sha() { sha256sum "$1" | awk '{print $1}'; }

# frontmatter_keys <SKILL.md> — the YAML keys in the leading frontmatter block
frontmatter_keys() {
  awk 'NR==1 && $0=="---" { inblock=1; next }
       inblock && $0=="---" { exit }
       inblock && /^[A-Za-z0-9_-]+:/ { sub(/:.*/, ""); print }' "$1"
}

# frontmatter_value <SKILL.md> <key> — the value of one frontmatter key
frontmatter_value() {
  awk -v key="$2" '
    NR==1 && $0=="---" { inblock=1; next }
    inblock && $0=="---" { exit }
    inblock && index($0, key ":")==1 { sub("^" key ":[[:space:]]*", ""); print; exit }' "$1"
}

echo "Skill discovery (#14) — $ROOT"
echo

# --- 1. the canonical entry point -----------------------------------------
echo "Canonical SKILL.md"
root="$ROOT/SKILL.md"
assert_true "root SKILL.md exists" test -f "$root"

if [[ -f "$root" ]]; then
  keys="$(frontmatter_keys "$root" | paste -sd' ' -)"
  assert_eq "frontmatter has exactly name + description" "$keys" "name description"
  assert_eq "frontmatter name is '$SKILL'" "$(frontmatter_value "$root" name)" "$SKILL"
  assert_true "frontmatter description is non-empty" test -n "$(frontmatter_value "$root" description)"
fi

# --- 2. per-agent entry directories ---------------------------------------
for base in "${ENTRY_DIRS[@]}"; do
  d="$ROOT/$base/$SKILL"
  entry="$d/SKILL.md"
  echo
  echo "$base/$SKILL"

  assert_true "$base/$SKILL/ exists" test -d "$d"
  # Codex's loader does not follow a symlinked SKILL.md, so the entry must be a
  # regular file. opencode follows either form, but a regular file is safe for
  # both and keeps a single, checkable copy per agent directory.
  assert_true "$base/$SKILL/SKILL.md is a regular file" test -f "$entry"
  assert_true "$base/$SKILL/SKILL.md is not a symlink" test ! -L "$entry"

  if [[ -f "$root" && -f "$entry" ]]; then
    assert_eq "$base entry is byte-identical to root SKILL.md" \
      "$(sha "$entry")" "$(sha "$root")"
  fi

  if [[ -f "$entry" ]]; then
    assert_eq "$base entry name matches its directory" \
      "$(frontmatter_value "$entry" name)" "$SKILL"
  fi

  # SKILL.md tells the agent to read `references/`; resolve it from the entry
  # directory the way the agent will.
  assert_true "$base entry resolves references/README.md" test -r "$d/references/README.md"
done

# --- 3. Claude instruction file -------------------------------------------
echo
echo "Claude instructions"
assert_true "CLAUDE.md exists" test -e "$ROOT/CLAUDE.md"
assert_true "CLAUDE.md content equals AGENTS.md" cmp -s "$ROOT/CLAUDE.md" "$ROOT/AGENTS.md"

# --- 4. automated discovery: opencode -------------------------------------
# Prefer a working binary: the PATH entry here may be a secret-injecting
# wrapper that exits without credentials.
find_opencode() {
  local c
  for c in opencode /usr/local/bin/opencode; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" --version >/dev/null 2>&1; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

echo
echo "Fresh-session discovery"
# Agent output can exceed a command-substitution buffer, so capture it in a
# file and grep the file rather than a shell variable.
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wf-skill.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

if oc="$(find_opencode)"; then
  if ( cd "$ROOT" && timeout 120 "$oc" debug skill ) >"$tmpdir/opencode.out" 2>/dev/null; then
    if grep -q "\"name\": \"$SKILL\"" "$tmpdir/opencode.out" \
       && grep -q "\.agents/skills/$SKILL/SKILL.md" "$tmpdir/opencode.out"; then
      report_ok "opencode discovers '$SKILL' (.agents/skills)"
    else
      report_fail "opencode discovers '$SKILL'" "skill absent from 'opencode debug skill'"
    fi
  else
    report_skip "opencode discovery" "'$oc debug skill' failed to run"
  fi
else
  report_skip "opencode discovery" "no usable opencode binary; run 'opencode debug skill' in the repo"
fi

# --- 5. automated discovery: Codex ----------------------------------------
if command -v codex >/dev/null 2>&1; then
  if ( cd "$ROOT" && timeout 120 codex debug prompt-input ) >"$tmpdir/codex.out" 2>/dev/null; then
    if grep -q "$SKILL" "$tmpdir/codex.out" \
       && grep -q "$ROOT/.agents/skills" "$tmpdir/codex.out"; then
      report_ok "Codex discovers '$SKILL' (.agents/skills)"
    else
      report_fail "Codex discovers '$SKILL'" "skill absent from 'codex debug prompt-input'"
    fi
  else
    report_skip "Codex discovery" "'codex debug prompt-input' failed to run"
  fi
else
  report_skip "Codex discovery" "codex not on PATH; run 'codex debug prompt-input' in the repo"
fi

# --- 6. manual discovery: Claude Code -------------------------------------
report_skip "Claude Code discovery" \
  "no local CLI. Manual check: run 'claude' in this repo, then '/skills' (or ask it to list skills) and confirm '$SKILL' is offered."

echo
echo "Skill discovery: $((pass + fail)) checks run | $pass passed | $fail failed"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
