#!/usr/bin/env bash
# lib/output_utils.sh — Always-on report persistence (D6). Sourced only.
#
# Provides directory-based persistence for every report module: one summary
# file (always .txt) and one detail file per run, colour-free, sharing a
# single launch timestamp inside the resolved output directory.
#
# Globals (sanctioned, documented):
#   RUN_OUTPUT_DIR  — resolved absolute path to the output directory.
#   RUN_TS          — fixed launch timestamp (YYYYMMDD_HHMMSS) for this run.
#
# Env contract (read by persist_init):
#   LOG_PARSE_OUTPUT_DIR — override the default ./log-parse directory.
#   LOG_PARSE_RUN_TS     — share a deterministic timestamp across child processes.
#
# Conventions:
#   - Source this file; do not execute directly.
#   - Never call init_tmpdir from a library.
#   - Never call exit except via die.
#   - All log output goes to STDERR; stdout = report content.

RUN_OUTPUT_DIR=""
RUN_TS=""

# persist_init CLI_OUTPUT_DIR
#   Purpose : Resolve and create the run output directory and fix the single
#             launch timestamp once for the lifetime of the process.
#             Idempotent within a process (subsequent calls are no-ops if
#             RUN_OUTPUT_DIR is already set).
#   Args    : CLI_OUTPUT_DIR — value of --output-dir flag ("" = use env/default).
#   Output  : nothing on stdout; logs resolved dir+ts at debug level.
#   Returns / Side effects : sets RUN_OUTPUT_DIR and RUN_TS; mkdir -p the dir.
#   Errors / Notes : Dir precedence (C1): CLI flag > $LOG_PARSE_OUTPUT_DIR >
#             ./log-parse. The ./log-parse literal lives ONLY here; callers
#             MUST default OPT_OUTPUT_DIR="" so the flag > env precedence holds.
#             ts: $LOG_PARSE_RUN_TS when set (shared/deterministic across child
#             processes launched by log_report) else date +%Y%m%d_%H%M%S.
persist_init() {
    local cli_dir="${1:-}"
    # Idempotency guard: if RUN_OUTPUT_DIR is already resolved in this process,
    # honour the existing dir+ts (single-RUN_TS invariant for I12/D33).
    if [[ -n "$RUN_OUTPUT_DIR" ]]; then return 0; fi
    RUN_OUTPUT_DIR="${cli_dir:-${LOG_PARSE_OUTPUT_DIR:-./log-parse}}"
    RUN_TS="${LOG_PARSE_RUN_TS:-$(date '+%Y%m%d_%H%M%S')}"
    mkdir -p "$RUN_OUTPUT_DIR" || die "cannot create output dir: $RUN_OUTPUT_DIR"
    log_debug "output dir: $RUN_OUTPUT_DIR  ts: $RUN_TS"
}

# persist_ext FORMAT
#   Purpose : Map a --format value to the detail file extension.
#   Args    : FORMAT — text|tsv|csv (unknown values default to txt).
#   Output  : file extension string (txt|tsv|csv) on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : summary files are ALWAYS .txt (C10); only detail uses this.
persist_ext() {
    case "${1:-text}" in
        tsv) echo tsv ;;
        csv) echo csv ;;
        *)   echo txt ;;
    esac
}

# persist_path MODULE KIND EXT
#   Purpose : Construct the canonical output file path for a module/kind pair.
#   Args    : MODULE — stem (overview|iis|access|errors);
#             KIND   — summary|detail;
#             EXT    — file extension (txt|tsv|csv).
#   Output  : full path string on stdout: RUN_OUTPUT_DIR/MODULE_KIND_RUN_TS.EXT
#   Returns / Side effects : none (RUN_OUTPUT_DIR and RUN_TS must be set first).
#   Errors / Notes : call persist_init before this function.
persist_path() {
    printf '%s/%s_%s_%s.%s\n' "$RUN_OUTPUT_DIR" "$1" "$2" "$RUN_TS" "$3"
}

# persist_views MODULE VIEW FORMAT SUMMARY_FN DETAIL_FN
#   Purpose : Write the summary file (always, colour-free) and, when DETAIL_FN
#             is non-empty, the detail file in FORMAT (colour-free); then mirror
#             the VIEW-selected render to console honouring TTY colour (D6).
#             DETAIL_FN="" means summary-only module (e.g. overview).
#   Args    : MODULE     — stem (overview|iis|access|errors);
#             VIEW       — summary|detail (which view to mirror to stdout);
#             FORMAT     — text|tsv|csv (governs detail ext only; summary=.txt);
#             SUMMARY_FN — bash function name that renders the summary view to stdout;
#             DETAIL_FN  — bash function name that renders the detail view to stdout,
#                          or "" for summary-only modules.
#   Output  : console mirror of the selected view on stdout (pipe-safe).
#             1-2 files written under RUN_OUTPUT_DIR; logged to stderr.
#   Returns / Side effects : writes files; never exits except via die in callers.
#   Errors / Notes : Colour is toggled via fmt_set_color_state (C3). Files are
#             written with NO_COLOR=1 so persisted records are plain text; the
#             console mirror is re-rendered with the caller's original colour state.
#             Each file is rendered exactly once (C4); the console mirror is one
#             additional formatting-only render. Nothing transient is written into
#             RUN_OUTPUT_DIR — glob/"exactly N files" tests never see stray files.
persist_views() {
    local module="$1" view="$2" fmt="$3" summary_fn="$4" detail_fn="$5"
    local ext sfile dfile saved _had_nc
    ext="$(persist_ext "$fmt")"
    sfile="$(persist_path "$module" summary txt)"   # summary ALWAYS .txt (C10)
    dfile=""
    if [[ -n "$detail_fn" ]]; then dfile="$(persist_path "$module" detail "$ext")"; fi

    # 1. Color-free file writes (C3): blank C_* globals via fmt_set_color_state,
    #    write both files, then restore caller's color state for the console mirror.
    # Track set-ness of NO_COLOR (not just value) so we unset rather than
    # set-empty on restore — important for no-color.org semantics (presence
    # regardless of value disables color in conforming consumers).
    if [[ -n "${NO_COLOR+set}" ]]; then _had_nc=1; else _had_nc=0; fi
    saved="${NO_COLOR:-}"
    NO_COLOR=1; fmt_set_color_state
    "$summary_fn" > "$sfile"
    if [[ -n "$detail_fn" ]]; then
        "$detail_fn" > "$dfile"
    fi
    if [[ "$_had_nc" == "0" ]]; then unset NO_COLOR; else NO_COLOR="$saved"; fi
    fmt_set_color_state

    # 2. Console mirror of the SELECTED view (TTY color honored) — D6 stdout=report.
    if [[ "$view" == "detail" && -n "$detail_fn" ]]; then
        "$detail_fn"
    else
        "$summary_fn"
    fi

    if [[ -n "$dfile" ]]; then
        log_info "Persisted: $sfile , $dfile"
    else
        log_info "Persisted: $sfile"
    fi
}
