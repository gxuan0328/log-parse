# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `analyze_iis`: per-server **client-IP roster** section listing every
  distinct `c-ip` with its request count and percentage share of total
  traffic, sorted by request count descending. Aids security triage
  (health-checker dominance, scanner bursts, unexpected client identities).
- `IIS_AWK` emits a new `CLIENT_IP\t<ip>\t<count>` record type.
- `tests/run_tests.sh`: five new baselines (B15–B19) covering header,
  percentage column, primary-client presence, row-count expectation, and
  per-region rendering. Total test count: 103 → 108.

### Changed
- `client_ips[]` in `IIS_AWK` is now a counter (`++`) rather than a set
  marker (`= 1`); `UNIQUE_IPS` continues to derive from `length()`, so
  the documented top-line counter is unchanged.
- `docs/design.md`, `docs/design.zh-TW.md`, `docs/usage.md`,
  `docs/usage.zh-TW.md` updated to document the new section, its
  rationale, and its empty-input semantics.
- `examples/sample-outputs/iis_*.txt` and dependent `log_report_*.txt`
  regenerated from the bundled dataset.

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
