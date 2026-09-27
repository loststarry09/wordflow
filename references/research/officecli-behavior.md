# OfficeCLI behaviour (verified notes)

Durable notes on what OfficeCLI actually does, distilled from the DOCX research pass (see `report/2026-09-28-docx-layout-research.md`). This is a **facts** file, not product guidance.

Legend:
- **[V]** — verified by running OfficeCLI locally (version below).
- **[S]** — backed by the OOXML/ECMA-376 standard.
- **[?]** — reported elsewhere but not confirmed here; treat as uncertain.

Pinned version: **OfficeCLI 1.0.152** (`officecli --version`). Help is version-pinned and authoritative for schema; these notes record observed behaviour and gaps.

## Document creation and defaults

- **[V]** `officecli create <file> --locale <tag>` sets per-script default fonts in `docDefaults` and enables RTL for Arabic/Hebrew/etc. locales. Without `--locale`, the host locale is used, so output is **not reproducible** across machines. Always pass `--locale`.
- **[V]** With `--locale en-US`, `get /` showed `docDefaults.font=Times New Roman`, `theme.font.minor.latin=Calibri`, margins 2.54 cm top/bottom and 3.18 cm left/right, A4 page, `compatibility.mode=15`.
- **[V]** With `--locale zh-CN`, `get /` showed `docDefaults.font.eastAsia=等线` (DengXian) and `theme.font.minor.eastAsia=等线`, `locale=zh-CN`.
- **[V]** `create --minimal` skips the Word-style baseline (Normal style, theme1.xml, Calibri) and emits a raw OOXML-spec document; useful for edge-case tests.
- **[V]** Default documents carry `compatibility.balanceSingleByteDoubleByteWidth=true`, `compatibility.doNotExpandShiftReturn=true`, `compatibility.adjustLineHeightInTable=true`, and `docGrid.type=default`.

## Styles

- **[V]** A small set of built-in styles is **auto-defined** when first referenced: `Title`, `Heading1`…`Heading9` produced a `… was not defined … added Word's built-in definition` warning and appeared in `styles.xml`.
- **[V]** Other built-ins are **not** auto-defined. Referencing `Caption` produced `style 'Caption' not found in styles part — will be referenced as-is`, and `styles.xml` contained only `Heading1` and `Normal`. The paragraph was left with the style name `caption` but no definition — a **dangling reference**.
- **[V]** Explicit style definition works: `officecli add <f> /styles --type style --prop styleId=Caption --prop name="caption" --prop type=paragraph --prop basedOn=Normal --prop qFormat=true …`.
- **[V]** `w:styleId` is the identity; `get` of a styled paragraph reported `style=caption styleId=Caption styleName=caption`. `styleId` cannot be renamed after Add.
- **[V]** `styles.xml` after a default create contained `Normal` + whatever was auto-added; it is not a full Word stylesheet.

## Sections

