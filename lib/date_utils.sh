#!/usr/bin/env bash
# lib/date_utils.sh — Date range generation and filename mapping helpers.
#
# Requires GNU date (Linux). Source this file; do not execute directly.
#
# Public surface:
#   validate_date DATE         — abort if not YYYY-MM-DD
#   today                      — print today (YYYY-MM-DD)
#   local_hour                 — print current host-clock hour 0-23 (no leading zero)
#   date_add BASE OFFSET       — add OFFSET days (may be negative)
#   date_diff END START        — integer day count
#   resolve_interval [flags]   — mutex interval validator; populates INTERVAL_ARGS
#   build_date_list [flags]    — emit one date per line (the workhorse)
#   date_to_iis_file DATE      — DATE → u_exYYMMDD.log
#   date_to_app_dir DATE       — DATE → DATE (kept for API symmetry)

# ---------------------------------------------------------------------------
# Interval-mutex validator — cross-call global
# ---------------------------------------------------------------------------

# INTERVAL_ARGS — sanctioned cross-call global (documented like WORK_TMPDIR).
# Populated by resolve_interval; consumed via "${INTERVAL_ARGS[@]}".
INTERVAL_ARGS=()

# resolve_interval --today T --date D --from F --to TO --days-set S --days N
#   Purpose : Enforce interval-flag mutual exclusion (D3), pair --from/--to,
#             map --today to a single --date, and emit the ONE canonical
#             selector for build_date_list into global INTERVAL_ARGS.
#   Args    : --today T (0|1)  --date D (YYYY-MM-DD|"")
#             --from F (YYYY-MM-DD|"")  --to TO (YYYY-MM-DD|"")
#             --days-set S (0|1 explicit --days sentinel)  --days N (int).
#   Output  : nothing on stdout; mutates global INTERVAL_ARGS.
#   Returns / Side effects : never returns on conflict — exits via die().
#   Errors / Notes : --from/--to counted as ONE selector. --days fallback only
#             when S=0. if/then/fi per bash.md; n=$((n+1)) per bash.md (no (( ++ ))).
resolve_interval() {
    local today_f=0 date_v="" from_v="" to_v="" days_set=0 days_v=7
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --today)    today_f="$2"; shift 2 ;;
            --date)     date_v="$2";  shift 2 ;;
            --from)     from_v="$2";  shift 2 ;;
            --to)       to_v="$2";    shift 2 ;;
            --days-set) days_set="$2";shift 2 ;;
            --days)     days_v="$2";  shift 2 ;;
            *) die "resolve_interval: unknown arg '$1'" ;;
        esac
    done
    if [[ -n "$from_v" && -z "$to_v" ]]; then die "--from requires --to"; fi
    if [[ -n "$to_v"   && -z "$from_v" ]]; then die "--to requires --from"; fi
    local n=0
    if (( today_f ));      then n=$((n+1)); fi
    if [[ -n "$date_v" ]]; then n=$((n+1)); fi
    if [[ -n "$from_v" ]]; then n=$((n+1)); fi
    if (( days_set ));     then n=$((n+1)); fi
    if (( n > 1 )); then
        die "interval flags are mutually exclusive (priority --date > --from/--to > --today > --days): choose exactly ONE (got $n)"
    fi
    if (( today_f )); then date_v="$(today)"; fi
    INTERVAL_ARGS=()
    if   [[ -n "$date_v" ]]; then INTERVAL_ARGS=(--date "$date_v")
    elif [[ -n "$from_v" ]]; then INTERVAL_ARGS=(--from "$from_v" --to "$to_v")
    else                          INTERVAL_ARGS=(--days "$days_v")
    fi
}

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

# local_hour  — Print the current host-clock hour as an integer 0-23, no leading zero.
#   Purpose : Return the current hour (0-23) from the host clock without a leading
#             zero, avoiding the octal-interpretation trap that %-H addresses on GNU
#             date (08 and 09 are not valid octal; the %-H format strips the pad).
#   Args    : none.
#   Output  : integer 0-23 on stdout.
#   Returns / Side effects : none.
#   Notes   : Reads the host clock deliberately — the same clock today() uses to
#             select UTC+8-named log directories — so the overview chart gate
#             (today() comparison) and the today-cap (local_hour - 1) always read
#             the SAME clock and can never desync.
#             PRECONDITION (inherited, not introduced): the host clock runs in the
#             business reference TZ UTC+8 (the same assumption today() already
#             makes).  On a non-UTC+8 host run with TZ=Asia/Taipei, which shifts
#             today() AND local_hour() together so the gate fires and the cap is
#             correct.  We deliberately do NOT pin only local_hour to Asia/Taipei;
#             that would make the cap UTC+8 while the gate/today() stay host-local,
#             desyncing them on a UTC host.
#             LOG_PARSE_NOW_HOUR — override for deterministic today-cap tests.
local_hour() { echo "${LOG_PARSE_NOW_HOUR:-$(date '+%-H')}"; }

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

# IIS_UTC_OFFSET_HOURS — IIS logs timestamp in UTC+0; business/reference TZ is
# UTC+8 (access CSV + .NET app logs). A local day D = UTC [D-1 16:00, D 16:00).
# 16 = 24 - IIS_UTC_OFFSET_HOURS. Single source for the IIS timezone correction.
IIS_UTC_OFFSET_HOURS=8
IIS_TZ_CUTOFF_UTC=$(printf '%02d:00:00' $(( 24 - IIS_UTC_OFFSET_HOURS )))   # 16:00:00

# iis_utc_window START END
#   Purpose : Map a local (UTC+8) inclusive date range to the half-open UTC
#             datetime bounds selecting exactly the IIS rows whose LOCAL date
#             falls in [START,END]. Keep a row when LO <= ($1" "$2) < HI.
#   Args    : START — YYYY-MM-DD (local UTC+8); END — YYYY-MM-DD (local UTC+8).
#   Output  : "LO|HI" where LO,HI are "YYYY-MM-DD HH:MM:SS" (UTC) on stdout.
#   Returns / Side effects : 0; pure stdout.
#   Notes   : Uses date_add from this file. IIS_TZ_CUTOFF_UTC must be sourced first.
iis_utc_window() {
    local start="$1" end="$2" lo_date
    lo_date=$(date_add "$start" -1)
    printf '%s %s|%s %s\n' "$lo_date" "$IIS_TZ_CUTOFF_UTC" "$end" "$IIS_TZ_CUTOFF_UTC"
}

# date_to_app_dir DATE → DATE
#   Purpose : The .NET application's per-day subdir is named YYYY-MM-DD
#             verbatim. Kept as a function for symmetry with date_to_iis_file
#             so call sites read uniformly.
date_to_app_dir() { echo "$1"; }
