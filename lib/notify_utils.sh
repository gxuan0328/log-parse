#!/usr/bin/env bash
# lib/notify_utils.sh — SMTP-API report delivery (D12). Sourced only.
#
# Opt-in, single-shot, post-run notification stage for `bin/log_report.sh
# --notify`. Builds one JSON document (the owner's fixed API contract; see
# docs/design.md §3.4.7) and POSTs it to an internal SMTP-relay HTTP API:
#   From        object            {DisplayName, Address}
#   To          array of objects  [{DisplayName, Address}, ...]  (receivers.conf order)
#   Subject     string            auto-derived, env-overridable
#   Body        string            minimal HTML (<pre>-wrapped, fully &<>-
#                                  escaped) UTF-8; carries the run's KEY SUMMARY
#   Attachments MAP               key = filename, value = base64 string
# There are no isBodyHtml / cc / bcc / fileName / contentBase64 keys.
#
# Every persisted file in the run directory becomes one attachment (never a
# zip); the Body carries the run's own KEY SUMMARY, extracted from
# overview_summary.txt -- never boilerplate. When bin/log_report.sh was also
# given --report-export, notify_send additionally attaches the xlsx
# deliverable lib/report_export_utils.sh produced (REPORT_EXPORT_DELIVERABLE_PATH,
# living outside the run directory under <output-dir>/production/output) via
# notify_collect_attachments' optional 4th EXTRA parameter -- see that
# function's own docblock for the exact guarantees this carries.
#
# curl and base64 are CONDITIONAL runtime dependencies (a narrow, recorded
# deviation from CLAUDE.md §6; see docs/design.md §4.9): they are named ONLY
# in this file, gated lazily behind notify_preflight, and never touched
# unless --notify is actually requested (test L01 proves the converse).
#
# Globals (sanctioned, documented):
#   NOTIFY_PREFLIGHT_DONE (int)    — idempotency guard for notify_preflight.
#   NOTIFY_RECEIVERS_TSV  (string) — load_receivers output, cached by notify_send.
#   NOTIFY_ATTACH_TSV     (path)   — attachment-manifest TSV, set by notify_send.
#   NOTIFY_WORKDIR        (path)   — scratch dir for this send (== WORK_TMPDIR).
#   NOTIFY_SKIP_REASON    (string) — cap-breach reason token (see §7.5 of the spec).
#   NOTIFY_HTTP_CODE, NOTIFY_TIME_MS — set by notify_post, read by notify_result_line.
#   NOTIFY_CURL_EXIT      (int)    — curl's own process exit code (0 on success);
#     distinct from NOTIFY_HTTP_CODE (which becomes the sentinel "000" on a
#     transport failure, since no HTTP response was ever received). Needed to
#     build the notify_result_line reason=curl_exit_<n> token. Not itemised in
#     the design spec's globals table, added here with this justifying comment
#     per library.md ("no new globals without a comment").
#   NOTIFY_PAYLOAD_PATH   (path)   — resolved final path of THIS send's
#     assembled payload, set by notify_send immediately before it calls
#     notify_build_payload; read by notify_result_line (payload_bytes) and by
#     notify_send's own "payload written:" log line. ORCHESTRATOR OVERRIDE
#     (supersedes this file's original "$WORK_TMPDIR always" design, see the
#     comment at the assignment site in notify_send): in --notify-dry-run
#     mode this is <RUN_DIR>/notify_payload.json, NOT $WORK_TMPDIR, because
#     init_tmpdir's EXIT trap deletes $WORK_TMPDIR when this process exits,
#     and a dry run exists solely so the operator can inspect the payload
#     afterwards. A real send keeps the historical, purely-transient
#     $WORK_TMPDIR/notify_payload.json convention. Not itemised in the design
#     spec's globals table, added here per library.md ("no new globals
#     without a comment").
#
# Env contract (all optional; every variable also appears, reproduced
# verbatim, in the "Notification" section of docs/usage.md):
#   LOG_PARSE_NOTIFY_URL                default: the contract endpoint below
#   LOG_PARSE_NOTIFY_SUBJECT            default: derived (notify_subject)
#   LOG_PARSE_NOTIFY_FROM_NAME          default: 系統通知
#   LOG_PARSE_NOTIFY_FROM_ADDR          default: notify@nhi.gov.tw
#   LOG_PARSE_NOTIFY_CURL_BIN           default: curl
#   LOG_PARSE_NOTIFY_INTERNAL_DOMAINS   default: (empty)
#   LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES   default: 2097152 (2 MiB, per file)
#   LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES    default: 8388608 (8 MiB, per run)
#   LOG_PARSE_NOTIFY_CONNECT_TIMEOUT    default: 5
#   LOG_PARSE_NOTIFY_MAX_TIME           default: 60
#
# Public function surface (call order mirrors notify_send's sequence):
#   notify_preflight, notify_assert_url, notify_assert_address, load_receivers,
#   notify_collect_attachments, notify_build_body, notify_subject,
#   notify_json_escape, notify_build_payload, notify_post, notify_result_line,
#   notify_send, notify_run.
#
# Conventions:
#   - Source this file; do not execute directly.
#   - Never call init_tmpdir from a library -- EXCEPT notify_send, which calls
#     it conditionally (only when WORK_TMPDIR is still unset). This is a
#     documented, narrow exception to the library.md rule: bin/log_report.sh
#     always calls init_tmpdir itself before notify_run, so the conditional
#     call is a no-op on the normal CLI path; it exists ONLY so direct-library
#     callers (unit tests; see docs/design.md §3.4.7 mechanism 3) get a
#     scratch dir without having to replicate CLI setup.
#   - Never call exit except via die.
#   - All log output goes to STDERR; stdout = report content (rule 3). The
#     notify stage never writes to stdout at all (test L10).
#   - No new UNCONDITIONAL dependency: curl/base64 are named ONLY in this file
#     and only reached through notify_preflight.

# ---------------------------------------------------------------------------
# Constants (env-overridable where noted; deliberately NOT `readonly` --
# no other file in this codebase uses `readonly`, and lib/notify_utils.sh may
# be sourced more than once within a single process across test blocks that
# reuse a shell; a `readonly` re-assignment would abort with "readonly
# variable" on the second source. Plain assignment matches every other
# lib/*.sh constant in this project (FMT_SEP1, IIS_UTC_OFFSET_HOURS, ...).)
# ---------------------------------------------------------------------------
NOTIFY_DEFAULT_URL="http://haididev.intra.nhi.gov.tw:8080/api/email/send"
NOTIFY_FROM_NAME="${LOG_PARSE_NOTIFY_FROM_NAME:-系統通知}"
NOTIFY_FROM_ADDR="${LOG_PARSE_NOTIFY_FROM_ADDR:-notify@nhi.gov.tw}"
NOTIFY_ADDR_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
NOTIFY_MAX_ATTACH_BYTES="${LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES:-2097152}"   # 2 MiB raw, per file
NOTIFY_MAX_TOTAL_BYTES="${LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES:-8388608}"     # 8 MiB raw, per run
NOTIFY_MAX_BODY_BYTES=65536
NOTIFY_CONNECT_TIMEOUT="${LOG_PARSE_NOTIFY_CONNECT_TIMEOUT:-5}"
NOTIFY_MAX_TIME="${LOG_PARSE_NOTIFY_MAX_TIME:-60}"
NOTIFY_RESP_LOG_BYTES=512

# No retry constants (D12 correction H): the API defines no idempotency
# mechanism, so an automatic curl retry after a lost response would risk a
# duplicate send; failing loudly once is the chosen behaviour (docs/design.md
# §3.4.7). No token/auth-header variable either: the contract defines no
# auth header (correction G).

# ---------------------------------------------------------------------------
# Cross-call state (sanctioned; mirrors WORK_TMPDIR / RUN_OUTPUT_DIR style)
# ---------------------------------------------------------------------------
NOTIFY_PREFLIGHT_DONE=0
NOTIFY_RECEIVERS_TSV=""
NOTIFY_ATTACH_TSV=""
NOTIFY_WORKDIR=""
NOTIFY_SKIP_REASON=""
NOTIFY_HTTP_CODE=""
NOTIFY_TIME_MS=""
NOTIFY_CURL_EXIT=""
NOTIFY_PAYLOAD_PATH=""

# ---------------------------------------------------------------------------
# Dependency gate
# ---------------------------------------------------------------------------

