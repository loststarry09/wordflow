# WordFlow — Requirements Clarification Report

- **Date**: 2026-09-28
- **Method**: `grill-with-docs` requirements interview (decision-tree rounds; each frontier question answered before the next round)
- **Outcome**: v0.1 product requirements and boundaries defined; glossary in `CONTEXT.md`; ADRs `0001`–`0004`
- **Status**: requirements only — no implementation, no `SKILL.md` change, no OfficeCLI integration change

## 1. Confirmed requirements

### Positioning

- WordFlow is the judgement/knowledge layer; **OfficeCLI is the single execution layer** (ADR-0001). WordFlow is not an engine, parser, or renderer.
- Scope is `.docx` only. Not a format converter (no PDF/Markdown), and it must not require Word or Windows.
- Audience: non-experts who want a correct, portable, maintainable document without being Word experts.

### The two jobs (equal priority)

- **From content**: the user supplies content and WordFlow produces a laid-out document.
- **From an existing document**: the user supplies a `.docx` and WordFlow tidies its layout.
- WordFlow changes **presentation only**. Restructuring requires the user's explicit request and per-item confirmation. It never authors or edits words, images, tables, or equations (ADR-0002).

### Input and output

- Input: content (text/Markdown, optionally images and table data) plus an optional **template** and/or **formatting requirement**; or an existing `.docx` to tidy.
- Precedence when the look is specified more than once: **formatting requirement > template > WordFlow defaults**.
- Output: a **new** `.docx`, default name `"<source name>-排版.docx"` (numbered on collision), user may specify the path. The source file is never modified; v0.1 has no in-place editing (ADR-0003).
- Every output carries a **change report**: what changed, which formatting decisions were made on the user's behalf, and any warnings or unverified items.
- A render preview (screenshot/HTML) is produced by default and can be turned off.

### Defaults when the user specifies nothing

- Produce directly and list the formatting decisions transparently; ask only for the minimal information whose absence would cause rework (language, document type).
- **Simplified Chinese is a first-class default**: Chinese body font, 2-character first-line indent, suitable line spacing, and mixed Chinese/Latin handling.
- For an existing document: preserve and tidy its existing style set by default; rebuild with **standard styles** only when the document has no usable styles; a supplied template outranks the document's own styles.

### Autonomy and risk

- **Downgrades are never silent** — every fallback is reported in the change report.
- **Warn then continue**: the result may render differently in another application (floating images, complex equations, merged/nested tables, columns, WPS-related conclusions).
- **Stop and ask**: to change content; to restructure without confirmation; when the source cannot be read or fails validation; when a requested construction would sacrifice portability with no safe alternative.

### Definition of done

- Automatic completion gate: the document opens without a repair prompt **and** WordFlow's own checklist is green (every referenced style is defined, automatic content is populated, no unevaluated items).
- Structural changes additionally require the user's per-item confirmation before the job is called done.

### Compatibility

- Hard gate: all three of Microsoft Word, WPS Writer, and LibreOffice Writer open the document without a repair prompt (ADR-0004).
- No pixel-identical promise; only the portable subset is promised.
- Target versions: Word 2016+, current WPS Writer, LibreOffice 7.6+.
- WPS findings are labelled best-effort/unverified; verification available to the project is OfficeCLI validation plus Linux rendering.

### Form

- Delivered as a **Skill installed to a coding agent** (opencode / Claude / Codex); `SKILL.md` is the entry point.
- No standalone CLI (consistent with ADR-0001).
- Does not replace OfficeCLI's official skills; it is a layout-judgement layer that references them.

## 2. v0.1 scope

**Task types**: generate from content; tidy an existing document.

**Inputs**: content (text/Markdown, images, table data); existing `.docx`; optional template; optional written formatting requirements.

**Fully supported (produced and verified)**:

- heading hierarchy and a full style set
- page size, orientation, margins
- headers/footers and page numbers
- table of contents
- inline images
- regular tables
- captions
- cross-references
- footnotes
- basic equations (simple inline/display)

**Supported with warning or automatic downgrade (always reported)**:

- floating images (text wrapping)
- merged-cell and nested tables
- multi-column layout
- different first-page / odd-even headers and footers
- page-number restart
- complex equations

**Cross-cutting**: template and formatting-requirement ingestion with the stated precedence; Simplified-Chinese-first defaults; change report on every output; optional render preview.

## 3. Explicitly out of scope for v0.1

