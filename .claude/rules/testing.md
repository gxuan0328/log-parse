---
paths:
  - "tests/**/*.sh"
---

# Testing rules

Loaded when editing `tests/run_tests.sh` or any new test file.

## Single source of truth

`tests/run_tests.sh` is the only regression suite. Currently 316 tests
across twelve sections (A access · B iis · C errors · D log_report ·
E validation · F user scenarios · G CJK alignment · H overview · I persistence ·
J test-host/health · K timezone+core-function · L notification dispatch).

Run with `make test` or `bash tests/run_tests.sh`. Exit 0 = all passed.

## Baselines must be deterministic

- Derive baselines from `examples/sample-logs/LUNG-CANCER-REPORT-LOG`
  with **fixed dates** (2026-05-18 ~ 2026-05-25).
- **Never** use `--days N` without `--date` / `--from-to` in a baseline,
  since the resolved window drifts with `$(date +%F)`.
- Document baseline numbers in section header comments so reviewers can
  validate at a glance.

## Test ID convention

`<SectionLetter><2-digit-id>`, sequential within a section:

- A01–A52  `analyze_access` (A42: IP file exists + counts; A43: empty corpus header-only; A44: stdout isolation + emit-stats no-create; A45–A52: BIRTHDAY (JWT dob) trailing column — header/value positive, decoder sentinel + positive/pretty-space/dobby-trap boundary, field-index + summary/ip_counts non-breaking regression)
- B01–B40  `analyze_iis` (B39: Top-端點 avg; B40: rank-fix)
- C01–C25  `analyze_errors`
- D01–D35  `log_report`
- E01–E38  validation paths (E27–E37: `--notify*` negatives — bad enum, missing `--notify`, bad URL/receivers/From-address, missing curl, duplicate address; E38: receivers.conf content validation dies in parse_args, before persist_init)
- F01–F18  user scenarios
- G01–G05  CJK display-width alignment (+ A35, A36, C22; G04: fmt_bar determinism; G05: agg_access_records malformed-APP_TIME guard)
- H01–H25  `analyze_overview` (H16-H21: per-region N/O/U + verdict boundaries; H22: single-day global chart; H23: per-region chart counts; H24: multi-day no chart; H25: today-cap + midnight)
- I01–I12  persistence (always-on report files)
- J01–J20  test-host filter + /health exclusion
- K01–K16  timezone correction + core-function CATEGORY
  (K13/K14 intentionally vacant — gap preserved per commit history; K15/K16 continue past gap)
- L01–L29  notification dispatch (`--notify`/`--notify-dry-run`/`--notify-attach`)
  — golden payload shape, attach-mode scoping, escaping round-trips, size
  caps, transport shim, fatal-on-failure; offline only, no test contacts a
  real endpoint. L23–L29: adversarial-review regression fixes — backslash
  in `--output-dir` still attaches correctly + an unreadable attachment
  dies (L23/L24), pinned `LOG_PARSE_RUN_TS` never self-attaches the dry-run
  payload (L25), empty-`DISPLAY_NAME` external-domain audit (L26), UTF-8
  safe body truncation (L27), no-trailing-newline byte count (L28), TAB in
  a filename dies (L29)

When inserting tests, keep numbering monotonic — append new tests at the
end of the relevant section, do not renumber existing ones.

## Required coverage per new behaviour

For every new flag / metric / output section, add at minimum:

1. **Positive baseline** — expected output / value appears.
2. **Boundary baseline** — empty / zero / no-data scenario behaves cleanly.
3. **Negative baseline** — invalid argument exits 1 with message.

Place positive + boundary in the matching A–D section; place negative
in section E.

## Helper functions (do not redefine)

| Helper                       | Asserts                                          |
|------------------------------|--------------------------------------------------|
| `_eq ID DESC ACTUAL EXPECTED`| String equality                                  |
| `_gte ID DESC ACTUAL MIN`    | Integer ≥                                        |
| `_has ID DESC OUT PATTERN`   | Substring present in output                      |
| `_lacks ID DESC OUT PATTERN` | Substring absent from output                     |
| `_ok ID DESC RC`             | Exit code == 0                                   |
| `_err ID DESC RC`            | Exit code != 0                                   |
| `_pick OUT PATTERN`          | Extract last whitespace-token from matching line |
| `_sum OUT PATTERN`           | Sum last tokens across matching lines            |
