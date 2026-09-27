# WordFlow — DOCX Layout Research Report

- **Date**: 2026-09-28
- **Type**: read-only research (no product requirements changed, no architecture decisions made, no implementation)
- **Subject**: OfficeCLI's DOCX capabilities and official skills; standard DOCX layout features; Word/WPS/LibreOffice compatibility; external projects worth borrowing
- **Baseline tooling**: OfficeCLI `1.0.152` at `/home/carlos/.local/bin/officecli`

This report separates **verified facts**, **OfficeCLI's current capabilities**, **external designs worth borrowing**, **compatibility risks**, and **open questions**. Claims from web sources carry a URL; uncertain items are marked **[uncertain]**. Local claims were verified by running OfficeCLI against throwaway files in `/tmp/opencode/wf-research` (never in the WordFlow repo).

---

## 0. Method & sources

- **Primary (local, authoritative)**: the installed OfficeCLI binary — `officecli help docx <element>`, and live commands on scratch `.docx` files. Help is version-pinned and authoritative per OfficeCLI's own Help-First Rule.
- **Primary (vendor)**: OfficeCLI's official skills and repo/wiki, fetched raw from GitHub:
  - `skills/officecli-docx/SKILL.md` (the "word" skill) — https://github.com/iOfficeAI/OfficeCLI/blob/main/skills/officecli-docx/SKILL.md
  - `skills/officecli-academic-paper/SKILL.md` — https://github.com/iOfficeAI/OfficeCLI/blob/main/skills/officecli-academic-paper/SKILL.md
  - `skills/officecli-word-form/SKILL.md` — https://github.com/iOfficeAI/OfficeCLI/blob/main/skills/officecli-word-form/SKILL.md
  - base `SKILL.md` — https://github.com/iOfficeAI/OfficeCLI/blob/main/SKILL.md
  - wiki: https://github.com/iOfficeAI/OfficeCLI/wiki/workflows · https://github.com/iOfficeAI/OfficeCLI/wiki/agent-guide
- **Spec/standards**: ECMA-376 / ISO 29500 mirrors (ooxml.org, c-rex.net), Microsoft Learn (Open XML SDK, MS-OI29500, MS-OE376).
- **Compatibility**: LibreOffice documentation/release notes, Microsoft Q&A, python-docx/docx4j issue trackers, project bug trackers. **LibreOffice Bugzilla was behind a proof-of-work wall during research**; those bug references come from indexed snippets. **WPS is closed-source with almost no format-level documentation**, so WPS claims are lower confidence.
- **Two parallel research passes** (compatibility; external project design) were delegated and their sourced findings are synthesised below.

---

## 1. Verified facts

### 1.1 OfficeCLI (local, 1.0.152)

Observed by running commands on fresh files:

