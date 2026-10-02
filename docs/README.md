# Docs

Project-level documentation.

For current status, read [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md); it summarises these
and links back. Load a file only when the task touches it.

- [`spec/v0.1.md`](./spec/v0.1.md) — the product spec: the behaviour WordFlow v0.1 promises
  (D1–D14). The contract every workflow and test is held to.
- [`adr/`](./adr/) — architecture decision records. One decision per file, numbered
  (`0001-*.md`). Read the ADR that touches your area; the `domain-modeling` /
  `grill-with-docs` skills maintain these.

Recorded ADRs:

- [`0001`](./adr/0001-officecli-is-the-single-execution-layer.md) — OfficeCLI is the single execution layer
- [`0002`](./adr/0002-layout-only-never-edit-content.md) — WordFlow lays out; it never writes or edits content
- [`0003`](./adr/0003-output-is-a-new-file.md) — Output is always a new file; the source is never modified
- [`0004`](./adr/0004-compatibility-means-opens-without-repair.md) — Compatibility means "opens without repair"

- [`distribution.md`](./distribution.md) — how the skill is installed and discovered by
  opencode, Claude Code, and Codex.
- [`agents/`](./agents/) — engineering-workflow configuration (issue tracker, triage labels,
  domain-doc layout). See [`../AGENTS.md`](../AGENTS.md).