- **[V]** `officecli add <f> / --type section --prop type=nextPage` inserts a **blank paragraph carrying the section break** (the previous section's `sectPr`) and leaves the document-level `sectPr` as the final section. Paths are `/section[1]`… .
- **[V]** To change the *second* section's page setup, add the break first, add the following content, then `set /section[2] …`. In a two-section test this produced `/section[1]` portrait and `/section[2]` landscape with independent margins.
- **[V]** Section properties include `type` (`nextPage|evenPage|oddPage|nextColumn`, also aliases), `pageWidth/Height`, `orientation`, all four margins plus header/footer/gutter, `columns`/`columnSpace`, `titlePage`, `pageNumFmt`, `pageStart`, `lineNumbers`.
- **[V]** `get` surfaces an empty section-break paragraph with `sectionBreak=…` fields; this paragraph is expected to look "empty" (see `view issues` below).

## Headers and footers

- **[V]** `officecli add <f> / --type footer --prop field=page --prop align=center` creates `/footer[1]` and writes a complete field chain: `fldChar begin` → `instrText " PAGE "` → `fldChar separate` → cached run `"1"` → `fldChar end`.
- **[V]** Header/footer parts are addressed `/header[N]`, `/footer[N]`; `raw <f> /footer1` is **invalid** (returns `(footer[0] not found)`).

## Fields, TOC, cross-references

- **[V]** `add <f> /<paragraph> --type field --prop fieldType=ref|pageref --prop name=<bookmark> --prop hyperlink=true` appends a field; fields and runs interleave in add order.
- **[V]** `add <f> / --type toc --prop levels="1-3" --prop title="Contents" --prop hyperlinks=true --prop pageNumbers=true` inserts a `TOCHeading` paragraph plus a TOC field with instruction `TOC \o "1-3" \h \u`.
- **[V]** `officecli set <f> / --prop recalcFields=seq` writes cached SEQ values in body order. In a caption test the `SEQ Figure` cache read `1`, and `view text` rendered `Figure 1: Example caption.`.
- **[V] `refresh` runs on Linux** and reports `Refreshed: … (backend: html)` with `Note: HTML fallback used. TOC page numbers reflect officecli's HTML pagination.` The CLI help still says "Word + Windows required for .docx", so treat the fallback as best-effort and version-dependent.
- **[V]** After `refresh`, TOC cached entries were populated (`Introduction\t2`, `Background\t2`, `Methods\t2`) and `PAGEREF` caches became real page numbers (`1`). `evaluated=true` for all.
- **[V] `refresh` does NOT resolve `REF`.** `REF target \h` reported `evaluated=true` but its cached text stayed the placeholder `«target»`, rendered as `Reference: «target» on page 1`. `PAGEREF` in the same paragraph resolved correctly. **Do not trust `evaluated=true` alone for `REF`; check the cached text.**
- **[V]** Fields written without a cache render the sentinel `#OCLI_NOTEVAL!` in `view text`; `view issues` emits subtype `field_not_evaluated`.

## Pictures and equations

- **[V]** `add <f> /body/p[N] --type picture --prop src=… --prop alt=… --prop width=3cm` inserts an inline picture into a run and preserves aspect ratio (height derived from width).
- **[V]** Anchored pictures accept `anchor=true`, `wrap=topAndBottom` (read back as `topandbottom`), `hRelative`, `vRelative`, `hPosition`, `vPosition`, `behindText`.
- **[V]** `add <f> /body --type equation --prop mode=inline --prop formula="E = mc^2"` creates `/body/p[N]/oMath[1]`; `mode=display` creates `/body/oMathPara[1]`. `\frac{a}{b}` becomes `m:f` with `m:num`/`m:den`.

## Footnotes, bookmarks

- **[V]** `add <f> /body/p[N] --type footnote --prop text=…` creates `/footnote[@footnoteId=1]` anchored to the paragraph.
- **[V]** `add <f> / --type bookmark --prop name=target --prop text="…"` creates a paragraph containing the bookmarked text (`bookmarkStart`/`bookmarkEnd` with a numeric `id`).

## Indentation and CJK

- **[V]** Paragraph `firstLineIndent` is a **length** routed through a spacing converter; `2em` is rejected (`Invalid 'spacing' value '2em'`), use `2cm`/`pt`.
- **[V]** `firstLineChars` (1/100 character, `w:ind @firstLineChars`) is **set/get only, not add**. To use it: add the paragraph, then `set /body/p[N] --prop firstLineChars=200`. `hangingChars` and `leftChars` exist similarly.
- **[V]** Setting `font.ea` and `font.latin` on a paragraph writes `w:rFonts` on its runs.

## Validation and issue reporting

- **[V]** `officecli validate <f>` prints `Validation passed: no errors found.` for all fixtures and exits 0.
- **[V]** `officecli view <f> issues` reports **style heuristics**, not only schema problems. Two observed advisory checks:
  - `[F] Body paragraph missing first-line indent` — for `Normal` body paragraphs without a 2-character first-line indent. Suppressed by `firstLineChars=200`.
  - `[S] Empty paragraph` — for the blank paragraph carrying a section break.
- **[V]** `view issues --type field_not_evaluated` etc. selects subtypes; a subtype that does not apply returns `count=0`, not an error.

## Round-trip and process

- **[V]** `dump <f> /body --json` produces a replayable batch (`dumpVersion: 2`); `batch` executes one open/save cycle and is atomic by default (any failure rolls back the whole batch; `--best-effort` opts out).
- **[V]** `view <f> screenshot --grid auto -o out.png`, `view <f> html -o out.html`, and `validate` all work headless on Linux.
- **[V] A live resident leaks state between fixtures.** If a file is not closed, a later `rm` + `create` on the same path can leave the previous in-memory document in place and reproduce confusing, non-deterministic results. Always `officecli close <f>` (or otherwise ensure a fresh file) between fixtures. The generator/validator do this.

## Uncertain / to confirm later

- **[?]** Whether the `refresh` HTML fallback remains correct across OfficeCLI versions and longer documents.
- **[?]** Whether `REF` resolution is added in a future version.
- **[?]** Behaviour of `differentFirstPage` as a prop (unsupported today) versus adding a `type=first` footer.
