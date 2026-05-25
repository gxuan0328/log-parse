---
name: feature-workflow
description: |
  Standardised feature-development & modification workflow for the log-parse
  repository. Auto-trigger this skill whenever the user requests a feature
  addition, behaviour change, bug fix, refactor, or any code-touching task in
  this project. Defines pre-development analysis, implementation discipline,
  validation gates (functional / quality / security / performance), bilingual
  documentation sync, sample regeneration, and Conventional-Commits release
  flow. Ends with a terminal-only execution summary (no extra files).
metadata:
  scope: project
  project: log-parse
  triggers:
    - user requests new functionality in this repo (feat)
    - user requests behaviour modification (refactor / change)
    - user requests bug fix (fix)
    - user requests documentation update tied to code (docs paired with code)
---

# log-parse — Feature Workflow

> **Status**: Project-scoped, auto-triggered.
> Project's [`CLAUDE.md`](../../CLAUDE.md) §13 mandates that every
> code-touching request in this repository follow this workflow.
> `.claude/CLAUDE.md` is the single authoritative location — Claude Code
> auto-loads it as the project's instructions (per the official docs:
> `./CLAUDE.md` and `./.claude/CLAUDE.md` are equivalent project-scope
> locations). Skip steps only with explicit user override.

---

## Phase 0 — Trigger Detection

Activate when the current user message implies any of:

- adding / removing / renaming a CLI flag, output section, metric, file, or library function;
- changing detection rules, thresholds, defaults, or data parsing logic;
- modifying anything under `bin/`, `lib/`, `conf/`, `tests/`, `docs/`, `examples/`, or root project files;
- producing a release, tag, or changelog entry.

Skip only when the request is read-only (e.g. "explain the codebase",
"show me the diff", "summarise CHANGELOG").

---

## Phase 1 — Pre-Development Analysis (read-first, write-never)

Goal: build a complete impact map before touching code.

### 1.1 Requirement decomposition
- Restate the user's request in one sentence.
- Identify the smallest user-visible deliverable.

### 1.2 Module-level impact mapping
For each item, list the files / functions that will be touched:

| Layer            | What to inspect                                          |
|------------------|----------------------------------------------------------|
| CLI entry        | `bin/<script>.sh` — parse_args, defaults, usage banner   |
| awk programs     | `*_AWK` blocks — fields, output kinds, sorting           |
| Shared library   | `lib/{common,date_utils,csv_utils,fmt_utils}.sh`         |
| Configuration    | `conf/regions.conf` and any new conf file                |
| Tests            | `tests/run_tests.sh` — relevant Section (A–F) baselines  |
| Docs             | `docs/{design,usage}.{md,zh-TW.md}` cross-refs           |
| Examples         | `examples/sample-outputs/*.txt` and `examples/*.sh`      |
| Cross-cutting    | `CLAUDE.md` (if a new convention emerges), `CHANGELOG.md`|

### 1.3 Design alignment check
Verify the proposed approach respects existing philosophy:
- §1 fail-fast, no silent error suppression
- §2.2 single source of truth (date math, regions, formatting)
- §2.3 stdout=report, stderr=log
- §2.5 heavy lifting in gawk, orchestration in bash
- §4.2 avoid `[[ cond ]] && cmd` as last statement in functions

### 1.4 Risk identification
Surface (without action):
- Backwards-compat breaks for downstream pipelines (TSV column shifts, exit-code changes).
- New dependencies (forbidden unless user explicitly approves).
- Potential O(n²) or unbounded-memory paths introduced by the change.
- Security: shell injection points, unescaped user input, new file-write paths.

Output a brief impact summary in the terminal **before any edit**.

---

## Phase 2 — Implementation

### 2.1 Coding rules (enforce, do not improvise)
- `set -euo pipefail` in every executable script.
- New library functions get the §6 docblock (Purpose / Args / Output / Notes).
- New awk programs get the §5.1 header comment block.
- Two-file joins use `FILENAME == varname`, not `FNR == NR` (§5.3).
- Conditional appends to argument arrays use `if/then/fi`, never `[[ ]] && cmd` (§4.2).

