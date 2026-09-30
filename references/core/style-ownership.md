# Style inspection and ownership decision

How WordFlow decides what to do with the styles a source document already has. This is the
first judgement in the **restyle** path (spec `docs/spec/v0.1.md` §D5, §D7): before laying
anything out, decide whether to **preserve and tidy** the document's own styles, **adopt a
template's** styles, or **rebuild** with WordFlow **standard styles**.

Reading this file does not implement any of those three outcomes. It only produces the
*decision*; applying standard styles is `#17`, template adoption is `#27`, and the tidy
operations belong to the restyle workflow.

## What to inspect

All facts come from OfficeCLI; WordFlow never parses the document itself (ADR-0001).

| Fact | Source | Notes |
|---|---|---|
| Styles the document **defines** | `officecli get <doc> /styles` | Each `/styles/style[n]` carries `styleId`, `name`, `type`, `default`. |
| Styles it **references** (with counts) | `officecli view <doc> stats` → *Style Distribution* | Keyed by style **name**, not `styleId`. Includes styles referenced but not defined. |
| **Dangling** styles | referenced − defined | Referenced, but no matching definition exists. |
| **Unused** defined styles | defined − referenced | Defined, but no paragraph uses them (default style excluded). |
| **Heading hierarchy** | referenced names matching `heading N` / `标题 N` | A signal, not the decision itself. |

`officecli view <doc> issues` does **not** report a paragraph that references a style that was
never defined — the dangling reference is only visible by comparing referenced names against
defined names. Do not rely on `view issues` to find dangling styles.

## Definitions

- **Named styles in use** — referenced paragraph styles other than the document's default
  style. A document whose every paragraph is the default style has *no* usable style set,
  even if it uses direct run formatting.
- **Coherent** — no dangling style references. A document can be usable but incoherent (it
  uses named styles, but one of them is not defined); the tidy step repairs that.
- **Usable** — the document uses at least one named style. Style-driven structure is the
  thing worth preserving; direct formatting is not a style set.

## The decision

Precedence, highest first (spec §D2, §D5):

1. **A template was supplied → `use-template-styles`.** A template outranks the document's
   own styles; its style inventory is read and reported. (A written formatting requirement
   outranks even the template, but that is the intake layer's concern, not this decision.)
2. **The document uses named styles → `preserve-and-tidy`.** Keep the author's style set; the
   tidy step repairs dangling references and may drop unused definitions.
3. **No named styles are in use → `rebuild-with-standard-styles`.** There is nothing worth
   preserving, so the standard style set applies.

### Interpretation: "coherent" in spec §D5.3

Spec §D5.3 words the preserve condition as "a usable, **coherent** style set". This operation
treats **coherent** (no dangling references) as a *reported quality flag*, not as a rebuild
trigger: a document that uses named styles but has a dangling reference is still
`preserve-and-tidy`, with the dangling reference recorded as a repair item. Rebuilding would
discard the author's style intent over a single missing definition, and §D14 already treats a
dangling style as a defect the tidy step must repair. This follows the requirements wording
("rebuild only when there are none") rather than the stricter reading of §D5.3; it is recorded
here so the decision can be confirmed or tightened deliberately.

## Reproducible operation

```
scripts/wf-style-ownership.sh <source.docx> [--template <template.docx>] [--json]
```

It is read-only: it opens the source through OfficeCLI, prints the inventory, the decision and
a change-report line, and never writes to the source. It exits non-zero only on bad usage, a
missing dependency, or a document OfficeCLI cannot read.

JSON shape (stable fields other work depends on):

```json
{
  "source": "…", "template": null,
  "defined_styles": ["Normal", "Title"],
  "referenced_styles": { "Normal": 3, "Title": 1 },
  "dangling_styles": [], "unused_styles": [],
  "named_styles_in_use": ["Title"],
  "heading_levels": [1, 2, 3],
  "has_heading_hierarchy": true,
  "template_styles": [],
  "coherent": true,
  "decision": "preserve-and-tidy",
  "reason": "…",
  "change_report": ["Style ownership: preserve-and-tidy — …"]
}
```

`change_report` is the entry this decision contributes to the document's change report
(spec §D12). The rest of the report is assembled by the change-report layer (`#28`); do not
format a report here.

## Limitations

- **Paragraph styles only.** The report is built from paragraph style distribution and
  `/styles`; character and table styles are not classified.
- **Structure is limited to headings.** The only structural fact the decision needs is the
  heading outline (`heading_levels`). A full structural inventory (sections, tables, images,
  lists) is not built here; those belong to the object/field references when a task needs them.
- **Name-based matching.** OfficeCLI reports referenced styles by name; definitions carry both
  `styleId` and `name`. Matching is case-insensitive by name, so two definitions sharing a
  name would be ambiguous. Word does not normally allow this.
- **Direct formatting is not a style set.** A document that *looks* styled but uses direct
  run formatting is `rebuild-with-standard-styles`, not `preserve`.
- **Heading detection is heuristic** and localised (`heading N`, `标题 N`); a custom heading
  style with another name will not register as a heading hierarchy.
- **Coherence is dangling-only.** "Incoherent" here means a dangling reference; deeper
  inconsistencies (conflicting definitions, orphaned based-on chains) are not judged in v0.1.

## Evidence

- `tests/style-ownership.sh` — acceptance checks over `styles/heading-hierarchy.docx`
  (preserve), `styles/unstyled.docx` (rebuild), `styles/template.docx` (template wins), and
  `styles/caption-dangling.docx` (preserve with a repair).
- `references/research/officecli-behavior.md` — OfficeCLI style auto-definition is partial;
  only a small set of built-ins is defined automatically.
