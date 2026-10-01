# Large documents, missing fonts, and offline behaviour

Practical document-size limits, what happens when a named font is absent from the rendering host,
and whether any part of the WordFlow path needs the network. This is a **facts** file, not product
guidance. It answers the open research item of spec `docs/spec/v0.1.md` §Further Notes
(**"Large-document limits, and behaviour offline or when fonts are missing (#9)"**) and touches
Q01 and W04.

Legend:
- **[V]** — verified by running the tools locally (commands and versions in §7).
- **[S]** — backed by a primary-source document (ECMA-376, fontconfig, product documentation) or by
  construction of the tooling.
- **[?]** — reported or reasoned but not confirmed here; treat as uncertain.

## 1. Method

Everything in §2–§4 was produced by one reproducible probe:

```
tests/probes/large-document.sh            # ~78 s on the reference host
```

It writes `tests/.out/large-document/result.json` (machine-readable) and `summary.md` (human), and
keeps the generated documents under `tests/.out/large-document/`. It never reads or writes DOCX by
any means other than OfficeCLI (ADR-0001); it only *names* fonts through OfficeCLI properties and
never embeds them. The probe is bounded: external renders carry a timeout and the default sizes are
small.

Reference host: WSL2 Ubuntu 24.04, 16 vCPU, ~7.8 GiB RAM. OfficeCLI **1.0.153** (the ticket cites
1.0.152; the host had 1.0.153 installed — the same behaviour family), LibreOffice 24.2.7.2,
Microsoft Word 16.0 and WPS Writer 12.0 through COM. **[V]**

Each large-document rung is built with `officecli create --locale zh-CN` then **one** `officecli
batch` of paragraph adds, using a fixed 50-character CJK+Latin sentence. The same sentence is used
at every size, so the file/byte figures are a **lower bound**: real varied prose compresses far
worse than this repetitive fixture. Renders use an isolated `-env:UserInstallation`; COM calls are
serialized with `flock -w 1800 /tmp/wordflow-wincom.lock`. **[V]**

## 2. Large-document scaling

### 2.1 Default rungs (250 → 16 000 paragraphs) **[V]**

Run of 2026-10-01 (`tests/.out/large-document/result.json`):

| paragraphs | docx bytes | create+add ms | validate ms | stats ms | issues ms | text ms | render ms | pages | peak RSS KB | ms/para |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 250 | 7 766 | 1 462 | 337 | 339 | 353 | 338 | 1 140 | 12 | 39 024 | 5.85 |
| 1 000 | 14 798 | 1 792 | 403 | 391 | 421 | 344 | 1 214 | 48 | 50 004 | 1.79 |
| 4 000 | 43 436 | 2 336 | 606 | 414 | 403 | 363 | 2 053 | 191 | 64 356 | 0.58 |
| 16 000 | 157 471 | 3 099 | 518 | 469 | 549 | 451 | 6 720 | 762 | 126 668 | 0.19 |

Findings:

- **Nothing degrades over this range; the curve is flat or sub-linear.** For a 64× increase in
  paragraphs, `validate` grows 1.54×, `view stats`/`issues`/`text` ~1.4–1.6×, and file bytes 20×.
  Per-paragraph cost **falls** (5.85 ms/para at 250 → 0.19 at 16 000) because a fixed ~1 s startup
  is amortised. `create --locale zh-CN` + one `batch` is the reason the adds stay cheap. **[V]**
- **Pages are linear in paragraphs for this template:** ≈ **21 paragraphs/page** (12, 48, 191, 762
  pdf pages for 250/1 000/4 000/16 000). **[V]**
- **LibreOffice render is linear in pages, not paragraphs:** ≈ **1 050 ms startup + 7.4 ms/page**
  (fit through the four points). The longest render measured here (762 pages) was 6.7 s. **[V]**
- **OfficeCLI peak RSS is linear in paragraphs:** ≈ **4.5–5.5 KB/paragraph + ~35 MB baseline**
  (39 MB at 250 → 127 MB at 16 000). **[V]**

### 2.2 Extended rungs (50 000 → 200 000 paragraphs) **[V]**

A second, still-bounded run isolates the memory curve (`--no-render --no-com --overhead 0
--sizes "50000 100000 200000"`, ~78 s):

