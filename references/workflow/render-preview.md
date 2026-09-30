# Render preview contract

Every WordFlow job produces a **visual preview** of its output by default, so a
person can inspect the result before using it (spec `docs/spec/v0.1.md` §D13).
This file is the contract for that capability: one shared implementation, one
set of rules for which document is previewed and what "disabled" means.

The preview is implemented **once**, in
[`../../scripts/wf-render-preview.sh`](../../scripts/wf-render-preview.sh), and
is used by every workflow. It renders the **final delivered output**
(`<output>.docx`) — never an intermediate file. A preview is for inspection
only: it is **not** the QA checklist (§D14) and **not** a compatibility gate
(§D10). Passing the preview never certifies portability.

Rendering is a read/export. The script never modifies the output document and
never touches the source (ADR-0003); the output is byte-identical before and
after.

## Render method

The output `.docx` is converted to PDF with **LibreOffice headless**
(`soffice --headless --convert-to pdf`); when PNG is wanted, poppler's
`pdftoppm` then rasterises **every** page. This is the chosen method because it:

- covers the whole document, page by page, with no grid or size cap;
- is page-accurate for inspection (the same LibreOffice the compatibility suite
  already uses for render measurement);
- keeps the document reading inside the tools WordFlow already depends on.

`officecli view <f> screenshot` is an acceptable alternative only when it
covers the whole document; it renders a single gridded image and can cap or
summarise content, so it is not used here.

A fresh, per-invocation LibreOffice user profile is used
(`-env:UserInstallation`) so renders never collide with a running LibreOffice.

## CLI

```
wf-render-preview.sh <output.docx> [--out <dir>] [--format png|pdf]
                                  [--disabled] [--report <report.json>] [--json]
```

| Option | Meaning |
|---|---|
| `<output.docx>` | The **final delivered output** to preview. Must exist and be non-empty. |
| `--out <dir>` | Directory for preview artifact(s). Default: the directory containing `<output.docx>`. Created if missing. |
| `--format <fmt>` | `png` (default) or `pdf`. |
| `--disabled` | Produce **no** artifact and note the omission in the change report. Requires `--report`. |
| `--report <r>` | The change report to extend on omission, via [`wf-change-report.sh`](./change-report.md). |
| `--json` | Emit a JSON result object on stdout instead of bare artifact paths. |

### Artifacts

Artifacts are named from the output stem, so a preview is never mistaken for the
delivered document and two documents in one directory cannot collide:

- PNG (default): `<stem>-preview-<page>.png`, one file per page, page order.
- PDF: `<stem>-preview.pdf`.

Stale `-preview-<page>.png` files from an earlier, longer render are removed, so
the artifact set always matches the current document's pages.

Without `--json`, stdout is one artifact path per line (page order), and nothing
when disabled. JSON fields: `output`, `directory`, `format`, `disabled`,
`method`, `dpi`, `pages`, `artifacts`, `report`, `report_updated`,
`compatibility_gate` (always `false`), `warnings`.

### Disabling

When `--disabled` is given:

- **no artifact is produced**;
- the omission is appended to the change report with the shared contract:
  `wf-change-report.sh add --report <r> --area unverified --entry "[D13-preview] …"`;
- the script exits `0` and, with `--json`, reports `disabled: true`,
  `artifacts: []` and `report_updated: true`.

`--report` is **required** with `--disabled`: a disabled preview must never be
silent, so the omission cannot be recorded nowhere. Use `--disabled` for a quick
batch job that should not pay for rendering.

**Area choice — `unverified`.** §D12 defines `unverified` as "anything WordFlow
could not verify, **and intentional omissions**". A disabled preview means the
output was not visually inspected, so it is an intentional omission and belongs
in `unverified`, not `decisions`. The entry carries the stable code
`[D13-preview]` so a consumer can recognise it without parsing prose.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (rendered, or disabled-and-noted). |
| `1` | Output missing/empty, or the render or report update failed. |
| `2` | Usage error or missing dependency. |

## Dependencies

`bash`, `jq`, `soffice` (LibreOffice), and `pdftoppm` (poppler-utils). No
OfficeCLI call is needed for rendering, and no DOCX parser is introduced
(ADR-0001); the DOCX is read only by LibreOffice's converter.

## Verification

`#31` verifies that the preview **reflects the final output** (rendered from the
delivered document, not an intermediate). Acceptance tests for this capability
live in [`../../tests/render-preview.sh`](../../tests/render-preview.sh).
