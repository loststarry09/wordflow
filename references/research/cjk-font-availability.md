# CJK font availability and substitution

Which CJK fonts WordFlow should name by default, what happens where those fonts are absent, and
whether a documented fallback is needed. This is a **facts** file, not product guidance.

Legend:
- **[V]** — verified by running the tools locally (versions and commands in §8).
- **[S]** — backed by the OOXML / ECMA-376 standard, fontconfig documentation, or a primary-source document.
- **[?]** — reported elsewhere but not confirmed here; treat as uncertain.

Scope: the candidate faces named by spec `docs/spec/v0.1.md` **D6** — SimSun/宋体, SimHei/黑体,
Times New Roman, Arial, DengXian/等线, Microsoft YaHei/微软雅黑 — on the three target renderers
(Microsoft Word 16, WPS Writer 12 on Windows; LibreOffice 24.2 on Linux) and mixed CJK+Latin runs.

## 1. Method

- **Windows (Word / WPS):** inspected the font store directly —
  `/mnt/c/Windows/Fonts/` (files) and the registry key
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` — because both applications render
  from the shared Windows font store. Host: Windows 11 (10.0.26200). **[V]**
- **Linux (LibreOffice):** `fc-list` / `fc-match` / `fc-query` (fontconfig) plus headless
  `soffice --convert-to pdf`, inspected with `pdffonts`, `pdftohtml -xml`, `pdftotext -bbox`,
  and `pdftoppm` page images. Host: Ubuntu 24.04 in WSL, LibreOffice 24.2.7.2. **[V]**
- **Test documents** were built with OfficeCLI 1.0.152 (`create --locale zh-CN`, then paragraphs
  carrying `font.ea` + `font.latin` + `font.hint`). Artifacts under `/tmp/wf-issue8/`.
- Three render conditions were compared for the same `.docx`:
  - **A — Windows CJK fonts present** on the Linux host;
  - **B — no Windows fonts** (host copy hidden via `XDG_DATA_HOME`);
  - **C — no CJK font at all** (a minimal fontconfig exposing only Liberation/DejaVu).

## 2. Candidate inventory per platform

### 2.1 Windows (Word / WPS) — the primary platform

All four faces plus both Latin faces are part of the base Windows font store; **[V]** confirmed by
the files and registry entries below.

| Font (D6 role) | File(s) | Registry name | Present |
|---|---|---|---|
| SimSun / 宋体 (body, captions, notes, header/footer) | `simsun.ttc` (+ `simsunb.ttf`, `SimsunExtG.ttf`) | `SimSun & NSimSun (TrueType)` | **yes [V]** |
| NSimSun / 新宋体 (SimSun's mono sibling) | `simsun.ttc` | `SimSun & NSimSun (TrueType)` | **yes [V]** |
| SimHei / 黑体 (title, headings) | `simhei.ttf` | `SimHei (TrueType)` | **yes [V]** |
| Times New Roman (Latin body) | `times.ttf` | `Times New Roman (TrueType)` | **yes [V]** |
| Arial (Latin headings) | `arial.ttf` | `Arial (TrueType)` | **yes [V]** |
| DengXian / 等线 (OfficeCLI `--locale zh-CN` default) | `Deng.ttf`, `Dengb.ttf`, `Dengl.ttf` | `DengXian (TrueType)` | **yes [V]** (Win11) |
| Microsoft YaHei / 微软雅黑 | `msyh.ttc` | `Microsoft YaHei & Microsoft YaHei UI (TrueType)` | **yes [V]** |

- **[V] Method note.** PowerShell `[System.Drawing.Text.InstalledFontCollection]` did **not** list
  SimSun, SimHei, DengXian, or Microsoft YaHei families (it showed only *Microsoft YaHei UI*). This
  is a GDI+ charset-scope artifact, not absence: the `Fonts/` files and the registry entries above
  are authoritative. Do not use `InstalledFontCollection` alone to decide availability on Windows.
- **[S]** SimSun/NSimSun and SimHei ship with Windows' Simplified-Chinese font support; DengXian
  ships with Office 2016+/modern Windows; Times New Roman/Arial ship with Windows. WPS Writer uses
  the same system font store, so its availability picture is identical. WPS-only substitution rules
  were not separately exercised — **[?]**.

### 2.2 Linux (LibreOffice) — the portability platform

- **[V] A stock Ubuntu 24.04 host has no SimSun, SimHei, DengXian, YaHei, Times New Roman, or Arial
  installed.** The CJK faces present by default here are:
  `WenQuanYi Zen Hei` (a *Hei*/sans face, Simplified + Traditional), `WenQuanYi Zen Hei Mono/Sharp`,
  `IPAGothic/IPAPGothic` (Japanese), and `Unifont` (bitmap).
- **[V] On this particular host SimSun (`simsun.ttc`) and SimHei (`simhei.ttf`) resolve only because
  Windows fonts were manually copied to `~/.local/share/fonts/win/`.** That is a host configuration,
  **not** a default Linux capability; it is the reason the earlier LibreOffice measurement embedded a
  real `SimSun` (`references/research/field-recalc-and-cross-app-verification.md` §7).
- **[V] fontconfig resolution with the Windows copies hidden** (what a stock Linux applies):

  | Named font | `fc-match` result | Has CJK glyphs? |
  |---|---|---|
  | `SimSun` | DejaVu Serif | no |
  | `宋体` | DejaVu Sans | no |
  | `SimHei` | DejaVu Sans | no |
  | `NSimSun` | DejaVu Sans Mono | no |
  | `DengXian` / `等线` | DejaVu Sans | no |
  | `Microsoft YaHei` | DejaVu Sans | no |
  | `Times New Roman` | **Liberation Serif** | (Latin only) |
  | `Arial` | **Liberation Sans** | (Latin only) |

  The **family match** for every CJK name collapses to a DejaVu face that has no CJK coverage.
  LibreOffice then applies **per-glyph fallback** for the CJK code points (§3), so the text is still
  drawn — but by whatever CJK font the OS provides, not the named one.
- **[V]** `fc-list :charset=4e2d` (the glyph 中) shows only SimSun/SimHei/NSimSun (host copies),
  WenQuanYi Zen Hei, IPAGothic, and Unifont on this host. DejaVu and Liberation contain no CJK.
- **[S]** fontconfig's `30-metric-aliases.conf` maps `Times New Roman → Liberation Serif` and
  `Arial → Liberation Sans`; `Calibri → Carlito`. These substitutes are **metric-compatible** by
  design (identical advance widths), so the Latin half of a mixed run keeps its layout. **[V]**
  confirmed live (`fc-match "Times New Roman"` → Liberation Serif; `fc-match Arial` → Liberation Sans).

## 3. Substitution as actually rendered (LibreOffice)

Same document, three conditions; fonts embedded in the exported PDF (`pdffonts`) and per-run mapping
(`pdftohtml -xml`). Probe text: `宋体正文 SimSun body: 中文与 Latin mixed 123.` and siblings.

### Render A — Windows fonts present on Linux

| Named (CJK) | Rendered CJK | Named (Latin) | Rendered Latin |
|---|---|---|---|
| SimSun | **SimSun** (real, embedded) | Times New Roman | Liberation Serif |
| SimHei | **SimHei** (real, embedded) | Arial | Liberation Sans |
| DengXian | **WenQuanYi Zen Hei** | Calibri | Calibri |
| Microsoft YaHei | **WenQuanYi Zen Hei** | Arial | Liberation Sans |

This extends the existing measurement (`SimSun` embedded; `YaHei → WenQuanYi Zen Hei`): **[V]** it
also shows DengXian → WenQuanYi Zen Hei (not the "no CJK glyphs" outcome the family match implies).

### Render B — no Windows fonts, but WenQuanYi present

- **[V]** `pdffonts`: `WenQuanYiZenHei`, `LiberationSerif`, `LiberationSans`, `DejaVuSans`.
- **[V]** per-run: **every CJK run → WenQuanYi Zen Hei** (one Hei/sans face); Latin runs →
  Liberation Serif (SimSun's Times slot), Liberation Sans (SimHei's Arial slot),
  DejaVu Sans (DengXian's Calibri slot).
- **[V]** Consequence: body 宋体 and heading 黑体 both render as the **same Hei face**; the Song
  (serif) character of the body is lost, and body/heading differ only in size/weight. Text stays
  readable and selectable.

### Render C — no CJK font at all

- **[V]** page image shows **tofu boxes** for every CJK character; the Latin text is intact.
- **[V]** `pdftotext` still extracted the CJK codepoints (the ToUnicode map survives), so
  **text extraction is not a validity check** — inspect the rendered pixels.
- **[V] Implication:** WordFlow cannot supply CJK glyphs; at least one CJK font must exist on the
  rendering machine. This is an OS-level prerequisite, not something a `.docx` can guarantee.

### LibreOffice's own substitution tables

- **[V]** LibreOffice's compiled `VCL.xcu` (in `/usr/lib/libreoffice/share/registry/main.xcd`) carries
  built-in replacement chains, e.g.:
  - `simsun` → `fzsongti; msunglightsc; simsun; nsimsun; arplshanheisununi; zycjksun; song; fzsongyi; …; arialunicodems; lucidaunicode`
  - `simhei` → `simhei; fzhei; zycjkhei; mhei; hei; …; arialunicodems; lucidaunicode`
  - `nsimsun` → same Song-oriented chain as `simsun`
- **[S]** The chain is **Song-oriented** for `simsun` and **Hei-oriented** for `simhei`; on a host
  with the matching faces (e.g. an AR PL UMing / FZSong font) the body can keep a Song look. On this
  host none of those exist, so fontconfig's only CJK option (WenQuanYi Zen Hei, a Hei) wins the
  per-glyph fallback. Which face the user actually sees therefore depends on **their** Linux font
  set, not on the name in the `.docx`.
- **[V]** fontconfig `40-nonlatin.conf` / `65-nonlatin.conf` list `SimSun` (English name) in the
  serif/non-latin alias groups, which is why the hidden state resolves `SimSun → DejaVu Serif` while
  the Chinese name `宋体` resolves to `DejaVu Sans`. The **English name** is the more portable one to
  write and matches both Windows and fontconfig. (D6 writes `SimSun`/`SimHei`; good.)

## 4. Mixed CJK + Latin: the `rFonts` slot model

- **[S]** OOXML `w:rFonts` selects a face per character script through four attributes:
  `w:ascii` + `w:hAnsi` (Latin), `w:eastAsia` (CJK), `w:cs` (complex scripts). Word picks the slot
  from each character's script. `w:hint` forces which slot is used for **ambiguous** characters —
  CJK punctuation, full-width symbols, and digits — that could belong to either side.
- **[V]** OfficeCLI encodes this correctly. `--prop font.latin` writes `ascii`+`hAnsi`;
  `--prop font.ea` writes `eastAsia`; `--prop font.hint` writes `hint`. Verified at run level:
  `<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="SimSun"/>`, and at
  **style** level, which is what WordFlow needs:
  `<w:rFonts w:hint="eastAsia" w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="SimSun"/>`
  inside `WFBody`'s `rPr` (and the SimHei/Arial equivalent in `WFHeading1`).
- **[S] Recommendation grounding:** setting `w:hint="eastAsia"` on CJK-bearing styles makes CJK
  punctuation use the CJK face instead of the Latin face — the correct behaviour for Chinese
  documents, and something D6 currently does not state. It is an addition *inside* D6, not a change
  to the chosen faces.

## 5. Line height, glyph width, and layout impact

Natural single-line metrics parsed from the fonts' `head`/`hhea`/`OS/2` tables: **[V]**

| Font | upem | hhea asc/desc/gap | natural line height | CJK glyph width |
|---|---|---|---|---|
| SimSun | 256 | 220 / -36 / 36 | **1.14 em** | full-em |
| SimHei | 256 | 220 / -36 / 36 | **1.14 em** | full-em |
| WenQuanYi Zen Hei | 1024 | 986 / -304 / 92 | **1.35 em** | full-em |
| Liberation Serif | 2048 | 1825 / -443 / 87 | 1.15 em | — |
| Liberation Sans | 2048 | 1854 / -434 / 67 | 1.15 em | — |
| DejaVu Sans | 2048 | 1901 / -483 / 0 | 1.16 em | — |

- **[V] CJK glyph width is consistent:** Chinese ideographs are full-width (1 em) in SimSun, SimHei
  and WenQuanYi Zen Hei, so column-wise character counts and wrapping within a line are stable; the
  visible difference is **vertical**.
- **[V] Measured pagination shift.** A 40-line 12 pt body at 1.5 line spacing, rendered by
  LibreOffice:
  - SimSun present: line pitch **20.1 pt**, **35 lines** on page 1, 5 on page 2.
  - SimSun substituted by WenQuanYi Zen Hei: line pitch **22.2 pt** (~10% taller), **31 lines** on
    page 1, 9 on page 2.
  - So the same `.docx` breaks pages differently depending on the CJK fallback. Any cached page
    number (already fragile per D9) is invalidated by a font substitution the author cannot control.

## 6. Substitution risk (summary)

- **Windows / WPS:** very low. Every D6 face is in the base font store. **[V]**
- **Linux / LibreOffice, Windows CJK fonts present:** low for SimSun/SimHei; DengXian/YaHei still
  substitute. Latin keeps metrics via Liberation/Carlito. **[V]**
- **Linux / LibreOffice, stock:** **real.** SimSun/SimHei are absent; the CJK body falls back to
  whatever CJK face exists (here WenQuanYi Zen Hei, a **Hei** face), so:
  1. the **Song/serif body style is lost** and body ≈ heading in face; **[V]**
  2. **line height grows ~10–18%** (measured 10% at 1.5 spacing) → **page breaks move**; **[V]**
  3. if the host has **no** CJK font, output is **tofu**. **[V]**
- The risk is **inherent to naming any Windows font on Linux** — see §7.1; switching the CJK name
  (to DengXian/YaHei) does not remove it, because none of those are stock on Linux either.

## 7. Recommendation

### 7.1 Keep the D6 font names — do not change the frozen choice

**Body: 宋体/`SimSun` + Times New Roman. Headings/Title: 黑体/`SimHei` + Arial. Captions, footnotes,
header/footer: `SimSun` + Times New Roman.** No change to `docs/spec/v0.1.md` D6 is warranted.

Why the frozen choice is the right one, given the evidence:
- There is **no font name native to both** Windows and stock Linux. SimSun/SimHei/宋体/黑体 are absent
  on stock Linux; the Linux-native CJK faces (Noto CJK, WenQuanYi, AR PL) are absent on Windows.
  Substitution is therefore unavoidable on one platform whichever name is written.
- The **primary** platform for Chinese documents is Word/WPS on Windows, where SimSun/SimHei are
  guaranteed. Optimise the name for the platform that can actually honour it.
- DengXian (OfficeCLI's locale default) and Microsoft YaHei are **not better**: neither is stock on
  Linux, both are Hei/sans faces rather than the conventional Song body, and DengXian is absent on
  older Windows/Office. Rejecting the `等线` locale default in D6 remains correct.
- The Latin pair is the safest available: Times New Roman/Arial are native on Windows, and their
  Linux substitutes (Liberation Serif/Sans) are **metric-compatible**, so the Latin half does not
  reflow. **[V]/[S]**
- **Add `w:hint="eastAsia"`** on CJK-bearing styles so ambiguous CJK punctuation uses the CJK slot
  (§4). This strengthens D6 without changing its faces.

### 7.2 When a named font is missing — WARN, do not downgrade, do not stop

Consistent with spec **D11** (a construction that "may render differently in one application" →
**Warn** and continue; "no safe alternative exists" → stop is reserved for constructs, not for a
graceful font substitution):

- WordFlow **always writes the D6 names explicitly** (never `docDefaults`/theme), so the file is
  correct on the primary platform.
- Before finalising, **probe the local host** for each named font (Linux: `fc-list`/`fc-match`;
  Windows: `Fonts/` + registry). This is a cheap, reproducible check.
- **All named fonts resolve locally → normal**, no font warning.
- **A named font is absent locally → Warn** and continue. The change report must name the font, the
  local substitution actually observed, and the expected effect (CJK face change and line-height /
  pagination shift on this host; exact effect depends on the host's CJK fonts). Never silent.
- **Downgrade** only when the user explicitly asks for a portable/embeddable option, or when a
  template / formatting requirement names an available face (which already outranks D6). Do **not**
  silently replace the default names.
- **Stop and ask** only when a user formatting requirement demands an *exact* typeface that is
  neither present nor substitutable and the user will not accept a warning.
- Also record a **reader-side unverified item** when the document contains CJK and its render target
  is not the local platform: substitution is the reader's OS behaviour and cannot be verified here.

### 7.3 A documented fallback is needed — OS-level, not embedded

- **Yes, document a fallback**, but as an **OS prerequisite**, not as a font embedded in the `.docx`
  (embedding is out of scope for v0.1 and adds size/licensing).
- On Linux, document installing a CJK font so rendering is faithful rather than merely readable.
  Recommended package: **`fonts-noto-cjk`** (Noto Sans/Serif CJK; the Serif CJK SC face is the
  closest stock Song-style body). Alternatives: `fonts-wqy-zenhei` / `fonts-wqy-microhei`
  (Hei/sans), `fonts-arphic-uming` (Song/Ming-style) — **[S]**.
- State the concrete risk in the same note: with a Windows-font set absent and only a Hei fallback
  present, the body loses its Song face and lines get ~10% taller, so page breaks can move.

### 7.4 Explicit strategy #17 can implement

1. `create --locale zh-CN` (keeps `docGrid`, `lang.ea`, first-line-indent metadata) **but override
   every font slot**; never inherit the `等线`/DengXian `docDefaults` or theme fonts.
2. Set fonts at the **style level** — `Normal`, `BodyNoIndent`, `Title`, `Heading 1–4`, `Caption`,
   `FootnoteText`, `Header`, `Footer` — via OfficeCLI style props (`font.ea`, `font.latin`,
   `font.hint`). **[V]** OfficeCLI writes `<w:rFonts>` into the style `rPr`; keep direct run
   formatting empty.
   - body/captions/notes/header/footer: `font.ea=SimSun`, `font.latin=Times New Roman`,
     `font.hint=eastAsia`.
   - title/headings: `font.ea=SimHei`, `font.latin=Arial`, `font.hint=eastAsia`.
3. Implement the missing-font probe (§7.2) and emit the D11 warning + D12 report entry.
4. Reference the Linux fallback note (§7.3) from the compatibility reference and the change report.
5. Assert in tests that every style's `rFonts` carries explicit `ascii`/`hAnsi`/`eastAsia`/`hint` —
   never empty, never `等线`. (This is the font half of the #17 style fixture.)

## 8. Reproduce

```bash
# Windows font store
ls /mnt/c/Windows/Fonts/ | grep -iE 'simsun|simhei|deng|msyh|times|arial|calibri'
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
  "Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' | Format-List" \
  | grep -iE 'SimSun|SimHei|DengXian|YaHei|Times New Roman|Arial'

