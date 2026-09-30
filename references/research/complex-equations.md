# Complex equation portability and downgrade target

Empirically measured behaviour of complex OMML — matrices and equation arrays / multi-line aligned
equations — in Microsoft Word, WPS Writer, and LibreOffice Writer, and the resulting recommendation
for what to do when such an equation is not faithful. This is a **facts** file, not product guidance.
It extends the simple inline/display measurement in
[`field-recalc-and-cross-app-verification.md`](./field-recalc-and-cross-app-verification.md) §7.

Legend:
- **[V]** — verified by running the tools locally (versions below).
- **[S]** — backed by the OOXML / ECMA-376 standard or a primary-source document.
- **[?]** — reported elsewhere but not confirmed here.

## Method

- **OfficeCLI** `1.0.152` on Linux (WSL); formula syntax discovered with `officecli help docx equation`
  and by probing the `FormulaParser` (`\begin{env}` with `&` column and `\\` row separators).
- **Microsoft Word** `16.0` and **WPS Writer** `12.0` driven by COM through
  `scripts/wf-compat-harness.sh` (opened read-only, exported to PDF, then `pdftoppm` to PNG).
- **LibreOffice** `24.2.7.2` headless with an isolated user profile, same harness.
- Fixtures: the four new `equations/*` fixtures committed for #6 (`matrix-equation.docx`,
  `aligned-equations.docx`, `cases-equation.docx`, `equation-array.docx`) plus the existing
  `display-equation.docx` / `inline-equation.docx` as the simple baseline.
- Artifacts (git-ignored): `tests/.out/compat/issue6-win/` (Word/WPS), `tests/.out/compat/issue6-lo/`
  (LibreOffice). Each directory holds `result.json`, per-app PDFs and PNGs, and an `officecli.png`
  baseline.
- **Text-extraction caveat:** `pdftotext` does **not** decode the WPS math font (every math glyph
  comes out as `�`), so WPS fidelity is judged from the rendered PNG, not the text layer. Word and
  LibreOffice text layers are readable. A PNG/PDF visual, not `pdftotext`, is the fidelity evidence.

## 1. What OfficeCLI's FormulaParser produces

- **[V]** `\begin{matrix}`, `\begin{pmatrix}`, `\begin{bmatrix}`, `\begin{vmatrix}` all parse. The
  bare `matrix` becomes `m:m` (matrix, `m:mr` rows of `m:e` cells); the delimited forms wrap it in
  `m:d` (delimiter) with the matching `m:begChr`/`m:endChr`.
- **[V]** `\begin{cases}` becomes `m:d` with `m:begChr={`, an **empty** `m:endChr`, wrapping a
  two-column `m:m` (each column `m:mcJc=left`).
- **[V]** `\begin{aligned}`, `\begin{align}`, and `\begin{align*}` all become an `m:m` with a
  two-column `m:mcs` (column 1 `mcJc=right`, column 2 `mcJc=left`) — **not** an `m:eqArr`. The `&`
  alignment point is approximated by the right/left column pair; no alignment marker is stored.
- **[V]** The parser **never emits `m:eqArr`** (the OMML equation-array element). A true equation
  array is produced only with `raw-set`, replacing `//m:oMath` with an `m:eqArr` fragment whose
  `m:e` children are the lines. `officecli validate` passes on the result.
- **[V]** Also parse: `\frac`, `\sqrt`, `\sum`/`\int` with limits, `\left(…\right)`, `\binom`,
  `\hat`, `\vec`, `\overbrace`, `\substack`, `\text`.

Reproducible construction (the committed fixtures): `tests/generate-fixtures.sh` §`equations/`.
Matrices/aligned/cases use `--prop 'formula=\begin{env}…'` (single-quoted so `\\` stays a row
separator); the equation array uses `officecli raw-set <f> /document --xpath '//m:oMath' --action
replace --xml '<m:oMath><m:eqArr>…</m:eqArr></m:oMath>'`.

## 2. Per-application fidelity

All six equation fixtures **open without a repair prompt** and pass `officecli validate` in **all
three** applications (`opens_without_repair=true`, `schema_valid=true`, one page each). Fidelity of
the rendered equation differs:

| Construct | Word 16 | WPS 12 | LibreOffice 24.2 | OfficeCLI baseline |
|---|---|---|---|---|
| simple inline / display (`E = mc²`, `a/b = c`) | faithful | faithful | faithful | faithful |
| matrix (`\begin{bmatrix}` 3×3 → `m:d`+`m:m`) | faithful | faithful | **faithful** | faithful |
| equation array (`m:eqArr`, via `raw-set`) | faithful | faithful | **faithful** | faithful |
| aligned (`\begin{aligned}` → `m:m`) | faithful | faithful | **NOT faithful** — each `=` renders as `¿` | faithful |
| cases with a leading absolute value (`\|x\| = …`) | faithful | faithful | **NOT faithful** — `\|x\| =` renders as `¿ x ∨ ¿`, rows reorder | faithful |
| cases **without** a leading `\|…\|` (probe) | (untested) | (untested) | **faithful** | faithful |

