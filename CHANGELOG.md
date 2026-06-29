# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `bin/analyze_overview.sh` — New management overview module. Sources metric
  data from `analyze_iis` and `analyze_access` via `--emit-stats` (zero
  log-re-parse; DRY via `lib/aggregate_utils.sh`). Renders three-cut layout:
  總體概況 (grand totals + health verdict), 分區別 (per-region request share +
  NORMAL%), 服務別 (per-role volume + role-specific signals: UNVERIFIED for API
  servers, ORPHAN/503/slow for APP servers). Summary-only, text-only.
  Accepts `--log-dir`, `--region`, all interval flags, `--slow-api-ms`,
  `--slow-app-ms`, `--output-dir`, `--conf`, `-v`. Persists a single
  `overview_summary_<TS>.txt`; no detail file.
- `lib/output_utils.sh` — Always-on report persistence. `persist_init` resolves
  and creates the output directory (precedence: `--output-dir` flag >
  `$LOG_PARSE_OUTPUT_DIR` env > `./log-parse/` default); `RUN_TS` is fixed once
  per launch (or inherited via `$LOG_PARSE_RUN_TS` from `log_report`).
  `persist_views` writes color-free summary + detail files and mirrors the
  selected view to stdout. File naming: `<module>_<kind>_<YYYYMMDD_HHMMSS>.<ext>`.
- `lib/aggregate_utils.sh` — Shared metric computation and CSV quoter.
  `AGG_IIS_AWK` relocated verbatim from `bin/analyze_iis.sh:129`; `AGG_CSV_FUNC`
  (shared gawk `q()` RFC-4180 quoter) relocated from `bin/analyze_access.sh:325`;
  `agg_iis_rows` and `agg_access_rows` consolidate the three separate counting
  passes in access; canonical `IIS_STAT_SCHEMA`/`ACCESS_STAT_SCHEMA` field-index
  constants shared by analyzers and overview.
- `--view summary|detail` on `analyze_iis` and `analyze_access`. Standalone
  default: `detail` (preserves prior behavior). `log_report` default: `summary`.
  Summary view is always text regardless of `--format` (format governs the detail
  file/view only). `analyze_errors` and `analyze_overview` do not accept `--view`.
- `--today` flag on all 5 CLIs: equivalent to `--date $(today)`. Sets
  `OPT_TODAY=1`; routed through `resolve_interval`.
- `--emit-stats` on `analyze_iis` and `analyze_access`: writes machine-readable
  dimensioned stat rows to stdout, bypasses persistence and human rendering.
  Used by `analyze_overview` for DRY data sourcing. Not accepted by
  `analyze_errors`, `analyze_overview`, or `log_report`.
- `resolve_interval` in `lib/date_utils.sh`: enforces interval-flag mutual
  exclusion. `{--today, --date, --from/--to, explicit --days}` — at most ONE
  explicit selector; `>1` ⇒ `die` citing the priority ranking
  `--date > --from/--to > --today > --days`. Populates sanctioned global
  `INTERVAL_ARGS[]`. All 5 CLIs gain `OPT_TODAY=0` and `OPT_DAYS_SET=0` and
  route through `resolve_interval` before `build_date_list`.
- `fmt_set_color_state` in `lib/common.sh` + `lib/fmt_utils.sh`: re-entrant
  color-state toggle. Called once at startup (same behavior as before); called
  again by `persist_views` to blank all `C_*` globals for color-free file writes
  and restore them for the console mirror. Covers `fmt_h1/h2/h3`, `fmt_kv`,
  `fmt_ok/warn/err`, `_log`, and the `-v C_*` gawk passes in renderers.
- 67 new test IDs (+2 assertions added under rewritten existing IDs) → 215
  total: H01–H15 (analyze_overview), I01–I12 (persistence), A37–A41
  (access summary/--today), B32–B38 (iis summary/format/emit-stats), C23–C25
  (errors interval + summary file), D27–D35 (log_report defaults/modules/view),
  E19–E26 (interval mutex), F14–F18 (scenario simulations), G+3 (CJK alignment
  in summary/overview tables). 18 existing `--output` references rewritten in
  place; affected Section-D default-modules tests rewritten in place. 0 IDs
  removed; base stays 146. Tests: 215/215.