# Linux font resolution
fc-match SimSun; fc-match SimHei; fc-match DengXian; fc-match "Microsoft YaHei"
fc-list :charset=4e2d family file | sort -u          # which fonts have 中
XDG_DATA_HOME=/tmp/empty fc-match SimSun              # simulate stock Linux (hide ~/.local/share/fonts)

# Build a probe with OfficeCLI 1.0.152
officecli create /tmp/probe.docx --locale zh-CN
officecli add /tmp/probe.docx /body --type paragraph \
  --prop text='宋体正文 SimSun body: 中文与 Latin mixed 123.' \
  --prop font.ea=SimSun --prop font.latin='Times New Roman'

# Render and inspect (present vs hidden Windows fonts)
soffice --headless -env:UserInstallation=file:///tmp/loA --convert-to pdf --outdir /tmp/pdfA /tmp/probe.docx
XDG_DATA_HOME=/tmp/nodata soffice --headless -env:UserInstallation=file:///tmp/loB \
  --convert-to pdf --outdir /tmp/pdfB /tmp/probe.docx
pdffonts /tmp/pdfA/probe.pdf; pdffonts /tmp/pdfB/probe.pdf
pdftohtml -xml -hidden -stdout /tmp/pdfB/probe.pdf | grep fontspec   # per-run font mapping
pdftoppm -png /tmp/pdfC/probe.pdf /tmp/pdfC/page                     # tofu check with no CJK font
```

## 9. Spec wording note (no edit made)

D6's parenthetical says the `等线` locale default "has no CJK coverage on Linux and substitutes to a
Latin font". At the **family-match** level that is true (`fc-match 等线` → DejaVu Sans, no CJK), but
empirically LibreOffice still draws 等线's CJK glyphs through per-glyph fallback to the host's CJK
font (Render B). The frozen decision to set fonts explicitly and reject `等线` **stands**; a future
spec revision could reword to "substitutes to a Latin family match and depends on an OS CJK
fallback", which also describes what happens to SimSun/SimHei on stock Linux. `docs/spec/v0.1.md`
was **not** modified.
