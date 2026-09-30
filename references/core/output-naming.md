# Output naming and filename safety

The **frozen** rule WordFlow uses to name the new `.docx` it produces, and the evidence that
the default suffix is safe in the target environments. It settles the spec open question
*"Output filename safety — whether `-排版` is safe in every environment, and whether the
default should localise"* (spec `docs/spec/v0.1.md` §Further Notes). It is derived from
§D2 and §D3, which fix the name `<source name>-排版.docx`, "numbered on collision, path
specifiable".

The rule is implemented as the pure path primitive `scripts/wf-output-name.sh`; the
acceptance suite is `tests/output-naming.sh`. Neither ticket nor script reads or writes a
DOCX — every DOCX operation stays with OfficeCLI (ADR-0001).

## The frozen rule

**Inputs.** A **source path** `S` (used only for its name; it need not exist and is never
read or changed) and an optional **user-specified path** `P`.

**Definitions.**

- `dir(S)` — the directory containing `S`, resolved to an absolute path.
- `base(S)` — the final path component of `S`.
- `stem(S)` — `base(S)` with **one** trailing extension removed. A leading-dot name is kept
  whole: `report.docx → report`, `archive.tar.gz → archive.tar`, `notes → notes`,
  `.docx → .docx`.
- `SUFFIX` — the fixed token `-排版` (U+6392 U+7248, no leading/trailing space).
- `EXT` — `.docx`.

**Default target.** With no user path:

```
<dir(S)>/<stem(S)>-排版.docx
```

If that name is taken, append a **space + parenthesised ASCII number** before the
extension, starting at 2, and take the lowest free number:

```
<stem>-排版.docx   →   <stem>-排版 (2).docx   →   <stem>-排版 (3).docx   →   …
```

"Taken" means any existing directory entry, including a directory or a (possibly dangling)
symlink, so resolution never lands on a name that the subsequent write could clobber.
Numbering fills the lowest gap: with `…-排版.docx` and `…-排版 (3).docx` present, the next
name is `…-排版 (2).docx`.

**User-specified path `P`.**

- If `P` is an existing directory (or ends in a path separator), the default-named file is
  placed inside it, still collision-numbered: `P/<stem(S)>-排版 (n).docx`.
- Otherwise `P` is the exact target. It is honoured verbatim (resolved to absolute). If it
  already exists, WordFlow **refuses** and asks rather than overwrite (ADR-0003; spec §D3).
  It does **not** silently rename a name the user chose.

**Never overwrite.** In every mode the returned path names a file that does not exist at
resolution time; the primitive itself creates nothing.

**Localisation: none.** The suffix is always `-排版` and the collision number is always
ASCII (` (2)`, not ` (二)`), regardless of the document language, the user's locale, or the
operating system. See *Why the default does not localise* below.

**Portability warning (does not change the path).** If the resolved path contains a
character illegal on Windows (`< > : " \ | ? *` or a C0 control), is a reserved Windows
device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`), or ends in a space
or dot, the primitive emits a warning (stderr and the JSON `warnings` field) so the agent
can surface it in the change report (D11/D12). WordFlow does not rewrite the user's own
source name; the caller can choose a different name with `--output`.

**Resolution is deterministic.** The same source path and the same existing filesystem
always yield the same output path.

## Why the default does not localise

`-排版` is a **fixed provenance token**, not a translated word, and the rule is deliberately
not localised:

1. **Reproducibility (spec §D14, *Testing Decisions*).** The output name must be a pure
   function of the source path. Localising would make it depend on detected document
   language, host locale, or a translation table, so the same source could produce different
   names in different environments and the naming tests would become host-dependent.
2. **The content boundary (ADR-0002).** Localising means choosing a document's language and
   translating a word for it — judgement over content WordFlow must not perform — and it
   adds a translation surface with no user value.
3. **A stable marker.** `-排版` consistently flags a WordFlow output; a translated suffix
   would fragment that identity across locales and could collide with a user's own naming
   convention.
4. **The v0.1 default is Simplified-Chinese-first (spec §D3, §D6).** The default audience
   reads `排版` ("typesetting/layout") directly. A user who wants another name has the
   explicit `--output` path, which is honoured verbatim.

This resolves the open question as **"safe, and not localised"**.

## Is `-排版` safe? Evidence

Tags: `[V]` verified by a real check in this repo's WSL/Linux environment; `[S]`
standard/documentation-backed; `[?]` uncertain / not measured here.

### The characters themselves

| Property | Value | Tag |
|---|---|---|
| Code points | `排` U+6392, `版` U+7248 — CJK Unified Ideographs, BMP | `[V]` |
| Category | `Lo` (letter, other) | `[V]` |
| Normalisation | NFC = NFD = NFKC = NFKD (no decomposition, no compatibility mapping) | `[V]` |
| UTF-8 | 6 bytes for `排版` (+1 for the hyphen), 2 characters | `[V]` |
| UTF-16 | 2 code units, one per character; no surrogate pairs | `[V]` |
| Windows-reserved characters (`< > : " / \ | ? *`, C0 controls) | none present | `[V]` |
| Reserved device name / trailing dot or space | no | `[V]` |

