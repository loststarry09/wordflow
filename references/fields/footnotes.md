# Footnotes

WordFlow owns footnotes as **generated content whose look is layout** (spec
`docs/spec/v0.1.md` §D8). This is the judgement behind
[`../../scripts/wf-footnote.sh`](../../scripts/wf-footnote.sh): which construction to
emit, why it is portable, and how the two footnote styles are kept from dangling. The
footnote/endnote facts live under [`../research/`](../research/); they are tagged here,
not restated.

Legend: **[V]** verified by running the tools locally · **[S]** backed by OOXML /
ECMA-376 or another primary source · **[?]** reported or suspected, not confirmed.

## The construction WordFlow emits

All reads and writes go through OfficeCLI (ADR-0001). A footnote is attached to a
paragraph with the same plain construction the fixture uses:

```sh
officecli add <docx> /body/p[N] --type footnote --prop text="…"
```

- **[V]** That command writes a run carrying `w:rStyle FootnoteReference` and
  `w:footnoteReference w:id=N` into the body paragraph, and a `w:footnote w:id=N`
  entry in the footnotes part whose paragraph carries `w:pStyle FootnoteText` (the
  separator/continuation footnotes are `w:id=-1`/`0`). It reports
  `Added footnote at /footnote[@footnoteId=N]` on stdout
  ([`../research/officecli-behavior.md`](../research/officecli-behavior.md)).
- **[S]** OOXML expresses the pair as `w:footnoteReference` in the document and
  `w:footnote` in `footnotes.xml`; `w:footnotePr` / `w:endnotePr` in `w:sectPr`
  control restart and placement, and reference marks use `w:footnoteRef` inside the
  note ([`../research/docx-feature-portability.md`](../research/docx-feature-portability.md)).
- **[V]** The `--para` path defaults to the **last body paragraph** (read back as an
  OfficeCLI paragraph path); an explicit `/body/p[N]` is used verbatim.

`wf-footnote.sh` then reads the footnote back as
`/footnote[@footnoteId=N]/p[1]`, confirms its paragraph style is `FootnoteText`, and
applies it explicitly if OfficeCLI did not.

## The two styles

The standard set (spec §D7) defines exactly two footnote styles, and the capability
defines no others:

| Style | Type | Look | Source |
|---|---|---|---|
| `FootnoteText` | paragraph | 宋体 (SimSun) 9 pt (小五), Times New Roman Latin, left, no first-line indent | §D6; [`../core/styles.md`](../core/styles.md) |
| `FootnoteReference` | character | superscript | §D7; [`../core/styles.md`](../core/styles.md) |

- **[V]** The committed fixture `tests/fixtures/notes/footnote-basic.docx` *references*
  both styles but defines only `Normal`: the footnote reads `FootnoteText` /
  `FootnoteReference` with **no matching `styles.xml` entry** (a dangling style).
  WordFlow's style-ownership rule (spec §D7) repairs that by adding the standard
  definitions **only when absent**; a document that already defines them (for example
  `tests/fixtures/styles/standard-style-set.docx`) keeps its own definitions.

A dangling style is a QA failure (spec §D14). The capability asserts the whole output
after the operation: it collects every `w:pStyle`/`w:rStyle` reference across
`/document`, `/footnotes`, and any header/footer, subtracts the defined
`styles.xml` ids, and refuses to ship if anything remains dangling.

## Portability (fully supported)

- **[V]** Each application displays the note on the page that holds its reference,
  with the reference mark and the footnote paragraph styled by the two styles;
  the fixture and the generated output open **without a repair prompt** in
  LibreOffice Writer 24.2.7.2 (measured here through the compatibility harness) and
  in Word 16 / WPS Writer 12 for the equivalent fixture
  ([`../../tests/footnote.sh`](../../tests/footnote.sh)).
- **[S]** Footnotes are in the spec's **fully supported** tier (§D8/§D9); the
  construction above is the shared, standard subset, so WordFlow emits no warning and
  records no downgrade for it.
- **[?]** **Per-section restart** (`w:footnotePr`) is often ignored by consumers, and
  converting footnotes to endnotes can create two note sets. WordFlow does not change
  placement, restart, or number format, so neither risk is triggered
  ([`../research/docx-feature-portability.md`](../research/docx-feature-portability.md)).

## Reports and risk policy

`wf-footnote.sh` contributes plain-string entries through the shared
[change-report contract](../workflow/change-report.md) (#28): what was attached, and
whether the footnote styles were **added** (source had none) or **preserved** (source
style ownership). It invents no warn/downgrade logic of its own — if it ever cannot
confirm the footnote text style was applied it routes an `unverifiable-field` warn
through the shared [risk policy](../workflow/risk-policy.md) (#30) instead of shipping
silently. Its JSON report carries `source`, `output`, `source_unchanged`,
`change_report`, and an `evidence` object (target paragraph, footnote id/text, the two
styles added/preserved, the reference/definition sets, the dangling set, and the
validation result).

## Evidence

- `tests/fixtures/notes/footnote-basic.docx` — one footnote, both footnote styles
  dangling, the repair target.
- `tests/fixtures/styles/unstyled.docx` — no style set; both footnote styles are added.
- `tests/fixtures/styles/standard-style-set.docx` — the styles are present and
  preserved; an existing footnote is kept alongside the new one.
- `scripts/wf-footnote.sh` — the capability; `tests/footnote.sh` — acceptance
  (construction, no dangling style, reproducibility, source protection,
  LibreOffice open-without-repair).
- `references/research/officecli-behavior.md` — the OfficeCLI footnote command.
- `references/research/docx-feature-portability.md` — the OOXML footnote/endnote facts.
- `references/core/styles.md` — the `FootnoteText` / `FootnoteReference` definitions.
