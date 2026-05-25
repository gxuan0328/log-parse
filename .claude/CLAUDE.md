# CLAUDE.md — log-parse project conventions

> Core context loaded into every session. Detailed rules live in
> `.claude/rules/` and load **only when** you open matching files —
> see §4 for the index. User-level (`~/.claude/CLAUDE.md`) instructions
> override this file.

---

## 1. Project identity

`log-parse` is a **read-only** bash + gawk toolkit that analyses three
log families (access CSV, IIS W3C, .NET app logs) for the
LUNG-CANCER-REPORT system across two regions × three servers each.

Unix philosophy: each script does one job, composes via pipes and exit
codes, prints reports to stdout, logs to stderr.

NOT a daemon. NOT a database. NOT a service. Do not introduce one.

---

## 2. Core philosophy (the five rules)

1. **Fail fast, loud** — `set -euo pipefail`; abort at boundaries with
   `die "…"`; no silent suppression.
2. **Single source of truth** — date math in `date_utils`, regions in
   `regions.conf`, parsing in `csv_utils`, formatting in `fmt_utils`.
   Don't reinvent.
3. **stdout = report, stderr = log** — pipe-safe by construction.
4. **Safe defaults, explicit flags** — `region=all`, `days=7`, output to
   stdout. `bash bin/log_report.sh --log-dir …` alone yields a useful report.
5. **Heavy lifting in gawk** — joins / group-bys / filters → gawk;
   orchestration → bash.

---

## 3. Repository layout

| Path        | Purpose                                                              |
|-------------|----------------------------------------------------------------------|
| `bin/`      | CLI entry points; one file = one command.                            |
| `lib/`      | Sourced-only helpers (common, date_utils, csv_utils, fmt_utils).     |
| `conf/`     | `regions.conf` — region ↔ server mapping read by `load_regions`.     |
| `tests/`    | `run_tests.sh` — single-file regression suite (currently 108 tests). |
| `docs/`     | `design.md` + `usage.md` (+ zh-TW). Update both languages together.  |
| `examples/` | `sample-logs/` (dataset), `sample-outputs/` (expected reports), `*.sh`.|
| `.claude/`  | Project rules (this file + `rules/` + `skills/`).                    |

---

## 4. Rule index (path-scoped, auto-loaded)

Detailed conventions live in `.claude/rules/`. Each file declares a glob
in its frontmatter and is loaded **only** when Claude reads a matching file.

| When editing…                              | Rule file                              |
|--------------------------------------------|----------------------------------------|
| `bin/**`, `lib/**`, `tests/**`, `examples/**` `.sh` | `.claude/rules/bash.md`        |
| Any file containing a gawk program         | `.claude/rules/awk.md`                 |
| Functions inside `lib/*.sh`                | `.claude/rules/library.md`             |
| `tests/run_tests.sh`                       | `.claude/rules/testing.md`             |
| `docs/**`, `README*.md`, `CHANGELOG.md`    | `.claude/rules/documentation.md`       |

---

## 5. Commit conventions

[Conventional Commits](https://www.conventionalcommits.org/):

```
feat(<scope>): <imperative summary, ≤ 72 chars>
fix(<scope>): …
docs(<scope>): …
test(<scope>): …
refactor(<scope>): …
chore(<scope>): …
```

Scopes: `access`, `iis`, `errors`, `report`, `lib`, `tests`, `docs`,
`build`. Body explains **why**, lists touched layers, anchors with
numerics (e.g. `Tests: 108/108`).

---

## 6. Hard "no"s

- ❌ New runtime dependencies beyond `bash gawk sort date mktemp`.
- ❌ Silent fallbacks (`2>/dev/null || true` without a justifying comment).
- ❌ `git add -A` / `git add .` in helper scripts — stage explicit paths.
- ❌ Interactive prompts in CLI paths.
- ❌ Emojis in source / docstrings / commit messages.
  (Report-text exceptions: `▶ ■` are intentional for visual scanning.)
- ❌ Reinventing date math / region loading / CSV extraction / formatting.

---

## 7. Auto-triggered workflow (MANDATORY)

**Trigger**: any request that modifies files under `bin/`, `lib/`,
`conf/`, `tests/`, `docs/`, `examples/`, `.claude/`, or root project
files (`README*`, `CHANGELOG.md`, `Makefile`, `LICENSE`, `.gitignore`,
`.gitattributes`, `.editorconfig`), OR asks for a tag / release / remote push.

**Skip**: strictly read-only conversations ("explain X", "show me Y",
"summarise CHANGELOG").

**On trigger** — invoke the skill at
[`skills/feature-workflow/SKILL.md`](skills/feature-workflow/SKILL.md).
It enforces seven phases (pre-dev analysis → implementation →
validation → doc sync → cross-validation → commit/release → terminal
summary). Override only on explicit user instruction; in the terminal
summary state which phases were skipped and why.
