---
name: wordflow
description: Lay out Word (.docx) documents to a standard, compatibility-first result by driving OfficeCLI. Use when a .docx needs creating or restructuring with proper styles and headings, page margins, headers/footers, images, tables, captions, table of contents, cross-references, footnotes/endnotes, equations, or fields, and it must open correctly in Microsoft Word, WPS Writer, and LibreOffice Writer.
---

# WordFlow

WordFlow lays out Word documents. It does not touch DOCX files itself — **OfficeCLI is the
single execution layer** for every DOCX read and write. WordFlow supplies the judgement
OfficeCLI deliberately leaves out: which styles, structures, and fields to use, and which
portable construction to prefer.

Requires OfficeCLI on `PATH` (`officecli --version`, `>= 1.0.152`). Run
`officecli help docx <element>` when a property name or value format is uncertain — do not
guess.

## Core rules

1. **Drive OfficeCLI for every DOCX operation.** Its commands are the only way files are read
   or changed (ADR-0001).
2. **Layout only — never write or edit content.** Words, images, tables, and equations are
   never changed (ADR-0002). Restructuring heading levels, section order, or paragraph
   grouping happens only on an explicit request with per-item confirmation.
3. **Always write a new file.** The source is never modified; the output is
   `<source name>-排版.docx`, numbered on collision (ADR-0003).
4. **Styles are the source of formatting truth.** Apply paragraph/character styles; keep
   direct run formatting for genuine exceptions only; define every style before referencing
   it (a dangling reference is a defect).
5. **Compatibility outranks convenience.** Choose the construction Word, WPS Writer, and
   LibreOffice Writer all open without repair; prefer the portable subset (ADR-0004).
6. **Never ship a hidden defect.** Every downgrade and warning is reported; a placeholder or
   wrong field cache is never shipped silently.
7. **Verify, then report.** Validate, check the Definition of Done, and state what changed,
   what you decided, and what is unverified.

## The two jobs

- **Generate from content** — content (text/Markdown) → styled document, optionally adopting a
  **template** and/or a written **formatting requirement**. Precedence: formatting requirement
  > template > standard styles > defaults.
- **Tidy an existing document** — restyle an existing `.docx`; preserve and tidy its own style
  set by default, rebuild with standard styles only when it has none.

Simplified Chinese is the default: SimSun body / SimHei headings, explicit Times New Roman
and Arial for Latin, 12 pt, 1.5 line spacing, 2-character first-line indent. Set fonts
explicitly — never inherit OfficeCLI's `等线`/DengXian default.

## How to run a job

1. **Inspect** — read the document and its styles through OfficeCLI (`view`, `get`, `query`,
  `view stats`) before changing anything.
2. **Decide** — pick the style set and section setup, and whether to preserve, rebuild, or
  adopt a template. Resolve the output path (collision-safe).
3. **Apply** through OfficeCLI — using the workflow tools `scripts/wf-pipeline.sh` (both jobs)
  and the per-capability `scripts/wf-*.sh` tools — preferring reusable styles over repeated
  direct formatting. Every warning/downgrade goes through `scripts/wf-risk-policy.sh`; every
  change through `scripts/wf-change-report.sh`.
4. **Verify** — `officecli validate`, the QA gate `scripts/wf-qa.sh` (spec §D14), and, for
  portability, `scripts/wf-compat-harness.sh`. Judge fields by their **cached text**, not the
  `evaluated` flag; the only exception is a layout-computed `PAGE`/`NUMPAGES`.
5. **Report** — deliver the new `.docx`, the five-area change report, and (unless disabled)
  the render preview. State every downgrade, every default applied, and anything unverified.

Common traps, all recorded in `references/`: floating images must be downgraded to centred
inline; a `PAGEREF` downgrades to a content reference; the v0.1 TOC carries **no page
numbers** (say so, and how to add them); `raw-set` is the recorded fallback when the DOM
cannot express a needed detail.

## References

Layout knowledge lives under `references/` and is read only when a task needs it; start from
`references/README.md` for the index. Key entry points:
`references/workflow/pipeline.md` (the workflows), `references/core/` (styles, sections,
naming, intake, template adoption), `references/objects/` and `references/fields/` (features),
`references/compatibility/harness.md` (portability), and `references/research/` (measured
OfficeCLI and cross-application facts).
