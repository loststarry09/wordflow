# Risk policy — warn / downgrade / stop

Spec `docs/spec/v0.1.md` §D11 names seven moments where WordFlow must react to
risk. **This policy is defined once and every feature calls it.** No feature
implements its own warn / downgrade / stop logic, and no feature formats its own
warning: a decision becomes a change-report entry through the shared contract
(#28, [`change-report.md`](./change-report.md)).

The vocabulary is `CONTEXT.md` "Behaviour under risk": **warn** (ship and report
a known risk), **downgrade** (ship a portable fallback, never silent),
**refuse** (stop without output and ask).

The policy is **data + a pure decision function**: the trigger table is data and
the decision rule is a `jq` expression over it, so it is testable with no DOCX
and no OfficeCLI. Canonical tool:
[`../../scripts/wf-risk-policy.sh`](../../scripts/wf-risk-policy.sh). Acceptance
tests: [`../../tests/risk-policy.sh`](../../tests/risk-policy.sh).

## The trigger table (normative)

| # | Trigger (`id`) | Decision | Report area |
|---|---|---|---|
| 1 | `floating-image`, `nested-table`, `columns`, `first-odd-even-headers`, `page-number-restart`, `complex-equation` — a construction may render differently in one application | **warn** | `warnings` |
| 2 | `preferred-unavailable` — a preferred construction is unavailable, unsafe, or known-unfaithful **and a portable fallback exists** | **downgrade** | `downgrades` |
| 3 | `content-change` — the user would need their content changed | **stop** | — |
| 4 | `restructure-unconfirmed` — a restructure without per-item confirmation | **stop** | — |
| 5 | `source-unreadable` — the source cannot be read or fails validation | **stop** | — |
| 6 | `portability-no-alternative` — a requested construction sacrifices portability and no safe alternative exists | **stop** | — |
| 7 | `unverifiable-field` — a field cache would be a placeholder or a page number cannot be guaranteed | **never ship silently**: omit (**downgrade**, `unverified`), or ship-but-state (**warn**, `unverified`), or **stop** | `unverified` |

Rows 1, 3, 4, 5, 6 are unconditional. Rows 2 and 7 depend on one fact supplied
by the caller:

Stable entry codes (one per trigger, used as the `[CODE]` prefix of an entry):

`D11-floating-image` · `D11-nested-table` · `D11-columns` ·
`D11-first-odd-even-headers` · `D11-page-number-restart` · `D11-complex-equation` ·
`D11-preferred-unavailable` · `D11-content-change` · `D11-restructure-unconfirmed` ·
`D11-source-unreadable` · `D11-portability-no-alternative` · `D11-unverifiable-field`

- `preferred-unavailable`: `fallback=exists` → **downgrade**; `fallback=none`
  → **stop** (this is row 6's situation, decided by the policy, not the caller).
- `unverifiable-field`: `resolution=omit` → **downgrade** (intentional omission);
  `resolution=state` → **warn** (shipped but explicitly unverified);
  `resolution=none` (or omitted) → **stop**. The forbidden outcome — shipping a
  placeholder silently — is not representable.

## CLI

```
wf-risk-policy.sh list   [--json]
wf-risk-policy.sh decide --trigger <id> [--fact k=v ...] [--detail <text>] [--json]
wf-risk-policy.sh classify ...        # alias for decide
wf-risk-policy.sh emit   --report <r> --trigger <id> [--fact k=v ...] [--detail <text>]
```

- **`list`** — print the trigger table; `--json` gives the machine-readable data.
- **`decide` / `classify`** — return the decision without touching anything.
  `--json` prints `{trigger, code, family, decision, area, rationale, entry, ask}`.
  Exit `0` for `warn`/`downgrade`; exit `3` for `stop` (the result still carries
  the `ask`).
- **`emit`** — decide and act. A `warn`/`downgrade` appends one `[CODE] text`
  entry to the report via `wf-change-report.sh add --area <warnings|downgrades|unverified>`.
  A `stop` **writes nothing**, prints nothing on stdout, prints the ask on
  stderr, and exits `3`.

Facts are passed as `--fact key=value` (repeatable) or the sugar flags
`--fallback exists|none` and `--resolution omit|state|none`. `--detail` supplies
caller-specific specifics (e.g. the construction name) woven into the entry or
ask. Requiring the caller to name the situation — rather than to pick the
decision — keeps the decision rule in one place.

Exit codes: `0` proceed (warn/downgrade) or `list` ok · `3` stop/ask ·
`1` report error · `2` usage / unknown trigger.

## How a feature calls it

Every feature decides **before** it writes, then reports through the same tool:

```sh
scripts/wf-risk-policy.sh decide --trigger floating-image --json
# -> {"decision":"warn","area":"warnings","entry":"[D11-floating-image] ..."}

scripts/wf-risk-policy.sh emit --report "$report" \
  --trigger preferred-unavailable --fallback exists --detail "anchored image"
# -> appends '[D11-preferred-unavailable] anchored image — ...' to .downgrades

scripts/wf-risk-policy.sh emit --report "$report" --trigger content-change
# -> writes nothing, asks the user on stderr, exits 3
```

A caller that gets exit `3` must **not** produce an output document; it puts the
`ask` to the user. A caller that gets exit `0` treats the entry as already
recorded in the report — it must not add its own warning or downgrade text.

## Invariants

- **No silent downgrade.** Every `downgrade` decision is emitted into the
  change report; a downgrade that reaches no report is a bug (#31 checks this).
- **No silent placeholder.** Row 7 has no silent path: omit, state, or stop.
- **Stop means no output.** A `stop` decision produces no document and no report
  entry; it only asks the user.
- **Defined once.** The trigger ids and decision rule live only here and in
  `wf-risk-policy.sh`; feature tickets (#19–#27, #15, #35) call the policy and
  add no warn/downgrade/stop logic of their own.
