# Figure and table captions

How WordFlow produces a **figure or table caption** that uses the Caption style and an
automatic numbering field (`SEQ`) whose *cached result is correct and never a placeholder*,
so the document never ships a stale or placeholder number. This is the caption reference
for issue [#22](https://github.com/loststarry09/wordflow/issues/22); the same mechanism is
consumed by cross-references ([`cross-references.md`](./cross-references.md)).

Companion evidence:
[`../research/field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
(§1–§4, §6). Fixtures: `tests/fixtures/captions/caption-seq.docx`,
`tests/fixtures/styles/standard-style-set.docx`. Test: `tests/caption.sh`.
Tool: `scripts/wf-caption.sh`.

Legend:

- **[V]** — verified by running the tools locally (OfficeCLI `1.0.153`; LibreOffice
  `24.2.7.2` via the compatibility harness; Word `16.0` / WPS `12.0` figures carried over
  from the field-recalc research).
- **[S]** — backed by OOXML / ECMA-376 or another primary source.
- **[?]** — reported or reasoned but not confirmed locally; treat as uncertain.

## 1. The constraint

- **[V]** No application updates fields on open. Word 16 and WPS 12 display a complex
  field's cached result **verbatim**; LibreOffice does not rebuild it either. The
  *cached result is what the reader sees* (research §3, §6).
- **[V]** `officecli add <docx> /body --type field --prop fieldType=seq` writes the
  `SEQ <identifier>` instruction **and** a cached result immediately, so every field reads
  `evaluated=true`; for a `SEQ` field the initial cache is a bare `1` (research §1).
  A field is therefore judged by its **cached text**, never by its `evaluated` flag.
- **[S]** In a complex field the instruction sits between `w:fldChar begin` and `w:fldChar
  end`, and the cached result between `w:fldChar separate` and `w:fldChar end`
  (ECMA-376 §17.16). The cache is a stored snapshot the consumer may regenerate; WordFlow
  must write the correct value into it.

**Consequence.** A caption is only correct if its `SEQ` field's cached result is the
resolved number. A placeholder (`«»`, `Update field…`, `#OCLI_NOTEVAL!`) must never ship
silently (spec §D8, §D11, §D14).

## 2. Portable construction

Build each caption in document order as three parts, then compute the number:

1. **The Caption style must be defined first** (spec §D7/§D14). The standard set defines
   `Caption`; if the document does not, add the standard definition and nothing else.
2. **The caption paragraph** — `style=Caption`, leading label text `"Figure "` / `"Table "`.
3. **The `SEQ` field** — `fieldType=seq`, `id=Figure` / `id=Table`.
4. **The trailing text** — a run `": <caption text>"`.
5. **Compute the cache** — `officecli set / --prop recalcFields=seq`.

```sh
# 1. the standard Caption definition, only when the document lacks one
officecli add F /styles --type style \
  --prop styleId=Caption --prop name="caption" --prop type=paragraph \
  --prop basedOn=Normal --prop qFormat=true --prop align=center

# 2-4. "Figure " + <SEQ Figure> + ": <text>"  (id=Table for table captions)
officecli add F /body --type paragraph --prop style=Caption --prop text="Figure "
officecli add F /body/p[N] --type field --prop fieldType=seq --prop id=Figure
officecli add F /body/p[N] --type run  --prop text=": Example figure caption."

# 5. SEQ numbering in body document order -> the field's cached result
officecli set F / --prop recalcFields=seq
```

- **[V]** `recalcFields=seq` "compute[s] and write[s] cached field values officecli CAN
  evaluate without a layout engine — currently SEQ numbering (Figure/Table 1,2,3… counted in
  body document order, honouring `\n` / `\c` / `\r` and arabic/roman/alphabetic formats)"
  (`officecli help docx set document`). A second `SEQ Figure` in the body therefore caches
  `2`, an independent `SEQ Table` caches `1`.
- **[V]** The result run is deterministic for a paragraph WordFlow builds: the runs are
  `begin`, `instrText`, `separate`, **result**, `end`. Read the cached text back from the
  paragraph's children, taking the first `run` after the `instrText` — do not address the
  field through `/field[N]` (that exposes the instruction and a read-only flag, not the
  cached run).
- **[V]** The Caption style is applied, never expanded: a source that already defines
  `Caption` keeps its definition (fixture `styles/standard-style-set.docx`, whose `Caption`
  is named 图注表注, is left unchanged); a source without it gains exactly the standard
  definition above.
- **[V]** No `raw-set` is needed. Unlike a cached cross-reference (whose `w:dirty` marker
  must be cleared), `recalcFields=seq` writes the `SEQ` cache cleanly: `officecli validate`
  passes and `officecli view issues` raises no `field_cache_stale`.

## 3. Compatibility (measured)

| Application | Opens without repair | Displays the caption number | Number source |
|---|---|---|---|
| Word 16.0 | **Yes** [V] | cached (`Figure 1: …`) | cached result (no update on open) |
| WPS Writer 12.0 | **Yes** [V] | cached (`Figure 1: …`) | cached result (no update on open) |
| LibreOffice 24.2.7.2 | **Yes** [V] | cached (`Figure 1: …`) | cached result |

- **[V]** All three applications open the committed fixtures repair-free (LibreOffice via
  `scripts/wf-compat-harness.sh ... --apps libreoffice`, `opens_without_repair=true`);
  Word/WPS repair-free and cache-verbatim behaviour is the field-recalc research (§3).
- **[V]** Because the cached number is correct and the field is not dirty, the harness
  reports `placeholder_count = 0` for the document — the visible caption is finished, not a
  placeholder.
- **[S]** `SEQ` is standard Transitional OOXML; the caption introduces no application-specific
  extension.

## 4. When the number cannot be resolved (downgrade)

If the cached text read back is not the resolved number (empty, a placeholder, or
non-numeric), WordFlow must not ship it:

1. **omit the automatic number** — leave the caption's label and text without the `SEQ`
   field, and
2. **report** the omission through the shared risk policy
   (`scripts/wf-risk-policy.sh emit --trigger unverifiable-field --resolution omit`, spec
   §D11 → a `downgrade` entry in the change report's `unverified` area).

The change report always states, for the caption, that the cached number was computed and
verified — or that it was omitted because a correct cache could not be produced. A
placeholder cache is never shipped silently.

## 5. Caveat — referencing the caption number

A cross-reference to an auto-numbered caption is a separate capability (#23). The
measured limitation is that a bookmark spanning a live `SEQ` result is dropped by
LibreOffice, so the reference must target plain text or be downgraded
([`cross-references.md`](./cross-references.md) §LibreOffice divergence). WordFlow keeps the
caption's own `SEQ` numbering and the cross-reference mechanism separate.

## 6. Reproduction

```sh
# regenerate the fixtures
tests/generate-fixtures.sh

# add a caption and read the JSON evidence back
scripts/wf-caption.sh tests/fixtures/captions/caption-seq.docx \
  --out /tmp/caption.docx --kind figure --text "Example." --json

# the #22 acceptance test: cached numbers, style integrity, source protection,
# reproducibility, and LibreOffice opens-without-repair
tests/caption.sh
```
