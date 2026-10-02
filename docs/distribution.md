# Distribution and discovery per agent

How WordFlow is installed and discovered by **opencode**, **Claude Code**, and
**Codex**. This resolves the open implementation decision in the spec
(`docs/spec/v0.1.md` §Further Notes: *"Distribution: install location and
discovery per agent"*, issue [#14]).

Status: current as of 2026-10-01. Verified against opencode 1.18.34, Codex
0.159.2, and the shared `skills` CLI 1.7.0.

## Evidence tags

- **`[V]`** — verified on this machine by running the named command and observing
  the named result (evidence log below).
- **`[S]`** — backed by the agent's official documentation, or by the shared
  `skills` CLI's published agent→directory mapping; not re-run here.
- **`[?]`** — uncertain, or not verifiable in this environment; the exact check
  to run is stated.

## The skill unit

Every supported agent discovers a skill as **`<skills-dir>/<name>/SKILL.md`**:
one directory per skill, named after the skill, holding a `SKILL.md` whose YAML
frontmatter carries `name` (which must match the directory name) and a
`description` the agent matches against the task. `SKILL.md` is WordFlow's entry
point (spec §D1); **no other manifest is required** for a bare skill — the
frontmatter is the manifest. Additional support files (`references/`, `scripts/`)
sit beside it and are read on demand, resolved relative to the skill directory.

The repo-root [`SKILL.md`](../SKILL.md) is the single authoring source. Its
frontmatter is deliberately exactly `name` + `description`: Codex rejects
unexpected frontmatter keys, and opencode recognises only `name`, `description`,
`license`, `compatibility`, and `metadata` `[S]`, so the minimal pair is the one
that is safe everywhere.

## Discovery matrix

| Agent | Project skills dirs (walk up to the worktree root) | Global skills dirs | Instruction file | Tag |
|---|---|---|---|---|
| **opencode** | `.opencode/skills/`, `.claude/skills/`, `.agents/skills/` | `~/.config/opencode/skills/`, `~/.claude/skills/`, `~/.agents/skills/` | `AGENTS.md` | project `[V]`; global `[S]` |
| **Claude Code** | `.claude/skills/` | `~/.claude/skills/` | `CLAUDE.md` (always-on) | `[S]` |
| **Codex** | `.codex/skills/`, `.agents/skills/` | `$CODEX_HOME/skills/` (default `~/.codex/skills/`), `~/.agents/skills/` | `AGENTS.md` | `[V]` |

`.agents/skills/` is the cross-agent "universal" directory: read by **both**
opencode and Codex, project-local and global, and used by the shared
[`skills` CLI](https://github.com/vercel-labs/skills) as its primary store `[S]`.
Claude Code does not read `.agents/skills/`; it needs `.claude/skills/` `[S]`.

## What this repo ships

Committed packaging, so a fresh agent session opened on the repo discovers the
skill with no install step:

| Path | Kind | Serves |
|---|---|---|
| `SKILL.md` | canonical file | WordFlow entry point (spec §D1) |
| `.agents/skills/wordflow/SKILL.md` | real copy of root `SKILL.md` | opencode + Codex project-local discovery |
| `.agents/skills/wordflow/references` | symlink → `../../../references` | keeps `references/` resolvable from the entry |
| `.claude/skills/wordflow/SKILL.md` | real copy of root `SKILL.md` | Claude Code (and opencode) project-local discovery |
| `.claude/skills/wordflow/references` | symlink → `../../../references` | keeps `references/` resolvable from the entry |
| `CLAUDE.md` | symlink → `AGENTS.md` | Claude Code's always-on project instructions |

This documentation lives under `docs/` rather than `references/` because
`references/` is scoped to layout knowledge with a frozen index
(`references/README.md`); this is repo/engineering documentation.

### Why real copies, not symlinks `[V]`

The entry `SKILL.md` is a **regular file** because the loaders differ:

- **Codex requires a regular file.** A skill whose `SKILL.md` was a symlink to
  the repo root was **not** discovered (`codex debug prompt-input` listed neither
  the skill nor a project skill root for it). Codex's directory scan does not
  follow a symlinked `SKILL.md`.
- **A whole-repo symlink makes opencode hang.** Pointing `.agents/skills/wordflow`
  at the repo root (`../..`) is discovered by Codex but causes `opencode debug
  skill` to recurse (the skill directory contains `.agents/skills/wordflow`
  again) and never return. It is therefore not used for project discovery.
- opencode accepts either form, so a real copy is the one representation that
  satisfies all three agents.

The duplication is contained: `tests/skill-discovery.sh` asserts every entry
copy is byte-identical to the root `SKILL.md`, so the copies cannot drift.
opencode loads both `.agents/skills/` and `.claude/skills/` and deduplicates the
same-named skill, reporting whichever entry it scans first; it does not error,
and discovery holds either way `[V]`.

## Installing outside this repo

**Project-local is zero-install.** Opening a fresh agent session in a clone of
this repo is enough — the committed entry directories above are found.

**Global install** makes the skill available from any directory. Clone the repo
first so the `references` symlinks stay intact, then link each agent's entry
directory (link the *skill directory*, never the repo root — see above):

```sh
git clone https://github.com/loststarry09/wordflow ~/.local/share/wordflow

# opencode + Codex (shared universal directory)
mkdir -p ~/.agents/skills
ln -sfn ~/.local/share/wordflow/.agents/skills/wordflow ~/.agents/skills/wordflow

# Claude Code
mkdir -p ~/.claude/skills
ln -sfn ~/.local/share/wordflow/.claude/skills/wordflow ~/.claude/skills/wordflow

# Codex personal directory, if you prefer ~/.codex/skills over the shared dir
mkdir -p ~/.codex/skills
ln -sfn ~/.local/share/wordflow/.agents/skills/wordflow ~/.codex/skills/wordflow
```

Alternatively the shared `skills` CLI installs for all agents at once
(`npx skills add <repo> --all --copy`, where `--copy` writes real files)
`[S]`. Global install has **not** been exercised end-to-end here `[?]`.

## Verification

Run:

```sh
tests/skill-discovery.sh
```

It checks the committed packaging (frontmatter, regular-file entries, byte
identity to root, `references/` resolution, `CLAUDE.md`) and, where the agent CLI
is installed, drives that CLI's own discovery surface: `opencode debug skill`
and `codex debug prompt-input`. On this machine both report the skill.

Claude Code has no CLI installed here, so its check is manual: run `claude` in
the repo, then `/skills` (or ask it to list skills) and confirm `wordflow` is
offered.

## Evidence log (2026-10-01)

- `[V]` `opencode debug skill` in the repo lists `"name": "wordflow"`, located
  at either committed entry (`.agents/skills/wordflow/SKILL.md` or
  `.claude/skills/wordflow/SKILL.md`); opencode dedupes the same-named copies
  and reports whichever it scans first.
- `[V]` `codex debug prompt-input` in the repo lists
  `wordflow: … (file: r7/wordflow/SKILL.md)` with skill root
  `r7 = <repo>/.agents/skills`.
- `[V]` Codex project skill roots are `.codex/skills` and `.agents/skills` only;
  a probe in `.opencode/skills` and `.claude/skills` was **not** listed by Codex.
- `[V]` opencode project skill roots are `.opencode/skills`, `.claude/skills`,
  and `.agents/skills`; all three were listed from a probe.
- `[V]` A symlinked `SKILL.md` was not discovered by Codex; a directory symlink
  to the repo root made opencode hang.
- `[V]` opencode loads `AGENTS.md`; Codex injects `AGENTS.md` instructions.
- `[S]` opencode's documented discovery locations (opencode docs, *Agent
  Skills*); Claude Code project `.claude/skills/` and personal `~/.claude/skills/`
  (Claude platform docs, *Agent Skills*); the `skills` CLI's agent→directory map
  (opencode/Codex → `.agents/skills`, Claude → `.claude/skills`).

## Unverified (not blockers)

- `[?]` Claude Code discovery and symlink-following are unverified locally (no
  CLI); the manual check above is the confirmation step.
- `[?]` Whether Claude Code also reads `AGENTS.md` directly; we ship `CLAUDE.md`
  (a symlink to `AGENTS.md`) to cover the documented instruction mechanism.
- `[?]` Global install commands are documented from the mechanisms, not yet run.
