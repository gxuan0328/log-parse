#!/usr/bin/env bash
# lib/report_export_utils.sh — report-export container integration. Sourced only.
#
# Opt-in, single-shot, post-analysis export stage for `bin/log_report.sh
# --report-export`. Runs the report-export:1.0.0 Docker image against this
# run's persisted access_detail.csv and publishes the container-authored
# xlsx deliverable's HOST path so notify_send can attach it to the SMTP
# payload, in addition to the run directory's own reports.
#
# docker is a CONDITIONAL runtime dependency (a narrow, recorded deviation
# from CLAUDE.md §6, alongside curl/base64; see docs/design.md §4.10): it is
# named ONLY in this file, gated lazily behind report_export_preflight, and
# never touched unless --report-export is actually requested (test M01
# proves the converse).
#
# Globals (sanctioned, documented):
#   REPORT_EXPORT_PREFLIGHT_DONE (int)  — idempotency guard for
#     report_export_preflight.
#   REPORT_EXPORT_PROD_DIR  (path) — <output-dir>/production, ABSOLUTE, set
#     by report_export_prepare_dirs.
#   REPORT_EXPORT_IN_DIR    (path) — REPORT_EXPORT_PROD_DIR/input.
#   REPORT_EXPORT_STATE_DIR (path) — REPORT_EXPORT_PROD_DIR/state.
#   REPORT_EXPORT_OUT_DIR   (path) — REPORT_EXPORT_PROD_DIR/output.
#   REPORT_EXPORT_WEEK_DATE (string) — YYYY-MM-DD, the analysis window START;
#     set by report_export_run before staging (report_export_window_start).
#   REPORT_EXPORT_DELIVERABLE_PATH (path) — HOST path of the validated xlsx;
#     set by _report_export_select_deliverable; read by notify_send's call
#     site (lib/notify_utils.sh) as notify_collect_attachments' 4th arg.
#   _RE_START_EPOCH (int) — `date +%s` recorded immediately before the
#     docker invocation (report_export_invoke); the freshness floor a
#     reported deliverable's mtime must clear (_report_export_select_deliverable).
#
# Env contract (all optional; every variable also appears, reproduced
# verbatim, in the "Report export" section of docs/usage.md):
#   LOG_PARSE_REPORT_EXPORT_DOCKER_BIN  default: docker
#   LOG_PARSE_REPORT_EXPORT_IMAGE       default: report-export:1.0.0
#   LOG_PARSE_REPORT_EXPORT_USER        default: (empty) -- OPT-IN. Empty
#     means no `--user` argument is emitted at all (the rendered docker
#     command is then EXACTLY the owner's literal command line and the
#     container runs as root, matching the image's own no-USER-directive
#     design). A non-empty value must match ^[0-9]+(:[0-9]+)?$ and is passed
#     verbatim to `docker run --user`.
#
# Public function surface (call order mirrors report_export_run's sequence):
#   report_export_preflight, report_export_assert_image_ref,
#   report_export_assert_user_spec, report_export_prepare_dirs,
#   report_export_window_start, report_export_stage_input,
#   _report_export_same_bytes, report_export_invoke,
#   _report_export_parse_summary, _report_export_select_deliverable,
#   report_export_result_line, report_export_run.
#
# Conventions:
#   - Source this file; do not execute directly.
#   - Never call init_tmpdir from a library -- bin/log_report.sh hoists ONE
#     init_tmpdir call ahead of BOTH --report-export and --notify (see
#     bin/log_report.sh main(); lib/common.sh:120 -- init_tmpdir is NOT
#     idempotent, so it must never be called twice in one process).
#   - Never call exit except via die (directly, or via the private
#     _report_export_die wrapper below).
#   - All log output goes to STDERR; stdout = report content (rule 3). The
#     container's own stdout is captured to a FILE, never inherited, so it
#     can never reach log_report.sh's report stdout (tests M19/M20).
#   - No new UNCONDITIONAL dependency: docker is named ONLY in this file and
#     only reached through report_export_preflight.

# ---------------------------------------------------------------------------
# Constants (env-overridable where noted; deliberately NOT `readonly` -- this
# file may be sourced more than once within a single process across test
# blocks that reuse a shell, exactly like lib/notify_utils.sh's identical
# rationale; a `readonly` re-assignment would abort with "readonly variable"
# on the second source.)
# ---------------------------------------------------------------------------
REPORT_EXPORT_DEFAULT_IMAGE="report-export:1.0.0"

# Anchored whitelist for the container-reported deliverable basename (§2.2
# step 3 of the design spec). Any '/', any '..', any leading '-', any
# control character, or any other shape fails this match by construction --
# the anchoring (^...$) leaves no room for extra bytes before or after the
# exact expected shape, so no separate traversal/leading-dash check is
# needed alongside it.
REPORT_EXPORT_DELIVERABLE_NAME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}_連線紀錄(_[0-9]{2})?\.xlsx$'
REPORT_EXPORT_DELIVERABLE_PREFIX='/data/output/'

# Image reference whitelist: no leading '-' (blocks flag injection via
# LOG_PARSE_REPORT_EXPORT_IMAGE, CWE-88), optional registry-host[:port]/
# prefix, optional additional /path segments, optional :tag or
# @sha256:digest. FIX H: the previous shape anchored a single optional
# `:tag` group at the very end and excluded ':' from the name class
# entirely, so a registry WITH a port (e.g.
# "registry.example.com:5000/report-export:1.0.0", advertised as supported
# by docs/usage.md's "configurable image" wording) had two colons and could
# never match. `(:[0-9]+)?` after the first component and `(/[...]+)*` for
# repeated path segments admit that shape while the leading `[A-Za-z0-9]`
# anchor (no '-') keeps closing the CWE-88 flag-injection hole exactly as
# before; empirically verified (see M-section tests) against both the
# default "report-export:1.0.0" (no registry) and a ported-registry
# reference, plus a battery of hostile inputs (leading '-', embedded ';',
# short/invalid sha256).
REPORT_EXPORT_IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?(/[A-Za-z0-9._-]+)*(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]{64})?$'

# --user spec whitelist: digits only, optional :gid. Emptiness is handled
# separately by report_export_assert_user_spec (opt-out is legal).
REPORT_EXPORT_USER_RE='^[0-9]+(:[0-9]+)?$'

# ---------------------------------------------------------------------------
# Cross-call state (sanctioned; mirrors the NOTIFY_* style in lib/notify_utils.sh)
# ---------------------------------------------------------------------------
REPORT_EXPORT_PREFLIGHT_DONE=0
REPORT_EXPORT_PROD_DIR=""
REPORT_EXPORT_IN_DIR=""
REPORT_EXPORT_STATE_DIR=""
REPORT_EXPORT_OUT_DIR=""
REPORT_EXPORT_WEEK_DATE=""
REPORT_EXPORT_DELIVERABLE_PATH=""
_RE_START_EPOCH=""

# ---------------------------------------------------------------------------
# Dependency gate
# ---------------------------------------------------------------------------