| Fact | Evidence |
|---|---|
| Adding `style=Heading1` to a fresh doc **auto-creates Word's built-in definition** for that style | `add … --prop style=Heading1` → `WARNING: style 'Heading1' was not defined in the styles part; added Word's built-in definition ('heading 1')` |
| A **non-auto-defined style reference stays dangling**. `style=Caption` did **not** create `w:styleId="Caption"` | `WARNING: style 'Caption' not found in styles part — will be referenced as-is`; `raw /styles` then contained only `Heading1` and `Normal` |
| `RAW` part addressing uses element paths, e.g. `/header[1]`, `/footer[1]` — not `/footer1` | `raw cap.docx /footer1` → `(footer[0] not found)`; `/footer[1]` works |
| Footer `field=page` writes a complete 5-run field chain | `get "/footer[1]" --depth 3` → run, `fieldChar begin`, `instrText " PAGE "`, `fieldChar separate`, run `"1"`, `fieldChar end` |
| `toc` inserts a real TOC field: `instruction = TOC \o "1-3" \h \u` | `get /toc --depth 2` |
| `recalcFields=seq` writes cached SEQ values and flips `evaluated=true` | `set / --prop recalcFields=seq`; `query field` → `/field[1] "1" instruction=SEQ Figure evaluated=true` |
| **`refresh` runs on Linux with an HTML pagination backend** (does not require Word/Windows) and fills page-number fields | `refresh cap.docx` → `Refreshed … (backend: html)`; afterwards `PAGEREF` fields read `evaluated=true` and TOC cached entries appeared |
| `updateFields=true` writes `<w:updateFields w:val="true"/>` | `raw /settings` contained `updateFields`; `get /` shows `updateFields=true` |
| Document root exposes page setup, compatibility and theme | `get /` → `pageWidth=21cm … marginLeft=3.18cm … compatibility.mode=15 … docGrid.type=default … theme.font.minor.latin=Calibri …` |
| `dump /body` produces a replayable batch (`dumpVersion: 2`) | `dump cap.docx /body --json` |
| `validate` passes for a doc containing heading, Caption-style ref, SEQ, PAGEREF, TOC, footnote, equation, footer PAGE field | `validate cap.docx` → `no errors found` |
| A contact-sheet screenshot can be produced headlessly | `view cap.docx screenshot --grid auto -o sheet.png` → PNG written |
| A `Footer`/`Header` can be added on a fresh officecli-created doc (`add / --type header` succeeds; `query header` was empty beforehand) | live run; note this differs from the word-form skill's K16, which concerns Word-created files where the parts already exist |

> **Correction to the initialization report**: it stated DOCX `refresh` requires Word + Windows and that TOC page numbers cannot be produced without Word. Live behaviour shows an **HTML pagination fallback** that does evaluate page-number fields on Linux. The CLI help text still says "Word + Windows required for .docx", so this behaviour may be version-dependent and should be treated as best-effort.

### 1.2 Standards facts (portable constructs)

- Styles: `w:styleId` is the machine identity; `w:name` is the UI label. Built-in canonical names are locale-independent (`heading 1`, `normal`, `caption`). `w:latentStyles` declares behaviour of styles absent from the file; it is not a definition. Inheritance via `w:basedOn`/`w:next`; theme fonts via `w:asciiTheme`/`w:hAnsiTheme`/`w:eastAsiaTheme`. — https://ooxml.org/wordml/w-name/ , https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.latentstyles
- Sections: final `w:sectPr` is a child of `w:body`; other breaks live in `w:pPr/w:sectPr` of the last paragraph of the preceding section; type ∈ `nextPage|continuous|evenPage|oddPage|nextColumn`. — https://ooxml.org/wordml/w-sectpr
- Headers/footers: `w:headerReference`/`w:footerReference` with `w:type` ∈ `default|first|even`; `w:titlePg` enables first-page variant per section; `w:evenAndOddHeaders` in `settings.xml` enables even variants. — https://ooxml.org/wordml/w-evenandoddheaders
- Page numbering: `PAGE`/`NUMPAGES` fields; `w:pgNumType` (`@w:start`, `@w:fmt`) inside each `w:sectPr` for restart/format. — https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.pagenumbertype
- Pictures: `wp:inline` vs `wp:anchor` (+ `wp:positionH/V`, `wp:wrapSquare|wrapTight|wrapTopAndBottom`, `wp:relativeFrom`); `a:blip @r:embed` references a media part.
- Tables: `w:tblLayout @w:type=fixed|autofit`, `w:gridSpan`, `w:vMerge` (`restart|continue`), `w:tblHeader`, `w:tblStyle`, direct `w:tblBorders`/`w:tcBorders`/`w:shd`. — https://ooxml.org/wordml/w-tblpr
- Captions: `Caption` style + `SEQ Figure`/`SEQ Table` field (`\* ARABIC`, `\s`, `\r`, `\c`). — http://c-rex.net/samples/ooxml/e1/Part4/OOXML_P4_DOCX_SEQSEQ_topic_ID0ETJM1.html
- Cross-refs: `w:bookmarkStart/End` + `REF bookmark \h` / `PAGEREF bookmark \h`. — (see §3.8)
- TOC: `TOC` field with switches `\o "1-3" \h \z \u`; `w:updateFields` in `settings.xml`; `w:dirty` on the field. — https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.updatefieldsonopen
- Notes: `w:footnoteReference`/`w:endnoteReference`; `w:footnotePr`/`w:endnotePr` in `w:sectPr` for restart and placement.
- Equations: modern is OMML (`m:oMath`, `m:oMathPara`); legacy is OLE Equation Editor / MathType. — https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oe376/
- Fields: complex field = `w:fldChar begin / w:instrText / w:fldChar separate / cached result / w:fldChar end`; `w:updateFields` and `w:dirty` request recalculation.
- CJK: `w:rFonts @w:eastAsia`, `w:ind @w:firstLineChars`, `w:kinsoku`, `w:autoSpaceDE`/`w:autoSpaceDN`, `w:docGrid`. — https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.docgrid
- Conformance: Transitional OOXML (the `schemas.openxmlformats.org/...` namespace) is what all three suites read; Strict OOXML (`purl.oclc.org/ooxml/...`) is widely rejected by tooling. — https://github.com/python-openxml/python-docx/issues/693

---

## 2. OfficeCLI current capabilities

Element inventory (from `officecli help docx`): `abstractNum`, `body`, `diagram`, `document`, `footer`, `header`, `markdown`, `num`, `numbering`, `paragraph` (children: bookmark, bookmarkEnd, chart, comment, endnote, equation, field, fieldchar, footnote, formfield, hyperlink, instrtext, ole, pagebreak, permStart, picture, ptab, revision, run, sdt, tab, toc), `raw`, `section`, `shape`, `style`, `styles`, `table`/`table-row`/`table-cell`, `textbox`, `watermark`.

### 2.1 Capability matrix (verified against 1.0.152)

| Concern | OfficeCLI support | Verified detail / limits |
|---|---|---|
| **Styles** | Full: add/set/get/query/remove on `/styles/StyleId` | Paragraph/character/table/numbering types; `basedOn`, `next`, `linked`, `qFormat`, `uiPriority`, `semiHidden`, `outlineLvl`, `numId`, `pbdr`, `indents`, `lineSpacing`. Built-in ids bypass `customStyle`: `Normal, Heading1..9, Title, Subtitle, Quote, IntenseQuote, ListParagraph, NoSpacing, TOCHeading`. **`Heading1` auto-defines; other built-ins (e.g. `Caption`) are only referenced, not defined** (verified). Renaming a `styleId` is not supported. |
| **Sections / margins / pagination** | Full on `/` and `/section[N]` | `pageWidth/Height`, `orientation`, `marginTop/Bottom/Left/Right`, `marginHeader/Footer`, `marginGutter`, `columns`, `columnSpace`, `titlePage`, `pageNumFmt` (wide enum incl. `lowerRoman`, `hindiNumbers`), `pageStart`, `lineNumbers`, `pgBorders`. `mirrorMargins`, `evenAndOddHeaders` at `/`. |
| **Header / footer / page number** | Full: `header`/`footer` (default/first/even) + `field` prop | `add / --type footer --prop field=page` injects the complete fldChar chain (verified). `differentFirstPage` is unsupported as a prop; adding a `type=first` footer flips `titlePg`. Composite "Page X of Y" is composed from child `field`s. |
| **Pictures** | Full: `picture` child of a run | `src`, `alt`, `width/height`, `anchor`, `wrap`, `behindText`, `hPosition/vPosition`, `hRelative/vRelative`, `crop`, `decorative`, `effectExtent`. Inline by default; `anchor=true` to float. |
| **Tables** | Full: `table`/`table-row`/`table-cell` | `rows/cols`, `width`, `layout`, `align`, `indent`, `cellSpacing`, `style` (tableStyle), `border.*`, `colWidths`; row `header`, `height`, `cantSplit`; cell `fill`/`shd`, `valign`, `hmerge`, `vmerge`, `border.*`, `nowrap`. Row-level `cN=` text shortcut. |
| **Caption / SEQ** | Composed, not a dedicated element | `style=Caption` reference + `field fieldType=seq identifier=Figure`. `recalcFields=seq` writes cached numbers. **No built-in Caption definition is auto-added** (verified). |
| **Bookmark / REF / PAGEREF** | Full | `bookmark` add/set/get/remove; `field fieldType=ref\|pageref` with `name` + `hyperlink=true` (`\h`). Cached results filled by `refresh` (HTML backend) or deferred via `updateFields`. |
| **TOC** | Full: `toc` / `/tableofcontents` | `levels`, `title`, `hyperlinks`, `pageNumbers`; inserts complex TOC field (verified instruction `TOC \o "1-3" \h \u`). Page numbers need recalc; `refresh` (HTML backend) filled them locally. |
| **Footnote / endnote** | Full | `footnote`/`endnote` anchored to a paragraph; `text`, `direction`, `align`, font slots (`font.latin/ea/cs`), `bold.cs/italic.cs`. |
| **Equation** | Full: `equation` | `mode=display` → `/body/oMathPara[N]`; `mode=inline` → `<m:oMath>` in a paragraph; `formula` is LaTeX-ish. Get returns `mode` and the formula in `Text`. Non-body parent guard: cells must target `tc/p[1]`. |
| **Fields** | Full: 30+ `fieldType` values | `page, pagenum, numpages, date, author, title, time, filename, section, sectionpages, mergefield, ref, pageref, noteref, seq, styleref, docproperty, if, createdate, savedate, printdate, edittime, lastsavedby, subject, numwords, numchars, revnum, template, comments, doccomments, keywords`; plus `instruction`, `format`, `epoch`. `evaluated` readback tells cache presence. |
| **Extras** | numbering/abstractNum, tab stops, hyperlink, comment, sdt, formfield, chart, ole, textbox/shape, diagram, watermark, pagebreak, revision (tracked changes) | Beyond current WordFlow scope but available. |
| **Low-level / round-trip** | `raw`, `raw-set`, `add-part`, `dump`, `batch` (atomic by default since 1.0.137; `--best-effort` to disable), `validate`, `view issues`, `refresh`, `create --minimal`, `merge`, `plugins` | `dump`/`batch` gives reproducible replay (`dumpVersion: 2`). |

### 2.2 OfficeCLI's own recommended usage (from its skills)

The official `officecli-docx` skill establishes patterns WordFlow should align with rather than duplicate:

- **Help-First Rule**: the skill teaches *decisions*, `officecli help docx <element>` teaches *schema*; when they disagree, **help is authoritative**.
- **Layering**: L1 semantic props → L2 dotted-attr fallback → L3 `raw-set`; use the highest layer that works.
- **Incremental execution**: one command at a time; re-`get` after every structural op; `[N]` paths are 1-based, `--index` is 0-based and shifts on insert.
- **Output contract**: clear Title→H1→H2 hierarchy; explicit heading sizes; one body font; spacing via `spaceBefore/After`, never empty paragraphs; live `PAGE` fields, never literal "Page 1"; curly quotes / en/em dashes.
- **Fields carry caches**: judge field presence by `fldChar` structure, not the visible digit; `recalcFields=seq` for SEQ, `updateFields=true` for pagination-dependent fields.
- **Pages/columns**: choose exactly one page-break mechanism (`pageBreakBefore` **or** explicit `pagebreak`, never both); multi-column does **not** auto-revert — a second section break must set `columns=1`.
- **QA**: `validate` + `view issues` + `view html`/`screenshot --grid` (the "render → look → fix" loop); a copy-paste Delivery Gate; `validate` catches schema, not design errors.
- **Taxonomy**: attribute a symptom as `[AGENT-ERROR]` (document wrong), `[RENDERER-BUG]` (document right, viewer differs), or `[SKILL gap]`.
- **Known renderer quirks** (explicitly not to chase): PAGE field may render literal "Page" until recalculated; TOC cached numbers may read "1 1 1 1"; pie/doughnut fill collapse; formfield checkbox `☐☐` in LibreOffice; OMML baseline shifts.

The `academic-paper` skill is a **scene layer** over `officecli-docx` (inherits base rules, adds citation styles, OMML equations, `SEQ`/`PAGEREF`, multi-column, bibliography hanging indent, extra gates). The `word-form` skill is **independent** (different payload: `w:sdt`/`w:ffData`/`documentProtection`; different QA) and enables form protection last. Both define a **reverse handoff** back to the base skill when the document type differs.

> **Observed defect in the vendor skills**: `officecli-academic-paper` repeatedly cross-references `docx v2 §Schema-invalid-on-emit`, a heading that **does not exist** in the current `officecli-docx` skill. Cross-file section references rot — a caution for WordFlow's own reference docs.

---

## 3. Standard DOCX features: portable construct, OfficeCLI support, compatibility

Per-feature synthesis of the compatibility research. "Portable construct" = what all three suites handle best.

### 3.1 Styles
- **Portable**: emit explicit `w:styleId` **and** canonical locale-independent `w:name`; `basedOn`→`Normal`; prefer explicit font names over theme references for determinism.
- **Risk**: tools keying off `styleId` vs `name` disagree; localized names silently break heading/TOC detection (docling #3959); a `tblStyle` referencing a missing style applies **nothing** (docx4java).
- **LibreOffice** maps Word styles onto its own model and does not use `latentStyles`; **WPS**: styles/fonts are the top round-trip risk **[uncertain]**.
- **WordFlow implication**: never rely on a built-in being auto-resolved. OfficeCLI verified this: `Caption` was left dangling.

### 3.2 Sections / margins / pagination
- **Portable**: prefer `nextPage`; encode `pgSz`/`pgMar`/`cols` explicitly per section.
- **Risk**: LibreOffice `continuous` section breaks have long-standing spacing/margin issues (tdf#170119 snippet; LO 24.8 fixed "spacing before paragraph ignored after section break"); orientation handled as page styles in LO.
- OfficeCLI exposes all needed section props (verified).

### 3.3 Headers / footers / page numbers
- **Portable**: declare all needed variants explicitly (`default`+`first`+`even`); set `w:titlePg` and `w:evenAndOddHeaders`; put `w:pgNumType` in each restarting `sectPr`; always write a cached field result.
- **Risk**: LO visibility regressions for first/even headers (ReleaseNotes/25.2); link-to-previous semantics not preserved; header distance drift. Page-number restart fails if `pgNumType` lands in the wrong section.

### 4.4 Pictures
- **Portable**: prefer **inline** `wp:inline` with explicit `wp:extent`; if floating, use `wrapTopAndBottom`/`behindText` with explicit `relativeFrom`; embed PNG/JPEG; for SVG ship the dual `asvg:svgBlip` + PNG fallback.
- **Risk**: anchored/`wrapSquare`/`wrapTight` rendering diverges between renderers (Docxodus #412); anchored images shift to the wrong page/paragraph; EMF/WMF/TIFF/SVG unsupported by some consumers (emfio docs; docxjs #193); LO FILESAVE has lost image sizes (whatsnew 26.2.3).

### 3.5 Tables
- **Portable**: `w:tblLayout type="fixed"` with explicit `w:tblW`/`w:gridCol`/`w:tcW`; **direct** `w:tblBorders`/`w:tcBorders`/`w:shd` rather than a style; `w:tblHeader` on the header row; avoid nested and floating tables.
- **Risk**: LO regressions — nested table escapes its parent (24.8.5), repeated header row and borders after FILESAVE (26.2.3), floating-table width (tdf#116854); table-style conditional formatting (`w:tblLook`) coverage differs.

### 3.6 Captions / SEQ
- **Portable**: literal text + `SEQ` field **with cached result**, anchored to an explicit bookmark for cross-refs; define the `Caption` style explicitly.
- **Risk**: LO uses its own caption/number-range model and bookmarks for cross-refs, not `SEQ`; whether LO/WPS recompute a raw `SEQ` on import is **[uncertain]**. A pre-recalc SEQ renders the sentinel `#OCLI_NOTEVAL!`.
- OfficeCLI: `recalcFields=seq` writes correct cached values in body order; heading-relative `\s` and header/footer SEQ defer to Word.

