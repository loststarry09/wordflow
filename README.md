# WordFlow

> A Word layout **skill for agents**.
> OfficeCLI operates `.docx` files; WordFlow teaches an agent how to use OfficeCLI to lay out
> Word documents in a standards-based, maintainable, compatibility-first way.

**v0.1.0 — shipped.** Generate a laid-out `.docx` from content, or tidy an existing one,
without touching its words.

## What it is

Agents can already read and write DOCX through OfficeCLI, but knowing *which* OOXML features
to use — and which to avoid — is the hard part. WordFlow is the judgement layer between "the
CLI can do this" and "this document will open correctly and stay maintainable in Microsoft
Word, WPS Writer, and LibreOffice Writer".

- **Role:** a skill/knowledge layer, not an engine.
- **Executor:** [OfficeCLI](https://officecli.ai) is the default and only tool for DOCX
  operations — WordFlow adds judgement, not another API.
- **Audience:** users who are not Word layout experts and want a correct, standards-based
  result.
- **Output:** DOCX files that are portable, style-driven, reproducible, and easy to keep
  maintaining.

## The two jobs

WordFlow does two jobs of equal priority:

- **Generate from content** — hand it text/Markdown (optionally a template and/or a written
  formatting requirement) and get a laid-out, style-driven document.
- **Tidy an existing `.docx`** — restyle it while leaving every word, image, table, and
  equation untouched.

Both produce a **new** file named `<source name>-排版.docx` (numbered on collision), a
five-area **change report** (what changed, decisions, warnings, downgrades, unverified items),
and a **render preview** by default. The source is never modified.

## v0.1 capabilities

**Fully supported:** heading hierarchy (levels 1–4) and a full standard style set; page size,
orientation, margins; headers/footers and page numbers including different-first-page and
odd/even; table of contents; inline images; regular, merged-cell, and nested tables; captions;
content cross-references; footnotes; basic inline/display equations.

**Supported with a warning or a reported downgrade:** floating images (→ centred inline),
multi-column layout, page-number restart, page-number cross-references (→ content reference),
complex equations.

**Out of scope:** editing content, in-place editing, charts/comments/tracked changes/forms/
watermarks/mail merge/text boxes, non-DOCX conversion, a standalone CLI, any Word/Windows
dependency.

Simplified Chinese is a first-class default (SimSun body, SimHei headings, explicit Latin
pairing, 2-character first-line indent) — no configuration needed.

## Compatibility

A document is **portable** when Microsoft Word, WPS Writer, and LibreOffice Writer each open
it **without a repair prompt** and render it faithfully from a shared portable subset — not
pixel-identical (ADR-0004). The v0.1 acceptance run measured **12/12 output × application
records repair-free** (4 outputs × 3 applications). No application recalculates fields on
open, so WordFlow pre-computes and verifies every cache.

## Install & use

WordFlow is a skill, not a CLI. Requires **OfficeCLI** `>= 1.0.152` on `PATH`
(`officecli --version`) — a single binary, no Office install needed.

- **In this repo (zero-install):** opening a fresh agent session in a clone discovers the
  skill via the committed entry directories (`.agents/skills/wordflow`,
  `.claude/skills/wordflow`). Read [`SKILL.md`](./SKILL.md) as the entry point.
- **Global install:** see [`docs/distribution.md`](./docs/distribution.md) for per-agent
  locations (opencode / Claude Code / Codex) and commands.

The workflows are driven by `scripts/wf-pipeline.sh`; feature capabilities are the individual
`scripts/wf-*.sh` tools. Every DOCX read/write goes through OfficeCLI.

## Testing

```sh
tests/acceptance.sh        # v0.1 end-to-end acceptance (51 checks)
tests/validate-fixtures.sh # validate + issue-check + render all 32 fixtures (65 checks)
tests/pipeline.sh          # existing-document end-to-end (63)
tests/generate.sh          # generate-from-content workflow (73)
tests/tidy.sh              # tidy-existing workflow (54)
tests/compat-harness.sh    # real Word / WPS / LibreOffice (42)
```

**v0.1.0:** 1,495 checks across 27 suites, all passing; `shellcheck -S warning` clean. See
[`tests/README.md`](./tests/README.md) for the full suite list.

## Known limitations

- Formatting-requirement overrides **without a template** are reported unverified rather than
  faked.
- **Automated restructuring** is not in v0.1; a confirmed request is a reported downgrade.
- **Floating images** are downgraded to centred inline (LibreOffice renders them in flow).
- **Pagination is not pixel-identical** across applications.
- TOC **page numbers are intentionally omitted**; update the field (F9) to add them.

## Documentation

- [`PROJECT_STATUS.md`](./PROJECT_STATUS.md) — authoritative current state (read first).
- [`CONTEXT.md`](./CONTEXT.md) — the ubiquitous language.
- [`SKILL.md`](./SKILL.md) — the agent-facing entry point.
- [`docs/spec/v0.1.md`](./docs/spec/v0.1.md) — the behaviour v0.1 promises.
- [`references/README.md`](./references/README.md) — layout knowledge, disclosed on demand.
- [`docs/adr/`](./docs/adr/) — architecture decisions.
- [`report/`](./report/) — the v0.1 development summary and acceptance evidence.