# report_export_preflight
#   Purpose : Verify docker is present and the report-export image is built/
#             pulled and inspectable, BEFORE any analyzer subprocess runs.
#             Also validates the image ref and the OPT-IN user spec here, so
#             both surface pre-analysis. Idempotent (REPORT_EXPORT_PREFLIGHT_DONE).
#   Args    : none.
#   Output  : nothing on success; two ERROR lines on stderr when docker is
#             missing (see docs/usage.md "Report export").
#   Returns / Side effects : returns 0; sets REPORT_EXPORT_PREFLIGHT_DONE=1.
#             Exits 1 via die/require_cmds on a missing/misconfigured
#             dependency -- never returns non-zero.
#   Errors / Notes : Two call sites (both idempotent): bin/log_report.sh
#             parse_args (offline pre-flight -- a missing docker, or a bad
#             image/user spec, is a sub-second failure, not a post-analysis
#             surprise) and report_export_run's first statement (point of
#             use, for direct-library callers that bypass parse_args). Die
#             messages here are NEVER suffixed with "reports are intact in
#             ..." and never emit a REPORT_EXPORT_RESULT line: this function
#             fires, on the normal CLI path, BEFORE persist_init has
#             resolved a run directory at all (§11.1 rows 1-5: reason="-").
#             `docker image inspect` gives daemon-reachability AND image-
#             presence in one round trip, local, read-only, sub-second, and
#             runs before any analysis burn; it is TOCTOU-racy against the
#             later `docker run`, and that race is accepted -- the value
#             here is failure TIMING, not a correctness guarantee (the
#             `docker run` itself remains authoritative). No automatic
#             `docker pull`, ever: an unattended job must not reach a
#             registry, and a silent pull would hide image-version drift.
report_export_preflight() {
    if [[ "$REPORT_EXPORT_PREFLIGHT_DONE" -eq 1 ]]; then return 0; fi

    local docker_bin="${LOG_PARSE_REPORT_EXPORT_DOCKER_BIN:-docker}"
    if ! command -v "$docker_bin" >/dev/null 2>&1; then
        log_error "--report-export needs the optional dependency 'docker' (container runtime that runs the report-export image)."
        log_error "Install docker, or drop --report-export to produce the analysis reports only."
        die "missing required commands: docker"
    fi

    local image="${LOG_PARSE_REPORT_EXPORT_IMAGE:-$REPORT_EXPORT_DEFAULT_IMAGE}"
    report_export_assert_image_ref "$image"

    # OPT-IN --user (ORCHESTRATOR OVERRIDE: default is empty -- no --user is
    # emitted and the container runs as root, matching the owner's literal
    # docker command line; see report_export_invoke). Validated here,
    # pre-analysis, exactly like the image ref, so a typo'd override is
    # never discovered only after a multi-minute analysis burn. Not part of
    # the design spec's verbatim report_export_preflight body (which predates
    # the override); added per the override's own instruction to "adjust ...
    # the spec's ... uid decision ... accordingly" and per §11.1 row 4's own
    # requirement that an invalid user spec is detected at parse_args
    # (pre-analysis) -- the only pre-analysis call site available is this
    # function's two call sites.
    report_export_assert_user_spec "${LOG_PARSE_REPORT_EXPORT_USER:-}"

    # Daemon reachability AND image presence in one round trip. Local,
    # read-only, sub-second, and it runs BEFORE any analysis burn.
    if ! "$docker_bin" image inspect "$image" >/dev/null 2>&1; then
        die "docker image inspect failed for '$image' (daemon unreachable, or the image is not built/pulled on this host); build it with: docker build -t $image -f docker/Dockerfile .   (run from report-export/)"
    fi

    REPORT_EXPORT_PREFLIGHT_DONE=1
}

# report_export_assert_image_ref REF
#   Purpose : Fail-fast guard that REF cannot be interpreted as a docker flag
#             and is a syntactically legal image reference.
#   Args    : REF — candidate image reference (LOG_PARSE_REPORT_EXPORT_IMAGE
#             or its default).
#   Output  : nothing on success.
#   Returns / Side effects : never returns on failure -- exits via die().
#   Errors / Notes : Anchored whitelist (no leading '-', optional :tag or
#             @sha256:digest suffix) closes CWE-88: a value such as
#             "--privileged" cannot become a docker flag because a leading
#             '-' is rejected outright by the anchor.
report_export_assert_image_ref() {
    local ref="$1"
    if [[ ! "$ref" =~ $REPORT_EXPORT_IMAGE_RE ]]; then
        die "report-export: invalid image reference: '$ref'"
    fi
}

# report_export_assert_user_spec SPEC
#   Purpose : Fail-fast guard that SPEC is either empty (opt out of --user
#             entirely -- the default) or a plain uid[:gid] docker accepts.
#   Args    : SPEC — LOG_PARSE_REPORT_EXPORT_USER value (may be "").
#   Output  : nothing on success.
#   Returns / Side effects : never returns on failure -- exits via die().
#   Errors / Notes : ORCHESTRATOR OVERRIDE: LOG_PARSE_REPORT_EXPORT_USER is
#             OPT-IN. Empty (the default) means "no --user argument at all"
#             -- the container runs as root, exactly the owner's literal
#             docker command line and the image's own no-USER-directive
#             design (report-export/docker/Dockerfile has no USER
#             instruction; verified in-repo). A non-empty value must match
#             ^[0-9]+(:[0-9]+)?$ (digits only; no name lookup, no shell
#             metacharacter) before report_export_invoke may pass it to
#             `docker run --user`, closing the same CWE-88 flag-injection
#             vector as the image ref (a value starting with '-' could
#             otherwise smuggle an extra docker flag after --user).
report_export_assert_user_spec() {
    local spec="$1"
    if [[ -z "$spec" ]]; then return 0; fi
    if [[ ! "$spec" =~ $REPORT_EXPORT_USER_RE ]]; then
        die "report-export: invalid LOG_PARSE_REPORT_EXPORT_USER: '$spec'"
    fi
}

# ---------------------------------------------------------------------------
# Private: audit-then-die helper
# ---------------------------------------------------------------------------

# _report_export_die REASON MSG...
#   Purpose : Emit the REPORT_EXPORT_RESULT failed audit line, THEN die --
#             the one place this pairing is implemented, so every internal
#             failure path in this file is guaranteed to leave the same kind
#             of audit trail NOTIFY_RESULT already guarantees for notify_run
#             (rule 2: single source of truth for the pairing).
#   Args    : REASON — closed reason= slug (§11.1 of the design spec);
#             MSG... — the die message (passed straight through to die()).
#   Returns / Side effects : never returns -- exits 1 via die().
#   Errors / Notes : NOT used by report_export_preflight's own die sites
#             (missing docker, bad image/user spec, image inspect failure):
#             those fire before persist_init has resolved a run directory on
#             the normal CLI path, so a REPORT_EXPORT_RESULT line naming
#             "reports are intact in ..." would be meaningless there --
#             §11.1 rows 1-5 explicitly carry reason="-" (no result line at
#             all). Every function below this point in the file (prepare
#             dirs, staging, invocation, summary parsing, deliverable
#             selection) DOES run only after persist_init, so it uses this
#             helper for all of its die sites.
_report_export_die() {
    local reason="$1"; shift
    report_export_result_line failed "$reason" -
    die "$@"
}

# ---------------------------------------------------------------------------
# Private: confidentiality mode-verification helper (FIX C)
# ---------------------------------------------------------------------------

# _report_export_mode_mismatch PATH EXPECTED
#   Purpose : Report whether PATH's ACTUAL octal permission mode differs from
#             EXPECTED -- reading the mode BACK rather than trusting chmod's
#             own exit status. Confidentiality of the accumulating PII under
#             production/ rests entirely on `umask 077` + `chmod 0700`
#             (directories) and `chmod 600` (the staged CSV); chmod
#             returning 0 is NOT proof the mode took effect. On a DrvFs/9p/
#             WSL mount -- and this repository itself lives on exactly such a
#             mount, /mnt/c/... -- chmod is commonly accepted and silently
#             ignored, leaving the tree world-/group-readable despite every
#             prior check in this file reporting success.
#   Args    : PATH — file or directory to inspect; EXPECTED — 3-digit octal
#             string, e.g. "700" or "600".
#   Output  : nothing.
#   Returns / Side effects : 0 (no mismatch) when `stat` is unavailable
#             (cannot verify -- NEVER treated as a mismatch, see below) or
#             the mode already matches; 1 (mismatch) when `stat` IS available
#             and reports a different mode.
#   Errors / Notes : `stat -c '%a'` (GNU coreutils) is used deliberately, NOT
#             folded into a new require_cmds gate: unlike wc/find/realpath/
#             readlink (each avoided elsewhere in this file, and in
#             lib/notify_utils.sh, with a documented bash/gawk-only
#             substitute), no bash/gawk substitute exists for reading back
#             numeric permission bits -- this is not a style preference this
#             project can route around, it is a genuine gap in what bash and
#             POSIX awk expose. GNU `stat` ships in the SAME coreutils
#             package as the `date -r`/`date -d` GNU extensions
#             lib/date_utils.sh already hard-requires ("Requires GNU date
#             (Linux)"), so this is not a NEW install requirement in
#             practice, and this project's own test harness
#             (tests/run_tests.sh, M09/L02) already relies on it directly.
#             Absence of `stat` is never fatal and never itself warned about:
#             the actual security control (umask 077 + chmod) still runs
#             unconditionally either way; this function only gates an
#             ADDITIONAL diagnostic warning layered on top of it, so a host
#             without `stat` is no worse off than before this fix existed.
_report_export_mode_mismatch() {
    local path="$1" expected="$2" actual
    if ! command -v stat >/dev/null 2>&1; then return 0; fi
    actual="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 0
    [[ -n "$actual" && "$actual" != "$expected" ]]
}

