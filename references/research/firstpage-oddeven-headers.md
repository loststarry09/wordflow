# Different-first-page and odd/even headers and footers — cross-application portability

Empirically measured behaviour of OfficeCLI, Microsoft Word, WPS Writer, and LibreOffice Writer for
**different first-page headers/footers** and **odd/even headers/footers**. This is a **facts** file,
not product guidance. It closes the "Untested" item in spec D10 and informs the limited-tier fallback
for E01 (spec D9: *"different-first-page and odd/even headers and footers"*).

Legend:
- **[V]** — verified by running the tools locally (versions below).
- **[S]** — backed by the OOXML / ECMA-376 standard.
- **[?]** — reported elsewhere or not confirmed here; treat as uncertain.

## Question

Spec D9 lists different-first-page and odd/even headers/footers as **limited** (produced with a
warning, or downgraded); D10 lists them as **untested**. The question is whether OfficeCLI can
express them and whether the three target applications open the result without repair and render
the intended first/odd/even differentiation. If any application is limited, establish the fallback.

## Method

- **OfficeCLI** `1.0.152` on Linux (WSL).
- **Microsoft Word** `16.0` via COM (`Word.Application`), opened hidden, `ReadOnly=true`, no save.
- **WPS Writer** `12.0` via COM (`KWPS.Application`), same procedure (best-effort; closed source).
- **LibreOffice** `24.2.7.2` (Ubuntu 24.04), headless with an isolated user profile.
- Harness: [`scripts/wf-compat-harness.sh`](../../scripts/wf-compat-harness.sh) (issue #2), one run
  per document, all three applications. COM runs serialised through
  `flock /tmp/wordflow-wincom.lock`. A longer `--timeout` is used because a cold LibreOffice profile
  can exceed the 120 s default.
- Repair-free open is the harness `opens_without_repair`; render fidelity is read from each
  application's exported PDF (per-page `pdftotext -layout`) and its PNG, not from OfficeCLI alone.
- Artifacts: `tests/.out/compat/issue5/tests_fixtures_headers_firstpage-oddeven_docx/`
  (`word.pdf`, `wps.pdf`, `libreoffice.pdf`, and `.png`).

## The committed fixture

`tests/fixtures/headers/firstpage-oddeven.docx` (built by `tests/generate-fixtures.sh`, headers/
section). One section, four explicit pages (`pageBreakBefore`), exercising first (p1), even (p2),
default/odd (p3), even again (p4). Distinct text in each header/footer and a live `PAGE` field in
each footer.

**OfficeCLI props used** (discovered from `officecli help docx header` / `footer` / `section`):

| Effect | Command / prop |
|---|---|
| A header part of a given scope | `officecli add <f> / --type header --prop type=first\|default\|even --prop text=… --prop align=center` |
| A footer part of a given scope | `officecli add <f> / --type footer --prop type=first\|default\|even …` |
| First-page header/footer | `--prop type=first` — **auto-writes `<w:titlePg/>`** on the section |
| Even-page header/footer | `--prop type=even` — **auto-writes `<w:evenAndOddHeaders/>`** in `settings.xml` |
| Odd-page (default) header/footer | `--prop type=default` |
| First-page flag alone, without adding a first part | `officecli set <f> /section[1] --prop titlePage=true` |
| A field in an existing footer paragraph | `officecli add <f> /footer[N]/p[1] --type field --prop fieldType=page` |

- **[V]** Adding the `even` part is what turns on `w:evenAndOddHeaders`; there is **no separate
  "differentFirstPage" or "evenAndOdd" prop to set**. `type=first` sets `titlePg`; `type=even`
  sets `evenAndOddHeaders`. Part order is `first → /header[1]`, `default → /header[2]`,
  `even → /header[3]` (same for footers).
- **[V]** `officecli query <f> section` reads the wiring back:
  `/section[1] … titlePage=true headerRef.first=/header[1] headerRef.default=/header[2] headerRef.even=/header[3] footerRef.first=/footer[1] footerRef.default=/footer[2] footerRef.even=/footer[3]`.
  The bare `headerRef`/`footerRef` shortcut echoes a part even when no `default` reference exists
  (see the no-default variant) — read the `.first/.default/.even` sub-keys, or the XML.
- **[S]** In OOXML the reference types are `default|first|even`; `w:titlePg` enables the first-page
  variant and `w:evenAndOddHeaders` (a document setting) enables the even variant. With
  `evenAndOddHeaders` on, the **default** part is the **odd**-page header/footer.
- **[V]** Resulting section XML (abridged): `<w:headerReference w:type="even" …/>`,
  `<w:headerReference w:type="default" …/>`, `<w:headerReference w:type="first" …/>`, the three
  `footerReference`s, then `<w:titlePg/>`; `settings.xml` carries `<w:evenAndOddHeaders/>`.
- **[V]** `officecli validate` passes; `officecli view issues` raises only the standard advisory
  (`[F1] Body paragraph missing first-line indent`).

## Results — committed fixture

| Application | Opens without repair | PDF pages | First page ≥ first H/F | p2 ≥ even H/F | p3 ≥ default (odd) H/F | p4 ≥ even H/F | Field placeholders |
|---|---|---|---|---|---|---|---|
| Word 16.0 | **yes** | 4 | FIRST | EVEN | ODD (default) | EVEN | 0 |
| WPS 12.0 | **yes** | 4 | FIRST | EVEN | ODD (default) | EVEN | 0 |
| LibreOffice 24.2.7.2 | **yes** | 4 | FIRST | EVEN | ODD (default) | EVEN | 0 |

- **[V]** All three open **without a repair prompt** and produce a 4-page PDF.
- **[V]** All three render the **first-page** header/footer on page 1, the **even** header/footer on
  pages 2 and 4, and the **default (odd)** header/footer on page 3 — verified in the per-page PDF
  text and the PNG visuals (Word and LibreOffice page images are visually identical apart from font
  substitution).
- **[V]** The `PAGE` fields in the three footers display the correct page number on every page
  (1/2/3/4). Word/WPS live-field reads report the OfficeCLI cached text `1` for each story, which
  the applications then update during pagination — the render is authoritative and correct.
- **[V]** Schema valid per OfficeCLI; no placeholder field caches; source file unchanged by the run.

## Isolation variants (two extra runs)

Built from the same primitive to see whether either mechanism fails independently. All variants
opened repair-free and rendered as intended in Word, WPS, and LibreOffice.

- **First-page only** (`titlePage` + `first` + `default`, no `even`): page 1 = FIRST on pages 2–3 =
  DEFAULT; no `evenAndOddHeaders` in `settings.xml`.
- **Odd/even only** (`default` + `even`, no `first`/`titlePage`): pages 1 and 3 = ODD (default),
  page 2 = EVEN; `evenAndOddHeaders` present, no `titlePg`.
- **First + even, no default** (`titlePage`, `first` and `even`, no `default`): page 1 = FIRST,
  page 2 = EVEN, **page 3 = blank header/footer** — the applications do **not** fall back to the
  first or even part when the default part is missing. This is the correct OOXML behaviour but a
  quick way to create a blank-looking document by accident.
- **First only, no default** (`titlePage` + `first`): page 1 = FIRST, pages 2–3 blank. The common
  "suppress the running header on the cover page" pattern works.

## Conclusion

- **[V]** Different first-page headers/footers and odd/even headers/footers are **portable** across
  Word 16.0, WPS 12.0, and LibreOffice 24.2.7.2, using the plain OOXML construction OfficeCLI
  emits (`headerReference`/`footerReference` of `type=first|default|even`, `w:titlePg`,
  `w:evenAndOddHeaders`). They open without repair and render faithfully, including correct
  odd/even parity and correct page numbers.
- **[V]** The limited-tier classification (D9) and the "Untested" label (D10) are **stronger than the
  evidence warrants** for these target versions. This is a candidate to **promote** the construction
  to fully supported, subject to the caveats below.
- **[?]** The `[?]` note in `references/research/docx-feature-portability.md` ("LibreOffice has
  visibility regressions for first/even headers and does not always preserve link-to-previous") was
  **not** reproduced in LibreOffice 24.2.7.2 for this single-section construction. The multi-section
  "link to previous" behaviour remains untested here and is the main residual uncertainty.

## Documented fallback (if a target application is limited)

Because the measured three are faithful, **no fallback is required for Word 2016+, WPS 12.0, or
LibreOffice 24.2.7.2**. If a specific target version is limited (e.g. LibreOffice 7.6, an older WPS,
or a regression), apply this downgrade and report it:

- **[S] Fallback:** emit a **single default header/footer** for the whole section and drop the
  `first`/`even` variants (removing `w:titlePg` / `w:evenAndOddHeaders`). Put any cover-page-specific
  running text into the first page's body content, and keep page numbering in the one default footer.
  This is the portable subset that every version handles.
- Per application, if limited:
  - **Word** — not limited in 16.0; no fallback. (2016+ shares the feature.)
  - **WPS 12.0** — not limited in the measured version; no fallback. WPS conclusions are
    best-effort (closed source); if a build ignores `evenAndOddHeaders`, use the single-default
    fallback above.
  - **LibreOffice 24.2.7.2** — not limited; no fallback. For 7.6, treat as untested and prefer the
    single-default fallback unless verified.
- **[S]** A downgrade is never silent: record it in the change report with the reason (spec D11/D12).

## Caveats and residual uncertainty

- **[S]** Odd/even selection is **parity-driven by each application's own pagination**. If two
  applications lay the same content onto a different number of pages, the variant that lands on a
  given *content* page can differ. First-page assignment is pagination-independent; odd/even is not.
  This is inherent to the feature, not a defect of the construction.
- **[?]** Multi-section documents, and the "link to previous header/footer" behaviour across a
  section break, were not measured.
- **[?]** LibreOffice 7.6 (spec's lower target bound) was not available; only 24.2.7.2 was measured.
- **[S]** The part slots are `default` = odd pages when even/odd is enabled. WordFlow must document
  that naming, or a user may expect `default` to mean "every page".

## Spec conflicts

- D9 lists **different-first-page and odd/even headers and footers** as *limited*; D10 lists
  **first-page/odd-even headers** as *untested*. This research measures them faithful across all
  three target applications (LibreOffice 24.2 specifically), so the two entries are now **stronger
  than the evidence**. A future spec revision should reclassify them (or note the version boundary),
  and D10's "Untested" list should drop first-page/odd-even headers.
- No conflict with ADR-0004: the construction opens without repair and renders faithfully from a
  shared portable subset (not pixel-identical).

## Reproduce

```sh
tests/generate-fixtures.sh                       # rebuilds the committed fixture
scripts/wf-compat-harness.sh \
  tests/fixtures/headers/firstpage-oddeven.docx \
  --out "$PWD/tests/.out/compat/issue5" --timeout 240 --json
```

(Pass an **absolute** `--out`: the harness builds a `file://` LibreOffice profile URL from it.)
