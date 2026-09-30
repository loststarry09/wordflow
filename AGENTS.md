# WordFlow — Agent Instructions

WordFlow teaches an agent how to lay out `.docx` documents by driving OfficeCLI. Before
working, read in order: [`PROJECT_STATUS.md`](./PROJECT_STATUS.md),
[`CONTEXT.md`](./CONTEXT.md), [`SKILL.md`](./SKILL.md). Read `report/` only to trace a
decision, and load an individual ADR or `references/` file only when the task touches it.

## Agent skills

### Issue tracker

Issues and specs for this repo live as GitHub issues in `loststarry09/wordflow`; use the
`gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles; each label string equals its role name. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.
