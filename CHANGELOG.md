# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `--format csv` output mode for `analyze_access` (extends existing `text|tsv`
  enum); `--format` promoted to shared global vocabulary accepted (as a no-op
  with a `log_warn` notice) by `analyze_iis` and `analyze_errors`, and
  forwarded by `log_report` to all child modules.
- `--merge` flag for `analyze_access` and `analyze_iis`: concatenates all
  per-server corpora into a single cross-region analysis pass. Requires
  `--region all` (explicit or default); any other `--region` value causes an
  immediate `die`.
- `--top N` flag for `analyze_iis` (replaces hard-coded caps): controls the
  maximum rows shown in both the Endpoint table and the Client-IP table;
  `0` means emit all rows. Default: `10`.
- `--top 0` (emit-all) support for `analyze_errors`: previously a value of `0`
  caused the pattern table to emit zero rows; `ERROR_AWK` now honors
  `top_n == 0` as "no limit" (Decision B parity with `analyze_iis`).
- `--slow-api-ms N` flag for `analyze_iis`: slow-request threshold in
  milliseconds applied to API-role servers (`REGION_APIS`). Default: `2000`.
- `--slow-app-ms N` flag for `analyze_iis`: slow-request threshold in
  milliseconds applied to APP-role servers (`REGION_APPS`). Default: `5000`.
- `% of total` column in the iis **Status** table (`["Status","Count","% of
  total"]`); denominator is `TOTAL` requests for that server. Status table now
  sorted in-gawk (composite key: count desc, status-code desc as tie-break) —
  no external `sort` pipe.
- `% of total` column in the iis **Endpoint** table (`["Endpoint","Avg(s)",
  "Count","% of total"]`); denominator is `TOTAL` requests.
- Per-category section headers and full `PATIENT_ID_AES` value in
  `analyze_access` text output.
- `assert_uint` and `assert_enum` validators in `lib/common.sh`; used in the
  `parse_args` post-loop of every CLI for fail-fast input validation.
- Full forwarding of `--format`, `--top`, `--slow-api-ms`, `--slow-app-ms`,
  and `--merge` from `log_report` to the child modules that accept them
  (per the flag-forwarding matrix in `§0`).
- `tests/run_tests.sh`: 33 new baselines (A28-A34, B23-B31, C18-C21,
  D22-D26, E13-E18, F12-F13) plus migration of 10 obsolete baselines to the
  refactored output; column-order assertions hardened against tautology via
  a new `_hasre` regex helper. Total: 110 -> 143 distinct tests.

### Changed
- `analyze_access` detail columns: `API_REQUEST_ID` and `APP_REQUEST_ID`
  merged into a single `REQUEST_ID` field; columns reordered; `PATIENT_ID_AES`
  now emits the full value (previously truncated). Text, tsv, and csv outputs
  share a single deterministic ascending sort pre-pass so all three formats
  are byte-stable.
- `analyze_iis` **Client-IP** table column order changed from
  `Count | IP | %` to `IP | Count | %` (IP-first). The `% of total` column
  itself was already present (added in commits 52f0a97 / b5b8828); this entry
  records the reorder only.
- `analyze_iis` Endpoint table default row cap changed from `15` (hard-coded)
  to `10` (via `--top`). Client-IP table changed from uncapped to `--top`
  (default `10`).
- `analyze_iis` slow-request log line now labels the threshold per server role
  (API vs APP) rather than a single shared label.
- `log_report` argument-forwarding logic refactored: shared flags are collected
  into a `_MOD_ARGS` array (module-aware) and forwarded only to modules that
  accept each flag, per the forwarding matrix.
- `docs/usage.md`, `docs/usage.zh-TW.md`, `docs/design.md`,
  `docs/design.zh-TW.md` updated to document all new and changed flags,
  table columns, and forwarding semantics.
- `examples/sample-outputs/` regenerated with `NO_COLOR=1` from the fixed
  dataset (`2026-05-18..2026-05-25`); `examples/*.sh` helper scripts updated
  to use the new flag names.

### Removed
- `--slow-ms` flag from `analyze_iis`: replaced by `--slow-api-ms` and
  `--slow-app-ms` with role-aware defaults. No backward-compat alias provided
  (clean-break Decision A).
- `API_REQUEST_ID` and `APP_REQUEST_ID` columns from `analyze_access` output:
  merged into the single `REQUEST_ID` field in all output formats (text, tsv,
  csv).

### Fixed
- `analyze_errors` `--top 0`: previously evaluated `limit = (n<top_n)?n:top_n`
  which resolved to `0` when `top_n=0`, emitting no patterns. `ERROR_AWK` now
  uses `limit = (top_n==0)?n:(n<top_n?n:top_n)` so `--top 0` correctly emits
  all patterns.
- `tests/run_tests.sh`: removed a stray `PASS=$(( PASS + 1 ))` after the `B10`
  `_pass` call (double-count) that had inflated the reported total by one;
  the reported count now equals the distinct test-ID count.

### Changed (meta / project conventions)
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
- **Project-scoped workflow skill** at
  `.claude/skills/feature-workflow/SKILL.md` defining the standardised
  feature-development & modification process (7 phases: pre-dev impact
  analysis → implementation → validation gate → docs sync → cross-validation
  → commit/release → terminal summary). Auto-triggered by `.claude/CLAUDE.md §7`
  for every code-touching request in this repository.
- `analyze_iis`: per-server **client-IP roster** section listing every
  distinct `c-ip` with its request count and percentage share of total
  traffic, sorted by request count descending.
- `IIS_AWK` emits a `CLIENT_IP\t<ip>\t<count>` record type; `client_ips[]`
  is now a counter (`++`) rather than a set marker (`= 1`); `UNIQUE_IPS`
  continues to derive from `length()`.
- `analyze_iis`: the top-endpoint table gains an **`Avg(s)`** column —
  each (DICOM-grouped) endpoint's mean response time in seconds, rounded to
  two decimals (`time-taken` is logged in ms).
- `IIS_AWK` accumulates `ep_time_ms[]` per endpoint and emits the mean as a
  4th field on each `ENDPOINT` record (`ENDPOINT\t<uri>\t<count>\t<avg_sec>`).

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