# ---------------------------------------------------------------------------
# production/{input,state,output} tree
# ---------------------------------------------------------------------------

# report_export_prepare_dirs
#   Purpose : Create/validate the production/{input,state,output} tree, a
#             SIBLING of the timestamped run directories, and resolve it to
#             an absolute path safe to hand to `docker -v`.
#   Args    : none.
#   Reads   : RUN_BASE_DIR (set by persist_init), RUN_OUTPUT_DIR (for die
#             message suffixes only).
#   Output  : nothing on stdout; FIX C may emit one log_warn (see step 6).
#   Returns / Side effects : 0, or dies. Sets REPORT_EXPORT_PROD_DIR,
#             REPORT_EXPORT_IN_DIR, REPORT_EXPORT_STATE_DIR,
#             REPORT_EXPORT_OUT_DIR (all absolute). Idempotent across calls
#             (mkdir -p / chmod are both no-ops on an already-correct tree).
#   Errors / Notes : Steps, in this exact order (design spec §5.3, extended
#             by FIX B/FIX C):
#             (1) require RUN_BASE_DIR; (2) persist_production_dir();
#             (3) mkdir -p all four under umask 077 (fatal on failure);
#             (4) FIX B: reject a SYMLINK at any of the four paths (`-L`, an
#             lstat that never follows) BEFORE chmod or absolutisation ever
#             touches it -- mkdir -p is a silent no-op when a path already
#             exists as a symlink to an existing directory, so a pre-planted
#             symlinked mount point would otherwise sail through unnoticed,
#             and `docker -v` resolves symlinks in its host-path argument at
#             mount(2) time, so an unchecked one would let `docker run`
#             bind-mount an arbitrary host directory as /data/input,
#             /data/state, or /data/output;
#             (5) chmod 0700 all four, BEST-EFFORT (idempotent; corrects a
#             loose pre-existing tree this uid owns -- a chmod that fails
#             because the tree is owned by ANOTHER uid, e.g. a previous ROOT
#             container, is deliberately NOT fatal here, so step 12 below
#             remains the one authoritative usability gate and gets to emit
#             its specific chown remedy instead of a generic chmod error);
#             (6) FIX C: read each directory's mode BACK (_report_export_mode_mismatch)
#             and, if `chmod 0700` did not actually take effect on one or
#             more of them (common on a DrvFs/9p/WSL mount, where chmod is
#             frequently accepted and silently ignored -- and this repo
#             itself can live on exactly such a mount), emit exactly ONE
#             consolidated, unmissable log_warn naming every offending path.
#             NEVER fatal -- see CONFIDENTIALITY note below; (7) absolutise
#             via `cd && pwd -P` (bash builtins only -- no realpath/readlink,
#             no new dependency; safe because the dir was just mkdir -p'd);
#             (8) derive the three subdirectory globals from the absolute
#             base; (9) refuse a suspiciously shallow resolved path (e.g.
#             --output-dir /); (10) refuse a ':' in the resolved path (would
#             make `docker -v HOST:CONTAINER:ro` unparseable); (11) FIX B:
#             physically resolve EACH of the three subdirectories the same
#             way the base was resolved in step 7, and require the result to
#             be EXACTLY the expected `${REPORT_EXPORT_PROD_DIR}/<name>` --
#             belt-and-suspenders alongside step 4's `-L` check (step 4 alone
#             already rejects a symlinked FINAL path component; this additionally
#             catches any other divergence between the logical and physical
#             location before it is ever trusted); (12) assert -d/-w/-x on
#             each of the three subdirectories, with a named `chown` remedy
#             on failure -- the migration path for a tree a previous ROOT
#             container left owned by root (§5.4).
#   CONFIDENTIALITY (FIX C): a hard `die` on a chmod-mode mismatch would make
#             --report-export entirely unusable on the owner's own WSL mount
#             (chmod is accepted there, just ineffective) -- failing the
#             feature outright is a strictly worse outcome for that operator
#             than proceeding with a loud, named warning. The warning is
#             deliberately not suppressable and is NOT itself the security
#             control (umask 077 + chmod remain that); it exists solely so
#             confidentiality is never silently assumed on a filesystem that
#             cannot provide it -- see docs/design.md §4.10.7 (CWE-732) and
#             docs/usage.md's PII section, both updated to stop implying a
#             guarantee the filesystem cannot honour.
report_export_prepare_dirs() {
    if [[ -z "${RUN_BASE_DIR:-}" ]]; then
        die "report-export: persist_init has not run (RUN_BASE_DIR unset)"
    fi

    local prod
    prod="$(persist_production_dir)"

    local old_umask d
    old_umask="$(umask)"
    umask 077
    for d in "$prod" "$prod/input" "$prod/state" "$prod/output"; do
        mkdir -p -- "$d" \
            || _report_export_die dirs "cannot create export dir: $d; reports are intact in $RUN_OUTPUT_DIR"
    done
    umask "$old_umask"

    # FIX B: reject a symlinked mount point BEFORE chmod (which follows a
    # symlink's final component and would silently act on whatever it
    # points at) or absolutisation (below) ever trusts it. `-L` is an lstat
    # -- it inspects the directory entry itself and never follows the link.
    for d in "$prod" "$prod/input" "$prod/state" "$prod/output"; do
        if [[ -L "$d" ]]; then
            _report_export_die dirs "report-export: refusing a symlinked export dir (would redirect the docker bind mount): $d; reports are intact in $RUN_OUTPUT_DIR"
        fi
    done

    # Best-effort, NOT immediately fatal: chmod only succeeds for the owner
    # (or root), so it naturally fails on a directory a previous ROOT
    # container left behind (§5.4) -- exactly the case step 12 below exists
    # to catch with a SPECIFIC, actionable chown remedy. Dying HERE instead
    # would intercept that scenario with a generic "chmod failed" message
    # and never reach step 12's more useful one. A directory we DO own but
    # with merely loose bits (the actual, ordinary case this step exists
    # for) always chmods successfully, so this is not a silent downgrade of
    # any real, actionable failure -- step 12's explicit -d/-w/-x assertion
    # remains the single authoritative USABILITY gate either way; step 6
    # (immediately below) is the single authoritative CONFIDENTIALITY check.
    for d in "$prod" "$prod/input" "$prod/state" "$prod/output"; do
        chmod 0700 -- "$d" 2>/dev/null \
            || log_debug "report-export: chmod 0700 did not apply (possibly not owned by this uid; step 12 will assert usability): $d"
    done

    # FIX C: chmod EXITING 0 (or being silently accepted) is not proof the
    # mode actually took effect -- read it back. Collected into ONE
    # consolidated warning naming every offending path, rather than up to
    # four near-duplicate lines, so the signal stays unmissable without
    # being noisy.
    local _re_bad_modes=()
    for d in "$prod" "$prod/input" "$prod/state" "$prod/output"; do
        if _report_export_mode_mismatch "$d" 700; then
            _re_bad_modes+=("$d")
        fi
    done
    if [[ "${#_re_bad_modes[@]}" -gt 0 ]]; then
        log_warn "report-export: SECURITY: chmod 0700 did not take effect on: ${_re_bad_modes[*]} -- this filesystem may not support Unix permission bits (common on DrvFs/WSL/9p mounts); the PII accumulating under production/ is NOT confidentiality-protected by chmod on this host. Restrict access by another means (host ACL, an encrypted volume, or a --output-dir on a filesystem that honours chmod)."
    fi

    if ! REPORT_EXPORT_PROD_DIR="$(cd "$prod" && pwd -P)"; then
        _report_export_die dirs "cannot resolve export dir: $prod; reports are intact in $RUN_OUTPUT_DIR"
    fi
    REPORT_EXPORT_IN_DIR="${REPORT_EXPORT_PROD_DIR}/input"
    REPORT_EXPORT_STATE_DIR="${REPORT_EXPORT_PROD_DIR}/state"
    REPORT_EXPORT_OUT_DIR="${REPORT_EXPORT_PROD_DIR}/output"

    # "At least two path components and not /" -- counted as raw '/' bytes
    # in the ABSOLUTE resolved path via pure parameter-expansion (no wc,
    # which is outside the sanctioned command set): "/production" has one
    # slash (unsafe, one level under root); "/home/x/log-parse/production"
    # has four (safe).
    local _slashes="${REPORT_EXPORT_PROD_DIR//[^\/]/}"
    if [[ "$REPORT_EXPORT_PROD_DIR" == "/" || "${#_slashes}" -lt 2 ]]; then
        _report_export_die dirs "report-export: refusing to use an unsafe production dir: $REPORT_EXPORT_PROD_DIR; reports are intact in $RUN_OUTPUT_DIR"
    fi

    if [[ "$REPORT_EXPORT_PROD_DIR" == *:* ]]; then
        _report_export_die path_colon "--output-dir path must not contain ':' when --report-export is used: $REPORT_EXPORT_PROD_DIR; reports are intact in $RUN_OUTPUT_DIR"
    fi

    # FIX B: physically resolve EACH of the three mount-point subdirectories
    # the same way the base was resolved above, and require the result to be
    # EXACTLY the expected path. This is what actually stops a pre-existing
    # symlinked mount point from redirecting a bind mount, belt-and-suspenders
    # alongside the `-L` check already performed above.
    local sub_name sub_expected sub_resolved
    for sub_name in input state output; do
        sub_expected="${REPORT_EXPORT_PROD_DIR}/${sub_name}"
        if ! sub_resolved="$(cd "$sub_expected" && pwd -P)"; then
            _report_export_die dirs "cannot resolve export dir: $sub_expected; reports are intact in $RUN_OUTPUT_DIR"
        fi
        if [[ "$sub_resolved" != "$sub_expected" ]]; then
            _report_export_die dirs "report-export: export dir resolved to an unexpected path: $sub_resolved (expected $sub_expected); reports are intact in $RUN_OUTPUT_DIR"
        fi
    done

    local sub
    for sub in "$REPORT_EXPORT_IN_DIR" "$REPORT_EXPORT_STATE_DIR" "$REPORT_EXPORT_OUT_DIR"; do
        if [[ ! -d "$sub" || ! -w "$sub" || ! -x "$sub" ]]; then
            _report_export_die dirs_perm "report-export: production dir not usable by uid ${UID}: $sub (a previous run under a root container may own it; fix with: sudo chown -R ${UID}:${GROUPS[0]} $REPORT_EXPORT_PROD_DIR); reports are intact in $RUN_OUTPUT_DIR"
        fi
    done
}

