# WordFlow

> A Word layout **Skill for Agents**.
> OfficeCLI operates DOCX; WordFlow teaches an Agent how to use OfficeCLI to lay out Word documents in a standards-based, maintainable, compatibility-first way.

## Where to start (Agent reading order)

Read these first, in order — they are the whole default context:

1. [`PROJECT_STATUS.md`](./PROJECT_STATUS.md) — authoritative current status: what is decided, verified, and next.
2. [`CONTEXT.md`](./CONTEXT.md) — the ubiquitous language.
3. [`SKILL.md`](./SKILL.md) — the agent-facing entry point.
4. Then only the **ADR or `references/` file the task actually touches**.

Do **not** read `report/` by default: it is a dated audit trail, opened only to trace how a
decision or fact was reached (see [`report/README.md`](./report/README.md)).

## Why this exists

Agents can already read and write DOCX through OfficeCLI, but knowing *which* OOXML features to use — and which to avoid — is the hard part. WordFlow is the missing layer of judgement between "the CLI can do this" and "this document will open correctly and stay maintainable in Microsoft Word, WPS Writer, and LibreOffice Writer."

## Positioning

- **Role**: a skill/knowledge layer, not an engine.
- **Executor**: [OfficeCLI](https://officecli.ai) is the default and only tool for DOCX operations.
- **Audience**: users who are not Word layout experts and want a correct, standards-based result.
- **Output**: DOCX files that are portable, style-driven, reproducible, and easy to keep maintaining.

## Goals

- Help non-experts produce properly laid-out DOCX files.
- Use Word's real features correctly: styles, headings, page margins, headers/footers, images, tables, captions, tables of contents, references, cross-references, footnotes, equations, and fields.
- Prefer standard, widely supported DOCX / OOXML capabilities.
- Stay compatible with Microsoft Word, WPS Writer, and LibreOffice Writer.
- Avoid dependence on Microsoft Word–proprietary behaviour.
- Delegate all DOCX mutation to OfficeCLI; encode the *how* and *why* here.

## Non-goals

- Re-implementing anything OfficeCLI already does (create/read/query/set/add/remove/dump/batch, raw XML, validation).
- Shipping a DOCX parser, renderer, or a replacement for python-docx / pandoc / OfficeCLI.
- Requiring Microsoft Word (or Windows) to produce a valid document.
- Emitting Word-only features when a portable alternative exists.
- Being a general document-conversion tool (PDF, Markdown, etc.).

## Core principles

1. **OfficeCLI is the single execution layer.** Every DOCX read or write goes through it; this project adds judgement, not another API.
2. **Compatibility first.** If Word, WPS, and LibreOffice do not all handle a feature well, prefer the portable construction.
3. **Styles drive formatting.** Set paragraph/character styles; avoid per-run ad-hoc formatting, because styles are what keep documents consistent and maintainable.
4. **Standards over shortcuts.** Prefer OOXML constructs with broad support; reach for `raw-set` only when the DOM layer cannot express it, and document why.
5. **Reproducible by construction.** Prefer declarative, replayable operations (styles + `dump`/`batch`) so a layout can be regenerated, not hand-tweaked.
6. **Verify, then report.** Validate with OfficeCLI's schema check and issue view before calling a document done.
7. **Progressive disclosure.** The skill stays small; layout knowledge lives under `references/` and is loaded only when a task needs it.

## Project layout

```
wordflow/
├── README.md            # this file
├── PROJECT_STATUS.md    # authoritative current status (read first)
├── CONTEXT.md           # ubiquitous language / glossary
├── SKILL.md             # agent-facing entry point (minimal; grows over time)
├── .gitignore
├── scripts/             # reproducible operations that drive OfficeCLI (e.g. style ownership)
├── references/          # layout knowledge, disclosed on demand (see references/README.md)
│   ├── README.md
│   ├── core/            # styles, headings, sections, margins, headers/footers
│   ├── fields/          # fields, TOC, captions, cross-references, footnotes/endnotes
│   ├── objects/         # images, tables, equations, charts
│   ├── compatibility/   # Word / WPS / LibreOffice portability rules
│   └── research/        # researched facts, tagged verified / standard / uncertain
├── tests/
│   ├── README.md
│   ├── generate-fixtures.sh   # deterministically rebuild fixtures/ with OfficeCLI
│   ├── validate-fixtures.sh   # validate + issue-check + render every fixture
│   └── fixtures/        # real DOCX inputs/outputs for round-trip testing
├── docs/
│   ├── README.md
│   └── adr/             # architecture decision records
├── report/              # dated work reports (see report/README.md)
└── .agents/skills/      # engineering workflow skills (Matt Pocock set)
```

`references/` is intentionally split by *concern* rather than by OfficeCLI element, because the same element (e.g. `paragraph`) appears in several concerns.

## Prerequisites

- **OfficeCLI** `>= 1.0.152` on `PATH` (`officecli --version`). It is a single binary with no Office installation required.

## Status

**Foundation.** The skill skeleton, references layout, and a verified DOCX fixture suite
exist; requirements are clarified and the compatibility research is done. No WordFlow
product guidance or layout rules have been written yet.

**Current status lives in [`PROJECT_STATUS.md`](./PROJECT_STATUS.md).**