### 3.7 Bookmarks / REF / PAGEREF
- **Portable**: emit fields with **cached results**; `\h` makes them hyperlinks; keep bookmarks outside the referenced field where possible; `updateFields` + `dirty`.
- **Risk**: REF with no cache renders blank until update; LO ate a bookmark in one regression (24.8.3) **[snippet]**; `\h` behaviour differs.
- OfficeCLI: `refresh` (HTML backend) evaluated PAGEREF caches locally (verified).

### 3.8 TOC
- **Portable**: built-in `Heading1..9` with correct outline levels; TOC field **with a cached result**; `w:updateFields=true` and `dirty=true`.
- **Risk (highest)**: without cached entries LO shows **"Error! No table of contents entries found"**; Word rebuilds only if `w:updateFields` is set (and, per one report, its global "update automatic links at open" setting); WPS builds from heading styles but no OOXML docs.
- OfficeCLI: writes the field; `refresh` filled cached entries in the local test.

### 3.9 Footnote / endnote
- **Portable**: explicit `footnotePr`/`endnotePr`; keep numbering continuous where possible.
- **Risk**: per-section restart ignored; endnote placement differs; footnote↔endnote conversion can create two note sets. LO 24.8 improved continuous endnotes for DOCX/RTF.

### 3.10 Equations
- **Portable**: OMML, wrapped in `m:oMathPara` for display; **each `m:r` should carry the Cambria Math font hint** (community-tested; Word/WPS may render bare OMML as plain text otherwise) **[community, not Microsoft-documented]**.
- **Risk**: LO converts OMML to its Math object and back — lossy; older Math Guide states OMML import failed; current fidelity is version-dependent; matrix/`eqArr` constructs degrade. Keep math simple; provide fallbacks for critical content.

