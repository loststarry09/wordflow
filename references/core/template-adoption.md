# Template adoption: look without content

A **template** is a `.docx` the user supplies whose **look** WordFlow adopts (spec
`docs/spec/v0.1.md` §D1, §D2, §D5). This is the write side of the `use-template-styles` outcome of
the style-ownership decision (`references/core/style-ownership.md`, #16): the template's style
definitions and page setup outrank the source document's own, but a written **formatting
requirement** outranks the template.

The behaviour is implemented as `scripts/wf-template.sh`; the acceptance suite is
`tests/template.sh`.

## The boundary (spec §D1–§D3, §D5)

A template is a source of *look*, **never of content** (spec §D1 frozen-decision summary;
CONTEXT.md "Template"). The adoption step copies none of the template's body.

| The template contributes | The template must never contribute |
|---|---|
| theme fonts and colour scheme (`/theme`) | body paragraphs / body text |
| style definitions (`/styles`) | images, drawings |
| section page size, orientation, margins | tables |
| the document grid (`docGrid.type`) | header/footer text |

Content isolation is asserted by reading the result back, not by trusting the write: the
output's body text and its running header/footer parts must be identical to the **source's**
(§Verification below).

## Precedence (spec §D2, §D5)

Highest first. The script applies lower layers first so higher layers overwrite them:

```
formatting requirement  →  template  →  source document's own styles
                        →  WordFlow standard styles  →  WordFlow defaults
```

- A **template** is applied before a **formatting requirement**, so a requirement's
  machine-applicable overrides win.
- Every style the template **defines** is (re)defined on the output, so the template outranks
  the source's own style definitions for that `styleId`. Styles the template does not define
  are left as the source had them.

## Portable construction (`scripts/wf-template.sh`)

```
scripts/wf-template.sh <source.docx> --template <tpl.docx> --out <output.docx>
                       [--requirement <file>] [--report <r.json>] [--json]
```

The source is never modified (ADR-0003): its bytes are copied to `--out` and only that new
file is changed, through OfficeCLI. The byte copy is a file duplication, not a DOCX read or
write; every DOCX operation still goes through OfficeCLI (ADR-0001). The source's and the
template's sha256 are verified unchanged at the end.

The rules the script encodes:

1. **Read the template's styles, then define/set them on the output** (§D5.3). It enumerates
   `/styles` with `officecli get <tpl> /styles --json`, reads each definition with
   `officecli get <tpl> /styles/<id> --json`, and replays the writable properties with
   `officecli set <out> /styles/<id>` (existing style) or `officecli add <out> /styles --type
   style …` (new style). `Normal` is `set`, never re-`add`ed, so its `w:default` is preserved
   (§D7; the same rule as `references/core/styles.md`). Identity keys (`id`, `type`,
   `customStyle`), the get-only resolved path (`basedOn.path`), and `effective.*` are not
   replayed. `font.latin` is written from the template's `font.ascii`.
   ```bash
   officecli get  tpl.docx /styles/WFBody --json
   officecli set  out.docx /styles/Normal --prop name=Normal --prop lineSpacing=1.0792x …
   officecli add  out.docx /styles --type style --prop styleId=WFBody --prop name="WF Body" …
   ```
2. **Adopt the theme as a whole.** `officecli dump <tpl> /theme --format batch --json` produces
   a one-item `raw-set` batch that replaces the output's `/theme` part with the template's, so
   theme-font bindings resolve to the template's fonts. Replacing a whole part is a standards
   part copy, not a content copy.
3. **Read the template's page setup, apply it to every section.** The template's geometry is
   read with `officecli query <tpl> section --json` (falling back to
   `officecli get <tpl> / --json`) and set on every `/section[N]` of the output: `pageWidth`,
   `pageHeight`, `orientation` (default `portrait` when the template leaves it implicit), all
   four margins, and `marginHeader`/`marginFooter`/`marginGutter` when present. The document
   grid (`docGrid.type`) is set on `/`. See `references/core/sections.md` for the section model.
4. **Apply the formatting requirement last.** The requirement file uses the intake convention
   (`references/core/intake.md`): `key = value` / `key: value` are machine-applicable
   overrides, `#`/blank lines are ignored, other non-blank lines are notes, duplicates are
   last-wins. Section keys (`pageWidth`, `pageHeight`, `orientation`, `margin*`) are applied to
   every section; every other override is applied to the document's **default paragraph style**
   (the template's default, else `Normal`). Because this runs after the template, an override
   wins.
5. **Report unadopted template items as unverified** (see Limitations): any template section
   property this primitive does not adopt, any template style property OfficeCLI refuses
   (`warnings[].code = unsupported_property`), and a template theme that cannot be copied.
6. **Route risk through the shared policy.** A multi-column template section
   (`columns > 1`) is a *limited* construct (spec §D9): the script calls
   `scripts/wf-risk-policy.sh decide --trigger columns` for the report entry and
   `… emit --trigger columns` to write it. No D11 code is hardcoded in this script (#30).

## Verification (spec §D14)

The script asserts the result through OfficeCLI before reporting done:

- **Styles** — every property the template defines reads back equal on the output
  (`officecli get <out> /styles/<id> --json` vs the template's). Properties the source already
  carried on a shared `styleId` may persist (rule below); only the template-defined properties
  are required to match.
- **Page setup** — the six geometry keys read back equal to the template's on every section
  (or to the requirement override, where one applies).
- **Content isolation** — `officecli view <out> text` is identical to `officecli view <src>
  text`, and `officecli query <out> header|footer --json` yields the same texts as the source.
  This proves neither the template's body nor its header/footer text reached the output.
- **Schema** — `officecli validate <out>` passes.
- **Protection** — the source's (and template's) sha256 is unchanged.

## Report shape (`--json`)

Stable fields other work depends on:

```json
{
  "source": "…", "output": "…", "template": "…",
  "source_unchanged": true, "template_unchanged": true,
  "styles_adopted": [ { "style_id": "Normal", "name": "Normal", "type": "paragraph", "default": true }, … ],
  "styles_adopted_count": 3,
  "page_setup": { "pageWidth": "21cm", "pageHeight": "29.7cm", "orientation": "portrait",
                  "marginTop": "2.54cm", "marginBottom": "2.54cm",
                  "marginLeft": "3.18cm", "marginRight": "3.18cm" },
  "theme_adopted": true,
  "requirement": { "given": true, "applied": ["lineSpacing=2x", "marginTop=1cm"] },
  "report": "/abs/…-report.json",
  "verification": { "template_content_absent": true, "source_content_intact": true,
                    "source_parts_intact": true, "output_valid": true,
                    "styles_read_back": true, "page_setup_read_back": true },
  "change_report": ["Template adoption: …", "…"],
  "evidence": ["officecli get <out> /styles --json — …", "…"]
}
```

`change_report` is the entry set this step contributes to the document's change report
(spec §D12); `--report <r.json>` additionally writes the full five-area report through the
shared contract (`references/workflow/change-report.md`, #28). `requirement` is `null` when no
requirement was supplied.

## Limitations

- **Set is a merge, not a replace** [?]. OfficeCLI cannot *unset* a style property, so a
  property the **source** already defined on a shared `styleId` but the template does not
  define survives on the output (e.g. the source's `Normal` font stays if the template's
  `Normal` omits a font slot). Template-defined properties always win; the test compares only
  the template-defined properties. A true replace would need the source's styles dropped, which
  is the tidy step's concern, not this primitive's.
- **Theme equivalence is semantic, not byte-identical** [?]. The theme part is replaced by the
  template's XML, but re-serialisation may re-declare a namespace; `officecli get /` theme
  fields are the comparison surface, not raw XML.
- **Multi-column sections are not adopted** [S]. `columns`/`columnSpace` are read only to warn
  (§D9); the output keeps one column.
- **Other section settings are out of scope** [S]. `pageNumFmt`, `pageStart`, `titlePage`,
  header/footer references, and `direction` are owned by their own steps; when present on the
  template section they are recorded as unverified rather than adopted.
- **Fonts are named, not embedded** [V]. Copying the theme copies font *names*; if a host lacks
  them, the application substitutes (the same caveat as `references/core/styles.md`).
- **An unsupported template property is unverified** [V]. OfficeCLI returns
  `warnings[].code = unsupported_property` when a property is refused; the script records it as
  unverified instead of silently dropping it.

## Evidence

- `tests/fixtures/styles/template.docx` — a template with `Normal`, `WFBody`, `WFQuote`, and
  body sentinels `Template body sample.` / `Template quote sample.` (rebuilt by
  `tests/generate-fixtures.sh`).
- `tests/template.sh` — acceptance checks: style and page-setup adoption read back; the
  template outranking a styled source; requirement overrides beating the template; body,
  table, image, and header/footer content isolation; reproducibility; source protection; a
  requirement report; bad usage; and a LibreOffice open-without-repair check.
- `scripts/wf-intake.sh` / `references/core/intake.md` (#15) — the requirement-file convention
  and the precedence chain.
- `scripts/wf-risk-policy.sh` (#30) — the D11 trigger used for multi-column layouts.
- `scripts/wf-compat-harness.sh` (#2) — the open-without-repair measurement.
