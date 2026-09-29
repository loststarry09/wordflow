# DOCX feature portability (research notes)

Per-feature notes distilled from the DOCX research pass (see `report/2026-09-28-docx-layout-research.md`). This is a **facts** file, not product guidance.

Legend:
- **[V]** — verified locally with OfficeCLI 1.0.152 or directly from the standard's definitions.
- **[S]** — backed by OOXML / ECMA-376.
- **[?]** — reported by external sources but not confirmed here (WPS is closed-source and LibreOffice Bugzilla was unreachable during research). Treat as uncertain.

General:
- **[S]** Emit **Transitional** OOXML, not Strict. Word, WPS and LibreOffice read the Transitional namespace (`schemas.openxmlformats.org/wordprocessingml/2006/main`); tooling such as python-docx rejects Strict (`purl.oclc.org/ooxml/...`).
- **[V]** OfficeCLI emits Transitional (`portability/transitional-baseline.docx` carries no `purl.oclc.org` reference).
- **[S]** `w:compatibilityMode=15` (Word 2013+) is present by default in OfficeCLI output.

## core/ — styles, headings, sections, headers/footers, page numbers

### Styles
- **[S]** `w:styleId` is the machine identity; `w:name` is the UI label. Built-in names are locale-independent (`heading 1`, `normal`, `caption`); `w:latentStyles` declares behaviour of styles not present, it is not a definition.
- **[S]** Applying an undefined style is a **silent no-op** in Word (python-docx issue tracker, `styles` semantics).
- **[V]** OfficeCLI auto-defines only some built-ins (`Title`, `Heading1`–`Heading9`); `Caption` stayed dangling. See `references/research/officecli-behavior.md`.
- **[?]** Tools keying off `styleId` vs `name` disagree; localized names can break heading/TOC detection (docling #3959). A `tblStyle` referencing a missing style applies nothing (docx4java).
- **[?]** WPS style/font round-trip is the top compatibility risk; no format-level documentation exists.

### Headings and TOC
- **[S]** TOC fields depend on heading styles + outline levels. Word rebuilds a TOC on open only when `w:updateFields=true`; without cached entries LibreOffice shows `Error! No table of contents entries found`.
- **[V]** OfficeCLI writes the TOC field and `refresh` (HTML backend) populated cached entries on Linux. **But Word 16 and WPS 12 do not recalculate fields on open** (not even with `updateFields=true`), and display the cached entries verbatim — including OfficeCLI's page numbers, which were **wrong** (2 where Word/WPS compute 1). See `field-recalc-and-cross-app-verification.md`.
- **[V]** None of Word, WPS, or LibreOffice rebuilds or updates the TOC on open (measured); see `field-recalc-and-cross-app-verification.md`.

### Sections and margins
- **[S]** The final `w:sectPr` is a child of `w:body`; other section breaks live in `w:pPr/w:sectPr` of the last paragraph of the preceding section. Type ∈ `nextPage|continuous|evenPage|oddPage|nextColumn`.
- **[?]** LibreOffice `continuous` section breaks have long-standing spacing/margin issues; `nextPage` is the safer portable choice.
- **[V]** OfficeCLI's `add section` model matches the standard: an empty paragraph carries the break; `/section[N]` paths address them.

### Headers, footers, page numbers
- **[S]** Variants are `default|first|even`; `w:titlePg` enables the first-page variant per section; `w:evenAndOddHeaders` (in `settings.xml`) enables even variants. `w:pgNumType` (`@w:start`, `@w:fmt`) in a section restarts/formats numbering.
- **[?]** LibreOffice has visibility regressions for first/even headers and does not always preserve link-to-previous; header distance can drift.
- **[V]** OfficeCLI `field=page` writes a complete cached PAGE field chain in the footer.

### CJK typography
- **[S]** Set all four font slots (`ascii`/`hAnsi`/`eastAsia`/`cs`); `w:ind @firstLineChars` is the character-unit first-line indent; `w:docGrid`, `w:kinsoku`, `w:autoSpaceDE/DN` control grid and punctuation.
- **[V]** OfficeCLI: `font.ea`/`font.latin` set per-script fonts; `firstLineChars=200` (= 2 chars) is settable after Add; `firstLineIndent=2em` is rejected.
- **[?]** Word's CJK line-height multiplier reflows text relative to LibreOffice; grid/table interactions differ.

## fields/ — fields, captions, cross-references, notes

### Fields generally
- **[S]** A complex field is `fldChar begin` → `instrText` → `fldChar separate` → cached result → `fldChar end`. `w:updateFields` / `w:dirty` request recalculation; no consumer is contractually required to honour them.
- **[V]** OfficeCLI `add field` **always writes a cached result**, so every field reads `evaluated=true` even when its cache is a placeholder (TOC `Update field to see table of contents`; REF `«target»`), and `view issues` reports nothing. Judge a field by its cached **text**. *(Corrects an earlier note here that cited an `#OCLI_NOTEVAL!` sentinel for uncached fields; that does not describe `add field` in 1.0.152 — see `field-recalc-and-cross-app-verification.md` §1.)*
- **[V]** Word 16, WPS 12 **and LibreOffice 24.2** do **not** update fields on open, even with `updateFields=true`; Word/WPS resolve them correctly on a manual update (F9). LibreOffice additionally resolves `REF` on import but does not rebuild the TOC. See `field-recalc-and-cross-app-verification.md` §3 and §6.

### Captions / SEQ
- **[S]** `SEQ` fields (`\* ARABIC`, `\s`, `\r`, `\c`) with a cached result; define the `Caption` style explicitly.
- **[V]** OfficeCLI: defined `Caption` + `SEQ Figure` + `recalcFields=seq` yields `Figure 1: …`.
- **[?]** LibreOffice uses its own caption/number-range model and bookmarks for cross-refs; whether LO/WPS renumber a raw `SEQ` on import is unverified.

### Bookmarks / REF / PAGEREF
- **[S]** `w:bookmarkStart/End` plus `REF bookmark \h` / `PAGEREF bookmark \h`; emit cached results so the reference shows before any update.
- **[V]** OfficeCLI `refresh` resolves `PAGEREF` but leaves `REF` cached text as the placeholder `«target»` with `evaluated=true`.
- **[?]** LibreOffice has had regressions losing bookmarks on round-trip.

### Footnotes / endnotes
- **[S]** `w:footnoteReference`/`w:endnoteReference`; `w:footnotePr`/`w:endnotePr` in `w:sectPr` control restart and placement.
- **[?]** Per-section restart is often ignored; footnote↔endnote conversion can create two note sets.

## objects/ — images, tables, equations

### Images
- **[S]** Prefer `wp:inline` with explicit `wp:extent`; floating uses `wp:anchor` + `wp:positionH/V`, `wp:wrapSquare|wrapTight|wrapTopAndBottom`, `wp:relativeFrom`. `a:blip @r:embed` references a media part.
- **[V]** OfficeCLI supports inline/anchored with wrap modes, `alt`, width/height (aspect preserved), crop.
- **[?]** Anchored/wrap rendering diverges between renderers; EMF/WMF/TIFF/SVG fail in some consumers (ship PNG/JPEG, or dual SVG+PNG).

### Tables
- **[S]** `w:tblLayout type="fixed"` with explicit `w:tblW`/`w:gridCol`/`w:tcW`; direct `w:tblBorders`/`w:tcBorders`/`w:shd`; `w:tblHeader` repeats a header row.
- **[V]** OfficeCLI `data=`, `layout=fixed`, `colWidths`, `border.all="single;8;000000"`, and `tr[1]/header=true` all work.
- **[?]** LibreOffice regressions: nested tables escaping their parent, repeated header rows and borders after save, floating-table width. Style-referenced borders apply nothing if the style is missing.

### Equations
- **[S]** Modern equations are OMML (`m:oMath`, `m:oMathPara`); legacy is OLE Equation Editor.
- **[V]** OfficeCLI `mode=inline|display` with a LaTeX-ish `formula`; `\frac` becomes `m:f`.
- **[?]** LibreOffice converts OMML to its formula model (lossy); community advice is to hint `m:r` runs with Cambria Math, which is not Microsoft-documented.

## compatibility/ — summary ranking

Most portable → least portable constructions:
1. Styles with explicit `styleId` + canonical name, defined before use.
2. `nextPage` sections with explicit `pgSz`/`pgMar`.
3. Inline images; fixed (non-floating, non-nested) tables with direct borders.
4. Fields with cached results + `updateFields`/`dirty`.
5. OMML equations with simple constructs (fractions, sums); avoid matrices/`eqArr` where fidelity matters.

Highest-risk constructs: TOC without cached entries; floating/nested objects; localized style names; `continuous` sections; CJK grid interactions; `SEQ` auto-renumbering.
