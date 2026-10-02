# Pipeline — the two WordFlow workflows

`scripts/wf-pipeline.sh` is the WordFlow orchestrator. It drives one document through
**inspect → decide → apply → validate → report → preview → deliver** and returns a
**new** `.docx` plus a preview and a change report. It **composes** the merged
capabilities (#13, #15–#30); it reimplements none of them.

It has two modes, matching the two jobs (spec §D4, §D5):

- **generate** — `--content <md>`: build a document from text/Markdown content
  (optionally a template and/or a written formatting requirement).
- **restyle / tidy** — `--source <docx>`: work on an existing document.

Canonical tool: [`../../scripts/wf-pipeline.sh`](../../scripts/wf-pipeline.sh).
Acceptance tests: [`../../tests/generate.sh`](../../tests/generate.sh) (generate) and
[`../../tests/pipeline.sh`](../../tests/pipeline.sh) (existing-document run).

## What it orchestrates

| Step | Capability | Reference |
|---|---|---|
| intake / inspect (precedence, source protection, output path) | `scripts/wf-intake.sh` (#15) | [`../core/intake.md`](../core/intake.md) |
| content → styled paragraphs + heading bookmarks | `scripts/wf-pipeline.sh` (`build_content`) using OfficeCLI | this file |
| style-ownership decision | `scripts/wf-style-ownership.sh` (#16) | [`../core/style-ownership.md`](../core/style-ownership.md) |
| page setup (A4 portrait, D6 margins) | `scripts/wf-page-setup.sh` (#18) | [`../core/sections.md`](../core/sections.md) |
| rebuild outcome — standard style set | `scripts/wf-standard-styles.sh` (#17) | [`../core/styles.md`](../core/styles.md) |
| preserve outcome — tidy (repair dangling styles) | `scripts/wf-tidy.sh` (#33) | this file |
| template adoption (look only) | `scripts/wf-template.sh` (#27) | [`../core/template-adoption.md`](../core/template-adoption.md) |
| headers / footers + page numbers | `scripts/wf-headers.sh` (#19) | [`../objects/headers-footers.md`](../objects/headers-footers.md) |
| inline image / floating-image downgrade | `scripts/wf-image.sh` (#20) | [`../objects/images.md`](../objects/images.md) |
| tables (regular / merged-cell / nested) | `scripts/wf-table.sh` (#21) | [`../objects/tables.md`](../objects/tables.md) |
| captions | `scripts/wf-caption.sh` (#22) | [`../fields/captions.md`](../fields/captions.md) |
| content cross-references | `scripts/wf-crossref.sh` (#23) | [`../fields/cross-references.md`](../fields/cross-references.md) |
| table of contents | `scripts/wf-toc.sh` (#24) | [`../fields/table-of-contents.md`](../fields/table-of-contents.md) |
| footnotes | `scripts/wf-footnote.sh` (#25) | [`../fields/footnotes.md`](../fields/footnotes.md) |
| equations | `scripts/wf-equation.sh` (#26) | [`../objects/equations.md`](../objects/equations.md) |
| default naming + collision numbering | `scripts/wf-output-name.sh` (#13) | [`../core/output-naming.md`](../core/output-naming.md) |
| change report (five areas) | `scripts/wf-change-report.sh` (#28) | [`change-report.md`](./change-report.md) |
| warn / downgrade / stop policy | `scripts/wf-risk-policy.sh` (#30) | [`risk-policy.md`](./risk-policy.md) |
| render preview of the final output | `scripts/wf-render-preview.sh` (#29) | [`render-preview.md`](./render-preview.md) |
| Definition-of-Done gate | `scripts/wf-qa.sh` (#31) | [`qa-gate.md`](./qa-gate.md) |

intake already resolves the style-ownership decision (#16) and the collision-safe
output path (#13); the pipeline consumes them from the job plan rather than repeating
the judgement.

## Generate mode (spec §D4)

`--content <file>` reads a line-oriented **Markdown superset**:

| Content line | Result |
|---|---|
| `# `, `## `, `### `, `#### ` | `Heading1` … `Heading4` |
| `- ` | `ListParagraph` |
| `> ` | `Quote` |
| any other non-blank line | body paragraph (`Normal`) |
| a whitespace-only line | a blank paragraph |

A trailing `{#name}` on a heading line is stripped and creates a **bookmark** named
`name`, so a later cross-reference can target it. `--title <text>` prepends a `Title`
paragraph. `--locale` (default `zh-CN`) is passed to every OfficeCLI create.

The run order is:

1. **Intake / inspect.** `wf-intake.sh` reads the content read-only, resolves the
   precedence chain (requirement > template > standard styles), computes the source
   hash, and returns the job plan with the **new, collision-safe output path**.
2. **Build the base.** `build_content` creates the document (`create --locale`), then
   adds each paragraph and its style, and its bookmark, in order. The content bytes are
   never modified.
3. **Apply the look.** With a template, `wf-template.sh` adopts its styles (`#27`) and
   page setup is *not* re-applied over it. Without a template, the standard style set
   (#17) is used and page setup runs (#18).
4. **Compose the features.** Each requested feature capability runs in a fixed order
   (headers → image → table → caption → cross-reference → footnote → equation → TOC),
   each producing its own report file; `merge_report` folds all five areas of every
   feature report into the single pipeline report. Every capability still goes through
   `wf-risk-policy.sh` for its warnings/downgrades.
5. **Validate.** `officecli validate` is the schema gate; a failure stops the run and
   delivers nothing.
6. **Definition of Done.** `wf-qa.sh` runs the #31 gate over the delivered output
   (`--no-compat` inside the run; the cross-application checks are #34).
7. **Preview.** `wf-render-preview.sh` renders the **final** output (never an
   intermediate). `--no-preview` renders nothing and records the omission in
   `unverified` via the shared contract.
8. **Deliver.** The output `.docx`, its preview, the report (JSON + Markdown), and the
   frozen plan are left in the artifact directory. Nothing is copied from the template's
   body, and the content source is byte-identical before and after.

### A formatting requirement without a template

intake parses `key = value` overrides, but there is no vocabulary to apply them without
a style source to override. The pipeline records that the WordFlow defaults were used
and lists the requirement under `unverified`, rather than claiming it was applied.

## Existing-document mode (spec §D5)

`--source <docx>` restyles or tidies an existing document:

1. **Intake / inspect** reads the source read-only and resolves the style-ownership
   decision (#16): `rebuild-with-standard-styles`, `preserve-and-tidy`, or
   `use-template-styles`.
2. **Apply layout.** `rebuild` runs `wf-standard-styles.sh`; `use-template-styles` calls
   `wf-template.sh`; `preserve` runs `wf-page-setup.sh` and then `wf-tidy.sh` (#33) over the
   preserved set. Page setup (D6) runs unless a template supplied the geometry.
3. **Restructure guard.** Restructuring is never automatic. A `--restructure <kind>` request
   is honoured only when every item has a matching `--confirm-restructure <kind>`; otherwise
   the pipeline routes the request through `wf-risk-policy.sh decide --trigger
   restructure-unconfirmed`, prints the ask, writes no output, and exits `3`. Automated
   restructuring is not part of v0.1, so a fully confirmed request is reported as a
   downgrade (`preferred-unavailable`, fallback=exists) and the structure and content are
   left unchanged.
4. **Validate → report → preview → deliver** are identical to generate mode.

### Tidy (preserve path)

`wf-tidy.sh` repairs the document's own style set without touching content: for every style
the document **references but does not define**, it adds a definition with that exact name —
a paragraph style based on the document's default style with explicit SimSun / Times New
Roman fonts, so the repair never inherits OfficeCLI's unsafe locale default (`等线`/DengXian).
Existing definitions and unused styles are left intact (non-destructive). `view stats`
classifies paragraph styles only, so every repair is a paragraph style; character/table
style classification is outside v0.1.

## CLI

```
wf-pipeline.sh --content <md> [--template <docx>] [--requirement <file>]
               [--title <text>] [--locale <tag>]
               [--header <text>] [--footer <text>] [--page-number]
               [--image <png>] [--image-para <path>] [--image-width <n>] [--image-alt <text>]
               [--table-data <csv>] [--table-widths <list>] [--table-header-row] ...
               [--caption <text>] [--caption-kind table|figure] [--caption-para <path>]
               [--xref <bookmark>] [--xref-para <path>]
               [--footnote <text>] [--footnote-para <path>]
               [--equation <latex>] [--equation-mode inline|display] [--equation-para <path>]
               [--toc] [--toc-levels <n-m>] [--toc-title <text>]
               [--out-dir <dir> | --output <path>] [--preview-format png|pdf] [--no-preview] [--json]

wf-pipeline.sh --source <docx> [--out-dir <dir> | --output <path>]
               [--template <docx>] [--requirement <file>]
               [--restructure <kind>] [--confirm-restructure <kind>]
               [--preview-format png|pdf] [--no-preview] [--json]
```

`--content` and `--source` are mutually exclusive; intake decides which job the run is.
The full feature-flag list is in the tool's `usage()`.

Exit codes: `0` delivered · `1` runtime failure (apply / validate / QA / report) ·
`2` usage error or missing dependency · `3` stop and ask.

## Artifacts

Written to the artifact directory (default: beside the source; tests use
`tests/.out/…`):

- `input-<source>` — a byte copy of the source/content, so a run is self-contained;
- `<stem>-排版.docx` — the delivered output (numbered `(2)`, `(3)` … on collision);
- `<stem>-排版-preview-<page>.png` (or `-preview.pdf`) — the preview of the output;
- `<stem>-排版-report.json` / `.md` — the change report, all five areas;
- `<stem>-排版-plan.json` — the frozen intake job plan.

## Risk hooks

The risk policy (#30) runs over the **delivered output**, and every finding is written
into the report through `wf-risk-policy.sh emit`; none is hand-formatted. The triggers
are the spec §D11 vocabulary (`floating-image`, `nested-table`, `page-number-restart`,
`columns`, `unverifiable-field`, `source-unreadable`, `content-change`,
`restructure-unconfirmed`, `preferred-unavailable`). A source that cannot be read is
routed through `wf-risk-policy.sh decide --trigger source-unreadable`: the pipeline
prints the ask, writes no output, and exits `3`.

## D14 checklist

- **Opens without repair** — `officecli validate` must pass; the full Word/WPS/LibreOffice
  checks are the `wf-qa.sh` gate (#31) and v0.1 acceptance (#34).
- **No dangling style** — every referenced style resolves to a defined style, matched by
  **styleId or display name** (see the #16 note below).
- **No placeholder field** — fields are judged by their **cached text**, never by the
  `evaluated` flag; a placeholder cached result is stated in `unverified`.
- **Every warning/downgrade recorded** — all risk decisions are emitted through
  `wf-risk-policy.sh`; none is hand-written.
- **Source unchanged** — the source SHA-256 is verified identical before and after the
  run (intake's hash and the pipeline's own post-run hash must agree).
- **Reproducible** — identical input and instructions produce an identical layout (the
  styles and section geometry are equal between runs; byte-identity is not expected
  because OfficeCLI stamps timestamps).

## Known upstream gaps (owned elsewhere)

1. **#16 matches by display name only.** `view stats` can label the default style by its
   styleId while it is defined with a different display name, so #16 can report it as
   dangling. The pipeline's own D14 check matches styleId **or** name.
2. **Formatting-requirement overrides** need a template (or #33's tidy vocabulary) to
   apply against; without one they are recorded, not faked.
