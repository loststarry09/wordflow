# Fixtures

Small, single-purpose DOCX samples used to exercise WordFlow's guidance and to verify OfficeCLI behaviour. They were generated with `tests/generate-fixtures.sh` and checked with `tests/validate-fixtures.sh` against **OfficeCLI 1.0.152**.

- **Regenerate**: `tests/generate-fixtures.sh`
- **Verify**: `tests/validate-fixtures.sh` (writes renders to `tests/.out/`, which is git-ignored)
- **Assets**: `assets/test-image.png` (a 96x64 red rectangle with a black border), embedded in the generator as base64 so regeneration needs no image library.
- **Locales**: every fixture pins `--locale en-US` or `--locale zh-CN` so output does not depend on the host locale.

Fixtures are committed as snapshots. OfficeCLI stamps `created`/`modified` timestamps, so a regenerated file is not byte-identical to the committed one; regenerate deliberately (e.g. after an OfficeCLI upgrade).

## What each fixture tests

### styles/

| Fixture | Tests | Expected construction |
|---|---|---|
| `heading-hierarchy.docx` | Heading styles and outline levels; OfficeCLI auto-defines built-in heading styles | `Title`, `Heading1`, `Heading2`, `Heading3` paragraphs with body text; `viewport outline` shows the tree |
| `caption-defined.docx` | A `Caption` style defined **before** use | `/styles/Caption` added explicitly, then referenced by a paragraph |
| `caption-dangling.docx` | A `Caption` style referenced but **never defined** | Paragraph `style=Caption` with no `/styles/Caption`; reproduces OfficeCLI's `style 'Caption' not found … referenced as-is` warning |
| `unstyled.docx` | A document with **no named styles** (the rebuild case) | Three default `Normal` paragraphs, no headings or named styles |
| `template.docx` | A distinct style set used as a **template** (the template-wins case) | `WFBody` and `WFQuote` styles defined and referenced; used as `--template` in the ownership tests |
| `standard-style-set.docx` | The frozen WordFlow **standard style set** (spec D7) with the D6 Simplified-Chinese typography; every style defined and used, no dangling reference | 18 styles defined by `scripts/wf-standard-styles.sh` (body SimSun/Times New Roman, headings SimHei/Arial, `hint=eastAsia`, body 12 pt 1.5× 2-char indent justified); paragraphs exercise `Normal`, `BodyNoIndent`, `Title`, `Heading1`–`Heading4`, `Caption`, `Quote`, `ListParagraph`, `TOC1`–`TOC3`, plus a footnote (`FootnoteText`/`FootnoteReference`), a hyperlink (`Hyperlink`), and a header/footer (`Header`/`Footer`) |

### sections/

| Fixture | Tests | Expected construction |
|---|---|---|
| `margins-orientation.docx` | Two sections, differing orientation and margins | `nextPage` section break; `/section[1]` portrait A4 + 2.54/3.18 cm margins, `/section[2]` landscape A4 + 1 cm margins |
| `page-number-restart.docx` | Page numbering format and restart per section | `/section[2]` with `pageNumFmt=lowerRoman`, `pageStart=1` |
| `page-setup-default.docx` | WordFlow default page setup carried across a section break | Two sections, both A4 portrait with margins 2.54 cm top/bottom and 3.17 cm left/right (spec D6); `/section[1]` carries the `nextPage` break |

### headers/

| Fixture | Tests | Expected construction |
|---|---|---|
| `page-number-footer.docx` | A live `PAGE` field in the footer | `/footer[1]` with `field=page`, centred; the footer part holds a begin/instrText/separate/result/end field chain |
| `firstpage-oddeven.docx` | A different first-page header/footer **and** odd/even headers/footers in one section | `/section[1]` `titlePage=true`; header/footer parts of `type=first`, `type=default` (odd) and `type=even`, each with distinct text; `settings.xml` carries `<w:evenAndOddHeaders/>`; four `pageBreakBefore` pages exercise first/even/odd/even |

### multipage/

