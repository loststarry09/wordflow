# The WordFlow QA gate (Definition of Done)

`scripts/wf-qa.sh` is the executable Definition of Done (spec §D14): one reproducible gate over a
delivered document and its job artifacts that returns **pass / fail / skip per item** and exits
non-zero if any item fails. "Done" is a check result, not a claim.

It composes the existing capabilities and reimplements none of them:

| Check | What it proves | Source |
|---|---|---|
| `schema` | `officecli validate` accepts the output. | OfficeCLI |
| `no-dangling-styles` | every referenced style is defined, matched by **styleId OR display name**. | #16 / #36 |
| `fields-no-placeholder` | no non-page field ships a placeholder cached result, judged by **cached text**. | spec §D14 |
| `toc-no-page-numbers` | a TOC cache carries no page numbers (`\z`, `format.pageNumbers=false`). | #11 / §D9 |
| `report-valid` | the change report validates (five non-blank areas). | #28 |
| `constructs-reported` | every limited construction in the output is in the report — **no silent downgrade**. | #30 / §D11 |
| `preview-covers-output` | the preview is of the final delivered output. | #29 |
| `source-unchanged` | the plan proves the source bytes are unchanged. | #15 / §D3 |
| `output-is-new-file` | the output is a distinct new file. | §D3 |
| `collision-safe-name` | the name is `-排版` / `-排版 (N)`. | #13 |
| `reproducible` | a second run has an identical content digest (text + style distribution). | §D4 |
| `opens-without-repair` | Word/WPS/LibreOffice open it repair-free (via the #2 harness). | #2 / §D10 |

Checks whose inputs are absent are **skipped**, not failed — but `constructs-reported` **fails** when
a limited construction is present and no `--report` is supplied, because silence cannot be proven
safe. Requested compatibility applications are also required; unavailable drivers fail.

## Usage

```sh
scripts/wf-qa.sh --output <docx> [--source <docx>] [--plan <json>] [--report <json>] \
                 [--preview <json|file>] [--repro <docx>] \
                 [--apps word,wps,libreoffice] [--no-compat] [--json]
```

Exit codes: `0` all applicable checks pass · `1` one or more failed · `2` usage / missing dependency.

`--plan` is the job plan from `scripts/wf-intake.sh` (#15); `--report` the change report from
`scripts/wf-change-report.sh` (#28); `--preview` the JSON from `scripts/wf-render-preview.sh` (#29);
`--repro` a second run's output. The compatibility gate runs the #2 harness over the output for each
requested application. Every requested application is required: a driver that is unavailable,
a missing record, or a non-repair-free open fails the gate. `--no-compat` explicitly skips this check.

## The DoD, in gate terms

A job is done when `wf-qa.sh` reports `ok: true` — schema valid, no dangling style, no placeholder
cache, a number-free TOC, a valid change report that carries every limited construction, a preview
of the delivered output, an unchanged source, a new collision-safe file, reproducible output, and a
repair-free open in every requested application. Structural changes additionally require the user's
per-item confirmation, which is a workflow obligation the gate cannot infer.

See `spec docs/spec/v0.1.md` §D14 and `tests/qa.sh`.
