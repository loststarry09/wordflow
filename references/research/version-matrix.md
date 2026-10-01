# Version matrix — Word, WPS Writer, LibreOffice Writer

Empirically detected compatibility-target versions for WordFlow v0.1, and the **committed**
support target they are measured against. This is a **facts** file, not product guidance. It
pins the "exact version matrix" open item in spec D10 / Further Notes (issue #10) and answers
*what was actually tested* separately from *what WordFlow promises*.

Legend:
- **[V]** — verified by running the tools locally (exact strings below).
- **[S]** — backed by vendor / project documentation (sources at the end).
- **[?]** — reported elsewhere or not confirmed here; treat as uncertain.

## Question

Spec D10 commits WordFlow to **Word 2016+, current WPS Writer, LibreOffice 7.6+**, but only
states that measurements were taken on "Word 16, WPS Writer 12, LibreOffice 24.2.7.2". The
open item is which *specific* releases were tested, what engine versions they correspond to,
and how far the committed floor exceeds the tested set. WPS is closed source, so its results
are labelled best-effort.

## Method

Detection only — no document is opened for layout. Each application reports its own version
through its own interface, and the raw string is recorded verbatim:

| Application | Detection command | Interface |
|---|---|---|
| OfficeCLI | `officecli --version` | CLI |
| Microsoft Word | `$app = New-Object -ComObject Word.Application; $app.Version; $app.Build` | COM automation |
| WPS Writer | `$app = New-Object -ComObject KWPS.Application; $app.Version; $app.Build` | COM automation |
| LibreOffice Writer | `soffice --version` | CLI |

Word and WPS share one Windows COM automation server, so every COM call is serialised with
`flock -w 1800 /tmp/wordflow-wincom.lock <command>`. The probe is
[`tests/probes/detect-versions.sh`](../../tests/probes/detect-versions.sh); it never opens or
writes a document and never invents a version (a missing application is reported
`unavailable`).

Environment: WSL2, Linux `6.18.33.2-microsoft-standard-WSL2 x86_64`, Ubuntu 24.04.4 LTS,
Windows `Microsoft Windows NT 10.0.26300.0`, PowerShell
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`.

## Detected matrix (tested on 2026-10-01)

| Application | `.Version` (engine) | `.Build` / build | Raw / detail |
|---|---|---|---|
| OfficeCLI | `1.0.153` | — | `officecli --version` → `1.0.153` |
| Microsoft Word | `16.0` | `16.0.19127` | `Word.Application` COM |
| WPS Writer | `12.0` | `12.1.0.28488` | `KWPS.Application` COM |
| LibreOffice Writer | `24.2.7.2` | `420(Build:2)` | `soffice --version` → `LibreOffice 24.2.7.2 420(Build:2)` |

**[V] Exact observed strings:**

```
officecli --version
  1.0.153

soffice --version
  LibreOffice 24.2.7.2 420(Build:2)

COM Word.Application
  .Version = "16.0"
  .Build   = "16.0.19127"

COM KWPS.Application
  .Version = "12.0"
  .Build   = "12.1.0.28488"
```

- **[V]** For both Word and WPS the COM `.Version` is the **engine/compatibility** version
  (`16.0`, `12.0`), while `.Build` carries the product build (`16.0.19127`, `12.1.0.28488`).
  A version claim must say *which* one it is quoting, or it is ambiguous.
- **[V]** OfficeCLI now reports `1.0.153` where earlier research recorded `1.0.152`
  (`references/research/officecli-behavior.md` and the other research notes). This is
  environment drift, not a matrix value; the Word/WPS/LibreOffice measurements remain valid.
- **[?]** The versions above are the *only* builds available on this machine. The probe cannot
  install or compare other builds; "tested" below always means exactly these builds.

## Committed target vs. what was actually tested

The committed target is the promise floor from spec D10. The tested set is a single build per
application, so the two must not be conflated.

| Target | Committed (spec D10) | Actually tested | Gap |
|---|---|---|---|
| Microsoft Word | **Word 2016+** (2016 / 2019 / 2021 / 2024 / 365) | Word **16.0** build `16.0.19127` only | One engine build; the 2016/2019/365 editions were **not** isolated |
| WPS Writer | **current WPS Writer** (WPS 12 line) | WPS **12.0**, build `12.1.0.28488` only | One build; every other WPS build is best-effort |
| LibreOffice Writer | **LibreOffice 7.6+** | LibreOffice **24.2.7.2** only | **7.6** not measured; **24.8+** not measured |

**[V] Word cannot be pinned to an edition.** `.Version` returns `16.0` for Word 2016, 2019,
2021, 2024 and Microsoft 365 alike; the perpetual editions differ by license/product release
id and build, not by this engine version. So the tested point is "the Word 16.0 engine", and
"Word 2016+" is a **committed floor**, not a measured set.

**[?] LibreOffice 7.6 is the largest untested gap.** The committed floor is `7.6+`, but every
LibreOffice measurement in this project (`references/research/*`) was taken on `24.2.7.2`.
Neither `7.6` nor `24.8+` has been exercised. Until one of them is, the honest statement is
"committed 7.6+, verified 24.2.7.2".

## Rationale for the committed target

- **[S] Word 2016+.** Office 2016 and Office 2019 (and later releases and Microsoft 365) share
  the same `16.0.xxxxx.xxxxx` version line; Microsoft's own compatibility documentation covers
  Word 2016–365 together. The constructs WordFlow relies on (character/paragraph styles,
  sections, headers/footers, tables, OMML equations, fields, `compatibilityMode=15`) all date
  from Word 2007–2013, so every "2016+" edition handles them. Word 2016 is therefore a
  conservative floor that any Word the user is likely to run meets.
- **[S] current WPS Writer.** WPS is closed source with no published format-compatibility
  contract, so a per-build guarantee cannot be documented. Its version line reports `12.0`
  (engine) with `12.1.0.x` builds. The target is deliberately "the current WPS Writer line"
  rather than a build number, and every WPS conclusion is labelled best-effort/unverified.
- **[S] LibreOffice 7.6+.** LibreOffice 7.6 (released 2023-08-21) was the last release under
  the old numbering, and 24.2 (2024-01-31) the first calendar-versioned release; both are
  included by "7.6+". 24.2 is the Ubuntu 24.04 LTS package and is the measured build here.
  The floor is set at 7.6 to cover older LTS desktops while the verified point is 24.2.7.2.

**Recommendation (not a spec change — the spec is out of scope for this ticket).** Either
keep `7.6+` as an aspirational floor and state plainly that only 24.2.7.2 is verified, or
tighten the committed floor to the verified `24.2.7.2` and treat 7.6 as best-effort. The
current wording ("Target versions: … LibreOffice 7.6+") reads as a guarantee that the
evidence does not yet cover for 7.6.

## Version schemes (why the numbers look the way they do)

- **[S]** Word: engine `16.0` spans Office 2016 → 365; build `16.0.<revision>` identifies the
  update channel. `Word 2016` and `Word 2019` are known to report identical builds when fully
  patched. ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5063621/microsoft-office-2016-and-2019-build-version);
  [Compatibility changes between versions](https://support.microsoft.com/en-us/word/compatibility-changes-between-versions).)
- **[S]** WPS: product builds are shown as `12.1.0.<nnnnn>`; the COM engine version is `12.0`.
  ([WPS help, "Check WPS Office version"](https://help.wps.com/articles/check-update-office-version-windows).)
- **[S]** LibreOffice: `soffice --version` prints `LibreOffice <major.minor.patch.build>
  <buildid>(Build:<n>)`, e.g. `24.2.7.2 420(Build:2)`. Versions before 2024 use
  `<cycle>.<major>` (7.6); from 2024 they use calendar `<year>.<month>` (24.2, 24.8).
  ([LibreOffice 7.6 announcement](https://blog.documentfoundation.org/blog/2023/08/21/libreoffice-7-6-community);
  [LibreOffice release/EOL data](https://endoflife.date/libreoffice).)

## Coverage gaps and residual uncertainty

- **[?]** Word 2016 and Word 2019 as *distinct editions* were not measured (only engine
  `16.0`); a feature introduced after a given perpetual release could still differ, though
  none of WordFlow's constructs is in that category.
- **[?]** LibreOffice 7.6 was not available on this machine; 24.8+ was not measured either.
- **[?]** WPS is closed source; `12.1.0.28488` is one build of the WPS 12 line, and results
  may not transfer to another build. Treat all WPS conclusions as best-effort.
- **[?]** OfficeCLI `1.0.153` vs the `1.0.152` recorded in existing research notes — a probe
  run on a different day would report whichever build is installed. Pin the OfficeCLI version
  in the change report when citing measurements.

## Implication for the compatibility harness

`scripts/wf-compat-harness.sh` already records `application_version` per (document,
application) record (Word/WPS from COM `.Version`, LibreOffice from the normalised
`soffice --version` string). [`tests/probes/detect-versions.sh`](../../tests/probes/detect-versions.sh)
is the standalone detector for the committed matrix: run it before a measurement wave to
capture the exact environment in the same vocabulary. Neither tool upgrades an unmeasured
case to a pass.

## Reproduce

```sh
# human-readable matrix (COM calls serialised with flock)
tests/probes/detect-versions.sh

# machine-readable report (schema wordflow.version-probe/v1)
tests/probes/detect-versions.sh --json

# the raw COM call the probe makes, under the shared lock:
flock -w 1800 /tmp/wordflow-wincom.lock \
  /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
  -NoProfile -ExecutionPolicy Bypass -File '<windows-temp>\versions.ps1'
```

## Sources

- Microsoft, *Compatibility changes between versions* — Word 2016 / 2019 / 2021 / 2024 / 365:
  <https://support.microsoft.com/en-us/word/compatibility-changes-between-versions>
- Microsoft Q&A, *Office 2016 and 2019 Build Version* (`16.0.XXX.XXX` shared):
  <https://learn.microsoft.com/en-us/answers/questions/5063621/microsoft-office-2016-and-2019-build-version>
- The Document Foundation, *LibreOffice 7.6 Community* (2023-08-21):
  <https://blog.documentfoundation.org/blog/2023/08/21/libreoffice-7-6-community>
- endoflife.date, *LibreOffice* (release + EOL dates for 7.6, 24.2, 24.8):
  <https://endoflife.date/libreoffice>
- WPS, *Check WPS Office version and update it* (`12.1.0.25242` example):
  <https://help.wps.com/articles/check-update-office-version-windows>
