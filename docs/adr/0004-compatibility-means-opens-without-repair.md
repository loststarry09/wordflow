# Compatibility means "opens without repair", not identical rendering

A document is portable when Microsoft Word, WPS Writer, and LibreOffice Writer each open it without a repair prompt and render it faithfully from a shared, portable subset of OOXML. WordFlow does not promise pixel-identical output across the three applications and does not chase renderer-specific quirks. This lets the project pick one portable construction instead of three per-application variants, and keeps WPS — closed-source, with no format-level documentation — a best-effort target rather than a blocking one.

## Considered options

Targeting Microsoft Word alone (much easier, but abandons the other two applications and bakes Word-only behaviour into the output) and shipping per-application output profiles (three times the surface, and it contradicts the "one portable construction" principle).
