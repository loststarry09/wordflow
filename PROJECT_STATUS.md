# WordFlow — Project Status

**Authoritative entry point — read this first.** It states what WordFlow is, what is
decided, what is verified, where the work stands, and what is next. It summarises and
links; the ADRs hold the full arguments and `references/research/` holds the evidence.

- **Last updated:** 2026-10-01
- **Verified tooling:** OfficeCLI `1.0.153` (baseline `1.0.152`; the drift is noted in the #9/#11 references); Word `16.0`; WPS Writer `12.0`; LibreOffice `24.2.7.2`
- **Phase:** foundation complete and hardened — the single-document **walking skeleton**, the first compatibility
  research wave, the TOC and cross-reference cache mechanisms, distribution, and an **executable QA gate (#31)**
  are implemented and merged; the document **features (#19–#27) are not built yet**. See **Implementation
  status** and §6.

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

## Implementation status

Everything below is merged to `main`, covered by acceptance tests, and reproducible. WordFlow owns the
judgement; every DOCX read/write still goes through OfficeCLI (ADR-0001).

| Capability | Issue | Deliverable | Test command |
|---|---|---|---|
| Style inspection + ownership decision | #16 | `scripts/wf-style-ownership.sh`, `references/core/style-ownership.md` | `tests/style-ownership.sh` |
| Output filename rule + primitive | #13 | `scripts/wf-output-name.sh`, `references/core/output-naming.md` | `tests/output-naming.sh` |
| Page setup + section model | #18 | `scripts/wf-page-setup.sh`, `references/core/sections.md` | `tests/page-setup.sh` |
| Standard style set + zh-CN typography | #17 | `scripts/wf-standard-styles.sh`, `references/core/styles.md` | `tests/standard-styles.sh` |
| Intake, precedence, source protection | #15 | `scripts/wf-intake.sh`, `references/core/intake.md` | `tests/intake.sh` |
| Change-report contract | #28 | `scripts/wf-change-report.sh`, `references/workflow/change-report.md` | `tests/change-report.sh` |
| Render preview | #29 | `scripts/wf-render-preview.sh`, `references/workflow/render-preview.md` | `tests/render-preview.sh` |
| Warn / downgrade / stop policy | #30 | `scripts/wf-risk-policy.sh`, `references/workflow/risk-policy.md` | `tests/risk-policy.sh` |
| Cross-application compatibility harness | #2 | `scripts/wf-compat-harness.sh`, `references/compatibility/harness.md` | `tests/compat-harness.sh` |
| **Walking skeleton (end-to-end)** | #35 | `scripts/wf-pipeline.sh`, `references/workflow/pipeline.md` | `tests/pipeline.sh` |
| TOC cache without page numbers | #11 | `references/fields/toc-without-page-numbers.md`, fixture `toc/toc-no-page-numbers.docx` | `tests/toc-cache.sh` |
| Cached cross-reference text | #12 | `references/fields/cached-cross-references.md`, fixture `fields/cached-cross-ref.docx` | `tests/crossref-cache.sh` |
| **QA / Definition-of-Done gate** | #31 | `scripts/wf-qa.sh`, `references/workflow/qa-gate.md` | `tests/qa.sh` |
| Skill distribution & discovery | #14 | `docs/distribution.md`, `.agents/skills/wordflow/`, `.claude/skills/wordflow/` | `tests/skill-discovery.sh` |
| Large-document & missing-font research | #9 | `references/research/large-documents-and-fonts.md` | `tests/probes/large-document.sh` |
| Version matrix | #10 | `references/research/version-matrix.md` | `tests/probes/detect-versions.sh` |

The walking skeleton (#35) runs one document through **inspect → layout decision → apply → new output
→ validate → preview → change report → risk hooks → deliver**, verifies the source is unchanged, and
produces a real DOCX + preview + change report under `tests/.out/walking-skeleton/`. Features #19–#27
and the full workflows #32/#33 build on these primitives.

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
  headers/footers + page numbers (incl. different first-page / odd-even); table of contents;
  inline images; regular, merged-cell, and nested tables (nested tables require
  `tblW == Σ colWidths` + fixed layout + explicit `colWidths` + direct borders); captions;
  content cross-references; footnotes; basic equations.
- **Supported with warning / downgrade**: floating images; multi-column layout; page-number
  restart; page-number cross-references; complex equations (construct-specific).
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

**New verified facts (2026-10-01 batch)** — detail in the linked research/references:

- **`view stats` labels the default referenced style by its `styleId`** (`Normal`) while a style can be
  *defined* with a different display name; match referenced→defined by `styleId` **or** name (this
  mismatch caused a false-dangling bug, #36).
- **LibreOffice ignores `w:firstLineChars`** unless the absolute `w:firstLine` twin is also written;
  write both for a character-unit first-line indent (#17).
- **`add /styles` with an existing `styleId` replaces the whole style and drops `w:default`** (sends
  unstyled paragraphs to `docDefaults`/`等线`); use `set /styles/Normal` or `add --prop default=true`.
- **Length parser** accepts `cm`, `in`, `pt` and a bare number; **rejects `mm` and `twip`** (#18).
- **Page-dependent fields are computed by the reader's layout engine, not the cache**: footer
  `PAGE`/`NUMPAGES` (and an unlocked `PAGEREF`) show the correct value per page in Word/WPS/LibreOffice
  with no F9, even when the cache is stale (#3).
- **`add / --type header|footer --prop type=first|default|even`** auto-writes `w:titlePg` /
  `<w:evenAndOddHeaders/>`; the `default` part is the **odd**-page part when even/odd is on (#5).
- **The equation FormulaParser is LaTeX-ish and never emits `m:eqArr`** (`\begin{aligned}` becomes
  `m:m`); a true equation array needs `raw-set` (#6).
- **Harness caveat:** `wf-compat-harness.sh` hangs LibreOffice when `--out` is a **relative** path
  (relative `file://` profile URI); pass an absolute `--out` (the default is absolute) (#37, fixed in #38).
- **Bulk operations:** one `officecli add` costs ≈0.77 s; 50 in one `batch` cost ≈1.5 s (~43×), and a resident
  does not help (startup-bound). Use `batch` for repeated operations; memory (~5 KB/paragraph) and the render
  preview are the practical limits, not per-op speed (#9).
- **Environment drift:** the current OfficeCLI is `1.0.153` (baseline `1.0.152`); the #11/#12 recipes and the
  #9/#10 probes were re-verified against it.

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
>
> **Carve-out (#3):** *page-dependent* fields (`PAGE`, `NUMPAGES`, and an unlocked `PAGEREF`) are
> recomputed by the reader's layout engine per page, so a stale cache does not affect what is shown.
> Content caches (`REF`/`SEQ`) and the TOC still need a correct, non-placeholder cache.

**Render fidelity (LibreOffice measured, via PDF render)**

- Faithful: simple OMML equations; **merged-cell tables**; **nested tables** (portable construction);
  **different first-page / odd-even headers**; multi-page footer `PAGE`/`NUMPAGES`; page-number restart +
  `lowerRoman`; centred `PAGE` footer.
- **Not faithful: floating (anchored) images** — rendered left-aligned and in flow, not
  centred/floating. Keep floating images in "supported with warning".
- CJK fonts substitute silently: real `SimSun` embedded, `Microsoft YaHei` → `WenQuanYi
  Zen Hei`, `等线` → `DejaVu Sans` (no CJK glyphs).

**First compatibility research wave (#3–#7)** — each with a committed fixture and a tagged research
note under `references/research/`:

- **Nested tables → promote to fully supported (#4).** All three open repair-free and render
  faithfully (fixed layout, explicit `colWidths`, direct borders; `tblW` must equal Σ`colWidths`).
- **Different first-page + odd/even headers/footers → portable (#5).** FIRST/EVEN/ODD/EVEN rendered
  identically in Word 16 / WPS 12 / LO 24.2; recommend promotion (LO 7.6 and multi-section
  link-to-previous remain untested).
- **Complex equations → keep OMML, warn (#6).** Matrices and `m:eqArr` are faithful in all three;
  failures are LibreOffice-only and narrow (parser `\begin{aligned}`, the `|` character). Image/
  plain-text fallbacks are excluded by ADR-0001/0002.
- **CJK punctuation / kinsoku → application-controlled; no setting required (#7).** 0 forbidden-boundary
  lines in all three; optional low-risk `charSpacingControl=compressPunctuation` default for #17.
- **Multi-page page numbers → footer `PAGE`/`NUMPAGES` safe to ship (#3).** PAGEREF/TOC page numbers
  stay limited/omitted.

These findings **challenged** the earlier "untested" list and the blanket "the cached result is what the
reader sees" claim; the spec/status changes are **applied in #37** (spec §D6/§D8/§D9/§D10/§D14 and this file).

**Testability:** all three applications are inspectable from this WSL environment — Word
and WPS via COM (`Word.Application`, `KWPS.Application`), LibreOffice headless.

## 6. Tests & fixtures

- `tests/fixtures/` — **31 DOCX fixtures**, one feature each; see
  [`tests/fixtures/MANIFEST.md`](./tests/fixtures/MANIFEST.md).
- `tests/generate-fixtures.sh` — deterministic rebuild (explicit `--locale`, closes each
  file); `tests/validate-fixtures.sh` — `validate` + `view issues` + screenshot render per
  fixture into git-ignored `tests/.out/`.
- **Acceptance suites** (one per capability, all green): `tests/style-ownership.sh`,
  `output-naming.sh`, `page-setup.sh`, `standard-styles.sh`, `intake.sh`, `change-report.sh`,
  `render-preview.sh`, `risk-policy.sh`, `toc-cache.sh`, `crossref-cache.sh`, `qa.sh`,
  `skill-discovery.sh`, `compat-harness.sh`, `pipeline.sh`; research probes under `tests/probes/`.
- **QA gate:** `scripts/wf-qa.sh` is the executable Definition of Done (spec §D14) — see
  [`references/workflow/qa-gate.md`](./references/workflow/qa-gate.md).
- **Last full run (2026-10-01):** `validate-fixtures` **63 checks | 63 passed** (31 fixtures);
  `qa` **33 | 33**; `compat-harness` (real Word/WPS/LibreOffice) **42 | 42**; `pipeline` (real
  end-to-end) **63 | 63**; `toc-cache` **40 | 40**; `crossref-cache` **39 | 39**; all other unit
  suites and `shellcheck -S warning` clean.
- Fixtures are committed snapshots; regenerated files are not byte-identical (timestamps).
- See [`tests/README.md`](./tests/README.md).

## 7. Open questions

**Resolved this batch:**

- ~~TOC page-number strategy~~ — frozen: page numbers omitted in v0.1 (spec §D9); footer
  `PAGE`/`NUMPAGES` confirmed safe per page (#3).
- ~~Default layout values / standard style set~~ — frozen in spec §D6/§D7 and implemented (#17).
- ~~Output filename safety~~ — frozen: `-排版`, ASCII numbering, not localised (#13).
- ~~CJK font strategy~~ — SimSun body / SimHei headings + explicit Latin faces confirmed (#8).
- ~~Untested render items in §5~~ — nested tables (#4), first-page/odd-even headers (#5), complex
  equations (#6), CJK punctuation/kinsoku (#7) are now measured and their capability tiers **applied to the
  spec in #37** (promotions: nested tables and first-page/odd-even headers → fully supported). See §5.
- ~~Exact version matrix (#10)~~, ~~distribution/discovery (#14)~~, ~~large-document / offline / missing-font
  behaviour (#9)~~, ~~TOC cache without page numbers (#11)~~, ~~cached cross-reference text (#12)~~ — all
  delivered; see the **Implementation status** table and the linked references. #36/#38/#39 (foundation bug and
  tool/fixture defects) are fixed.

**Still open:**

- **Template adoption boundary** (what a template contributes vs must not) — implementation ticket #27.
- **Tidy capability**: dangling-style repair and template/formatting-requirement application are recorded as
  unverified by the walking skeleton; built out in #27/#33.
- **Feature mechanics** for #19–#27 (headers/footers + page numbers, images, tables, captions,
  cross-references, TOC, footnotes, equations) — the next build phase.

## 8. Next steps

1. Implement the document **features**: `#19` headers/footers + page numbers, `#20` images,
   `#21` tables, `#22` captions, `#23` cross-references, `#24` TOC, `#25` footnotes, `#26`
   equations, `#27` template adoption. Each must pass the executable DoD gate (`scripts/wf-qa.sh`, #31).
2. Then the full workflows **`#32`/`#33`** and **`#34`** v0.1 acceptance.
3. Grow `SKILL.md` from skeleton to content as the feature set lands.
4. Keep the reference index and this file current; record each ticket in `report/` as an audit trail.

> Do **not** start the spec or implement features from this file alone; it is a status
> entry point, not the spec.

## 9. Historical / archive map

`report/` is an append-only audit trail — **not default reading**.

- [`report/2026-09-27-initialization.md`](./report/2026-09-27-initialization.md) — project init; two of its claims (DOCX `refresh` needs Word; no git commits) were later corrected.
- [`report/2026-09-28-docx-layout-research.md`](./report/2026-09-28-docx-layout-research.md) — the broad DOCX/OfficeCLI/compatibility research pass.
- [`report/2026-09-28-fixtures-and-baseline.md`](./report/2026-09-28-fixtures-and-baseline.md) — fixtures, scripts, and the first research notes.
- [`report/2026-09-28-requirements-grilling.md`](./report/2026-09-28-requirements-grilling.md) — the full requirements clarification (canonical source for §3).
- [`report/2026-09-28-status.md`](./report/2026-09-28-status.md) — a point-in-time status snapshot; **superseded by this file**.

`references/` (on-demand): `core/` (styles, sections, naming, intake), `workflow/` (change report,
render preview, risk policy, pipeline, QA gate), `compatibility/` (the cross-app harness), and `fields/`
(the TOC and cross-reference cache mechanisms) hold the implemented guidance; `objects/` is future feature
work (per-feature evidence lives under `research/`).
