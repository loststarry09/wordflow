# WordFlow — Feature implementation batch: #19–#27 (capability scripts)

- **Date**: 2026-10-01
- **Method**: orchestrator + parallel sub-agents in isolated git worktrees (three waves of three); the main agent reviewed, ran each suite, merged `--no-ff`, and ran the full regression.
- **Outcome**: all nine feature issues `#19`–`#27` implemented, merged, tested, and closed. `main` at `1a30f5f`, pushed, tree clean.
- **Design**: each feature is a **self-contained capability script** (`scripts/wf-<name>.sh`) that protects the source (ADR-0003), performs every DOCX read/write through OfficeCLI under `timeout 60`, verifies its effect by reading the output back, routes warnings/downgrades through the shared risk policy (no hardcoded `D11-*`), emits a JSON report, and ships with a fixture-driven acceptance suite. The capabilities are not yet wired into the single-document pipeline — that is the workflows phase `#32`/`#33`.

## Waves and commits

| Wave | Issue | Feature | Commit | Suite |
|---|---|---|---|---|
| 1 | #19 | headers/footers + page numbers | `da03b0c` | `headers.sh` 52 |
| 1 | #20 | inline images + floating-image downgrade | `cf04a7c` | `image.sh` 50 |
| 1 | #21 | regular / merged-cell / nested tables (+ `merged-table.docx`) | `08079b3` | `table.sh` 49 |
| 2 | #22 | captions (SEQ, correct cached number) | `5ec1c1b` | `caption.sh` 60 |
| 2 | #25 | footnotes (+ defined text/reference styles) | `18cd6fa` | `footnote.sh` 54 |
| 2 | #26 | inline/display equations (construct-specific complex warning) | `cf5ccce` | `equation.sh` 49 |
| 3 | #23 | content cross-references (correct cached text; PAGEREF downgrades) | `4b4a133` | `crossref.sh` 45 |
| 3 | #24 | table of contents without page numbers | `f6df27b` | `toc.sh` 75 |
| 3 | #27 | template adoption (look only; requirement outranks) | `57f7cdc` | `template.sh` 56 |

Merge points: wave 1 → `a05421b`; wave 2 → `b8471fd`; wave 3 → `1a30f5f` (final).

## What each feature added

- **#19 `wf-headers.sh`** — running header/footer and a live footer `PAGE`/`NUMPAGES` field (fully supported, no warning); different-first-page / odd-even parts (fully supported within the verified matrix, no warning); `--restart` is limited and emits the `page-number-restart` warning. Reference `objects/headers-footers.md`.
- **#20 `wf-image.sh`** — inline image placement fully supported; an anchored/floating request is **downgraded** to a centred inline image (risk policy `preferred-unavailable`, `fallback=exists`) and reported; width clamped to the text column. Reference `objects/images.md`.
- **#21 `wf-table.sh`** — fixed-layout tables with explicit `colWidths`/`direct borders`, merged cells (horizontal span + vertical merge), and nested tables under the portable construction (`tblW == Σ colWidths`); the `nested-table` warning fires only when the portable construction cannot be met. Reference `objects/tables.md`; new fixture `tables/merged-table.docx`.
- **#22 `wf-caption.sh`** — figure/table captions on the Caption style with a SEQ field whose cached number is correct and non-placeholder. Reference `fields/captions.md`.
- **#25 `wf-footnote.sh`** — footnotes attached to a paragraph, with `FootnoteText`/`FootnoteReference` defined and applied (added only when absent), no dangling style. Reference `fields/footnotes.md`.
- **#26 `wf-equation.sh`** — inline/display OMML equations (fully supported); the R04 construct-specific risk is enforced — matrices/`m:eqArr` never warn, `\begin{aligned}`/`|` emit the `complex-equation` warning; no image/plain-text fallback (ADR-0001/0002). Reference `objects/equations.md`.
- **#23 `wf-crossref.sh`** — content cross-references using the #12 cached-text mechanism (resolved bookmark text written into the REF result; `w:dirty` cleared); `«target»` can never ship; `--kind pageref` downgrades to a content reference and is reported. Reference `fields/cross-references.md`.
- **#24 `wf-toc.sh`** — a real, updatable TOC field (`TOC \o "1-3" \h \z \u`) with cached heading entries and **no** page numbers and no placeholder; the omission is stated in the change report (#11 mechanism). Reference `fields/table-of-contents.md`.
- **#27 `wf-template.sh`** — adopts the template's look only (style definitions, theme, page/section setup) and never its content (the template's sentinels never appear); the source's content is preserved; a `--requirement` override outranks the template. Reference `core/template-adoption.md`.

## Verification (final `main` @ `1a30f5f`)

- **32 fixtures**; `validate-fixtures` **65/65**; `pipeline` **63/63**; `compat-harness` (real Word/WPS/LibreOffice) **42/42**.
- All unit + feature suites green: style-ownership 35, output-naming 32, page-setup 61, standard-styles 75, intake 91, change-report 61, render-preview 33, risk-policy 132, toc-cache 40, crossref-cache 39, qa 33, skill-discovery 20, headers 52, image 50, table 49, caption 60, footnote 54, equation 49, crossref 45, toc 75, template 56. `shellcheck -S warning` clean.
- Every feature suite drives its capability end-to-end, asserts source protection and reproducibility, and checks LibreOffice repair-free open via the compatibility harness.

## Next

Assemble these capabilities into the two workflows — **#32 generate-from-content** and **#33 tidy-existing-DOCX** — wiring them into `scripts/wf-pipeline.sh` with the D2 precedence and a single change report (this is where the pipeline's stale "template adoption is #27 / not implemented" note gets replaced by a real `wf-template.sh` call), then run **#34** v0.1 acceptance under `scripts/wf-qa.sh`.
