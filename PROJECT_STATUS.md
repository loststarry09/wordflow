# WordFlow — Project Status

**Authoritative entry point — read this first.** It states what WordFlow is, what is
decided, what is verified, where the work stands, and what is next. It summarises and
links; the ADRs hold the full arguments and `references/research/` holds the evidence.

- **Last updated:** 2026-09-28
- **Verified tooling:** OfficeCLI `1.0.152`; Word `16.0`; WPS Writer `12.0`; LibreOffice `24.2.7.2`
- **Phase:** requirements frozen, compatibility research done, **no layout rules or implementation written yet**

## Reading order

1. **`PROJECT_STATUS.md`** — this file.
2. **`CONTEXT.md`** — the ubiquitous language (roles, layout/content, risk vocabulary).
3. **`SKILL.md`** — the agent-facing entry point that ships with the skill.
4. **Only the ADR or `references/` file the task touches.**

Do **not** read the reports by default. `report/` is a dated audit trail — open a report
only to trace how a decision or fact was reached.

---

## 1. What WordFlow is

- A Word layout **Skill for Agents**: a judgement/knowledge layer, not an engine, parser,
  or renderer.
- **OfficeCLI is the single execution layer** for every DOCX read and write (ADR-0001);
  WordFlow supplies the *which construct, and why* that OfficeCLI deliberately leaves out.
- Scope is `.docx` only. It is not a format converter (no PDF/Markdown) and must **not**
  require Microsoft Word or Windows.
- Audience: non-experts who want a correct, portable, maintainable document.

## 2. Architecture & responsibility boundaries

| Boundary | Rule | Source |
|---|---|---|
| Execution | Every DOCX read/write goes through OfficeCLI; WordFlow has no parser/renderer/writer. | ADR-0001 |
| Content | WordFlow owns **layout only**. It never authors or edits words, images, tables, or equations. Restructuring only on explicit request + per-item confirmation. | ADR-0002 |
| Output | Always a **new** file; the source is never modified. No in-place editing in v0.1. | ADR-0003 |
| Compatibility | "Opens without repair" in Word + WPS + LibreOffice, rendering faithfully from a shared portable subset — **not** pixel-identical. | ADR-0004 |

**Frozen decisions** — see the ADRs for the full reasoning (do not restate them elsewhere):

- [`docs/adr/0001-officecli-is-the-single-execution-layer.md`](./docs/adr/0001-officecli-is-the-single-execution-layer.md)
- [`docs/adr/0002-layout-only-never-edit-content.md`](./docs/adr/0002-layout-only-never-edit-content.md)
- [`docs/adr/0003-output-is-a-new-file.md`](./docs/adr/0003-output-is-a-new-file.md)
- [`docs/adr/0004-compatibility-means-opens-without-repair.md`](./docs/adr/0004-compatibility-means-opens-without-repair.md)

## 3. v0.1 confirmed requirements

Full wording in [`report/2026-09-28-requirements-grilling.md`](./report/2026-09-28-requirements-grilling.md).

- **Two jobs, equal priority**: generate from content; tidy an existing `.docx`.
- **Input**: content (text/Markdown, optionally images/table data) plus an optional
  **template** and/or written **formatting requirement**; or an existing `.docx`.
