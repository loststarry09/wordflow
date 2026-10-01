# WordFlow — Foundation Hardening Batch: correctness, spec refresh, QA gate

- **Date**: 2026-10-01
- **Method**: orchestrator + parallel sub-agents, one issue per isolated git worktree/branch; the main agent was the sole orchestrator (worktree creation, review, semantic merges, full regression, issue/blocking updates).
- **Outcome**: 8 target issues (`#36`, `#37`, `#31`, `#9`, `#10`, `#11`, `#12`, `#14`) closed, plus 2 discovered bugs (`#38`, `#39`). `main` at `77aadda`, pushed, tree clean.
- **Status**: document features `#19`–`#27` and workflows `#32`/`#33` are **not** built yet. The foundation is complete and an executable QA gate now exists; the batch stopped at the requested stop point.

## 1. Phase 1 — the style-identity bug (#36)

`wf-style-ownership.sh` matched referenced styles against defined styles by **display name only**.
`officecli view stats` references the default style by its **styleId** (`Normal`), while #17 defines it with
the name `正文`, so every standard-style output showed a false dangling `Normal`.

- RED first: added a regression to `tests/style-ownership.sh` using `tests/fixtures/styles/standard-style-set.docx`
  (3 failing checks), then fixed.
- Fix: match each reference against the union of defined **styleIds and names** (`skeys`), mirroring the
  pipeline's D14 check. Real dangling references (e.g. `Caption`) are still detected; the `Normal` default is
  no longer counted as named-in-use.
- Commit `d98c5fc` (merge `5fc6096`); style-ownership **35/35**, standard-styles 75/75, pipeline 63/63,
  validate-fixtures 59/59, shellcheck clean.

## 2. Phase 2 — spec/status refresh (#37) and the two flagged defects

`docs/spec/v0.1.md` §D6/§D8/§D9/§D10/§D11/§D14 + Further Notes/frozen summary, `PROJECT_STATUS.md` §3/§5/§7/§8,
and `references/research/field-recalc-and-cross-app-verification.md` were updated from the #3–#7 measurements;
the published copy (issue #1) was synced. The two defects #37 flagged were split out as their own bugs and fixed.
Commit `0a9b2a1` (merge `d17c331`).

| Decision | Before | After |
|---|---|---|
| `PAGE`/`NUMPAGES` | "unverified"; blanket "the cache is what the reader sees" | **verified per page** (layout-computed); D14 carve-out added |
| Nested tables | limited (untested) | **fully supported**, with the portable construction (`tblW == Σ colWidths`, fixed layout, explicit `colWidths`, direct borders) |
| First-page / odd-even headers | limited (untested) | **fully supported** within the verified matrix; LO 7.6 + multi-section link-to-previous noted unverified |
| Complex equations | limited (untested) | limited but **construct-specific** (matrices/`m:eqArr` faithful; LO-only `\begin{aligned}`/`\|` failures); keep OMML + warn |
| CJK punctuation / kinsoku | untested | application-controlled; no setting required; `charSpacingControl=compressPunctuation` optional guidance, not a default |
| byte-copy | unstated | ADR-0003: copying bytes to make a distinct output file is not a WordFlow DOCX parse/write |

Also fixed, as separate bugs:

- **#38** (`c78cf0e`, `da247c0`): `wf-compat-harness.sh` hangs LibreOffice on a **relative** `--out`
  (`file://` profile URI); now absolutised, with a relative-path regression. Compat harness 42/42.
- **#39** (`6035350`): `tables/fixed-table.docx` had `ΣcolWidths=9000` vs `tblW=5102`; regenerated with
  `colWidths=1701,1701,1700`; MANIFEST and the #4 note updated.

## 3. Phase 3 — foundation wave (#9, #10, #11, #12, #14) + QA gate (#31)

Dispatched five isolated sub-agents in parallel; all merged cleanly (only additive conflicts in the fixture
generator/MANIFEST, resolved semantically).

| Issue | Deliverable | Commit |
|---|---|---|
| `#11` | `references/fields/toc-without-page-numbers.md`, fixture `toc/toc-no-page-numbers.docx`, `tests/toc-cache.sh` | `f3f4ba4` |
| `#12` | `references/fields/cached-cross-references.md`, fixture `fields/cached-cross-ref.docx`, `tests/crossref-cache.sh` | `72b8c57` |
| `#9` | `references/research/large-documents-and-fonts.md`, `tests/probes/large-document.sh` | `1359f41` |
| `#10` | `references/research/version-matrix.md`, `tests/probes/detect-versions.sh` | `ac5b8d7` |
| `#14` | `docs/distribution.md`, `.agents/skills/wordflow/`, `.claude/skills/wordflow/`, `CLAUDE.md`, `tests/skill-discovery.sh` | `f3a658b`, `81b89e3` |
| `#31` | `scripts/wf-qa.sh`, `references/workflow/qa-gate.md`, `tests/qa.sh` | `f06f5ad`, `7877957`, `a09130b` |

`#31` was blocked by `#11`/`#12` (and others already closed), so it started only after they merged.

### #31 — the executable Definition of Done

`scripts/wf-qa.sh` runs the D14 checklist over a delivered document and its artifacts, `pass`/`fail`/`skip` per
item, non-zero if any fails: `schema`, `no-dangling-styles` (styleId OR name), `fields-no-placeholder`
(page-dependent fields exempt), `toc-no-page-numbers`, `report-valid`, `constructs-reported` (no silent
downgrade — codes resolved from the risk policy so the trigger table stays defined once), `preview-covers-output`,
`source-unchanged`, `output-is-new-file`, `collision-safe-name`, `reproducible`, `opens-without-repair` (via the
#2 harness). `tests/qa.sh` covers the clean pass and every defect (dangling, placeholder, numbered TOC, silent
downgrade, wrong preview, source/output/name violations, non-reproducibility) plus per-capability fixture coverage.

## 4. State after the batch

- `main` at `77aadda` (pushed), tree clean; OfficeCLI in this environment is `1.0.153` (baseline `1.0.152`, noted).
- **31 fixtures**; `validate-fixtures` **63/63**; all suites green — style-ownership 35, output-naming 32,
  page-setup 61, standard-styles 75, intake 91, change-report 61, render-preview 33, risk-policy 132, toc-cache 40,
  crossref-cache 39, qa 33, pipeline 63, skill-discovery 20 — `compat-harness` **42/42**, `shellcheck` clean.
- Closed: `#9 #10 #11 #12 #14 #31 #36 #37 #38 #39`.
- Open: `#1` (spec), `#19`–`#27` (features), `#32`/`#33` (workflows), `#34` (acceptance).

## 5. Readiness for feature implementation

Foundation complete + QA gate executable + spec/status consistent with the latest research — the condition to
start `#19`–`#27` is met. Recommended next parallel grouping (dependencies all closed):

1. `#19` headers/footers + page numbers, `#20` images, `#21` tables, `#22` captions, `#25` footnotes, `#26` equations.
2. `#23` cross-references and `#24` TOC (now unblocked by the #12/#11 cache mechanisms they depend on).
3. `#27` template adoption (leans on #16/#17, now with the #36 fix).
4. Then `#31` gate green per feature, and `#32`/`#33`/`#34`.
