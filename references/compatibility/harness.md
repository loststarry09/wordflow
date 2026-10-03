# Cross-application compatibility harness

`scripts/wf-compat-harness.sh` is WordFlow's single, reproducible measurement entry point for
the ADR-0004 portability promise. Given one or more `.docx` files it opens each in **Microsoft
Word**, **WPS Writer**, and **LibreOffice Writer** and records, per document/application:

- whether it **opens without a repair prompt** (the hard gate);
- a **rendered artifact** (per-application PDF export) and a **PNG visual** derived from it;
- the **field caches** — each field's *cached text*, not merely its evaluated flag — read both
  through OfficeCLI (document level) and, for Word/WPS, from the live object model.

It is a measurement tool, not a layout tool. It never writes the source document, never parses
DOCX itself (OfficeCLI is the only DOCX reader, per ADR-0001), and never reimplements OfficeCLI.

## Prerequisites

| Requirement | Role | If absent |
|---|---|---|
| `officecli` ≥ 1.0.152, `jq`, `sha256sum` | Required. Document-level field caches, validation, baseline render. | Harness exits `2`. |
| `soffice` (LibreOffice) on `PATH` | LibreOffice record, driven headless with an isolated profile. | LibreOffice record is `unavailable`. |
| WSL Windows interop + `powershell.exe` | Drives Word and WPS over COM. Invoked by absolute path. | Word/WPS records are `unavailable`. |
| Microsoft Word (2016+) with `Word.Application` registered | Word record. Opened `ReadOnly`, no save. | Word record `unavailable` (engine did not start). |
| WPS Writer with `KWPS.Application` registered | WPS record. Opened `ReadOnly`, no save. | WPS record `unavailable`. |
| `pdftoppm` (poppler-utils) | PNG visual derived from each PDF. | PDF is still captured; `visual` is `null`. |

Every application is an **external prerequisite**: this harness never installs or repairs one.
There is no manual one-off step in a run — when a driver is missing the harness reports
`unavailable`, it never fakes a pass. The report records the outcome under `environment` and lists
the prerequisites under `manual_prerequisites`.

### WSL interop and path handling

- WSL interop is assumed (`appendWindowsPath` may be `false`); the harness therefore calls
  `powershell.exe` by absolute path, overridable with `$WF_POWERSHELL`:

  ```sh
  WF_POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  ```

- Documents are staged to a Windows-visible directory (`/mnt/c/temp/wordflow-compat/<run-id>`) and
  COM receives the **converted** path (`/mnt/c/x` → `C:\x`). The staging directory is removed on
  exit; `--keep-staging` retains it for debugging.

## Usage

```sh
scripts/wf-compat-harness.sh <docx|glob|dir> ... [options]

# The fixtures that matter for a quick check (the default set):
scripts/wf-compat-harness.sh

# One document through all three applications, JSON on stdout:
scripts/wf-compat-harness.sh tests/fixtures/toc/toc-basic.docx --json

# A quoted glob, a list file, or every fixture:
scripts/wf-compat-harness.sh 'tests/fixtures/**/*.docx'
scripts/wf-compat-harness.sh --list fixtures.txt --apps libreoffice
scripts/wf-compat-harness.sh --all-fixtures --apps word,libreoffice
```

| Option | Meaning |
|---|---|
| `--apps word,wps,libreoffice` | Subset to drive (default: all three). |
| `--out <dir>` | Artifact directory (default `tests/.out/compat/<timestamp>`). |
| `--timeout <secs>` | Per-application wall-clock bound (default `120`); a modal dialog becomes a `timeout`, never a guess. |
| `--max-fields <n>` | Cap on fields read per application via COM (default `200`). |
| `--json` | Print the JSON report to stdout. |
| `--no-visual` | Skip PNG derivation (PDFs are still captured). |

Exit codes: `0` report produced (even with some apps `unavailable`); `1` no documents to run;
`2` bad usage or a missing required dependency. A per-application failure lives in the JSON, not
the exit code.

The default set is intentionally small: `headers/page-number-footer.docx`,
`toc/toc-basic.docx`, `fields/bookmark-ref-pageref.docx`. Runtime is bounded by
`--timeout × applications × documents`.

