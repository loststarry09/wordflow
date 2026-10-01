# Tables

How WordFlow builds regular, merged-cell, and nested tables, and why. Every claim is
tagged: **[V]** verified by running the tools locally, **[S]** backed by OOXML / ECMA-376,
**[?]** not confirmed here. The evidence for the portability judgements is
[`../research/nested-tables.md`](../research/nested-tables.md); the OfficeCLI property list
is authoritative and is not copied here (run `officecli help docx table` / `docx table-cell`).

## The judgement

- **Regular tables — fully supported.** [V] A fixed-layout table with explicit column
  widths and direct borders opens repair-free and renders faithfully in Word 16, WPS
  Writer 12, and LibreOffice 24.2.
- **Merged-cell tables — fully supported.** [V] LibreOffice 24.2 rendered a horizontal
  span (`colspan` → `w:gridSpan`) and a vertical merge (`vmerge` restart/continue →
  `w:vMerge`) with borders exactly as intended; the construct is ordinary Transitional
  OOXML [S].
- **Nested tables — fully supported** when built with the portable construction below.
  [V] All three applications opened the committed fixture repair-free and rendered the
  inner table contained in its host cell with its own red borders preserved.

## The portable construction

Build every table — and every nested table — as:

1. **Fixed layout** (`layout=fixed`).
2. **Explicit column widths** (`colWidths=...`), one per grid column.
3. **Direct borders** (`border.all="STYLE;SIZE;COLOR"`), so the borders survive nesting.
4. **`tblW == Σ colWidths` at every level**: the table `width` must equal the sum of its
   column widths. [V] WPS stretches a table to the grid width when the two disagree,
   while Word and LibreOffice use `tblW`; making them equal is what made all three renders
   byte-identical. Unit rounding is worth up to 1 twip (e.g. 12 cm ≈ 6803 twips), so allow
   a one-twip slack rather than demanding bit equality.

The merge semantics are native cell properties, not `raw-set`:

| Merge | OfficeCLI property | OOXML |
|---|---|---|
| Horizontal span of N columns | `set <cell> --prop colspan=N` | `<w:gridSpan w:val="N"/>` |
| Vertical merge, top cell | `set <top-cell> --prop vmerge=restart` | `<w:vMerge w:val="restart"/>` |
| Vertical merge, lower cells | `set <cell> --prop vmerge=continue` | `<w:vMerge/>` |

[V] Setting `colspan` removes the now-redundant trailing cells in that row; a rectangular
2×2 merge is `colspan=2` on both rows plus `vmerge=restart` on the top cell and
`vmerge=continue` on the row below. Leave the cells a vertical span covers empty in the
source data — the merged cell shows the top cell's content.

### OfficeCLI commands

```sh
# regular table
officecli add F /body --type table \
  --prop data="Column A,Column B;A1,B1" \
  --prop layout=fixed --prop colWidths=1701,1701 --prop width=9cm \
  --prop border.all="single;8;000000"
officecli set F /body/tbl[1]/tr[1] --prop header=true        # repeating header row

# merged cells
officecli set F /body/tbl[1]/tr[1]/tc[1] --prop colspan=2      # horizontal span
officecli set F /body/tbl[1]/tr[2]/tc[1] --prop vmerge=restart # vertical merge top
officecli set F /body/tbl[1]/tr[3]/tc[1] --prop vmerge=continue

# a nested table in a host cell
officecli add F /body/tbl[1]/tr[2]/tc[1] --type table \
  --prop data="Inner 1,Inner 2;Inner 3,Inner 4" \
  --prop layout=fixed --prop colWidths=1418,1417 --prop width=5cm \
  --prop border.all="single;8;C00000"
```

`scripts/wf-table.sh` produces exactly this construction from `--data` and enforces the
portable rule (a mismatched `--width` is rejected; a nested table that cannot meet the rule
emits the `nested-table` warning through `scripts/wf-risk-policy.sh`).

## Styling

Table text is a paragraph, so it takes a paragraph style; use the frozen standard set
(`../core/styles.md`) and define nothing new [S]. `BodyNoIndent` is the right style for
cell text because table cells must not carry the body first-line indent. When the output
does not define that style there is nothing to apply — leave the document's own default
rather than reference an undefined style (a dangling reference is a QA failure, spec §D14).

## Caveats

- **Autofit nested tables are unverified** [?, `../research/nested-tables.md`] and
  therefore not portable; keep nesting fixed-layout. WordFlow warns (D11) rather than
  guessing.
- **One nesting level is measured.** [V] Deeper nesting and nested tables spanning a page
  break are not verified across Word/WPS [?, same source].
- **Merged cells combined with nesting or floating placement is unverified** [?]. The
  measured fixtures are regular + merged, and regular + nested.
- **`w:hMerge` is a legacy horizontal-merge form** [S]; prefer `w:gridSpan`
  (`colspan`). OfficeCLI still round-trips `hMerge` for files that already use it.
- Because WordFlow is layout-only (ADR-0002), an **existing** table is restyled in place,
  never rebuilt or reformatted into a different structure.
