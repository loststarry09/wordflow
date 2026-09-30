# Walking-skeleton pipeline

The first vertical slice of WordFlow: the smallest **end-to-end** run that proves the
whole loop is real before the feature set is complete (issue #35; spec
`docs/spec/v0.1.md` §D3, §D4, §D5, §D12, §D13, §D14). It takes one existing `.docx`,
makes a layout decision, applies it through OfficeCLI, writes a **new** output,
validates it, renders a preview of the final output, emits the change report, and
delivers — with the warn / downgrade / stop hooks wired.

It is a **restyle** slice (spec §D5). Scope is **body/headings and page setup only**;
the advanced feature set, headers/footers, automatic content, and template adoption
(#27) are added by later tickets. The pipeline orchestrates the merged capabilities
and reimplements none of them.

Canonical tool: [`../../scripts/wf-pipeline.sh`](../../scripts/wf-pipeline.sh).
Acceptance tests: [`../../tests/pipeline.sh`](../../tests/pipeline.sh).

## What it orchestrates

| Step | Capability | Reference |
|---|---|---|
| intake / inspect (precedence, source protection, output path) | `scripts/wf-intake.sh` (#15) | [`../core/intake.md`](../core/intake.md) |
| style-ownership decision | `scripts/wf-style-ownership.sh` (#16) | [`../core/style-ownership.md`](../core/style-ownership.md) |
| page setup (A4 portrait, D6 margins) | `scripts/wf-page-setup.sh` (#18) | [`../core/sections.md`](../core/sections.md) |
| rebuild outcome — standard style set | `scripts/wf-standard-styles.sh` (#17) | [`../core/styles.md`](../core/styles.md) |
| default naming + collision numbering | `scripts/wf-output-name.sh` (#13) | [`../core/output-naming.md`](../core/output-naming.md) |
| change report (five areas) | `scripts/wf-change-report.sh` (#28) | [`change-report.md`](./change-report.md) |
| render preview of the final output | `scripts/wf-render-preview.sh` (#29) | [`render-preview.md`](./render-preview.md) |
| warn / downgrade / stop hooks | `scripts/wf-risk-policy.sh` (#30) | [`risk-policy.md`](./risk-policy.md) |

intake already resolves the style-ownership decision (#16) and the collision-safe
output path (#13); the pipeline consumes them from the job plan rather than repeating
the judgement.

## Run order

1. **Intake / inspect.** `wf-intake.sh` reads the source read-only, validates it through
   OfficeCLI, resolves the precedence chain, verifies the source hash, and returns the
   job plan with the **new, collision-safe output path**.
2. **Decide style ownership** (#16, from the plan): `rebuild-with-standard-styles`,
   `preserve-and-tidy`, or `use-template-styles`.
3. **Apply layout.** Every path goes through `wf-page-setup.sh` (D6 defaults). The
   **rebuild** path additionally runs `wf-standard-styles.sh` (§D7). The **preserve**
   path keeps the source style set — the tidy step that repairs dangling references is a
   later ticket and is recorded, not faked. `use-template-styles` cannot be honoured
   without #27 and is recorded as unverified while the source styles are preserved.
4. **New output.** The output is always a file the plan resolved as free; the source is
   never opened for writing (ADR-0003).
5. **Validate.** `officecli validate` is the schema gate; a failure stops the run and
   delivers nothing.
6. **Change report.** `wf-change-report.sh new` creates the empty report (all five
   areas); entries are added as the run proceeds.
7. **Preview.** `wf-render-preview.sh` renders the **final** output (never an
   intermediate). `--no-preview` renders nothing and records the omission in
   `unverified` via the shared contract.
8. **Risk hooks.** The delivered output is scanned for the constructs the walking
   skeleton can detect, and each finding is routed through `wf-risk-policy.sh emit`,
   which writes the warning/downgrade into the report. Nothing is hand-formatted.
9. **D14 QA for this slice.** Source unchanged; no dangling style; fields judged by
   cached text (no placeholders); every warning/downgrade recorded.
10. **Deliver.** The output `.docx`, its preview, and the report (JSON + Markdown) are
    left in the artifact directory.

## CLI

```
wf-pipeline.sh --source <docx> [--out-dir <dir> | --output <path>]
               [--template <docx>] [--requirement <file>]
               [--preview-format png|pdf] [--no-preview] [--json]
```

| Option | Meaning |
|---|---|
| `--source <docx>` | The source document to restyle (required). Never modified. |
| `--out-dir <dir>` | Directory for the output, preview, and report. Default: the source's directory. |
| `--output <path>` | Exact output path (refused if it exists) or a directory. Mutually exclusive with `--out-dir`. |
| `--template <docx>` | Source of look only; resolved by intake. Adopting it is #27 (not in this slice) and is recorded as unverified. |
| `--requirement <file>` | Written formatting requirement; resolved by intake. Applying its overrides is a later feature and is recorded as unverified. |
| `--preview-format <fmt>` | `png` (default) or `pdf`. |
| `--no-preview` | Do not render; record the omission in `unverified`. |
| `--json` | Print a machine-readable result summary. |

Exit codes: `0` delivered · `1` runtime failure (apply / validate / QA / report) ·
`2` usage error or missing dependency · `3` stop and ask.

## Artifacts

Written to the artifact directory (default: beside the source; tests use
`tests/.out/walking-skeleton/`):

- `input-<source>.docx` — a byte copy of the input, so a run is self-contained;
- `<stem>-排版.docx` — the delivered output (numbered `(2)`, `(3)` … on collision);
- `<stem>-排版-preview-<page>.png` (or `-preview.pdf`) — the preview of the output;
- `<stem>-排版-report.json` / `.md` — the change report, all five areas;
- `<stem>-排版-plan.json` — the frozen intake job plan.

## Risk hooks in this slice

The walking skeleton is deliberately small, so it exercises the risk policy over the
constructs it can detect in the **delivered output**:

- an anchored/floating image (`picture[anchor=true]`) → **warn**
  (`D11-floating-image`), because LibreOffice may render it in flow;
- a nested table (`table table`) → **warn** (`D11-nested-table`);
- a section with a page-number restart (`pageStart`) → **warn**
  (`D11-page-number-restart`);
- a field whose **cached text** is a placeholder → `unverifiable-field` with
  `resolution=state` → **warn** (`D11-unverifiable-field`), so a placeholder is never
  shipped silently.

The pipeline **warns** rather than downgrades floating images because repositioning an
image is image handling, outside this slice's body/headings scope; the warning is
accurate and the construct is left untouched. The **stop** hook is exercised when the
source cannot be read: intake refuses, and the pipeline routes the refusal through
`wf-risk-policy.sh decide --trigger source-unreadable`, prints the ask, writes no
output, and exits `3`.

Deeper construct detection (columns, first-page/odd-even headers, complex equations,
nested tables across cells) belongs with the feature tickets that own those elements;
the pipeline does not reimplement them.

## D14 checklist for this slice

- **Opens without repair** — `officecli validate` must pass; a failure stops delivery.
  (Full Word/WPS/LibreOffice repair-free checks are #31, which arrives later.)
- **No dangling style** — every referenced style resolves to a defined style. The check
  matches a reference against a style's **styleId or display name**, because `view
  stats` labels the default style by styleId and an explicit style by display name.
- **No placeholder field** — fields are judged by their **cached text**, never by the
  `evaluated` flag; a placeholder cached result is stated in `unverified`.
- **Every warning/downgrade recorded** — all risk decisions are emitted through
  `wf-risk-policy.sh` into the report; none is hand-written.
- **Source unchanged** — the source SHA-256 is verified identical before and after the
  run (intake's hash and the pipeline's own post-run hash must agree).
- **Reproducible** — identical input and instructions produce an identical layout (the
  styles and section geometry are equal between runs; byte-identity is not expected
  because OfficeCLI stamps timestamps).

## Known upstream gaps found (not patched here)

These are reported for their owning tickets; the pipeline works around them without
reimplementing a feature.

1. **#16 false-positives on #17 output.** `wf-style-ownership.sh` matches referenced
   styles against defined style **display names** only. `view stats` labels the
   default style by its **styleId** (`Normal`) while #17 defines the default with the
   display name `正文`, so #16 reports `Normal` as dangling on a freshly rebuilt
   document. The pipeline's D14 check matches on styleId **or** name, which is correct;
   #16 should do the same.
2. **No tidy capability.** The preserve outcome is described as "preserve and tidy"
   (§D5.3) and dangling references are repair items, but no tidy operation exists yet.
   The pipeline preserves the styles and records any dangling reference as unverified
   rather than pretending to repair it.
3. **#27 template adoption.** A supplied template is resolved by intake but cannot be
   adopted; the pipeline records this as unverified and preserves the source styles.
4. **Formatting-requirement overrides.** intake parses `key = value` overrides but the
   pipeline has no vocabulary to apply them, so it records that the WordFlow defaults
   were used.

## Limitations

- **Restyle only.** Generating from content (§D4) is the full workflow (#32), which
  builds on this slice.
- **Body/headings and page setup only.** Headers/footers, page numbering, automatic
  content (TOC, captions, cross-references), images, tables, and equations are later
  tickets; whatever the source already contains is preserved and, where a known risk
  applies, warned about.
- **Fonts are named, not embedded.** On a host without SimSun/SimHei the OS
  substitutes; #8 owns reporting that condition.
