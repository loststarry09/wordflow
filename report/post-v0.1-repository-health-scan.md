# WordFlow v0.1.0 — Post-Release Repository Health Scan

- **Date:** 2026-10-02
- **Scope:** read-only scan of `~/projects/wordflow` at tag `v0.1.0` (HEAD `a7599bd`)
- **Method:** read the required docs, read every `scripts/wf-*.sh` and `tests/*.sh`, and
  empirically reproduced the highest-severity findings on scratch copies in `/tmp/opencode`
  (no repo file was modified). Empirical results are marked **[REPRO]**; static evidence
  marked **[READ]**.
- **Verdict:** v0.1.0 is coherent and unusually well-documented, but it has **two confirmed
  source-protection/report-integrity defects** and several silent-misreport paths that
  contradict the project's own Definition of Done. The test suite is large but has a
  systematic blind spot: many checks read the tool's *own* JSON rather than independent
  evidence, and the Word/WPS half of the compatibility promise is skipped, not enforced.

---

## 1. Architecture & test coverage summary

**Architecture (as implemented).** 21 executable `scripts/wf-*.sh` form a clean layering:

- **Orchestration:** `wf-pipeline.sh` (764 lines) composes everything; it reimplements no
  feature. Exit codes `0` delivered · `1` runtime · `2` usage/dependency · `3` stop-and-ask.
- **Cross-cutting contracts:** `wf-intake.sh` (precedence + job plan + source hash),
  `wf-change-report.sh` (one 5-area report), `wf-risk-policy.sh` (one D11 trigger table),
  `wf-qa.sh` (D14 gate).
- **Capabilities:** `wf-style-ownership`, `wf-standard-styles`, `wf-tidy`, `wf-page-setup`,
  `wf-template`, `wf-headers`, `wf-image`, `wf-table`, `wf-caption`, `wf-crossref`, `wf-toc`,
  `wf-footnote`, `wf-equation`, `wf-output-name`, `wf-render-preview`, `wf-compat-harness`.
- **Invariant honored in the main path:** every capability copies the source bytes to `--out`
  and mutates only the copy through OfficeCLI; the byte copy is treated as non-DOCX.
- **Single execution layer:** OfficeCLI `1.0.153` on this host; LibreOffice `soffice` +
  `pdftoppm` are required for the default preview.

**Test coverage.** 28 `tests/*.sh` files (27 "suites" + `generate-fixtures.sh`). Claimed
**1,495 checks / 27 suites** (`PROJECT_STATUS.md:147-150`). All tools are present on this
host, so the suite is runnable. Coverage is broad on the happy path and per-feature, and
`acceptance.sh` genuinely ties the workflows together. Weak spots:

- Strong unit coverage of *contract* tools (`risk-policy`, `change-report`, `output-naming`,
  `intake`).
- Feature suites assert final state externally (good) but often *also* trust the tool's own
  `.evidence` block.
- The end-to-end acceptance and workflow suites run with `--no-compat` and LibreOffice-only;
  **Microsoft Word / WPS are only exercised (and skippable) in `compat-harness.sh`**.

---

## 2. Top 10 weak points

Severity: **H** = data-loss / silent wrongness; **M** = correctness/report risk; **L** = hygiene.