| paragraphs | docx bytes | create+add ms | validate ms | stats ms | issues ms | text ms | peak RSS KB | pages (extrapolated) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 000 | 480 359 | 5 379 | 914 | 660 | 872 | 731 | 265 588 | ≈ 2 380 |
| 100 000 | 955 548 | 8 140 | 2 217 | 1 196 | 1 306 | 1 149 | 482 416 | ≈ 4 760 |
| 200 000 | 1 905 571 | 15 605 | 2 723 | 1 444 | 1 757 | 1 699 | 931 752 | ≈ 9 520 |

- Even at **200 000 paragraphs** every OfficeCLI operation completes and stays sub-linear
  (validate 2.7 s, stats 1.4 s, issues 1.8 s, text 1.7 s) on OfficeCLI 1.0.153. **[V]**
- **The binding constraint is memory, not time.** Peak RSS is ≈ 4.5 KB/paragraph here; at 200 000
  paragraphs the process holds ~0.9 GB. On the reference host (~1.4 GiB free) that is close to the
  wall; a host with less free RAM will fail or swap before any operation gets slow. A 400 000
  rung was **deliberately not attempted** — it would need ~1.8 GB and risk the OOM killer. **[V]**
- At this scale the **render preview is the first thing to become impractical**: ~9 500 pages at
  200 000 paragraphs would be a PDF of hundreds of MB taking ~1–2 minutes to build. The probe's
  render bound was therefore kept to the 16 000-paragraph rung. **[V]**

### 2.3 The per-process overhead that forces `batch` **[V]**

- One isolated `officecli add` costs roughly **0.77 s in wall time** (20 adds in a row = 15.4 s);
  the same 20 adds in a single `batch` cost **0.98 s total** (§2.1, `cli_overhead`). A manually
  run 50-add sample was **64.4 s isolated vs 1.5 s batched (~43×)**. **[V]**
- A resident (`officecli open`) is **not** a substitute: 50 adds through a live resident still took
  ~45 s, because the cost is OfficeCLI process startup, not document open/save. **[V]**
- **Consequence:** any repeated layout operation (applying a style to many paragraphs, building an
  output) must be expressed as `batch`/replayable operations, not as a shell loop of one command per
  item. This is already the project's "reproducible operations" stance; the probe puts a number on
  it.

### 2.4 Where it degrades, in one sentence

Up to ~200 000 paragraphs the OfficeCLI operations themselves do **not** degrade; the practical
ceiling is (a) **process memory ≈ 5 KB/paragraph** and (b) the **render preview**, which grows
linearly with page count (~7.4 ms/page, plus a PDF artefact that can reach hundreds of MB). **[V]**

## 3. Missing fonts

The probe names three fonts that are **absent on this Linux host** (confirmed with `fc-match`) and
then observes what each layer does.

| Named in the document | `fc-match` on this host | Status here | Present on Windows? |
|---|---|---|---|
| `Microsoft YaHei` | `DejaVu Sans` | absent | yes [V] |
| `方正书宋` (FZSong) | `DejaVu Sans` | absent | **no** [V] |
| `Arial Black` | `DejaVu Sans` | absent | yes [V] |

### 3.1 OfficeCLI

- `officecli validate` **passes** on a document naming absent fonts; `view issues` reports only
  layout heuristics (here, "missing first-line indent") and **never a font problem**. **[V]**
- **[S]** This is expected: `w:rFonts` is just names and a `w:hint`; ECMA-376 has no construct that
  asserts a font is installed, and OfficeCLI's `validate` is a schema gate.
- **Consequence for QA (D14):** a green `validate` is **not** evidence that a named font exists on
  the reader's machine. Font availability must be probed separately (§5.2).

### 3.2 LibreOffice 24.2 (Linux)

The missing-font document rendered to PDF embeds only:

```
BAAAAA+DejaVuSans
CAAAAA+WenQuanYiZenHei
```

- Every named font was absent, so fontconfig's family match collapsed to **DejaVu Sans** (Latin-only)
  and LibreOffice applied **per-glyph fallback**, drawing all CJK with **WenQuanYi Zen Hei**. **[V]**
- The same embedded set appears with the user font directory hidden (`XDG_DATA_HOME` pointed at an
  empty dir) because none of the three names resolve through the user directory either. **[V]**
