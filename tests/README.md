# Tests

Tests exercise WordFlow's guidance against **real DOCX files** produced and inspected with OfficeCLI.

## Layout

- `fixtures/` — input and expected DOCX documents for round-trip checks.
  - Keep inputs small and purpose-built (one feature per fixture where possible).
  - Name by feature: `styles/heading-hierarchy.docx`, `fields/toc-basic.docx`.
  - Treat expected outputs as regenerable: a test that compares documents should rebuild them and diff, not freeze opaque blobs.
  - See `fixtures/MANIFEST.md` for what every fixture tests.
- `generate-fixtures.sh` — deterministically rebuild `fixtures/` with OfficeCLI (explicit locales; no host-locale dependence).
- `validate-fixtures.sh` — run `validate`, `view issues`, and a `screenshot` render over every fixture; writes renders to `.out/` (git-ignored).
- Per-capability acceptance suites (each drives its `scripts/wf-*.sh`):
  - `style-ownership.sh` (#16), `output-naming.sh` (#13), `page-setup.sh` (#18),
    `standard-styles.sh` (#17), `intake.sh` (#15);
  - `change-report.sh` (#28), `render-preview.sh` (#29), `risk-policy.sh` (#30);
  - `toc-cache.sh` (#11), `crossref-cache.sh` (#12) — the cache mechanisms;
  - the feature suites (#19–#27): `headers.sh`, `image.sh`, `table.sh`, `caption.sh`,
    `crossref.sh`, `toc.sh`, `footnote.sh`, `equation.sh`, `template.sh`;
  - `qa.sh` (#31) — the Definition-of-Done gate;
  - `skill-discovery.sh` (#14) — per-agent skill discovery;
  - `compat-harness.sh` (#2) — drives real Word/WPS/LibreOffice;
  - `generate.sh` (#32) — the full generate-from-content workflow (D4);
  - `tidy.sh` (#33) — the full tidy/restyle-existing workflow (D5);
  - `acceptance.sh` (#34) — v0.1 end-to-end acceptance (both workflows, tiers, DoD, compat);
  - `pipeline.sh` (#35) — the existing-document end-to-end run.
- Correctness regression suites for v0.1.1:
  - `source-protection.sh` — shared direct/symlink/hardlink negative matrix over writers;
  - `table-correctness.sh` — shape rejection and independent outer/nested width read-back;
  - `standard-styles-idempotency.sh` — existing IDs and rerunning the tool's own output;
  - `crossref-isolation.sh` — unrelated field markers, locks and caches stay intact;
  - `qa-constructs.sh` — current limited constructs need matching risk entries;
  - `preview-artifacts.sh` — acceptance rejects missing/empty/non-file preview artifacts;
  - `compat-required.sh` — requested unavailable applications fail the QA/release gate;
  - `qa-output-alias.sh` — actual/declared source and output aliases fail QA;
  - `compat-ownership.sh` — native unrelated processes survive; owned timeout processes
    exit; stale PID identity and unrelated command lines are refused;
  - `toc-cache-concurrent.sh` — two real TOC suites use separate staging/artifacts and
    both complete with zero native skips.
- `lib/preview-artifacts.sh` — the filesystem predicate shared by acceptance and its negative suite.
- `probes/` — research probes (not pass/fail gates): `large-document.sh` (#9),
  `detect-versions.sh` (#10).
- `.out/` — generated renders, pipeline and probe artifacts. Not committed.

## What to verify

- The document opens without repair in Microsoft Word, WPS Writer, and LibreOffice Writer.
- `officecli validate` passes and `officecli view <file> issues` reports nothing blocking.
- The intended style/field construction is present (`officecli get` / `query`), not merely the visual appearance.

A fixture suite exists under `fixtures/`; regenerate with `generate-fixtures.sh` and verify with `validate-fixtures.sh`.

## Required compatibility gate

Run `WF_REQUIRE_COMPAT=1 tests/compat-harness.sh` for release verification. Word/WPS
unavailable is a failure in this mode; the default diagnostic suite may skip unavailable
Windows engines. The measurement harness still reports `unavailable` truthfully.
`wf-qa.sh` requires every requested application unless `--no-compat` is supplied.

The harness cleans only explicit process owners, pinned by PID and creation time;
LibreOffice-only runs never clean Windows processes. Native COM tests still use
`/tmp/wordflow-wincom.lock` to serialize application calls. `toc-cache.sh` allocates a
unique artifact directory and Windows staging directory per invocation, and removes
only its own staging on exit. `compat-ownership` and `toc-cache-concurrent` require
real Word/WPS/PowerShell; missing native drivers fail those suites.

`validate-fixtures.sh` also checks exact grid-width equality, fixed layout, explicit
column widths, and direct borders at both levels of the nested-table fixture (73 checks
over 32 fixtures).
