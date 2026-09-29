# Field recalculation and cross-application verification

Empirically measured behaviour of OfficeCLI, Microsoft Word, and WPS Writer for fields, tables of contents, and cross-references. This is a **facts** file, not product guidance.

Legend:
- **[V]** — verified by running the tools locally (versions below).
- **[S]** — backed by the OOXML / ECMA-376 standard or a primary-source document.
- **[?]** — reported elsewhere but not confirmed here.

## Method

- **OfficeCLI** `1.0.152` on Linux (WSL).
- **Microsoft Word** `16.0` (Office 16) driven by COM (`Word.Application`) from WSL interop, opened hidden, `ReadOnly=true`, **no save**; fields read before and after an explicit update.
- **WPS Writer** `12.0` driven by COM (`KWPS.Application`), same procedure.
- **LibreOffice** `24.2.7.2` (Ubuntu 24.04, installed in WSL), driven headless (`soffice --headless --convert-to pdf`) and through a `.docx` round-trip (LO open + save), then inspected with OfficeCLI.
- Test document: a field matrix — a `TOC` field, a `REF`/`PAGEREF` pair to a bookmark, a `SEQ Figure`, and footer `PAGE`/`NUMPAGES`. Three variants:
  - `fm_plain` — no `updateFields`, no `refresh`;
  - `fm_update` — `w:updateFields=true`, no `refresh`;
  - `fm_refresh` — OfficeCLI `refresh` run after building.
- Harness (Windows temp, not in the repo): `C:\temp\wf-verify\` — `build-variants.sh`, `test-word.ps1`, `test-wps.ps1`. Re-runnable: build variants, open each in Word/WPS, print fields on open and after `Fields.Update()`.

## 1. OfficeCLI always writes a cached result

- **[V]** At `add` time, OfficeCLI writes a cached field result, so **every** field reads `evaluated=true` immediately. For TOC and REF the cache is a *placeholder*:
  - `TOC` → cached text is the literal `Update field to see table of contents`;
  - `REF target \h` → cached text is `«target»`;
  - `PAGEREF`, `SEQ`, `PAGE`, `NUMPAGES` → cached text defaults to `1`.
- **[V]** `view issues` reports **no** `field_not_evaluated` for any of these, because a cache exists.
- **[V] Consequence:** neither `evaluated=true` nor `view issues` can detect a bad or placeholder cache. Judge a field by its **cached text**, not its flags.
- **Correction to an earlier note.** An earlier observation that "fields written without a cache render `#OCLI_NOTEVAL!`" does **not** describe `add field` in 1.0.152, which always caches. The sentinel may still appear in other construction paths.

## 2. OfficeCLI `refresh` (HTML backend) fills some caches — with caveats

- **[V]** `refresh` populates the TOC: the TOC field's cached result becomes hyperlink paragraphs, one per heading, each carrying a `PAGEREF _Toc…` field. Cached entry text was `Alpha section<TAB>2`, `Beta section<TAB>2`.
- **[V] The page numbers are wrong for Word/WPS.** OfficeCLI's cache said page `2`; both Word and WPS compute page `1` for the same document. The cache comes from OfficeCLI's HTML pagination model, not from the reader's layout. A document opened in Word/WPS therefore **displays the wrong page numbers** until the user updates fields.
- **[V]** `PAGEREF target` resolves; `SEQ` resolves; `PAGE`/`NUMPAGES` are `1`.
- **[V] `REF` is never resolved by `refresh`.** Its cached text stays `«target»`, and (see §3) Word/WPS display exactly that.

## 3. Word and WPS do not recalculate fields on open

Measured on both `Word 16.0` and `WPS Writer 12.0`; results were identical.

| Variant | On open (no manual update) | After `Fields.Update()` (the F9 action) |
|---|---|---|
| `fm_plain` | TOC = `Update field to see table of contents`; REF = `«target»`; PAGEREF/SEQ = `1` | TOC lists `Alpha section 1`, `Beta section 1`; REF = `Target paragraph (bookmark)`; PAGEREF = `1` |
| `fm_update` (`updateFields=true`) | **Identical to `fm_plain`** — `updateFields` did **not** trigger an update on open | Correct, as above |
| `fm_refresh` | TOC shows cached entries with page `2`; REF = `«target»` | Correct: page `1`, REF resolved |

- **[V]** Neither Word nor WPS updates fields when a document is opened, **even when `w:updateFields=true`**. They display the cached result verbatim.
- **[V]** Both resolve everything correctly on a manual field update (Word `Ctrl+A`+`F9`; WPS the same UI action). `Fields.Update()` via COM is a faithful stand-in for that user action.
- **[V]** `fm_refresh` demonstrates the real failure mode: a document that *looks* complete (the TOC has entries) but shows **wrong page numbers** until updated.
- **[V]** Word's `Options.UpdateFieldsAtPrint` was `False` on this machine; printing/exporting would therefore not update fields either. This is a machine setting, not a document property, so it cannot be relied upon.