| # | Weak point | Evidence | Sev | Test? |
|---|---|---|---|---|
| 1 | `wf-headers.sh` and `wf-footnote.sh` accept `--report <path>` with no guard against the source; `--report <source>.docx` **overwrites the source with report JSON**. | `scripts/wf-headers.sh:112-114,131-136,149`; `scripts/wf-footnote.sh:109-110,128-131,146` **[REPRO]** | H | No (tests only `--out == source`) |
| 2 | `wf-standard-styles.sh` blindly `add`s every non-`Normal` standard style, so it **fails (exit 1) on any document that already defines a standard styleId** — the rebuild path and re-runs are not idempotent. | `scripts/wf-standard-styles.sh:116-120,144-147` vs `:125-133` **[REPRO]** | H | No |
| 3 | `wf-table.sh` only validates `--width` vs `--col-widths` from the *requested* values; OfficeCLI can silently pad/merge columns, producing `tblW != ΣcolWidths`, yet the script exits 0 and **reports the opposite** ("tblW == sum(colWidths)"). | `scripts/wf-table.sh:212-224,227-230,355-364,416` **[REPRO]** | H | No |
| 4 | `wf-crossref.sh` clears `w:dirty` on **every** `fldChar begin` in `/document`, not just the new REF — silently un-dirties unrelated stale fields (the exact "stale cache shown as finished" failure D14 exists to prevent). | `scripts/wf-crossref.sh:173-175` **[READ]** | H/M | No |
| 5 | `wf-qa.sh` "every limited construction is reported" only detects `floating-image`, `nested-table`, `page-number-restart`; it does **not** detect `columns`, `complex-equation`, or `first-odd-even-headers`. | `scripts/wf-qa.sh:186-194` vs `references/workflow/qa-gate.md:16` **[READ]** | M | No |
| 6 | The end-to-end acceptance's "preview produced" check counts a JSON array length, not files on disk; top-level QA is `--no-compat`, so **Word/WPS repair-free is never proven by the main acceptance**. | `tests/acceptance.sh:137-138,254`; `tests/compat-harness.sh:141-146` **[READ]** | M | Weak |
| 7 | Report-path guards are inconsistent across tools (template/tidy/caption/crossref/table/toc guard; headers/footnote do not; `wf-render-preview --report` writes to an arbitrary path). | `scripts/wf-headers.sh`, `scripts/wf-footnote.sh` vs `scripts/wf-template.sh:114-118` **[READ]** | M | No |
| 8 | Many feature scripts parse OfficeCLI *human-readable* strings (`Added footnote at …`, `Added equation at …`, `… at /body/p[n]`) with `sed`/`capture`, not a structured JSON path. | `wf-footnote.sh:207-208`; `wf-equation.sh:164`; `wf-caption.sh:190`; `wf-toc.sh:203` **[READ]** | M | No |
| 9 | Output-name reservation is TOCTOU: `free_name` probes the filesystem, then the pipeline writes minutes later in `wf-pipeline.sh:658`; no `O_EXCL`/lock. Concurrent batch runs can collide. | `scripts/wf-output-name.sh:105-120`; `scripts/wf-pipeline.sh:658` **[READ]** | M | No |
| 10 | Source/output equality is string-compared with logical `abs()`, not `realpath`; a symlink/hardlink `--out` bypasses the ADR-0003 guard and relies on `cp`'s same-inode detection (implementation detail). | `scripts/wf-headers.sh:123-127`; `wf-template.sh:107`; `wf-standard-styles.sh:79` **[READ]** | L/M | No |

---

## 3. Top 10 tests most worth adding

Each maps to a concrete, currently-unverified behaviour.

1. **Source-protection negative matrix (H).** For every `wf-*.sh` that takes `--report`
   and/or `--out`, assert that `--report <src>` and `--out <src>` leave the source byte-identical.
   Start with `wf-headers.sh` and `wf-footnote.sh` (proven failures).
2. **`wf-standard-styles.sh` idempotency (H).** Feed it `tests/fixtures/styles/standard-style-set.docx`
   and then its own output; assert exit 0 and no duplicate-style error.
3. **Outer-table `tblW == ΣcolWidths` read-back (H).** Same shape as the nested assertion,
   but for the outer table: assert observed `width` equals the sum of observed `colWidths` for
   matched and mismatched `--data`/`--col-widths`.
4. **Ragged / special-character table data (M).** `--data 'a,b;c'` and `--data 'Smith, John'`;
   assert exit 2 (or an explicit reported downgrade), never a silently ragged table.
5. **`w:dirty` isolation for cross-refs (M).** Build a doc with a pre-existing dirty field,
   run `wf-crossref.sh`, assert the unrelated field is still dirty and the new REF is clean.
6. **QA constructs-reported completeness (M).** Fixtures with `columns>1`, an aligned/complex
   equation, and odd/even headers; assert `wf-qa.sh constructs-reported` fails when the
   corresponding risk entry is absent from the report.