- **[V]** Matrices, equation arrays, and simple equations are faithful in all three applications —
  the bracket/brace delimiters, the row/column layout, and superscripts all render as intended.
- **[V]** LibreOffice is the **only** application that fails, and only on two constructs: the
  parser's `\begin{aligned}` output and any equation containing the absolute-value bar `|`.
- **[V]** Word and WPS render **all** measured constructs faithfully, including the two LibreOffice
  failures (verified in the PNGs and, for Word, the text layer).

## 3. Root cause — the LibreOffice failures are narrow

LibreOffice imports OMML by converting it to its own StarMath; StarMath uses `¿`/`¡` as
"missing-operand" markers. Two isolation probes pin the cause:

- **[V]** `|` (U+007C) is mangled by LibreOffice **wherever it appears**, including inside a single
  `m:eqArr` run (`|x| = 5` → `¿ x∨¿ 5`). It is the **character**, not the surrounding structure.
- **[V]** The parser's `\begin{aligned}` output splits the operator so that `= a` becomes the
  **base of a superscript** (`m:sSup` with `m:sup=2`). StarMath reads a leading binary `=` with no
  left operand and emits `¿`. A hand-built `m:m` whose cells hold a whole line as one run
  (`a = b`) renders faithfully, and `\begin{cases}` **without** a leading `|…|` renders faithfully.
- **[V] Consequence:** these are (a) a LibreOffice character limitation (`|`) and (b) an OfficeCLI
  `FormulaParser` run-splitting artifact, **not** an inherent limitation of OMML matrices or
  equation arrays. Both are repairable at construction time (see §5).

## 4. Downgrade target

The candidates are keep OMML, image, and plain text.

- **Image — ruled out.** WordFlow has no renderer (ADR-0001: OfficeCLI is the only execution layer;
  OfficeCLI has no equation→image operation), and inserting a rendered image would be authoring
  content (ADR-0002). An image downgrade is not available to WordFlow.
- **Plain text — last resort only.** It is producible but destroys the mathematical layout and is a
  content change, which ADR-0002 forbids without an explicit request and per-item confirmation
  (CONTEXT: *Restructure* is never automatic).
- **Keep OMML — the recommendation.** Measured faithful for matrices, equation arrays, cases
  without bars, and all simple equations; the only failures are LibreOffice-only and narrow.

**[V] Recommendation: the downgrade target is _keep OMML_ — do not replace the equation.**
When a complex equation is not faithful, WordFlow keeps the OMML unchanged and **warns**; it does
not silently swap in an image or plain text. Reasons, in order: (1) the hard gate passes everywhere
and the measured failures are limited to LibreOffice on two specific encodings; (2) no faithful
image path exists (no renderer); (3) the failures are repairable by re-encoding the OMML, not by
dropping the equation. If a caller ever demands an explicit downgrade, **plain text** is the only
viable fallback (image unavailable) and it must go through stop-and-ask and be reported.

**How #30 surfaces it.** The D11 trigger *"a construction may render differently in one application
… complex equations"* → **warn-and-continue**. The shared risk policy (#30) raises one warning per
complex equation, naming the application(s) at risk (LibreOffice for `\begin{aligned}` output and
for `|`), and the change report (#28) carries it as a non-silent caveat; no downgrade is performed
without an explicit request.

## 5. Guidance for the equation feature (#26)

- **[V]** Prefer a **single-run-per-line `m:eqArr`** (or an `m:m` whose cells hold a whole line in
  one run) over the parser's `\begin{aligned}` output when LibreOffice fidelity matters; the parser's
  operator/superscript split is what LibreOffice misreads.
- **[V]** Avoid absolute-value bars `|…|` in an equation that must render in LibreOffice; there is no
  measured workaround via the parser, so treat a `|` as an at-risk construct to warn about.
- **[V]** Matrices and `m:eqArr` need no workaround: both are faithful in all three applications.
- **[?]** Whether LibreOffice 7.6 behaves differently from 24.2 on these constructs is unverified
  (only 24.2.7.2 was measured); the exact version matrix is still open (spec Further Notes).

## 6. Open / untested

- **[?]** Nested matrices, matrices with fractions inside cells (parse correctly via OfficeCLI, not
  rendered cross-app here), `m:eqArr` with more than two lines, and matrices with explicit column
  spacing/justification beyond the parser defaults.
- **[?]** WPS text-layer extraction is unusable (font encoding); WPS judgements rest on rendered
  visuals, consistent with the best-effort status of all WPS conclusions (spec D10).
