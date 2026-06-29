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
# Display-width engine (wcwidth convention) — SINGLE SOURCE OF TRUTH
# ---------------------------------------------------------------------------
# Reused by the bash KV helpers (via fmt_dwidth) and by inline awk programs
# that print CJK labels. EVERY gawk invocation using these functions MUST run
# under LC_ALL=C so length()/substr() operate on BYTES (UTF-8 is decoded
# manually below). Wide (2-col) code points per Unicode East-Asian-Width;
# everything else, INCLUDING U+2192 (arrow), U+25A0, U+25B6, is width 1.
FMT_AWK_WIDTH='
function _byte(c) {
    if (_ORD_INIT != 1) { for (_k = 0; _k < 256; _k++) _ORD[sprintf("%c", _k)] = _k; _ORD_INIT = 1 }
    return _ORD[c]
}
function _wide(cp) {
    return ( (cp >= 4352   && cp <= 4447)   ||
             (cp >= 11904  && cp <= 12350)  ||
             (cp >= 12353  && cp <= 13311)  ||
             (cp >= 13312  && cp <= 19903)  ||
             (cp >= 19968  && cp <= 40959)  ||
             (cp >= 40960  && cp <= 42191)  ||
             (cp >= 44032  && cp <= 55203)  ||
             (cp >= 63744  && cp <= 64255)  ||
             (cp >= 65072  && cp <= 65103)  ||
             (cp >= 65280  && cp <= 65376)  ||
             (cp >= 65504  && cp <= 65510)  ||
             (cp >= 131072 && cp <= 262141) )
}
function dwidth(s,    n, i, b, w, cp) {
    n = length(s); w = 0
    for (i = 1; i <= n; ) {
        b = _byte(substr(s, i, 1))
        if (b < 128) { w += 1; i += 1 }
        else if (b >= 192 && b <= 223) {
            cp = (b - 192) * 64 + (_byte(substr(s, i+1, 1)) - 128)
            w += (_wide(cp) ? 2 : 1); i += 2
        }
        else if (b >= 224 && b <= 239) {
            cp = (b - 224) * 4096 + (_byte(substr(s, i+1, 1)) - 128) * 64 + (_byte(substr(s, i+2, 1)) - 128)
            w += (_wide(cp) ? 2 : 1); i += 3
        }
        else if (b >= 240 && b <= 247) {
            cp = (b - 240) * 262144 + (_byte(substr(s, i+1, 1)) - 128) * 4096 + (_byte(substr(s, i+2, 1)) - 128) * 64 + (_byte(substr(s, i+3, 1)) - 128)
            w += (_wide(cp) ? 2 : 1); i += 4
        }
        else { w += 1; i += 1 }
    }
    return w
}
function rpad(s, w,    pad) {
    pad = w - dwidth(s); if (pad < 1) pad = 1
    return s sprintf("%*s", pad, "")
}
'

# fmt_dwidth STRING
#   Purpose : Terminal display width (columns) of STRING under wcwidth rules.
#   Args    : STRING — arbitrary UTF-8 text (may contain leading spaces).
#   Output  : integer column count on stdout.
#   Returns / Side effects : none.
#   Notes   : Runs gawk under LC_ALL=C so dwidth() decodes UTF-8 from bytes.
#             BEGIN-only program reads no input (no stdin wait).
fmt_dwidth() {
    LC_ALL=C gawk -v s="$1" "${FMT_AWK_WIDTH}"'BEGIN { print dwidth(s) }'
}

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
#   Purpose : Emit "  <KEY padded to 40 display columns><VALUE>".
#   Args    : KEY — label (may contain CJK; display width measured via
#             FMT_AWK_WIDTH engine); VALUE — string (or number); INDENT —
#             leading spaces (default 2).
#   Output  : one line on stdout.
#   Returns / Side effects : forks one gawk per call (acceptable for the
#             ~10-20 KV rows per interactive report).
#   Notes   : For pure-ASCII keys shorter than 40 chars the output is
#             byte-identical to the old "%-40s" form.
fmt_kv() {
    local key="$1" val="$2" indent="${3:-2}"
    local pad=$(( 40 - $(fmt_dwidth "$key") ))
    if (( pad < 1 )); then pad=1; fi
    printf "%${indent}s%s%*s%s\n" "" "$key" "$pad" "" "$val"
}

# fmt_kv_color KEY VALUE COLOR [INDENT]
#   Purpose : Same as fmt_kv but the value is wrapped in COLOR…RESET so the
#             eye can land on critical numbers (e.g. red 5xx counts).
#   Args    : KEY — label (CJK-safe; display width via FMT_AWK_WIDTH);
#             VALUE — string; COLOR — ANSI escape (e.g. $C_RED); INDENT —
#             leading spaces (default 2).
#   Output  : one line on stdout.
#   Returns / Side effects : forks one gawk per call.
#   Notes   : For pure-ASCII keys shorter than 40 chars the output is
#             byte-identical to the old "%-40s" form.
fmt_kv_color() {
    local key="$1" val="$2" color="$3" indent="${4:-2}"
    local pad=$(( 40 - $(fmt_dwidth "$key") ))
    if (( pad < 1 )); then pad=1; fi
    printf "%${indent}s%s%*s%b%s%b\n" "" "$key" "$pad" "" "$color" "$val" "$C_RESET"
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
#   Purpose : Print the closing separator block with the run's generation time.
#   Args    : none.
#   Output  : footer block on stdout.
#   Returns / Side effects : none.
#   Notes   : Uses the shared run timestamp $RUN_TS (set once by persist_init in
#             output_utils.sh) so a report's footer matches its persisted
#             filename suffix and is byte-reproducible under a pinned
#             $LOG_PARSE_RUN_TS. Falls back to wall-clock when RUN_TS is unset
#             (e.g. fmt_utils sourced outside a CLI run).
fmt_footer() {
    local gen_ts
    if [[ -n "${RUN_TS:-}" ]]; then
        gen_ts="${RUN_TS:0:4}-${RUN_TS:4:2}-${RUN_TS:6:2} ${RUN_TS:9:2}:${RUN_TS:11:2}:${RUN_TS:13:2}"
    else
        gen_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    fi
    echo ""
    echo "$FMT_SEP1"
    printf "  Generated: %s\n" "$gen_ts"
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