## 4. Implications for WordFlow

- **Pre-computing the cache is mandatory** for TOC, REF, PAGEREF, SEQ, PAGE, NUMPAGES: that cache is what every reader shows until the user presses F9. Omitting it (or shipping a placeholder) is a visible defect.
- **The cache must be *correct*.** A wrong cached page number (from a non-Word pagination model) is worse than no entry, because it looks finished and is silently wrong.
- **Render fidelity is uneven per feature** (see §7): simple equations and merged-cell tables render faithfully in LibreOffice; floating images do not. This is what "supported with warning" should key off.
- **Page numbers cannot be guaranteed without a real layout engine.** The requirement "automatic content is populated" must be re-scoped: WordFlow can populate *structure* (entries, references, captions) but not trust its own page numbers.
- **Safe options to decide in spec** (not decided here):
  1. build the TOC **without page numbers** (heading entries only) so there is nothing wrong to show; or
  2. build page numbers best-effort and **warn** that the user must update fields (F9 / Update TOC) once in their application; or
  3. require an application pass (Word/WPS/LibreOffice) to finalise — contradicts "does not require Word".
- **`REF` and TOC placeholders must never ship silently**; the change report must say when a reference or page number is a placeholder.

## 5. Verification harness notes

- WSL interop is enabled but `appendWindowsPath=false`, so Windows binaries are invoked by full path (`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`). COM ProgIDs `Word.Application`, `KWPS.Application`, `KET.Application` are registered.
- Always open via COM **ReadOnly**, and always `Quit()` in a `finally`; an abandoned run leaves an invisible `WINWORD.EXE` holding the file (a `~$name.docx` lock). Killing only processes with `MainWindowHandle -eq 0` avoids touching the user's own visible Word.
- **Do not use `ExportAsFixedFormat` (PDF) inside the hidden automation** — it hung in testing. Test field values through the object model instead.

## 6. LibreOffice 24.2.7.2

Tested by (a) headless `--convert-to pdf`, and (b) a `.docx` round-trip (LO opens the file and saves it as `.docx`, then OfficeCLI reads back the field caches).

- **[V] LO does not rebuild a TOC on open.** For `fm_plain` the TOC area shows the cached placeholder `Update field to see table of contents`; for `fm_refresh` it shows OfficeCLI's stale entries, including OfficeCLI's page numbers (`2`) — **not** LibreOffice's own pagination — and the placeholder `«target»` inside the second entry. A bad or placeholder cache survives LibreOffice untouched.
- **[V] LO ignores `updateFields` on open.** The PDF for `fm_plain` and `fm_update` was text-identical (same content) — `updateFields=true` changed nothing.
- **[V] LO *does* resolve `REF` on import** — unlike Word and WPS. After the round-trip, `REF target` cached text became `Target paragraph (bookmark)` (Word/WPS still showed `«target»` without an F9). `PAGEREF target` = `1`.
- **[V] Headless PDF export renders cached field results**; it does not recalculate. Automated recalculation verification would need a UNO/macro update step.

## 7. Cross-application render checks (LibreOffice, via `--convert-to pdf` + `pdftoppm`)

Rendered the committed fixtures and two probes; inspected the PDF text and page images.

- **[V] Simple OMML equations render correctly.** `equations/display-equation.docx` shows a real stacked fraction `a/b = c`; `equations/inline-equation.docx` shows `E = mc²`. (Complex constructs, matrices and `eqArr`, were **not** tested.)
- **[V] Floating (anchored) image is NOT faithful.** `images/anchored-image.docx` (`anchor=true`, `wrap=topAndBottom`, `hRelative=column`, `hPosition=0cm`) rendered **left-aligned and in flow above the paragraph**, not centred on the column and not floating as intended. This confirms floating images belong in "supported with warning".
- **[V] Merged-cell tables are faithful.** A probe with `colspan=2` on the header row and `vmerge=restart|continue` down column 1 rendered exactly as intended, borders included. (Nested tables were **not** tested.)
- **[V] Page-number restart and format work.** A two-section probe with `pageNumFmt=lowerRoman`, `pageStart=1` on section 2 rendered the section-2 footer as `i`. A centred `PAGE` footer rendered `1`. (Different-first-page and odd/even headers were **not** tested.)
- **[V] CJK fonts substitute silently, with metric risk.** In `cjk/cjk-fonts-indent.docx`, LibreOffice embedded the real `SimSun` (present on this host) but substituted `Microsoft YaHei` with `WenQuanYi Zen Hei`. `fc-match` maps `等线`/`DengXian` to **`DejaVu Sans`**, a Latin font with no CJK coverage — so OfficeCLI's `create --locale zh-CN` default (`等线`) is **not safe** on a Linux/LibreOffice system.
- **Untested / still documentary:** nested tables, different-first-page and odd/even headers, complex equations, and Chinese punctuation/kinsoku compression.
