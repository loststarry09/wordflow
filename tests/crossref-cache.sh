#!/usr/bin/env bash
#
# Acceptance tests for correct cached cross-reference text (#12).
#
# These tests exercise the *external behaviour* of the recipe documented in
# references/fields/cross-references.md: a REF content cross-reference
# must carry the resolved target text in its cached result (never the
# placeholder «target»), and the document must open repair-free in Word, WPS
# Writer, and LibreOffice Writer showing that text.
#
# They assert the facts a reader would see — the cached TEXT of each field, the
# absence of placeholders/stale caches, schema validity, the rendered text of
# each application — not the OfficeCLI commands the recipe runs internally.
#
# Requirements: officecli >= 1.0.152, jq, sha256sum, pdftotext, flock on PATH;
# Microsoft Word / WPS Writer (COM) and LibreOffice reachable for the live-app
# checks. Usage: tests/crossref-cache.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/fields/cached-cross-ref.docx"
TOOL="$ROOT/scripts/wf-compat-harness.sh"
OUTROOT="$ROOT/tests/.out/crossref-cache"
COM_LOCK=/tmp/wordflow-wincom.lock

for bin in officecli jq sha256sum pdftotext flock; do
  command -v "$bin" >/dev/null || { echo "$bin not found on PATH" >&2; exit 2; }
done
if [[ ! -f "$FIXTURE" ]]; then
  echo "missing fixture: $FIXTURE" >&2
  exit 2
fi
if [[ ! -x "$TOOL" ]]; then
  echo "missing or non-executable operation: $TOOL" >&2
  exit 2
fi

rm -rf "$OUTROOT"; mkdir -p "$OUTROOT"

pass=0
fail=0
declare -a failures=()

report_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
report_fail() { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail + 1)); failures+=("$1: $2"); }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then report_ok "$1"; else report_fail "$1" "expected '$3', got '$2'"; fi
}
assert_contains() { # <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then report_ok "$1"; else report_fail "$1" "expected to contain '$3', got '$2'"; fi
}
assert_true() { # <label> <jq-expr> <json>
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then report_ok "$1"; else report_fail "$1" "assertion failed: $2"; fi
}

# field <n> <file> -> compact JSON of /field[n]
field() { officecli get "$2" "/field[$1]" --json 2>/dev/null; }

