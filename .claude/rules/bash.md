---
paths:
  - "bin/**/*.sh"
  - "lib/**/*.sh"
  - "tests/**/*.sh"
  - "examples/**/*.sh"
---

# Bash conventions

Loaded when editing any shell script. Pairs with `awk.md` for analyser
files and `library.md` for `lib/`.

## Script scaffold (mandatory header)

```bash
#!/usr/bin/env bash
# bin/<name>.sh
# ----------------------------------------------------------------------------
# <one-line summary>
# <multi-line context: inputs, outputs, why it exists>
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"   # if dates
source "${SCRIPT_DIR}/../lib/csv_utils.sh"    # if log parsing
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"    # if rendering
```

## The `[[ cond ]] && cmd` footgun

Inside a function, this returns 1 when `cond` is false. As the **last
statement** of a function it makes the function return 1, which under
`set -e` aborts the caller. Always use `if/then/fi` in function bodies:

```bash
# WRONG — function returns 1 when $verbose is empty
build_args() {
    args=("--log-dir" "$dir")
    [[ -n "$verbose" ]] && args+=("--verbose")
}

# RIGHT
build_args() {
    args=("--log-dir" "$dir")
    if [[ -n "$verbose" ]]; then args+=("--verbose"); fi
}
```

Compound `[[ ]] && cmd` is acceptable at top-level (bash exempts simple-list
components from `set -e` mid-execution), but treat with suspicion in any
function whose return value is consumed.

## Argument forwarding: arrays, never strings

```bash
args=()
args+=("--log-dir" "$OPT_LOG_DIR")
if [[ -n "$OPT_DATE" ]]; then args+=("--date" "$OPT_DATE"); fi
"$bin" "${args[@]}"
```

Never `echo` + word-split — paths with spaces break.

## Quoting

- Quote every expansion: `"$var"` (except in arithmetic).
- Wrap with literal: `"${path}_${date}.txt"`.
- Safe fallback: `${var:-default}`.
- Integer compare: `(( x > 0 ))`, not `[[ "$x" -gt 0 ]]`.

## Temp files

- Allocate via `init_tmpdir` (sets `$WORK_TMPDIR`, installs EXIT/INT/TERM trap).
- Always write under `${WORK_TMPDIR}/descriptive_name.tsv`.
- Never hardcode `/tmp/foo`.

## Logging helpers (from `lib/common.sh`)

| Helper       | Use for                                                |
|--------------|--------------------------------------------------------|
| `log_debug`  | Verbose-only details (gated by `LOG_LEVEL=DEBUG`, `-v`).|
| `log_info`   | Normal progress (one per region, one per stage).       |
| `log_warn`   | Recoverable issues (missing per-server dir, no data).  |
| `log_error`  | Fatal context; usually paired with `exit 1`.           |
| `die "msg"`  | Shortcut for `log_error + exit 1`.                     |

All log helpers write to **stderr**. Never `echo "ERROR: …" >&2` directly.
