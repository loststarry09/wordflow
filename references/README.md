# References

Layout knowledge for WordFlow. These files are **disclosed on demand**: `SKILL.md` points
here, and an agent loads a single topic only when a task needs it. Keep each file
self-contained and focused; do not duplicate content across files.

For the distilled current conclusions, read [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md);
for the contract, [`../docs/spec/v0.1.md`](../docs/spec/v0.1.md); these files hold the detail
and the evidence behind them.

## Layout

| Directory | Concern | Topics |
|-----------|---------|--------|
| `core/` | Document skeleton and typography | standard styles + zh-CN typography, style ownership, sections/page setup, output naming, intake/precedence, template adoption |
| `workflow/` | Job-level behaviour | change report, render preview, warn/downgrade/stop policy, the pipeline, the QA gate |
| `fields/` | Generated and linked content | TOC (incl. the number-free cache), captions (SEQ), cross-references (REF/PAGEREF incl. the cached-text mechanism), footnotes |
| `objects/` | Embedded and structured content | images, tables, equations, headers/footers |
| `compatibility/` | Portability across applications | the cross-application harness (Word / WPS / LibreOffice) |
| `research/` | Measured facts and evidence | OfficeCLI behaviour, the version matrix, per-feature portability, CJK fonts/punctuation, large documents, and the cross-application measurements behind the capability tiers |

Directories are grouped by concern, not by OfficeCLI element, because one element (e.g.
`paragraph`) belongs to several concerns.

`research/` holds the **evidence** behind the frozen rules: each claim is tagged `[V]`
verified, `[S]` standard-backed, or `[?]` uncertain, so nothing unproven is mistaken for a
rule. The engineered rules live in the concern directories and follow this convention:

## Convention for adding a reference

- **One topic per file**, named for the topic (`core/styles.md`, `fields/cross-references.md`).
- **State the portable construction first**, then the OfficeCLI commands that produce it, then
  the compatibility caveat — and point to the `research/` file that measured it.
- **Cite OfficeCLI capabilities instead of copying them.** Run `officecli help docx <element>`
  for the property list; document the *decision*, not the schema.
- **Prefer reproducible operations** (styles + `dump`/`batch`) over one-off edits, and say when
  `raw-set` is the only option.
- **No speculative content.** Add a file when a real layout task needs it.
