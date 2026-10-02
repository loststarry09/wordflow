# Cross-references

WordFlow owns cross-references to headings, figures, tables, and equations as
**layout / automatic content** (spec `docs/spec/v0.1.md` §D8). This is the judgement
behind [`../../scripts/wf-crossref.sh`](../../scripts/wf-crossref.sh): which field to
emit, why the cached result must be correct, and what is limited or downgraded. It
folds in the cached-text mechanism proved in issue
[#12](https://github.com/loststarry09/wordflow/issues/12) and used unchanged by the
feature (#23).

Companion evidence:
[`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
(§1–§4, §6). Fixtures: `tests/fixtures/fields/cached-cross-ref.docx` (correct cache) and
`tests/fixtures/fields/bookmark-ref-pageref.docx` (the placeholder "before" state).
Tests: `tests/crossref-cache.sh` (mechanism), `tests/crossref.sh` (feature).

Legend: **[V]** verified by running the tools locally (OfficeCLI `1.0.152`/`1.0.153`; Word
`16.0`; WPS Writer `12.0`; LibreOffice `24.2.7.2`) · **[S]** backed by OOXML / ECMA-376 or
another primary source · **[?]** reported or inferred, not confirmed locally.

## The constraint

- **[V]** `officecli add <docx> <para> --type field --prop fieldType=ref --prop
  name=<bookmark>` writes the `REF <bookmark>` instruction **and** a cached result of the
  literal `«<bookmark>»` (e.g. `«sec_intro»`); `officecli refresh` never resolves `REF`
  either.
- **[V]** Word 16, WPS Writer 12 and LibreOffice 24.2 do **not** update fields on
  open, even with `updateFields=true`; the cache is what the reader shows, so a placeholder
  ships verbatim.
- **[S]** In OOXML the instruction sits between `w:fldChar begin`/`end` and the
  cached result between `w:fldChar separate`/`end` (ECMA-376 §17.16); the cache is a
  stored snapshot a consumer may regenerate.

**Consequence.** A cross-reference is only correct if its cached result already holds the
resolved target text. `«target»` must never ship silently (spec §D8, §D11, §D14).

## Portable construction

1. **Create the target**, with a **plain-text bookmark** covering exactly the text the
   reference should insert (see *Target kinds* below).
2. **Add the `REF` field** pointing at that bookmark.
3. **Write the resolved text into the field's cached result run** — the `run` immediately
   after the field's `separate` `fldChar`.
4. **Clear the `w:dirty` marker** OfficeCLI adds when the cached result changes; otherwise
   the field reads as a stale cache (`field_cache_stale`). The `field` element exposes no
   `dirty` property, so this one step is `raw-set` — the recorded raw-set fallback (SKILL
   rule 4).

```sh
# 1–2. target + reference to it
officecli add doc.docx / --type bookmark --prop name=sec_intro --prop text="Introduction"
officecli set doc.docx /body/p[1] --prop style=Heading1
officecli add doc.docx /body --type paragraph --prop text="See section "
officecli add doc.docx /body/p[2] --type field --prop fieldType=ref --prop name=sec_intro

# 3. resolved target text -> the result run (text run after the `separate` fldChar)
officecli set doc.docx /body/p[2]/r[5] --prop text="Introduction"

# 4. clear the w:dirty marker on every field this wrote (raw-set; no DOM property for dirty)
officecli raw-set doc.docx /document \
  --xpath '//w:fldChar[@w:fldCharType="begin" and @w:dirty="true"]' \
  --action replace \
  --xml '<w:fldChar w:fldCharType="begin"/>'
```

- **[V]** Step 4 is required: after step 3 alone, `officecli get <docx> /field[N]` reports
  `"dirty": true` and `officecli view <docx> issues` raises subtype `field_cache_stale`;
  after step 4 the field reads clean and `officecli validate` passes.
- **[V]** The result-run index is deterministic for a paragraph WordFlow builds (the `REF`
  field's runs are `begin`, `instrText`, `separate`, **result**, `end`). For an arbitrary
  document, locate it from the paragraph's child list:

```sh
officecli get doc.docx /body/p[2] --json \
  | jq -r '.data.results[0].children as $c
           | ($c | to_entries
                  | map(select(.value.type=="fieldChar"
                               and .value.format.fieldCharType=="separate"))
                  | .[0].key) as $s
           | $c[$s+1].path'          # -> the cached result run to `set`
```

Do **not** address the field through `/field[N]`: that path exposes `instruction` and
read-only `evaluated`/`dirty`, but no way to write the cached text. The result run is
addressed as `<paragraph>/r[N]`.

## Target kinds and what the cache must hold

The rule is the same for every target: the bookmark must cover **exactly** the text the
reference should insert, and that same text is written into the `REF` cache.

| Target | Bookmark covers | Cache holds | Evidence |
|---|---|---|---|
| Heading | the heading text | the heading text | **[V]** `fields/cached-cross-ref.docx` |
| Figure / table caption | the plain-text label + number (`Figure 1`) | that label | **[V]** plain-text label |
| Equation | the equation-number text (`(1)`) | that number | **[?]** not measured locally |
| Page number | — | — | **limited**, downgraded (below) |

- **[V]** A bookmark that spans a nested field result is a portability trap: with
  `Figure <SEQ Figure>` and the bookmark closed before the `SEQ` `fldChar end`,
  Word and WPS show `Figure 1` but LibreOffice re-resolves the `REF` and drops the
  nested `SEQ`, showing `Figure` (see *LibreOffice divergence* below). Keep the bookmark
  over plain text.

## Content reference (`REF`) — fully supported

- **[V]** A `REF` whose cached result is the resolved plain-text target opens repair-free
  and displays that text in Word 16, WPS Writer 12, and LibreOffice 24.2.7.2; Word/WPS show
  the cache, LibreOffice re-resolves it, and because the bookmark covers plain text the two
  agree.
- **[S]** `hyperlink=true` appends the `\h` switch and makes the resolved reference
  clickable; its result run then needs the `Hyperlink` character style, which must be
  **defined** or it is a dangling style and a QA failure (spec §D7). The plain (non-`\h`)
  reference is the verified construction.
- **[V]** `wf-crossref.sh` reads the cache back and refuses to report success if it differs
  from the target or contains `«`/`»`.

### Measured compatibility

Fixture `fields/cached-cross-ref.docx`: a `Heading1 "Introduction"` bookmark and a
`Caption "Figure 1: …"` bookmark, body text
`See section <REF sec_intro> and <REF fig_demo> for details.`; caches `Introduction` and
`Figure 1`.

| Application | Opens without repair | Displays the reference | Cached text source |
|---|---|---|---|
| Word 16.0 | **Yes** | `See section Introduction and Figure 1 for details.` | cached result (no update on open) |
| WPS Writer 12.0 | **Yes** | `See section Introduction and Figure 1 for details.` | cached result (no update on open) |
| LibreOffice 24.2.7.2 | **Yes** | `See section Introduction and Figure 1 for details.` | re-resolves `REF` on import |

- **[V]** The harness reports `placeholder_count = 0` and `field_cache_stale = 0`, and
  Word/WPS report the live cached text `REF sec_intro => Introduction`, `REF fig_demo =>
  Figure 1`. The three agree **because the bookmark covers plain text**.

### LibreOffice divergence when the bookmark spans a field result — limitation

- **[V]** Measured probe: a caption `Figure <SEQ Figure>: …` with the bookmark opened before
  `Figure ` and closed **before the `SEQ` field's `end` `fldChar`**. OfficeCLI cached `REF`
  as `Figure 1`; Word/WPS displayed `Figure 1`, but **LibreOffice displayed `Figure`** — it
  re-resolved the `REF` and dropped the nested field result.
- **[V] Consequence:** a bookmark must not depend on a nested field result for portability.
  **Downgrade (defined, always reported):** WordFlow either (a) bookmarks a **plain-text**
  label (`Figure 1`) and keeps the caption's own `SEQ` numbering separate — portable, the
  number is a snapshot; or (b) omits the figure-number reference and cross-references the
  heading/section instead. It never ships a `REF` whose cache disagrees with what an
  application resolves.
- **[?]** Whether closing the bookmark *after* the `SEQ` `end` `fldChar` makes LibreOffice
  agree is unverified; OfficeCLI's `add bookmark --text` cannot place the end there, so it
  would need `raw-set`.

## Page-number reference (`PAGEREF`) — limited, downgraded

- **[V]** A `PAGEREF` cache cannot be made correct without a layout engine: OfficeCLI's
  `refresh` fills `PAGEREF` from its own HTML pagination, whose page numbers are wrong for
  Word/WPS (`../research/field-recalc-and-cross-app-verification.md` §2), and Word/WPS ship
  a stale `PAGEREF` cache verbatim (§3). A wrong page number looks finished and is silently
  wrong.
- **[S]** Per spec §D8/§D9 WordFlow will **not present a page number it cannot guarantee**:
  `wf-crossref.sh --kind pageref` **downgrades** the request to a content reference, records
  the downgrade through the shared [risk policy](../workflow/risk-policy.md) (#30, trigger
  `preferred-unavailable` with `fallback=exists`), and adds it to the change report (spec
  §D11, §D12). It never emits a `PAGEREF`.
- **[S]** The carve-out is only a *layout-computed* `PAGE`/`NUMPAGES` footer field, which
  each reader recomputes per page (spec §D8, §D9);
  [`headers-footers.md`](../objects/headers-footers.md) holds that construction.

## When the cache cannot be made correct

If the resolved target text cannot be computed (e.g. a target whose text is itself a field
result the mechanism above cannot cover portably), WordFlow must not ship `«target»`:

1. prefer a **content reference to plain text** (the portable construction above); failing
   that,
2. **downgrade** the reference to plain run text with the target's known text (or omit the
   reference), and
3. **report** the downgrade in the change report (spec §D11, §D12).

The change report must state, for every cross-reference, that its cached result is the
resolved target text — or that the reference was omitted/downgraded because a correct cache
was not guaranteed.

## Reports and risk policy

`wf-crossref.sh` contributes plain-string entries through the shared
[change-report contract](../workflow/change-report.md) (#28) and routes the pageref
downgrade through the shared [risk policy](../workflow/risk-policy.md) (#30). It invents no
warn/downgrade logic of its own. Its JSON report carries `source`, `output`,
`source_unchanged`, the five change-report areas collapsed into `change_report`, and feature
`evidence` (the field instruction, the cached text, the placeholder flag, the dirty flag,
the paragraph text, the result-run path, and schema validity).

## Reproduction

```sh
# regenerate the fixture (also regenerates every other fixture)
tests/generate-fixtures.sh

# #12 mechanism: cache facts + rebuild + all three applications
tests/crossref-cache.sh
# #23 feature: cached text, style integrity, downgrade, source protection
tests/crossref.sh

# or drive the harness directly (Word/WPS serialised by flock)
flock -w 1800 /tmp/wordflow-wincom.lock \
  scripts/wf-compat-harness.sh tests/fixtures/fields/cached-cross-ref.docx \
  --apps word,wps,libreoffice --out tests/.out/compat/issue12 --no-visual
```

## Source

- [`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
  — no application updates fields on open; the `REF`/`PAGEREF` measured matrix.
- Fixtures `tests/fixtures/fields/cached-cross-ref.docx` and
  `tests/fixtures/fields/bookmark-ref-pageref.docx`.
- Acceptance: [`../../tests/crossref-cache.sh`](../../tests/crossref-cache.sh),
  [`../../tests/crossref.sh`](../../tests/crossref.sh).
