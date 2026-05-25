#!/usr/bin/env bash
# lib/date_utils.sh — Date range generation and filename mapping helpers.
#
# Requires GNU date (Linux). Source this file; do not execute directly.
#
# Public surface:
#   validate_date DATE         — abort if not YYYY-MM-DD
#   today                      — print today (YYYY-MM-DD)
#   date_add BASE OFFSET       — add OFFSET days (may be negative)
#   date_diff END START        — integer day count
#   build_date_list [flags]    — emit one date per line (the workhorse)
#   date_to_iis_file DATE      — DATE → u_exYYMMDD.log
#   date_to_app_dir DATE       — DATE → DATE (kept for API symmetry)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# validate_date DATE
#   Purpose : Abort (via die) when DATE is not a `date -d`-parseable string.
#   Args    : DATE — any string the caller offered as a date.
#   Side    : Calls die on failure (exit 1).
validate_date() {
    local d="$1"
    if ! date -d "$d" '+%Y-%m-%d' &>/dev/null; then
        die "Invalid date: '$d' (expected YYYY-MM-DD)"
    fi
}

# ---------------------------------------------------------------------------
# Date arithmetic
# ---------------------------------------------------------------------------

# today  — Print today in YYYY-MM-DD (local time).
today() { date '+%Y-%m-%d'; }

# date_add BASE OFFSET
#   Purpose : Add OFFSET days (signed) to BASE; print resulting YYYY-MM-DD.
#   Args    : BASE — YYYY-MM-DD; OFFSET — integer (can be negative).
date_add() { date -d "$1 $2 days" '+%Y-%m-%d'; }

# date_diff END START
#   Purpose : Integer day count (END − START). Negative when END precedes START.
date_diff() { echo $(( ( $(date -d "$1" +%s) - $(date -d "$2" +%s) ) / 86400 )); }

# ---------------------------------------------------------------------------
# Range generation — single source of truth for all CLIs
# ---------------------------------------------------------------------------

# build_date_list [--days N] [--from DATE] [--to DATE] [--date DATE]
#   Purpose : Emit one YYYY-MM-DD per line for the requested range.
#   Args    : Subset of flags below. Unknown flags are silently skipped so
#             callers can use `${OPT_VAR:+--flag "$OPT_VAR"}` patterns safely.
#   Priority: --date  >  --from/--to  >  --days
#             (when --date is given the function returns immediately).
#   Range   : Inclusive on both ends. When only --from is given, --to defaults
#             to today; when neither is given, --days N selects the last N
#             days ending today.
#   Errors  : Invalid date → die; --from after --to → die.
build_date_list() {
    local opt_days=7
    local opt_from="" opt_to="" opt_date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)  opt_days="$2";  shift 2 ;;
            --from)  opt_from="$2";  shift 2 ;;
            --to)    opt_to="$2";    shift 2 ;;
            --date)  opt_date="$2";  shift 2 ;;
            *) shift ;;
        esac
    done

    local start end

    # Single-date short-circuit
    if [[ -n "$opt_date" ]]; then
        validate_date "$opt_date"
        echo "$opt_date"
        return
    fi

    # Resolve start
    if [[ -n "$opt_from" ]]; then
        validate_date "$opt_from"
        start="$opt_from"
    else
        # Last N days ending today: today − (N − 1)
        start=$(date_add "$(today)" "$(( -opt_days + 1 ))")
    fi

    # Resolve end
    if [[ -n "$opt_to" ]]; then
        validate_date "$opt_to"
        end="$opt_to"
    else
        end=$(today)
    fi

    if [[ "$(date -d "$start" +%s)" -gt "$(date -d "$end" +%s)" ]]; then
        die "--from ($start) must not be after --to ($end)"
    fi

    # Emit inclusive range, day by day.
    local cur="$start"
    while [[ "$(date -d "$cur" +%s)" -le "$(date -d "$end" +%s)" ]]; do
        echo "$cur"
        cur=$(date_add "$cur" 1)
    done
}

# ---------------------------------------------------------------------------
# Filename mapping
# ---------------------------------------------------------------------------

# date_to_iis_file DATE  → u_exYYMMDD.log
#   Purpose : IIS rotates daily into u_ex<2-digit year><month><day>.log.
#             Convert from internal YYYY-MM-DD to that filename convention.
date_to_iis_file() {
    date -d "$1" '+u_ex%y%m%d.log'
}

# date_to_app_dir DATE → DATE
#   Purpose : The .NET application's per-day subdir is named YYYY-MM-DD
#             verbatim. Kept as a function for symmetry with date_to_iis_file
#             so call sites read uniformly.
date_to_app_dir() { echo "$1"; }
