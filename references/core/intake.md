# Intake, precedence, and source protection

The **front door of both workflows** (spec `docs/spec/v0.1.md` §D2, §D3, §D4 step 1,
§D5 step 1). Intake accepts either raw **content** or an existing `.docx` **source**, plus an
optional **template** and/or written **formatting requirement**; resolves the precedence
chain; protects the source; refuses when a source cannot be read safely; and emits a
machine-readable **job plan** that the downstream workflows (`#32`, `#33`, and the walking
skeleton `#35`) consume.

Intake **does not lay anything out**. It resolves *which layer wins* and *what the output
path is*; rendering the style set is `#17`, template adoption is `#27`, page setup is `#18`,
and the end-to-end apply is `#35`. It performs every DOCX read through OfficeCLI (ADR-0001)
and never writes, copies, or edits a DOCX.

The behaviour is implemented as `scripts/wf-intake.sh`; the acceptance suite is
`tests/intake.sh`.

## Inputs

Exactly one source is required:

- `--source <docx>` — a **restyle** job on an existing `.docx`.
- `--content <file>` — a **generate** job from text/Markdown content.

Optional:

- `--template <docx>` — a source of *look* only, never content (spec §D5, `#27`).
- `--requirement <file>` — a written formatting requirement (see *Requirement file* below).
- `--output <path>` — a user-specified output path (file or directory); default naming is
  delegated to `scripts/wf-output-name.sh` (`#13`).
- `--plan <path>` — write the job plan JSON to a file in addition to printing a summary.
- `--json` — print the job plan as JSON instead of the human summary.

## The precedence chain

Highest first (spec §D2, §D5):

```
formatting requirement  →  template  →  document styles (restyle)  →  standard styles  →  defaults
```

Intake resolves the chain into two facts in the plan:

- **`style.set`** — where the style *definitions* come from: `template` if a template was
  supplied; else `document` if a restyle source uses named styles (`#16` decides this); else
  `standard` (the WordFlow set, `#17`).
- **`style.source`** — the highest layer that is **authoritative** for the look:
  `formatting-requirement` > `template` > `document-styles` > `standard-styles`.

A formatting requirement is authoritative whenever it is supplied, because §D5.3 states it
outranks both the template and the document's own styles. Its machine-applicable subset is
the parsed **overrides** (below); any other text is preserved as **notes** for the agent to
read as intent. When a requirement and a template are both present, `style.set` is `template`
(the definitions) while `style.source` is `formatting-requirement` (the authority): the
requirement's overrides shadow the template. This is the worked conflict case.

The plan also lists the five layers with `rank`, `present`, and `authoritative`, so a consumer
can see the chain explicitly rather than reconstruct it.

## Requirement file

The formatting requirement is a plain UTF-8 text file. The format is **frozen by this
ticket** (the spec fixes the precedence but not the file syntax):

- Blank lines and lines whose first non-blank character is `#` are ignored.
- A line of the form `key = value` or `key: value` is a machine-applicable **override**. The
  key must match `[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*` — a dot-separated identifier in
  the look vocabulary (`font.ea`, `body.size`, `page.margin.left`, …). Whitespace around the
  separator is ignored; the value is the rest of the line, trimmed.
- Any other non-blank line is preserved verbatim as a **note** (free-form intent the agent
  reads, not something intake interprets).
- Duplicate keys are kept in written order; consumers apply last-wins.
- A requirement with **no overrides and no notes** (an empty file, or only blank/comment
  lines) contributes nothing and does **not** outrank a template. The layer is still
  `present` (the file was supplied), but not `authoritative`.

Intake does **not** validate the meaning of a key — the vocabulary belongs to the feature
that owns that facet. It only distinguishes an override from free text, which is what the
precedence resolution needs.

## Source protection (spec §D3, ADR-0003)

- The source (and template) are opened **read-only** and never modified. Intake creates no
  DOCX at all; the planned `output` path names a file that does not exist yet.
- A SHA-256 of the source is taken **before** and **after** all reads and recorded in the
  plan (`source.sha256`, `source.sha256_after`, `source.unchanged`). A mismatch is a
  protection failure and a refusal.
- Output naming, collision numbering, and the "never overwrite a specified file" rule are
  delegated to `wf-output-name.sh`; intake does not reimplement them.

## Refusal conditions

Intake **stops and asks** (non-zero exit, a clear message, **no output document and no plan
file written**) when:

| Condition | `reason_code` |
|---|---|
| The source `.docx` / content file is missing or unreadable | `source-unreadable` / `content-unreadable` |
| The source `.docx` fails `officecli validate`, or OfficeCLI cannot read it | `source-invalid` |
| A supplied template is missing/unreadable | `template-unreadable` |
| A supplied template fails validation / cannot be read | `template-invalid` |
| A supplied requirement file is missing or unreadable | `requirement-unreadable` |
| The user-specified output path already exists (`#13` exit 3) | `output-exists` |
| No free collision number can be found (`#13` exit 4) | `output-unavailable` |
| The source changed during the job (hash mismatch) | `source-changed` |

Refusals are reported on stderr (human) and, with `--json`, as a JSON object with
`"status": "refused"` and `"output_written": false`. A refusal writes nothing to `--plan`.

## Job plan

Stable JSON emitted on success (`"status": "planned"`). Everything downstream depends on
these field names; they are frozen for `#35`.

```json
{
  "status": "planned",
  "tool": "wf-intake.sh",
  "version": 1,
  "mode": "restyle",
  "source": {
    "kind": "docx",
    "path": "/abs/report.docx",
    "sha256": "…",
    "sha256_after": "…",
    "unchanged": true
  },
  "inputs": {
    "template": { "path": "/abs/tpl.docx", "sha256": "…", "styles": ["WF Body", "WF Quote"] },
    "requirement": {
      "path": "/abs/req.txt",
      "overrides": [ { "key": "font.ea", "value": "楷体" } ],
      "notes": ["Body text must be justified."]
    }
  },
  "precedence": [
    { "layer": "formatting-requirement", "rank": 1, "present": true,  "authoritative": true,  "note": "…" },
    { "layer": "template",               "rank": 2, "present": true,  "authoritative": false, "note": "…" },
    { "layer": "document-styles",        "rank": 3, "present": true,  "authoritative": false, "note": "…" },
    { "layer": "standard-styles",        "rank": 4, "present": false, "authoritative": false, "note": "…" },
    { "layer": "defaults",               "rank": 5, "present": true,  "authoritative": false, "note": "…" }
  ],
  "style": {
    "source": "formatting-requirement",
    "set": "template",
    "ownership": "use-template-styles",
    "coherent": true,
    "named_styles_in_use": ["Title"],
    "defined_styles": ["Normal", "Title"],
    "dangling_styles": [],
    "heading_levels": [1, 2, 3],
    "template_styles": ["WF Body", "WF Quote"]
  },
  "output": { "output": "/abs/report-排版.docx", "mode": "default", "…": "… (wf-output-name.sh contract)" },
  "protection": { "read_only": true, "verified_unchanged": true },
  "change_report": [ "…intake-level entries for #28…" ]
}
```

`inputs.template` and `inputs.requirement` are `null` when not supplied. `style.ownership`,
`style.coherent`, and the document-style fields come from `wf-style-ownership.sh` (`#16`) for
a restyle and are `null`/empty for a generate job. `output` is the unmodified JSON of
`wf-output-name.sh`, so its fields (`output`, `filename`, `collision_index`, `numbered`,
`warnings`, …) are stable by reference.

`change_report` holds intake-level entries in the `#28` contract (plain non-blank strings);
intake does not format a report.

## Reproducibility

The plan contains no timestamps and is a pure function of the inputs and the filesystem, so
the same inputs produce byte-identical JSON.

## Limitations

- **No layout.** Intake resolves authority; it does not apply fonts, styles, margins, or
  anything visual. `style.set`/`style.source` are a plan, not a rendered result.
- **Requirement syntax only.** Only `key = value` / `key: value` lines become overrides; the
  key vocabulary is not interpreted or validated.
- **Uniform refusals.** Every refusal exits `3`; the specific reason is in `reason_code`.
- **Content hashing.** A content file is hashed like a source so `unchanged` is meaningful,
  but content is never validated (it is not a `.docx`).
- **Template styles are names only.** Intake reads a template's style *names* for the plan;
  adopting their property values is `#27`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Plan produced. |
| `2` | Usage error / missing dependency. |
| `3` | Refused — stop and ask (`reason_code` in the JSON). |

## Evidence

- `scripts/wf-intake.sh` — the implementation.
- `tests/intake.sh` — acceptance checks: usage errors; the precedence chain with conflicting
  requirement + template inputs; source/`template`/requirement refusal paths; source hash
  protection; default naming and collision numbering; specified path; generate vs restyle;
  `--json`/`--plan` contracts; reproducibility.
- `scripts/wf-output-name.sh` / `references/core/output-naming.md` (`#13`) — naming.
- `scripts/wf-style-ownership.sh` / `references/core/style-ownership.md` (`#16`) — the
  document-styles decision.
- `scripts/wf-change-report.sh` / `references/workflow/change-report.md` (`#28`) — the report
  contract intake contributes entries to.