## Output

- `<out>/result.json` — the machine-readable report (also printed with `--json`).
- `<out>/<doc>/document.json` — per-document facts (field cache, source SHA, schema validity).
- `<out>/<doc>/<app>.pdf` and `<out>/<doc>/<app>.png` — the render and visual per application.
- `<out>/<doc>/officecli.png` — a baseline OfficeCLI render for comparison.

`result.json` schema: `wordflow.compat-harness/v1`.

```
environment            officecli + per-application availability and versions
manual_prerequisites   the external prerequisites, as strings
apps_requested         the applications asked for
records[]              one object per (document, application):
  source, source_sha256, app, application_version
  status                 ok | failed | unavailable | timeout
  opens_without_repair   true | false | "unavailable" | "timeout"
  detail                 human explanation for any non-ok status
  render                 { pdf, visual, pdf_bytes, pages, pdf_error }
  field_cache            document-level, via OfficeCLI (all fields' cached_text)
  app_field_cache        Word/WPS live object model (null for LibreOffice)
  schema_valid           OfficeCLI validate result
summary                counts by application and placeholder totals
```

`status`/`opens_without_repair` are deliberately separate: `false` means an application rejected
the document; `"unavailable"`/`"timeout"` mean the harness could not measure it. Neither is ever
reported as `true`.

### Field caches

- `field_cache` is read once per document through OfficeCLI and applies to every application. Each
  field carries `cached_text` plus a `placeholder` boolean. A field is judged by its **cached
  text**, never by `evaluated` alone — OfficeCLI writes a cache for every field, so a placeholder
  (`«target»`, `Update field to see table of contents`) still reads `evaluated=true`.
- `app_field_cache` (Word/WPS only) enumerates the *live* fields — body plus every header/footer
  story — and records what that application will actually display. Any placeholder it sees is
  flagged under `placeholder_fields`. This is the cross-application evidence: e.g. a TOC whose
  cached page number is wrong shows the same wrong text in Word and WPS.
- LibreOffice's field cache is not exposed headlessly without a macro round-trip, so
  `app_field_cache` is `null` for LibreOffice; its `render.pdf` shows the cached result as rendered
  and `field_cache` still reports every cache's text.

## What is and is not automatable

**Automatable**

- Opening each document read-only in Word and WPS over COM, and in LibreOffice headless.
- Repair-free detection: a COM `Documents.Open` that throws is `failed`; a modal dialog that blocks
  is bounded by `--timeout` and reported as `timeout` (never as a pass). LibreOffice produces a PDF
  or it does not.
- Per-application PDF export and a PNG visual.
- Reading every field's cached text (OfficeCLI for all apps; Word/WPS object model additionally).
- Closing the read-only document opened by the probe; quitting only a privately owned COM
  instance. The supervisor records the PowerShell worker it creates; the probe identifies its
  Word/WPS process through the document window's HWND and rejects a pre-existing/shared instance.
- Cleanup reads only those ownership records, checks image and creation time, and terminates a
  pinned process handle. PowerShell also requires the matching driver command line. An unrelated
  PID appearing during the run is never a cleanup target. LibreOffice-only runs do no Windows
  process cleanup. Claims and cleanup outcomes are kept under `<out>/processes/` for verification.

**Best-effort / documented limitations**

- **Repair detection is a proxy.** Word/WPS are opened *without* `OpenAndRepair`, so a file needing
  repair either errors or blocks (→ `timeout`); an application that silently auto-recovers could
  still report `ok`. WPS conclusions are best-effort overall (closed source, undocumented format).
- **LibreOffice repair prompts** are not surfaced headlessly; a conversion failure is `failed`, but
  a lossy import that still yields a PDF is reported `ok`.
- **Page count** (`render.pages`) comes from Word's repagination for Word/WPS and is `null` for
  LibreOffice.
- **PNG visuals** need poppler; without it the PDF remains the artifact.

These limits are why a result is evidence, not proof: the harness reports what it measured and
never upgrades an unmeasured case to a pass.