### 3.11 Fields generally
- **Portable**: always emit a cached result; set `w:updateFields=true` and `dirty=true`; **design as if no app updates on open**.
- **Risk**: LO updates fields manually (F9) and has **no primary statement that it honours `w:updateFields` on open [uncertain]**; Word's behaviour may depend on a global setting (MS Q&A #491304); WPS has manual update commands **[uncertain]**.

### 3.12 CJK / Chinese typography
- **Portable**: set **all four** font slots (`ascii`/`hAnsi`/`eastAsia`/`cs`); declare the East Asian font in `docDefaults`; prefer twips `w:firstLine` over `firstLineChars` when exact indent matters; enable matching `w:compat` flags (`balanceSingleByteDoubleByteWidth`).
- **Risk**: Word applies a CJK font line-height multiplier that reflows vs LO; grid-vs-table interactions (LO 25.2.4); punctuation/kinsoku differences. WPS is CJK-native and likely strongest **[uncertain]**. OfficeCLI's default template already sets `compatibility.balanceSingleByteDoubleByteWidth=true` and `docGrid.type=default` (verified via `get /`).

### 3.13 General portability
- **Portable**: emit Transitional, set `compatibilityMode=15`, keep `w:compat` minimal and explicit, avoid VML.
- **Risk**: Strict rejected by python-docx and others; over-full `w:compat` emulates legacy Word; "opens but looks wrong" LO issues (borders invisible in Word after save, content controls corrupting files, charts in footnotes).

