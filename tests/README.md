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
  - `compat-harness.sh` (#2) — drives real Word/WPS/LibreOffice;
  - `pipeline.sh` (#35) — the real single-document end-to-end run.
- `.out/` — generated renders and pipeline artifacts. Not committed.

## What to verify

- The document opens without repair in Microsoft Word, WPS Writer, and LibreOffice Writer.
- `officecli validate` passes and `officecli view <file> issues` reports nothing blocking.
- The intended style/field construction is present (`officecli get` / `query`), not merely the visual appearance.

A fixture suite exists under `fixtures/`; regenerate with `generate-fixtures.sh` and verify with `validate-fixtures.sh`.
