# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`PROJECT_STATUS.md`** — the authoritative entry point: what is decided, verified, and next.
- **`CONTEXT.md`** at the repo root — the ubiquitous language.
- **`docs/adr/`** — read the ADRs that touch the area you're about to work in.
- **`SKILL.md`** — the agent-facing entry point that ships with the skill.

Read `report/` only to trace how a decision or fact was reached; it is a dated, append-only audit trail. Load
an individual `references/` file only when a task needs that topic.

This is a **single-context** repo: one `CONTEXT.md` plus `docs/adr/` at the root.

## File structure

```
/
├── PROJECT_STATUS.md
├── CONTEXT.md
├── SKILL.md
├── docs/
│   ├── adr/            ← architecture decision records
│   ├── agents/         ← engineering-skills configuration
│   └── spec/           ← published product specs
├── references/         ← layout knowledge, disclosed on demand (core/ fields/ objects/ compatibility/ research/)
└── tests/              ← fixtures and validation scripts
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0003 (output is a new file) — but worth reopening because…_