### 2.2 Local sanity (before validation phase)
- `bash -n bin/<changed>.sh` syntax check.
- Run the changed analyser at least once against the bundled dataset and
  read the output yourself — confirm the new section / value appears and
  the surrounding output did not regress.

### 2.3 Performance-aware coding
- Prefer awk hashes over bash arrays for per-row aggregation.
- Avoid spawning a subshell per row (`while read … do bash -c …`).
- New unbounded data structures (e.g. unique-IP roster) need a documented
  rationale OR a `--top-X N` cap.

---

## Phase 3 — Validation Gate (must pass before docs phase)

### 3.1 Functional regression
```bash
bash tests/run_tests.sh
```
Required outcome: **100% pass**, with the suite-total count strictly
non-decreasing (new tests added, none removed).

### 3.2 New baselines
For every new behaviour added, append at least:
- **Positive baseline** — the new output appears with expected value.
- **Boundary baseline** — empty / zero / no-data scenario behaves cleanly.
- **Negative baseline** — invalid arg / unknown value still exits 1 with message.

Place new tests in the matching Section (A–F) of `tests/run_tests.sh`.

### 3.3 Cross-mode smoke
For analyser changes, manually run at least:
- single date (`--date`)
- range (`--from --to`)
- both regions (`taipei`, `taichung`, `all`)
- one no-data date (e.g. taichung 2026-05-25)
- write modes (`--output FILE`, `--output-dir DIR` via `log_report`)

### 3.4 Static analysis
```bash
make lint    # shellcheck if available
```
If shellcheck is absent, at minimum `bash -n` every changed script.

### 3.5 Exit-code contract
Re-verify §6 of `usage.md`: success = 0, validation error = 1, no-data = 0.

### 3.6 Quality & security gate
- Confirm no new silent error suppression (`2>/dev/null || true`,
  `cmd || true`, untested return values).
- Confirm `init_tmpdir` trap is still installed for any new code path.
- Confirm no unescaped user input flows into `eval`, `bash -c`, or paths.
- Confirm no new runtime dependency beyond `bash gawk sort date mktemp`.

### 3.7 Performance sanity (light-touch)
For non-trivial additions, measure once against the bundled dataset:
```bash
time bash bin/<changed>.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 >/dev/null
```
Report wall-clock in the terminal summary if it changed by > 50%.

---

## Phase 4 — Documentation & Example Sync

### 4.1 Design specs
Update **both** language variants — never leave one stale:
- `docs/design.md`
- `docs/design.zh-TW.md`
Touch the right subsections (§3.x per module, §4 cross-cutting, §6 limits).

### 4.2 CLI reference
Update **both**:
- `docs/usage.md`
- `docs/usage.zh-TW.md`
Reflect the new flag in the option table, add at least one worked example,
and update the embedded sample-output excerpt if the printed sections changed.

### 4.3 In-code documentation
- Update the `usage()` heredoc inside the changed `bin/<script>.sh`.
- Update awk header comments and library docblocks affected.
- If a new convention emerged, add a section to `CLAUDE.md` and link it from
  the relevant skill or doc.

### 4.4 Sample outputs
Regenerate the affected files under `examples/sample-outputs/` with
`NO_COLOR=1`:

```bash
LOG_DIR="./examples/sample-logs/LUNG-CANCER-REPORT-LOG"; export NO_COLOR=1
# regenerate only what the change actually affects
bash bin/analyze_<x>.sh ... > examples/sample-outputs/<file>.txt
# always refresh dependent log_report_*.txt when a sub-module changes
```

Update `examples/sample-outputs/README.md` + `README.zh-TW.md` if the file
list changed.

### 4.5 Driver scripts
Update or add `examples/*.sh` when the change unlocks a new realistic
scenario. Keep scripts self-contained and runnable from a fresh clone.

### 4.6 CHANGELOG
Append to the `[Unreleased]` section using Keep-a-Changelog categories
(`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`).

---

## Phase 5 — Cross-Validation (consistency audit)

Run these checks before staging — fix any divergence, then re-run.

### 5.1 Doc-vs-code alignment
- Every flag in `parse_args` appears in the docs/usage table.
- Every default in `OPT_<X>` matches the default column in docs/usage.
- Output field tables in `docs/design.md` match what the code actually prints.
- Sample-output blocks reflect the real bundled dataset (re-run if unsure).