7. **Real preview artifact existence (M).** Acceptance should `test -s` every path in
   `.preview.artifacts`, not just count the array.
8. **Concurrent output naming (M).** Launch two `wf-pipeline.sh` runs with identical inputs
   simultaneously; assert two distinct outputs (or an explicit lock/refusal), never a collision.
9. **Symlink/hardlink `--out == source` (M).** `ln -s src out` then run each capability; assert
   exit 2 (clean usage error), not a `cp` same-file failure or a silent success.
10. **Word/WPS not-skipped gate (M).** A test that fails (not skips) when Word/WPS are required
    but unavailable, so a host without them cannot report the D10 promise as verified.

---

## 4. Top 10 most likely bug locations

Ranked by combination of likelihood × impact.

1. **`scripts/wf-headers.sh:149` + `scripts/wf-footnote.sh:146`** — source destruction via
   `--report`. **Confirmed.** [REPRO]
2. **`scripts/wf-standard-styles.sh:144-238`** — duplicate-style add; rebuild path crashes on
   already-standard documents. **Confirmed.** [REPRO]
3. **`scripts/wf-table.sh:212-224` / `:416`** — width guard checks requested values only;
   silent non-portable outer table + false portability claim. **Confirmed.** [REPRO]
4. **`scripts/wf-crossref.sh:173-175`** — global `w:dirty` strip. **Static, high confidence.**
5. **`scripts/wf-qa.sh:186-194`** — incomplete limited-construct detection.
6. **`scripts/wf-image.sh:112-115,161,175`** — `awk printf "%.4f"` under a comma-decimal
   `LC_NUMERIC` yields e.g. `3,0000cm` passed straight into `--prop width=`.
7. **`scripts/wf-table.sh:366-370,417-422`** — header/merge read-back recorded but not
   enforced; report asserts success unconditionally.
8. **`scripts/wf-footnote.sh:207-215` / `wf-equation.sh:164-172`** — fallback to "max id /
   last equation" can validate a pre-existing node, masking a failed add.
9. **`scripts/wf-template.sh:261-263`** — orientation forced to portrait when the template's
   section exposes no explicit `orientation` key (landscape encoded via width>height flips).
