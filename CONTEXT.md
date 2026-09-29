# WordFlow

WordFlow is a knowledge layer that teaches an Agent how to lay out Word (`.docx`) documents. It decides *how a document should be shaped* and delegates every read and write to OfficeCLI. It is not an engine, a parser, or a renderer.

## Language

### Roles

**WordFlow**:
The judgement layer — the rules and knowledge that decide how a `.docx` should be structured and formatted.
_Avoid_: plugin, engine, renderer, parser, backend

**OfficeCLI**:
The single tool that performs every DOCX read and write on WordFlow's behalf.
_Avoid_: backend, adapter, "Word"

### The layout / content boundary

**Layout**:
How content is presented — styles, fonts, sizes, line spacing, margins, page setup, headers/footers, page numbering, captions, tables of contents, and how elements are arranged on the page. WordFlow owns this.

**Content**:
The words, images, tables, and equations a document conveys. WordFlow does not author or edit content in v0.1 — it only lays it out.
_Avoid_: "text" when the whole content is meant

**Restyle**:
Changing only the layout of a document the user already has, leaving every word, image, and table untouched. The safe default for working on an existing document.

**Restructure**:
Changing a document's organization — heading levels, section order, grouping of paragraphs — without changing its words. Never automatic; only on the user's explicit request and confirmation.

### Style ownership

**Standard styles**:
WordFlow's own style set, used when a document has no usable styles or the user supplies no template. When a document already has a coherent style set, WordFlow preserves and tidies it instead of replacing it.

### Documents in a job

**Source document**:
The document the user supplies, either as raw content or as an existing `.docx` to restyle. WordFlow never modifies it.

**Output document**:
The new `.docx` WordFlow produces, named by default `"<source name>-排版.docx"`, numbered on collision. Always a new file, not an overwrite of the source.

**Change report**:
The short summary WordFlow delivers with every output document: what it changed, which formatting decisions it made on the user's behalf, and any warnings or unverified items.

### Behaviour under risk

**Warn**:
Producing the result while reporting a known risk — for example, a construction that may render differently in one of Word, WPS Writer, or LibreOffice Writer.

**Downgrade**:
Replacing a preferred construction with a less capable fallback because the preferred one is unavailable or unsafe. A downgrade is never silent; it is always reported in the change report.

**Refuse**:
Stopping without producing output and asking the user instead of guessing. WordFlow refuses to change content, to restructure without confirmation, or to work on a source it cannot read safely.

**Template**:
A `.docx` the user supplies whose styles and page setup WordFlow should adopt. A template is a source of *look*, never of content.

**Formatting requirement**:
A written instruction from the user about how the document should look (fonts, sizes, spacing, indentation, margins). WordFlow reads it as intent. When a formatting requirement and a template disagree, the formatting requirement wins; both win over WordFlow's defaults.

### Quality bar

**Portable**:
A document is portable when Microsoft Word, WPS Writer, and LibreOffice Writer each open it without a repair prompt and render it faithfully. WordFlow prefers constructions that all three handle over ones that only one handles.

**Standards-based**:
Built from broadly supported OOXML constructs rather than application-specific extensions. Being standards-based is a design stance; it is not the same as passing a validation check.

**Reproducible**:
The same instructions regenerate the same layout, rather than depending on manual fixes. Layouts are expressed as replayable operations, not hand edits.
