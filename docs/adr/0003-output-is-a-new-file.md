# Output is always a new file; the source document is never modified

Every job writes a new `.docx` and leaves the source file untouched, so a failed or unwanted result can never destroy the user's document. It also keeps a job idempotent: the same source plus the same instructions produce the same output. In-place editing is out of scope for v0.1. Rejected: editing in place — convenient, but it destroys the original and removes the ability to re-run.

Creating the independent output file may be done by copying the source's bytes and then mutating that copy **only** through OfficeCLI. Copying bytes is a file-system operation that obtains a distinct file; it is not a WordFlow DOCX parse or write, and every semantic DOCX read or write remains OfficeCLI's (ADR-0001).