### 5.2 Bilingual parity
- `README.md` and `README.zh-TW.md` describe the same set of features.
- `docs/design.md` and `docs/design.zh-TW.md` cover the same subsections.
- `docs/usage.md` and `docs/usage.zh-TW.md` carry the same examples.

### 5.3 Link validity
Walk relative markdown links; every target must resolve.

### 5.4 Baseline integrity
Specific numbers in docs (e.g. "ERROR=46, OracleDB=44, Restart=9") must
match the actual `tests/run_tests.sh` baselines. Update both together.

### 5.5 Terminology hygiene
Prefer precise software-engineering vocabulary (e.g. "subprocess
invocation", "two-pass awk join", "Conventional Commits") over vague
phrasing. Avoid inventing brand-tied claims that cannot be verified
(e.g. naming a specific logger framework when the format alone cannot
prove it).

---

## Phase 6 — Commit & Release

### 6.1 Stage explicit paths
Never use `git add -A` or `git add .` in this workflow — secrets, stray
artifacts, or sample-data drift could ride along. Stage by name.

### 6.2 Conventional Commits
Subject format:
```
<type>(<scope>): <imperative summary, ≤ 72 chars>
```
Common scopes: `access` `iis` `errors` `report` `lib` `tests` `docs` `build`.
Common types: `feat` `fix` `refactor` `docs` `test` `chore`.

Body (heredoc-quoted, blank line after subject):
- One paragraph WHY.
- A short bullet list of touched layers (impl / tests / docs / samples).
- Numerics that anchor the change (e.g. "Tests: 108/108").

### 6.3 Versioning decision
| Change kind                         | Version bump |
|-------------------------------------|--------------|
| Backwards-compatible feature        | MINOR        |
| Backwards-incompatible behaviour    | MAJOR        |
| Bug fix / docs / refactor (no API)  | PATCH        |

Apply the bump only when the user asks for a release; otherwise leave
changes under `[Unreleased]` in `CHANGELOG.md`.

### 6.4 Tag & GitHub release (only when releasing)
```bash
git tag -a vX.Y.Z -m "log-parse vX.Y.Z — <one-line>"
gh release create vX.Y.Z --title "..." --notes-file ...   # or --notes inline
```

### 6.5 Push
```bash
git push origin main
git push origin vX.Y.Z   # if tagged
```

---

## Phase 7 — Terminal Execution Summary (no files written)

Print to terminal, one block, sectioned. Suggested layout:

```
═══════════════════════════════════════════════════════════════════
  log-parse — Workflow Summary
═══════════════════════════════════════════════════════════════════
  Request          : <restated user ask>
  Impact layers    : bin / lib / docs / tests / examples
  Files touched    : <N> (list)
  Tests            : <PASS>/<TOTAL> passed
  Lint             : OK | skipped (shellcheck absent)
  Perf delta       : negligible | +X% on <command>
  Docs in sync     : design.md, design.zh-TW.md, usage.md, usage.zh-TW.md,
                     CLAUDE.md (if touched), CHANGELOG.md
  Samples updated  : <list of regenerated files>
  Commit           : <hash> — <subject>
  Push             : origin/main → ok | (not pushed; user requested local-only)
  Release          : vX.Y.Z (URL) | n/a (Unreleased)
  Next suggestion  : <e.g. tag a release, run gh release create, etc.>
═══════════════════════════════════════════════════════════════════
```

No persistent artefact, no follow-up file. The summary lives only in the
chat transcript.

---

## Quick reference checklist

- [ ] **Phase 1** Impact map printed before edits
- [ ] **Phase 2** Code follows §4 / §5 / §6 conventions of CLAUDE.md
- [ ] **Phase 3** Tests 100% (+ new baselines), lint clean, quality gate ok
- [ ] **Phase 4** Both EN & zh-TW docs updated; samples regenerated; CHANGELOG entry
- [ ] **Phase 5** Cross-validation: flags, fields, numbers, links, bilingual parity
- [ ] **Phase 6** Conventional Commit; version decision recorded
- [ ] **Phase 7** Terminal summary printed, no extra files created
