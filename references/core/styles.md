# Standard styles and Simplified-Chinese typography

WordFlow's **standard style set** and the **Simplified-Chinese-first defaults** it applies when a
document has no usable style set and no template or formatting requirement overrides them
(spec `docs/spec/v0.1.md` §D6, §D7). This is the layout behind the style-ownership decision
`rebuild-with-standard-styles` (`references/core/style-ownership.md`, #16): styles carry the
formatting, so a paragraph's look is a property of its style, not of ad-hoc run overrides.

The font names and the explicit-slot strategy are the ones confirmed by the CJK font research
(`references/research/cjk-font-availability.md`, #8). Page geometry (A4, margins) is a distinct
concern owned by `references/core/sections.md` (#18) and is **not** applied by this primitive.

## The frozen style set (spec §D7)

Exactly this list — do not expand it. `styleId` is the identity; the display name is what the
Styles pane shows.

| `styleId` | Name | Type | Role |
|---|---|---|---|
| `Normal` | 正文 | paragraph | Default body paragraph (first-line indent) |
| `BodyNoIndent` | 正文无缩进 | paragraph | Body that must not indent (lists, captions, and similar) |
| `Title` | 标题 | paragraph | Document title |
| `Heading1` … `Heading4` | 标题 1 … 标题 4 | paragraph | Heading hierarchy, outline levels 0–3 |
| `Caption` | 图注表注 | paragraph | Figure and table captions |
| `Quote` | 引用 | paragraph | Block quotations |
| `ListParagraph` | 列表段落 | paragraph | List items |
| `TOC1` … `TOC3` | TOC 1 … TOC 3 | paragraph | Table-of-contents entries |
| `FootnoteText` | Footnote Text | paragraph | Footnote text |
| `FootnoteReference` | Footnote Reference | character | Footnote reference mark |
| `Header` | Header | paragraph | Running header |
| `Footer` | Footer | paragraph | Running footer |
| `Hyperlink` | Hyperlink | character | Links and resolved cross-references |

`Normal` is the document's **default** style (`w:style/@w:default`); every paragraph that names no
style resolves through it.

## The frozen typography (spec §D6)

| Style | CJK face | Latin face | Size | Line spacing | First-line indent | Alignment | Other |
|---|---|---|---|---|---|---|---|
| `Normal` | SimSun (宋体) | Times New Roman | 12 pt (小四) | 1.5× | 2 characters | justified | — |
| `BodyNoIndent` | SimSun | Times New Roman | 12 pt | 1.5× | none | justified | — |
| `Title` | SimHei (黑体) | Arial | 22 pt (二号) | 1.5× | none | centred | space after 18 pt |
| `Heading1` | SimHei | Arial | 16 pt | 1.5× | none | left | before 18 / after 12 pt, outline 1 |
| `Heading2` | SimHei | Arial | 14 pt | 1.5× | none | left | before 12 / after 6 pt, outline 2 |
| `Heading3` | SimHei | Arial | 13 pt | 1.5× | none | left | before 12 / after 6 pt, outline 3 |
| `Heading4` | SimHei | Arial | 12 pt | 1.5× | none | left | before 6 / after 6 pt, outline 4 |
| `Caption` | SimSun | Times New Roman | 10.5 pt (五号) | single | none | centred | before/after 6 pt |
| `Quote` | SimSun | Times New Roman | 12 pt | 1.5× | none | left | left indent 2 chars |
| `ListParagraph` | SimSun | Times New Roman | 12 pt | 1.5× | none | left | left indent 2 chars, contextual spacing |
| `TOC1` | SimSun | Times New Roman | 12 pt | single | none | left | — |
| `TOC2` | SimSun | Times New Roman | 12 pt | single | none | left | left indent 2 chars |
| `TOC3` | SimSun | Times New Roman | 12 pt | single | none | left | left indent 4 chars |
| `FootnoteText` | SimSun | Times New Roman | 9 pt (小五) | single | none | left | — |
| `Header` | SimSun | Times New Roman | 9 pt | single | none | left | — |
| `Footer` | SimSun | Times New Roman | 9 pt | single | none | centred | — |
| `Hyperlink` | SimSun | Times New Roman | — | — | — | — | colour `#0563C1`, single underline |
| `FootnoteReference` | SimSun | Times New Roman | — | — | — | — | superscript |

Spec §D6 freezes the body and heading values and the faces; the sizes for `Quote`,
`ListParagraph`, and `TOC 1–3` are WordFlow's own (D6 does not state them). The heading
space-before/after amounts are likewise chosen here (D6 says only "space before/after") and are
frozen by this table.

## Portable construction (`scripts/wf-standard-styles.sh`)

```
scripts/wf-standard-styles.sh <source.docx> --out <output.docx> [--json]
```

The source is never modified (ADR-0003): it is copied byte-for-byte to `--out` and only that new
file is changed, through OfficeCLI. The operation defines styles only; it never adds, edits, or
restyles content. It is the write side of `rebuild-with-standard-styles`.

The rules the script encodes:

1. **Set fonts explicitly on every style, never inherit `docDefaults`.** Each style carries
   `font.ea` (the `w:eastAsia` slot), `font.latin` (the `w:ascii`+`w:hAnsi` slots) and
   `font.hint=eastAsia`. Body styles use `SimSun` + `Times New Roman`; Title/headings use
   `SimHei` + `Arial`. This is the frozen strategy of §D6 and #8: OfficeCLI's `--locale zh-CN`
   default `等线`/DengXian is never relied on. `font.hint=eastAsia` makes ambiguous CJK
   punctuation resolve to the CJK face.
   ```bash
   officecli add "$out" /styles --type style \
     --prop styleId=BodyNoIndent --prop name="正文无缩进" --prop type=paragraph \
     --prop font.ea=SimSun --prop font.latin="Times New Roman" --prop font.hint=eastAsia ...
   ```
2. **Write both the character-unit and the absolute indent.** `w:firstLineChars`/`w:leftChars`
   are the canonical CJK form, but **LibreOffice ignores the character-unit attributes** (verified
   by PDF render, #17). Write the em-equivalent absolute value too — 2 characters at the 12 pt
   body size are `24pt` — so Word (character form) and LibreOffice (absolute form) agree. The
   absolute twin is rounded to the frozen body size; if a formatting requirement changes the body
   size, recompute it from the new size.
3. **`Normal` must stay the default style.** OfficeCLI's `set /styles/Normal` preserves
   `w:default`; re-`add`ing the style would drop it and silently push unstyled paragraphs onto
   `docDefaults`. The script `set`s `Normal` when it exists and only `add`s it (with
   `default=true`) when it does not.
4. **Define before use.** Only `Title` and `Heading1`–`Heading9` are auto-defined by OfficeCLI;
   every other name in the set is defined explicitly here, so no paragraph is ever left dangling
   (§D7, §D14).
5. **`--locale zh-CN` for language and grid, not for fonts.** The base document is created with
   `--locale zh-CN` so `docGrid` and the East-Asian language are Chinese, then the fonts are
   overridden at the style level.

Report shape (`--json`) — stable fields siblings depend on:

```json
{
  "source": "…", "output": "…",
  "style_set": [ { "style_id": "Normal", "name": "正文", "type": "paragraph", "default": true }, … ],
  "styles_defined": 18,
  "default_style": "Normal",
  "font_defaults": { "body_east_asia": "SimSun", "body_latin": "Times New Roman",
                     "heading_east_asia": "SimHei", "heading_latin": "Arial", "hint": "eastAsia" },
  "source_unchanged": true,
  "change_report": ["Standard styles: defined 18 style(s) — …"]
}
```

`change_report` is the entry this step contributes to the document's change report (spec §D12);
the report as a whole is assembled by the change-report layer (`references/workflow/change-report.md`, #28).

## Compatibility caveat

- **Fonts are named, not embedded.** SimSun/SimHei/Times New Roman/Arial are guaranteed on
  Windows (Word/WPS). On stock Linux none of the CJK faces is present: LibreOffice substitutes a
  local CJK face (often a Hei face), which loses the Song body and changes line height, so page
  breaks can move. This is the operating system's behaviour, not WordFlow's; #8 requires it be
  reported as an unverified/warning item when the document contains CJK and the render target is
  not the local platform. WordFlow never silently replaces the names.
- **Character-unit indents need their absolute twin** (rule 2 above), or LibreOffice renders the
  body flush left while Word indents it.
- **`view issues` is advisory.** OfficeCLI's `[F] Body paragraph missing first-line indent`
  heuristic does not resolve *style-level* indentation, so `Normal` paragraphs get an advisory
  even though the style indents them. It is not a schema error; `validate` is the gate.
- **Heading space values and non-body sizes** are WordFlow choices (§D6 freezes only the faces,
  body/heading sizes and the body indent); treat the table above as the frozen values.

## Limitations

- **Styles only.** No content, no page setup, no headers/footers, no numbering. Lists use
  `ListParagraph` but the numbering definition is a separate concern.
- **Define, do not tidy.** Existing styles with a different `styleId` are left in place; this
  primitive is the rebuild outcome, not the tidy outcome. Removing unused or foreign styles is
  the tidy step's job.
- **`customStyle` is set per style** — `BodyNoIndent` is WordFlow's own and is marked custom;
  the built-in ids (`Normal`, `Title`, `Heading1–4`, `Caption`, `Quote`, `ListParagraph`,
  `TOC1–3`, `Header`, `Footer`, `FootnoteText`, `FootnoteReference`, `Hyperlink`) are not.
- **Font substitution is not detected here.** Probing the host for the named fonts and emitting
  the §D11 warning is a separate step (#8 §7.2).

## Evidence

- `tests/fixtures/styles/standard-style-set.docx` — the full style set (spec §D7), each style
  defined and used once: body, no-indent body, title, four headings, caption, quote, list,
  the three TOC levels, footnote text and reference, header, footer, and a hyperlink.
- `tests/standard-styles.sh` — acceptance checks: exact style set, no dangling reference, every
  style used, D6 typography, explicit font slots, operation behaviour, and a LibreOffice render.
- `references/research/cjk-font-availability.md` — the font and substitution facts (#8).
