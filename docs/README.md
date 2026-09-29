# Docs

Project-level documentation.

For current status, read [`../PROJECT_STATUS.md`](../PROJECT_STATUS.md); it summarises
these ADRs and links back. Load an individual ADR only when the task touches it.

- `adr/` — architecture decision records. One decision per file, numbered (`0001-*.md`). Record the decision and its consequences; the `domain-modeling` / `grill-with-docs` skills maintain these.

Recorded:

- `0001` — OfficeCLI is the single execution layer
- `0002` — WordFlow lays out; it never writes or edits content
- `0003` — Output is always a new file; the source document is never modified
- `0004` — Compatibility means "opens without repair", not identical rendering
