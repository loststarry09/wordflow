---
name: wordflow
description: Lay out Word (.docx) documents to a standard, compatibility-first result by driving OfficeCLI. Use when a .docx needs creating or restructuring with proper styles and headings, page margins, headers/footers, images, tables, captions, table of contents, cross-references, footnotes/endnotes, equations, or fields, and it must open correctly in Microsoft Word, WPS Writer, and LibreOffice Writer.
---

# WordFlow

WordFlow teaches an Agent how to lay out Word documents correctly. It does not touch DOCX files itself — **OfficeCLI is the single execution layer** for every DOCX read and write. WordFlow supplies the judgement OfficeCLI deliberately leaves out: which styles, structures, and fields to use, and which portable construction to prefer.

Requires OfficeCLI on `PATH` (`officecli --version`). Run `officecli help docx <element>` when a property name or value format is uncertain — do not guess.

## Core rules

1. **Drive OfficeCLI for every DOCX operation.** Treat its commands as the only way files are read or changed.
2. **Styles are the source of formatting truth.** Apply paragraph and character styles; keep direct run formatting for genuine exceptions only.
3. **Compatibility outranks convenience.** Choose the construction that Word, WPS Writer, and LibreOffice Writer all render faithfully.
4. **Prefer standard OOXML.** Fall back to `raw-set` only when the DOM layer cannot express the need, and record the reason.
5. **Verify before reporting done.** Run OfficeCLI's schema validation and issue view; report unresolved warnings.

## Workflow

1. **Inspect** — read the document and its styles (`officecli view`, `get`, `query`) before changing anything.
2. **Plan the styles** — decide the paragraph/character styles and section setup the layout needs.
3. **Apply** — make changes through OfficeCLI, preferring reusable styles over repeated direct formatting.
4. **Verify** — `officecli validate` and `officecli view <file> issues`.
5. **Report** — summarize what changed and any compatibility caveats.

## References

Layout knowledge lives under `references/` and is read only when the task needs it. Start from `references/README.md` for the index and the convention for adding entries.

## Status

Skeleton. The rules and workflow above are stable; the detailed layout knowledge is not yet written.
