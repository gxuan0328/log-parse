---
paths:
  - "lib/**/*.sh"
---

# Library function checklist

Loaded when editing `lib/common.sh`, `lib/date_utils.sh`,
`lib/csv_utils.sh`, or `lib/fmt_utils.sh`. Library files are **sourced
only** — they must NOT call `main "$@"`.

## Mandatory docblock for every public function

Five required fields. Omit a field only when truly N/A (state so).

```bash
# count_lines FILE
#   Purpose : Count lines in FILE; returns 0 for non-existent / empty.
#   Args    : FILE — path.
#   Output  : line count on stdout.
#   Returns / Side effects : none.
#   Notes   : Uses gawk to dodge wc's whitespace padding quirk.
count_lines() { ... }
```

| Field                    | Captures                                                   |
|--------------------------|------------------------------------------------------------|
| Purpose                  | One-line statement of intent.                              |
| Args                     | Positional names + type; `[OPT]` for optional.             |
| Output                   | What's printed and on which stream (stdout / stderr).      |
| Returns / Side effects   | Mutated globals (e.g. `WORK_TMPDIR`), files written.       |
| Errors / Notes           | Failure modes; non-obvious gotchas; cross-references.      |

## Library design rules

- **Pure where possible** — operate on arguments, return via stdout / exit code.
- **Document mutated globals** — `WORK_TMPDIR`, `LOG_LEVEL`,
  `REGION_IDS[]`, `REGION_NAMES[]`, `REGION_APIS[]`, `REGION_APPS[]` are
  the only sanctioned cross-call state.
- **No new globals without a comment** — explain why a local won't do.
- **Never call `exit`** except via `die` (callers may want to recover).
- **Never call `init_tmpdir` from a library** — it's the CLI's job.