---

## 4. External projects worth borrowing (design ideas)

Each idea names its source. Facts are cited; the framing is interpretation.

1. **Style contract via a reference document.** Keep layout in a portable template; content only references style *names*. (Pandoc `--reference-doc` — https://raw.githubusercontent.com/jgm/pandoc/main/MANUAL.txt ; Quarto — https://quarto.org/docs/output-formats/ms-word-templates.html)
2. **Style existence is a precondition, verified.** python-docx: applying an undefined style is a **silent no-op** — Word just ignores it. Define styles, then read `styles.xml` back. (https://python-docx.readthedocs.io/en/latest/user/styles-understanding.html)
3. **Separate construction ≠ schema validation ≠ visual render.** Run all three. (Open XML SDK `OpenXmlValidator` — https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.validation.openxmlvalidator ; OfficeCLI `validate` + `view issues` + screenshot)
4. **Help/CLI schema is authoritative; the skill teaches decisions.** Pin guidance to the installed version. (OfficeCLI Help-First Rule)
5. **Layered precision, prefer the highest layer.** L1 semantic props → L2 attribute fallback → L3 raw XML, raw XML only with a recorded reason. (OfficeCLI L1/L2/L3)
6. **Executable delivery gates, not prose checklists.** A copy-paste gate that must print OK. (OfficeCLI docx + word-form Delivery Gates)
7. **Render-and-look verification.** Convert to images/HTML and inspect actual pages. (Anthropic docx skill `soffice`→`pdftoppm`→Read — https://github.com/anthropics/skills/blob/main/skills/docx/SKILL.md ; OfficeCLI `view html` / `screenshot --grid`)
8. **Normalise before string edits.** Word fragments text across runs; coalesce runs first, never reformat/pretty-print XML. (Anthropic `merge_runs.py`)
9. **Classify each construct portable / engine-specific / degrade-to-text.** Zotero achieves portable citations via a field with a stable payload anchored to a bookmark/content control, but Word *Fields* and LO *Bookmarks* are not cross-compatible. (https://www.zotero.org/support/kb/word_field_codes ; https://library.caltech.edu/citation-management/zotero-cite-write)
10. **Known-issue taxonomy: agent-error vs renderer-bug vs skill-gap.** Attribute before chasing. (OfficeCLI)
11. **A stable, catalogued QA vocabulary with IDs, reporting all findings at once.** (docxtemplater error catalog — https://docxtemplater.com/docs/errors/ ; OfficeCLI `view issues --type`)
12. **Scene layer vs independent skill, chosen deliberately, with explicit reverse handoff.** (OfficeCLI academic-paper vs word-form)
13. **Fields are live values with caches; judge by structure.** A generator cannot compute page numbers — emit the field + recalc instruction. (Pandoc issue #458 — https://github.com/jgm/pandoc/issues/458)
14. **Stable-ID addressing survives edits; positional indices do not.** (`paraId`, `@id=`; re-index after structural inserts. OfficeCLI stable-ID addressing)
15. **Style maps decouple meaning from rendering and are testable text.** (Mammoth — https://github.com/mwilliamson/mammoth.js)
16. **A QA signal for unrecognised styles** rather than silent pass-through. (Mammoth's unmapped-style `messages`)

---

## 5. Compatibility risks (ranked)

1. **TOC on open** — no cached entries → LO "Error! No table of contents entries found"; fields may stay empty. Mandate cached TOC entries + correct heading styles/outline levels.
2. **Field recalculation is not guaranteed** — no app is contractually required to honour `updateFields`; LO updates manually. Pre-cache every field.
3. **Floating objects (images/tables)** — wrap modes and anchors diverge; nested/floating tables escape in LO. Prefer inline images and fixed non-floating tables.
4. **Style identity** — localized names / `styleId`-vs-`name` mismatch silently breaks headings/TOC/captions. Emit canonical `styleId` + `name` + outline levels, and define styles explicitly.
5. **OMML equations** — lossy through LO's formula model; may need the Cambria Math run hint in Word/WPS; complex constructs degrade.
6. **Table borders/merges/repeat headers** — style referenced but absent applies nothing; nested/floating tables and `tblHeader` are regressions.
7. **Section breaks, especially `continuous`** — long-standing LO spacing/margin issues; prefer `nextPage`.
8. **Headers/footers first/even** — LO visibility regressions and page-style remapping; declare all variants.
9. **CJK line metrics / `docGrid`** — Word's CJK line-height multiplier and grid-vs-table interactions cause reflow.
10. **Captions/SEQ auto-numbering** — no evidence LO/WPS auto-renumber Word `SEQ` identically; treat as cached static numbers + bookmark cross-refs.
11. **Strict vs Transitional** — always Transitional.
12. **Legacy image formats** — EMF/WMF/TIFF/SVG fail in some consumers; rasterise or provide fallbacks.
13. **OfficeCLI-specific (verified)** — a non-auto-defined style reference remains dangling (`Caption`); `differentFirstPage` is unsupported as a prop; `shd.fill` on a paragraph emits schema-invalid XML (word-form K14); header/footer and watermark quirks (K16/K17).
14. **Cross-app field engines differ for citations** — Word Fields vs LO Bookmarks are not cross-compatible (Zotero), and no first-party source on WPS citation behaviour was found **[uncertain]**.

---

## 6. Open questions (not decided)

1. **Scope of layout knowledge**: which document archetypes does WordFlow own (report/letter/thesis/contract/report-with-figures)? The vendor `academic-paper` scene layer already covers citations/equations/multi-column; does WordFlow compete, complement, or defer?
2. **Compatibility target**: is "opens correctly in Word + WPS + LibreOffice" the hard gate? Which versions? Is WPS at all testable here (no public format docs)?
3. **Field strategy**: pre-cache everything at generation time (requires pagination), or ship dirty fields + `updateFields=true` and require the user to recalc? Local evidence shows OfficeCLI's `refresh` HTML backend can fill page numbers on Linux — is that trustworthy enough to rely on, or only a convenience?
4. **Caption/SEQ strategy**: always define `Caption` + `SEQ` explicitly and run `recalcFields=seq`, or treat numbering as static text? How to guarantee `Caption` exists given OfficeCLI does not auto-define it?
5. **Citation/bibliography**: in scope at all? If yes, which model — portable fields/bookmarks (Zotero-style), static `CSL`-rendered text, or defer to OfficeCLI's academic-paper skill?
6. **Equation fidelity**: accept OMML only, add Cambria Math hints, and/or provide image fallbacks? What is the acceptable degradation for LO/WPS?
7. **CJK policy**: is Chinese typography a first-class requirement (fonts, first-line-by-chars, docGrid)? This is unstated but likely central to the audience.
8. **Template/reference-doc strategy**: start from a blank doc, a WordFlow-owned reference `.docx` (Pandoc-style style contract), or a user template?
9. **Style system ownership**: does WordFlow define a canonical style set, or adapt to each document's existing styles?
10. **A valid baseline document**: what exact style/font/section defaults should every WordFlow output carry (fonts, sizes, compat flags)?
11. **Packaging/discovery**: where `SKILL.md` installs; whether to build on OfficeCLI's `word`/`academic-paper` skills or replace them.
12. **Verification harness**: which checks are mandatory (validate, `view issues`, field-structure, render-and-look) and which renderer is the source of truth for page layout on Linux.

---

## 7. Suggested DOCX test fixtures (to build later)

Grouped by concern; each fixture should be inspectable via OfficeCLI and ideally opened/compared in Word, WPS, and LibreOffice.

**Styles**
- `styles/heading-hierarchy.docx` — Title/H1/H2/H3 with explicit sizes.
- `styles/style-inheritance.docx` — `basedOn`/`next` chain.
- `styles/theme-vs-explicit-font.docx` — theme fonts vs explicit `ascii`/`hAnsi`/`eastAsia`.
- `styles/caption-defined.docx` and `styles/caption-dangling.docx` — the difference OfficeCLI produced (defined vs referenced-only).
- `styles/table-style-vs-direct-borders.docx`.

**Sections / margins / pagination**
- `sections/margins-orientation.docx` — A4 portrait → landscape section.
- `sections/continuous-vs-nextpage.docx`.
- `sections/multicolumn-and-revert.docx` — 2-col body then revert to 1-col.
- `sections/page-number-restart.docx` — `pageNumFmt` + `pageStart` per section.

**Headers / footers / page numbers**
- `headers/default-first-even.docx` — `titlePg` + `evenAndOddHeaders`.
- `headers/page-x-of-y.docx` — composite PAGE + NUMPAGES.
- `headers/footer-distance.docx` — `marginHeader`/`marginFooter`.

**Pictures**
- `images/inline.docx`, `images/anchored-square.docx`, `images/anchored-topAndBottom.docx`, `images/behind-text.docx`.
- `images/svg-with-png-fallback.docx`.
- `images/alt-and-decorative.docx`, `images/crop.docx`.

**Tables**
- `tables/fixed-width-merge.docx` — `gridSpan` + `vMerge`.
- `tables/repeat-header-row.docx`.
- `tables/direct-borders.docx` vs `tables/table-style.docx`.
- `tables/nested.docx` (negative/compat probe).

**Captions / SEQ / cross-refs**
- `captions/figure-caption-below.docx` — Caption style + `SEQ Figure` + bookmark + `PAGEREF`.
- `captions/table-caption-above.docx` — `SEQ Table` above the table.
- `captions/multi-figure-recalc.docx` — verify distinct cached numbers after `recalcFields=seq`.

**Bookmarks / REF / PAGEREF**
- `fields/ref-and-pageref-cached.docx` — with and without cached results.

**TOC**
- `toc/three-headings-updatefields.docx`.
- `toc/no-headings-error-case.docx` (negative).

**Footnotes / endnotes**
- `notes/footnote-basic.docx`, `notes/endnote-basic.docx`, `notes/numbering-restart.docx`.

**Equations**
- `equations/inline-omml.docx`, `equations/display-omml.docx`, `equations/greek-fraction.docx`, `equations/cambria-math-hint.docx`, `equations/in-table-cell.docx`.

**Fields**
- `fields/page-numpages-date.docx`, `fields/field-cache-presence.docx`.

**CJK**
- `cjk/eastAsia-fonts.docx`, `cjk/firstline-chars-vs-twips.docx`, `cjk/docgrid.docx`, `cjk/punctuation-compression.docx`.

**Portability / round-trip**
- `roundtrip/dump-batch-replay.docx` (OfficeCLI `dump`→`batch`).
- `portability/transitional-baseline.docx`; `portability/strict-ooxml.docx` (expected-reject).
- `portability/open-in-three-apps.docx` — a single "kitchen-sink but portable" document for manual Word/WPS/LibreOffice comparison.

**QA/negative**
- `qa/dangling-style.docx`, `qa/placeholder-token-leak.docx`, `qa/missing-alt-text.docx`, `qa/empty-paragraph-spacing.docx`.

---

## Appendix — key source URLs

**OfficeCLI**: skills https://github.com/iOfficeAI/OfficeCLI/tree/main/skills ; base https://github.com/iOfficeAI/OfficeCLI/blob/main/SKILL.md ; wiki workflows/agent-guide ; local `officecli help docx *`.
**Standards**: ooxml.org (`w:sectPr`, `w:tblPr`, `w:name`, `w:docGrid`, `w:evenAndOddHeaders`, `w:pgNumType`); Microsoft Learn (Open XML SDK, `UpdateFieldsOnOpen`, `PageNumberType`, `DocGrid`, MS-OI29500, MS-OE376).
**Compatibility**: LibreOffice release notes/help (24.8, 25.2, 26.2, Math Guide), Microsoft Q&A #491304, Docxodus #412, docxjs #193, docling #3959, python-docx #693/#476, docx4java `tblStyle`.
**External design**: pandoc MANUAL, python-docx docs, mammoth.js, docxtemplater, Quarto, Zotero field-codes KB, Anthropic `skills/docx`.
