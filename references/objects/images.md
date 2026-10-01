# Images

An **image** is content; where it sits on the page is layout. WordFlow places an image WordFlow
did not author into the text flow, and constrains its width to the text column. It never crops,
recolours, or otherwise edits the image (ADR-0002). This is the image step of the "Populate"
phase (spec `docs/spec/v0.1.md` §D8); the paragraph that carries the image is owned by the
style/paragraph model, not by this step.

## The portable construction: inline

An **inline** image (`wp:inline` with an explicit `wp:extent`) is **fully supported**
(spec §D9). It flows with the text and renders faithfully in Word, WPS Writer, and LibreOffice
Writer. **[S]** Inline is the portable OOXML form — `wp:inline` with `wp:extent` and an
`a:blip @r:embed` that references the media part
(`references/research/docx-feature-portability.md` §objects/ Images). **[V]** OfficeCLI's
`add … --type picture` produces `wp:inline` and preserves the aspect ratio from the width
(OfficeCLI `help docx picture`; `tests/fixtures/images/inline-image.docx`).

Ship **PNG or JPEG**. **[?]** EMF/WMF/TIFF/SVG fail in some consumers, so WordFlow does not
prefer them (`references/research/docx-feature-portability.md` §objects/ Images).

## The limited construction: floating (anchored) — downgraded

A **floating** image (`--anchor`, `wp:anchor` + `wp:positionH/V` + a wrap mode) is **limited**
(spec §D8/§D9). **[V]** LibreOffice 24.2 does **not** render it faithfully: the committed
`images/anchored-image.docx` (`anchor=true`, `wrap=topAndBottom`, `hRelative=column`,
`hPosition=0cm`) rendered **left-aligned and in flow above the paragraph**, not centred on the
column and not floating as intended
(`references/research/field-recalc-and-cross-app-verification.md` §7). **[?]** Anchored/wrap
rendering diverges between renderers generally
(`references/research/docx-feature-portability.md` §objects/ Images).

The decision (spec §D11 row 2) is a **downgrade**, never a silent difference: when an anchored
placement is requested, WordFlow emits the portable fallback — a **centred inline** image — and
records the downgrade through the shared risk policy (`scripts/wf-risk-policy.sh`, trigger
`preferred-unavailable` with `fallback=exists`). The report's `downgrades` area carries the
`[D11-preferred-unavailable]` entry. The reader gets a correct, portable result instead of an
image that moves in one application.

An anchored image that **already exists in a document** is likewise a limited construct: the
document-level risk hook looks for `picture[anchor=true]` and emits the `floating-image`
**warning** (it does not rewrite content, ADR-0002).

## Width is constrained to the text column

The **text column** is the section's page width minus its left and right margins. For the
WordFlow default (A4, 3.17 cm side margins) that is 21 − 3.17 − 3.17 = 14.66 cm; OfficeCLI's own
`create` default is 3.18 cm, giving 14.64 cm on a fresh document
(`references/core/sections.md` §Default page setup). A requested width **wider than the column
is clamped to the column** and the clamp is reported: an unclamped width would overflow onto the
page margin. **[S]** The page geometry the column is computed from is the section `w:pgSz` /
`w:pgMar` model (`references/core/sections.md`).

## Reproducible operation

```
scripts/wf-image.sh <source.docx> --image <img.png> --out <output.docx> \
  [--para <path>] [--width <w>] [--alt <text>] [--anchor] \
  [--report <report.json>] [--json]
```

It copies the source bytes to `--out` (the source is never modified, ADR-0003), places the image
through OfficeCLI, reads the result back, and reports what it placed. `/body/p[1]` is created
(empty) when the document has no paragraph yet; an explicit `--para` must already exist.

| Option | Effect | Default |
|---|---|---|
| `--image <file>` | The image to place. | — (required) |
| `--out <file>` | New output document; must differ from the source. | — (required) |
| `--para <path>` | Paragraph that receives the image. | `/body/p[1]` |
| `--width <length>` | Image width (`cm`/`in`/`pt`, or cm). Clamped to the column. | `3cm` |
| `--alt <text>` | Alternative text (accessibility). | none |
| `--anchor` | Request a floating image; downgraded to centred inline. | off |
| `--report <file>` | Change report to create or extend (spec §D12). | none |
| `--json` | Machine-readable report. | text |

JSON shape (stable fields other work depends on):

```json
{
  "source": "…", "output": "…", "source_unchanged": true,
  "image": { "path": "…", "target_paragraph": "/body/p[1]",
             "requested_width_cm": 3.0, "applied_width_cm": 3.0,
             "text_column_cm": 14.64, "clamped": false },
  "placement": "inline" | "inline-downgraded",
  "anchored_requested": false, "anchored_present": 0,
  "picture": { "path": "…", "width": "3.0cm", "height": "2.0cm",
               "alt": "…", "wrap": "inline", "anchor": false, "relId": "…" },
  "changed": ["…"], "decisions": ["…"], "warnings": [],
  "downgrades": ["…"], "unverified": [],
  "change_report": ["…"], "report": "…|null"
}
```

`change_report` is this step's entries (spec §D12); the report as a whole is assembled by the
change-report layer (`#28`). Do not format a report here.

## Limitations

- **One image per run.** Placing several is several calls (or the caller's `batch`); this
  primitive is the single-image decision.
- **Single section for the column.** The column is computed from the first section; a
  multi-section document with different page geometry is not resolved per paragraph in v0.1.
- **Centring the downgrade centres its paragraph.** A requested floating image becomes a
  centred inline image by centring the paragraph it is placed in; existing text in that
  paragraph is centred with it. Place the image in its own paragraph for a figure-like result.
- **No cropping, recolouring, or rotation.** Those are content edits and are out of scope
  (ADR-0002).
- **`--anchor` never produces a float.** A request cannot force the limited construction; that
  is the downgrade, by design (spec §D11).
- **EMF/WMF/TIFF/SVG** are not preferred (uncertain consumer support); ship PNG/JPEG.

## Evidence

- `tests/fixtures/images/inline-image.docx` — the inline construction
  (`--type picture --prop src=… --prop width=3cm`), `wp:inline`.
- `tests/fixtures/images/anchored-image.docx` — the floating construction
  (`--prop anchor=true --prop wrap=topAndBottom …`), `wp:anchor`; the LibreOffice
  in-flow/left-aligned render.
- `tests/fixtures/assets/test-image.png` — the shared image asset.
- `tests/image.sh` — acceptance checks for inline placement, the recorded anchored downgrade,
  the width clamp, reproducibility, source protection, and LibreOffice open-without-repair.
- `references/research/docx-feature-portability.md` §objects/ Images; `[V]`/`[S]`/`[?]` tags.
- `references/research/field-recalc-and-cross-app-verification.md` §7 — the measured floating
  image render in LibreOffice 24.2.