- **Precedence**: formatting requirement > template > WordFlow defaults.
- **Output**: new `.docx`, default name `"<source name>-排版.docx"` (numbered on
  collision, path specifiable), with a **change report** (what changed, decisions made on
  the user's behalf, warnings). Render preview on by default, switchable off.
- **Defaults when unspecified**: produce directly and list decisions transparently; ask
  only the minimal question (language, document type). **Simplified Chinese is a
  first-class default** (Chinese body font, 2-character first-line indent, suitable line
  spacing, mixed CJK/Latin handling).
- **Existing documents**: preserve and tidy the existing style set by default; rebuild
  with **standard styles** only when there are none; a supplied template outranks them.
- **Risk behaviour**: downgrades are never silent (always reported). *Warn then continue*
  for constructs that may render differently; *stop and ask* to change content, to
  restructure without confirmation, or when the source cannot be read safely.
- **Definition of done**: opens without a repair prompt **and** the WordFlow checklist is
  green; structural changes additionally need per-item user confirmation.
- **Form**: a skill installed to a coding agent (opencode / Claude / Codex); `SKILL.md`
  is the entry point; no standalone CLI; does not replace OfficeCLI's own skills.

**Scope tiers**

- **Fully supported**: heading hierarchy + full style set; page size/orientation/margins;
  headers/footers + page numbers; table of contents; inline images; regular tables;
  captions; cross-references; footnotes; basic equations.
- **Supported with warning / downgrade**: floating images; merged-cell and nested tables;
  multi-column layout; different first-page / odd-even headers; page-number restart;
  complex equations.
- **Out of scope for v0.1**: editing content (ADR-0002); topic-to-article authoring;
  charts, comments, tracked changes, forms/content controls, watermarks, references &
  citation styles, mail merge, text boxes / WordArt / OLE; non-DOCX conversion; in-place
  editing (ADR-0003); a standalone CLI; built-in document-archetype presets; any Word or
  Windows dependency.

## 4. Verified facts — OfficeCLI & DOCX

Observed on OfficeCLI 1.0.152; detail in
[`references/research/officecli-behavior.md`](./references/research/officecli-behavior.md).

- **Always pass `--locale`** (`create --locale zh-CN`). It drives `docDefaults`; without it
  output is host-dependent. **Its `zh-CN` default font `等线`/DengXian is unsafe** on
  Linux/LibreOffice (no CJK coverage there).
- **`add field` always writes a cached result**, so every field reads `evaluated=true`
  immediately — even when the cache is a *placeholder*. TOC caches
  `Update field to see table of contents`; `REF` caches `«target»`. **Judge a field by its
  cached text, not by `evaluated` or `view issues`** (neither detects a bad cache).
- **`refresh` (HTML backend) runs on Linux** and fills TOC entries and `PAGEREF`, but its
  **page numbers are wrong** for Word/WPS (it uses its own HTML pagination), and it never
  resolves `REF`.
- **Style auto-definition is partial**: only `Title`, `Heading1`–`Heading9` are
  auto-defined; referencing e.g. `Caption` leaves a **dangling** style. Define styles
  explicitly before use.
- **`add section`** inserts a blank paragraph carrying the break; sections are
  `/section[N]`; set the second section after adding its content.
- **`firstLineChars`** (e.g. `200` = 2 chars) is **set/get only, not add**; lengths in
  `firstLineIndent` (`2em` is rejected).
- **Resident state leaks between files** — `officecli close` each file (the scripts do).
- **`validate`** is the schema gate; **`view issues`** is heuristic (typography opinions,
  not only schema).
- Output is **Transitional** OOXML, `compatibilityMode=15`.

## 5. Compatibility conclusions

Empirically measured — full method and evidence in
[`references/research/field-recalc-and-cross-app-verification.md`](./references/research/field-recalc-and-cross-app-verification.md);
documentary per-feature notes in
[`references/research/docx-feature-portability.md`](./references/research/docx-feature-portability.md).

**Fields / TOC / cross-references**

| Behaviour | Word 16 | WPS 12 | LibreOffice 24.2 |
|---|---|---|---|
| Recalculate fields on open | No | No | No |
| Honour `updateFields` on open | No | No | No |
| Show a placeholder / stale cache | Verbatim | Verbatim | Verbatim |
| Rebuild a TOC on open | No | No | No |
| Resolve `REF` on open | No (needs F9) | No (needs F9) | **Yes** |
| TOC page-number source | cached | cached | cached |

> **Consequence:** no application updates fields on its own. The cached result **is** what
> the reader sees, so a pre-computed cache is mandatory — and it must be *correct*. A wrong
> page number (from a non-Word pagination model) is worse than none, because it looks
> finished and is silently wrong. Placeholders must never ship silently.

**Render fidelity (LibreOffice measured, via PDF render)**

- Faithful: simple OMML equations; **merged-cell tables**; page-number restart +
  `lowerRoman`; centred `PAGE` footer.
  (Merged-cell tables are still scoped as "supported with warning" in §3; the spec may
  promote them now that they measure faithful — nested tables remain untested.)
- **Not faithful: floating (anchored) images** — rendered left-aligned and in flow, not
  centred/floating. Keep floating images in "supported with warning".
- CJK fonts substitute silently: real `SimSun` embedded, `Microsoft YaHei` → `WenQuanYi
  Zen Hei`, `等线` → `DejaVu Sans` (no CJK glyphs).
- **Untested:** nested tables, different-first-page and odd/even headers, complex
  equations, Chinese punctuation/kinsoku compression.

**Testability:** all three applications are inspectable from this WSL environment — Word
and WPS via COM (`Word.Application`, `KWPS.Application`), LibreOffice headless.

## 6. Tests & fixtures

- `tests/fixtures/` — **17 DOCX fixtures**, one feature each; see
  [`tests/fixtures/MANIFEST.md`](./tests/fixtures/MANIFEST.md).
- `tests/generate-fixtures.sh` — deterministic rebuild (explicit `--locale`, closes each
  file); `tests/validate-fixtures.sh` — `validate` + `view issues` + screenshot render per
  fixture into git-ignored `tests/.out/`.
- Last run: **`35 checks run | 35 passed | 0 failed`**.
- Fixtures are committed snapshots; regenerated files are not byte-identical (timestamps).
- See [`tests/README.md`](./tests/README.md).

## 7. Open questions

Carried from [`report/2026-09-28-requirements-grilling.md`](./report/2026-09-28-requirements-grilling.md) §4–5.

- **TOC page-number strategy** (must be decided in spec): omit page numbers / best-effort
  plus an "update fields (F9)" warning / require an application finalisation pass.
- **Template adoption boundary**: what a template contributes (theme fonts, style
  definitions, page setup) vs what it must not (its content, arguably header/footer text).
- **Exact version matrix**: which Word releases (2016/2019/365), which WPS version,
  LibreOffice 7.6 vs 24.8+.
- **Default layout values** and the concrete **standard style set**.
- **Output filename safety** (is `-排版` safe everywhere; should it localise) and
  **distribution** (install location, discovery per agent).
- **Large-document limits**, and behaviour offline or with missing fonts.
- The untested render items in §5.

## 8. Next steps

1. **`/to-spec`** — turn the frozen requirements into the v0.1 spec, resolving the open
   questions above (start with the TOC page-number strategy).
2. Write the first real layout reference (suggest `references/core/styles.md`) and grow
   `SKILL.md` from skeleton to content.
3. Fill the untested compatibility items in §5 as needed.

> Do **not** start the spec or implement features from this file alone; it is a status
> entry point, not the spec.

## 9. Historical / archive map

`report/` is an append-only audit trail — **not default reading**.

- [`report/2026-09-27-initialization.md`](./report/2026-09-27-initialization.md) — project init; two of its claims (DOCX `refresh` needs Word; no git commits) were later corrected.
- [`report/2026-09-28-docx-layout-research.md`](./report/2026-09-28-docx-layout-research.md) — the broad DOCX/OfficeCLI/compatibility research pass.
- [`report/2026-09-28-fixtures-and-baseline.md`](./report/2026-09-28-fixtures-and-baseline.md) — fixtures, scripts, and the first research notes.
- [`report/2026-09-28-requirements-grilling.md`](./report/2026-09-28-requirements-grilling.md) — the full requirements clarification (canonical source for §3).
- [`report/2026-09-28-status.md`](./report/2026-09-28-status.md) — a point-in-time status snapshot; **superseded by this file**.

`references/` (on-demand): `core/`, `fields/`, `objects/`, `compatibility/` are for future
layout guidance; `research/` holds the tagged evidence and is loaded only when a task
touches it.
