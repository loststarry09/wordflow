# WordFlow — Parallel Implementation Batch: Walking Skeleton

- **Date**: 2026-10-01
- **Method**: orchestrated parallel sub-agents, each in an isolated git worktree/branch, one GitHub issue per agent; the main agent was the sole orchestrator (dependency checks, worktree creation, assignment, review, merge, full regression, issue/blocking updates).
- **Outcome**: foundation + walking skeleton + first cross-application research wave delivered. 15 issues closed; 2 follow-ups opened. `main` at `409230e`, pushed.
- **Status**: features `#19`–`#27` and workflows `#32`/`#33` are **not** built yet. Spec/status changes from research are **not** applied silently (tracked in `#37`).

## 1. Scope and goal

Drive a batch that takes WordFlow from "spec frozen" to "first real vertical slice":

- Build the foundation and cross-cutting contracts in parallel, then compose them.
- Reach **`#35` Walking Skeleton** (single-document end-to-end pipeline).
- Run the first compatibility research wave (`#3`–`#7`) against the `#2` harness.
- Do not skip blockers or lower acceptance bars. Correctness, isolation, review, and rollback safety outrank speed.

## 2. Method

- **Isolation**: one `git worktree` per issue, branches `issue/<n>-<slug>`; no two agents share a working tree; agents never merge or push.
- **Dependency gating**: an agent starts only when every `blocked_by` issue is closed. The batch was run in waves so newly-unblocked work starts without waiting for the whole wave.
- **Interface freezing**: the orchestrator froze the cross-cutting contracts in the agent briefs (change-report JSON + CLI, risk-event shape, intake job-plan) so sibling tickets could build in parallel without divergence.
- **Review before merge**: each result checked for ticket scope, spec conformance, unrelated diff, OfficeCLI re-implementation, real test coverage, and new runtime dependencies. All merges used `--no-ff` to preserve the reported feature commit hashes.
- **Regression after every merge**: unit suites, `validate-fixtures`, `compat-harness`, `shellcheck`.
- **Concurrency control**: the `#2` harness and every Word/WPS COM call were serialized with `flock`; LibreOffice runs use isolated user profiles.

## 3. Waves and results

### Wave 1 — foundation (5 agents in parallel)

| Issue | Deliverable | Commit |
|---|---|---|
| `#2` | `scripts/wf-compat-harness.sh` + `references/compatibility/harness.md` + `tests/compat-harness.sh` | `6eee1e1` |
| `#8` | `references/research/cjk-font-availability.md` | `43c2845` |
| `#13` | `scripts/wf-output-name.sh` + `references/core/output-naming.md` + tests | `abb4379` |
| `#18` | `scripts/wf-page-setup.sh` + `references/core/sections.md` + fixture + tests | `3637b64` |
| `#28` | `scripts/wf-change-report.sh` + `references/workflow/change-report.md` + tests | `2313c49` |

### Wave 1b / 2 — contracts + cores (5 agents, started as blockers closed)

| Issue | Deliverable | Commit |
|---|---|---|
| `#15` | `scripts/wf-intake.sh` + `references/core/intake.md` + tests | `6f1ad90` |
| `#17` | `scripts/wf-standard-styles.sh` + `references/core/styles.md` + fixture + tests | `3b05d23` |
| `#29` | `scripts/wf-render-preview.sh` + `references/workflow/render-preview.md` + tests | `3479004` |
| `#30` | `scripts/wf-risk-policy.sh` + `references/workflow/risk-policy.md` + tests | `93585df` |

`#29`/`#30` were sequenced after `#28` merged so they consumed the real change-report contract rather than a guessed one (a deliberate correctness-over-parallelism choice).

### Wave 3 — walking skeleton + research (6 agents in parallel)

| Issue | Deliverable | Commit |
|---|---|---|
| `#35` | `scripts/wf-pipeline.sh` + `references/workflow/pipeline.md` + tests | `fcdee01` |
| `#3` | multi-page fixture + `references/research/multipage-page-fields.md` | `64fd91b` |
| `#4` | nested-table fixture + `references/research/nested-tables.md` | `3a54b39` |
| `#5` | first-page/odd-even fixture + `references/research/firstpage-oddeven-headers.md` | `6f7c548` |
| `#6` | 4 equation fixtures + `references/research/complex-equations.md` | `ec0efda` |
| `#7` | CJK punctuation fixture + `references/research/cjk-punctuation.md` | `c0b23bb` |

Two orchestrator commits followed: `87dca06` (silence intentional CJK-quote shellcheck warnings in the fixture generator) and `409230e` (project-status/index refresh).

## 4. Research findings (`#3`–`#7`)

- **`#3` Multi-page page numbers.** Footer `PAGE`/`NUMPAGES` render the correct number per page in Word/WPS/LibreOffice **without F9**, even with a stale cache (proved with `fldLock=true`). Conclusion: footer page numbers are **safe to ship**; PAGEREF/TOC page numbers stay limited/omitted.
- **`#4` Nested tables.** All three open repair-free and render faithfully (fixed layout, explicit `colWidths`, direct borders; `tblW` must equal Σ`colWidths`). Recommendation: **promote** to fully supported.
- **`#5` First-page / odd-even headers.** Portable across Word 16 / WPS 12 / LibreOffice 24.2 (FIRST/EVEN/ODD/EVEN identical). Recommendation: promote out of the limited tier (LO 7.6 and multi-section link-to-previous untested).
- **`#6` Complex equations.** Matrices and `m:eqArr` are faithful in all three; failures are LibreOffice-only and narrow (parser `\begin{aligned}`, the `|` character). Recommendation: **keep OMML + warn** (image/plain-text fallbacks conflict with ADR-0001/0002).
- **`#7` CJK punctuation / kinsoku.** Zero forbidden-boundary lines in all three; the behaviour is application-controlled and WordFlow need not set anything. Optional low-risk default for `#17`: `charSpacingControl=compressPunctuation`.

