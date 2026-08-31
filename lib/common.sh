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
# curl and base64 are DELIBERATELY excluded from this unconditional set --
# they are optional, needed only by --notify, and gated lazily inside
# lib/notify_utils.sh (notify_preflight), never here (see docs/design.md §4.9).
require_cmds gawk sort date

# ---------------------------------------------------------------------------
# Colour codes (auto-disabled when stdout is not a TTY or NO_COLOR is set)
# ---------------------------------------------------------------------------
# References the standard NO_COLOR convention (https://no-color.org/).

# fmt_set_color_state
#   Purpose : (Re)derive every C_* global from the CURRENT NO_COLOR + TTY state.
#             Lets persist_views blank color for file writes and restore it for
#             the console mirror without rewriting individual helpers.
#   Args    : none.
#   Output  : none.
#   Returns / Side effects : assigns C_RESET C_BOLD C_RED C_YELLOW C_GREEN
#             C_CYAN C_GREY from the live environment.
#   Errors / Notes : pure assignment; never fails.
fmt_set_color_state() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET='\033[0m';    C_BOLD='\033[1m'
        C_RED='\033[0;31m';   C_YELLOW='\033[0;33m'
        C_GREEN='\033[0;32m'; C_CYAN='\033[0;36m';  C_GREY='\033[0;90m'
    else
        C_RESET='' C_BOLD='' C_RED='' C_YELLOW='' C_GREEN='' C_CYAN='' C_GREY=''
    fi
}

# Initialise color globals once at source time; re-callable by persist_views.
fmt_set_color_state

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

# ----------------------------------------------------------------------------
# Purpose : Read test_hosts.conf and emit its entry set as one space-joined
#           string for passing to gawk via -v th_set=... . Each entry is either
#           an exact IPv4 (e.g. 192.168.117.90) or an IPv4/prefix CIDR block
#           (e.g. 192.168.0.0/16); TH_FILTER_FUNC's th_skip() matches a client
#           IP against both. Never regex/substring.
# Args    : $1 CONF — path to test_hosts.conf.
# Output  : space-joined entry string on stdout (empty string if file has none).
# Returns : 0; dies (fail-fast) if CONF is unreadable OR any entry is neither a
#           valid IPv4 nor a valid IPv4 CIDR (a per-line diagnostic is printed
#           to stderr for every offending entry before aborting).
# Notes   : Strips inline/whole-line '#' comments, blank lines, and surrounding
#           whitespace/CR. Single source for the test-host set. First true
#           shared loader in common.sh (mirrors assert_enum/die placement, NOT
#           the per-bin load_regions).
# ----------------------------------------------------------------------------
load_test_hosts() {
    local conf="$1" out
    if [[ ! -f "$conf" ]]; then die "test-hosts config not found: $conf"; fi
    # Validate every entry as an exact IPv4 or an IPv4/prefix CIDR, then emit
    # them space-joined. gawk reports each malformed entry to stderr and exits 2
    # so a typo fails loudly at load, never silently at match time (§2 rule 1).
    out="$(gawk '
        function octet_ok(o) { return o ~ /^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$/ }
        function ipv4_ok(ip,   a) {
            return (split(ip, a, ".") == 4) &&
                   octet_ok(a[1]) && octet_ok(a[2]) && octet_ok(a[3]) && octet_ok(a[4])
        }
        function entry_ok(tok,   sl) {
            sl = index(tok, "/")
            if (sl == 0) return ipv4_ok(tok)
            return ipv4_ok(substr(tok, 1, sl - 1)) &&
                   (substr(tok, sl + 1) ~ /^(3[0-2]|[12]?[0-9])$/)
        }
        { entry = $0; sub(/#.*/, "", entry); gsub(/[ \t\r]+/, "", entry) }
        entry == "" { next }
        !entry_ok(entry) {
            printf "[test_hosts.conf] invalid entry at line %d: %s\n", NR, $0 > "/dev/stderr"
            bad = 1; next
        }
        { ips = (ips == "" ? entry : ips " " entry) }
        END { if (bad) exit 2; print ips }
    ' "$conf")" || die "test_hosts.conf has invalid entries (see above): $conf"
    printf '%s\n' "$out"
}

# TH_FILTER_FUNC — gawk snippet implementing the test-host membership filter.
# Prepend to any gawk program that filters by client IP. Requires the program
# to set, via -v: _th_mode=exclude|only|all and th_set="entry entry ...", where
# each entry is an exact IPv4 or an IPv4/prefix CIDR block (as emitted by
# load_test_hosts). Call th_init(th_set) in BEGIN; then `if (th_skip(ip)) next`
# at the read stage. All private state is _th-prefixed to avoid colliding with
# the host program's globals.
TH_FILTER_FUNC='
# _th_ip2int(ip) -> the 32-bit integer for a dotted IPv4, or -1 if not 4 octets.
function _th_ip2int(ip,   a) {
    if (split(ip, a, ".") != 4) return -1
    return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4]
}
# th_init(set_str): partition the space-joined token string into the exact-IP
# set _th[] and _th_nc CIDR ranges _th_lo[]/_th_hi[]. A token containing "/" is
# a CIDR network/prefix (prefix 0-32); every other token is an exact IP. A CIDR
# spans [base, base + 2^(32-prefix) - 1]; host bits of a non-canonical network
# (e.g. 192.168.5.9/16) are cleared via integer division so it still covers the
# whole block.
function th_init(set_str,   n, i, a, tok, sl, blk) {
    _th_nc = 0
    n = split(set_str, a, " ")
    for (i = 1; i <= n; i++) {
        tok = a[i]
        if (tok == "") continue
        sl = index(tok, "/")
        if (sl == 0) { _th[tok] = 1; continue }
        blk = 2 ^ (32 - (substr(tok, sl + 1) + 0))
        _th_nc++
        _th_lo[_th_nc] = int(_th_ip2int(substr(tok, 1, sl - 1)) / blk) * blk
        _th_hi[_th_nc] = _th_lo[_th_nc] + blk - 1
    }
}
# _th_match(ip) -> 1 if ip is an exact member OR falls inside any CIDR block.
function _th_match(ip,   v, i) {
    if (ip in _th) return 1
    if (_th_nc) {
        v = _th_ip2int(ip)
        if (v >= 0)
            for (i = 1; i <= _th_nc; i++)
                if (v >= _th_lo[i] && v <= _th_hi[i]) return 1
    }
    return 0
}
# th_skip(ip) -> 1 = DROP this record, 0 = KEEP, per mode.
#   exclude (default): drop test hosts; only: keep ONLY test hosts; all: keep all.
function th_skip(ip) {
    if (_th_mode == "all")  return 0
    if (_th_mode == "only") return !_th_match(ip)
    return _th_match(ip)            # exclude (default)
}
'
