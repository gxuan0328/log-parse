#!/usr/bin/env bash
# lib/common.sh — Shared utilities for the log-parse toolkit.
#
# Provides: dependency gate, ANSI colour constants, levelled logging,
#           tmpdir lifecycle, small misc helpers (file_or_empty, count_lines,
#           join_arr).
#
# Conventions:
#   - Source this file; do not execute directly.
#   - All log output goes to STDERR so STDOUT remains clean for the report.
#   - WORK_TMPDIR / LOG_LEVEL are the only documented global state.

# ---------------------------------------------------------------------------
# Script root resolution (robust whether sourced from bin/ or examples/)
# ---------------------------------------------------------------------------
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "${_LIB_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Dependency gate
# ---------------------------------------------------------------------------

# require_cmds CMD...
#   Purpose : Verify every named command is on PATH; abort otherwise.
#   Args    : One or more command names (e.g. gawk sort date).
#   Exit    : 1 (with message to stderr) when any command is missing.
#   Usage   : Called once at module load time so scripts fail fast on
#             environments missing GNU coreutils / gawk rather than producing
#             cryptic mid-pipeline errors.
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: missing required commands: ${missing[*]}" >&2
        exit 1
    fi
}

# Hard requirement for every script that sources this library.
# gawk = field extraction & joins; sort = ordering; date = range generation.
require_cmds gawk sort date

# ---------------------------------------------------------------------------
# Colour codes (auto-disabled when stdout is not a TTY or NO_COLOR is set)
# ---------------------------------------------------------------------------
# References the standard NO_COLOR convention (https://no-color.org/).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_RED='\033[0;31m'
    C_YELLOW='\033[0;33m'
    C_GREEN='\033[0;32m'
    C_CYAN='\033[0;36m'
    C_GREY='\033[0;90m'
else
    C_RESET='' C_BOLD='' C_RED='' C_YELLOW='' C_GREEN='' C_CYAN='' C_GREY=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# LOG_LEVEL gates log_debug; INFO/WARN/ERROR always print.
LOG_LEVEL="${LOG_LEVEL:-INFO}"   # DEBUG | INFO | WARN | ERROR

# _log LEVEL COLOR MSG…
#   Internal helper. Emits "[HH:MM:SS][LEVEL] MSG" to STDERR with colour.
_log() {
    local level="$1"; shift
    local color="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%H:%M:%S')
    printf "%b[%s][%s]%b %s\n" "$color" "$ts" "$level" "$C_RESET" "$msg" >&2
}

# log_debug MSG  — emitted only when LOG_LEVEL=DEBUG (triggered by -v flag).
# Trailing `|| true` keeps `set -e` happy when the debug branch is skipped.
log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && _log DEBUG "$C_GREY" "$@" || true; }
log_info()  { _log INFO  "$C_CYAN"   "$@"; }
log_warn()  { _log WARN  "$C_YELLOW" "$@"; }
log_error() { _log ERROR "$C_RED"    "$@"; }

# die MSG  — log at ERROR level and exit 1. Used at validation boundaries.
die() {
    log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Temporary directory lifecycle
# ---------------------------------------------------------------------------
# WORK_TMPDIR is set by init_tmpdir and cleaned by _cleanup_tmpdir on EXIT.
# All intermediate artifacts (combined per-server logs, join inputs, TSV
# intermediate files) live under this directory.
WORK_TMPDIR=""

# init_tmpdir
#   Purpose : Create a per-process tmpdir and arm cleanup trap.
#   Args    : none.
#   Side    : Mutates WORK_TMPDIR; installs EXIT/INT/TERM trap.
#   Notes   : Subsequent calls would replace WORK_TMPDIR without unlinking
#             the previous one — by convention each CLI calls this exactly
#             once in main().
init_tmpdir() {
    WORK_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/log_analyze.XXXXXX")
    trap '_cleanup_tmpdir' EXIT INT TERM
    log_debug "tmpdir: $WORK_TMPDIR"
}

# _cleanup_tmpdir — internal; trap target.
_cleanup_tmpdir() {
    [[ -n "$WORK_TMPDIR" && -d "$WORK_TMPDIR" ]] && rm -rf "$WORK_TMPDIR"
}

# ---------------------------------------------------------------------------
# Small utility helpers
# ---------------------------------------------------------------------------

# file_or_empty FILE
#   Purpose : Echo the path if FILE exists and has non-zero size; "" otherwise.
#   Used    : Guards that want to fall through cleanly on missing input.
file_or_empty() { [[ -s "$1" ]] && echo "$1" || echo ""; }

# count_lines FILE
#   Purpose : Count lines in FILE; returns 0 for non-existent / empty.
#   Why awk : `wc -l` returns whitespace-padded output and a non-zero exit
#             code with `--files0-from`; awk avoids both pitfalls and matches
#             the codebase's "awk for all extraction" convention.
count_lines() {
    if [[ -s "$1" ]]; then
        gawk 'END{print NR}' "$1"
    else
        echo 0
    fi
}

# join_arr DELIM ITEM…
#   Purpose : Join ITEMs with DELIM. Equivalent to Python's ",".join(...).
#   Args    : DELIM (single char preferred), then any number of items.
join_arr() {
    local delim="$1"; shift
    local IFS="$delim"
    echo "$*"
}

# ---------------------------------------------------------------------------
# Fail-fast validators
# ---------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Purpose : Fail-fast guard that VALUE is a non-negative integer (0 allowed).
# Args    : $1 NAME (flag label for the message), $2 VALUE (candidate).
# Output  : nothing on success.
# Returns : never returns on failure — exits via die().
# Notes   : Use for --top / --days / --slow-*-ms.
# ----------------------------------------------------------------------------
assert_uint() { case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer: '$2'";; esac; }

# ----------------------------------------------------------------------------
# Purpose : Fail-fast guard that VALUE is in the ALLOWED set.
# Args    : $1 NAME, $2 VALUE, $3.. ALLOWED tokens.
# Output  : nothing on success.
# Returns : never returns on failure — exits via die().
# Notes   : Use for --format text|tsv|csv.
# ----------------------------------------------------------------------------
assert_enum() { local name="$1" val="$2"; shift 2; local a
                for a in "$@"; do if [[ "$val" == "$a" ]]; then return 0; fi; done
                die "$name must be one of: $* (got '$val')"; }