| Fixture | Tests | Expected construction |
|---|---|---|
| `page-fields.docx` | Per-page page-number behaviour on a **multi-page** document without a manual F9: footer `PAGE` + `NUMPAGES`, a body `PAGEREF`, and a `TOC` with page numbers (issue #3) | Three explicit `pagebreak`s force exactly 4 pages (title + three breaks + page-4 content). Footer is `"Page " + PAGE + " of " + NUMPAGES`; page 4 has `PAGEREF target` to a bookmark on page 3; a `TOC \o "1-2"` lists the four headings; `refresh` run. Cached values are `PAGE=1`, `NUMPAGES=1`, `PAGEREF=1` (`refresh`'s HTML pagination), yet Word, WPS, and LibreOffice each render `Page 1 of 4` … `Page 4 of 4` and `on page 3` per page. See `references/research/multipage-page-fields.md`. |

### images/

| Fixture | Tests | Expected construction |
|---|---|---|
| `inline-image.docx` | Inline (in-flow) image with alt text | Picture in a run of `/body/p[1]`, `wrap=inline`, `width=3cm`, `alt` set |
| `anchored-image.docx` | Floating image with top-and-bottom wrapping | `anchor=true`, `wrap=topAndBottom`, `hRelative=column`, `vRelative=paragraph` |

### tables/

| Fixture | Tests | Expected construction |
|---|---|---|
| `fixed-table.docx` | Fixed layout, explicit widths, direct borders, repeating header row | 4x3 table, `layout=fixed`, `colWidths=1701,1701,1700` (Σ = 5102 = `width=9cm`), `border.all="single;8;000000"`, `tr[1]/header=true` |
| `nested-table.docx` | A table nested inside a table cell, measured for cross-application portability (#4) | 2x3 outer fixed table (`colWidths=3402,3402`, `width=12cm`, black direct borders); a 2x2 inner fixed table at `/body/tbl[1]/tr[2]/tc[1]/tbl[1]` (`colWidths=1418,1417`, `width=5cm`, red `C00000` direct borders) |
| `merged-table.docx` | A merged-cell table: a horizontal span (`colspan`) and a vertical merge (`vmerge` restart/continue) (#21) | 4x3 fixed table (`colWidths=1701,1701,1700`, `width=9cm`, black direct borders); `/body/tbl[1]/tr[1]/tc[1]` `colspan=2` (w:gridSpan), `/body/tbl[1]/tr[2]/tc[1]` `vmerge=restart`, `/body/tbl[1]/tr[3]/tc[1]` `vmerge=continue` (w:vMerge); the continuation cell is empty in the data. See `references/objects/tables.md` |

### captions/

| Fixture | Tests | Expected construction |
|---|---|---|
| `caption-seq.docx` | A caption composed from a defined `Caption` style plus a `SEQ` field | `Caption` paragraph `"Figure "` + `SEQ Figure` field + `": …"` run; `recalcFields=seq` writes the cached number |

### fields/

| Fixture | Tests | Expected construction |
|---|---|---|
| `bookmark-ref-pageref.docx` | Bookmark, `REF` and `PAGEREF` cross-references | Bookmark `target`; paragraph `"Reference: "` + `REF target \h` + `" on page "` + `PAGEREF target \h`; `refresh` run |
| `cached-cross-ref.docx` | Content cross-references whose **cached result is the resolved target text**, never the `«target»` placeholder (#12) | Heading bookmark `sec_intro` around `Introduction` and a caption's label bookmark `fig_demo` around plain-text `Figure 1`; paragraph `"See section "` + `REF sec_intro` + `" and "` + `REF fig_demo` + `" for details."`. Each `REF` result run is then written with the resolved text (`set`) and the `w:dirty` marker cleared (`raw-set`). Opens repair-free in Word/WPS/LibreOffice, all showing `See section Introduction and Figure 1 for details.` See `references/fields/cross-references.md`. |

### toc/

| Fixture | Tests | Expected construction |
|---|---|---|
| `toc-basic.docx` | A table of contents with hyperlinks and page numbers | TOC field (`TOC \o "1-3" \h \u`) after a `Title`, then `Heading1`/`Heading2` content; `refresh` run |
| `toc-no-page-numbers.docx` | A table of contents whose **cached** result lists the heading entries with **no page numbers**, while remaining a real, updatable field (issue #11, spec D9) | `TOC1`–`TOC3` defined up front; TOC field `pageNumbers=false` (`TOC \o "1-3" \h \z \u`) after a `Title`; three headings forced onto pages 1/2/3 with explicit `pagebreak`s; `refresh` caches one `TOC1`/`TOC2` hyperlink paragraph per heading, **no** tab/PAGEREF. Word/WPS/LibreOffice display the entries with no page numbers on open (repair-free); a manual F9 rebuilds the field and adds the correct numbers `1,2,3`. See `references/fields/table-of-contents.md`. |

### notes/

| Fixture | Tests | Expected construction |
|---|---|---|
| `footnote-basic.docx` | A footnote anchored to a paragraph | Paragraph + `footnote` child; `/footnotes/footnote[1]` |

### equations/

| Fixture | Tests | Expected construction |
|---|---|---|
| `inline-equation.docx` | Inline OMML equation inside a paragraph | `/body/p[2]/oMath[1]`, `mode=inline`, `E = mc^2` |
| `display-equation.docx` | Display OMML equation in its own paragraph | `/body/oMathPara[1]`, `mode=display`, `\frac{a}{b} = c` (becomes `m:f` numerator/denominator) |
| `matrix-equation.docx` | A 3×3 matrix with bracket delimiters (#6) | `mode=display`, `\begin{bmatrix} … \end{bmatrix}`; becomes `m:d` (bracket) wrapping `m:m` with `m:mr`/`m:e` rows and cells |
| `aligned-equations.docx` | Multi-line aligned equations in one display equation (#6) | `mode=display`, `\begin{aligned} x &= … \\ y &= … \end{aligned}`; the parser emits `m:m` with a 2-column `m:mcs` (right/left justification), **not** `m:eqArr` |
| `cases-equation.docx` | A piecewise `cases` construct (#6) | `mode=display`, `\begin{cases} … \end{cases}`; becomes `m:d` with `m:begChr={`, empty `m:endChr`, wrapping a 2-column `m:m` |
| `equation-array.docx` | A true multi-line equation array `m:eqArr` (#6) | `raw-set` replaces the parsed `m:oMath` with an `m:eqArr` fragment (two `m:e` lines) — the FormulaParser cannot emit `m:eqArr` |

### cjk/

| Fixture | Tests | Expected construction |
|---|---|---|
| `cjk-fonts-indent.docx` | East-Asian fonts plus character-unit first-line indent | Two Chinese paragraphs with `font.ea` set (`SimSun`, then `Microsoft YaHei`); `/body/p[2]` `firstLineChars=200` |
| `cjk-punctuation-kinsoku.docx` | Chinese punctuation, kinsoku (禁则) line-breaking, and punctuation compression (标点压缩) across Word/WPS/LibreOffice (#7) | A4, margins 2.54/3.17 cm, body metrics (SimSun + Times New Roman, `hint=eastAsia`, 12 pt); `rightIndent=1112` leaves exactly 30 full-width characters per line, so a forbidden (行首/行尾) punctuation placed after 30 ideographs would start the next line unless kinsoku applies. Paragraphs: closing `，` at a would-be line start; opening `“` at a would-be line end; `（`/`）` bracket pair; a punctuation-dense block (`。”` `……` `——` `【】` `？！` `《》`); mixed CJK/Latin/digit with a long Latin token; and a no-punctuation control |

### portability/

| Fixture | Tests | Expected construction |
|---|---|---|
| `transitional-baseline.docx` | A document is emitted as **Transitional** OOXML, not Strict | Heading + body; `/document` uses the `schemas.openxmlformats.org/wordprocessingml/2006/main` namespace and contains no `purl.oclc.org/ooxml` reference |

## Advisory issues and how to read them

`officecli view <file> issues` reports style heuristics, not schema errors. Every fixture here passes `officecli validate`; all issues observed are the following two, and they are advisory:

- **`[F] Body paragraph missing first-line indent`** — raised for `Normal` body paragraphs without a 2-character first-line indent. It is an opinionated typography suggestion (Chinese/Japanese style), not an error. It is *suppressed* by `firstLineChars=200` (see `cjk/`). It is **not** suppressed by a *style-level* `firstLineChars` (the heuristic reads the paragraph's direct indent only), so `styles/standard-style-set.docx` shows one such advisory per `Normal` paragraph even though the `Normal` style indents them; the rendered result is indented (verified in `tests/standard-styles.sh`).
- **`[S] Empty paragraph`** — raised for the blank paragraph that carries a section break (see `sections/`). Expected for the section model.
- **`[F] Body paragraph missing first-line indent`** and **`[C] Duplicate punctuation`** in `cjk/cjk-punctuation-kinsoku.docx` — both expected. That fixture sets `firstLineIndent=0` deliberately so the wrap boundary is exactly 30 full-width characters per line (the whole point of the fixture), and its punctuation-dense paragraph repeats a sentence to force line-end decisions, which the duplicate-punctuation heuristic flags. Both are advisory; `officecli validate` passes.

No `field_not_evaluated` issues were raised: every generated field carries a cached result. See `references/research/officecli-behavior.md` for the cross-reference caveat.

## Known OfficeCLI limitations these fixtures expose

- A referenced but undefined style (e.g. `Caption`) stays dangling; only a small set of built-ins (`Title`, `Heading1`–`Heading9`, …) are auto-defined. See `styles/caption-dangling.docx`.
- `REF` cached text stays the placeholder `«target»` after `refresh` (the HTML backend resolves `PAGEREF` but not `REF`). See `fields/bookmark-ref-pageref.docx` and the research note. **Workaround (#12):** write the resolved text into the `REF` result run and clear the `w:dirty` marker with `raw-set`; see `fields/cached-cross-ref.docx` and `references/fields/cross-references.md`. A bookmark that spans a nested field result (e.g. an auto-numbered `SEQ` caption label) resolves differently in LibreOffice than in Word/WPS, so bookmark plain text.
- A resident process leaks edits into the next file if it is not closed first; the generator and validator `close` each file after use.
