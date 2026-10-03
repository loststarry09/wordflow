# WordFlow — Project Status

**Authoritative entry point — read this first.** It states what WordFlow is, what is
decided, what is verified, and where everything lives. It summarises and links; the ADRs
hold the arguments, `docs/spec/v0.1.md` holds the contract, and `references/research/` holds
the evidence.

- **Status:** **v0.1.1 — COMPLETE** (2026-10-03). Correctness / hardening release;
  no new features or contract expansion. The v0.1.0 tag is preserved.
- **Verified tooling:** OfficeCLI `1.0.153` (baseline `1.0.152`); Microsoft Word `16.0`;
  WPS Writer `12.0`; LibreOffice `24.2.7.2`.
- **Verified by:** `tests/acceptance.sh` 51/51; compatibility gate 12/12 records repair-free;
  required compat 42/42 with 0 skip; `tests/validate-fixtures.sh` 73/73 over 32 fixtures;
  **2,464 checks across 37 suites, all passing**; `shellcheck -S warning` clean over
  63 shell sources. Release verification: [final record](./report/2026-10-03-v0.1.1-release.md).

## Reading order

1. **`PROJECT_STATUS.md`** — this file.
2. **`CONTEXT.md`** — the ubiquitous language (roles, layout/content, risk vocabulary).
3. **`SKILL.md`** — the agent-facing entry point that ships with the skill.
4. **`docs/spec/v0.1.md`** — the behaviour v0.1 promises (D1–D14).
5. **Only the ADR or `references/` file the task touches.**

Do **not** read `report/` by default: it is a narrative audit trail — open
[`report/v0.1-development-summary.md`](./report/v0.1-development-summary.md) for the v0.1
story or [`report/2026-10-02-v0.1-acceptance.md`](./report/2026-10-02-v0.1-acceptance.md) for
the acceptance evidence.
For v0.1.1 correctness fixes and final gates, see
[`report/2026-10-03-v0.1.1-release.md`](./report/2026-10-03-v0.1.1-release.md) and the
[release notes](./report/v0.1.1-release-notes.md).

---

## 1. What WordFlow is

- A Word layout **skill for agents**: a judgement/knowledge layer, not an engine, parser, or
  renderer.
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

**Frozen decisions** — the full reasoning lives in the ADRs:

- [`0001`](./docs/adr/0001-officecli-is-the-single-execution-layer.md) · OfficeCLI is the single execution layer
- [`0002`](./docs/adr/0002-layout-only-never-edit-content.md) · WordFlow lays out; it never writes or edits content
- [`0003`](./docs/adr/0003-output-is-a-new-file.md) · Output is always a new file; the source is never modified
- [`0004`](./docs/adr/0004-compatibility-means-opens-without-repair.md) · Compatibility means "opens without repair"

**Orchestration.** `scripts/wf-pipeline.sh` composes the capabilities; four cross-cutting
contracts keep them coherent — the **job plan** (`wf-intake.sh`), the **change report**
(`wf-change-report.sh`, five areas), the **risk policy** (`wf-risk-policy.sh`, one trigger
table), and the **QA gate** (`wf-qa.sh`). See
[`references/workflow/pipeline.md`](./references/workflow/pipeline.md).

## 3. Workflows (spec §D4, §D5)

Both jobs write a **new** file named `<source name>-排版.docx` (numbered on collision), with a
five-area **change report** and, by default, a **render preview**.

**Generate from content** — `wf-pipeline.sh --content <md> [--template …] [--requirement …]`:
intake → build the styled base (line-oriented Markdown superset; trailing `{#name}` becomes a
bookmark) → apply the look (template styles, else the standard set + page setup) → compose the
requested features → `validate` → QA gate → preview → deliver.

**Tidy an existing document** — `wf-pipeline.sh --source <docx> …`: intake → style-ownership
decision (`preserve-and-tidy` / `rebuild-with-standard-styles` / `use-template-styles`) →
restyle layout only → `preserve` runs page setup then `wf-tidy.sh` (repairs dangling paragraph
styles non-destructively) → the restructure guard → `validate` → QA gate → preview → deliver.
Restructuring is never automatic: an unconfirmed `--restructure` request stops with exit `3`
and writes nothing; a fully confirmed request is reported as a downgrade and changes nothing.

Exit codes: `0` delivered · `1` runtime failure · `2` usage/dependency · `3` stop and ask.
Documented in [`references/workflow/pipeline.md`](./references/workflow/pipeline.md).

## 4. Capability matrix (spec §D9)

**Fully supported** — produced with QA, expected to open and render faithfully:

- heading hierarchy (levels 1–4) and the full standard style set (§D7);
- page size, orientation, margins;
- headers/footers and page numbers, including different-first-page and odd/even;
- table of contents (structure; page numbers intentionally omitted — §D9);
- inline images;
- regular, merged-cell, and nested tables (nested tables require `tblW == Σ colWidths`,
  fixed layout, explicit `colWidths`, direct borders);
- captions (SEQ, correct cached number);
- content cross-references (correct cached text);
- footnotes;
- basic (simple inline/display) equations.

**Limited — produced with a warning, or downgraded (always reported):**

- floating (anchored / text-wrapped) images → downgraded to centred inline;
- multi-column layout (warn);
- page-number restart (warn);
- page-number cross-references (`PAGEREF`) → downgraded to a content reference;
- complex equations (construct-specific: matrices/`m:eqArr` faithful; `\begin{aligned}`/`|`
  warn — keep OMML, no image/text fallback).