# notify_preflight
#   Purpose : Verify the dependency this run actually needs is present:
#             base64 only in --notify-dry-run (no network is ever touched);
#             curl + base64 for a real send. Idempotent (NOTIFY_PREFLIGHT_DONE).
#   Args    : none.
#   Output  : nothing on success; three ERROR lines on stderr when curl is
#             missing for a real send (see docs/usage.md "Notification").
#   Returns / Side effects : returns 0; sets NOTIFY_PREFLIGHT_DONE=1. Exits 1
#             via die/require_cmds on a missing dependency -- never returns
#             non-zero.
#   Errors / Notes : Two call sites (both idempotent): bin/log_report.sh
#             parse_args (offline pre-flight, so a missing curl is a 50ms
#             failure, not a post-analysis surprise) and the first statement
#             of notify_send (point of use, for callers that reach this
#             library directly). Body is locked verbatim by the design spec.
notify_preflight() {
    if [[ "$NOTIFY_PREFLIGHT_DONE" -eq 1 ]]; then return 0; fi
    if [[ "$OPT_NOTIFY_DRY_RUN" -eq 1 ]]; then
        require_cmds base64                     # no network in dry-run
    else
        local curl_bin="${LOG_PARSE_NOTIFY_CURL_BIN:-curl}"
        if ! command -v "$curl_bin" >/dev/null 2>&1; then
            # Loud, named, actionable. Deliberately not require_cmds alone:
            # a bare "missing required commands: curl" tells a 3am operator
            # nothing about WHICH flag caused it. Last line reproduces the
            # canonical string verbatim so existing greps still match.
            log_error "--notify needs the optional dependency 'curl' (HTTP client for the SMTP API)."
            log_error "Install curl, or use --notify-dry-run to build the payload without sending."
            die "missing required commands: curl"
        fi
        require_cmds base64
    fi
    NOTIFY_PREFLIGHT_DONE=1
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

# notify_assert_url URL
#   Purpose : Fail-fast guard that URL is a well-formed, non-flag-like
#             http(s) endpoint before it ever reaches curl's argv.
#   Args    : URL — candidate endpoint string.
#   Output  : nothing on success.
#   Returns / Side effects : never returns on failure -- exits via die().
#   Errors / Notes : regex `^https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+$`; the
#             leading http/https anchor also rejects a leading '-', which
#             curl would otherwise read as a flag (CWE-88). Called from
#             bin/log_report.sh parse_args whenever --notify is set,
#             including --notify-dry-run, so a malformed endpoint is caught
#             offline.
notify_assert_url() {
    local url="$1"
    local re='^https?://[A-Za-z0-9._~:/?#@!$&'\''()*+,;=%-]+$'
    if [[ ! "$url" =~ $re ]]; then
        die "unsupported endpoint URL: $url"
    fi
}

# notify_assert_address LABEL ADDR
#   Purpose : Fail-fast guard that ADDR is a syntactically valid address.
#   Args    : LABEL — name to quote in the die message (e.g. the env var
#             name); ADDR — candidate address string.
#   Output  : nothing on success.
#   Returns / Side effects : never returns on failure -- exits via die().
#   Errors / Notes : Uses the SAME $NOTIFY_ADDR_RE the receivers.conf gawk
#             loader validates against (rule 2, single source). Used for
#             From.Address; recipients are validated inside load_receivers.
notify_assert_address() {
    local label="$1" addr="$2"
    if [[ ! "$addr" =~ $NOTIFY_ADDR_RE ]]; then
        die "$label is not a valid address: $addr"
    fi
}

