#!/usr/bin/env bash
# lib/fmt_utils.sh — Text-report formatting primitives.
#
# All helpers honour the colour codes defined in common.sh (auto-disabled when
# stdout is not a TTY or NO_COLOR is set). Source this file; do not execute.
#
# Layout conventions:
#   h1  → top-level report header  (=== blocks ===)
#   h2  → per-region / per-server section (▶ prefix)
#   h3  → sub-section inside h2 (■ prefix, indented)
#   kv  → label / value row, 40-char label column, indented 2 spaces

# ---------------------------------------------------------------------------
# Separator constants — exposed for callers that want bare rules
# ---------------------------------------------------------------------------
FMT_SEP1='========================================================================'
FMT_SEP2='------------------------------------------------------------------------'
FMT_SEP3='  - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -'

# ---------------------------------------------------------------------------
# Section headers
# ---------------------------------------------------------------------------

# fmt_h1 TITLE — top-level header, wrapped in === rules with a blank lead-in.
fmt_h1() {
    echo ""
    echo "$FMT_SEP1"
    printf "  %b%s%b\n" "$C_BOLD" "$1" "$C_RESET"
    echo "$FMT_SEP1"
}

# fmt_h2 TITLE — section header (e.g. per server), ▶ prefix and --- rule.
fmt_h2() {
    echo ""
    printf "%b▶ %s%b\n" "$C_BOLD" "$1" "$C_RESET"
    echo "$FMT_SEP2"
}

# fmt_h3 TITLE — sub-section header, ■ prefix, cyan, 4-space indent.
fmt_h3() {
    echo ""
    printf "    %b■ %s%b\n" "$C_CYAN" "$1" "$C_RESET"
}

fmt_sep()  { echo "$FMT_SEP2"; }
fmt_sep3() { echo "$FMT_SEP3"; }

# ---------------------------------------------------------------------------
# Key-value rows
# ---------------------------------------------------------------------------

# fmt_kv KEY VALUE [INDENT]
#   Purpose : Emit "  <KEY padded to 40><VALUE>".
#   Args    : KEY — label; VALUE — string (or number); INDENT — leading
#             spaces (default 2).
fmt_kv() {
    local key="$1" val="$2" indent="${3:-2}"
    printf "%${indent}s%-40s%s\n" "" "$key" "$val"
}

# fmt_kv_color KEY VALUE COLOR [INDENT]
#   Purpose : Same as fmt_kv but the value is wrapped in COLOR…RESET so the
#             eye can land on critical numbers (e.g. red 5xx counts).
fmt_kv_color() {
    local key="$1" val="$2" color="$3" indent="${4:-2}"
    printf "%${indent}s%-40s%b%s%b\n" "" "$key" "$color" "$val" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Inline status helpers (used inside larger printf strings)
# ---------------------------------------------------------------------------

fmt_ok()   { printf "%b%s%b" "$C_GREEN"  "$1" "$C_RESET"; }
fmt_warn() { printf "%b%s%b" "$C_YELLOW" "$1" "$C_RESET"; }
fmt_err()  { printf "%b%s%b" "$C_RED"    "$1" "$C_RESET"; }

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

# fmt_table_header COL_WIDTH COL_NAME...
#   Purpose : Render a header row plus an underline rule sized to match.
#   Args    : COL_WIDTH — uniform width per column; COL_NAME… — column labels.
fmt_table_header() {
    local w="$1"; shift
    local sep=""
    printf "  "
    for col in "$@"; do
        printf "%-${w}s  " "$col"
        sep+=$(printf '%0.s-' $(seq 1 $((w+2))))
    done
    echo ""
    printf "  %s\n" "$sep"
}

# fmt_table_row COL_WIDTH VALUE...
#   Purpose : Print a uniform-width data row matching fmt_table_header.
fmt_table_row() {
    local w="$1"; shift
    printf "  "
    for val in "$@"; do
        printf "%-${w}s  " "$val"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Footer & numeric formatters
# ---------------------------------------------------------------------------

# fmt_footer — closing block with generation timestamp.
fmt_footer() {
    echo ""
    echo "$FMT_SEP1"
    printf "  Generated: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "$FMT_SEP1"
    echo ""
}

# fmt_duration_seconds SECONDS
#   Purpose : Human-friendly duration: "1m 23s" when >= 60, "45s" otherwise.
#   Args    : SECONDS — integer or decimal (decimal portion is truncated).
fmt_duration_seconds() {
    local secs="${1%.*}"   # strip decimal
    secs="${secs:-0}"
    if (( secs >= 60 )); then
        printf '%dm %ds' $(( secs / 60 )) $(( secs % 60 ))
    else
        printf '%ds' "$secs"
    fi
}

# fmt_pct NUMERATOR DENOMINATOR
#   Purpose : Percentage with one decimal, e.g. "75.0%". "N/A" when denom=0.
fmt_pct() {
    local n="$1" d="$2"
    if (( d == 0 )); then echo "N/A"; return; fi
    gawk -v n="$n" -v d="$d" 'BEGIN { printf "%.1f%%\n", (n/d)*100 }'
}