# ---------------------------------------------------------------------------
# Window-start derivation
# ---------------------------------------------------------------------------

# report_export_window_start
#   Purpose : Derive the analysis window's FIRST day (the window START) --
#             the exact YYYY-MM-DD used to name the staged input CSV.
#   Args    : none.
#   Output  : YYYY-MM-DD on stdout, no trailing content.
#   Returns / Side effects : none; dies on failure.
#   Errors / Notes : Reads INTERVAL_ARGS (populated by resolve_interval in
#             main(), before this runs). Uses build_date_list + validate_date
#             ONLY -- no new date arithmetic (rule 2). --date D -> D;
#             --from A --to B -> A; --days N -> the earliest day of the
#             rolling N-day window; --today -> today.
#             DEVIATION FROM THE DESIGN SPEC (§6.2), empirically verified,
#             documented per this project's own review discipline: the
#             spec's given body pipes build_date_list DIRECTLY into
#             `| head -n 1`. Under this codebase's mandatory
#             `set -euo pipefail` (bash.md), that pipe is a live SIGPIPE
#             hazard, not a style nit: for any window of more than one day
#             (i.e. --from/--to spanning >1 day, or --days N -- THE
#             TOOLKIT'S OWN DEFAULT), `head -n 1` reads the first line and
#             closes its end of the pipe while build_date_list's `while`
#             loop (each iteration shelling out to `date`, so slow enough
#             for the race to lose reliably in practice, not just in theory)
#             is still writing later lines; the write fails with SIGPIPE,
#             build_date_list's subshell exits 128+13=141, and pipefail
#             propagates that 141 as the PIPELINE's status despite `head`
#             itself having succeeded and `$d` having already captured the
#             CORRECT value. Verified empirically (bash 5.2.26): a bare
#             `d="$(build_date_list --from A --to B | head -n 1)"` inside a
#             function, under `set -euo pipefail`, reliably aborts the
#             ENTIRE PROCESS with exit 141 for any multi-day A/B -- and the
#             `|| die` form here would misfire down the SAME "cannot derive"
#             error path on every ordinary multi-day run, since `||`
#             prevents an uncontrolled errexit abort but the fallback branch
#             still fires on the pipeline's spurious non-zero status. Fix:
#             capture build_date_list's FULL output with no pipe at all (a
#             bare command substitution's internal read runs to the writer's
#             own EOF; there is no early-closing reader to race), then take
#             the first line via pure bash suffix removal (${var%%$'\n'*}) --
#             no subprocess, no pipe, no dependency added. The exact same
#             `build_date_list "${INTERVAL_ARGS[@]}" | head -n 1` /
#             `| tail -n 1` shape also appears, pre-existing, in
#             notify_subject and notify_build_body (lib/notify_utils.sh);
#             those calls carry the identical latent hazard but have never
#             tripped it because every existing test fixture that reaches
#             them uses a single-day `--date` window (build_date_list's
#             --date branch is a single `echo` with no loop, so there is
#             nothing left to write once head has read it) -- flagged here
#             for a separate, dedicated fix rather than folded into this
#             feature's own change set.
report_export_window_start() {
    local all d
    all="$(build_date_list "${INTERVAL_ARGS[@]}")" \
        || _report_export_die window_start "report-export: cannot derive the analysis window start date; reports are intact in $RUN_OUTPUT_DIR"
    d="${all%%$'\n'*}"
    if [[ -z "$d" ]]; then
        _report_export_die window_start "report-export: analysis window produced no dates; reports are intact in $RUN_OUTPUT_DIR"
    fi
    validate_date "$d"
    printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# CSV staging
# ---------------------------------------------------------------------------

# _report_export_same_bytes A B
#   Purpose : Byte-for-byte comparison of two regular files, deciding the
#             overwrite-semantics branch in report_export_stage_input.
#   Args    : A, B — paths (both must exist and be readable).
#   Output  : nothing.
#   Returns / Side effects : 0 if byte-identical (including both empty), 1
#             if they differ; dies if either file cannot be opened.
#   Errors / Notes : gawk RS="^$" whole-file slurp (modelled on
#             _notify_file_bytes's idiom, lib/notify_utils.sh), files passed
#             as gawk OPERANDS (never `-v`, which would C-string-unescape a
#             backslash in the path -- see notify_utils.sh's identical
#             rationale; this tree lives on a OneDrive/WSL mount where a
#             backslash in --output-dir is a live risk). ARGIND (gawk-
#             native, set automatically while iterating its own ARGV; no
#             `-v` path-crossing needed) distinguishes the two operands.
#             gawk aborts with a fatal, non-zero exit the instant either
#             operand cannot be opened (missing file or permission denied;
#             verified empirically for both operand positions) -- exactly
#             the "unopenable -> die, never a silent false" contract
#             _notify_file_bytes established. Two genuinely empty files
#             correctly compare SAME (RS="^$" yields zero records for an
#             empty file, so content_a/content_b simply default to "" rather
#             than the main rule ever firing for that operand -- there is no
#             fatal error, an empty file opens fine).
#             FIX E: the unopenable-comparison-file die path uses
#             _report_export_die (reason=stage_compare), not a bare die, so
#             it emits a REPORT_EXPORT_RESULT line like every other failure
#             path in this file below persist_init (see _report_export_die's
#             own docblock) -- a bare die here used to silently break that
#             invariant. "stage_compare" is a closed reason= slug: see
#             report_export_result_line's docblock, docs/design.md §4.10.6,
#             and docs/usage.md's failure-triage table.
_report_export_same_bytes() {
    local a="$1" b="$2"
    local result rc=0
    result="$(LC_ALL=C gawk '
        BEGIN { RS = "^$" }
        { if (ARGIND == 1) content_a = $0; else content_b = $0 }
        END { print (content_a == content_b) ? "SAME" : "DIFF" }
    ' "$a" "$b" 2>/dev/null)" || rc=$?

    if (( rc != 0 )); then
        _report_export_die stage_compare "report-export: cannot read staged-input comparison file: $a or $b; reports are intact in $RUN_OUTPUT_DIR"
    fi
    [[ "$result" == "SAME" ]]
}

# report_export_stage_input
#   Purpose : Copy this run's persisted access_detail.csv into
#             REPORT_EXPORT_IN_DIR as week-<REPORT_EXPORT_WEEK_DATE>.csv,
#             atomically, without ever touching the run directory's own copy.
#   Args    : none.
#   Reads   : RUN_OUTPUT_DIR, REPORT_EXPORT_IN_DIR, REPORT_EXPORT_WEEK_DATE.
#   Output  : nothing on stdout; log_info/log_warn on the overwrite branches;
#             FIX C may additionally emit one log_warn if chmod 600 did not
#             actually take effect on the staged file (never fatal).
#   Returns / Side effects : 0, or dies. Leaves the staged file at
#             REPORT_EXPORT_IN_DIR/week-<D>.csv, mode 0600.
#   Errors / Notes : Source resolved via persist_path (rule 2 -- never a
#             hand-written string); that resolves to
#             <RUN_OUTPUT_DIR>/access_detail.csv when --format csv persisted
#             one. Copy, never move (the run's own access_detail.csv must
#             remain for notify_collect_attachments and the operator's own
#             reports), never hardlink (unreliable across the DrvFs/OneDrive
#             filesystem this repo can live on, and would share an inode
#             with a container-writable mount). Written tmp-then-mv (mode
#             600 set BEFORE the mv, so the visible name is never briefly
#             world-/group-readable) so a concurrent reader never observes a
#             half-written file. If the destination already exists (the
#             normal re-run-of-the-same-window case), byte-compares first
#             via _report_export_same_bytes: identical -> log_info and
#             refresh in place; different -> log_warn (loud, not silent --
#             rule 1) and overwrite. Both branches proceed (a deliberate
#             non-fatal repair path, not a silent fallback: the log_warn is
#             unconditional and unsuppressable). A header-only CSV is NOT
#             empty and is perfectly legal (§11 of the design spec).
report_export_stage_input() {
    local src dst tmp d
    src="$(persist_path access detail csv)"
    d="$REPORT_EXPORT_WEEK_DATE"
    dst="${REPORT_EXPORT_IN_DIR}/week-${d}.csv"

    if [[ ! -f "$src" ]]; then
        _report_export_die source_missing "report-export: source CSV missing: $src (the access module produced no CSV detail file); reports are intact in $RUN_OUTPUT_DIR"
    fi
    local src_bytes
    if ! src_bytes="$(_notify_file_bytes "$src")"; then
        _report_export_die source_missing "report-export: source CSV missing: $src (the access module produced no CSV detail file); reports are intact in $RUN_OUTPUT_DIR"
    fi
    if [[ "$src_bytes" == "0" ]]; then
        _report_export_die source_empty "report-export: source CSV is empty: $src; reports are intact in $RUN_OUTPUT_DIR"
    fi

    if [[ -f "$dst" ]]; then
        if _report_export_same_bytes "$src" "$dst"; then
            log_info "report-export: input already staged (identical): $dst"
        else
            log_warn "report-export: overwriting existing staged input $dst (a previous run of the same window staged different content)"
        fi
    fi

    tmp="${REPORT_EXPORT_IN_DIR}/.week-${d}.csv.$$.tmp"
    cp -- "$src" "$tmp" \
        || _report_export_die stage "report-export: cannot stage input CSV to ${REPORT_EXPORT_IN_DIR}; reports are intact in $RUN_OUTPUT_DIR"
    chmod 600 "$tmp" \
        || _report_export_die stage "report-export: cannot stage input CSV to ${REPORT_EXPORT_IN_DIR}; reports are intact in $RUN_OUTPUT_DIR"
    # FIX C: chmod exiting 0 is not proof mode 600 actually took effect (see
    # _report_export_mode_mismatch's docblock and report_export_prepare_dirs'
    # identical treatment of the production/ tree) -- read it back and warn
    # loudly, once, if not. Checked on $tmp (pre-mv) rather than $dst:
    # rename(2) preserves the inode/mode, so the check is equally valid
    # either side of the mv, and doing it here keeps this warning textually
    # adjacent to the chmod call it verifies.
    if _report_export_mode_mismatch "$tmp" 600; then
        log_warn "report-export: SECURITY: chmod 600 did not take effect on staged input $tmp -- this filesystem may not support Unix permission bits (common on DrvFs/WSL/9p mounts); the PII in this staged CSV is NOT confidentiality-protected by chmod on this host."
    fi
    mv -- "$tmp" "$dst" \
        || _report_export_die stage "report-export: cannot finalise staged input CSV: $dst; reports are intact in $RUN_OUTPUT_DIR"
}

# ---------------------------------------------------------------------------
# Docker invocation
# ---------------------------------------------------------------------------

# report_export_invoke
#   Purpose : Execute the report-export container as a bash ARRAY argv (no
#             eval, no sh -c), capturing its stdout/stderr to files so the
#             container's own JSON summary can never reach log_report.sh's
#             report stdout (rule 3, guaranteed by construction, not by any
#             filter's correctness).
#   Args    : none.
#   Reads   : REPORT_EXPORT_IN_DIR/_STATE_DIR/_OUT_DIR/_WEEK_DATE,
#             LOG_PARSE_REPORT_EXPORT_DOCKER_BIN/_IMAGE/_USER, WORK_TMPDIR.
#   Output  : nothing on stdout. Writes $WORK_TMPDIR/report_export.json (the
#             container's stdout) and .err (its stderr).
#   Returns / Side effects : sets _RE_START_EPOCH immediately before exec.
#             Returns 0 on container rc 0; dies (translating the container's
#             exit code, §11.1 rows 11-16) on any non-zero rc.
#   Errors / Notes : ORCHESTRATOR OVERRIDE (supersedes the design spec's
#             original uid decision): LOG_PARSE_REPORT_EXPORT_USER is
#             OPT-IN. Default is empty -- no `--user` argument is emitted at
#             all, and the rendered command is EXACTLY the owner's literal
#             docker command line. Only when the operator explicitly sets a
#             non-empty, already-whitelisted (report_export_assert_user_spec,
#             enforced in report_export_preflight) value is `--user <spec>`
#             appended. `--network none` denies the container any network
#             path (defence in depth: no exfiltration route for the PII this
#             CSV carries). `-v` (not `--mount`) per the owner's own command
#             line; every host path was already absolutised and
#             colon-checked by report_export_prepare_dirs. The full argv is
#             logged via log_info BEFORE invocation (the "argv logged above"
#             referenced by the exit-1 die message below). On success, the
#             summary line is echoed to stderr via log_info (diagnostic
#             trail preserved, test M21). On failure, the last 20 lines of
#             stderr are sanitised (gawk tail, no new dependency) and
#             surfaced via log_error -- FIX D: ONE log_error call PER LINE,
#             each carrying log-parse's own prefix, so a hostile/buggy
#             container's stderr can never forge an unprefixed, apparently-
#             trusted log line (CWE-117; see the call site's own comment) --
#             before translating rc to the taxonomy of §11.1.
report_export_invoke() {
    local docker_bin="${LOG_PARSE_REPORT_EXPORT_DOCKER_BIN:-docker}"
    local image="${LOG_PARSE_REPORT_EXPORT_IMAGE:-$REPORT_EXPORT_DEFAULT_IMAGE}"
    local re_user="${LOG_PARSE_REPORT_EXPORT_USER:-}"

    local -a _RE_ARGV=(
        "$docker_bin" run --rm
        --network none
        -v "${REPORT_EXPORT_IN_DIR}:/data/input:ro"
        -v "${REPORT_EXPORT_STATE_DIR}:/data/state"
        -v "${REPORT_EXPORT_OUT_DIR}:/data/output"
    )
    if [[ -n "$re_user" ]]; then
        _RE_ARGV+=(--user "$re_user")
    fi
    _RE_ARGV+=("$image" "/data/input/week-${REPORT_EXPORT_WEEK_DATE}.csv")

    log_info "report-export: invoking: ${_RE_ARGV[*]}"

    _RE_START_EPOCH="$(date '+%s')"
    local rc=0
    "${_RE_ARGV[@]}" >"$WORK_TMPDIR/report_export.json" 2>"$WORK_TMPDIR/report_export.err" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        local summary_line
        summary_line="$(LC_ALL=C gawk 'END{print}' "$WORK_TMPDIR/report_export.json")"
        log_info "report-export summary: $summary_line"
        return 0
    fi

    if [[ -s "$WORK_TMPDIR/report_export.err" ]]; then
        log_error "report-export: docker stderr (last 20 lines):"
        # FIX D (CWE-117, log-record forgery): _log (lib/common.sh) does
        # exactly ONE `printf "...%s\n" ... "$msg"` per call, prefixing only
        # the FIRST line of a multi-line $msg -- every subsequent embedded
        # line used to reach the log stream with NO log-parse prefix at all,
        # letting a hostile/buggy container forge an apparently-independent,
        # apparently-trusted log-parse line on its own stderr (e.g. a fake
        # "[HH:MM:SS][INFO] ..." line). Fix: call log_error ONCE PER LINE so
        # every relayed line carries log-parse's own timestamp+level prefix,
        # and gawk-sanitise a trailing CR plus any other control byte
        # (0x01-0x1F, 0x7F -- the SAME class lib/notify_utils.sh's
        # NOTIFY_RECEIVERS_AWK already rejects display names for) BEFORE it
        # is ever handed to log_error, so a forged ANSI escape (ESC is
        # 0x1B, inside that class) cannot rewrite the terminal or otherwise
        # disguise itself. Each relayed line is additionally indented with a
        # literal "  | " marker so it visibly reads as QUOTED content under
        # log-parse's own real prefix, never as a standalone entry.
        while IFS= read -r _re_errline; do
            log_error "  | $_re_errline"
        done < <(LC_ALL=C gawk '
            { gsub(/\r$/, ""); gsub(/[\001-\037\177]/, "."); buf[NR] = $0 }
            END { s = (NR > 20) ? NR - 19 : 1; for (i = s; i <= NR; i++) print buf[i] }
        ' "$WORK_TMPDIR/report_export.err")
    fi

    case "$rc" in
        1) _report_export_die container_usage "report-export failed (exit 1: usage error) — this is an orchestration bug, please report the argv logged above; reports are intact in $RUN_OUTPUT_DIR" ;;
        2) _report_export_die container_input "report-export failed (exit 2: input validation) — the staged CSV was rejected: ${REPORT_EXPORT_IN_DIR}/week-${REPORT_EXPORT_WEEK_DATE}.csv; reports are intact in $RUN_OUTPUT_DIR" ;;
        3) _report_export_die container_state "report-export failed (exit 3: state integrity) — inspect ${REPORT_EXPORT_STATE_DIR}; reports are intact in $RUN_OUTPUT_DIR" ;;
        4) _report_export_die container_lock "report-export failed (exit 4: lock busy) — another export run holds the lock on ${REPORT_EXPORT_STATE_DIR}; this run did not export, rerun later; reports are intact in $RUN_OUTPUT_DIR" ;;
        5) _report_export_die container_write "report-export failed (exit 5: write error) — check free space and ownership of ${REPORT_EXPORT_OUT_DIR}; reports are intact in $RUN_OUTPUT_DIR" ;;
        *) _report_export_die docker "report-export: docker run failed (rc=$rc); reports are intact in $RUN_OUTPUT_DIR" ;;
    esac
}

