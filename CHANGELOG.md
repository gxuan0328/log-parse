# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Prompt structure refactor for LLM attention efficiency**:
  - `.claude/CLAUDE.md` slimmed from 367 → 113 lines (≤ 200-line target
    per official Claude Code memory guidance).
  - `.claude/skills/feature-workflow/SKILL.md` slimmed from 317 → 156
    lines (narrative re-written as actionable checklists).
  - Detailed conventions split into five **path-scoped rule files** under
    `.claude/rules/` (frontmatter `paths:` glob, loaded on demand):
    `bash.md` (91), `awk.md` (72), `library.md` (42), `testing.md` (63),
    `documentation.md` (88).
  - Effect on per-session context load:
    - Pure conversation: 684 → 113 lines (-83%)
    - Edit `docs/usage.md`: 684 → 201 lines (-71%)
    - Edit `bin/analyze_iis.sh`: 684 → 276 lines (-60%)
    - Worst case (edit `lib/csv_utils.sh`): 684 → 318 lines (-54%)
  - No information lost — every prior convention now lives in exactly
    one place; cross-references replaced narrative duplication.
- **Project conventions consolidated under `.claude/`**: the file formerly
  at `./CLAUDE.md` is now the single authoritative document at
  `.claude/CLAUDE.md`. Per the official Claude Code documentation
  (`https://code.claude.com/docs/en/memory` — "Choose where to put
  CLAUDE.md files"), `./CLAUDE.md` and `./.claude/CLAUDE.md` are
  equivalent project-scope locations and both auto-load at session start.
  The root stub was removed to enforce a single source of truth; all
  cross-document references (`README.md`, `README.zh-TW.md`,
  `docs/design.md`, `docs/design.zh-TW.md`, `.claude/skills/feature-workflow/SKILL.md`)
  now point to `.claude/CLAUDE.md`.

### Added
- **Project-scoped workflow skill** at
  `.claude/skills/feature-workflow/SKILL.md` defining the standardised
  feature-development & modification process (7 phases: pre-dev impact
  analysis → implementation → validation gate → docs sync → cross-validation
  → commit/release → terminal summary). Auto-triggered by `CLAUDE.md §13`
  for every code-touching request in this repository.
- `CLAUDE.md §13` declares the auto-trigger contract, lists qualifying
  request kinds, and enumerates the seven enforced phases.
- `analyze_iis`: per-server **client-IP roster** section listing every
  distinct `c-ip` with its request count and percentage share of total
  traffic, sorted by request count descending. Aids security triage
  (health-checker dominance, scanner bursts, unexpected client identities).
- `IIS_AWK` emits a new `CLIENT_IP\t<ip>\t<count>` record type.
- `tests/run_tests.sh`: five new baselines (B15–B19) covering header,
  percentage column, primary-client presence, row-count expectation, and
  per-region rendering. Total test count: 103 → 108.
- `analyze_iis`: the top-endpoint table gains an **`Avg(s)`** column —
  each (DICOM-grouped) endpoint's mean response time in seconds, rounded
  to two decimals (`time-taken` is logged in ms). Surfaces slow logical
  endpoints (e.g. DICOM image retrieval at ~1.0s) against sub-second
  static assets and `/health`.
- `IIS_AWK` accumulates `ep_time_ms[]` per endpoint and emits the mean as
  a 4th field on each `ENDPOINT` record (`ENDPOINT\t<uri>\t<count>\t<avg_sec>`).
- `tests/run_tests.sh`: three new baselines (B20–B22) covering the column
  header, a slow DICOM-endpoint mean (1.03s), and a sub-second boundary
  (`/health` = 0.06s). Total test count: 108 → 111.

### Changed
- `client_ips[]` in `IIS_AWK` is now a counter (`++`) rather than a set
  marker (`= 1`); `UNIQUE_IPS` continues to derive from `length()`, so
  the documented top-line counter is unchanged.
- `docs/design.md`, `docs/design.zh-TW.md`, `docs/usage.md`,
  `docs/usage.zh-TW.md` updated to document the new section, its
  rationale, and its empty-input semantics.
- `examples/sample-outputs/iis_*.txt` and dependent `log_report_*.txt`
  regenerated from the bundled dataset.
- `docs/design.md`, `docs/design.zh-TW.md`, `docs/usage.md`,
  `docs/usage.zh-TW.md`, and `examples/sample-outputs/README*.md` updated
  to document the endpoint `Avg(s)` column; `iis_taipei_2026-05-21.txt`,
  `iis_taichung_2026-05-21.txt`, `iis_all_slow3000_2026-05-21.txt`, and
  `log_report_full_2026-05-21.txt` regenerated with `NO_COLOR=1`.

## [1.0.0] — 2026-05-25

### Added
- `bin/analyze_access.sh` — Cross-region API/APP token correlation engine.
  Categorises access events as NORMAL / ORPHAN / UNVERIFIED and reports
  time-delta statistics between token issuance and verification.
- `bin/analyze_iis.sh` — IIS W3C log analyser: per-server request counts,
  status-code distribution, slow-request detection, health-check 503 counts,
  endpoint-level breakdown with DICOM path grouping.
- `bin/analyze_errors.sh` — Application error & lifecycle analyser:
  OracleDB-health failure detection, top-N error pattern extraction with
  message normalisation, and SHUTDOWN/STARTED pairing for restart downtime.
- `bin/log_report.sh` — Orchestrator: runs all modules in a single invocation,
  supports combined stdout, single combined file, or per-module output dir.
- `lib/common.sh` — Logging (DEBUG/INFO/WARN/ERROR), `init_tmpdir` with
  auto-cleanup, `require_cmds` dependency gate, terminal-aware colour codes.
- `lib/date_utils.sh` — `build_date_list` supporting `--date`, `--from/--to`,
  and `--days`; filename mapping helpers (`date_to_iis_file`).
- `lib/csv_utils.sh` — Schema-aware access-CSV extractors, IIS field guard,
  pipe-delimited app-log helpers.
- `lib/fmt_utils.sh` — Section headers, key-value rows, table primitives,
  ANSI colour helpers honouring `NO_COLOR`.
- `conf/regions.conf` — Region ↔ server mapping (Taipei / Taichung).
- `tests/run_tests.sh` — 103-test functional suite covering all CLIs,
  regions, parameter combinations, validation paths, and six user scenarios.
- `docs/design.md` — Architecture and data-flow specification.
- `docs/usage.md` — Full CLI reference with worked examples.
- `CLAUDE.md` — Coding conventions and design principles.
- `Makefile` — Convenience targets: `test`, `lint`, `report`, `clean`.

### Security
- All scripts use `set -euo pipefail`; failures surface immediately.
- No silent error suppression in correlation paths.
- Regions config validated before use; missing config aborts with explicit error.

[Unreleased]: https://example.com/log-parse/compare/v1.0.0...HEAD
[1.0.0]: https://example.com/log-parse/releases/tag/v1.0.0
