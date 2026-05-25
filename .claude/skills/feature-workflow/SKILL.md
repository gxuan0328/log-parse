---
name: feature-workflow
description: |
  Standardised feature-development workflow for log-parse. Auto-triggered
  by CLAUDE.md §7 for any code-touching request. Enforces seven phases:
  pre-dev impact analysis, implementation discipline, validation gate,
  documentation sync, cross-validation, commit/release, terminal summary.
metadata:
  scope: project
  project: log-parse
---

# feature-workflow — log-parse standardised process

Read this once when triggered. Follow the seven phases in order; check
items off explicitly in your response so the user can verify nothing was
skipped. Detailed conventions for each layer live in `.claude/rules/*.md`
and load automatically when you touch matching files.

> Trigger contract & override rules: see
> [`../../CLAUDE.md`](../../CLAUDE.md) §7.

---

## Phase 1 — Pre-development impact analysis

Print a brief impact map **before** any file edit.

- [ ] Restate the user request in one sentence.
- [ ] List every file/function that will change, grouped by layer:
      `bin/` · `lib/` · `conf/` · `tests/` · `docs/` (EN+zh-TW) ·
      `examples/sample-outputs/` · `examples/*.sh` · `CHANGELOG.md` ·
      `.claude/` (if conventions evolve).
- [ ] Confirm approach respects CLAUDE.md §2 (the five rules) — call out
      any deviation up-front.
- [ ] Flag risks: backwards-compat breaks (TSV column shifts, exit-code
      changes), new dependency requests (forbidden — see §6), potential
      unbounded memory paths, shell-injection or unsafe file-write surfaces.

---

## Phase 2 — Implementation

Apply the conventions from the path-scoped rule files; do not improvise.

- [ ] Touched `*.sh` → follow `.claude/rules/bash.md`.
- [ ] Touched a gawk program → follow `.claude/rules/awk.md`.
- [ ] Touched `lib/*.sh` → follow `.claude/rules/library.md`.
- [ ] Ran the changed analyser at least once against the bundled dataset
      and read its output. New section / value appears; surrounding
      output did not regress.
- [ ] No unbounded data structures without a documented rationale OR a
      `--top-X N` cap.

---

## Phase 3 — Validation gate

All gates must pass before the documentation phase.

- [ ] **Regression**: `bash tests/run_tests.sh` → 100% pass, test count
      strictly non-decreasing.
- [ ] **New baselines** added per `.claude/rules/testing.md` (positive +
      boundary + negative).
- [ ] **Cross-mode smoke** for analyser changes: single date · range ·
      `taipei` · `taichung` · `all` · no-data date · `--output` /
      `--output-dir` via `log_report`.
- [ ] **Static analysis**: `make lint` clean if shellcheck present;
      else `bash -n` every changed script.
- [ ] **Exit codes**: success = 0, validation error = 1, no-data = 0.
- [ ] **Quality & security**: no new silent suppression; `init_tmpdir`
      trap still installed; no unescaped user input into `eval` / `bash -c`;
      no new runtime dependency.
- [ ] **Perf sanity** for non-trivial additions:
      `time bash bin/<x>.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 >/dev/null`
      — report in §7 summary if wall-clock changed > 50%.

---

## Phase 4 — Documentation & example sync

Six-file invariant (also encoded in `.claude/rules/documentation.md`):

- [ ] `bin/<script>.sh` — code + `usage()` heredoc.
- [ ] `docs/usage.md` **and** `docs/usage.zh-TW.md`.
- [ ] `docs/design.md` **and** `docs/design.zh-TW.md`.
- [ ] `tests/run_tests.sh` — baselines.
- [ ] `examples/sample-outputs/*.txt` — regenerated with `NO_COLOR=1`;
      dependent `log_report_*.txt` also refreshed.
- [ ] `CHANGELOG.md` `[Unreleased]` — Keep-a-Changelog category.

Update in-code comments (awk header, library docblock) per
`.claude/rules/awk.md` and `.claude/rules/library.md`.

---

## Phase 5 — Cross-validation

Audit before staging. If any check fails, fix and re-run.

- [ ] **Doc ↔ code**: every flag in `parse_args` appears in the docs
      table with the right default.
- [ ] **EN ↔ zh-TW parity**: matching headings, same numerics, same examples.
- [ ] **Link audit**: every relative markdown link resolves.
- [ ] **Baseline integrity**: numbers cited in docs match
      `tests/run_tests.sh` baselines (`grep -RIn` to confirm).
- [ ] **Terminology**: precise software-engineering vocabulary
      (subprocess invocation, two-pass awk join, Conventional Commits) —
      avoid claims that cannot be verified.

---

## Phase 6 — Commit & release

- [ ] **Stage explicit paths** — never `git add -A` / `.`.
- [ ] **Subject**: `<type>(<scope>): <imperative ≤ 72 chars>` (see
      CLAUDE.md §5).
- [ ] **Body** (HEREDOC-quoted, blank line after subject):
      one paragraph WHY · touched layers bullet list · anchoring numerics.
- [ ] **Version decision**: feature → MINOR · breaking → MAJOR ·
      fix/refactor/docs (no API change) → PATCH. Bump only when user
      requests a release; otherwise leave entries under `[Unreleased]`.
- [ ] **Tag & GitHub Release** (only on release request):
      `git tag -a vX.Y.Z -m "…"` + `gh release create vX.Y.Z …`.
- [ ] **Push**: `git push origin main` (+ `git push origin vX.Y.Z` if tagged).

---

## Phase 7 — Terminal execution summary

Print one block, no files written, no follow-up artefacts:

```
═══════════════════════════════════════════════════════════════════
  log-parse — Workflow Summary
═══════════════════════════════════════════════════════════════════
  Request          : <restated user ask>
  Impact layers    : bin / lib / docs / tests / examples (only those touched)
  Files touched    : <N> (concise list)
  Tests            : <PASS>/<TOTAL> passed
  Lint             : OK | skipped (shellcheck absent)
  Perf delta       : negligible | +X% on <command>
  Docs in sync     : design.md, design.zh-TW.md, usage.md, usage.zh-TW.md,
                     CHANGELOG.md (others if touched)
  Samples updated  : <list> | none
  Commit           : <hash> — <subject>
  Push             : origin/main → ok | local-only (per user)
  Release          : vX.Y.Z (URL) | n/a (Unreleased)
  Phases skipped   : none | <list with reason>
  Next suggestion  : <e.g. tag a release, fold [Unreleased] → vX.Y.Z>
═══════════════════════════════════════════════════════════════════
```

Override behaviour: if the user explicitly tells you to skip a phase
(e.g. "no tests this time"), still run the others and list the skipped
phase under `Phases skipped` with the reason.
