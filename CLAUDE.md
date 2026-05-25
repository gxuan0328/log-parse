# CLAUDE.md — Project Conventions for AI Assistants & Contributors

> This file captures the design principles, coding conventions, and
> idiomatic patterns of `log-parse`. Read it before changing any code.
> When user-level instructions (e.g. `~/.claude/CLAUDE.md`) conflict with
> this file, the user-level instructions win.

---

## 1. What this project is

`log-parse` is a **read-only** bash + gawk toolkit that analyses three
families of logs (access CSV, IIS W3C, .NET app logs) emitted by the
LUNG-CANCER-REPORT system. It is deliberately small, dependency-light,
and Unix-philosophy aligned: each script does one job, composes via pipes
and exit codes, and prints to stdout.

It is **not** a daemon, not a database, not a long-running service. Do
not introduce one.

---

## 2. Core design philosophy

### 2.1 Fail fast, fail loud
- `set -euo pipefail` is mandatory at the top of every executable script.
- Validate required arguments at the boundary (in `parse_args`); abort via
  `die "…"` (defined in `lib/common.sh`) rather than printing and continuing.
- Never silently swallow errors. `cmd 2>/dev/null || true` is forbidden
  unless the failure is truly inert (e.g. an exists-check). Add a comment
  explaining why if you must.

### 2.2 Single source of truth
- Date math: `lib/date_utils.sh::build_date_list`. Do not reinvent.
- Region mapping: `conf/regions.conf` consumed by `load_regions`.
- CSV / IIS / app-log field extraction: `lib/csv_utils.sh`.
- Formatting: `lib/fmt_utils.sh`.

If a behaviour is needed in two places, extract it. If it is needed in
one place, keep it inline — premature abstraction is worse than duplication.

### 2.3 Stdout is the report; stderr is the log
- Reports always go to stdout. Logs (`log_info`, `log_warn`, …) always go
  to stderr. This invariant lets users pipe the report into a file or tool
  without log noise.
- The `--output FILE` flag uses a `tee` so users see progress on stdout
  AND get the file on disk.

### 2.4 Defaults are safe; flags are explicit
- Default region is `all`. Default date window is the last 7 days. Default
  output is stdout.
- A user typing `bash bin/log_report.sh --log-dir …` with no other flags
  should produce a sensible full report.

### 2.5 Heavy lifting in gawk, not bash
- Joins, group-bys, filters → gawk.
- Orchestration, argument parsing, file plumbing → bash.
- This keeps bash code small and gawk programs auditable.

---

## 3. Repository layout

| Path             | Purpose                                                              |
|------------------|----------------------------------------------------------------------|
| `bin/`           | Executable CLI entry points. One file = one user-visible command.    |
| `lib/`           | Sourced-only helpers. Library files must not have `main "$@"`.       |
| `conf/`          | Plain-text configuration consumed by `load_regions` and similar.     |
| `docs/`          | `design.md`, `usage.md`. Update both whenever a flag or field changes. |
| `examples/`      | `sample-logs/` (bundled dataset), `sample-outputs/` (expected reports), and small driver scripts. |
| `tests/`         | `run_tests.sh` — single-file functional suite.                       |
| Root files       | `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `LICENSE`, `Makefile`, `.gitignore`, `.editorconfig`. |

---

## 4. Bash conventions

### 4.1 Scaffold every executable script with this header

```bash
#!/usr/bin/env bash
# bin/<name>.sh
# ----------------------------------------------------------------------------
# <one-line summary>
# <multi-line context: what inputs, what outputs, why it exists>
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"   # if dates
source "${SCRIPT_DIR}/../lib/csv_utils.sh"    # if log parsing
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"    # if rendering
```

### 4.2 Avoid the `[[ cond ]] && cmd` footgun

Inside a function body, this idiom returns 1 when `cond` is false. If it
is the last statement in the function, the function's return value is 1,
which under `set -e` aborts the caller. Prefer:

```bash
# WRONG (silently breaks set -e behaviour)
build_args() {
    args=("--log-dir" "$dir")
    [[ -n "$verbose" ]] && args+=("--verbose")   # returns 1 when $verbose is empty
}

