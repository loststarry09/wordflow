# Sections and page setup

A **section** is the layout unit that owns page geometry, headers/footers, and page numbering.
WordFlow establishes the page setup and the section model before any header/footer or
page-number work, because those features hang off the section boundaries created here. This is
the first layout decision in both workflows (spec `docs/spec/v0.1.md` §D4 step 3, §D8): set the
document's default page setup, and split it into sections only where the layout needs them.

## Default page setup (spec §D6)

| Setting | WordFlow default |
|---|---|
| Page | A4, portrait |
| Margins | top/bottom 2.54 cm, left/right 3.17 cm |

These apply only when a higher-precedence input does not specify otherwise. Precedence is
formatting requirement → template → the source document's own setup → WordFlow default
(spec §D2). In this primitive, an explicit input on the command line stands in for the
formatting requirement; a template's page setup is read by the template-adoption step (`#27`),
not here.

> **Spec/tool discrepancy — left/right margin.** Spec §D6 says **3.17 cm**; OfficeCLI's own
> `create` default is **3.18 cm** (`officecli get /` on a fresh `--locale en-US` document;
> `references/research/officecli-behavior.md` §Document creation). WordFlow follows the spec and
> **sets 3.17 cm explicitly**, never relying on the tool default. This is recorded so the spec
> owner can confirm 3.17 cm or change it deliberately; the discrepancy is not resolved silently.
> The committed `sections/page-setup-default.docx` fixture is built at 3.17 cm.

## The section model

- Every document has at least one section. The **final** section's properties live in the
  body-level `sectPr`; each **mid-document** section ends in a paragraph whose properties carry
  that section's `sectPr` (its geometry plus its break type).
- OfficeCLI enumerates sections as `/section[1] … /section[N]` via `officecli query <doc>
  section`; `/section[N]` is also readable with `officecli get <doc> /section[N]`. The final
  section is additionally addressable as the body-level path `/`.
- A section break is inserted with `officecli add <doc> / --type section --prop type=nextPage`.
  It inserts a **blank paragraph carrying the break**; that is expected and reads as an empty
  paragraph in `view issues` (advisory only).

### Break types

`type` accepts `nextPage` (default), `continuous`, `evenPage`, `oddPage`, and `nextColumn`.

- **`nextPage`** is the portable choice for "start the next section on a new page" and the only
  one WordFlow uses by default. Use it for a change of page geometry, page numbering, or
  header/footer.
- `evenPage` / `oddPage` force the section to start on an even/odd page. They are **limited**
  (spec §D9): render fidelity across Word/WPS/LibreOffice is untested, so prefer `nextPage`
  unless the user requires the parity.
- The break `type` belongs only to a **mid-document** section. Setting `type` on the final,
  body-level section (`/`) is rejected by OfficeCLI with an actionable error pointing at
  `/section[N]`; a document with no breaks has no type to set.

### Getting the order right

A mid-document section only exists once its break is present, and its geometry is set after the
content that follows it is in place:

1. add the section break (`add … --type section --prop type=nextPage`);
2. add the content that belongs to the next section;
3. set the section's properties on `/section[N]` (or on `/` for the final section).

Setting `/section[N]` before the following content exists can attach the properties to the wrong
section, because the document-level `sectPr` is always the *last* section.

| Address | Meaning |
|---|---|
| `/section[1] … /section[N]` | Every section, in document order (via `query … section`). |
| `/section[N]` | The N-th section; for a one-section document this is the final section. |
| `/` | The body-level path; also the **final** section. Rejects `type`. |

## Why later header/footer work depends on this

Each section is the anchor for:

- **Header/footer references** — `headerRef.default|first|even` and
  `footerRef.default|first|even` point at that section's running parts; the parts themselves are
  addressed `/header[N]` and `/footer[N]`. `titlePage=true` turns on a distinct first-page
  header/footer. A header/footer is therefore attached to a *section*, not to the document.
- **Page numbering** — `pageNumFmt` and `pageStart` are per-section. Restarting numbering
  (`pageStart`) is **limited** (spec §D9); a format change (`pageNumFmt`, e.g. `lowerRoman`) is
  faithful.

**Consequence for the section model:** the section boundaries created here are the handles the
header/footer and page-numbering steps will hold. Those steps must not add or remove sections;
they set properties on the sections this step established. Follow the "order right" sequence
above so each section's geometry and break land on the correct section.

## Reproducible operation

```
scripts/wf-page-setup.sh <source.docx> --out <output.docx> [options]
```

It copies the source bytes to `--out` (the source is never modified, ADR-0003), enumerates the
sections through OfficeCLI, and applies page size, orientation, and all four margins to every
section — or to one section with `--section N`. It sets `pageWidth`/`pageHeight`/`orientation`
and the four margins **explicitly**, so the result does not depend on OfficeCLI's own defaults,
and it never touches a section's break `type`.

| Option | Effect | Default |
|---|---|---|
| `--out <file>` | New output document (required; must differ from the source). | — |
| `--page-size A4\|A3\|A5\|Letter\|Legal` | Named page size. | A4 |
| `--page-width` / `--page-height <length>` | Custom size (both required; excludes `--page-size`). | — |
| `--orientation portrait\|landscape` | Page orientation; a named size is swapped for landscape. | portrait |
| `--margin-top` / `--margin-bottom` | Top/bottom margin. | 2.54cm |
| `--margin-left` / `--margin-right` | Left/right margin. | 3.17cm |
| `--section all\|N` | Apply to every section, or only `/section[N]`. | all |
| `--json` | Machine-readable report. | text |

JSON shape (stable fields other work depends on):

```json
{
  "source": "…", "output": "…",
  "page_setup": { "page_size": "A4", "page_width": "21cm", "page_height": "29.7cm",
                  "orientation": "portrait",
                  "margin_top": "2.54cm", "margin_bottom": "2.54cm",
                  "margin_left": "3.17cm", "margin_right": "3.17cm" },
  "sections_applied": ["/section[1]", "/section[2]"],
  "sections": [ { "path": "/section[1]", "format": { "…": "…" } } ],
  "overrides": ["page size", "orientation"],
  "source_unchanged": true,
  "change_report": ["Page setup: A4 portrait, …"]
}
```

`change_report` is the entry this step contributes to the document's change report (spec §D12);
the report as a whole is assembled by the change-report layer (`#28`). Do not format a report
here.

## Limitations

- **Page setup only.** Headers/footers, page numbering, columns, gutter, and page borders are
  distinct decisions and are not applied here, even though OfficeCLI can express them.
- **Custom size is used as given.** `--page-width`/`--page-height` are not swapped for
  `landscape`; only a named size is. Pass the landscape dimensions deliberately.
- **No template read.** A template's page setup is adopted by `#27`; this primitive takes
  explicit inputs (the formatting-requirement layer) only.
- **`evenPage` / `oddPage` / `continuous` breaks** are not produced by default and their render
  fidelity is untested (limited, spec §D9).
- **Per-section settings beyond page setup** (`pageNumFmt`, `pageStart`, `titlePage`, header/footer
  refs) are left to their own steps; this primitive preserves whatever a section already has.

## Evidence

- `tests/fixtures/sections/page-setup-default.docx` — two sections, both at the spec §D6 page
  setup, `/section[1]` carrying a `nextPage` break.
- `tests/page-setup.sh` — acceptance checks for the default, an explicit override, a
  per-section override, reproducibility, and source protection.
- `references/research/officecli-behavior.md` §Sections, §Document creation — the observed
  OfficeCLI behaviour (including the 3.18 cm tool default) behind these rules.