# cache_facts <file> -> per field: "instruction<TAB>cached_text<TAB>placeholder<TAB>dirty"
cache_facts() {
  officecli query "$1" field --json 2>/dev/null | jq -r '
    .data.results[]? |
    [ (.format.instruction // "?"),
      (.text // ""),
      (if (.text // "") | test("\u00ab|\u00bb") then "placeholder" else "resolved" end),
      (if (.format.dirty // false) then "dirty" else "clean" end) ] | @tsv'
}

echo "Cached cross-references (#12) — $FIXTURE"

# ---------------------------------------------------------------------------
# 1. The committed fixture's field caches are correct and non-placeholder
# ---------------------------------------------------------------------------
json="$(field 1 "$FIXTURE")"
assert_eq "first REF instruction" "$(jq -r '.data.results[0].format.instruction' <<<"$json")" "REF sec_intro"
assert_eq "first REF cached text is the heading text" "$(jq -r '.data.results[0].text' <<<"$json")" "Introduction"
assert_eq "first REF is not a placeholder" "$(jq -r '(.data.results[0].text | test("\u00ab|\u00bb")) | not' <<<"$json")" "true"
assert_eq "first REF is not dirty/stale" "$(jq -r '.data.results[0].format.dirty // false' <<<"$json")" "false"

json="$(field 2 "$FIXTURE")"
assert_eq "second REF instruction" "$(jq -r '.data.results[0].format.instruction' <<<"$json")" "REF fig_demo"
assert_eq "second REF cached text is the caption label" "$(jq -r '.data.results[0].text' <<<"$json")" "Figure 1"
assert_eq "second REF is not a placeholder" "$(jq -r '(.data.results[0].text | test("\u00ab|\u00bb")) | not' <<<"$json")" "true"
assert_eq "second REF is not dirty/stale" "$(jq -r '.data.results[0].format.dirty // false' <<<"$json")" "false"

# every field in the document is resolved (no «target» anywhere)
facts="$(cache_facts "$FIXTURE")"
assert_eq "no placeholder field in the document" \
  "$(printf '%s\n' "$facts" | awk -F'\t' '$3=="placeholder"{n++} END{print n+0}')" "0"
assert_eq "no dirty field in the document" \
  "$(printf '%s\n' "$facts" | awk -F'\t' '$4=="dirty"{n++} END{print n+0}')" "0"
assert_eq "two REF fields" "$(printf '%s\n' "$facts" | grep -c .)" "2"

json="$(officecli view "$FIXTURE" issues --json 2>/dev/null)"
assert_eq "no field_cache_stale issue" "$(jq -r '[.data.issues[]?|select(.subtype=="field_cache_stale")]|length' <<<"$json")" "0"

if officecli validate "$FIXTURE" >/dev/null 2>&1; then report_ok "fixture validates"; else report_fail "fixture validates" "officecli validate failed"; fi

# the bookmarks cover exactly the text the reference inserts
assert_eq "sec_intro bookmark covers the heading text" \
  "$(officecli get "$FIXTURE" '/bookmark[@name=sec_intro]' --json 2>/dev/null | jq -r '.data.results[0].text')" "Introduction"
assert_eq "fig_demo bookmark covers the caption label" \
  "$(officecli get "$FIXTURE" '/bookmark[@name=fig_demo]' --json 2>/dev/null | jq -r '.data.results[0].text')" "Figure 1"

# ---------------------------------------------------------------------------
# 2. The documented recipe reproduces the same caches from scratch
# ---------------------------------------------------------------------------
REPRO="$OUTROOT/repro.docx"
officecli close "$REPRO" >/dev/null 2>&1 || true
rm -f "$REPRO"
officecli create "$REPRO" --locale en-US >/dev/null
officecli add "$REPRO" /styles --type style --prop styleId=Caption --prop name="caption" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true --prop align=center >/dev/null
officecli add "$REPRO" / --type bookmark --prop name=sec_intro --prop text="Introduction" >/dev/null
officecli set "$REPRO" /body/p[1] --prop style=Heading1 >/dev/null 2>&1
officecli add "$REPRO" /body --type paragraph --prop style=Caption --prop text="Figure 1: Cached cross-reference demonstration." >/dev/null
officecli add "$REPRO" /body/p[2] --type bookmark --prop name=fig_demo --prop text="Figure 1" >/dev/null
officecli add "$REPRO" /body --type paragraph --prop text="See section " >/dev/null
officecli add "$REPRO" /body/p[3] --type field --prop fieldType=ref --prop name=sec_intro >/dev/null
officecli add "$REPRO" /body/p[3] --type run --prop text=" and " >/dev/null
officecli add "$REPRO" /body/p[3] --type field --prop fieldType=ref --prop name=fig_demo >/dev/null
officecli add "$REPRO" /body/p[3] --type run --prop text=" for details." >/dev/null
officecli set "$REPRO" /body/p[3]/r[5]  --prop text="Introduction" >/dev/null
officecli set "$REPRO" /body/p[3]/r[11] --prop text="Figure 1" >/dev/null
officecli raw-set "$REPRO" /document \
  --xpath '//w:fldChar[@w:fldCharType="begin" and @w:dirty="true"]' \
  --action replace --xml '<w:fldChar w:fldCharType="begin"/>' >/dev/null 2>&1 || true
officecli close "$REPRO" >/dev/null 2>&1 || true

rjson="$(field 1 "$REPRO")"
assert_eq "recipe: first REF cached text" "$(jq -r '.data.results[0].text' <<<"$rjson")" "Introduction"
assert_eq "recipe: first REF clean" "$(jq -r '.data.results[0].format.dirty // false' <<<"$rjson")" "false"
rjson="$(field 2 "$REPRO")"
assert_eq "recipe: second REF cached text" "$(jq -r '.data.results[0].text' <<<"$rjson")" "Figure 1"
assert_eq "recipe: second REF clean" "$(jq -r '.data.results[0].format.dirty // false' <<<"$rjson")" "false"
if officecli validate "$REPRO" >/dev/null 2>&1; then report_ok "recipe: rebuild validates"; else report_fail "recipe: rebuild validates" "officecli validate failed"; fi
assert_eq "recipe: no placeholder field" \
  "$(cache_facts "$REPRO" | awk -F'\t' '$3=="placeholder"{n++} END{print n+0}')" "0"

# ---------------------------------------------------------------------------
# 3. Live applications: opens-without-repair and the displayed text
# ---------------------------------------------------------------------------
before="$(sha256sum "$FIXTURE" | awk '{print $1}')"
json="$(flock -w 1800 "$COM_LOCK" "$TOOL" "$FIXTURE" --out "$OUTROOT/compat" \
        --apps word,wps,libreoffice --timeout 180 --no-visual --json 2>/dev/null)"
rc=$?
after="$(sha256sum "$FIXTURE" | awk '{print $1}')"

assert_eq "harness exits 0" "$rc" "0"
if jq -e . >/dev/null 2>&1 <<<"$json"; then report_ok "harness output is valid JSON"; else report_fail "harness output is valid JSON" "unparseable"; fi

for app in word wps libreoffice; do
  status="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.status' <<<"$json")"
  if [[ "$status" != "ok" ]]; then
    report_fail "$app: opens (status ok)" "status='$status' (application unavailable?)"
    continue
  fi
  assert_eq "$app: opens without repair" \
    "$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.opens_without_repair' <<<"$json")" "true"
  assert_eq "$app: document-level placeholder_count 0" \
    "$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.field_cache.placeholder_count' <<<"$json")" "0"
  assert_eq "$app: document-level field_cache_stale 0" \
    "$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.field_cache.checks.field_cache_stale' <<<"$json")" "0"
done

# Word and WPS expose the live cached text; it must be the resolved text.
for app in word wps; do
  cached="$(jq -r --arg a "$app" '.records[]|select(.app==$a)|.app_field_cache.placeholder_count // "na"' <<<"$json")"
  if [[ "$cached" == "na" ]]; then
    report_fail "$app: live cached fields reported" "app_field_cache missing"
    continue
  fi
  assert_eq "$app: live placeholder_count 0" "$cached" "0"
  texts="$(jq -r --arg a "$app" '[.records[]|select(.app==$a)|.app_field_cache.fields[]?|.cached_text]|sort|join(",")' <<<"$json")"
  assert_eq "$app: live cached texts are resolved" "$texts" "Figure 1,Introduction"
done

# LibreOffice re-resolves REF on import; the rendered PDF must show the same text.
lo_pdf="$(jq -r '.records[]|select(.app=="libreoffice")|.render.pdf // empty' <<<"$json")"
if [[ -n "$lo_pdf" && -s "$lo_pdf" ]]; then
  report_ok "libreoffice: PDF render captured"
  lo_text="$(pdftotext "$lo_pdf" - 2>/dev/null | tr '\n' ' ')"
  assert_contains "libreoffice: renders the resolved reference" "$lo_text" "See section Introduction and Figure 1 for details."
else
  report_fail "libreoffice: PDF render captured" "no non-empty pdf at '$lo_pdf'"
fi

# the committed fixture is never modified
assert_eq "fixture unchanged by the run" "$before" "$after"

echo
echo "Cached cross-references: $((pass + fail)) checks run | $pass passed | $fail failed"
echo "Artifacts: $OUTROOT"

if (( fail > 0 )); then
  printf '\nFailures:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
