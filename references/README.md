# References

Layout knowledge for WordFlow. These files are **disclosed on demand**: `SKILL.md` points here, and an agent loads a single topic only when a task needs it. Keep each file self-contained and focused; do not duplicate content across files.

For the distilled current conclusions, read [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md); these files hold the detail and the evidence behind them.

## Layout

| Directory | Concern | Example topics |
|-----------|---------|----------------|
| `core/` | Document skeleton and typography | paragraph/character styles, heading hierarchy, sections, page size, margins, headers/footers, page numbering, output naming, intake/precedence |
| `workflow/` | Job-level behaviour | change report, render preview, warn/downgrade/stop policy, the end-to-end pipeline |
| `fields/` | Generated and linked content | fields, TOC, captions (SEQ), cross-references (REF/PAGEREF), bookmarks, footnotes/endnotes |
| `objects/` | Embedded and structured content | images, tables, equations, charts |
| `compatibility/` | Portability across applications | Word / WPS Writer / LibreOffice Writer differences and the portable choice |
| `research/` | Holding area for researched facts | OfficeCLI behaviour; per-feature portability notes, each item tagged verified / standard / uncertain |

Directories are grouped by concern, not by OfficeCLI element, because one element (e.g. `paragraph`) belongs to several concerns.

`research/` is a **holding area**, not finished guidance. Each claim is tagged `[V]` verified, `[S]` standard-backed, or `[?]` uncertain, so nothing unproven is mistaken for a rule. Facts move from `research/` into the concern directories once a real layout task needs them.

## Convention for adding a reference

- **One topic per file**, named for the topic (`core/styles.md`, `fields/cross-references.md`).
- **State the portable construction first**, then the OfficeCLI commands that produce it, then the compatibility caveat.
- **Cite OfficeCLI capabilities instead of copying them.** Run `officecli help docx <element>` for the property list; document the *decision*, not the schema.
- **Prefer reproducible operations** (styles + `dump`/`batch`) over one-off edits, and say when `raw-set` is the only option.
- **No speculative content.** Add a file when a real layout task needs it.
