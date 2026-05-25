---
paths:
  - "docs/**/*.md"
  - "README*.md"
  - "CHANGELOG.md"
  - "examples/**/README*.md"
---

# Documentation rules

Loaded when editing user-facing docs, READMEs, sample-output indexes, or
the changelog.

## The six-file invariant

When you change a flag, default, output field, or detection rule, update
**every one** of these in the same commit:

1. `bin/<script>.sh` — code + `usage()` heredoc
2. `docs/usage.md` **and** `docs/usage.zh-TW.md`
3. `docs/design.md` **and** `docs/design.zh-TW.md`
4. `tests/run_tests.sh` — baseline + new positive/boundary/negative tests
5. `examples/sample-outputs/<file>.txt` — regenerated with `NO_COLOR=1`
6. `CHANGELOG.md` — entry under `[Unreleased]`

## Bilingual parity (EN ↔ zh-TW)

For each English doc there is a matching `*.zh-TW.md`. Rules:

- **Never** leave one language stale. Same commit, same scope.
- Same section structure (§ numbers + headings parallel).
- Same code blocks, same numeric values, same examples.
- The translation must preserve precise software-engineering terminology
  — don't translate `awk`, `gawk`, `set -e`, `stdout`, `mktime`, etc.

## Sample-output regeneration

```bash
LOG_DIR="./examples/sample-logs/LUNG-CANCER-REPORT-LOG"; export NO_COLOR=1
bash bin/analyze_<x>.sh ... > examples/sample-outputs/<file>.txt
```

`NO_COLOR=1` is mandatory so diffs stay readable and ANSI escapes never
pollute the committed artefact.

When a module's output changes, also regenerate dependent
`log_report_*.txt` files in the same commit.

## CHANGELOG format

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Add
entries to the `[Unreleased]` section under the matching category:

`Added` · `Changed` · `Deprecated` · `Removed` · `Fixed` · `Security`

Promote `[Unreleased]` → a real version section only when releasing.

## Link hygiene

- Every relative link must resolve. Audit with:
  ```bash
  grep -oE '\]\([^)#h][^)]*\)' file.md
  ```
- Markdown to a file outside `docs/` should use the path from this file's
  directory (e.g. `docs/design.md` → `../.claude/CLAUDE.md`).
- Don't link to anchors that don't exist; if you cite a section, link to
  the file and quote the section heading nearby.

## Numbers and baselines

Specific numbers in docs (`108/108`, `ERROR=46`, `OracleDB=44`,
`Restart=9`) must match `tests/run_tests.sh` baselines. When you bump
a baseline, grep the repo:

```bash
grep -RIn "108/108\|ERROR=46\|OracleDB=44" --include="*.md"
```

## Terminology hygiene

Prefer precise terms:

| Avoid                  | Prefer                                        |
|------------------------|-----------------------------------------------|
| "the script runs X"    | "the module invokes X as a subprocess"        |
| "joins two files"      | "two-pass awk join over <files>"              |
| "uses Serilog"         | "structured-logger format (pipe-delimited)"   |
| "commits the change"   | "Conventional Commits: `feat(scope): …`"      |