10. **`scripts/wf-pipeline.sh:290-292`** — stale comment claiming `wf-style-ownership` matches
    display names only (defect #36 fixed it); misleading for future maintainers.

---

## 5. Most dangerous real-world usage scenarios

Targeted at the real inputs the spec names: course reports, lab reports, project proposals,
legacy `.docx`.

1. **"Tidy my existing report" with a careless `--report` path.** A user runs
   `wf-headers.sh my-report.docx --out my-report-排版.docx --report my-report.docx` (plausible
   because the flag looks like "name the report after my file") and **loses the source** —
   violation of the single most-emphasized promise (ADR-0003). Confirmed for `headers` and
   `footnote`. [REPRO]
2. **Legacy/styled template documents routed to `rebuild-with-standard-styles`.** Old school
   or journal templates often already define `BodyNoIndent`/`Heading1`/… with standard IDs but
   are classified "no named styles"; `wf-standard-styles.sh` then aborts mid-run (partial
   output). The job fails or, worse, a caller that ignores the exit code keeps a partially
   restyled file.
3. **Pasting a data table from a spreadsheet.** `--table-data 'Name, Score; Smith, John, 88'`
   (commas inside a cell) or a column-count/width mismatch produces a **silently
   non-portable** table while the change report affirms portability — exactly the "looks
   right here, breaks in the reviewer's Word" failure the project targets.
4. **Editing a document that already has a TOC/REF with a stale cache.** `wf-crossref.sh`
   clears `w:dirty` globally, so Word/WPS will no longer prompt F9 and will display the old
   cached value as final. Silent stale field shipped.
5. **Complex/legacy documents with floating images or `\begin{aligned}` equations on a
   grading machine.** The downgrade/warn path is correct in isolation, but the end-to-end
   acceptance never opens these in Word/WPS on the reference host (only LibreOffice), and the
   compat harness *skips* when the apps are absent — so a WPS-only reviewer may see a
   different layout than the "12/12 repair-free" headline suggests.
6. **A grading/submission machine without SimSun/SimHei.** The promised "good Chinese layout
   by default" renders through OS substitution; the report marks it unverified but the user
   often never reads it. No script detects host font availability (`references/core/styles.md`
   admits substitution is not detected).

---

## 6. Environment / portability risks

The toolchain is **GNU/Linux + WSL-first**; several documented "requirements" are incomplete.

**GNU-only / macOS-BSD breakage [READ]:**
- `readlink -f` (`wf-render-preview.sh:107`), `sha256sum` (16 scripts), GNU `timeout` (all 18
  scripts, never dependency-checked), `stat -c`, `sort -z` (`wf-compat-harness.sh:165,189`;
  `tests/validate-fixtures.sh:73`), `sed -i` without backup (`tests/intake.sh:272`), `flock`
  (util-linux; tests/probes).
- Bash ≥4 only: `mapfile`, `declare -A`, `${var^^}`/`${var,,}`. macOS default bash is 3.2.
- `find -maxdepth` (`wf-render-preview.sh:207`).

**WSL/Windows coupling [READ]:** hardcoded
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`, `tasklist.exe`, staging under
`/mnt/c/temp`, COM ProgIDs `Word.Application`/`KWPS.Application`, `/mnt/<drive>` mapping
(`wf-compat-harness.sh:56-58,225-249,449,596-604`; several tests). Degrades to `unavailable`
off WSL, but Word/WPS evidence is only reproducible in WSL+Windows.

**Locale [READ]:** only `wf-render-preview.sh:207` pins `LC_ALL=C`. `awk` `printf "%.4f"`
is `LC_NUMERIC`-sensitive (`wf-image.sh:112-115,161`) — comma-decimal locales corrupt the width
string. No script forces a locale.

**Fonts [READ]:** fonts are written by name only (`wf-standard-styles.sh:86-89`,
`wf-tidy.sh:81-82`); no host-font probe, yet `tests/standard-styles.sh:193-194` compares rendered
glyph metrics via `pdftotext -bbox`, making those checks host-font-dependent.

**Dependencies vs docs [READ]:** `README.md:66-67` says only OfficeCLI is required ("no Office
install needed"), but the default pipeline **hard-requires LibreOffice + poppler**
(`wf-pipeline.sh:272-276` exits 2 without `soffice`/`pdftoppm`); `docs/distribution.md` never
mentions them. No script enforces the documented OfficeCLI `>= 1.0.152`; a version check is
absent (`command -v officecli` only).

**Version drift [READ]:** `tests/fixtures/MANIFEST.md:3` pins 1.0.152; `PROJECT_STATUS.md:9,11`
says 1.0.153; the fixture header is stale.

---

## 7. Documentation vs implementation inconsistencies

| Doc claim | Reality | Evidence |
|---|---|---|
| "the existing **29** single-feature fixtures" | 32 fixtures on disk | `docs/spec/v0.1.md:426` vs `find` = 32 |
| "**27 suites**" / 1,495 checks | 28 `tests/*.sh` (27 suites + generator, but `tests/README.md:12-27` lists 28 and doesn't name the excluded one) | `PROJECT_STATUS.md:150` vs `ls tests/*.sh` |
| Fixtures checked against OfficeCLI **1.0.152** | Verified tooling 1.0.153 | `tests/fixtures/MANIFEST.md:3` vs `PROJECT_STATUS.md:9` |
| QA gate reports "**every** limited construction" | Detects only 3 of 6 limited triggers | `references/workflow/qa-gate.md:16` vs `wf-qa.sh:186-194` |
| QA doc says `toc-no-page-numbers` checks `\z` | Gate checks only `pageNumbers==false` + absence of `\n`; `\z` is enforced only in `wf-toc.sh:277` | `references/workflow/qa-gate.md:14` vs `wf-qa.sh:165-169` |
| Risk policy lists `first-odd-even-headers` as **warn** | Spec/status say first-page & odd/even headers are **fully supported, no warning**; the trigger is never emitted by any script | `wf-risk-policy.sh:73-77` vs `docs/spec/v0.1.md:303-304`; grep finds no emit |
| `wf-pipeline.sh` comment: `wf-style-ownership` "matches display names only" | It matches styleId **or** name (defect #36 fixed) | `wf-pipeline.sh:290-292` vs `wf-style-ownership.sh:98-114` |
| `references/core/style-ownership.md` says matching is "by name" only | Code matches styleId OR name | `references/core/style-ownership.md:101-103` vs `wf-style-ownership.sh:98-114` |
| `references/objects/tables.md:54` example: `colWidths=1701,1701` with `width=9cm` | `Σ=3402 twips ≈ 6 cm ≠ 9 cm`, violating the doc's own `tblW == ΣcolWidths` rule | `references/objects/tables.md:29-33,54` vs `MANIFEST.md:57` |
| ADR-0001: "**Every** read and write of a `.docx` is performed by OfficeCLI" | Preview and compat harness read the DOCX via LibreOffice/COM | `docs/adr/0001-…md:3` vs `wf-render-preview.sh:185-207` (reference doc admits the exception) |
| `README.md` testing block lists 6 suites / 1,495 checks | `tests/README.md` lists 28 scripts; `validate-fixtures.sh` logs `view issues` but never asserts it | `README.md:80-90` vs `tests/README.md:12-27`; `tests/validate-fixtures.sh:49-51` |

---

## 8. If tonight only has limited tokens: 3 highest-value actions

1. **Close the source-destruction hole (H, ~30 min).** Land a shared `--report`/`--out`
   guard in `wf-headers.sh` and `wf-footnote.sh` (mirror `wf-template.sh:114-118`), plus the
   negative-matrix test. This is a direct ADR-0003 violation and the single worst finding.
2. **Enforce the outer-table portability invariant on read-back (H, ~30 min).** In
   `wf-table.sh`, after building, compare observed `width` to `sum(observed colWidths)` for the
   outer table (as already done for the nested table) and fail/report honestly instead of
   asserting `tblW == ΣcolWidths`. Add the mismatch test.
3. **Make `wf-standard-styles.sh` idempotent (H, ~30 min).** Check each styleId's existence
   before `add` (like the `Normal` branch) so rebuild and re-runs don't abort; add the
   `standard-style-set.docx` idempotency test. This unblocks the entire tidy/rebuild path on
   real world documents that already use standard style IDs.

**Runner-up (if a 4th is possible):** make `wf-qa.sh constructs-reported` cover `columns`,
`complex-equation`, and `first-odd-even-headers`, or narrow the doc claim — the current gate
can pass an output that silently ships a limited construct.

---

## Appendix — reproduced evidence log

Scratch dir `/tmp/opencode/wfverify` (repo untouched):

- `wf-headers.sh src.docx --out out.docx --header HDR --report src.docx`
  → source sha256 changed; `file` reports `JSON text data`; **SOURCE_DESTROYED**.
- `wf-footnote.sh src.docx --out out.docx --text x --report src.docx`
  → **SOURCE_DESTROYED** (`JSON text data`).
- `wf-standard-styles.sh tests/fixtures/styles/standard-style-set.docx --out ss-out.docx`
  → `Error: Style 'BodyNoIndent' already exists…`, exit 1.
- `wf-table.sh src2.docx --out tbl.docx --data 'A,B,C;1,2,3' --col-widths 1000,1000 --width 2000`
  → exit 0; report prints `Table portability: … tblW == sum(colWidths)` while OfficeCLI
  observed `colWidths=1000,1000,2400` against requested `width=2000` (mismatch, unreported).
- `officecli query tests/.out/acceptance/generate-full/content-排版.docx field/toc --json`
  → `field.matches=5, results=5`; `toc.matches=1, results=1` (query shape is consistent, so
  the mixed `.matches`/`.results` usage is not itself a bug).
- Host check: `officecli 1.0.153`, `soffice`, `pdftoppm`, `pdfinfo`, `flock`, `shellcheck 0.9.0`
  present; `LANG=C.UTF-8`; no `de_DE`/`fr_FR` locale installed (comma-decimal bug not
  reproducible here, valid in principle).

No files in the repository were modified by this scan.
