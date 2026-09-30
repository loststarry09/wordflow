# Chinese punctuation, kinsoku, and compression across Word / WPS / LibreOffice

How the three target applications break CJK lines around punctuation, whether they can be
steered through OOXML, and whether WordFlow v0.1 must set anything in its Simplified-Chinese
defaults. This is a **facts** file, not product guidance.

Legend:

- **[V]** — verified by running the tools locally (versions and commands in §7).
- **[S]** — backed by ECMA-376 / ISO 29500 or another primary-source document.
- **[?]** — reported or expected but not confirmed here; treat as uncertain.

Scope: the CJK typography behaviours named by issue #7 and spec `docs/spec/v0.1.md` **§D6**
(Simplified-Chinese defaults) and **§D10 / Further Notes** (untested "Chinese
punctuation/kinsoku compression"):

- line-start / line-end forbidden characters (禁则 / kinsoku);
- punctuation compression / squeezing (标点压缩 / 挤压);
- where Word 16, WPS Writer 12, and LibreOffice 24.2 differ;
- whether OOXML / OfficeCLI can express the behaviour, naming the property;
- whether WordFlow v0.1 must set anything.

## 1. Method

- **Fixture.** `tests/fixtures/cjk/cjk-punctuation-kinsoku.docx`, built by
  `tests/generate-fixtures.sh` with `officecli create --locale zh-CN`. It fixes the page to
  A4 with the §D6 margins (2.54 / 3.17 cm), so the text column is 8312 twips wide; each test
  paragraph then carries `rightIndent=1112` and `firstLineIndent=0`, leaving **exactly 7200
  twips = 30 full-width 12 pt characters per line**. A forbidden punctuation placed after 30
  ideographs therefore falls on the next line unless the application applies kinsoku — the
  boundary is deterministic rather than incidental. Body metrics are the §D6 pair
  (`font.ea=SimSun`, `font.latin=Times New Roman`, `font.hint=eastAsia`, 12 pt). Content:
  a closing `，` at a would-be line start; an opening `“` at a would-be line end; a `（`/`）`
  bracket pair; a punctuation-dense block (`。”` `……` `——` `【】` `？！` `《》`); mixed
  CJK/Latin/digit with a long Latin token; and a no-punctuation control. **[V]**
- **Rendering.** Each document was rendered to PDF by each application:
  LibreOffice 24.2.7.2 headless (`soffice --convert-to pdf`, isolated profile); Microsoft
  Word 16 and WPS Writer 12 over COM (`Word.Application` / `KWPS.Application`,
  `Documents.Open` then `ExportAsFixedFormat`, read-only, quit afterwards). COM calls were
  serialized with `flock` against a shared lock. **[V]**
- **Inspection.** Each PDF was read at character level with `pdfminer.six`: per rendered
  line the first and last character, the inter-character gaps, and the advance width of every
  CJK punctuation glyph. A line whose first character is a closing/trailing punctuation
  (`。，、；：？！）】》」』”’`) or whose last character is an opening one (`（【《「『“‘`) is
  reported as a **forbidden-boundary** line. **[V]**
- **Controls.** A second set of documents was built by adding one property to every paragraph
  of the fixture (`kinsoku=false`, `overflowPunct=false`, `topLinePunct=true`,
  `autoSpaceDE=false`+`autoSpaceDN=false`, `wordWrap=false`) and by setting the document
  setting `charSpacingControl=compressPunctuation` (OfficeCLI's default is `doNotCompress`).
  Each was rendered and compared with the base. **[V]**
- **Environment.** Windows 11 (10.0.26200) via WSL for Word/WPS; Ubuntu 24.04 for
  LibreOffice. SimSun/SimHei are present (Windows fonts on the Linux host, as in #8); Word
  and WPS use the real Windows SimSun. **[V]**

## 2. Default behaviour — the per-application comparison

With no kinsoku/compression properties set (OfficeCLI's `--locale zh-CN` output, which is what
WordFlow's default layout produces), all three applications render the fixture without a
single forbidden-boundary line: **0 of 24 rendered lines in each application start with a
closing punctuation or end with an opening one. [V]**

The applications agree on the *correctness* of the boundary and differ on *where* the line
breaks fall:

| Aspect | Word 16.0 | WPS Writer 12.0 | LibreOffice 24.2.7.2 |
|---|---|---|---|
| Closing punctuation forced to a would-be line start | Pulls the preceding character down so the punctuation is not first (line = 29 chars) **[V]** | Same as Word **[V]** | **Hangs** the punctuation into the right margin (line = 31 chars incl. `，`); never moves it to the next line **[V]** |
| Opening punctuation (`“`, `（`) forced to a would-be line end | Pushes it to the next line **[V]** | Same as Word **[V]** | Same **[V]** |
| Punctuation-dense run (`。”` `……` `——` `【】` `？！` `《》`) | Breaks at one point **[V]** | Breaks 1–2 characters earlier than Word on some lines **[V]** | Matches Word on this fixture **[V]** |
| Forbidden-boundary lines (all paragraphs) | **0** | **0** | **0** |
| Punctuation advance width at 12 pt body | Full-width (12.00 pt) for `。，、；：？！（）【】《》…—` | Full-width (12.00 pt) | Full-width (12.00 pt) |
| Punctuation compression / squeezing observed | **None** | **None** | **None** |
| Automatic CJK↔Latin / CJK↔digit space (`autoSpace`) | Present (~3.0 pt gap) **[V]** | Present (~3.0 pt gap) **[V]** | Present (~2.4 pt gap) **[V]** |
| Long Latin token (`supercalifragilisticexpialidocious`) | Kept whole, moved to next line **[V]** | Kept whole **[V]** | Kept whole **[V]** |

**Reading of the table.** The three differ in two visible ways, neither of which violates the
forbidden-character rule:

1. **Overflow vs push-down.** For a closing punctuation at the column edge, Word and WPS
   *push the last ideograph down* (kinsoku), while LibreOffice *hangs the punctuation into the
   margin* (overflow-punctuation). Both are conventional East-Asian behaviours; Word/WPS are
   the primary Windows targets and agree with each other on this rule.
2. **Break position on punctuation-dense text.** Where several full-width punctuation glyphs
   meet the column edge, the applications may choose different breaks; on this fixture WPS
   broke 1–2 characters differently from Word and LibreOffice (Word and LibreOffice coincided
   here). No application put a forbidden punctuation at a boundary. **[V]**

No punctuation was compressed in any application, including in adjacent pairs (`。”`,
`、；`, `）。`): every punctuation glyph advanced a full em. **[V]**

## 3. Do the OOXML controls work, and in which applications

OOXML exposes the behaviours as paragraph/style properties (ECMA-376 `CT_PPrBase`) and one
document setting. OfficeCLI writes all of them (verified in `document.xml` / `settings.xml`),
so they *can* be expressed. Whether each application honours them was measured by toggling one
property at a time on the committed fixture:

| Property (ECMA-376) | OfficeCLI prop | Meaning | Word 16 | WPS 12 | LibreOffice 24.2 |
|---|---|---|---|---|---|
| `w:kinsoku` | `kinsoku` | Apply East-Asian line-breaking rules | **Honoured** — `false` yields 5 forbidden-boundary lines | **Honoured** — same 5 | **Ignored** — output byte-identical with `false` **[V]** |
| `w:overflowPunct` | `overflowPunct` | Allow punctuation to hang past the margin | No observable effect (already push-down) | No observable effect | No observable effect (already hangs; `false` does **not** stop it) **[V]** |
| `w:topLinePunct` | `topLinePunct` | Compress punctuation at line start | No observable effect | No observable effect | No observable effect **[V]** |
| `w:autoSpaceDE` / `w:autoSpaceDN` | `autoSpaceDE` / `autoSpaceDN` | Insert space between East-Asian and Latin / digits | **Honoured** — the ~3 pt gap disappears with `false` | **Honoured** — gap disappears | **Ignored** — keeps its own ~2.4 pt gap **[V]** |
| `w:wordWrap` | `wordWrap` | Allow Latin words to break at the margin | **Honoured** — long Latin token breaks mid-word with `false` | **Honoured** — same | **Ignored** — output unchanged **[V]** |
| `w:snapToGrid` + `w:docGrid` | `snapToGrid`, `docGrid.type/linePitch/charSpace` | Align lines/glyphs to the document grid | (not toggled; see below) | — | — |
| `w:characterSpacingControl` (settings) | `charSpacingControl` | `doNotCompress` / `compressPunctuation` / `compressPunctuationAndJapaneseKana` | **No change** — identical output | **Honoured for line-breaking** — `compressPunctuation` changed 3 break decisions on the dense paragraph and made WPS output **byte-for-line identical to Word**; no glyph width changed | **No change** — identical output **[V]** |

Notes:

- **[V]** Toggling `kinsoku=false`, `autoSpace*=false`, and `wordWrap=false` each changed Word
  and WPS output exactly as expected; LibreOffice ignored all three (its rendered output was
  identical to the base for each). `overflowPunct=false` and `topLinePunct=true` changed
  nothing in any application. `characterSpacingControl=compressPunctuation` changed nothing in
  Word or LibreOffice, but changed WPS's line-breaking on the dense paragraph.
- **[V]** The `characterSpacingControl` effect is **layout-dependent, not glyph-dependent**: on
  the committed fixture, setting `compressPunctuation` moved WPS's three dense-paragraph break
  decisions so that WPS became **line-for-line identical to Word** (base Word↔WPS differed on 3
  lines; with the setting they differ on 0). Every punctuation glyph still advanced a full
  12 pt in both; the change is in *where* WPS breaks, not in visible squeezing. On a shorter
  variant the setting had no effect at all, so it is not a guaranteed alignment lever — but it
  never regressed Word or LibreOffice.
- **[S]** ECMA-376 defaults for the absent flags are `kinsoku`, `overflowPunct`,
  `autoSpaceDE`, `autoSpaceDN`, `wordWrap`, and `snapToGrid` **true**; `topLinePunct` **false**.
  Because the defaults are already the desired ones, a document that sets nothing gets correct
  forbidden-character handling in all three applications. **[V]** confirms this on the fixture.
- **[S]** `characterSpacingControl` lives in `settings.xml`; OfficeCLI's `create --locale
  zh-CN` writes `<w:characterSpacingControl w:val="doNotCompress"/>`. Word's native default
  for a Chinese document is usually `compressPunctuation`. Because OfficeCLI pins
  `doNotCompress`, WPS does not apply the compression that Word effectively does by default,
  which is why WPS diverged on the dense paragraph. **[V]**
- **[S]** `docGrid` is a section property; `--locale zh-CN` writes `<w:docGrid
  w:type="default"/>`, i.e. **no** character grid is imposed, so line width is governed purely
  by font metrics. Per-character grid snapping (`type=linesAndChars` / `snapToChars`) was not
  exercised; it is a separate layout lever, not needed for kinsoku. **[?]** for its cross-app
  effect.

## 4. Where the three applications differ (summary)

- **LibreOffice ignores every kinsoku-family toggle** (`w:kinsoku`, `w:autoSpaceDE/DN`,
  `w:wordWrap`). It always applies its own East-Asian line-breaking and its own CJK/Latin
  spacing. Word and WPS honour all three. **[V]**
- **Word and WPS agree on the boundary rules**, but on this fixture WPS broke the
  punctuation-dense paragraph 1–2 characters differently from Word; setting
  `characterSpacingControl=compressPunctuation` removed that difference (Word↔WPS: 3 differing
  lines become 0). **[V]**
- **No application visibly compresses punctuation glyphs** in the fixture: every punctuation
  advance is a full em. `topLinePunct` changes nothing. `characterSpacingControl=compressPunctuation`
  changes WPS's line *breaks* on dense punctuation (aligning WPS with Word) without changing any
  glyph width; Word and LibreOffice are unaffected. **[V]**
- **Word/WPS push a forbidden closing punctuation down; LibreOffice hangs it into the margin.**
  Both avoid the forbidden line start; the visible line differs (29 vs 31 characters here).
  **[V]**

## 5. Conclusion — what WordFlow v0.1 must set

**The kinsoku family needs no setting; one document setting is recommended and is recorded as a
follow-up to #17 (§9).**

- **Kinsoku / forbidden characters / auto-space / word-wrap: application-controlled, nothing to
  set.** The OOXML defaults are already the desired values (`kinsoku`, `overflowPunct`,
  `autoSpaceDE/DN`, `wordWrap` all default true), and every application applies them without
  instruction: the fixture renders with **zero** forbidden-boundary lines in Word, WPS, and
  LibreOffice. WordFlow does **not** need to write `kinsoku`, `overflowPunct`, `topLinePunct`,
  `autoSpaceDE/DN`, or `wordWrap`. No spec §D6 change is needed for these. **[V]**
- **Recommended (not required for correctness): set
  `w:characterSpacingControl w:val="compressPunctuation"`.** OfficeCLI's `create --locale zh-CN`
  pins `doNotCompress`, which is *not* Word's usual Chinese default. The pin caused WPS to break
  a punctuation-dense paragraph differently from Word; switching to `compressPunctuation` made
  WPS **line-for-line identical to Word** and changed nothing in Word or LibreOffice. Because
  this adds a default that D6 does not currently state, it is **not** applied silently — see the
  follow-up against #17 in §9. Exact request to #17:
  `charSpacingControl=compressPunctuation` (`w:characterSpacingControl w:val="compressPunctuation"`).
- The existing `hint=eastAsia` decision from #8 is reinforced: it makes ambiguous full-width
  punctuation resolve to the CJK font slot. **[V]/[S]**

This confirms and completes the spec's §D10 / Further Notes item "Chinese punctuation /
kinsoku compression" as **measured**: forbidden-character handling is faithful in all three
applications with no setting; the only portable lever that measurably helps is
`characterSpacingControl`, carried as a #17 follow-up.

## 6. Instability, report behaviour, and how #30 surfaces it

The behaviour is **stable enough not to warn by default**, but it is not identical across
applications. The documented positions:

- **Default (no special user requirement): no warning.** Every application handles forbidden
  characters correctly; the residual differences (LibreOffice hangs instead of pushing down;
  any remaining punctuation-dense break positions — reduced, but not eliminated, by the §9
  setting) are application-controlled line-breaking, not a WordFlow construction. Emitting a
  §D11 warning on every Chinese document would be noise.
- **If the user's formatting requirement demands identical line breaks / identical kinsoku
  across Word, WPS, and LibreOffice: WordFlow cannot guarantee it.** It has no layout engine,
  and LibreOffice ignores the `w:kinsoku` / `w:autoSpace*` / `w:wordWrap` controls that would be
  needed to force parity. This is exactly **#30 trigger `portability-no-alternative`** (row 6 in
  `references/workflow/risk-policy.md`): *stop and ask*, produce no output, and explain that
  line-break positions are application-controlled and LibreOffice disregards the kinsoku
  controls. **No new #30 trigger is needed.**
- **If WordFlow (or a template) ever explicitly sets `kinsoku=false`:** LibreOffice would ignore
  it and still apply kinsoku, so the document would not behave as requested there. Because
  WordFlow's conclusion is to leave the property at its default, this path is not taken; were it
  ever taken, it would be reported as a §D11 warning (a construction that renders differently in
  one application).
- **Placeholder/field reporting is unaffected**: this behaviour involves no fields, so the
  `unverifiable-field` path (#30 row 7) does not apply.

## 7. Reproduce

```bash
# 1. Fixture (also added to tests/generate-fixtures.sh)
tests/generate-fixtures.sh    # or run just the cjk/ block

# 2. LibreOffice render
soffice --headless --norestore --invisible \
  -env:UserInstallation=file:///tmp/loprof \
  --convert-to pdf --outdir /tmp/out tests/fixtures/cjk/cjk-punctuation-kinsoku.docx

# 3. Word / WPS render over COM (WSL; serialize with flock)
flock -w 1800 /tmp/wordflow-wincom.lock \
  /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile \
  -Command '$w=New-Object -ComObject Word.Application; $w.Visible=$false; \
            $d=$w.Documents.Open("C:\temp\cjk-punctuation-kinsoku.docx"); \
            $d.ExportAsFixedFormat("C:\temp\word.pdf",17); $d.Close($false); $w.Quit()'

# 4. Character-level inspection (first/last char, gaps, punctuation advances)
python3 - <<'PY'
from pdfminer.high_level import extract_pages
from pdfminer.layout import LTTextContainer, LTTextLineHorizontal, LTChar
for page in extract_pages("/tmp/out/cjk-punctuation-kinsoku.pdf"):
    for el in page:
        if isinstance(el, LTTextContainer):
            for line in el:
                if isinstance(line, LTTextLineHorizontal):
                    cs=[c for c in line if isinstance(c,LTChar) and c.get_text().strip()]
                    if cs:
                        print(len(cs), repr(cs[0].get_text()), "->", repr(cs[-1].get_text()))
PY
```

## 8. Reproduce (control variants)

Copy the fixture and add one property to each `/body/p[i]`, then re-render:
`officecli set <doc> /body/p[i] --prop kinsoku=false` (and likewise `overflowPunct=false`,
`topLinePunct=true`, `autoSpaceDE=false --prop autoSpaceDN=false`, `wordWrap=false`); set
`charSpacingControl=compressPunctuation` on the document root (`officecli set <doc> / --prop
charSpacingControl=compressPunctuation`). Render artifacts are kept (git-ignored) under
`tests/.out/issue7/`.

## 9. Follow-up against #17 (recorded, not applied)

**Not a silent scope change.** This research does not touch #17's frozen output; it records one
recommendation for #17 to consider when it next defines the Simplified-Chinese defaults:

| Item | Exact value | Rationale | Risk |
|---|---|---|---|
| Document setting `characterSpacingControl` | `compressPunctuation` (`officecli set <doc> / --prop charSpacingControl=compressPunctuation`; writes `w:characterSpacingControl w:val="compressPunctuation"`) | OfficeCLI pins `doNotCompress`, which is not Word's usual Chinese default and caused WPS to break a punctuation-dense paragraph differently from Word. `compressPunctuation` aligned WPS with Word line-for-line and changed nothing in Word/LibreOffice. Portable, standard (`settings.xml`), validation passes. | Low: no measured regression; effect is layout-dependent (no visible change on some documents), so treat as an alignment improvement, not a guarantee. |

The kinsoku-family properties (`kinsoku`, `overflowPunct`, `topLinePunct`, `autoSpaceDE/DN`,
`wordWrap`, `snapToGrid`) are **not** recommended for #17 — their defaults already give correct
behaviour and LibreOffice ignores the toggles anyway.

## 10. Spec wording note (no edit made)

`docs/spec/v0.1.md` §D10 lists "Chinese punctuation/kinsoku compression" as **untested**. This
research measures it and finds forbidden-character handling faithful in all three applications
with no setting required; the one portable lever that measurably helps is
`characterSpacingControl`, recorded as a follow-up to #17 (§9). The spec, CONTEXT, ADRs,
PROJECT_STATUS, README, and tests README were **not** modified by this ticket. The only fixture
folder updated is `tests/fixtures/cjk/` plus its MANIFEST entry.
