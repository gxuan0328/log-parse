---
paths:
  - "tests/**/*.sh"
---

# Testing rules

Loaded when editing `tests/run_tests.sh` or any new test file.

## Single source of truth

`tests/run_tests.sh` is the only regression suite. Currently 108 tests
across six sections (A access · B iis · C errors · D log_report ·
E validation · F user scenarios).

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

- A01–A27  `analyze_access`
- B01–B19  `analyze_iis`
- C01–C17  `analyze_errors`
- D01–D21  `log_report`
- E01–E12  validation paths
- F01–F11  user scenarios

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