Because the two ideographs are normalisation-stable, they pass through Windows NTFS
(UTF-16), macOS HFS+/APFS (Unicode-normalising), and Linux byte-oriented filesystems
unchanged — no platform can recompose, decompose, or reorder them.

### Per operating system

| OS / filesystem | Name model | `-排版` verdict | Tag |
|---|---|---|---|
| Linux (ext4/ext2, WSL2 here) | Opaque bytes; only `/` and NUL forbidden | Safe: file created, listed, globbed, `find`-matched and read back under the exact name | `[V]` |
| Windows (NTFS/ReFS) | UTF-16 names; CJK fully supported; reserved chars/device names and trailing dot/space apply | Safe: no reserved char, no device name, no trailing dot/space; 7 added bytes well inside practical length | `[S]` |
| macOS (APFS/HFS+) | Unicode names; HFS+ stores a NFD variant | Safe: `排`/`版` have no decomposition, so the NFD variant is identical | `[S]` + `[V]` stability |

Real checks run here (`[V]`): creating `报告-排版.docx` and `报告-排版 (2).docx`;
`ls`, shell globbing, `find -name '*-排版*.docx'`, `[ -e ]`, and byte read-back all succeed;
the name is 6 UTF-8 bytes for the suffix; the reserved-character, device-name and
trailing-dot/space scans are all negative. The symlink/directory collision rule is also
verified (`[ -e ]` counts both).

### The three applications

| Application | Filename handling | Tag |
|---|---|---|
| Word 16 | Unicode filename via the OS open/save layer; the `.docx` package is unaffected by the filename's characters | `[S]` |
| WPS Writer 12 | Same, via the OS | `[S]` |
| LibreOffice 24.2 | Same, via the OS | `[S]` |

A filename is an operating-system concern of the open/save path, not part of the DOCX
package, so no application introduces its own reserved characters. One caveat: a legacy
Windows console or tool under a non-UTF-8 code page (e.g. `cmd.exe` code page 437) may
*display* CJK as mojibake, but the stored filename is correct. The exact per-version matrix
remains open (`#10`), so cross-app filename behaviour is tagged `[S]` rather than `[V]`.

## Reproducible operation

```
scripts/wf-output-name.sh <source> [--output <path>] [--json]
```

Pure path logic: it stats candidate names with `[ -e ]` and prints the resolved **absolute**
path on stdout (or JSON with `--json`). It writes nothing and reads no DOCX. It works with
the shell builtins plus `tr`; no OfficeCLI, `jq`, or other runtime dependency is required.

JSON shape (stable fields other work depends on):

```json
{
  "source": "/abs/report.docx",
  "mode": "default",
  "requested": null,
  "output": "/abs/report-排版.docx",
  "filename": "report-排版.docx",
  "directory": "/abs",
  "stem": "report",
  "suffix": "-排版",
  "extension": ".docx",
  "collision_index": 0,
  "numbered": false,
  "localised": false,
  "warnings": []
}
```

`mode` is `default`, `specified-directory`, or `specified-file`; `collision_index` is `0`
for the unnumbered base name and `n ≥ 2` for `… (n)`; `numbered` is `true` exactly when
`collision_index ≥ 2`.

Exit codes: `0` resolved; `2` bad usage; `3` an existing user-specified file (refusing to
overwrite); `4` no free collision number found.

## Limitations

- **No control-character escaping across all tooling.** Windows-illegal characters and
  control characters in a *source* name are warned about, not repaired; the rule never
  rewrites the user's own name. The `--output` path is the escape hatch.
- **The suffix's characters are the only ones WordFlow adds.** Portability of a source name
  that is already illegal on another OS is the user's choice, merely flagged.
- **`~` is not expanded** and `..` inside a directory argument is not canonicalised; the
  primitive resolves the containing directory but leaves such a path as written.
- **Source names containing a newline** are outside the rule (shell command substitution
  cannot represent them). This does not affect the suffix's safety.
- **Case-insensitive filesystems.** The collision probe uses the filesystem's own
  case sensitivity; on Windows/macOS a case-only variant counts as a collision because
  `[ -e ]` says so. No separate case-folding is done.

## Evidence

- `tests/output-naming.sh` — acceptance checks: first run, collision `(2)`, collision `(3)`,
  gap fill, user-specified file (honoured / refused on collision), user-specified directory,
  spaces + non-ASCII, extension handling, subdirectory, the `--json` contract, and the
  Windows-illegal warning.
- `scripts/wf-output-name.sh` — the implementation.
- This file's character checks were run in the working tree's WSL/Linux environment
  (ext4/ext2); the per-OS and per-application rows are documentation-backed (`[S]`) as
  tagged.