# ---------------------------------------------------------------------------
# Summary parsing and deliverable selection -- THE core mechanism (§2 of the
# design spec). Authority: the "deliverable" field of the single JSON line
# report-export prints on its own stdout -- not an inference, the field IS
# the identity of the file report-export's own process just finalized
# (pipeline.py sets it from the SAME final_path object xlsx_writer's
# os.replace() moved into place, in the same process, before cli.py's sole
# print()). Steps below add falsification, not inference: they turn an
# authoritative claim into a verified fact.
# ---------------------------------------------------------------------------

# _report_export_parse_summary JSON_FILE
#   Purpose : Assert JSON_FILE holds exactly one JSON-object-shaped line,
#             then extract its "deliverable" member, COUNTING occurrences in
#             the same gawk pass (heavy lifting in gawk, rule 5).
#   Args    : JSON_FILE — path to the container's captured stdout.
#   Output  : the raw "deliverable" value on stdout (no trailing content);
#             NOTHING on stdout on any failure path.
#   Returns / Side effects : 0 and prints the value on success; dies (via
#             _report_export_die) on 0 JSON-shaped lines, >1 JSON-shaped
#             lines, 0 deliverable members, or >=2 deliverable members.
#   Errors / Notes : the match/count logic in the gawk program below is the
#             design spec's §2.2 step 2 program, with one addition (see the
#             function body's own leading comment for the full, empirically-
#             verified justification): both this program and the line-count
#             check above it SKIP any line that is not JSON-object-shaped
#             (does not start with '{' and end with '}' once a trailing \r
#             and surrounding whitespace are stripped), reconciling this
#             section's "exactly one line" assertion with §12.2's own test
#             shim, whose default/happy-path stdout is a noisy non-JSON line
#             FOLLOWED BY the real JSON line. The match/count program signals
#             BOTH "0 members" and ">=2 members" via the SAME `exit 3` -- by
#             design it counts and validates in one pass, but a single exit
#             code cannot itself tell two distinct die messages apart. A
#             second, independent, side-effect-free gawk count (same match
#             regex and JSON-line filter, no bearing on the extraction
#             above, which already ran unmodified) resolves ONLY which of
#             the two die messages applies; it never changes the
#             accept/reject decision already made by the first program. The
#             regex deliberately rejects any backslash escape inside the
#             value; a legal deliverable path under a fixed /data/output
#             mount can never contain one. CJK arrives as literal UTF-8
#             (report-export prints with ensure_ascii=False) and is matched
#             byte-wise under LC_ALL=C, which is safe here because every
#             byte the regex acts on specially (", \, whitespace, digits,
#             {, }) is < 0x80 and every UTF-8 continuation byte is >= 0x80.
_report_export_parse_summary() {
    local json_file="$1"

    # "Line" for both counts below means a JSON-OBJECT-SHAPED line -- after
    # stripping a possible trailing \r and surrounding whitespace, one that
    # starts with '{' and ends with '}' -- NOT a bare physical line.
    #
    # DEVIATION FROM THE DESIGN SPEC, empirically verified, required to
    # reconcile two of its OWN locked sections that otherwise directly
    # contradict each other: §2.2 step 1 says to assert "exactly one
    # non-empty line", and its step-2 gawk program (reproduced verbatim
    # further below) resets its match counter and can `exit 3` on the FIRST
    # line that doesn't carry exactly one "deliverable" match -- but §12.2's
    # own offline test shim unconditionally prints "a deliberately noisy
    # non-JSON line, THEN the canned single-line JSON summary" as its
    # DEFAULT/happy-path stdout (point d), i.e. TWO physical lines on every
    # ordinary successful run, not one. Verified directly: feeding the
    # spec's own verbatim step-2 program that exact two-line shim output
    # (noisy line first, valid JSON second) makes it `exit 3` on the noisy
    # first line before ever reaching the real summary -- so a fully literal
    # implementation of §2.2 would make EVERY happy-path test that relies on
    # the shim's default behaviour (M09-M18, M22-M24 in the spec's own test
    # plan) fail, which cannot be the intent given those are explicitly
    # positive/"happy path" cases. Filtering both counts to JSON-shaped
    # lines resolves this without weakening any hostile-input check: the
    # shim's noisy line never matches ^\{.*\}$ and is simply never counted,
    # while a file that is genuinely empty, or genuinely carries 0 or >=2
    # JSON-shaped lines, or one JSON-shaped line lacking/duplicating the
    # key, is rejected exactly as before -- reproducing all three malformed-
    # summary sub-cases of the spec's own M26 test (empty -> "produced no
    # summary"; two JSON lines -> "not a single JSON line"; one JSON line
    # lacking the key -> "reported no deliverable"). In real production
    # (never shimmed) this distinction is moot: report-export's cli.py has
    # exactly one stdout write, `print(json.dumps(...))`, on the only
    # success path (§2.1) -- stdout is either that one JSON-shaped line or
    # completely empty, never preceded by incidental non-JSON noise.
    local n_lines
    n_lines="$(LC_ALL=C gawk '
        { line = $0; gsub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line ~ /^\{.*\}$/) c++ }
        END { print c+0 }
    ' "$json_file")"

    if [[ "$n_lines" -eq 0 ]]; then
        _report_export_die summary_shape "report-export exited 0 but produced no summary on stdout (expected one JSON line with a 'deliverable' field); reports are intact in $RUN_OUTPUT_DIR"
    fi
    if [[ "$n_lines" -gt 1 ]]; then
        _report_export_die summary_shape "report-export summary was not a single JSON line; refusing to guess which deliverable was produced; reports are intact in $RUN_OUTPUT_DIR"
    fi

    local val rc=0
    val="$(LC_ALL=C gawk '
        { line = $0; gsub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line !~ /^\{.*\}$/) next
          n = 0; s = line
          while (match(s, /"deliverable"[[:space:]]*:[[:space:]]*"([^"\\]*)"/, m)) {
            n++; val = m[1]; s = substr(s, RSTART + RLENGTH)
          }
          if (n != 1) { exit 3 }
          print val
        }
    ' "$json_file")" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        printf '%s\n' "$val"
        return 0
    fi
    if [[ "$rc" -ne 3 ]]; then
        _report_export_die summary_shape "report-export: could not read summary for parsing: $json_file; reports are intact in $RUN_OUTPUT_DIR"
    fi

    # rc == 3: the one JSON-shaped line found n != 1 occurrences of
    # "deliverable" -- a single exit code cannot itself say whether that was
    # 0 or >=2, so a second, independent, side-effect-free gawk count (same
    # match regex and the same JSON-line filter, no bearing on the
    # extraction above, which already ran unmodified) resolves ONLY which of
    # the two die messages applies.
    local n_count
    n_count="$(LC_ALL=C gawk '
        { line = $0; gsub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line !~ /^\{.*\}$/) next
          s = line
          while (match(s, /"deliverable"[[:space:]]*:[[:space:]]*"([^"\\]*)"/)) {
            n++; s = substr(s, RSTART + RLENGTH)
          }
        }
        END { print n+0 }
    ' "$json_file")"

    if [[ "$n_count" -eq 0 ]]; then
        _report_export_die summary_field "report-export exited 0 but reported no deliverable; reports are intact in $RUN_OUTPUT_DIR"
    else
        _report_export_die summary_field "report-export reported multiple deliverables; refusing to guess; reports are intact in $RUN_OUTPUT_DIR"
    fi
}

