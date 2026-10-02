# Equations

How WordFlow places equations: a simple inline or display equation is **fully supported**; a
complex construct is **kept as OMML and warned about**, because the failure is construct-specific
and application-specific, not a blanket loss. WordFlow never swaps an equation for an image or plain
text (ADR-0001: no renderer; ADR-0002: that would author content).

Evidence: [`references/research/complex-equations.md`](../research/complex-equations.md) (R04) and
the simple inline/display measurement in
[`field-recalc-and-cross-app-verification.md`](../research/field-recalc-and-cross-app-verification.md)
§7. Tags follow the research convention: **[V]** verified locally, **[S]** standard-backed,
**[?]** reported but unconfirmed.

## Portable construction

OfficeCLI's equation element carries an OMML `<m:oMath>` (inline) or `<m:oMathPara>`
(display) into the document. This is the construction all three applications read natively, and
the only one WordFlow uses.

Inline — the equation sits in the text flow of its paragraph:

```
officecli add <file> /body --type equation --prop mode=inline --prop formula="E = mc^2"
```

Display — the equation gets its own centred paragraph (`/body/oMathPara[N]`):

```
officecli add <file> /body --type equation --prop mode=display --prop formula="\frac{a}{b} = c"
```

`--para <path>` (implemented by `scripts/wf-equation.sh`, #26) targets the parent: for inline it
selects which paragraph receives the `m:oMath`; display mode always produces a body-level
`oMathPara`.

After an add, Get returns the **mode** in `format.mode` and the reconstructed formula in the node's
`text`; it does not surface a `formula` key for DOCX. Judge the add by reading the equation back
(mode present and `text` non-empty), not by the command that ran.

**[V]** Inline and display equations round-trip faithfully in Word 16, WPS Writer 12, and
LibreOffice 24.2, and `officecli validate` passes.

## The judgement — basic vs complex

| Construct | Word 16 | WPS 12 | LibreOffice 24.2 | WordFlow |
|---|---|---|---|---|
| inline / display `E = mc²`, `\frac{a}{b} = c` | faithful [V] | faithful [V] | faithful [V] | fully supported |
| matrix (`\begin{bmatrix}`, `matrix`, `pmatrix`, `vmatrix`) | faithful [V] | faithful [V] | faithful [V] | supported, **no warning** |
| equation array (`m:eqArr`) | faithful [V] | faithful [V] | faithful [V] | supported, **no warning** |
| `cases` without a leading `\|…\|` | [V] OfficeCLI baseline only | [V] OfficeCLI baseline only | faithful [V] | supported, **no warning** |
| `\begin{aligned}` / `\begin{align}` / `\begin{align*}` | faithful [V] | faithful [V] | **not faithful [V]** | **warn** |
| any formula containing `\|` (e.g. `\|x\|`) | faithful [V] | faithful [V] | **not faithful [V]** | **warn** |

- **[V]** LibreOffice is the only application that fails, and only on two encodings: the
  FormulaParser's `\begin{aligned}` output (an operator split into a superscript base, which
  LibreOffice's StarMath reads as a missing operand → `¿`) and the absolute-value bar `|` (a
  LibreOffice character limitation).
- **[V]** Matrices and `m:eqArr` need no workaround: both render faithfully in all three.
- **[S]** OMML is the ECMA-376 math namespace Word, WPS, and LibreOffice all implement; no
  application-specific extension is required.
- **[?]** LibreOffice 7.6, nested matrices, and matrices with fractions in cells are unmeasured;
  the version matrix is pinned by `#10` (`references/research/version-matrix.md`).

## When a construct is risky

A complex equation is **not** downgraded. `scripts/wf-equation.sh` (#26) keeps the OMML and routes
the risk through the shared policy (#30) as the D11 trigger `complex-equation` →
**warn and continue**. The change report (#28) carries one warning naming the construct and the
application at risk; no downgrade is recorded because none is performed.

- **Image — ruled out.** WordFlow has no renderer and OfficeCLI has no equation→image operation
  (ADR-0001); inserting a rendered image would author content (ADR-0002).
- **Plain text — last resort only.** Producible, but it destroys the mathematical layout and is a
  content change, which ADR-0002 forbids without an explicit request and per-item confirmation; it
  must go through stop-and-ask and be reported.

The at-risk constructs are matched on the **input** formula: a `|` anywhere, or an
`aligned`/`align`/`align*` environment. `matrix`/`bmatrix`/`pmatrix`/`vmatrix`, `cases`, and
equation arrays are not matched and produce no warning.

## Verification

Read the output back through OfficeCLI and assert external behaviour:

```
officecli query <file> equation --json        # every equation, in document order
officecli get   <file> /body/oMathPara[1] --json
```

`tests/equation.sh` additionally runs the compatibility harness
(`scripts/wf-compat-harness.sh <out.docx> --apps libreoffice`) and checks
`records[].opens_without_repair` when `soffice` is available; the renderer is reported unverified
when it is not.
