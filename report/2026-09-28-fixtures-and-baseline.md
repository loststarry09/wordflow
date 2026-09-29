# WordFlow — Fixtures, Research Notes & Baseline Report

- **Date**: 2026-09-28
- **Scope**: non-decisional foundation work only — fixtures, verification scripts, and research notes. No product rules, no v0.1 scope changes, no feature implementation, no change to `SKILL.md`.
- **Tooling observed**: OfficeCLI `1.0.152` at `/home/carlos/.local/bin/officecli`
- **Git**: baseline established at commit `ceffdb3`; vendored `.agents/` at `390821c`. This report itself is a post-baseline change.

## 1. What was done

1. Built a DOCX fixture suite under `tests/fixtures/` from the features verified in the DOCX research report.
2. Added a deterministic generator and a validator:
   - `tests/generate-fixtures.sh` — rebuilds every fixture with OfficeCLI, pinning `--locale` and closing each file so no resident state leaks.
   - `tests/validate-fixtures.sh` — runs `validate`, `view issues`, and a `screenshot` render over every fixture; writes renders to `tests/.out/` (git-ignored).
3. Distilled the research into reference notes under `references/research/`, each claim tagged verified / standard / uncertain.
4. Updated `tests/README.md`, `references/README.md`, the root `README.md` status, and `.gitignore`.
5. Checked Git state and committed the project baseline.

## 2. Fixtures added (17)

| Group | Fixtures |
|---|---|
| `styles/` | `heading-hierarchy`, `caption-defined`, `caption-dangling` |
| `sections/` | `margins-orientation`, `page-number-restart` |
| `headers/` | `page-number-footer` |
| `images/` | `inline-image`, `anchored-image` |
| `tables/` | `fixed-table` |
| `captions/` | `caption-seq` |
| `fields/` | `bookmark-ref-pageref` |
| `toc/` | `toc-basic` |
| `notes/` | `footnote-basic` |
| `equations/` | `inline-equation`, `display-equation` |
| `cjk/` | `cjk-fonts-indent` |
| `portability/` | `transitional-baseline` |

Supporting files: `tests/fixtures/MANIFEST.md` (per-fixture purpose, expected construction, notes), `tests/fixtures/assets/test-image.png` (96x64 red rectangle, embedded as base64 in the generator so regeneration needs no image library).

Each fixture documents what it tests in the manifest. Fixtures are committed as snapshots; regenerated files are not byte-identical because OfficeCLI stamps timestamps.

## 3. Validation results

- `officecli validate`: **17/17 pass**.
- `view issues`: only advisory heuristics, no schema errors:
  - `[F] Body paragraph missing first-line indent` — for `Normal` body paragraphs without a 2-character first-line indent; an opinionated typography suggestion, suppressed by `firstLineChars=200`.
  - `[S] Empty paragraph` — for the blank paragraph carrying a section break; expected under the section model.
- `screenshot --grid auto`: **17/17** produced non-empty PNGs. Visual spot checks of `toc-basic` (TOC entries and page numbers rendered) and `cjk-fonts-indent` (Chinese text, visible first-line indent) were correct.
- `transitional-baseline`: namespace assertion passes (Transitional, no `purl.oclc.org`).
- Totals: `35 checks run | 35 passed | 0 failed`. The generator is repeatable across runs.

## 4. Research notes added

Under `references/research/` (a holding area, not finished guidance; claims tagged `[V]` verified, `[S]` standard-backed, `[?]` uncertain):

- `officecli-behavior.md` — observed OfficeCLI 1.0.152 behaviour (creation defaults, styles, sections, headers/footers, fields, TOC, rules for pictures/equations/notes, indentation/CJK, validation, round-trip, resident pitfalls).
- `docx-feature-portability.md` — per-feature portable construct, OfficeCLI support, and compatibility caveat, grouped by core/fields/objects/compatibility, with a most→least portable summary.

Also updated `references/README.md` to describe `research/` as the holding area whose facts move into the concern directories once a real task needs them.

## 5. New facts / tool problems

1. **`refresh` does not resolve `REF`.** After `refresh`, `REF target \h` reports `evaluated=true` but its cached text stays the placeholder `«target»`, while `PAGEREF` in the same paragraph resolves to `1`. The `evaluated` flag alone is not trustworthy for `REF`.
2. **`refresh` does fill TOC and `PAGEREF` on Linux** via the HTML backend, but TOC cached page numbers read as the same value (HTML pagination artifact).
3. **`firstLineChars` is set/get only, not add.** Add the paragraph, then `set … firstLineChars=200`. `firstLineIndent=2em` is rejected; only lengths are accepted.
4. **Resident state leaks between files.** Without `close`, a `rm` + `create` on the same path can operate on the previous in-memory document and produce non-deterministic results. The scripts close each file.
5. **`view issues` is heuristic, not schema.** It exits 0 and reports style opinions alongside structure notes; `validate` remains the schema gate.
6. **`add section` inserts an empty break paragraph**, and the final `body/sectPr` is `/section[2]` in a two-section document; set the second section after adding its content.
7. **`--locale` drives `docDefaults`** (`en-US` → Times New Roman; `zh-CN` → `eastAsia=等线`). Omitting it makes output host-dependent and non-reproducible.
8. **Confirmed dangling-style behaviour**: only some built-ins (`Title`, `Heading1`–`Heading9`) are auto-defined; `Caption` is not, reproducing a dangling reference (`styles/caption-dangling.docx`).
9. **Transitional emission confirmed**: `xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"`, `mc:Ignorable="w14 w15 wp14"`, no Strict namespace.

This corrects the initialization report's statement that DOCX `refresh` requires Word + Windows, and its statement that TOC page numbers cannot be produced without Word (the HTML fallback produces them, best-effort).

## 6. Git state

- `main` has two commits: `ceffdb3` (`chore: initialize WordFlow baseline …`) and `390821c` (`chore: vendor local engineering workflow skills (.agents)`).
- Working tree was clean after the baseline; this report and its index entry are currently **uncommitted**.
- `.agents/` (89 files, ~932K) was committed separately so it can be dropped or re-scoped without touching the baseline.
- No destructive operations (no reset, force-push, or history rewrite).

## 7. Open decisions (for the user)

- Whether `.agents/` should remain committed; it is isolated in its own commit.
- Whether fixtures should stay committed snapshots or be generated on demand (both are currently provided).
- Whether the advisory "body paragraph missing first-line indent" heuristic becomes a WordFlow rule (a product decision).
- How to handle the `REF` placeholder `«target»` — accept it, or require a fallback at generation time.
- Whether the Linux `refresh` HTML fallback is trustworthy enough to rely on.
- The compatibility target: which Word / WPS Writer / LibreOffice Writer versions.
- Whether to add negative/edge fixtures (Strict OOXML, dangling table style, TOC without cache, nested tables).
