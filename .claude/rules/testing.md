---
paths:
  - "tests/**/*.sh"
---

# Testing rules

Loaded when editing `tests/run_tests.sh` or any new test file.

## Single source of truth

`tests/run_tests.sh` is the only regression suite. Currently 352 tests
across thirteen sections (A access · B iis · C errors · D log_report ·
E validation · F user scenarios · G CJK alignment · H overview · I persistence ·
J test-host/health · K timezone+core-function · L notification dispatch ·
M report-export container integration).

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
- L01–L31  notification dispatch (`--notify`/`--notify-dry-run`/`--notify-attach`)
  — golden payload shape, attach-mode scoping, escaping round-trips, size
  caps, transport shim, fatal-on-failure; offline only, no test contacts a
  real endpoint. L23–L29: adversarial-review regression fixes — backslash
  in `--output-dir` still attaches correctly + an unreadable attachment
  dies (L23/L24), pinned `LOG_PARSE_RUN_TS` never self-attaches the dry-run
  payload (L25), empty-`DISPLAY_NAME` external-domain audit (L26), UTF-8
  safe body truncation (L27), no-trailing-newline byte count (L28), TAB in
  a filename dies (L29). L30/L31: a LATER review round's own "FIX I"/
  "FIX J" (unrelated to L23–L29's identically-lettered, earlier fixes —
  letters are reused independently per round; disambiguated in the test
  file itself) — `notify_subject`/`notify_build_body` no longer SIGPIPE
  (rc=141) under `set -euo pipefail` for a multi-day window (L30, called
  directly so the `if notify_send` calling context that incidentally
  suspended errexit cannot mask a regression), and the coverage gap that
  hid this (every earlier fixture used a single-day `--date`) is closed
  by driving `--from`/`--to` and `--days` through the full `--notify
  --notify-dry-run` CLI path and asserting the Subject/Analysis-range
  render the complete window (L31)
- M01–M34  `--report-export` container integration — dependency
  conditionality (M01); the `--format csv`/access-module legality guards
  and their exact die text (M02–M04); the docker preflight gate, both its
  missing-binary and `image inspect`-failure paths, and the image-ref /
  user-spec whitelists (M05–M08); the `production/{input,state,output}`
  tree as a sibling of the run directory with mode 700 (M09); the
  window-start staging derivation across `--days`/`--date`/`--from`-`--to`
  (M10–M12); staging copy-not-move semantics and the identical/differing
  overwrite branches (M13–M15); the `:`-in-path guard (M16); the rendered
  `docker run` argv shape, including the default no-`--user` behaviour
  and the `LOG_PARSE_REPORT_EXPORT_USER` opt-in escape hatch (M17), and
  image-reference override propagation (M18); stdout isolation
  and byte-identity with/without the flag, and stderr diagnostic
  preservation (M19–M21); the happy path plus `--notify` integration
  (7 attachments incl. the CJK filename key, and the `--notify-attach
  summary` mode-bypass proof) (M22); the deliverable-selection
  correctness proof against planted newer-mtime decoys (M23) and the
  idempotent-overwrite branch (M24); malformed/missing/stale deliverable
  handling (M25); malformed JSON-summary shapes (M26); the hostile
  deliverable-path whitelist (M27); and container exit-code
  classification plus the attachment size cap applying to the xlsx under
  a combined `--report-export --notify` run (M28). M29–M34: a LATER
  review round's own "FIX A"–"FIX H" (unrelated to L23–L29's identically-
  lettered, earlier fixes to `lib/notify_utils.sh` — letters are reused
  independently per round; disambiguated in the test file itself) — a
  host-side SYMLINKED deliverable is refused and dies before being
  followed, and no `--notify-dry-run` payload is ever produced from it
  (M29, CRITICAL — CWE-22/CWE-61); a pre-existing symlinked
  `production/output` mount point is rejected before mkdir/chmod/trust
  (M30); a chmod that is silently ignored (simulated by shadowing
  `chmod` with a no-op stand-in on PATH) still lets the run proceed but
  emits exactly one unmissable SECURITY warning (M31); a forged
  log-parse-style bracketed prefix inside relayed container stderr can
  never appear unprefixed in the log stream (M32, CWE-117); the
  staged-CSV byte-compare's unopenable-file path now emits a
  `REPORT_EXPORT_RESULT status=failed reason=stage_compare` line before
  dying (M33); and a ported-registry image reference is accepted
  verbatim while a leading-`-`-plus-port/path hostile value is still
  rejected (M34, CWE-88). Also fixed in this round (regression-covered by
  the corrected M16/M28 above, each proven to fail against the prior
  behaviour): M16's vacuous `docker run`-never-invoked assertion (a
  leading space made the negated `grep` pattern unmatchable regardless of
  actual invocation) and M28's oversize sub-case (a 1-byte cap breached
  on a run-directory file before the xlsx was ever reached, so the
  cap-applies-to-the-xlsx claim was never actually exercised — now a
  6000-byte cap against an 8000-byte sentinel xlsx, comfortably above
  every real run-directory file). Offline only via a `fake_docker.sh`
  shim (mirrors Section L's `fake_curl.sh` pattern) — no test ever
  contacts a real Docker daemon or network endpoint.

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
| `_hasre ID DESC OUT EREGEX`  | Extended-regex match present (use when fixed-string `_has` cannot lock column order, e.g. a reordered header) |
| `_glob ID DESC GLOB`         | At least one file matches the shell glob (use when the filename contains a timestamp component) |
| `_pick OUT PATTERN`          | Extract last whitespace-token from matching line |
| `_sum OUT PATTERN`           | Sum last tokens across matching lines            |