## 5. Frozen assumptions — confirmed and challenged

- **Confirmed**: the spec §D6 Chinese font strategy (`#8`); `-排版` naming safe and non-localised (`#13`); §D9 principle "never present a page number it cannot guarantee" (`#3`).
- **Challenged**: `PROJECT_STATUS.md` §5 / `field-recalc-and-cross-app-verification.md` §3–4 claim that "no application updates fields on its own; the cached result is what the reader sees" — false for **page-dependent** fields (`PAGE`/`NUMPAGES`, unlocked `PAGEREF`).
- **Challenged**: spec §D8/§D9/§D10 list nested tables, first-page/odd-even headers, and complex-equation items as limited/untested; measurement shows the first two are faithful and the third is construct-specific.

All spec/status impacts are recorded in **`#37`** rather than edited silently.

## 6. Test and regression evidence (main)

- Per-capability suites: `style-ownership 28/28`, `output-naming 32/32`, `page-setup 61/61`, `standard-styles 75/75`, `intake 91/91`, `change-report 61/61`, `render-preview 33/33`, `risk-policy 132/132`, `compat-harness 39/39`, `pipeline 63/63`.
- `tests/validate-fixtures.sh`: **59 checks | 59 passed** across **29 fixtures**.
- `shellcheck -S warning`: clean.
- `compat-harness` is a real run: Word 16 via COM, WPS 12 via COM, LibreOffice 24.2 headless.

## 7. Walking skeleton (`#35`) — real end-to-end result

One run executes: intake/inspect → style-ownership decision → apply (`wf-page-setup.sh`; rebuild adds `wf-standard-styles.sh`) → **new** collision-safe output → `officecli validate` → preview of the final output → five-area change report → risk hooks → deliver.

Artifacts (git-ignored, `tests/.out/walking-skeleton/`):

- **rebuild**: `rebuild/input-unstyled.docx` → `rebuild/unstyled-排版.docx`, `unstyled-排版-preview-1.png`, `unstyled-排版-report.{json,md}`; a second run yields `unstyled-排版 (2).docx`.
- **preserve**: `preserve/heading-hierarchy-排版.docx` + preview + report.
- **risk**: `risk/anchored-image-排版.docx` + report containing `[D11-floating-image]`.
- **stop**: `stop/broken.docx` → no output, no report (exit 3).
- **reproducibility**: `repro1/` and `repro2/` identical.

Verified: source `sha256` unchanged, output is a new file with default naming + collision numbering, decisions listed, preview covers the final output, at least one warn + one stop path exercised, run reproducible, D14 DoD green for scope.

## 8. Follow-ups and open work

- **`#36` (bug, ready-for-agent)**: `wf-style-ownership.sh` matches referenced styles by display name only; it reports false dangling `Normal` on `#17` output (should match `styleId` **or** name).
- **`#37` (decision, ready-for-human)**: spec/status refresh from the research findings, including the harness relative-`--out` LibreOffice hang and the `fixed-table.docx` `tblW`/`colWidths` mismatch.
- **Not built**: `#19`–`#27` features, `#31` QA DoD, `#32`/`#33` workflows, `#34` acceptance; `#9`–`#12`, `#14` foundations.
- Recorded upstream gaps: no tidy capability (dangling-style repair); template adoption and formatting-requirement application are parsed but not applied.

## 9. Architecture assessment

- No rework required. The layering held: WordFlow judgement/scripts + OfficeCLI as the only DOCX reader/writer.
- The four cross-cutting contracts (intake job plan, change report, risk policy, pipeline) composed cleanly.
- `#36` is a genuine correctness defect in a foundation tool and should be fixed before feature work leans on it.
- New-files are produced by byte-copying the source and then mutating the copy through OfficeCLI (page-setup, standard-styles, pipeline). This is a deliberate reading of ADR-0001 ("copying bytes is not a DOCX read/write"); worth a one-line ADR/spec note.

## 10. Process notes

- The batch (15 issues) merged with only additive conflicts in `tests/generate-fixtures.sh` / `MANIFEST.md`, resolved without dropping any side.
- One agent (`#2`) was interrupted and re-dispatched; no partial work was merged.
- `#17`'s WPS verification was completed by the orchestrator with the `#2` harness after the fact (the sub-agent's probe mis-reported WPS as not installed).

## 11. State after the batch

- `main` at `409230e` (pushed), working tree clean.
- 29 DOCX fixtures; 11 `scripts/wf-*.sh` capabilities; 20 reference docs across `core/`, `workflow/`, `compatibility/`, `research/`.
- Closed: `#2 #3 #4 #5 #6 #7 #8 #13 #15 #17 #18 #28 #29 #30 #35`.
- Open: `#1 #9 #10 #11 #12 #14 #19`–`#27 #31`–`#34 #36 #37`.