# _report_export_select_deliverable
#   Purpose : Validate the container's reported deliverable against a
#             hostile-input whitelist, map it to its host path, assert the
#             host file exists/is non-empty/is fresh, and publish it.
#   Args    : none.
#   Reads   : $WORK_TMPDIR/report_export.json, REPORT_EXPORT_OUT_DIR,
#             _RE_START_EPOCH.
#   Output  : nothing on stdout.
#   Returns / Side effects : 0, sets REPORT_EXPORT_DELIVERABLE_PATH; or dies.
#   Errors / Notes : Whitelist (design spec §2.2 step 3): the value MUST
#             start with the literal prefix "/data/output/", and the
#             remainder MUST match REPORT_EXPORT_DELIVERABLE_NAME_RE,
#             anchored -- any '/', any '..', any leading '-', any control
#             character, or any other shape is rejected by that single
#             anchored match (no separate traversal check is needed
#             alongside it). Host mapping is legitimate because log-parse
#             itself authored the bind mount. FIX A (CWE-22/CWE-61,
#             symlink-following exfiltration): the anchored basename
#             whitelist constrains only the NAME string -- never the inode --
#             so, immediately after the host path is derived and BEFORE any
#             probe touches it, this function additionally (1) rejects the
#             path outright if it is a symlink (`-L`, an lstat that never
#             follows) and (2) asserts PHYSICAL CONTAINMENT: the path's
#             containing directory, resolved via `cd && pwd -P` (bash
#             builtins only, no realpath/readlink -- the same idiom
#             report_export_prepare_dirs already uses), must equal EXACTLY
#             the already-resolved REPORT_EXPORT_OUT_DIR. Without these two
#             checks, the container -- root, with production/output
#             bind-mounted read-write -- could plant
#             `<D>_連線紀錄.xlsx -> /proc/net/tcp` (or any host file whose
#             mtime falls in this run's freshness window); every remaining
#             check below (`-f`, `_notify_file_bytes`, `date -r`) follows
#             symlinks by design and would silently validate and then
#             base64-encode-and-mail the TARGET, not the deliverable.
#             Reproduced end-to-end against a real docker daemon before this
#             fix existed; see the verification section of the commit this
#             lands in. Freshness: the host file's mtime must be >=
#             (_RE_START_EPOCH - 2); the 2-second slack absorbs filesystem
#             timestamp granularity.
_report_export_select_deliverable() {
    local json_file="${WORK_TMPDIR}/report_export.json"
    local val name host_path

    val="$(_report_export_parse_summary "$json_file")"

    case "$val" in
        "${REPORT_EXPORT_DELIVERABLE_PREFIX}"*) ;;
        *) _report_export_die deliverable_shape "report-export reported an unacceptable deliverable path: '$val'; reports are intact in $RUN_OUTPUT_DIR" ;;
    esac
    name="${val#"${REPORT_EXPORT_DELIVERABLE_PREFIX}"}"

    if [[ ! "$name" =~ $REPORT_EXPORT_DELIVERABLE_NAME_RE ]]; then
        _report_export_die deliverable_shape "report-export reported an unacceptable deliverable path: '$val'; reports are intact in $RUN_OUTPUT_DIR"
    fi

    host_path="${REPORT_EXPORT_OUT_DIR}/${name}"

    # FIX A, check 1/2: reject a symlink BEFORE any probe below ever follows
    # it. `-L` lstats the path itself and never resolves the link target.
    if [[ -L "$host_path" ]]; then
        _report_export_die deliverable_shape "report-export reported a deliverable that is a symlink on the host (refusing to follow it): $host_path; reports are intact in $RUN_OUTPUT_DIR"
    fi

    # FIX A, check 2/2: physical containment. `name` cannot itself contain
    # '/' (the anchored whitelist above already guarantees that), so
    # host_path's containing directory is, LOGICALLY, always
    # REPORT_EXPORT_OUT_DIR -- but resolve it PHYSICALLY anyway and require
    # exact equality, so that a symlinked ancestor swapped in after
    # report_export_prepare_dirs originally resolved it can never silently
    # redirect where this file is actually read from.
    local _deliv_dir _deliv_dir_resolved
    _deliv_dir="$(dirname -- "$host_path")"
    if ! _deliv_dir_resolved="$(cd -- "$_deliv_dir" && pwd -P)"; then
        _report_export_die deliverable_shape "report-export: cannot resolve deliverable's containing dir: $_deliv_dir; reports are intact in $RUN_OUTPUT_DIR"
    fi
    if [[ "$_deliv_dir_resolved" != "$REPORT_EXPORT_OUT_DIR" ]]; then
        _report_export_die deliverable_shape "report-export: deliverable resolves outside the expected output dir: $_deliv_dir_resolved (expected $REPORT_EXPORT_OUT_DIR); reports are intact in $RUN_OUTPUT_DIR"
    fi

    if [[ ! -f "$host_path" ]]; then
        _report_export_die deliverable_missing "report-export reported $val but no such file on host: $host_path (bind-mount or uid mismatch); reports are intact in $RUN_OUTPUT_DIR"
    fi
    local host_bytes
    if ! host_bytes="$(_notify_file_bytes "$host_path")"; then
        _report_export_die deliverable_missing "report-export reported $val but no such file on host: $host_path (bind-mount or uid mismatch); reports are intact in $RUN_OUTPUT_DIR"
    fi
    if [[ "$host_bytes" == "0" ]]; then
        _report_export_die deliverable_missing "report-export reported $val but no such file on host: $host_path (bind-mount or uid mismatch); reports are intact in $RUN_OUTPUT_DIR"
    fi

    local mtime_epoch
    mtime_epoch="$(date -r "$host_path" '+%s')" \
        || _report_export_die deliverable_missing "report-export reported $val but no such file on host: $host_path (bind-mount or uid mismatch); reports are intact in $RUN_OUTPUT_DIR"
    if (( mtime_epoch < _RE_START_EPOCH - 2 )); then
        _report_export_die deliverable_stale "deliverable predates this invocation: $host_path; reports are intact in $RUN_OUTPUT_DIR"
    fi

    REPORT_EXPORT_DELIVERABLE_PATH="$host_path"
}