**Out of scope for v0.1:** editing content (ADR-0002); topic-to-article authoring; charts,
comments, tracked changes, forms/content controls, watermarks, references & citation styles,
mail merge, text boxes / WordArt / OLE; non-DOCX conversion; in-place editing (ADR-0003); a
standalone CLI; document-archetype presets; any Word or Windows dependency; heading levels
beyond 4.

## 5. Compatibility (measured)

Full method and evidence in
[`references/research/field-recalc-and-cross-app-verification.md`](./references/research/field-recalc-and-cross-app-verification.md)
and [`references/research/docx-feature-portability.md`](./references/research/docx-feature-portability.md).

| Behaviour | Word 16 | WPS 12 | LibreOffice 24.2 |
|---|---|---|---|
| Recalculate fields on open | No | No | No |
| Honour `updateFields` on open | No | No | No |
| Show a placeholder / stale cache | Verbatim | Verbatim | Verbatim |
| Rebuild a TOC on open | No | No | No |
| Resolve `REF` on open | No (needs F9) | No (needs F9) | **Yes** |
| TOC page-number source | cached | cached | cached |

- **Consequence:** the cached result **is** what the reader sees, so every cache must be
  correct. **Carve-out:** *page-dependent* fields (`PAGE`, `NUMPAGES`, an unlocked `PAGEREF`)
  are recomputed by the reader's layout engine per page, so a stale cache does not change what
  is shown.
- **Render fidelity (LibreOffice measured):** simple equations, merged-cell and nested tables,
  first-page/odd-even headers, multi-page footer `PAGE`/`NUMPAGES`, and page-number restart +
  Roman format are faithful. **Floating images are not** (rendered in flow) — hence the
  downgrade. CJK fonts substitute silently when absent; WordFlow sets its own fonts explicitly.
- **Version matrix:** pinned in [`references/research/version-matrix.md`](./references/research/version-matrix.md).
  Word/WPS are drivable from WSL over COM and LibreOffice is headless, so all three are
  measurable ([`references/compatibility/harness.md`](./references/compatibility/harness.md)).

## 6. QA and tests

- **The QA gate** `scripts/wf-qa.sh` is the executable Definition of Done (spec §D14): schema,
  no dangling styles (styleId **or** name), no placeholder cache, number-free TOC, valid change
  report, every limited construction reported, preview covers the output, source unchanged,
  output is a new collision-safe file, reproducible, opens repair-free. See
  [`references/workflow/qa-gate.md`](./references/workflow/qa-gate.md).
- **v0.1.1 hardening (2026-10-03):** source/output/report alias protection, actual table
  width read-back, standard-style idempotency, isolated REF field cleanup, complete limited
  construct reporting, real preview artifact checks, required three-application compatibility,
  owned-process cleanup, concurrent TOC staging, and the corrected nested-table fixture.
  Full regression: **37 suites / 2,464 checks**, all green; required compat **42/42,
  0 skip**. Two rounds and final gate evidence are linked from the
  [release record](./report/2026-10-03-v0.1.1-release.md).
- **Historical run (2026-10-02, v0.1.0):** `acceptance` **51**, `validate-fixtures` **65** (32
  fixtures), `compat-harness` **42/42** (real Word/WPS/LibreOffice), `pipeline` **63**,
  `generate` **73**, `tidy` **54**, `qa` **33**, `skill-discovery` **20**, plus every unit and
  feature suite — **1,495 checks across 27 suites, all green**; `shellcheck -S warning` clean.
- **Fixtures:** 32 DOCX snapshots, one feature each, documented in
  [`tests/fixtures/MANIFEST.md`](./tests/fixtures/MANIFEST.md); rebuilt deterministically by
  `tests/generate-fixtures.sh`. See [`tests/README.md`](./tests/README.md).

## 7. Known limitations

- **Formatting-requirement overrides without a template** are recorded `unverified` (no style
  source to apply them against); WordFlow defaults are used.
- **Automated restructuring** is not in v0.1; a confirmed request is a reported downgrade and
  the document is unchanged.
- **Floating images** are downgraded to centred inline (ported from the LibreOffice finding).
- **Pagination is not pixel-identical** across applications (the promise is *opens without
  repair*, ADR-0004).
- **Font substitution** on a host lacking SimSun/SimHei is the OS's behaviour, reported where
  relevant.
- TOC page numbers are intentionally omitted; the user updates the field (F9) to add them.

## 8. Documentation map

| Need | Read |
|---|---|
| What v0.1 promises | [`docs/spec/v0.1.md`](./docs/spec/v0.1.md) |
| The vocabulary | [`CONTEXT.md`](./CONTEXT.md) |
| How to use WordFlow (agent) | [`SKILL.md`](./SKILL.md) |
| Learned behaviour / rules | `references/{core,workflow,fields,objects}/` (index: [`references/README.md`](./references/README.md)) |
| OfficeCLI facts & measurements | [`references/research/`](./references/research/) |
| Portability method & tooling | [`references/compatibility/harness.md`](./references/compatibility/harness.md) |
| Architecture decisions | [`docs/adr/`](./docs/adr/) |
| Install & discovery per agent | [`docs/distribution.md`](./docs/distribution.md) |
| History / acceptance evidence | [`report/`](./report/) |
| How the repo is run | [`AGENTS.md`](./AGENTS.md) |
