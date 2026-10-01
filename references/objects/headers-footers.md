# Headers, footers and page numbers

WordFlow owns running headers/footers and page numbering as **layout** (spec
`docs/spec/v0.1.md` §D8). This is the judgement behind
[`../../scripts/wf-headers.sh`](../../scripts/wf-headers.sh): which construction to
emit, why it is portable, and what is limited or downgraded. It is the object
counterpart to the facts files under [`../research/`](../research/); the facts are
tagged here, not restated.

Legend: **[V]** verified by running the tools locally · **[S]** backed by OOXML /
ECMA-376 or another primary source · **[?]** reported or suspected, not confirmed.

## The construction WordFlow emits

All reads and writes go through OfficeCLI (ADR-0001). The parts and their scope
are built with these plain OfficeCLI constructions (the same ones the committed
fixtures use):

| Effect | OfficeCLI construction |
|---|---|
| Default header/footer | `add F / --type header\|footer --prop text=… --prop align=center` |
| Different first page | `add F / --type header\|footer --prop type=first …` |
| Odd/even | `add F / --type header\|footer --prop type=default\|even …` |
| A live page number | `add F "/footer[k]/p[1]" --type field --prop fieldType=page` (and `fieldType=numpages`) |
| Page-number restart | `set F /section[N] --prop pageStart=<n>` (LIMITED) |

- **[S]** OOXML expresses these with `w:headerReference` / `w:footerReference` of
  `w:type="default|first|even"`. `type=first` turns on `<w:titlePg/>`; an `even`
  part turns on the document setting `<w:evenAndOddHeaders/>`.
- **[V]** Adding the `even` part is what writes `w:evenAndOddHeaders`; there is no
  separate "different first page" or "odd/even" prop to toggle. Part order is the
  order the references were created, so the script maps a part by its
  `.format.type` rather than by index (see
  [`../research/firstpage-oddeven-headers.md`](../research/firstpage-oddeven-headers.md)).

### Part-slot naming (the trap)

- **[S]** With `w:evenAndOddHeaders` on, the **`default`** part is the **odd**-page
  header/footer, not "every page". WordFlow documents this or a user will expect
  `default` to mean every page.
- **[S]** If a `first` or `even` part exists but the `default` part is missing, the
  applications do **not** fall back to it: pages that need `default` render a blank
  header/footer. So a page number placed only in the `first` part is not a running
  page number.

## Why the page number is portable (fully supported)

- **[V]** On a forced 4-page document, Word 16.0, WPS Writer 12.0 and LibreOffice
  24.2.7.2 each display the correct `PAGE` and `NUMPAGES` on every page **without
  a manual field update**, even when the cached value OfficeCLI wrote is stale
  (`1`). The value is produced by each reader's layout engine, so the cache does
  not govern what is displayed — proved by locking the field and still seeing the
  later page numbers.
- **[V]** Different first-page and odd/even headers/footers open without repair and
  render the intended first/even/odd part on pages 1/2–4/3 in all three
  applications, including the `PAGE` fields inside each footer.
- **[V]** Both findings were re-affirmed against the current OfficeCLI `1.0.153`
  and are the basis for the #37 spec revision that promoted these to **fully
  supported** (§D8/§D9/§D10).

Consequence for WordFlow: a footer `PAGE`/`NUMPAGES` field is **not** a downgrade
and **must not** raise a warning. WordFlow writes the field and reports it as a
layout decision; it never has to compute or guarantee the number itself, because
the reader always does.

`wf-headers.sh` adds `PAGE` followed by `of ` and `NUMPAGES` (the `"Page X of Y"`
pattern measured in the multipage study), guarded so it never duplicates a
page-number field already present in a part.

## Capability tiers (§D9 as revised by #37)

| Tier | Item | Construction | Handling |
|---|---|---|---|
| Full | header/footer text | `default` part | built; reported as changed |
| Full | live page number | footer `PAGE` + `NUMPAGES` | built; **no warning** (layout-computed) |
| Full | different first page | `type=first` + `w:titlePg` | built; **no warning** |
| Full | odd/even | `type=even` + `w:evenAndOddHeaders` | built; **no warning** |
| Limited | page-number restart | `section --prop pageStart` | applied; **warn** (`D11-page-number-restart`) |
| Limited/omitted | `PAGEREF`, TOC page numbers | — | never presented (no layout engine) |

Residual uncertainty, carried honestly:

- **[?]** Odd/even selection is parity-driven by each application's own
  pagination; if two applications lay the same content onto a different number of
  pages, the variant on a given *content* page can differ. First-page assignment
  is pagination-independent. This is inherent to the feature, not a defect.
- **[?]** Multi-section documents and "link to previous" across a section break
  were not measured. WordFlow applies a page-number restart to the last section
  and reports which section.

## Page-number restart is limited (warn, never silent)

- **[V]** `pageStart` / `pageNumFmt` on a section is honoured by all three
  applications (restart + `lowerRoman` rendered faithfully in the measured
  matrix), but the numbered result still depends on each application's pagination.
- **[S]** Per §D9/§D11 WordFlow **warns** rather than promising the number: the
  script emits `D11-page-number-restart` through
  [`../../scripts/wf-risk-policy.sh`](../../scripts/wf-risk-policy.sh) and records
  the entry in the change report.
- **[S]** Fallback when a target version is limited: keep one default footer and
  drop the restart (and any first/even variants), which is the portable subset
  every version handles. A downgrade is never silent (§D11/§D12).

## Never present a page number WordFlow cannot guarantee

- **[V]** `PAGEREF` and TOC page numbers are *cached-text* fields, not
  layout-computed ones: no application updates fields on open, so a wrong cached
  page number ships verbatim. WordFlow keeps them omitted or limited and does not
  present a number it cannot guarantee (§D8/§D9, §D14).
- **[S]** The `PAGE`/`NUMPAGES` carve-out is exact: those two (and an *unlocked*
  `PAGEREF`) are recomputed by the reader's layout engine, so their cached text is
  legitimately stale without being a defect (§D14 as revised by #37).

## Reports and risk policy

`wf-headers.sh` contributes plain-string entries through the shared
[change-report contract](../workflow/change-report.md) (#28) and routes the
restart through the shared [risk policy](../workflow/risk-policy.md) (#30). It
invents no warn/downgrade logic of its own. Its JSON report carries the five
change-report areas plus feature evidence (`headers`, `footers`, `first_page`,
`odd_even`, `page_numbers`, `restart`) and `source_unchanged`; the
`change_report` array flattens the areas for a single human/agent view.

## Source

- `references/research/multipage-page-fields.md` — `PAGE`/`NUMPAGES` are
  layout-computed; `PAGEREF`/TOC remain limited (#3).
- `references/research/firstpage-oddeven-headers.md` — first-page/odd-even
  portability, part-slot naming, and the single-default fallback (#5).
- `references/research/field-recalc-and-cross-app-verification.md` — the general
  "no application updates fields on open" rule and its page-field carve-out.
- `tests/fixtures/headers/page-number-footer.docx` and
  `tests/fixtures/headers/firstpage-oddeven.docx` — the committed constructions.
- Acceptance: [`../../tests/headers.sh`](../../tests/headers.sh).