# ---------------------------------------------------------------------------
# NOTIFY_RECEIVERS_AWK — conf/receivers.conf parser (gawk; rule 5)
# ---------------------------------------------------------------------------
# Gawk-based like load_test_hosts (lib/common.sh), NOT the IFS='|' read idiom
# every load_regions duplicates: IFS='|' read silently ingests a whitespace-
# only line, silently ingests an indented "# comment", and leaves a literal
# CR glued to the LAST field on CRLF input -- which in this two-field format
# is the ADDRESS. This tree lives under a OneDrive-synced WSL mount, so CRLF
# is a live risk, and a stray CR on an address is a silent mis-delivery.
NOTIFY_RECEIVERS_AWK='
# ----------------------------------------------------------------------------
# Purpose : Parse conf/receivers.conf (or an equivalent fixture) into
#           normalised NAME<TAB>ADDRESS rows, one per accepted line.
# Input   : DISPLAY_NAME|ADDRESS text; "#" comments (inline or whole-line)
#           and blank/whitespace-only lines are ignored; CRLF tolerated.
# Vars    : addr_re -- NOTIFY_ADDR_RE, passed in so bash and gawk validate
#           addresses against the SAME regex (rule 2; also used by
#           notify_assert_address for the From address).
# Output  : "NAME<TAB>ADDRESS" per accepted row, file order, on stdout.
# Notes   : Every diagnostic is prefixed with the LITERAL string
#           "receivers.conf" (never FILENAME) so messages stay stable when
#           --receivers-conf points at a different path; the bash-layer
#           wrapper (load_receivers) logs the real path separately. Exits 3
#           (not 1 or 2) on any defect so the bash caller can distinguish a
#           parse failure from a generic gawk usage error.
# ----------------------------------------------------------------------------
{
    line = $0
    sub(/#.*/, "", line)
    gsub(/\r/, "", line)

    trimmed = line
    gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
    if (trimmed == "") next

    n = split(line, F, "|")
    if (n != 2) {
        printf "receivers.conf:%d: expected 2 pipe-separated fields (DISPLAY_NAME|ADDRESS), got %d\n", NR, n > "/dev/stderr"
        had_error = 1
        exit 3
    }

    name = F[1]; addr = F[2]
    gsub(/^[ \t]+|[ \t]+$/, "", name)
    gsub(/^[ \t]+|[ \t]+$/, "", addr)

    if (name ~ /[|,;<>"]/ || name ~ /[\001-\037\177]/) {
        printf "receivers.conf:%d: display name contains '\''|'\'' , ; < > \" or a control character\n", NR > "/dev/stderr"
        had_error = 1
        exit 3
    }

    if (addr !~ addr_re) {
        printf "receivers.conf:%d: invalid address '\''%s'\'' (need user@domain.tld, no whitespace, no , ; < > \" )\n", NR, addr > "/dev/stderr"
        had_error = 1
        exit 3
    }

    key = tolower(addr)
    if (key in seen) {
        printf "receivers.conf:%d: duplicate address '\''%s'\'' (first seen on line %d)\n", NR, addr, seen[key] > "/dev/stderr"
        had_error = 1
        exit 3
    }
    seen[key] = NR
    accepted++
    printf "%s\t%s\n", name, addr
}
END {
    # Only the natural-EOF path (no earlier line-level defect already fired
    # its own specific message and exit 3) checks for "zero accepted rows" --
    # otherwise this would print a confusing SECOND, generic message right
    # after a already-specific one, since gawk always runs END after an
    # exit() from a main rule.
    if (!had_error && accepted == 0) {
        print "receivers.conf: no recipient defined" > "/dev/stderr"
        exit 3
    }
}
'

# load_receivers CONF
#   Purpose : Parse conf/receivers.conf into normalised recipient rows.
#   Args    : CONF — path to receivers.conf (or an equivalent test fixture).
#   Output  : "NAME<TAB>ADDRESS" rows, one per accepted line, file order, stdout.
#   Returns / Side effects : none (pure, stdout-returning; mirrors load_test_hosts).
#   Errors / Notes : dies (fail-fast) on: missing file, wrong field count,
#             invalid address, invalid display name, duplicate address
#             (case-insensitive), or zero accepted rows -- exact wording in
#             NOTIFY_RECEIVERS_AWK above and docs/usage.md.
#             BUG FIX (found by Section-L/E integration tests, not caught by
#             unit-level invocation): the internal die fires inside the
#             command-substitution subshell a caller's own
#             `VAR="$(load_receivers ...)"` forks, so that subshell's exit 1
#             can only end the subshell, never the calling process. A bare
#             assignment DOES still propagate correctly when the enclosing
#             code runs with errexit ACTIVE (bash aborts the shell on a
#             failing plain-assignment command substitution) -- but this
#             library's only production caller, notify_send, is invoked by
#             notify_run as `if notify_send ...; then`, and bash disables
#             errexit for the ENTIRE body of any function used as an
#             if/while/until condition, not just the direct condition
#             command. So inside notify_send, a bare assignment here can
#             NEVER trigger an automatic abort, no matter how load_receivers
#             itself exits -- a malformed receivers.conf would silently leave
#             NOTIFY_RECEIVERS_TSV empty and the run would report a false
#             "sent"/"dry-run" success with zero recipients, exactly the
#             silent fallback CLAUDE.md rule 1 forbids. CALLERS THAT CANNOT
#             GUARANTEE AN ERREXIT-ACTIVE CONTEXT MUST EXPLICITLY CHECK THE
#             ASSIGNMENT AND die() THEMSELVES -- see notify_send's own call
#             site for the pattern now in force.
load_receivers() {
    local conf="$1"
    if [[ ! -f "$conf" ]]; then die "conf file not found: $conf"; fi
    local out
    # gawk's `-v var=value` applies C-string escape processing to value (POSIX
    # behaviour): an unrecognised sequence like the regex's own `\.` is
    # silently reduced to a plain `.`, which would turn the "literal dot"
    # anchor into "any character" and weaken address validation. Doubling
    # every backslash here first means gawk's escape pass consumes exactly
    # one level (\\ -> \), leaving the regex engine the single backslash it
    # needs -- the stored $NOTIFY_ADDR_RE itself is untouched and keeps
    # working correctly for bash's own `=~` (notify_assert_address).
    local addr_re_gv="${NOTIFY_ADDR_RE//\\/\\\\}"
    if ! out="$(gawk -v addr_re="$addr_re_gv" "$NOTIFY_RECEIVERS_AWK" "$conf")"; then
        die "invalid receivers config: $conf"
    fi
    if [[ -z "$out" ]]; then die "no receivers defined in: $conf"; fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Shared byte-counting helper (FIX E; composes with FIX A)
# ---------------------------------------------------------------------------

# _notify_file_bytes FILE
#   Purpose : Print the TRUE byte count of FILE -- the ONE byte-counting
#             primitive shared by attachment sizing (notify_collect_attachments),
#             body sizing (notify_build_body), and payload sizing
#             (notify_result_line), so the three can never drift apart
#             (rule 2) and so a file with no trailing newline is never
#             over-counted by one byte (FIX E fixes the old, independently
#             duplicated `n += length(line) + 1` idiom, which silently added
#             a phantom byte per line for exactly this case).
#   Args    : FILE — path to a regular file (may be empty; must exist).
#   Output  : exact byte count on stdout for a readable FILE (0 for a
#             genuinely empty one); NOTHING on stdout when FILE could not be
#             opened at all.
#   Returns / Side effects : 0 on success. Non-zero, with nothing printed, if
#             gawk could not open FILE -- the caller MUST check this and
#             die() rather than treat a failed probe as "0 bytes" (FIX A):
#             an unopenable/misresolved attachment silently reported as
#             empty, followed by `status=sent`, is a false-success report
#             CLAUDE.md rule 1 forbids.
#   Errors / Notes : FILE is passed as a gawk OPERAND, never through `-v`
#             (FIX A) -- operands are never C-string-escape-processed, so a
#             backslash in the path (e.g. `--output-dir 'C:\reports'`) can
#             never be silently rewritten into a different, non-existent
#             path the way `-v f="$path"` would. `RS="^$"` is a regex that
#             can never match, so gawk slurps the whole file into `$0` as
#             ONE record; `length($0)` under `LC_ALL=C` is then the true
#             byte count, with no assumption that the file ends in LF. An
#             empty file yields zero records (the main rule never fires) so
#             END's `n+0` prints "0" -- exit status still 0 (gawk opened the
#             file fine, there was simply nothing to read), which is exactly
#             how this is distinguished from an open failure (non-zero exit,
#             nothing printed).
_notify_file_bytes() {
    local file="$1"
    LC_ALL=C gawk 'BEGIN{RS="^$"} {n=length($0)} END{print n+0}' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Attachment enumeration
# ---------------------------------------------------------------------------

# notify_collect_attachments DIR MODE OUT_TSV [EXTRA]
#   Purpose : Enumerate DIR (the run's persisted output directory), PLUS the
#             optional EXTRA file (report-export's xlsx deliverable, living
#             outside DIR under <output-dir>/production/output), into one
#             attachment manifest, applying MODE and the per-file/per-run
#             raw-byte caps BEFORE any base64 encoding is attempted.
#   Args    : DIR — run directory (flat; a subdirectory is an invariant
#             violation); MODE — all|summary; OUT_TSV — manifest path to
#             write; EXTRA — [OPT] an additional absolute file path to
#             attach alongside DIR's own contents (e.g.
#             REPORT_EXPORT_DELIVERABLE_PATH), or "" (default) for none.
#   Output  : nothing on stdout. Writes OUT_TSV, one row per regular file:
#               ATTACH<TAB>name<TAB>bytes<TAB>path
#               SKIP<TAB>name<TAB>bytes<TAB>empty        (0-byte file)
#   Returns / Side effects : 0 on success; 2 with NOTIFY_SKIP_REASON set
#             (attachment_too_large:<name> | total_too_large) on a cap
#             breach -- the caller must stop, no curl call is appropriate.
#   Errors / Notes : dies on a subdirectory under DIR ("run dir must be flat"),
#             a duplicate basename (filesystem-guaranteed not to happen from
#             one flat glob; asserted anyway as a documented invariant -- and
#             now LOAD-BEARING rather than purely defensive: it is the only
#             guard against EXTRA shadowing a same-named run-dir file), a
#             filename containing a TAB or newline byte (FIX I -- would
#             corrupt the TSV manifest read back elsewhere), or an
#             attachment that exists per the earlier `-f` check yet cannot
#             actually be opened for its size probe (FIX A -- distinct from
#             a genuinely empty file, which is SKIPPED, not fatal).
#             `notify_payload.json` is unconditionally excluded from
#             enumeration in every MODE (FIX B) so a dry run's own artifact,
#             or an earlier run's leftover under a pinned LOG_PARSE_RUN_TS,
#             can never become a 7th attachment of itself. EXTRA is asserted
#             to exist as a regular file BEFORE the loop even starts --
#             LOUDLY (rule 1): unlike the loop body's lenient
#             `[[ ! -f "$f" ]] && continue` (a TOCTOU allowance for a
#             directory THIS tool owns), silently dropping an
#             operator/feature-named path here would be exactly the silent
#             fallback rule 1 forbids. EXTRA bypasses ONLY the
#             --notify-attach summary basename filter (via the per-iteration
#             is_extra flag) -- every other rule in the loop body (the
#             notify_payload.json exclusion, the TAB/newline check, the
#             seen_names collision table, the size probe, the 0-byte skip,
#             both size caps, the ATTACH manifest row) applies to it
#             identically, unmodified. Enumeration of DIR is a bash glob
#             (never find, which is outside the sanctioned command set), so
#             it is already lexicographically sorted for DIR's own entries,
#             with EXTRA appended last -- deterministic, and this remains the
#             ONLY enumeration of DIR; nothing here is a second source of
#             truth for RUN_OUTPUT_DIR's contents (rule 2 / §7.1). Size is
#             measured by gawk (never stat/wc) in the same pass that will
#             later encode.
notify_collect_attachments() {
    local dir="$1" mode="$2" out="$3" extra="${4:-}"
    local f name bytes total=0
    local -A seen_names=()

    if [[ -n "$extra" && ! -f "$extra" ]]; then
        die "notify: extra attachment not found or not a regular file: $extra"
    fi

    : > "$out"
    shopt -s nullglob
    local -a candidates=("$dir"/*)
    shopt -u nullglob
    if [[ -n "$extra" ]]; then candidates+=("$extra"); fi

    for f in "${candidates[@]}"; do
        if [[ -d "$f" ]]; then die "run dir must be flat: unexpected subdirectory: $f"; fi
        if [[ ! -f "$f" ]]; then continue; fi
        name="$(basename "$f")"

        local is_extra=0
        if [[ -n "$extra" && "$f" == "$extra" ]]; then is_extra=1; fi

        # FIX B: notify_payload.json (this run's own --notify-dry-run
        # artifact, or a PRIOR run's leftover when LOG_PARSE_RUN_TS is
        # pinned to reuse this exact directory) must never be attachable, in
        # ANY --notify-attach mode. Checked unconditionally, before the
        # summary-mode filter below, so it never depends on incidentally NOT
        # matching *_summary.txt. See notify_send's ORCHESTRATOR OVERRIDE
        # comment for the full guarantee this establishes.
        case "$name" in
            notify_payload.json) continue ;;
        esac

        if [[ "$mode" == "summary" && "$is_extra" -eq 0 ]]; then
            case "$name" in
                *_summary.txt) ;;
                *) continue ;;
            esac
        fi

        # FIX I: a filename containing a TAB or newline byte would corrupt
        # the TSV manifest read back with `IFS=$'\t' read -r tag name bytes
        # path` (fields would shift). Linux filenames may legally contain
        # either byte, so this is a real, if unusual, invariant violation --
        # reject it the same way the collision check below does.
        if [[ "$name" == *$'\t'* || "$name" == *$'\n'* ]]; then
            die "attachment filename contains a TAB or newline byte (would corrupt the manifest): $name"
        fi

        if [[ -n "${seen_names[$name]:-}" ]]; then die "attachment name collision: $name"; fi
        seen_names["$name"]=1

        # FIX A: $f is fed to the byte-count probe as an operand (never
        # through gawk's `-v`, which C-string-unescapes its value and would
        # silently rewrite a backslash in $f -- a live risk since this tree
        # is on a OneDrive/WSL mount and --output-dir may contain one, e.g.
        # 'C:\reports'). A non-zero return here means gawk could NOT open
        # $f at all -- distinct from "opened fine, 0 bytes" -- and must be
        # fatal, never a silent SKIP that lets the run report false success.
        if ! bytes="$(_notify_file_bytes "$f")"; then
            die "notify: could not read attachment for size probe (unopenable or misresolved path): $f"
        fi
        log_debug "attach: $name $bytes"

        if (( bytes == 0 )); then
            log_warn "attachment skipped (0 bytes): $name"
            printf 'SKIP\t%s\t%s\tempty\n' "$name" "$bytes" >> "$out"
            continue
        fi

        if (( bytes > NOTIFY_MAX_ATTACH_BYTES )); then
            log_error "notify: $name is $bytes bytes, over the per-file cap $NOTIFY_MAX_ATTACH_BYTES; nothing was sent"
            NOTIFY_SKIP_REASON="attachment_too_large:$name"
            return 2
        fi

        total=$(( total + bytes ))
        if (( total > NOTIFY_MAX_TOTAL_BYTES )); then
            log_error "notify: attachments total $total bytes, over the per-run cap $NOTIFY_MAX_TOTAL_BYTES; nothing was sent"
            NOTIFY_SKIP_REASON="total_too_large"
            return 2
        fi

        printf 'ATTACH\t%s\t%s\t%s\n' "$name" "$bytes" "$f" >> "$out"
    done
    return 0
}

# _notify_attach_totals
#   Purpose : Aggregate ATTACH/SKIP counts and byte totals from
#             NOTIFY_ATTACH_TSV -- the ONE place this arithmetic is done, so
#             notify_send's audit/info lines and notify_result_line can never
#             drift apart (rule 2).
#   Args    : none (reads global NOTIFY_ATTACH_TSV).
#   Output  : "files skipped_empty raw_bytes b64_bytes" (space-joined) stdout.
#   Returns / Side effects : none. Prints all-zero row when NOTIFY_ATTACH_TSV
#             is unset or missing (defensive; should not occur post-collection).
#   Errors / Notes : b64_bytes uses the exact RFC 4648 length formula
#             4*ceil(n/3) rather than re-invoking base64, so the total never
#             disagrees with what notify_build_payload actually emits.
_notify_attach_totals() {
    if [[ -z "${NOTIFY_ATTACH_TSV:-}" || ! -f "$NOTIFY_ATTACH_TSV" ]]; then
        printf '0 0 0 0\n'
        return 0
    fi
    gawk -F'\t' '
        $1 == "ATTACH" { files++; raw += $3; b64 += 4 * int(($3 + 2) / 3) }
        $1 == "SKIP"   { skipped++ }
        END { printf "%d %d %d %d\n", files+0, skipped+0, raw+0, b64+0 }
    ' "$NOTIFY_ATTACH_TSV"
}

# _notify_head_bytes FILE CAP
#   Purpose : Print the first CAP bytes of FILE, byte-precise.
#   Args    : FILE — path (may be missing/empty); CAP — integer byte count.
#   Output  : up to CAP bytes on stdout; empty for a missing/empty FILE.
#   Returns / Side effects : none.
#   Errors / Notes : gawk-only (no head/dd/stat -- not sanctioned deps). Used
#             to cap logged curl error/response bodies (CWE-214, §9). FIX A:
#             FILE is fed to gawk as an operand, never through `-v` (which
#             C-string-unescapes its value and would silently rewrite a
#             backslash in the path); the missing-file case is handled in
#             bash BEFORE gawk ever runs, both because the docblock promises
#             "empty for a missing FILE" (not a die) and because every
#             current call site already guards with `[[ -s FILE ]]` first.
_notify_head_bytes() {
    local file="$1" cap="$2"
    if [[ ! -f "$file" ]]; then return 0; fi
    LC_ALL=C gawk -v cap="$cap" 'BEGIN{RS="^$"} {printf "%s", substr($0, 1, cap)}' "$file"
}

# ---------------------------------------------------------------------------
# NOTIFY_BODY_AWK — KEY SUMMARY extractor
# ---------------------------------------------------------------------------
NOTIFY_BODY_AWK='
# ----------------------------------------------------------------------------
# Purpose : Extract the KEY SUMMARY block from a persisted *_summary.txt for
#           the mail Body -- never boilerplate (docs/design.md §3.4.7).
# Input   : one persisted summary text file (normally overview_summary.txt,
#           or the body-fallback file when overview did not run).
# Vars    : none.
# Output  : retained lines, CR/ANSI-stripped, trailing blank/rule lines
#           trimmed, one per stdout line, original order preserved.
# Notes   : Stop conditions (first one reached wins): the hourly bar-chart
#           heading (a wall of U+2588 that is ~70% of the file and useless in
#           a proportional mail font), or the SECOND "▶ " section heading --
#           the FIRST is kept (it is the desired Overall block); the second
#           starts an unrelated section and is where extraction must stop.
#           A hard 60-line cap is insurance against future render drift.
#           MUST run under LC_ALL=C so the CR/ESC byte strips never split a
#           multi-byte UTF-8 sequence (every byte touched here is < 0x80;
#           CJK bytes >= 0x80 pass straight through the untouched $0 text).
# ----------------------------------------------------------------------------
{
    line = $0
    gsub(/\r/, "", line)
    gsub(/\033\[[0-9;]*m/, "", line)

    if (line ~ /^[[:space:]]*■ 存取紀錄橫條圖/) exit

    if (line ~ /^▶ /) {
        arrow_n++
        if (arrow_n >= 2) exit
    }

    n++
    buf[n] = line
    if (n >= 60) exit
}
END {
    while (n > 0 && (buf[n] == "" || buf[n] ~ /^[=-]+[[:space:]]*$/)) n--
    for (i = 1; i <= n; i++) print buf[i]
}
'

# ---------------------------------------------------------------------------
# NOTIFY_BODY_HTML_AWK -- HTML-escape + <pre>-wrap the assembled plaintext body
# ---------------------------------------------------------------------------
# The SMTP API renders Body as HTML unconditionally (no isBodyHtml toggle;
# docs/design.md Sec3.4.7): plain newlines and the space-padded, CJK-
# display-width column alignment the four printf blocks below build would
# otherwise collapse to one unreadable line under HTML whitespace rules.
# Wrapping the WHOLE body in a single <pre> preserves every space and
# newline verbatim -- the only way that column alignment survives HTML
# rendering -- but <pre> alone would still let an attacker/operator-
# influenced attachment FILENAME (see the manifest block notify_build_body
# renders below) inject a live tag (CWE-79), so the entire body is
# HTML-escaped FIRST, before it is ever wrapped.
NOTIFY_BODY_HTML_AWK='
# ----------------------------------------------------------------------------
# Purpose : HTML-escape the ENTIRE assembled plaintext body, UTF-8-safe cap
#           it against a wrapper-reserved byte budget, then wrap it in a
#           minimal <html><body><pre>...</pre></body></html> skeleton --
#           the exact text notify_build_body writes back to OUT_FILE as the
#           final HTML Body.
# Input   : the plaintext body file the four printf blocks below already
#           assembled (envelope + KEY SUMMARY + attachments manifest +
#           footer), slurped whole via RS="^$" (one record; no assumption
#           the file ends in LF).
# Vars    : cap -- NOTIFY_MAX_BODY_BYTES, the hard ceiling on the FINAL
#           (escaped + wrapped) Body, passed via -v.
# Output  : the complete HTML Body on stdout, byte-precise.
# Notes   : Escape order is LOAD-BEARING -- & FIRST, so the literal "&" of
#           an entity THIS pass just emitted (e.g. the "&" in "&lt;") is
#           never itself re-escaped into "&amp;lt;" -- then <, then >. Runs
#           under LC_ALL=C so gsub matches only the three ASCII bytes < > &
#           (all < 0x80); every CJK/multi-byte UTF-8 byte (>= 0x80) passes
#           through untouched, so the escape pass itself can never split a
#           sequence. Replacement literals are written "\\&amp;" etc.
#           (backslash-backslash-amp;) because in a gsub replacement string
#           an UNESCAPED & means "the matched text" -- \& is what inserts a
#           literal ampersand character. The truncation idiom below (only
#           reached when the ESCAPED text overflows the budget) is the same
#           continuation-byte back-off the pre-HTML cap used: after
#           computing a tentative cut length, keep backing off while the
#           byte immediately AFTER the cut is a UTF-8 continuation byte
#           (octal 200-277), so a multi-byte character is never split (a
#           cut MAY still split an HTML entity like "&amp;" -- cosmetic
#           only: entities are pure ASCII, so this never corrupts UTF-8 or
#           produces invalid JSON once jesc() escapes this text later).
#           head_w/tail_w are concatenated AFTER truncation and are never
#           part of the truncatable region, so </pre></body></html> can
#           never be cut away. Named head_w/tail_w, not open/close --
#           "close" is a gawk builtin and would be a syntax error as a
#           plain variable name.
# ----------------------------------------------------------------------------
BEGIN { RS = "^$" }
{
    content = $0
    gsub(/&/, "\\&amp;", content)
    gsub(/</, "\\&lt;",  content)
    gsub(/>/, "\\&gt;",  content)

    head_w = "<html><body><pre>\n"
    tail_w = "\n</pre></body></html>\n"
    budget = cap - length(head_w) - length(tail_w)
    if (budget < 0) budget = 0

    if (length(content) > budget) {
        notice = "... [body truncated at " cap " bytes]\n"
        keep = budget - length(notice)
        if (keep < 0) keep = 0
        while (keep > 0) {
            nb = substr(content, keep + 1, 1)
            if (nb < "\200" || nb > "\277") break
            keep--
        }
        content = substr(content, 1, keep) notice
    }

    printf "%s%s%s", head_w, content, tail_w
}
'

# notify_build_body DIR OUT_FILE
#   Purpose : Render the four-block mail Body (envelope, KEY SUMMARY,
#             attachment manifest, footer) to OUT_FILE, then HTML-escape and
#             <pre>-wrap the whole thing (see NOTIFY_BODY_HTML_AWK above)
#             so the SMTP API's unconditional HTML rendering preserves the
#             monospace column alignment those four blocks depend on.
#   Args    : DIR — run directory (same one notify_collect_attachments read);
#             OUT_FILE — output path.
#   Output  : nothing on stdout. Writes OUT_FILE, mode 0600.
#   Returns / Side effects : returns 0 on the ordinary path. Never dies for
#             missing/absent SUMMARY CONTENT -- a body is always produced,
#             see the fallback chain below -- but DOES die on a genuine I/O
#             failure while measuring, escaping, or truncating OUT_FILE
#             (disk full, permissions, or an unopenable/misresolved path); a
#             silently short or stale body would itself be the kind of
#             silent fallback CLAUDE.md rule 1 forbids (FIX A/FIX H
#             hardening).
#   Errors / Notes : Reads NOTIFY_ATTACH_TSV (already populated by
#             notify_collect_attachments), RUN_TS, OPT_REGION, OPT_MODULES,
#             OPT_NOTIFY_ATTACH, RUN_OUTPUT_DIR, INTERVAL_ARGS.
#             Fallback chain (never empty, never a die -- a blank body would
#             itself be a silent fallback):
#               1. overview_summary.txt present  -> NOTIFY_BODY_AWK over it.
#               2. absent, but some *_summary.txt exists -> first 25 lines of
#                  the lexicographically-first one, prefixed with the literal
#                  line "(overview not run — showing <name>)"; log_warn.
#               3. no *_summary.txt at all -> the literal line
#                  "(no summary view available for this run)"; log_warn.
#             Both fallbacks flow through the SAME always-run HTML pass as
#             the ordinary path -- there is no separate/unwrapped code path.
#             Once assembled, the plaintext above is UNCONDITIONALLY (not
#             only on overflow -- this is a behaviour change from the prior
#             plain-text cap) HTML-escaped end to end (& then < then >,
#             CWE-79: closes the injection hole an attacker/operator-
#             influenced attachment FILENAME in the manifest block could
#             otherwise open now that the API renders Body as HTML) and
#             wrapped in a minimal <html><body><pre>...</pre></body></html>
#             skeleton. The 64 KiB NOTIFY_MAX_BODY_BYTES cap now bounds the
#             FINAL escaped+wrapped Body, with the 40-byte wrapper
#             (<html><body><pre>\n + \n</pre></body></html>\n) reserved
#             OUT OF the cap, not on top of it, so the emitted Body can
#             never exceed the cap and the closing tags can never be cut
#             away by truncation; on overflow the escaped content carries a
#             visible final line "... [body truncated at 65536 bytes]"
#             inside the <pre> -- safe because the authoritative file is
#             attached in full (attachments are never truncated).
notify_build_body() {
    local dir="$1" out="$2"
    local first last fb total_rows tag name bytes path

    # FIX I (SIGPIPE safety -- disambiguation: this is a LATER review round's
    # "FIX I", unrelated to notify_collect_attachments' own, earlier
    # "FIX I" a few hundred lines above this one about TAB/newline bytes in
    # attachment filenames; both happen to reuse the same letter across two
    # independent review passes). Capture build_date_list's FULL output with
    # NO pipe (a bare command substitution's internal read runs to the
    # writer's own EOF; there is no early-closing reader to race), then take
    # the first/last LINE via pure parameter expansion -- no subprocess, no
    # pipe, no dependency added. This mirrors lib/report_export_utils.sh's
    # report_export_window_start EXACTLY (see that function's docblock for
    # the full empirically-verified writeup): the previous
    # `build_date_list ... | head -n 1` / `| tail -n 1` shape SIGPIPEs the
    # still-writing producer for any multi-day window under
    # `set -euo pipefail`, and pipefail then reports exit 141 for the whole
    # pipeline even though $first/$last had already captured the correct
    # value. It was harmless here ONLY by accident of the calling context
    # (notify_send is invoked as `if notify_send ...`, which suspends
    # errexit for its entire dynamic extent, including this call) -- not by
    # design, and any future direct-library caller (docs/design.md §3.4.7
    # mechanism 3) or any refactor that stops calling notify_send from an
    # `if` condition would have hit it. Fails loud via die() if the range
    # itself cannot be derived (should not happen: resolve_interval has
    # already validated INTERVAL_ARGS before this ever runs).
    local all
    all="$(build_date_list "${INTERVAL_ARGS[@]}")" \
        || die "notify: cannot derive the analysis date range for the mail body"
    first="${all%%$'\n'*}"
    last="${all##*$'\n'}"

    : > "$out"
    chmod 600 "$out"

    {
        printf '%-14s: %s\n' "Run timestamp"  "$RUN_TS"
        printf '%-14s: %s\n' "Analysis range" "$first ~ $last"
        printf '%-14s: %s\n' "Region"         "$OPT_REGION"
        printf '%-14s: %s\n' "Modules"        "${OPT_MODULES//,/, }"
        printf '%-14s: %s\n' "Output dir"     "$RUN_OUTPUT_DIR"
        printf '%-14s: %s\n' "Attach mode"    "$OPT_NOTIFY_ATTACH"

        if [[ -s "${dir}/overview_summary.txt" ]]; then
            LC_ALL=C gawk "$NOTIFY_BODY_AWK" "${dir}/overview_summary.txt"
        else
            fb=""
            if [[ -n "${NOTIFY_ATTACH_TSV:-}" && -f "$NOTIFY_ATTACH_TSV" ]]; then
                # SAFE pipe (unlike the build_date_list sites fixed for SIGPIPE):
                # the producer emits at most one line per persisted *_summary.txt
                # (a handful per run), far under the pipe buffer, so `head` never
                # closes the read end while `sort` -- which buffers all input
                # before writing a single byte -- is still writing. Do NOT copy
                # this `... | sort | head` idiom to an unbounded producer.
                fb="$(gawk -F'\t' '$1 == "ATTACH" && $2 ~ /_summary\.txt$/ { print $2 }' "$NOTIFY_ATTACH_TSV" | sort | head -n 1)"
            fi
            if [[ -n "$fb" ]]; then
                log_warn "overview_summary.txt not found; body falls back to: $fb"
                printf '(overview not run — showing %s)\n' "$fb"
                LC_ALL=C gawk "$NOTIFY_BODY_AWK" "${dir}/${fb}" | head -n 25
            else
                log_warn "no *_summary.txt found under $dir; body has no summary content"
                printf '(no summary view available for this run)\n'
            fi
        fi

        printf '\n'
        total_rows=0
        if [[ -n "${NOTIFY_ATTACH_TSV:-}" && -f "$NOTIFY_ATTACH_TSV" ]]; then
            total_rows="$(gawk 'END{print NR+0}' "$NOTIFY_ATTACH_TSV")"
        fi
        printf 'Attachments (%s):\n' "$total_rows"
        if [[ -n "${NOTIFY_ATTACH_TSV:-}" && -f "$NOTIFY_ATTACH_TSV" ]]; then
            while IFS=$'\t' read -r tag name bytes path; do
                if [[ "$tag" == "ATTACH" ]]; then
                    printf '  %-24s %8s bytes\n' "$name" "$bytes"
                else
                    printf '  %-24s SKIPPED (empty)\n' "$name"
                fi
            done < "$NOTIFY_ATTACH_TSV"
        fi

        printf '\n'
        printf 'Generated by log-parse. Full reports are attached and also retained at\n'
        printf '%s on the analysis host.\n' "$dir"
    } >> "$out"

    # Post-process (ALWAYS runs -- not conditional on size, unlike the old
    # plaintext-only cap; see NOTIFY_BODY_HTML_AWK above for the full
    # escape/cap/wrap mechanism and why). FIX A: $out crosses to gawk as an
    # OPERAND, never `-v` (same reason as _notify_file_bytes above -- a
    # backslash in the path, e.g. an --output-dir under 'C:\reports', must
    # never be silently rewritten by -v's C-string-escape processing).
    local html_tmp="${out}.html"
    if ! LC_ALL=C gawk -v cap="$NOTIFY_MAX_BODY_BYTES" "$NOTIFY_BODY_HTML_AWK" "$out" > "$html_tmp"; then
        rm -f "$html_tmp"
        die "notify: failed to HTML-escape/wrap body: $out"
    fi
    mv "$html_tmp" "$out" || die "notify: failed to install HTML body: $out"
    chmod 600 "$out"      || die "notify: failed to chmod HTML body: $out"
    return 0
}

# ---------------------------------------------------------------------------
# Subject derivation
# ---------------------------------------------------------------------------

# notify_subject
#   Purpose : Derive the mail Subject string (raw, not yet jesc-escaped --
#             the payload builder escapes whatever this returns).
#   Args    : none.
#   Output  : Subject string on stdout (no trailing newline).
#   Returns / Side effects : none.
#   Errors / Notes : LOG_PARSE_NOTIFY_SUBJECT, when set, wins verbatim over
#             both forms below (still passes through jesc() later, same as
#             every other string). Otherwise, derived from
#             build_date_list "${INTERVAL_ARGS[@]}" (rule 2 -- date math
#             stays in date_utils; NO `date` call at send time, which is what
#             makes test L19's two-dry-run cmp meaningful):
#               single-day range -> 【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-21
#               multi-day range  -> 【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-18 ~ 2026-05-25
#             Region is deliberately NOT in the subject (it already appears
#             on the body's Region line; the subject stays byte-identical to
#             the owner's example modulo the date).
notify_subject() {
    if [[ -n "${LOG_PARSE_NOTIFY_SUBJECT:-}" ]]; then
        printf '%s' "$LOG_PARSE_NOTIFY_SUBJECT"
        return 0
    fi
    # FIX I (SIGPIPE safety, this later review round -- see the
    # disambiguation note on notify_build_body's identical fix; unrelated to
    # notify_collect_attachments' own, earlier "FIX I" about TAB/newline
    # bytes in filenames). Pure parameter expansion instead of
    # `build_date_list ... | head -n 1` / `| tail -n 1`, which SIGPIPEs the
    # still-writing producer for any multi-day window under
    # `set -euo pipefail` (harmless today only by accident of notify_send's
    # `if` calling context, not by design).
    local all first last
    all="$(build_date_list "${INTERVAL_ARGS[@]}")" \
        || die "notify: cannot derive the analysis date range for the subject"
    first="${all%%$'\n'*}"
    last="${all##*$'\n'}"
    if [[ "$first" == "$last" ]]; then
        printf '【肺癌報告】 調閱紀錄彙整資訊 - %s' "$first"
    else
        printf '【肺癌報告】 調閱紀錄彙整資訊 - %s ~ %s' "$first" "$last"
    fi
}

# ---------------------------------------------------------------------------
# NOTIFY_JSON_FUNC — the ONE JSON string escaper in the repo
# ---------------------------------------------------------------------------
# Requires LC_ALL=C so length()/substr() operate on BYTES, never characters.
# Bytes >= 0x80 pass through verbatim: raw UTF-8 is legal JSON (RFC 8259
# §8.1), and byte-wise scanning provably cannot split a multi-byte sequence
# because every continuation byte is >= 0x80 and every byte jesc acts on
# specially is < 0x80.
NOTIFY_JSON_FUNC='
function jesc(s,   i, n, c, o, out) {
    n = length(s)
    out = ""
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        o = _ORD[c]
        if      (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (o == 8)    out = out "\\b"
        else if (o == 9)    out = out "\\t"
        else if (o == 10)   out = out "\\n"
        else if (o == 12)   out = out "\\f"
        else if (o == 13)   out = out "\\r"
        else if (o < 32 || o == 127) out = out sprintf("\\u%04x", o)
        else out = out c
    }
    return out
}
function jesc_init(   i) { for (i = 0; i < 256; i++) _ORD[sprintf("%c", i)] = i }
'

# notify_json_escape  (filter: stdin -> stdout)
#   Purpose : The single JSON string escaper entry point. Used for
#             attachment KEYS (filenames -- a filename is a JSON key and goes
#             through the SAME escaper as every value) and directly by tests.
#   Args    : none (reads stdin).
#   Output  : jesc()-escaped text on stdout, NO trailing newline.
#   Returns / Side effects : none.
#   Errors / Notes : multiple input lines are reconstructed with real
#             newlines, then escaped in ONE jesc() call, so an embedded LF
#             becomes the two-character sequence \n in the output -- the
#             same jesc() also used by NOTIFY_PAYLOAD_AWK, so there is
#             exactly one escaper in the repo (no second escaping path).
notify_json_escape() {
    LC_ALL=C gawk "$NOTIFY_JSON_FUNC"'
        BEGIN { jesc_init() }
        { buf = (NR == 1) ? $0 : buf "\n" $0 }
        END { printf "%s", jesc(buf) }
    '
}

# ---------------------------------------------------------------------------
# NOTIFY_PAYLOAD_AWK — payload prefix builder (From/To/Subject/Body)
# ---------------------------------------------------------------------------
NOTIFY_PAYLOAD_AWK='
# ----------------------------------------------------------------------------
# Purpose : Stream everything up to and including the literal `"Attachments":{`
#           -- the From object, the To array, Subject and Body -- every
#           string passed through jesc(). MUST be invoked with
#           $NOTIFY_JSON_FUNC prepended (defines jesc/jesc_init) and under
#           LC_ALL=C.
# Input   : File 1 = receivers TSV (NAME<TAB>ADDRESS, file order);
#           File 2 = body text file (arbitrary lines; joined by a real LF
#           before being escaped, exactly once).
# Vars    : recv_file  -- path of file 1 (FILENAME==var two-file join guard;
#           awk.md: FNR==NR is not used because it misclassifies an empty
#           first file).
#           from_name, from_addr -- From.DisplayName / From.Address (raw).
#           subj       -- pre-derived Subject string (raw, from notify_subject).
# Output  : the payload prefix text; the bash caller appends the attachment
#           map entries and the closing `}}`.
# Notes   : the final LF of the body file is intentionally not represented
#           (join semantics: N lines join with N-1 separators) -- documented,
#           deterministic behaviour, not a bug.
# ----------------------------------------------------------------------------
BEGIN {
    jesc_init()
    to_buf = ""
    to_n = 0
    body_buf = ""
    body_n = 0
}
FILENAME == recv_file {
    n = split($0, F, "\t")
    if (n < 2) next
    if (to_n > 0) to_buf = to_buf ","
    to_buf = to_buf "{\"DisplayName\":\"" jesc(F[1]) "\",\"Address\":\"" jesc(F[2]) "\"}"
    to_n++
    next
}
{
    body_buf = (body_n == 0) ? $0 : body_buf "\n" $0
    body_n++
}
END {
    printf "{\"From\":{\"DisplayName\":\"%s\",\"Address\":\"%s\"},", jesc(from_name), jesc(from_addr)
    printf "\"To\":[%s],", to_buf
    printf "\"Subject\":\"%s\",", jesc(subj)
    printf "\"Body\":\"%s\",", jesc(body_buf)
    printf "\"Attachments\":{"
}
'

# notify_build_payload OUT_FILE
#   Purpose : Assemble the complete JSON payload document at OUT_FILE, in
#             three streamed phases, with NO whole-file buffering anywhere
#             (the base64 blob is never held in a shell or gawk variable).
#   Args    : OUT_FILE — payload path.
#   Output  : nothing on stdout. Writes OUT_FILE, mode 0600 (created and
#             chmod'd BEFORE any content is written, under the umask 077
#             notify_send already set -- closes the create-then-chmod
#             window, CWE-377).
#   Returns / Side effects : returns 0 on success. Returns 1 -- with a
#             specific log_error already emitted -- on ANY write failure
#             (disk full, permissions) or on an encoded attachment failing
#             the ^[A-Za-z0-9+/=]*$ canonical-alphabet assertion; the two
#             causes are deliberately DISTINGUISHED (via PIPESTATUS, FIX H)
#             so a full disk is never misreported as "base64 output is not
#             canonical". Callers MUST check the return value and die() --
#             ambient `errexit` is inert here because notify_send invokes
#             this chain inside an `if`, so a full disk mid-write must never
#             be allowed to yield a truncated-but-"successful" payload.
#   Errors / Notes : Reads NOTIFY_RECEIVERS_TSV, NOTIFY_ATTACH_TSV, the body
#             file written by notify_build_body, NOTIFY_FROM_NAME,
#             NOTIFY_FROM_ADDR, notify_subject. NOTIFY_RECEIVERS_TSV (a bash
#             string) and the body file (a fixed path convention, see below)
#             are the two file arguments to NOTIFY_PAYLOAD_AWK.
#             Fixed filename convention within NOTIFY_WORKDIR (same pattern
#             notify_post uses for notify_resp/notify_meta/notify_err):
#               notify_receivers.tsv -- materialised here from the
#                 NOTIFY_RECEIVERS_TSV string (gawk needs a real file for the
#                 FILENAME==var two-file join).
#               notify_body.txt -- written earlier by notify_send's call to
#                 notify_build_body.
#             base64 is unwrapped via `base64 < f | gawk '"'"'{printf "%s",$0}'"'"'`
#             (never -w0, which is GNU-only) and validated in the SAME gawk
#             pass before the closing quote is written. An empty attachment
#             set yields the literal `"Attachments":{}` (boundary-tested,
#             valid JSON).
notify_build_payload() {
    local out="$1"
    local recv_file="${NOTIFY_WORKDIR}/notify_receivers.tsv"
    local body_file="${NOTIFY_WORKDIR}/notify_body.txt"
    local subj
    subj="$(notify_subject)"

    # FIX H: every write below is checked explicitly -- ambient `errexit` is
    # inert here (notify_send calls this chain inside an `if`), so without
    # this a full disk or a permissions failure mid-write could otherwise
    # yield a truncated-but-"successful" payload that still gets POSTed.
    : > "$recv_file"       || { log_error "notify: cannot create $recv_file"; return 1; }
    chmod 600 "$recv_file" || { log_error "notify: cannot chmod $recv_file"; return 1; }
    printf '%s\n' "$NOTIFY_RECEIVERS_TSV" >> "$recv_file" \
        || { log_error "notify: cannot write $recv_file (disk full?)"; return 1; }

    : > "$out"       || { log_error "notify: cannot create $out"; return 1; }
    chmod 600 "$out" || { log_error "notify: cannot chmod $out"; return 1; }

    # See load_receivers' addr_re_gv comment: gawk's `-v var=value` applies
    # C-string escape processing to value, so any operator-supplied From
    # name/address (LOG_PARSE_NOTIFY_FROM_NAME/_ADDR) or Subject
    # (LOG_PARSE_NOTIFY_SUBJECT) that happens to contain a literal backslash
    # must have it doubled before crossing the -v boundary, or gawk would
    # silently reinterpret/drop it -- BEFORE jesc() ever sees the byte. FIX
    # A: recv_file itself crosses -v too, but ONLY so NOTIFY_PAYLOAD_AWK's
    # `FILENAME == recv_file` two-file-join guard (awk.md) can compare it
    # against FILENAME (which gawk derives from the UNESCAPED operand
    # below) -- doubling here and leaving the operand list raw means both
    # sides resolve to the SAME original path, so the join still matches
    # even when recv_file contains a backslash.
    local from_name_gv="${NOTIFY_FROM_NAME//\\/\\\\}"
    local from_addr_gv="${NOTIFY_FROM_ADDR//\\/\\\\}"
    local subj_gv="${subj//\\/\\\\}"
    local recv_file_gv="${recv_file//\\/\\\\}"

    LC_ALL=C gawk \
        -v recv_file="$recv_file_gv" \
        -v from_name="$from_name_gv" \
        -v from_addr="$from_addr_gv" \
        -v subj="$subj_gv" \
        "$NOTIFY_JSON_FUNC$NOTIFY_PAYLOAD_AWK" \
        "$recv_file" "$body_file" > "$out" \
        || { log_error "notify: failed to render payload prefix to $out"; return 1; }

    local first=1 tag name bytes path key
    if [[ -n "${NOTIFY_ATTACH_TSV:-}" && -f "$NOTIFY_ATTACH_TSV" ]]; then
        while IFS=$'\t' read -r tag name bytes path; do
            [[ "$tag" == "ATTACH" ]] || continue
            if [[ "$first" -eq 0 ]]; then
                printf ',' >> "$out" || { log_error "notify: failed writing payload separator (disk full?)"; return 1; }
            fi
            first=0
            key="$(printf '%s' "$name" | notify_json_escape)" \
                || { log_error "notify: failed to escape attachment name: $name"; return 1; }
            printf '"%s":"' "$key" >> "$out" \
                || { log_error "notify: failed writing attachment key for $name (disk full?)"; return 1; }

            # Two independent failure modes down this one pipeline, kept
            # DISTINCT via PIPESTATUS (FIX H) so a full disk mid-write is
            # never misreported as the unrelated "base64 output is not
            # canonical" message: PIPESTATUS[0] is base64's own exit code;
            # PIPESTATUS[1] is the validating/streaming gawk's.
            base64 < "$path" | gawk '
                { if ($0 !~ /^[A-Za-z0-9+\/=]*$/) { exit 3 }
                  printf "%s", $0 }
            ' >> "$out"
            local b64_rc=${PIPESTATUS[0]} enc_rc=${PIPESTATUS[1]}
            if [[ "$b64_rc" -ne 0 ]]; then
                log_error "notify: base64 encoding failed (exit $b64_rc) reading attachment: $name ($path)"
                return 1
            fi
            if [[ "$enc_rc" -eq 3 ]]; then
                log_error "notify: base64 output is not canonical for: $name"
                return 1
            elif [[ "$enc_rc" -ne 0 ]]; then
                log_error "notify: failed writing base64 payload for $name (exit $enc_rc; disk full?)"
                return 1
            fi

            printf '"' >> "$out" \
                || { log_error "notify: failed writing attachment closing quote for $name (disk full?)"; return 1; }
        done < "$NOTIFY_ATTACH_TSV"
    fi

    printf '}}' >> "$out" || { log_error "notify: failed writing payload closing braces (disk full?)"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# notify_post PAYLOAD
#   Purpose : POST the payload file to $OPT_NOTIFY_URL and classify the result.
#   Args    : PAYLOAD — path to the assembled JSON payload file.
#   Output  : nothing on stdout. Writes $NOTIFY_WORKDIR/notify_resp
#             (response body), notify_meta (http_code + time_total),
#             notify_err (curl's own stderr).
#   Returns / Side effects : sets NOTIFY_HTTP_CODE, NOTIFY_TIME_MS,
#             NOTIFY_CURL_EXIT. Returns 0 on HTTP 2xx, 1 otherwise. NEVER
#             dies -- the caller (notify_send / notify_run) decides fatality.
#   Errors / Notes : the payload is passed ONLY as --data-binary "@path" --
#             never on argv, never via --data (which strips newlines/CRs and
#             would corrupt the JSON), never via stdin. No --retry (D12
#             correction H: the API defines no idempotency mechanism, so a
#             retry after a lost response risks a duplicate send). Only
#             header sent is Content-Type: application/json -- no auth
#             header exists in the contract. --max-redirs 0 and
#             --proto '='"'"'http,https'"'"' bound where the payload can go
#             (CWE-918). Logged error/response bodies are capped at
#             NOTIFY_RESP_LOG_BYTES via _notify_head_bytes (CWE-214).
notify_post() {
    local payload="$1"
    local rc=0
    "${LOG_PARSE_NOTIFY_CURL_BIN:-curl}" \
        --silent --show-error \
        --request POST \
        --header 'Content-Type: application/json' \
        --data-binary "@${payload}" \
        --connect-timeout "$NOTIFY_CONNECT_TIMEOUT" \
        --max-time "$NOTIFY_MAX_TIME" \
        --max-redirs 0 \
        --proto '=http,https' \
        --output "$NOTIFY_WORKDIR/notify_resp" \
        --write-out '%{http_code} %{time_total}' \
        "$OPT_NOTIFY_URL" \
        > "$NOTIFY_WORKDIR/notify_meta" 2> "$NOTIFY_WORKDIR/notify_err" || rc=$?
    NOTIFY_CURL_EXIT="$rc"

    if (( rc != 0 )); then
        NOTIFY_HTTP_CODE=000
        NOTIFY_TIME_MS=0
        log_error "notify: curl transport failure (exit $rc)"
        if [[ -s "$NOTIFY_WORKDIR/notify_err" ]]; then
            log_error "notify: $(_notify_head_bytes "$NOTIFY_WORKDIR/notify_err" "$NOTIFY_RESP_LOG_BYTES")"
        fi
        return 1
    fi

    local code time_s
    read -r code time_s < "$NOTIFY_WORKDIR/notify_meta"
    NOTIFY_HTTP_CODE="$code"
    NOTIFY_TIME_MS="$(gawk -v t="$time_s" 'BEGIN{printf "%d", t*1000}')"

    if (( code >= 200 && code < 300 )); then
        return 0
    fi

    log_error "notify failed — HTTP $code"
    if [[ -s "$NOTIFY_WORKDIR/notify_resp" ]]; then
        log_error "$(_notify_head_bytes "$NOTIFY_WORKDIR/notify_resp" "$NOTIFY_RESP_LOG_BYTES")"
    fi
    return 1
}

# notify_result_line STATUS REASON
#   Purpose : Emit exactly one machine-parseable NOTIFY_RESULT stderr line
#             per run -- the single grep-able marker for automation/audits.
#   Args    : STATUS — sent|dry-run|skipped|failed; REASON — closed token:
#             -, attachment_too_large:<name>, total_too_large, http_error,
#             curl_exit_<n>, payload_write_failed, dry_run.
#   Output  : one line on stderr (via log_info for sent/dry-run, log_error
#             for skipped/failed).
#   Returns / Side effects : none.
#   Errors / Notes : to/files/skipped_empty/raw_bytes/b64_bytes are derived
#             from NOTIFY_RECEIVERS_TSV / NOTIFY_ATTACH_TSV via
#             _notify_attach_totals (single source, shared with notify_send's
#             own info/audit lines); payload_bytes is measured from
#             NOTIFY_PAYLOAD_PATH (set by notify_send; falls back to the
#             historical $NOTIFY_WORKDIR/notify_payload.json convention for
#             any caller that invokes this without going through
#             notify_send). No attempts= field (retries are removed, §8.1);
#             no cc=/bcc= fields (the contract has no such recipients).
notify_result_line() {
    local status="$1" reason="$2"
    local to=0 files skipped raw b64 payload_bytes=0

    if [[ -n "${NOTIFY_RECEIVERS_TSV:-}" ]]; then
        to="$(printf '%s\n' "$NOTIFY_RECEIVERS_TSV" | gawk -F'\t' 'NF>=2{n++} END{print n+0}')"
    fi
    read -r files skipped raw b64 <<< "$(_notify_attach_totals)"

    # NOTIFY_PAYLOAD_PATH is set by notify_send immediately before it calls
    # notify_build_payload (dry-run -> under RUN_DIR; real send -> under
    # $NOTIFY_WORKDIR; see the ORCHESTRATOR OVERRIDE comment there). The
    # fallback keeps this function safe for any caller that invokes it
    # without going through notify_send.
    local payload_file="${NOTIFY_PAYLOAD_PATH:-${NOTIFY_WORKDIR:-}/notify_payload.json}"
    if [[ -n "$payload_file" && -f "$payload_file" ]]; then
        # FIX A/E: shared helper -- operand-based (no `-v` path-crossing;
        # dry-run's payload_file is under RUN_OUTPUT_DIR, which inherits
        # whatever --output-dir the operator gave, backslash included) and
        # byte-exact (no "+1 per line" assumption). This is a summary/audit
        # metric, not a correctness gate -- the send/dry-run already
        # succeeded by the time this line is emitted -- so an unreadable
        # payload here degrades to a logged warning and payload_bytes=0
        # rather than a fresh die (unlike the fatal treatment an unreadable
        # ATTACHMENT gets in notify_collect_attachments).
        if ! payload_bytes="$(_notify_file_bytes "$payload_file")"; then
            log_warn "notify: could not measure payload size for result line: $payload_file"
            payload_bytes=0
        fi
    fi

    local line
    line="$(printf 'NOTIFY_RESULT status=%s http=%s ms=%s to=%s files=%s skipped_empty=%s raw_bytes=%s b64_bytes=%s payload_bytes=%s run_ts=%s reason=%s' \
        "$status" "${NOTIFY_HTTP_CODE:--}" "${NOTIFY_TIME_MS:-0}" "$to" "$files" "$skipped" "$raw" "$b64" "$payload_bytes" "${RUN_TS:--}" "$reason")"

    case "$status" in
        sent|dry-run) log_info  "$line" ;;
        *)            log_error "$line" ;;
    esac
}

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

# notify_send RUN_DIR
#   Purpose : The public library entry point -- validate, enumerate, build
#             the body + payload, then (unless dry-run) POST it.
#   Args    : RUN_DIR — a run's persisted output directory (RUN_OUTPUT_DIR).
#   Output  : nothing on stdout (rule 3). stderr: recipient/file audit
#             warnings, external-domain warnings, plain-HTTP warning, the
#             NOTIFY_RESULT marker line.
#   Returns / Side effects : writes scratch files under $NOTIFY_WORKDIR. The
#             one documented exception is the --notify-dry-run payload,
#             written to $RUN_DIR/notify_payload.json (mode 0600) instead --
#             see the ORCHESTRATOR OVERRIDE comment at the NOTIFY_PAYLOAD_PATH
#             assignment below for why, and why it cannot self-attach. A real
#             send never writes inside RUN_DIR. Returns 0 on success or
#             dry-run, 1 on any delivery failure. Dies only on a
#             configuration/validation defect (bad RUN_DIR, bad From address,
#             bad receivers.conf).
#   Errors / Notes : Sequence: preflight -> validate RUN_DIR -> acquire a
#             tmpdir (init_tmpdir ONLY if the caller has not already set
#             WORK_TMPDIR -- see the header docblock's documented exception)
#             -> validate From address -> load receivers -> enumerate
#             attachments, PLUS the report-export deliverable when present
#             (cap breach returns 1 with no curl call at all; see
#             notify_collect_attachments' EXTRA parameter) ->
#             recipient/file audit + external-domain warnings -> build body
#             -> build payload -> dry-run short-circuit, or POST + result line.
#             The recipient/file audit line is emitted AFTER attachment
#             collection (not before, as a strict top-to-bottom reading of
#             the design spec's numbered sequence would place it) so that
#             "every attached file" in the audit trail (CWE-200, §9) names
#             the FINAL, mode-filtered, cap-checked set actually sent, not a
#             coarse pre-filter directory listing that could differ from it.
notify_send() {
    local run_dir="$1"
    notify_preflight
    if [[ ! -d "$run_dir" ]]; then die "run dir not found: $run_dir"; fi

    if [[ -z "${WORK_TMPDIR:-}" ]]; then init_tmpdir; fi
    NOTIFY_WORKDIR="$WORK_TMPDIR"
    umask 077

    notify_assert_address "LOG_PARSE_NOTIFY_FROM_ADDR" "$NOTIFY_FROM_ADDR"

    # BUG FIX: this function is invoked by notify_run as `if notify_send
    # ...; then`, and bash disables errexit for the ENTIRE body of any
    # function used as an if/while/until condition -- not only its direct
    # condition command. A bare `NOTIFY_RECEIVERS_TSV="$(load_receivers
    # ...)"` therefore can never auto-abort here even though load_receivers
    # dies internally on every malformed-config case (see load_receivers's
    # own docblock): that die's exit only ends the command-substitution
    # subshell it fires inside, leaving NOTIFY_RECEIVERS_TSV silently empty
    # and the run reporting a false "sent"/"dry-run" success with zero
    # recipients -- confirmed by Section E (E31-E34, E37) before this fix.
    # load_receivers has already printed the specific gawk diagnostic AND
    # its own "invalid receivers config: <path>" bash-layer line to the
    # real stderr fd (neither is buffered by the subshell) before this
    # check runs, so the explicit test below is what actually makes the
    # failure fatal; the die() message matches docs/usage.md's own
    # "gawk failed (bash layer)" row, so nothing new is invented here.
    #
    # FIX F: bin/log_report.sh's parse_args now performs and CACHES this
    # exact validation before persist_init ever runs (so a malformed
    # receivers.conf surfaces before any analysis module executes, not
    # after). Reuse that cached value here instead of re-parsing when it is
    # already populated. Direct-library callers that invoke notify_send
    # without going through parse_args (unit tests; docs/design.md §3.4.7
    # mechanism 3) start with an empty cache, so they still get full
    # validation right here, unchanged from before FIX F.
    if [[ -z "$NOTIFY_RECEIVERS_TSV" ]]; then
        if ! NOTIFY_RECEIVERS_TSV="$(load_receivers "$RECEIVERS_CONF")"; then
            die "invalid receivers config: $RECEIVERS_CONF"
        fi
    fi

    NOTIFY_ATTACH_TSV="${NOTIFY_WORKDIR}/notify_attach.tsv"
    local collect_rc=0
    # 4th arg: the report-export xlsx deliverable (lib/report_export_utils.sh),
    # when --report-export produced one this run; "" (unset-safe via :-)
    # otherwise, in which case notify_collect_attachments behaves exactly as
    # it always did for the pre-existing three-argument call shape.
    notify_collect_attachments "$run_dir" "$OPT_NOTIFY_ATTACH" "$NOTIFY_ATTACH_TSV" "${REPORT_EXPORT_DELIVERABLE_PATH:-}" || collect_rc=$?
    if [[ "$collect_rc" -eq 2 ]]; then
        notify_result_line skipped "$NOTIFY_SKIP_REASON"
        return 1
    elif [[ "$collect_rc" -ne 0 ]]; then
        die "notify: attachment collection failed unexpectedly (rc=$collect_rc)"
    fi

    # Recipient + file audit -- unsuppressable permanent log trail (CWE-200).
    local addr_list file_list n_attach skipped_total raw_total b64_total
    addr_list="$(printf '%s\n' "$NOTIFY_RECEIVERS_TSV" | gawk -F'\t' 'NF>=2{ printf "%s%s", (n++?", ":""), $2 }')"
    file_list="$(gawk -F'\t' '$1=="ATTACH"{ printf "%s%s", (n++?", ":""), $2 }' "$NOTIFY_ATTACH_TSV")"
    read -r n_attach skipped_total raw_total b64_total <<< "$(_notify_attach_totals)"
    log_warn "notify: sending ${n_attach} attachment(s) to: ${addr_list} -- files: ${file_list}"

    # FIX C: TAB is bash IFS *whitespace* regardless of what IFS is set to,
    # so `IFS=$'\t' read -r rname raddr` silently collapses/strips a LEADING
    # tab -- exactly what an accepted row with an empty DISPLAY_NAME
    # produces (NAME<TAB>ADDR with NAME==""). That shifted `raddr` into
    # emptiness, so `[[ -n "$raddr" ]] || continue` silently dropped the row
    # from the external-recipient audit entirely. Fix: let gawk -F'\t' do
    # the field split instead (a literal single-char FS does NOT collapse
    # or strip, unlike bash's IFS-whitespace `read`) and hand bash only the
    # already-correct address column -- exactly the sibling `addr_list`
    # idiom two blocks above.
    local internal_doms=" ${LOG_PARSE_NOTIFY_INTERNAL_DOMAINS:-} " raddr dom
    while IFS= read -r raddr; do
        [[ -n "$raddr" ]] || continue
        dom="${raddr#*@}"
        dom="${dom,,}"
        if [[ "$internal_doms" != *" $dom "* ]]; then
            log_warn "recipient on external domain: $raddr"
        fi
    done < <(printf '%s\n' "$NOTIFY_RECEIVERS_TSV" | gawk -F'\t' 'NF>=2{print $2}')

    notify_build_body "$run_dir" "${NOTIFY_WORKDIR}/notify_body.txt"

    # ORCHESTRATOR OVERRIDE (supersedes this file's original "$NOTIFY_WORKDIR
    # always" design): a dry run exists ONLY so the operator can inspect the
    # built payload, but init_tmpdir (lib/common.sh) installs an EXIT trap
    # that rm -rf's $WORK_TMPDIR when this process exits -- a payload left
    # there is already gone by the time anyone looks. $run_dir is this run's
    # own persisted output directory, where its report files already live,
    # so it is the correct home for this artifact of the run too.
    #
    # FIX B -- the REAL self-attachment guarantee (corrected; the previous
    # comment here claimed "collection precedes the write", which only
    # holds WITHIN one process and is false across two separate invocations
    # that share a directory via a pinned LOG_PARSE_RUN_TS, a documented,
    # supported knob (lib/output_utils.sh): a second run's
    # notify_collect_attachments would then enumerate the FIRST run's
    # already-written notify_payload.json as a real, on-disk file and
    # attach it. The actual guarantee is structural, not ordering-based:
    # notify_collect_attachments unconditionally excludes the literal
    # filename `notify_payload.json` from its enumeration, in every
    # --notify-attach mode, so the payload can never be attached by THIS
    # run or by any LATER run that reuses this directory, regardless of
    # write order.
    #
    # A real send has no inspection need -- curl consumes the file within
    # this same process -- so it keeps the historical, purely-transient
    # $NOTIFY_WORKDIR location.
    if [[ "$OPT_NOTIFY_DRY_RUN" -eq 1 ]]; then
        NOTIFY_PAYLOAD_PATH="${run_dir}/notify_payload.json"
    else
        NOTIFY_PAYLOAD_PATH="${NOTIFY_WORKDIR}/notify_payload.json"
    fi
    notify_build_payload "$NOTIFY_PAYLOAD_PATH" \
        || die "notify: failed to build payload (see error above): $NOTIFY_PAYLOAD_PATH"

    if [[ "$OPT_NOTIFY_DRY_RUN" -eq 1 ]]; then
        notify_result_line dry-run dry_run
        log_info "payload written: ${NOTIFY_PAYLOAD_PATH}"
        return 0
    fi

    if [[ "$OPT_NOTIFY_URL" == http:* ]]; then
        log_warn "endpoint is plain HTTP; the payload including attachments is unencrypted: $OPT_NOTIFY_URL"
    fi
    log_info "Notify: POST ${OPT_NOTIFY_URL} (${n_attach} attachments, ${raw_total} bytes)"

    if notify_post "$NOTIFY_PAYLOAD_PATH"; then
        notify_result_line sent -
        return 0
    fi

    local reason
    if [[ "$NOTIFY_HTTP_CODE" == "000" ]]; then
        reason="curl_exit_${NOTIFY_CURL_EXIT:-1}"
    else
        reason="http_error"
    fi
    notify_result_line failed "$reason"
    return 1
}

# notify_run — the bin/log_report.sh adapter; the only call site outside tests.
#   Purpose : Run the notify stage if and only if --notify was given, and
#             turn a delivery failure into a fatal error (D12, §8.2).
#   Args    : none.
#   Output  : none directly (delegates to notify_send).
#   Returns / Side effects : returns 0 when --notify was not given, or on a
#             successful send/dry-run. Dies otherwise.
#   Errors / Notes : Fatal by design: the operator explicitly asked for a
#             notification, so a run that could not deliver it did not do
#             what was asked; there is no cheap resend path (no
#             bin/send_report.sh); CLAUDE.md rule 1 is fail fast, loud.
#             Tolerance is composed by the caller, not flagged:
#               bash bin/log_report.sh --log-dir ... --notify || true
notify_run() {
    if [[ "$OPT_NOTIFY" -ne 1 ]]; then return 0; fi
    if notify_send "$RUN_OUTPUT_DIR"; then return 0; fi
    die "notify failed; reports are intact in $RUN_OUTPUT_DIR (see the NOTIFY_RESULT line above)"
}
