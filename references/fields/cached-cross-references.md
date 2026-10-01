# Cached cross-references (REF)

How WordFlow produces a **content cross-reference** (`REF` field) whose *cached result is the
resolved target text*, so the document never ships the placeholder `«target»`. This is the E05
reference; the mechanism was proved and measured in issue [#12](https://github.com/loststarry09/wordflow/issues/12).

Companion evidence: [`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
(§1–§4, §6). Fixture: `tests/fixtures/fields/cached-cross-ref.docx`. Test: `tests/crossref-cache.sh`.

Legend:

- **[V]** — verified by running the tools locally (OfficeCLI `1.0.152`/`1.0.153`; Word `16.0`;
  WPS Writer `12.0`; LibreOffice `24.2.7.2`).
- **[S]** — backed by OOXML / ECMA-376 or another primary source.
- **[?]** — reported or reasoned but not confirmed locally; treat as uncertain.

## 1. The constraint

- **[V]** `officecli add <docx> /body --type field --prop fieldType=ref --prop name=<bookmark>`
  writes the `REF <bookmark>` instruction **and** a cached result of the literal `«target»`.
- **[V]** `officecli refresh` never resolves `REF`; its cached text stays `«target»`.
- **[V]** Word 16 and WPS 12 display a complex field's cached result **verbatim** and do **not**
  update fields on open (not even with `w:updateFields=true`). So the cache is what the user sees.
- **[V]** LibreOffice Writer *does* resolve `REF` on import, ignoring the cache — but that does not
  help Word/WPS, and it can override a correct cache with its own reading (see §5).
- **[S]** In OOXML a complex field places its instruction between `w:fldChar begin` and `w:fldChar
  end`, and its cached result between the `w:fldChar separate` and `w:fldChar end` (ECMA-376
  §17.16). The instruction is authoritative; the cache is a stored snapshot the consumer may
  regenerate.

**Consequence.** A content cross-reference is only correct if the cached result run already holds
the resolved target text. `«target»` must never ship silently (spec §D8, §D11, §D14).

## 2. Portable construction

1. **Create the target**, with a **plain-text bookmark** covering exactly the text the reference
   should insert (see §4 for per-target detail).
2. **Add the `REF` field** pointing at that bookmark.
3. **Write the resolved text into the field's cached result run** — the `run` immediately after the
   field's `separate` `fldChar`.
4. **Clear the `w:dirty` marker** OfficeCLI adds when the cached result changes; otherwise the field
   reads as a stale cache (and OfficeCLI reports `field_cache_stale`). The `field` element exposes no
   `dirty` property, so this one step is `raw-set` — the recorded raw-set fallback (SKILL rule 4).

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
  `"dirty": true` and `officecli view <docx> issues` raises subtype `field_cache_stale`
  ("cached value may differ from re-evaluation"). After step 4 the field reads clean
  (`dirty` absent, no issue) and `officecli validate` passes.
- **[V]** The result-run index is deterministic for a paragraph WordFlow builds (the `REF` field's
  runs are `begin`, `instrText`, `separate`, **result**, `end`). For an arbitrary document, locate
  it from the paragraph's child list:

```sh
officecli get doc.docx /body/p[2] --json \
  | jq -r '.data.results[0].children as $c
           | ($c | to_entries
                  | map(select(.value.type=="fieldChar"
                               and .value.format.fieldCharType=="separate"))
                  | .[0].key) as $s
           | $c[$s+1].path'          # -> the cached result run to `set`
```

Do **not** address the field through `/field[N]`: that path exposes `instruction` and read-only
`evaluated`/`dirty`, but no way to write the cached text. The result run is addressed as
`<paragraph>/r[N]`.

## 3. What to insert for each target kind

The rule is the same in every case: the bookmark must cover exactly the text the reference should
insert, and that same text is written into the `REF` cache.

- **Heading** — bookmark wraps the heading's text run(s); the cache is the heading text
  (e.g. `Introduction`). **[V]** (`tests/fixtures/fields/cached-cross-ref.docx`).
- **Figure / table caption** — WordFlow bookmarks the **label + number** region (e.g. `Figure 1`),
  not the whole caption, so `REF` inserts `Figure 1`. **[V]** for a plain-text label. OfficeCLI
  `add bookmark --prop text="Figure 1"` wraps that existing text prefix inside the caption
  paragraph (it splits the run). See the field-spanning caveat in §5 if the label contains a live
  `SEQ` field.
- **Equation** — bookmark the equation-number text (e.g. `(1)`) and cache that text; identical to
  the heading case. **[?]** not measured locally (OfficeCLI has no equation-numbering primitive;
  the number is authored text).
- **Page-number reference (`PAGEREF`, "see page N")** — **not** a content reference and **not**
  supported: WordFlow cannot compute a page number, so it is **limited** and downgrades to a content
  reference where possible (spec §D9). A stale `PAGEREF` cache is shipped verbatim by Word/WPS
  (LibreOffice recomputes). Do not present a page number you cannot guarantee.

Hyperlinked cross-references: `--prop hyperlink=true` appends the `\h` switch so the resolved
reference is a clickable hyperlink. The result run then needs the `Hyperlink` character style, which
must be **defined** in the style set (spec §D7; a dangling style is a QA failure). **[?]** The plain
(non-hyperlink) reference used by the fixture needs no extra style and is the verified construction.

## 4. Compatibility (measured)

Fixture `tests/fixtures/fields/cached-cross-ref.docx`: a `Heading1 "Introduction"` bookmark and a
`Caption "Figure 1: …"` bookmark, with the body text
`See section <REF sec_intro> and <REF fig_demo> for details.`; caches `Introduction` and `Figure 1`.

| Application | Opens without repair | Displays the reference | Cached text source |
|---|---|---|---|
| Word 16.0 | **Yes** | `See section Introduction and Figure 1 for details.` | cached result (no update on open) |
| WPS Writer 12.0 | **Yes** | `See section Introduction and Figure 1 for details.` | cached result (no update on open) |
| LibreOffice 24.2.7.2 | **Yes** | `See section Introduction and Figure 1 for details.` | re-resolves `REF` on import |

- **[V]** All three render the resolved text; the harness reports `placeholder_count = 0` and
  `field_cache_stale = 0` for the document, and Word/WPS report the live cached text
  `REF sec_intro => Introduction`, `REF fig_demo => Figure 1`.
- **[V]** The three agree **because the bookmark covers plain text**. LibreOffice re-resolves `REF`
  and its result is what it shows; when the bookmark covers plain text its re-resolution equals the
  text WordFlow cached.

## 5. LibreOffice divergence when the bookmark spans a field result — limitation

- **[V]** Measured probe: a caption `Figure <SEQ Figure>: …` (live numbering field) with the
  bookmark opened before `Figure ` and closed **before the `SEQ` field's `end` `fldChar`**. OfficeCLI
  cached `REF` as `Figure 1`; Word and WPS displayed `Figure 1`, but **LibreOffice displayed
  `Figure`** — it re-resolved the `REF` itself and dropped the nested field result.
- **[V] Consequence:** a bookmark must not depend on a nested field result for portability.
  **Downgrade (defined, always reported):** for an auto-numbered caption the label's number is not
  itself referenceable through OfficeCLI's DOM, so WordFlow either
  (a) bookmarks a **plain-text** label (`Figure 1`) and keeps the caption's own `SEQ` numbering
  separate — portable, the number is a snapshot; or
  (b) omits the figure-number reference and cross-references the heading/section instead.
  It never ships a `REF` whose cache disagrees with what an application will resolve.
- **[?]** Whether closing the bookmark *after* the `SEQ` `end` `fldChar` makes LibreOffice agree is
  unverified; OfficeCLI's `add bookmark --text` cannot place the end there, so it would need
  `raw-set`.

## 6. When the cache cannot be made correct (downgrade)

If the resolved target text cannot be computed (e.g. a target whose text is itself a field result
that the mechanism above cannot cover portably), WordFlow must not ship `«target»`:

1. prefer a **content reference to plain text** (the portable construction in §2); failing that,
2. **downgrade** the reference to plain run text with the target's known text (or omit the
   reference), and
3. **report** the downgrade in the change report (spec §D11, §D12).

The change report must state, for every cross-reference, that its cached result is the resolved
target text — or that the reference was omitted/downgraded because a correct cache was not
guaranteed. A placeholder cache is never shipped silently.

## 7. Reproduction

```sh
# regenerate the fixture (also regenerates every other fixture)
tests/generate-fixtures.sh

# the #12 acceptance test: cache facts + rebuild + all three applications (COM under the shared lock)
tests/crossref-cache.sh

# or drive the harness directly (Word/WPS serialized by flock)
flock -w 1800 /tmp/wordflow-wincom.lock \
  scripts/wf-compat-harness.sh tests/fixtures/fields/cached-cross-ref.docx \
  --apps word,wps,libreoffice --out tests/.out/compat/issue12 --no-visual
```
