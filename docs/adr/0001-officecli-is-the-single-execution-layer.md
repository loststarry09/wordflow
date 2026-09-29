# OfficeCLI is the single execution layer

WordFlow adds judgment, not another DOCX API. Every read and write of a `.docx` is performed by OfficeCLI; WordFlow contains no parser, renderer, or writer of its own. This keeps a single code path for correctness and makes OfficeCLI's own schema authority the place to resolve uncertainty. The cost is a hard dependency on OfficeCLI's capability set and version.

## Considered options

Wrapping a general OOXML library (python-docx, docx4j) behind WordFlow, or emitting raw OOXML directly. Rejected: both duplicate an execution layer, add a second behaviour to keep compatible, and pull WordFlow back into being an engine rather than a knowledge layer.