- `--format csv` output mode for `analyze_access` (extends existing `text|tsv`
  enum); `--format` promoted to shared global vocabulary accepted (as a no-op
  with a `log_warn` notice) by `analyze_errors`; accepted with real tsv/csv
  detail output by `analyze_iis` (see Changed); forwarded by `log_report` to
  child modules that accept it.
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
- `log_report` default modules changed from `access,iis,errors` to
  `overview,iis,access` (executed in that order). `analyze_errors` is now
  opt-in: pass `--modules ...,errors` to include it. BREAKING.
- `analyze_iis` `--format tsv|csv` now produces real long-format detail tables
  (REGION/ROLE/SERVER/METRIC/KEY/COUNT/AVG_SEC/PCT columns, one header,
  `--top`-capped, RFC-4180 quoting for csv). The previous no-op + `log_warn`
  behavior is removed. `--format` governs the detail file/view only; summary is
  always text. BREAKING (callers relying on the warn path will no longer see it).
- `--output-dir DIR` semantics redefined on all 5 CLIs: previously routed
  combined `log_report` output to a single directory (single-file model); now
  triggers always-on per-module summary + detail file persistence across all
  modules. Default is the empty string in each CLI; the `./log-parse/` literal
  lives only inside `persist_init` (precedence: flag > `$LOG_PARSE_OUTPUT_DIR`
  env > `./log-parse/`). `log_report` propagates the resolved dir to children
  via `$LOG_PARSE_OUTPUT_DIR` env (not via flag forwarding). BREAKING.
- Interval flags are now mutually exclusive on all 5 CLIs: specifying more than
  one of `--today`, `--date`, `--from/--to`, or an explicit `--days` aborts with
  `die` citing the priority ranking `--date > --from/--to > --today > --days`.
  `--days` remains the implicit fallback when no selector is given.
- `log_report --view` (default `summary`) is now parsed and forwarded to
  `analyze_iis` and `analyze_access`; `analyze_overview` and `analyze_errors`
  receive neither `--view` nor `--format`.
- `docs/usage.md`, `docs/usage.zh-TW.md`, `docs/design.md`,
  `docs/design.zh-TW.md` updated to document all new and changed flags,
  persistence model, interval-mutex table, summary/detail split, and
  forwarding semantics. `examples/sample-outputs/README.md` and
  `README.zh-TW.md` updated to index all new and regenerated fixtures.
- `examples/sample-outputs/` extended with new fixtures: `overview_all_week.txt`,
  `overview_taipei_week.txt`, `iis_summary_all_2026-05-21.txt`,
  `iis_detail_all_2026-05-21.{tsv,csv}`, `access_summary_all_2026-05-21.txt`,
  `access_detail_all_2026-05-21.txt`, `errors_summary_taipei_2026-05-21.txt`,
  `errors_detail_taipei_2026-05-21.txt`; existing `log_report_*` fixtures
  regenerated (new default modules/order/view).
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
- `--output FILE` from all 5 CLIs (breaking change). The single-file output
  model is incompatible with the always-on two-files-per-module persistence
  introduced in this release. Migration: remove `--output file.txt`; reports
  are written automatically to `./log-parse/` (or `--output-dir DIR`).
- `--slow-ms` flag from `analyze_iis`: replaced by `--slow-api-ms` and
  `--slow-app-ms` with role-aware defaults. No backward-compat alias provided
  (clean-break Decision A).
- `API_REQUEST_ID` and `APP_REQUEST_ID` columns from `analyze_access` output:
  merged into the single `REQUEST_ID` field in all output formats (text, tsv,
  csv).

### Fixed
- CJK display-width alignment for KV/stat/restart rendering: `fmt_kv` /
  `fmt_kv_color` now compute pad via `FMT_AWK_WIDTH` (wcwidth engine in
  `lib/fmt_utils.sh`) instead of byte-count `%-40s`; delta-stats and ORPHAN
  verify-summary inline awk in `analyze_access.sh` and restart/UNMATCHED table
  in `analyze_errors.sh` likewise use `rpad(…,N)` under `LC_ALL=C`. CJK and
  ASCII labels now align in the terminal. Tests: 143 -> 146 (A35, A36, C22).
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