- No error, no prompt; `pdftotext` extracts the correct characters. **Text extraction is not a
  fidelity check** — inspect the rendered fonts/pixels (this matches #8). **[V]**

This is the D6 story in miniature: on stock Linux a Windows CJK face is absent and the body can
silently change face and line height. See `references/research/cjk-font-availability.md` (#8) for the
measured ~10–18 % line-height/pagination shift that follows.

### 3.3 Word 16 / WPS Writer 12 (Windows, via COM)

Both opened the same document **read-only, without a repair prompt or dialog**, and exported a PDF:
**[V]**

| App | opens without repair | fonts embedded in its PDF | interpretation |
|---|---|---|---|
| Word 16.0 | **yes** | `Arial-Black`, `MicrosoftYaHei`, `TimesNewRomanPSMT`, `SimSun` | YaHei + Arial Black are installed and honoured; absent **方正书宋** substituted by **SimSun** |
| WPS 12.0 | **yes** | `MicrosoftYaHei`, `SimSun`, `Arial-Black` | same: YaHei + Arial Black honoured; 方正书宋 → SimSun |

- Windows silently substitutes the absent CJK face with its system Song face (**SimSun**) and keeps
  the document intact. Neither Word nor WPS reports the substitution to the user. **[V]**
- So an absent font is **not** a repair-prompt risk; it is a **fidelity/rendering** risk that is
  invisible to everyone except the author who compares the output. **[V]/[S]**

## 4. Offline behaviour

- **No part of the required path uses the network.** OfficeCLI operates on local files; LibreOffice
  headless renders local files; Word/WPS COM runs locally; font probing (`fc-match`/registry) is
  local. There is no download, license check, or remote call in the layout path. **[S]**
- The probe and the whole pipeline completed on this host, which reaches no OfficeCLI/LO/Word
  service over the network. **[V]**
- A true network-namespace test (`unshare -n`) was attempted but is **not permitted in this
  sandbox** ("Operation not permitted"), so the strongest available statement is the design one
  above. **[V] (attempt) / [?] (no forced-network proof).**
- **Font availability is an OS prerequisite, not an offline failure.** Installing a CJK font is a
  user action; once present, everything works without network. On Linux the recommended package is
  `fonts-noto-cjk` (per #8). **[S]**

## 5. Recommendation: what WordFlow must warn about

D11 already fixes the *shape* of the behaviour (warn and continue for render-difference risk).
These are the concrete triggers and thresholds. They are **research recommendations**; no spec or
ADR text is changed here.

### 5.1 Document size **[V]-derived**

Ground the numbers in the measured curves: pages ≈ paragraphs/21 for the probe template (real D6
typography will differ), process RSS ≈ 5 KB/paragraph, render ≈ 1 s + 7.4 ms/page.

| Trigger (measured / derived) | WordFlow behaviour |
|---|---|
| > **10 000 paragraphs** (~0.1 MB docx here, ~475 pages, ~50–90 MB RSS, validate/render both a few seconds) | **Warn**: "large document — layout/validation/preview take several seconds." Continue. |
| > **50 000 paragraphs** (~0.5 MB, ~2 400 pages, ~260 MB RSS) | **Strong warn**; recommend splitting; note that the PDF preview will be tens of MB and seconds-to-minutes to render. |
| > **100 000 paragraphs** (~1 MB, ~4 800 pages, ~480 MB RSS) | **Strong warn + preview off by default** (D13 allows disabling; note it in the change report). Continue layout. |
| Estimated peak RSS (≈5 KB × paragraphs) exceeds ~30 % of free RAM, **or** the count is so large the batch input cannot be staged | **Stop and ask** (cannot complete safely on this host) — this is the genuine limit, not a fixed paragraph number. |
| Preview page count > **~500 pages** | Warn that the preview is large/slow; still offer it. |
| More than ~**10 repeated OfficeCLI operations** | Use `batch`/replayable operations, not a command-per-item loop (~0.77 s each). Not a user-facing warning; a WordFlow execution rule. |

Notes:
- The prompt wording referenced here is illustrative; the *thresholds* are the deliverable.
- The measured per-paragraph memory (~5 KB) is the number to key the hard limit off, because it is
  the only quantity that actually stops a job; paragraph counts are just a convenient proxy.

### 5.2 Missing / absent fonts **[V]/[S]**

Before finalising, probe every font the layout names — D6 names `SimSun`/宋体, `SimHei`/黑体,
`Times New Roman`, `Arial` (plus any face from a template or formatting requirement) — on the
rendering host. `fc-match`/`fc-list` on Linux; the `Fonts/` store + registry on Windows.

| Condition | Behaviour |
|---|---|
| All named fonts resolve locally | Normal; no font warning. |
| ≥1 named font is absent locally | **Warn** and continue (D11). The change report must name the missing font, the substitution actually observed (e.g. `Microsoft YaHei → WenQuanYi Zen Hei`), and the expected effect (CJK face change; line-height/pagination shift per #8). **Never silent.** |
| Document contains CJK and the host has **no CJK-capable font at all** (`fc-list :charset=4e2d` empty) | **Strong warn** (tofu risk). Document `fonts-noto-cjk` as the OS prerequisite. |
| The user supplied a formatting requirement naming an **exact** face that is neither present nor substitutable, and they will not accept a warning | **Stop and ask** (D11). |
| A portable/embeddable font is explicitly requested | Out of scope for v0.1 (embedding is excluded); explain, do not silently embed. |

- Do **not** silently replace the D6 names, and do **not** stop merely because a font is absent —
  absent-font substitution is graceful in all three applications (§3). The risk is fidelity, and
  D11 handles fidelity with a warning. **[V]/[S]**
- Because `validate` cannot see font availability (§3.1), the font probe is the **only** check that
  catches this before delivery.

## 6. What this does and does not change

- No spec, ADR, status, or README text is modified by this research. It answers the open item in
  spec §Further Notes and feeds Q01/W04.
- Nothing here requires a product capability; the probe is a research artefact under
  `tests/probes/` and writes only to git-ignored `tests/.out/`.
- The font findings are consistent with `references/research/cjk-font-availability.md` (#8) and add
  the missing-font *behaviour* (validate/open/substitute) rather than re-deriving the D6 choice.

## 7. Reproduce

```bash
# Required: officecli, jq, coreutils. Optional: soffice, pdfinfo/pdffonts,
# /usr/bin/time, powershell.exe + Word/WPS.

# Canonical bounded run (default sizes; ~78 s):
tests/probes/large-document.sh

# Scaling where the memory curve is clear (still bounded, ~78 s):
tests/probes/large-document.sh --out /tmp/wf9/ext \
  --sizes "50000 100000 200000" --overhead 0 --no-render --no-com

# Missing-font facts only, no Word/WPS COM:
tests/probes/large-document.sh --sizes "100" --overhead 0 --no-com

# Outputs:
#   tests/.out/large-document/result.json
#   tests/.out/large-document/summary.md
```

Direct spot-checks behind the tables:

```bash
# Font availability on this host
fc-match "Microsoft YaHei"; fc-match "方正书宋"; fc-match "Arial Black"
fc-list :charset=4e2d family | sort -u

# OfficeCLI does not check font availability
officecli create /tmp/mf.docx --locale en-US
officecli add /tmp/mf.docx /body --type paragraph \
  --prop 'text=微软雅黑 中文' --prop 'font.ea=Microsoft YaHei' --prop 'font.latin=Arial Black'
officecli close /tmp/mf.docx
officecli validate /tmp/mf.docx            # -> no errors
officecli view /tmp/mf.docx issues         # -> no font issue

# Embedded fonts after a render
soffice --headless -env:UserInstallation=file:///tmp/lo-mf \
  --convert-to pdf --outdir /tmp/pdf-mf /tmp/mf.docx
pdffonts /tmp/pdf-mf/mf.pdf

# Word/WPS: open read-only + export via COM is what tests/probes/large-document.sh does,
# serialized with: flock -w 1800 /tmp/wordflow-wincom.lock <powershell ...>
```

## 8. Open / uncertain

- **[?]** The byte-size figures use a repetitive fixture and are a lower bound; a document of varied
  prose will be larger for the same paragraph count (compression ratio differs).
- **[?]** Paragraph→page is template-dependent (≈21/page here at 11 pt defaults; D6's 12 pt body with
  1.5 line spacing will be fewer lines per page), so the *page* thresholds are indicative while the
  *memory and render-per-page* relationships are the durable ones.
- **[?]** Only LibreOffice was exercised for substitution on Linux; Word/WPS were exercised on
  Windows, where the D6 faces exist. A Word/WPS substitution for a face absent on Windows was
  observed only for 方正书宋 (→ SimSun); other absent-font names were not individually matrixed.
- **[?]** No forced-network (`unshare -n`) proof; see §4.