# ---------------------------------------------------------------------------
# Audit line + public orchestrator entry point
# ---------------------------------------------------------------------------

# report_export_result_line STATUS REASON DELIVERABLE
#   Purpose : Emit exactly one machine-parseable REPORT_EXPORT_RESULT stderr
#             line per run -- the single grep-able marker for automation/
#             audits, mirroring NOTIFY_RESULT (lib/notify_utils.sh).
#   Args    : STATUS — ok|failed; REASON — "-" or a closed reason= slug
#             (dirs, dirs_perm, path_colon, window_start, source_missing,
#             source_empty, stage_compare, stage, container_usage,
#             container_input, container_state, container_lock,
#             container_write, docker, summary_shape, summary_field,
#             deliverable_shape, deliverable_missing, deliverable_stale);
#             DELIVERABLE — the deliverable's basename, or "-" when none
#             was selected.
#   Output  : one line on stderr (log_info for ok, log_error otherwise).
#   Returns / Side effects : none.
report_export_result_line() {
    local status="$1" reason="$2" deliverable="$3"
    local line
    line="$(printf 'REPORT_EXPORT_RESULT status=%s reason=%s deliverable=%s' "$status" "$reason" "$deliverable")"
    case "$status" in
        ok) log_info "$line" ;;
        *)  log_error "$line" ;;
    esac
}

