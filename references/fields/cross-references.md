# Cross-references

WordFlow owns cross-references to headings, figures, tables, and equations as
**layout / automatic content** (spec `docs/spec/v0.1.md` §D8). This is the judgement
behind [`../../scripts/wf-crossref.sh`](../../scripts/wf-crossref.sh): which field to
emit, why the cached result must be correct, and what is limited or downgraded. It
is the feature counterpart to the measured facts under
[`../research/`](../research/); the facts are tagged here, not restated.

The write mechanism itself — how a content reference's cached result is made to
hold the resolved target text instead of the placeholder — lives in
[`cached-cross-references.md`](./cached-cross-references.md) (the #12 mechanism,
reused unchanged here).

Legend: **[V]** verified by running the tools locally · **[S]** backed by OOXML /
ECMA-376 or another primary source · **[?]** reported or suspected, not confirmed.

## The constraint

- **[V]** `officecli add <docx> <para> --type field --prop fieldType=ref --prop
  name=<bookmark>` writes the `REF <bookmark>` instruction **and** a cached result
  of the literal `«<bookmark>»` (e.g. `«sec_intro»`).
- **[V]** Word 16, WPS Writer 12 and LibreOffice 24.2 do **not** update fields on
  open, even with `updateFields=true`; `refresh` never resolves `REF` either. The
  cache is what the reader shows, so a placeholder ships verbatim.
- **[S]** In OOXML the instruction sits between `w:fldChar begin`/`end` and the
  cached result between `w:fldChar separate`/`end` (ECMA-376 §17.16); the cache is a
  stored snapshot a consumer may regenerate.

Consequence: a cross-reference is only correct if its cached result already holds
the resolved target text. `«target»` must never ship silently (spec §D8, §D11,
§D14). The working write/verification recipe is
[`cached-cross-references.md`](./cached-cross-references.md) §2.

## Target kinds and what the cache must hold

The rule is the same for every target: the bookmark must cover **exactly** the text
the reference should insert, and that same text is written into the `REF` cache
([`cached-cross-references.md`](./cached-cross-references.md) §3).

| Target | Bookmark covers | Cache holds | Evidence |
|---|---|---|---|
| Heading | the heading text | the heading text | **[V]** fixture `fields/cached-cross-ref.docx` |
| Figure / table caption | the plain-text label + number (`Figure 1`) | that label | **[V]** plain-text label |
| Equation | the equation-number text (`(1)`) | that number | **[?]** not measured locally |
| Page number | — | — | **limited**, downgraded (below) |

- **[V]** A bookmark that spans a nested field result is a portability trap: with
  `Figure <SEQ Figure>` and the bookmark closed before the `SEQ` `fldChar end`,
  Word and WPS show `Figure 1` but LibreOffice re-resolves the `REF` and drops the
  nested `SEQ`, showing `Figure` ([`cached-cross-references.md`](./cached-cross-references.md) §5).
  Keep the bookmark over plain text.

## Content reference (`REF`) — fully supported

- **[V]** A `REF` whose cached result is the resolved plain-text target opens
  repair-free and displays that text in Word 16, WPS Writer 12, and LibreOffice
  24.2.7.2; Word/WPS show the cache, LibreOffice re-resolves it, and because the
  bookmark covers plain text the two agree
  ([`cached-cross-references.md`](./cached-cross-references.md) §4).
- **[S]** `hyperlink=true` appends the `\h` switch and makes the resolved reference
  clickable; its result run then needs the `Hyperlink` character style, which must
  be **defined** or it is a dangling style and a QA failure (spec §D7). The
  plain (non-`\h`) reference is the verified construction.
- **[S]** The field's `w:dirty` marker must be cleared after the cached result is
  written; otherwise OfficeCLI reports the field as a stale cache
  (`field_cache_stale`). The `field` element exposes no `dirty` property, so this
  one step is `raw-set` — the recorded fallback (SKILL rule 4). `wf-crossref.sh`
  reads the cache back and refuses to report success if it differs from the target
  or contains `«`/`»`.

## Page-number reference (`PAGEREF`) — limited, downgraded

- **[V]** A `PAGEREF` cache cannot be made correct without a layout engine:
  OfficeCLI's `refresh` fills `PAGEREF` from its own HTML pagination, whose page
  numbers are wrong for Word/WPS ([`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md) §2),
  and Word/WPS ship a stale `PAGEREF` cache verbatim (§3). A wrong page number looks
  finished and is silently wrong.
- **[S]** Per spec §D8/§D9 WordFlow will **not present a page number it cannot
  guarantee**: `wf-crossref.sh --kind pageref` **downgrades** the request to a
  content reference, records the downgrade through the shared
  [risk policy](../workflow/risk-policy.md) (#30, trigger `preferred-unavailable`
  with `fallback=exists`), and adds it to the change report (spec §D11, §D12). It
  never emits a `PAGEREF`.
- **[S]** The carve-out is only a *layout-computed* `PAGE`/`NUMPAGES` footer field,
  which each reader recomputes per page (spec §D8, §D9);
  [`headers-footers.md`](../objects/headers-footers.md) holds that construction.

## Reports and risk policy

`wf-crossref.sh` contributes plain-string entries through the shared
[change-report contract](../workflow/change-report.md) (#28) and routes the
pageref downgrade through the shared [risk policy](../workflow/risk-policy.md)
(#30). It invents no warn/downgrade logic of its own. Its JSON report carries
`source`, `output`, `source_unchanged`, the five change-report areas collapsed into
`change_report`, and feature `evidence` (the field instruction, the cached text, the
placeholder flag, the dirty flag, the paragraph text, the result-run path, and
schema validity) — the OfficeCLI-observable facts the acceptance test asserts.

## Source

- [`cached-cross-references.md`](./cached-cross-references.md) — the write
  mechanism, per-target detail, and the LibreOffice field-span caveat (#12).
- [`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
  — no application updates fields on open; the `REF`/`PAGEREF` measured matrix
  (#3/#12).
- [`../research/docx-feature-portability.md`](../research/docx-feature-portability.md)
  §fields — the documentary per-feature portability note.
- Fixture `tests/fixtures/fields/cached-cross-ref.docx`; the placeholder "before"
  state is `tests/fixtures/fields/bookmark-ref-pageref.docx`.
- Acceptance: [`../../tests/crossref.sh`](../../tests/crossref.sh).
