# Nested tables — cross-application portability (#4)

Empirically measured behaviour of a table nested inside a table cell in **Microsoft Word**,
**WPS Writer**, and **LibreOffice Writer**. This is a **facts** file, not product guidance;
it supplies the evidence for the spec's nested-table tier decision (spec §D8, §D9, §D10).

Legend:
- **[V]** — verified by running the tools locally (versions below).
- **[S]** — backed by the OOXML / ECMA-376 standard or a primary-source document.
- **[?]** — reported elsewhere but not confirmed here; treat as uncertain.

## Method

- **OfficeCLI** `1.0.152` on Linux (WSL), the only DOCX reader/writer (ADR-0001).
- **Microsoft Word** `16.0` via COM (`Word.Application`), opened hidden, `ReadOnly=true`,
  no save, repair prompt **not** suppressed (`OpenAndRepair` not used).
- **WPS Writer** `12.0` via COM (`KWPS.Application`), same procedure.
- **LibreOffice** `24.2.7.2`, driven headless with an isolated user profile
  (`--convert-to pdf`).
- Harness: `scripts/wf-compat-harness.sh` (cross-application measurement; see
  `references/compatibility/harness.md`), invoked under the shared COM lock.
- Evidence: per-application PDF export + PNG render, inspected for borders and layout.
  Artifacts under `tests/.out/nested-tables/` (git-ignored); probe artifacts under
  `/tmp/opencode/nested/`.

Test document — the committed fixture **`tests/fixtures/tables/nested-table.docx`**
(`sha256 bec0bcf1…a459e5a59`), built by `tests/generate-fixtures.sh`:

- an outer fixed 2×3 table: `layout=fixed`, `colWidths=3402,3402`, `width=12cm`,
  `border.all="single;8;000000"` (black);
- an inner fixed 2×2 table at `/body/tbl[1]/tr[2]/tc[1]/tbl[1]`: `layout=fixed`,
  `colWidths=1418,1417`, `width=5cm`, `border.all="single;8;C00000"` (red);
- `tblW` equals the sum of `colWidths` at both levels (12 cm = 6804 twips; 5 cm = 2835 twips).

## Result — the committed fixture

| Application | Version | Opens without repair | Renders faithfully? | Pages |
|---|---|---|---|---|
| Microsoft Word | 16.0 | **yes** | **yes** — outer black + inner red borders; inner table contained in its host cell | 1 |
| WPS Writer | 12.0 | **yes** | **yes** — same borders and containment | 1 |
| LibreOffice Writer | 24.2.7.2 | **yes** | **yes** — same borders and containment | — |

- **[V]** All three opened the fixture with `status=ok` / `opens_without_repair=true` and
  produced a PDF; `officecli validate` passed and the source was unchanged.
- **[V]** The three PNG renders were **byte-identical** between the probe (`nested2.docx`,
  same construction) and the committed fixture, and show the same layout: a 12 cm outer
  table with black 1 pt borders and a red-bordered 2×2 table fully inside cell (row 2,
  column 1), not escaping it.
- **[V]** The inner table's direct cell borders (`w:tcBorders`, red) survive in every
  application; nesting does not strip or reassign them.
- **[V]** OfficeCLI builds true nesting (`/body/tbl[1]/tr[2]/tc[1]/tbl[1]`) and appends a
  terminating paragraph after the inner table, which a cell requires.

This **contradicts** the documentary caution in `docx-feature-portability.md`
(**[?]** "LibreOffice regressions: nested tables escaping their parent") for
LibreOffice 24.2.7.2 — no escape was observed.

## Incidental finding — table width vs. column-width agreement

While building the probe, one draft used `width=9cm` (tblW = 5102 twips) with
`colWidths=4500,4500` (grid sum = 9000 twips = 15.875 cm).

- **[V]** Word 16 and LibreOffice 24.2 rendered the table at tblW (≈9 cm). **WPS 12
  stretched it to the grid width** (≈16 cm). The nested table inside stayed correctly
  contained in all three; only the outer (regular) table width diverged.
- **[V]** When `tblW` was made equal to Σ`colWidths` (12 cm = 6804 twips), **all three
  agreed**, and the three renders became byte-identical.
- **Consequence:** the portable construction is to keep `width` and the sum of
  `colWidths` consistent. `tests/fixtures/tables/fixed-table.docx` is internally
  inconsistent (`colWidths=3000,3000,3000` = 9000 twips vs `width=9cm` = 5102 twips) and
  is therefore expected to show the same Word/LO-vs-WPS width divergence; that is a
  separate regular-table issue, out of scope for #4.

## Exploratory probe — deeper nesting (LibreOffice only)

- **[V]** A three-level fixed nesting (outer black 1×2 → blue 1×2 in cell 1 → red 1×2 in
  the middle table's cell 1) opened without repair and rendered with all three border
  colours preserved and each table contained in its parent cell.
- **[?]** Word and WPS were **not** measured for three levels; only one level is in scope
  for #4, so deeper nesting is unverified across all three.

## Conclusion — recommended tier: **promote nested tables to fully supported**

- **[V]** On the committed fixture, nested tables open **without repair** and render
  **faithfully** (borders + containment) in all three target applications, from a
  standards-based construction (`w:tbl` inside `w:tc`, fixed layout, explicit widths,
  direct borders). This is the same evidence standard on which merged-cell tables were
  promoted (spec §D9); nested tables now meet it, and should be **promoted**.
- **[S]** The construction is ordinary Transitional OOXML: a `w:tbl` may be a child of a
  `w:tc`; no application-specific extension is involved.

**Conditions of the promotion (must be encoded in WordFlow's layout rules):**

1. Fixed layout with explicit `colWidths` and direct cell borders — the measured
   construction.
2. `tblW` (table `width`) must equal the sum of `colWidths`, at every nesting level, or
   WPS diverges on width (see incidental finding).
3. A cell that holds a nested table must still end with a paragraph (OfficeCLI already
   does this); if WordFlow ever constructs nesting directly it must preserve it.
4. Depth: one level is measured; deeper nesting is unverified Word/WPS.
5. Because WordFlow is layout-only (ADR-0002), an **existing** nested table is restyled
   in place, never rebuilt.

**Documented fallback (if a consumer chooses to retain the "limited" tier):**

- Nested tables are "limited" = produced **with a warning** (spec §D9/§D11). The safe
  fallback is **warn and preserve**: keep the nested table as-is and report that nested
  tables are measured faithful but not guaranteed beyond the tested construction. If the
  user demands maximum portability, WordFlow may offer — only on explicit request and per
  item, since it changes organization (ADR-0002, §D5 step 5) — to **flatten** the inner
  table into a sibling table (or a set of rows) below the host table, reported as a
  downgrade. Auto-flattening without confirmation is **refused**.

## Spec conflicts / follow-ups

- Spec §D9 (frozen) and §D10 list nested tables as **limited (untested)**; this research
  provides the missing evidence and argues for **promotion**. The frozen line
  "Merged-cell tables are promoted to fully supported; nested tables stay limited (D9)"
  in §Further Notes is now contradicted by measurement. Resolving it is a spec-owner edit
  (this research file does not change the spec).
- `tests/fixtures/tables/fixed-table.docx`'s `colWidths`/`width` mismatch (above) deserves
  its own check if regular-table portability is re-verified.

## Untested / open

- **[?]** Word/WPS rendering of nesting deeper than one level.
- **[?]** Autofit (`layout=autofit`) nested tables.
- **[?]** Nested tables combined with merged cells, floating placement, or a nested table
  spanning a page break.
- **[?]** Round-trip: open + save in each application, then re-read (does a nested table
  survive an application's save?).