# report_export_run
#   Purpose : The single orchestrator entry point for the whole feature --
#             the only function bin/log_report.sh's main() calls directly
#             (besides the idempotent preflight already run during
#             parse_args).
#   Args    : none.
#   Reads   : everything the sequence below reads (RUN_BASE_DIR,
#             RUN_OUTPUT_DIR, INTERVAL_ARGS, WORK_TMPDIR, the
#             LOG_PARSE_REPORT_EXPORT_* env vars).
#   Output  : nothing on stdout (rule 3). stderr: progress log_info lines,
#             the REPORT_EXPORT_RESULT audit line.
#   Returns / Side effects : sets REPORT_EXPORT_DELIVERABLE_PATH on success.
#             Returns 0. Dies on ANY failure in the sequence below -- an
#             export the operator explicitly asked for that did not succeed
#             is never silently tolerated (rule 1). Runs strictly BEFORE
#             notify_run (bin/log_report.sh main()) so a failed export can
#             never ship a mail that silently lacks the xlsx it exists to
#             carry.
#   Errors / Notes : Sequence (the ONLY function in this file that assumes
#             globals rather than operating on explicit args -- library.md's
#             "pure where possible" applies to every other function here):
#               report_export_preflight (idempotent no-op on the normal CLI
#                 path, which already ran it during parse_args; point of use
#                 for direct-library callers) -> report_export_prepare_dirs
#               -> REPORT_EXPORT_WEEK_DATE="$(report_export_window_start)"
#               -> report_export_stage_input -> report_export_invoke
#                 (emits its own "report-export summary: ..." log_info on
#                 success) -> _report_export_select_deliverable
#               -> report_export_result_line ok - <basename>.
#             Every internal die path (inside the callees above) emits
#             `report_export_result_line failed <slug> -` FIRST via the
#             private _report_export_die helper, so a REPORT_EXPORT_RESULT
#             line is always the last word on a failed run.
report_export_run() {
    report_export_preflight
    report_export_prepare_dirs
    REPORT_EXPORT_WEEK_DATE="$(report_export_window_start)"
    report_export_stage_input
    report_export_invoke
    _report_export_select_deliverable

    local basename
    basename="$(basename "$REPORT_EXPORT_DELIVERABLE_PATH")"

    # Best-effort, NON-FATAL read of "normal" from the same summary JSON
    # (design spec §11.1 "Not an error": a header-only CSV, or zero NORMAL
    # rows, is a legitimate, successful outcome, never a failure).
    # Deliberately NOT folded into _report_export_parse_summary's locked
    # contract (which dies on 0/>=2 "deliverable" members and nothing else)
    # -- only the deliverable field is ever load-bearing for fatality here;
    # a malformed/absent "normal" field degrades to simply skipping the
    # warning, never to a die.
    local normal_rows
    normal_rows="$(LC_ALL=C gawk '
        { if (match($0, /"normal"[[:space:]]*:[[:space:]]*([0-9]+)/, m)) print m[1] }
    ' "${WORK_TMPDIR}/report_export.json" 2>/dev/null)"
    if [[ "$normal_rows" == "0" ]]; then
        log_warn "report-export: 0 normal rows in this window"
    fi

    log_info "report-export deliverable: $REPORT_EXPORT_DELIVERABLE_PATH"
    report_export_result_line ok - "$basename"
}
