# Table of contents cached without page numbers

How WordFlow builds a table of contents whose **cached result lists the heading entries but
carries no page-number references**, so it never shows a wrong page number while remaining a
real, updatable field. This is the mechanism behind the frozen TOC decision in spec §D9.

Feeds **E06**; issue [#11](https://github.com/loststarry09/wordflow/issues/11).

## Legend

- **[V]** — verified by running the tools locally (versions below).
- **[S]** — backed by OOXML / ECMA-376 or another primary source.
- **[?]** — reported elsewhere but not confirmed here; treat as uncertain.

## Versions and instrument

OfficeCLI `1.0.153` (this host's binary; project baseline `1.0.152`); Microsoft Word
`16.0`; WPS Writer `12.0`; LibreOffice `24.2.7.2`. Word/WPS were driven read-only over COM
under the shared `flock` lock; LibreOffice headless with an isolated profile; renders read
with `pdftotext`. Fixture: `tests/fixtures/toc/toc-no-page-numbers.docx`; test:
`tests/toc-cache.sh`.

## The decision this implements

No application rebuilds a TOC on open, and none honours `w:updateFields` on open. The
cached result **is** what Word, WPS, and LibreOffice display until the user updates the
field (see `references/research/field-recalc-and-cross-app-verification.md`). WordFlow has
no layout engine, so any page number it computed would look finished while being wrong
(spec §D9, §D11). The decision is therefore: the cached TOC lists the heading entries with
**no page numbers at all**; the field stays real, so a manual F9 / Update TOC in Word/WPS
adds the reader's own (correct) page numbers.

## Portable construction

Build the TOC with `pageNumbers=false`, then refresh to fill the cache **last**, after all
heading content exists:

```sh
# 1. Define the entry styles the refreshed cache will reference (see "Styles" below).
officecli add "$f" /styles --type style --prop styleId=TOC1 --prop name="TOC 1" ...
officecli add "$f" /styles --type style --prop styleId=TOC2 --prop name="TOC 2" ...
officecli add "$f" /styles --type style --prop styleId=TOC3 --prop name="TOC 3" ...

# 2. Insert the TOC field. pageNumbers=false is the load-bearing property.
officecli add "$f" / --type toc --prop levels="1-3" --prop hyperlinks=true --prop pageNumbers=false

# 3. Add the heading/body content.

# 4. Fill the cached result from the current headings (must run after step 3).
officecli refresh "$f"
```

- **[V]** `add --type toc --prop pageNumbers=false` writes the instruction
  `TOC \o "1-3" \h \z \u` and a placeholder cache
  (`Update field to see table of contents`).
- **[V]** `refresh` then replaces the placeholder with one `TOC1`/`TOC2`/… hyperlink
  paragraph per heading. With `pageNumbers=false` the cache contains **no** tab and **no**
  `PAGEREF` field. Raw check on the fixture: `fldChar` begin/separate/end = 1 each,
  `PAGEREF` = 0, `<w:tab>` = 0.
- **[V]** The result is a normal complex field; `officecli query <f> field` shows
  `/field[1] fieldType=toc evaluated=true` with cached text `Alpha SectionBeta SectionGamma
  Subsection` (entries concatenated, no numbers).
- **[V]** `officecli validate` passes; `scripts/wf-style-ownership.sh` reports
  `coherent=true`, no dangling styles.
- **[V]** Prefer the field **instruction** over the derived `query toc` format readback.
  Under concurrent officecli resident load the `--json` readback has been observed to omit
  the derived `pageNumbers` key while the instruction text
  (`TOC \o "1-3" \h \z \u`) stayed correct; the instruction is the document fact.

For verification, the field instruction/`\z` switch and the cache text are the reliable
signals; `tests/toc-cache.sh` asserts both plus the cross-application displays.

## What each application shows on open

Fixture headings sit on pages 1, 2 and 3 (explicit `pagebreak`s), so a wrong cached page
number would be visible as a wrong number, not merely hidden by "everything is page 1".

| Application | Opens without repair | TOC text on open (no F9) | Page numbers? |
|---|---|---|---|
| Word 16.0 | **yes** | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** |
| WPS Writer 12.0 | **yes** | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** |
| LibreOffice 24.2.7.2 | **yes** | `Alpha Section` / `Beta Section` / `Gamma Subsection` | **none** |

- **[V]** Measured from each application's own PDF export (`pdftotext`) and, for Word/WPS,
  from the live COM object model (`TablesOfContents(1).Range.Text`), which returned
  `\rAlpha Section\rBeta Section\rGamma Subsection\r`. All three display the cache verbatim,
  so the entries appear and no page number does.

## The field stays real: a manual F9 adds page numbers

| Application | TOC text after F9 (`Fields.Update` + `TablesOfContents(1).Update`) |
|---|---|
| Word 16.0 | `Alpha Section<TAB>1`, `Beta Section<TAB>2`, `Gamma Subsection<TAB>3` |
| WPS Writer 12.0 | `Alpha Section<TAB>1`, `Beta Section<TAB>2`, `Gamma Subsection<TAB>3` |

- **[V]** Both applications rebuild the field, restoring the correct page numbers. The TOC
  was never "just text": it is a live `TOC` field whose cache happened to omit the numbers.

## Why `pageNumbers=false` is exactly the right switch (the `\z` finding)

- **[S]** The OOXML/Word TOC switch that *omits page numbers entirely* is `\n`; the `\z`
  switch only *hides tab leader and page numbers in Web layout view*.
- **[V]** OfficeCLI maps `pageNumbers=false` to the **`\z`** switch
  (`TOC \o "1-3" \h \z \u`), not `\n`.
- **[V]** Consequence, confirmed by the F9 measurements above: in normal/print layout `\z`
  leaves page numbers enabled, so updating the field adds them; had OfficeCLI emitted `\n`,
  the field would be permanently page-number-less and the "gains page numbers on F9"
  acceptance could not hold.

> This is a **load-bearing** OfficeCLI behaviour, not a cosmetic one. Do not "fix" it by
> hand-writing `\n`; that would break the update path.

## Styles

- **[V]** `refresh` writes each cached entry with `w:pStyle` `TOC1`, `TOC2`, … If those
  styles are not defined, they become **dangling** references and the D14 checklist fails.
  Define `TOC1`–`TOC3` (the standard style set already does; see
  `scripts/wf-standard-styles.sh`) before refreshing.
- **[V]** The `\h` hyperlinks use `w:anchor="_Toc…"`; `refresh` also inserts the matching
  `w:bookmarkStart`/`w:bookmarkEnd` into each heading paragraph, so no extra relationship
  part is needed and no `Hyperlink` style is required.

## When not to use this pattern

- **[V]** With `pageNumbers=true`, `refresh` writes `PAGEREF` fields whose cached page
  numbers come from OfficeCLI's **HTML pagination**, which does not match Word/WPS layout
  (e.g. a heading OfficeCLI caches as page 2 is page 1 in Word). Word, WPS, and LibreOffice
  display that wrong cache verbatim. Never ship a TOC refreshed with `pageNumbers=true`.
- **[V]** `refresh` must run **after** all heading content; run early and the cache is empty
  or incomplete. Re-run it whenever headings change.
- **[?]** `officecli help docx refresh` states Word + Windows is required for `.docx`, but
  `refresh` completed on Linux here (HTML backend) and filled the cache. The mechanism
  relies on that Linux path.

## Limitation and fallback

The recipe depends on `officecli refresh` filling the cache. If `refresh` is unavailable or
does not populate the TOC on a given host:

- **Fallback (recorded use of `raw-set`).** The DOM layer cannot insert a cached result, so
  compose it with `officecli raw-set` between the field's `separate` and `end` `fldChar`s:
  one `w:p` per heading carrying the `TOC1`/`TOC2`/… style and a
  `w:hyperlink w:anchor="_Toc…"` run over the heading text, plus a matching
  `w:bookmarkStart`/`w:bookmarkEnd` in each heading. This reproduces exactly the
  `refresh`-generated shape (entries, no page numbers). Record the reason, per SKILL rule 4.
- **Last resort.** Omit the TOC and report it — never ship the placeholder
  `Update field to see table of contents` (D11: a placeholder cache is never shipped
  silently).

## Change-report wording

When a TOC is produced this way the change report must state the omitted item (spec §D12
item 5, §D9): *"Table of contents built from the headings; page numbers are intentionally
omitted in v0.1. Update the TOC (Word/WPS: click it and press F9, or Update Table) to add
page numbers."*

## Reproduction

```sh
tests/generate-fixtures.sh                       # builds tests/fixtures/toc/toc-no-page-numbers.docx
tests/toc-cache.sh                               # structural + cross-application checks

# manual cross-application check (Word/WPS serialised under the shared lock):
flock -w 1800 /tmp/wordflow-wincom.lock \
  scripts/wf-compat-harness.sh tests/fixtures/toc/toc-no-page-numbers.docx \
  --apps word,wps,libreoffice --out tests/.out/compat/issue11 --no-visual
```

## Spec / documentation conflicts raised

None. The mechanism satisfies §D9 as written: entries present, no page numbers in the cache,
field real and updatable. The only point worth recording for authors is the `\z`-vs-`\n`
distinction above — the acceptance ("gains page numbers on F9") depends on `\z`.
