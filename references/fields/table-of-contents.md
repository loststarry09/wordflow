# Table of contents

How WordFlow places a **table of contents** built from a document's headings as a real,
updatable field whose *cached result lists the entries with no page numbers* — so no
application ever displays a wrong number (spec `docs/spec/v0.1.md` §D8, §D9). This is the
TOC reference for issue [#24](https://github.com/loststarry09/wordflow/issues/24); the
number-free cache mechanism itself is
[`toc-without-page-numbers.md`](./toc-without-page-numbers.md) (#11), which this file
builds on.

Companion evidence:
[`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
(field recalculation on open; §3, §6) and
[`../research/docx-feature-portability.md`](../research/docx-feature-portability.md).
Fixtures: `tests/fixtures/toc/toc-no-page-numbers.docx`,
`tests/fixtures/styles/standard-style-set.docx`. Test: `tests/toc.sh`. Tool:
`scripts/wf-toc.sh`.

Legend:

- **[V]** — verified by running the tools locally (OfficeCLI `1.0.153`; LibreOffice
  `24.2.7.2` via the compatibility harness; Word `16.0` / WPS `12.0` carried over from the
  field-recalc research).
- **[S]** — backed by OOXML / ECMA-376 or another primary source.
- **[?]** — reported or reasoned but not confirmed locally; treat as uncertain.

## 1. The decision this implements

The frozen v0.1 decision (spec §D9) is that WordFlow builds the TOC **without page
numbers**:

- **[V]** No application updates fields on open, and none honours `w:updateFields` on open;
  the *cached result is what the reader sees* until the user updates the field
  ([`toc-without-page-numbers.md`](./toc-without-page-numbers.md) §1, research §3/§6).
- **[V]** WordFlow has no layout engine, so any page number it computed would look finished
  while being wrong — worse than none (spec §D9).
- **[S]** The TOC stays a **real complex field** (`w:fldChar begin` / `separate` / `end`
  with a `TOC` instruction), not static text, so a manual F9 / Update Table in Word/WPS
  rebuilds it and adds the correct page numbers.

**Consequence.** The TOC is correct when its cached entries are the headings, carry **no
`PAGEREF`** reference, and the cache is never a placeholder (`Update field to see table of
contents` / `«»`). The change report states that page numbers are intentionally omitted and
how to add them (spec §D12 item 5).

## 2. Portable construction

Use the #11 mechanism: define the entry styles, place or configure the TOC field with
`pageNumbers=false`, add/keep the headings, then **`refresh` last**.

```sh
# 1. the TOC 1..TOC 3 entry styles must be defined before refresh references them
#    (the standard set defines them; add the standard definitions when absent)
officecli add F /styles --type style --prop styleId=TOC1 --prop name="TOC 1" ...
officecli add F /styles --type style --prop styleId=TOC2 --prop name="TOC 2" ...
officecli add F /styles --type style --prop styleId=TOC3 --prop name="TOC 3" ...

# 2. the TOC field; pageNumbers=false makes officecli emit TOC \o "1-3" \h \z \u
officecli add F / --type toc --prop levels="1-3" --prop hyperlinks=true --prop pageNumbers=false

#    an existing TOC is reused, not duplicated: configure it in place
officecli set F /toc --prop levels="1-3" --prop hyperlinks=true --prop pageNumbers=false

# 3. refresh LAST, after the headings exist, to fill the cached entries
officecli refresh F
```

- **[V]** `pageNumbers=false` writes the instruction `TOC \o "a-b" \h \z \u`; `refresh`
  then replaces the placeholder with one `TOC1`/`TOC2`/… hyperlink paragraph per heading and
  writes **no** `<w:tab>` and **no** `PAGEREF` (raw check: `fldChar` begin/separate/end = 1
  each, `PAGEREF` = 0, `<w:tab>` = 0).
- **[V]** `scripts/wf-toc.sh` reuses an existing TOC by setting it to the requested levels
  with `pageNumbers=false` and refreshing — an existing page-numbered cache is cleared
  (`PAGEREF` before → 0 after). It creates a TOC only when none exists, inserted after the
  first `Title` paragraph, else before the first body paragraph.
- **[V]** `officecli remove F /toc` is **not** a clean replace: it drops the field markers
  but leaves the cached `TOC1`/`TOC2` entry paragraphs behind as orphaned text. Reuse rather
  than remove-and-re-add.
- **[V]** The refreshed entries reference only `TOC1`/`TOC2`/… styles. Defining them up
  front keeps the document free of dangling style references (spec §D14); a source that
  already defines them (e.g. the standard set) is left unchanged.
- **[V]** A titled TOC (`--prop title=…`) adds a paragraph carrying the built-in
  `TOCHeading` style. OfficeCLI does **not** define that style, so the tool defines it
  explicitly (basedOn `Normal`, no first-line indent) when `--title` is used — otherwise the
  reference would be dangling.

## 3. Levels and the frozen style set

- **[V]** `--levels a-b` sets the included heading range; both ends must be in 1..3 and
  `a <= b`. The entry styles are the frozen `TOC 1..TOC 3` (spec §D7); levels beyond 3 are
  out of scope and rejected (exit 2) rather than produced with an undefined style.
- **[V]** The cached entries are the headings within the range, in document order; an
  in-range heading outside a narrower range (e.g. a Heading 1 with `--levels 2-3`) is
  omitted, and the entry count equals the heading count in range.

## 4. Compatibility (measured)

| Application | Opens without repair | TOC on open (no F9) | Page numbers? |
|---|---|---|---|
| Word 16.0 | **Yes** [V] | heading entries | none |
| WPS Writer 12.0 | **Yes** [V] | heading entries | none |
| LibreOffice 24.2.7.2 | **Yes** [V] | heading entries | none |

- **[V]** `scripts/wf-compat-harness.sh <out.docx> --apps libreoffice --no-visual` reports
  `records[].opens_without_repair = true` and `field_cache.placeholder_count = 0` for the
  outputs; Word/WPS repair-free and cache-verbatim behaviour is the field-recalc research
  (§3, §6) and the #11 measurements.
- **[V]** The field is live: setting `pageNumbers=true` on a copy and re-running `refresh`
  writes `PAGEREF` fields and tab leaders (`PAGEREF` 0 → 3 on the fixture), proving the
  entries are a field, not static text — and that `pageNumbers=false` is the reason the
  shipped cache has none.
- **[S]** The TOC uses standard Transitional OOXML (complex field + `TOC` instruction); it
  introduces no application-specific extension.

## 5. When the cache cannot be filled

If `refresh` does not populate the cache (empty when headings exist, or the placeholder
wording), WordFlow must not ship it silently (spec §D11):

- `scripts/wf-toc.sh` verifies the cache through OfficeCLI and **exits 1** with the reasons
  instead of reporting success; it never claims a TOC whose cache is a placeholder.
- The recipe depends on `officecli refresh` filling the TOC from headings; when that is
  unavailable the #11 fallback (compose the cached entries with `raw-set`, recorded per SKILL
  rule 4) is the manual alternative, and the last resort is to omit the TOC and report it.

## 6. Change report

When a TOC is produced this way the change report (spec §D12 item 5, §D9) states:

> *Table of contents: page numbers are intentionally omitted in v0.1; the TOC is a real
> field. Update the TOC (Word/WPS: click it and press F9, or Update Table) to add page
> numbers.*

The script routes that omission through the shared risk policy
(`scripts/wf-risk-policy.sh emit --trigger unverifiable-field --resolution state`), so the
`[D11-unverifiable-field]` entry lands in the report's `unverified` area and no D11 code is
hard-coded.

## 7. Reproduction

```sh
# place a TOC and read the JSON evidence back
scripts/wf-toc.sh tests/fixtures/toc/toc-no-page-numbers.docx \
  --out /tmp/toc.docx --json

# a titled TOC over a document without one
scripts/wf-toc.sh src.docx --out /tmp/toc.docx --levels 1-3 --title "Contents" --json

# the #24 acceptance test: entries, no page numbers, no placeholder, real field,
# source protection, reproducibility, LibreOffice opens-without-repair
tests/toc.sh
```