# RIGHT
build_args() {
    args=("--log-dir" "$dir")
    if [[ -n "$verbose" ]]; then args+=("--verbose"); fi
}
```

The compound `[[ ]] && cmd` is fine in scripts at the *top level* (bash
exempts simple-list components from `set -e` mid-execution), but treat it
as suspicious in any function whose return value is consumed.

### 4.3 Argument arrays, not strings

When forwarding arguments to a sub-process, build a bash array:

```bash
args=()
args+=("--log-dir" "$OPT_LOG_DIR")
[[ -n "$OPT_DATE" ]] && args+=("--date" "$OPT_DATE")
"$bin" "${args[@]}"
```

Never `echo` and word-split — paths with spaces will break.

### 4.4 Quoting

- Quote every variable expansion except in arithmetic contexts: `"$var"`.
- Use `"${var}"` when a literal follows: `"${path}_${date}.txt"`.
- Use `${var:-default}` for safe fallback.
- Use arithmetic `(( ... ))` for integer compares, not `[[ "$x" -eq … ]]`.

### 4.5 Temp files

- Allocate via `init_tmpdir` (sets `$WORK_TMPDIR`, installs cleanup trap).
- Use `${WORK_TMPDIR}/descriptive_name.tsv`. Never write to `/tmp/foo`.
- Per-process tmpdirs survive crashes for postmortem because the trap is
  cancelled in those cases; manually `rm -rf` if needed.

### 4.6 Logging idiom

| Helper       | Use for                                              |
|--------------|------------------------------------------------------|
| `log_debug`  | Verbose-only details (enabled by `-v`). Gated by LOG_LEVEL. |
| `log_info`   | Normal progress (one-per-region, one-per-stage).     |
| `log_warn`   | Recoverable issues (missing per-server dir, etc.).   |
| `log_error`  | Fatal context; usually paired with `exit 1`.         |
| `die "msg"`  | Shortcut for `log_error + exit 1`.                   |

Never `echo "ERROR: …" >&2` directly — go through the helpers so format
and colour stay consistent.

---

## 5. gawk conventions

### 5.1 Anchor every awk program with a comment block

```awk
# ----------------------------------------------------------------------------
# Purpose : one-line summary.
# Input   : how each record is shaped.
# Vars    : -v passes from the caller.
# Output  : TAB-prefixed kind tags, one per row.
# ----------------------------------------------------------------------------
```

### 5.2 Always emit TAB-delimited, kind-prefixed rows

Downstream bash should be able to `grep TAG | awk '{print $2}'` without
guessing whitespace. Pattern:

```
TOTAL\t<n>
STATUS\t<code>\t<count>
ENDPOINT\t<uri>\t<count>
```

### 5.3 Two-file joins: prefer `FILENAME == varname` over `FNR == NR`

`FNR == NR` is the standard awk idiom but breaks when the first file is
empty (FNR resets and the second file is parsed as the first). Pass the
first file's path via `-v var=...` and compare `FILENAME == var`.

### 5.4 Normalise before grouping

For top-N error pattern reports, replace timing values / dates / numbers
with placeholders so semantically identical messages collapse into one
key. See `ERROR_AWK` in `bin/analyze_errors.sh` for the canonical pattern.

---

## 6. Library function checklist

Every public function in `lib/*.sh` must carry a docblock comment with:

1. **Purpose** — one line.
2. **Args** — name and type of each positional argument.
3. **Output** — what is printed (and which stream).
4. **Returns / Side effects** — mutated globals, files written, exit codes.
5. **Errors** — failure modes worth knowing about.

Example:

```bash
# count_lines FILE
#   Purpose : Count lines in FILE; returns 0 for non-existent / empty.
#   Args    : FILE — path.
#   Output  : line count on stdout.
#   Notes   : Uses gawk to dodge wc's whitespace padding quirk.
count_lines() { ... }
```

---

## 7. Configuration

`conf/regions.conf` is pipe-delimited and consumed by every analyser via
`load_regions`. Format:

```
# REGION_ID|REGION_NAME|API_SERVERS|APP_SERVERS
taipei|台北|10.22.63.37|10.21.3.35,10.21.3.36
```

- Adding a region is a no-code change: append a line; tests still pass.
- Lines starting with `#` and blank lines are skipped.
- The display name is free-form (CJK is fine and used).

---

## 8. Testing

- `tests/run_tests.sh` is the single source of regression truth.
- Every parameter combination that ships in the CLI table must have at
  least one test (positive path) and at least one negative-path test
  (invalid value / missing arg).
- Baselines are derived from `examples/sample-logs/LUNG-CANCER-REPORT-LOG`
  with **fixed dates**. Do not introduce `--days N` baselines that drift
  with `$(date +%F)`.
- New scenarios should land in Section F (`使用情境模擬`).

Run with `make test` or `bash tests/run_tests.sh`.

---

## 9. Documentation invariants

Whenever you change a flag, default, output field, or detection rule:

1. Update `bin/<script>.sh` (code + usage banner).
2. Update `docs/usage.md` (flag table + at least one example).
3. Update `docs/design.md` (rule semantics, output field table).
4. Update `tests/run_tests.sh` (add or modify the baseline).
5. Update `examples/sample-outputs/` (re-run the affected commands).
6. Update `CHANGELOG.md` under `[Unreleased]`.

If you change a number that appears in `design.md` (e.g. the top-N
default), grep for it across the repo — it is referenced from multiple
places by design.

---

## 10. Things to avoid

- **No new dependencies.** The toolkit requires only `bash`, `gawk`,
  `date`, `sort`, `mktemp` — all GNU coreutils. Do not introduce `jq`,
  `python`, `node`, or compiled tooling.
- **No emojis in source files.** They are fine in user-facing report
  text where they aid scanning (▶ ■), but not in docstrings or commits.
- **No silent fallbacks.** A missing log file is `log_warn` + return; a
  missing region config is `die`. Never default to "empty data is fine".
- **No `git add -A` in helper scripts.** Stage explicit paths so secrets
  / data don't sneak in.
- **No interactive prompts.** The toolkit is automation-friendly; every
  flag must have a non-interactive default.

---

## 11. Commit messages

Follow Conventional Commits:

```
feat(access): add --format tsv for downstream pipelines
fix(report): use if/then/fi in build_module_args to satisfy set -e
docs(usage): document --slow-ms threshold and worked examples
test(errors): cover unmatched SHUTDOWN baseline for Taipei
```

Scope hints: `access`, `iis`, `errors`, `report`, `lib`, `tests`, `docs`,
`build` (for Makefile / .gitignore changes).

---

## 12. When extending the toolkit

Before writing code, answer:

1. Which user persona / use case is this for? (Reference `docs/design.md §1.2`.)
2. Where does it fit in the layering — bin, lib, or conf?
3. Does it require a new dependency? (If yes → reconsider.)
4. What tests will pin its behaviour?

After writing code, run:

```bash
make test       # tests must still pass
make lint       # shellcheck must be clean if installed
```

…and update every file listed in §9.

---

## 13. Auto-triggered feature workflow (MANDATORY)

This repository ships a project-scoped workflow skill at
[`.claude/skills/feature-workflow/SKILL.md`](.claude/skills/feature-workflow/SKILL.md).

**When to auto-trigger** — you MUST invoke (read & follow) the
`feature-workflow` skill at the start of any request that meets ANY of:

- Adds, removes, renames, or modifies a CLI flag, output section, metric,
  detection rule, threshold, default value, file, or library function.
- Changes parsing logic, awk programs, formatters, region config, or
  test baselines.
- Modifies anything under `bin/`, `lib/`, `conf/`, `tests/`, `docs/`,
  `examples/`, `.claude/`, or root project files (`README*`, `CLAUDE.md`,
  `CHANGELOG.md`, `Makefile`, `LICENSE`, `.gitignore`, `.gitattributes`,
  `.editorconfig`).
- Produces a tag, release, or remote push.

**When to skip** — strictly read-only conversations (e.g. "explain X",
"summarise CHANGELOG", "show me file Y") do not trigger the workflow.

**What the skill enforces** — seven phases, in order, none optional:

| Phase | Purpose                                                                                  |
|-------|------------------------------------------------------------------------------------------|
| 1     | **Pre-development impact analysis** — module map, design alignment, risk surface         |
| 2     | **Implementation discipline** — §4/§5/§6 conventions, local sanity, performance-aware    |
| 3     | **Validation gate** — regression + new baselines + cross-mode + lint + quality + perf    |
| 4     | **Documentation & example sync** — bilingual docs, in-code comments, samples, CHANGELOG  |
| 5     | **Cross-validation** — doc↔code, EN↔zh-TW parity, link validity, baseline integrity      |
| 6     | **Commit & release** — Conventional Commits, semver decision, tag/release if requested   |
| 7     | **Terminal-only execution summary** — no extra files, no persistent reports              |

**Why this matters**

- Prevents drift between code, tests, English docs, and Traditional Chinese docs.
- Bakes test-pass + lint-clean + samples-regenerated into every change.
- Standardises commit / version / release decisions so the repo history
  remains auditable.

Override only on explicit user instruction such as "skip the workflow"
or "no tests this time". When overridden, state in the terminal summary
which phases were skipped and why.
