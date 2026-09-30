# Change report contract

Every output document WordFlow produces ships with a **change report** (spec
`docs/spec/v0.1.md` §D12). This file is the contract for that report: one shared
shape, one tool that creates, extends, validates, and renders it.

The report is **rendered in one place**. Features and workflows contribute structured
entries and never format their own report. The canonical tool is
[`../../scripts/wf-change-report.sh`](../../scripts/wf-change-report.sh); it is pure
`jq` + coreutils and reads no DOCX. It carries **no feature-specific logic** — it only
stores, checks, and prints whatever entries its callers give it.

## Report shape

A report is a JSON object with two strings and five arrays of strings:

```json
{
  "source": "input.md",
  "output": "input-排版.docx",
  "changed":    ["Applied the WordFlow standard style set", "Set A4 portrait, margins 2.54/3.17 cm"],
  "decisions":  ["Body 1.5 line spacing (default, nothing specified)"],
  "warnings":   ["[D11-floating-image] a floating image may render in flow in LibreOffice"],
  "downgrades": ["[D11-floating-image] anchored image centred inline instead"],
  "unverified": ["TOC page numbers omitted — no application recalculates fields on open (D9)"]
}
```

| Key | Meaning (§D12) |
|---|---|
| `source` | The document / content WordFlow started from. Never modified. |
| `output` | The new `.docx` this report describes. |
| `changed` | The layout operations applied — style set adopted or preserved, page setup, headers/footers, automatic content. |
| `decisions` | Every decision made on the user's behalf, **especially each default applied because nothing was specified**. |
| `warnings` | Every construct that may render differently in Word / WPS Writer / LibreOffice Writer (D10, D11). |
| `downgrades` | Every replacement of a preferred construction by a fallback, with the reason. Never silent (D11). |
| `unverified` | Anything WordFlow could not verify, and automatic content intentionally omitted (e.g. TOC page numbers). |

### Entries

Each array holds **plain, non-blank strings**. A `warnings` or `downgrades` entry may
prefix a stable code as `[CODE] text`, for example
`[D11-floating-image] centred inline instead`. The code is advisory: the tool stores and
prints it verbatim and never parses it. Any caller may add an entry whose text contains a
newline; the renderer indents continuation lines.

## CLI

```
wf-change-report.sh new      --source <s> --output <o> --out <report.json>
wf-change-report.sh add      --report <r> --area <area> --entry <text> [--entry <text> ...]
wf-change-report.sh render   --report <r> [--format text|markdown]
wf-change-report.sh validate --report <r>
```

Areas: `changed` | `decisions` | `warnings` | `downgrades` | `unverified`.

- **`new`** — write an empty report (all five areas present and empty) to `--out`.
  It overwrites an existing file at `--out`; the output directory must already exist.
  `--source` and `--output` must be non-empty.
- **`add`** — append one or more entries to one area, in the order given. `--entry` may
  be repeated. The area must be one of the five; anything else is a usage error. Blank
  entries are rejected. The report is validated before and written atomically, so a
  failed `add` never leaves a partially written file.
- **`render`** — print the report for a person. `--format text` (default) prints labelled
  sections; `--format markdown` prints headings. **Empty areas are always stated
  explicitly** — `Downgrades: none` in text, `_none_` under the heading in markdown — so
  a reader can tell "nothing to report" from "the report is incomplete".
- **`validate`** — check the report against the schema below. Prints `valid: <path>` and
  exits `0`, or writes a diagnostic to stderr and exits `1`.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Report missing, unreadable, not valid JSON, or malformed; or a write failed. |
| `2` | Usage error: unknown command/option, missing required option, unknown area or format, blank entry, or a missing dependency. |

## Schema

`validate` accepts a value when **all** hold:

- it is a JSON object;
- `source` and `output` are non-blank strings;
- `changed`, `decisions`, `warnings`, `downgrades`, `unverified` are arrays;
- every element of those arrays is a non-blank string.

Additional top-level keys are tolerated, so sibling work can attach metadata without
breaking existing consumers. The five arrays and the two strings are mandatory.

## How callers use it

A workflow or feature **contributes structured entries**; it does not format anything:

```sh
scripts/wf-change-report.sh new --source "$src" --output "$out" --out "$report"
scripts/wf-change-report.sh add --report "$report" --area changed \
  --entry "Applied the WordFlow standard style set" \
  --entry "Set A4 portrait, margins 2.54/3.17 cm"
scripts/wf-change-report.sh add --report "$report" --area decisions \
  --entry "Body 1.5 line spacing (default, nothing specified)"
scripts/wf-change-report.sh render --report "$report" --format markdown
```

The risk policy of §D11 (ticket #30) supplies warning and downgrade **entries** of the
shape above, including any `[CODE]` prefix; they flow through `add --area warnings` and
`add --area downgrades` with no per-feature formatting. Features contributed by the
sibling tickets (#19–#27, #29, #30, #35) graft their entries onto the same report.

Acceptance tests live in [`../../tests/change-report.sh`](../../tests/change-report.sh).
