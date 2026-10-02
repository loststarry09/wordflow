# Table of contents

How WordFlow places a **table of contents** built from a document's headings as a real,
updatable field whose *cached result lists the entries with no page numbers* — so no
application ever displays a wrong number (spec `docs/spec/v0.1.md` §D8, §D9). This is the
TOC reference for issue [#24](https://github.com/loststarry09/wordflow/issues/24); the
number-free cache mechanism was proved in issue
[#11](https://github.com/loststarry09/wordflow/issues/11) and is folded in here.

Companion evidence:
[`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
(field recalculation on open) and
[`../research/multipage-page-fields.md`](../research/multipage-page-fields.md). Fixtures:
`tests/fixtures/toc/toc-no-page-numbers.docx`, `tests/fixtures/styles/standard-style-set.docx`.
Tests: `tests/toc.sh` (feature), `tests/toc-cache.sh` (mechanism). Tool: `scripts/wf-toc.sh`.

Legend:

- **[V]** — verified by running the tools locally (OfficeCLI `1.0.153`; Word `16.0`; WPS
  Writer `12.0`; LibreOffice `24.2.7.2` via the compatibility harness).
- **[S]** — backed by OOXML / ECMA-376 or another primary source.
- **[?]** — reported or reasoned but not confirmed locally; treat as uncertain.

## 1. The decision this implements

The frozen v0.1 decision (spec §D9) is that WordFlow builds the TOC **without page
numbers**:

- **[V]** No application updates fields on open, and none honours `w:updateFields` on open;
  the *cached result is what the reader sees* until the user updates the field (research
  §3/§6).
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

Define the entry styles, place or configure the TOC field with `pageNumbers=false`, add/keep
the headings, then **`refresh` last** — it must run after every heading exists:

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

# 3. add / keep the heading content.

# 4. refresh LAST, after the headings exist, to fill the cached entries
officecli refresh F
```

- **[V]** `pageNumbers=false` writes the instruction `TOC \o "a-b" \h \z \u`; `refresh`
  then replaces the placeholder with one `TOC1`/`TOC2`/… hyperlink paragraph per heading and
  writes **no** `<w:tab>` and **no** `PAGEREF` (raw check: `fldChar` begin/separate/end = 1
  each, `PAGEREF` = 0, `<w:tab>` = 0). `officecli query <f> field` then shows
  `/field[1] fieldType=toc evaluated=true` with the entry text concatenated, no numbers.
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
- **[V]** Prefer the field **instruction** over the derived `query toc` format readback.
  Under concurrent OfficeCLI resident load the `--json` readback has been observed to omit
  the derived `pageNumbers` key while the instruction text (`TOC \o "1-3" \h \z \u`) stayed
  correct; the instruction is the document fact.

## 3. Levels and the frozen style set

- **[V]** `--levels a-b` sets the included heading range; both ends must be in 1..3 and
  `a <= b`. The entry styles are the frozen `TOC 1..TOC 3` (spec §D7); levels beyond 3 are
  out of scope and rejected (exit 2) rather than produced with an undefined style.
- **[V]** The cached entries are the headings within the range, in document order; an
  in-range heading outside a narrower range (e.g. a Heading 1 with `--levels 2-3`) is
  omitted, and the entry count equals the heading count in range.
- **[V]** The `\h` hyperlinks use `w:anchor="_Toc…"`; `refresh` also inserts the matching
  `w:bookmarkStart`/`w:bookmarkEnd` into each heading paragraph, so no extra relationship part
  is needed and no `Hyperlink` style is required.

## 4. Compatibility (measured)

The fixture headings sit on pages 1, 2 and 3 (explicit `pagebreak`s), so a wrong cached page
number would be visible as a wrong number, not hidden by "everything is page 1".

| Application | Opens without repair | TOC on open (no F9) | Page numbers? | Cached text source |
|---|---|---|---|---|
| Word 16.0 | **Yes** [V] | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** | cached result (no update on open) |
| WPS Writer 12.0 | **Yes** [V] | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** | cached result (no update on open) |
| LibreOffice 24.2.7.2 | **Yes** [V] | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** | cached result (no update on open) |

- **[V]** Measured from each application's own PDF export (`pdftotext`) and, for Word/WPS,
  from the live COM object model (`TablesOfContents(1).Range.Text`), which returned
  `\rAlpha Section\rBeta Section\rGamma Subsection\r`.
- **[V]** `scripts/wf-compat-harness.sh <out.docx> --apps libreoffice --no-visual` reports
  `records[].opens_without_repair = true` and `field_cache.placeholder_count = 0`.
- **[V]** The field is **live**: updating it (Word/WPS `Fields.Update` +
  `TablesOfContents(1).Update`) rebuilds it as `Alpha Section<TAB>1`, `Beta Section<TAB>2`,
  `Gamma Subsection<TAB>3`, proving it was never "just text".
- **[S]** The TOC uses standard Transitional OOXML (complex field + `TOC` instruction); it
  introduces no application-specific extension.

### Why `pageNumbers=false` is exactly the right switch (the `\z` finding)

- **[S]** The OOXML/Word TOC switch that *omits page numbers entirely* is `\n`; the `\z`
  switch only *hides tab leader and page numbers in Web layout view*.
- **[V]** OfficeCLI maps `pageNumbers=false` to the **`\z`** switch
  (`TOC \o "1-3" \h \z \u`), not `\n`.
- **[V]** Consequence, confirmed by the F9 measurements above: in normal/print layout `\z`
  leaves page numbers enabled, so updating the field adds them; had OfficeCLI emitted `\n`,
  the field would be permanently page-number-less and the "gains page numbers on F9"
  acceptance could not hold. This is a **load-bearing** OfficeCLI behaviour: do not "fix" it
  by hand-writing `\n`.

### When not to use this pattern

- **[V]** With `pageNumbers=true`, `refresh` writes `PAGEREF` fields whose cached page
  numbers come from OfficeCLI's **HTML pagination**, which does not match Word/WPS layout
  (e.g. a heading OfficeCLI caches as page 2 is page 1 in Word). All three display that wrong
  cache verbatim. Never ship a TOC refreshed with `pageNumbers=true`.
- **[V]** `refresh` must run **after** all heading content; run early and the cache is empty
  or incomplete. Re-run it whenever headings change.
- **[?]** `officecli help docx refresh` states Word + Windows is required for `.docx`, but
  `refresh` completed on Linux here (HTML backend) and filled the cache. The mechanism relies
  on that Linux path.

## 5. When the cache cannot be filled

If `refresh` does not populate the cache (empty when headings exist, or the placeholder
wording), WordFlow must not ship it silently (spec §D11):

1. `scripts/wf-toc.sh` verifies the cache through OfficeCLI and **exits 1** with the reasons
   instead of reporting success; it never claims a TOC whose cache is a placeholder.
2. **Fallback (recorded use of `raw-set`).** The DOM layer cannot insert a cached result, so
   compose it with `officecli raw-set` between the field's `separate` and `end` `fldChar`s:
   one `w:p` per heading carrying the `TOC1`/`TOC2`/… style and a
   `w:hyperlink w:anchor="_Toc…"` run over the heading text, plus a matching
   `w:bookmarkStart`/`w:bookmarkEnd` in each heading. This reproduces the `refresh`-generated
   shape (entries, no page numbers). Record the reason, per SKILL rule 4.
3. **Last resort.** Omit the TOC and report it — never ship the placeholder
   `Update field to see table of contents`.

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
tests/generate-fixtures.sh                       # builds tests/fixtures/toc/toc-no-page-numbers.docx
tests/toc-cache.sh                               # #11 mechanism: entries, no numbers, cross-application displays
tests/toc.sh                                     # #24 feature: entries, no page numbers, real field, source protection

# place a TOC and read the JSON evidence back
scripts/wf-toc.sh tests/fixtures/toc/toc-no-page-numbers.docx --out /tmp/toc.docx --json

# manual cross-application check (Word/WPS serialised under the shared lock)
flock -w 1800 /tmp/wordflow-wincom.lock \
  scripts/wf-compat-harness.sh tests/fixtures/toc/toc-no-page-numbers.docx \
  --apps word,wps,libreoffice --out tests/.out/compat/issue11 --no-visual
```

## Spec / documentation conflicts raised

None. The mechanism satisfies §D9 as written: entries present, no page numbers in the cache,
field real and updatable. The only point worth recording for authors is the `\z`-vs-`\n`
distinction above — the acceptance ("gains page numbers on F9") depends on `\z`.
