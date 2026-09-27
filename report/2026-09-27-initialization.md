# WordFlow — Project Initialization Report

- **Date**: 2026-09-27
- **Scope**: project initialization only (no layout knowledge or features)
- **Tooling observed**: OfficeCLI `1.0.152`

## 1. Existing capabilities found

### OfficeCLI (DOCX)

- **Styles / structure**: `style` (paragraph & character styles; `basedOn`, `next`, `outlineLvl`, `numId`; built-in ids: Normal, Heading1..9, Title, Subtitle, Quote, ListParagraph, TOCHeading), `section` (page size, orientation, margins, header/footer distances, gutter; `mirrorMargins`, even/odd headers)
- **Headers / footers**: `header` / `footer` (default, first, even; can insert page / numpages / date fields)
- **Fields & references**: `field` (page, numpages, pageref, ref, noteref, seq, styleref, docproperty, if, …), `toc` (levels / hyperlinks / pageNumbers; complex field), `bookmark`, `hyperlink` (internal `anchor`)
- **Notes / math / objects**: `footnote`, `endnote`, `equation` (LaTeX-ish; display/inline), `picture` (inline/anchored, wrap, crop, alt/decorative), `table`/`table-row`/`table-cell`, `chart`, `comment`, `sdt`, `formfield`, `watermark`
- **Low level & safety**: `raw` / `raw-set` / `add-part` (universal fallback), `validate`, `view issues`, `dump` / `batch` (replayable round-trip), `refresh` (**DOCX requires Word + Windows**), `create` / `merge`

**Notable gaps (shape later design):** no first-class **caption**, **cross-reference**, or **bibliography/citation** element — must be composed from `Caption style + SEQ field`, `REF/PAGEREF field + bookmark`. TOC page numbers cannot be computed without Word in the loop.

### Skills

- **OfficeCLI-bundled skills (all not installed):** `word`, `academic-paper`, `word-form`, `pptx`, `excel`, `morph-ppt`, `morph-ppt-3d`, `pitch-deck`, `data-dashboard`, `financial-model`
- **Matt Pocock engineering skills already installed** in `.agents/skills/`: `grill-me`, `grill-with-docs`, `grilling`, `setup-matt-pocock-skills`, `domain-modeling`, `to-spec`, `to-tickets`, `triage`, `wayfinder`, `implement`, `research`, `tdd`, `writing-for-agents`, and more
- **Global skills of note:** `officecli`, `writing-for-agents`
- No `AGENTS.md` / `CLAUDE.md` / `CONTEXT.md` present

### Git

- No git repository at check time. Ran `git init` (branch `main`); **no commits made**.

## 2. Files created

- `README.md` — positioning, goals, non-goals, core principles, structure, prerequisites, status
- `SKILL.md` — minimal skeleton (frontmatter + core rules + workflow + pointers; no layout knowledge)
- `references/README.md` — index and convention for adding reference files
- `references/{core,fields,objects,compatibility}/.gitkeep`
- `tests/README.md`, `tests/fixtures/.gitkeep`
- `docs/README.md`, `docs/adr/.gitkeep`
- `.gitignore`
- `report/README.md`, `report/2026-09-27-initialization.md` (this file)

## 3. Current project structure

```
wordflow/
├── README.md
├── SKILL.md
├── .gitignore
├── references/  README.md + core/ fields/ objects/ compatibility/
├── tests/       README.md + fixtures/
├── docs/        README.md + adr/
├── report/      README.md + dated reports
└── .agents/skills/   （pre-existing）
```

Structure adjustment rationale: the suggested layout is kept; added `.gitignore` and `docs/adr/` (aligned with the installed `domain-modeling` / `grill-with-docs` conventions), and `references/` is split by **concern** rather than by OfficeCLI element, because one element spans several concerns.

## 4. Decisions locked in

- Positioning: WordFlow is the judgement layer; **OfficeCLI is the single execution layer** — its capabilities are not re-implemented
- Seven core principles (compatibility first, style-driven, standards over shortcuts, reproducible by construction, verify before reporting done, progressive disclosure)
- Reference knowledge is loaded on demand; one topic per file; record the decision, not the OfficeCLI schema
- Tests target real DOCX files and check Word/WPS/LibreOffice plus `validate` / `issues`

## 5. Open questions (to resolve via grilling)

1. **Input/output scope**: DOCX only? Include docm/dotx? Input source (Markdown/pandoc, template, plain text)?
2. **Compatibility target & test matrix**: which apps/versions must pass? Can WPS and LibreOffice run in CI?
3. **Citations & bibliography**: in scope? Which style (GB/T 7714 / APA / IEEE)? Word's Citations & Bibliography is not portable — what is the alternative?
4. **First-time TOC/page-number rendering**: without Word, `refresh` cannot run. Accept "write dirty fields + `updateFields=true`, recompute on open"?
5. **Style system**: does WordFlow define a canonical style set (CJK fonts, first-line indent, line spacing) or derive per document?
6. **Template strategy**: start from a blank document or a reference template (`merge`)?
7. **Packaging & discovery**: where `SKILL.md` is installed (`.agents/skills/wordflow/`, Claude, Codex)? Install OfficeCLI's `word` / `academic-paper` skills as references?
8. **Test harness**: assertion method (`validate` + `issues` + XML path queries, or render diff)? Which runner?

## 6. Recommended next step

Run `/grill-with-docs` to resolve the frontier above and produce `CONTEXT.md` plus the first ADRs; then `/setup-matt-pocock-skills` for issue-tracker and domain-doc configuration. Only after that is it worth writing the first reference (suggest `references/core/styles.md` or `references/core/sections-margins.md`).

## 7. Constraints observed

No OfficeCLI skills installed, no global environment changes, no commits made.