- Editing or writing any content (text, images, tables, equations) — ADR-0002.
- Topic-to-article authoring.
- Charts, comments, tracked changes, forms/content controls, watermarks, references & citation styles, mail merge, text boxes / WordArt / OLE objects.
- Non-DOCX format conversion (PDF, Markdown, …).
- In-place modification of the source document — ADR-0003.
- A standalone CLI.
- Built-in document-archetype presets (official letter / thesis / report) — deferred.
- Any dependency on Microsoft Word or Windows.

## 4. Unresolved

- **Template adoption boundary**: exactly what a supplied template contributes (theme fonts, style definitions, page setup) versus what it must not (its content, and arguably concrete header/footer text). Not yet decided; needs design.
- **Exact version matrix**: which specific Word releases (2016/2019/365), which WPS version, and LibreOffice 7.6 versus 24.8+.
- **Default layout values**: the concrete body font, size, line spacing, and heading sizes for the Chinese-first default.
- **Standard style set contents**: the concrete list of WordFlow's standard styles.
- **Output filename safety**: whether a Chinese default name `-排版` is safe in every environment, and whether the default should localise.
- **Distribution**: install location and how each agent discovers the skill.
- **Verification reality**: whether a human-verifiable Word/WPS/LibreOffice environment is available; this determines how strongly "compatibility" can be checked.
- **Large-document limits** and behaviour offline or with missing fonts.

## 5. Research still needed before spec

- **Field cache and recalculation on open**: measure across Word / WPS / LibreOffice whether tables of contents, page numbers, and cross-references refresh on their own, and which fields must carry a pre-computed cached result to be safe. Some local evidence exists (OfficeCLI's HTML `refresh` fills page numbers and `PAGEREF` but not `REF`); LibreOffice and WPS behaviour is unmeasured.
- **Chinese font availability and substitution** across platforms (DengXian/SimSun/SimHei on Linux, WPS, LibreOffice), plus mixed Chinese/Latin first-line indent and punctuation-compression behaviour.
- **Downgrade boundaries** for floating objects and merged/nested tables in LibreOffice, to turn "supported with warning" into concrete rules and fallback targets.
- **Equation fidelity**: OMML behaviour in LibreOffice and WPS, and the downgrade target (keep OMML vs image vs text).
- **Header/footer (first/even) and page-number restart** behaviour across the three applications.
- **Testability of each application** (LibreOffice headless; whether WPS can be scripted) to decide how strict the compatibility gate can be in practice.

### Status after follow-up research (2026-09-28)

Full detail in `references/research/field-recalc-and-cross-app-verification.md`; documentary findings in `references/research/docx-feature-portability.md`.

- **Field cache and recalculation on open — RESOLVED for Word and WPS (LibreOffice open).** Word 16 and WPS 12, driven by COM, **do not recalculate fields on open**, not even with `updateFields=true`; they display the cached result verbatim, and both resolve fields correctly on a manual update (F9). OfficeCLI always writes a cache and its TOC/REF caches are placeholders; OfficeCLI's `refresh` page numbers come from an HTML pagination model and are **wrong** for Word/WPS (2 where both compute 1).
- **Consequence for the "definition of done".** Page numbers cannot be guaranteed without a real layout engine. The spec must choose: a TOC without page numbers; best-effort page numbers plus a "update fields (F9)" warning; or an application finalisation pass. Placeholders (REF, TOC) must never ship silently.
- **Chinese font availability — measured.** Windows has the CJK fonts; on Linux LibreOffice substitutes silently — it rendered `SimSun` for real but replaced `Microsoft YaHei` with `WenQuanYi Zen Hei`, and maps `等线`/`DengXian` to `DejaVu Sans` (no CJK glyphs). OfficeCLI's `zh-CN` default (`等线`) is therefore unsafe. The concrete default font choice remains a spec decision.
- **Downgrade boundaries, equation fidelity, header/footer behaviour — measured in LibreOffice 24.2.** Simple OMML equations render faithfully; **merged-cell tables render faithfully**; a centred `PAGE` footer and a section-2 page-number restart (`lowerRoman`) render correctly; but **a floating (anchored) image is not faithful** (rendered left-aligned, not centred/floating). Still untested: nested tables, different-first-page and odd/even headers, complex equations, CJK punctuation compression.
- **Testability — RESOLVED.** Word and WPS are COM-drivable from WSL (`Word.Application`, `KWPS.Application`); LibreOffice `24.2.7.2` is installed in WSL and drivable headless. All three applications are now inspectable from this environment.
