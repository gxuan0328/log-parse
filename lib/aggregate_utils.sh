#!/usr/bin/env bash
# lib/aggregate_utils.sh — Shared metric computation + CSV quoter (D5 DRY).
#
# Single source for IIS + access metric awk programs and the RFC-4180 quoter.
# Sourced by bin/analyze_iis.sh, bin/analyze_access.sh, and bin/analyze_overview.sh.
#
# Contents:
#   AGG_IIS_AWK     — IIS W3C log analyser program (relocated from analyze_iis.sh).
#   AGG_CSV_FUNC    — RFC-4180 gawk q() function (relocated from analyze_access.sh).
#   agg_iis_rows    — Run AGG_IIS_AWK on a combined IIS log file.
#   agg_access_rows — Single-pass access correlation stats aggregation.
#   Schema constants IIS_STAT_SCHEMA, ACCESS_STAT_SCHEMA and field-index helpers.
#
# Conventions:
#   - Source this file; do not execute directly.
#   - Never call init_tmpdir from a library.
#   - Never call exit except via die.
#   - All log output goes to STDERR; stdout = report content.
#
# Under both awk.md and library.md globs.

# ---------------------------------------------------------------------------
# AGG_IIS_AWK — IIS W3C log analyser (verbatim from bin/analyze_iis.sh)
# ---------------------------------------------------------------------------
# Single source of truth for IIS metric computation (risk #3: move only,
# no logic edit). bin/analyze_iis.sh already sources aggregate_utils.sh and
# uses AGG_IIS_AWK via agg_iis_rows; there is no remaining duplication —
# this is the one and only definition of the IIS awk program.
AGG_IIS_AWK='
# ----------------------------------------------------------------------------
# Purpose : Analyse IIS W3C log lines; emit TAB-delimited kind-tagged rows.
# Input   : Raw W3C extended log lines (space-delimited; # lines = comments).
# Vars    : slow_ms — role-resolved slow-request threshold in milliseconds.
#           top     — max rows for ENDPOINT and CLIENT_IP (0 = all).
# Output  : TAB-delimited, kind-prefixed rows on stdout:
#             TOTAL\t<n>
#             5XX\t<n>
#             503_HEALTH\t<n>
#             SLOW\t<n>
#             REDIRECT\t<n>
#             UNIQUE_IPS\t<n>
#             STATUS\t<status>\t<count>
#             ENDPOINT\t<uri>\t<count>\t<avg_sec>   (Top-N by count desc,
#                                                    --top default 10, 0=all)
#             CLIENT_IP\t<ip>\t<count>              (Top-N by count desc,
#                                                    --top default 10, 0=all)
# ----------------------------------------------------------------------------
BEGIN {
    health_path    = "/health"
    slow_threshold = slow_ms + 0
}

# Skip W3C directive lines and any truncated rows missing required fields.
/^#/ { next }
NF < 17 { next }

{
    # Default IIS W3C field positions (1-based):
    #   1=date  2=time  3=s-ip  4=cs-method  5=cs-uri-stem  6=cs-uri-query
    #   7=s-port 8=cs-username 9=c-ip 10=cs(User-Agent) 11=cs(Referer)
    #   12=sc-status 13=sc-substatus 14=sc-win32-status
    #   15=sc-bytes 16=cs-bytes 17=time-taken (ms)
    method = $4
    uri    = $5
    status = $12 + 0
    ttms   = $17 + 0
    client = $9

    total++
    status_count[status]++

    # Per-client request counter; "-" appears when IIS could not resolve
    # the client and is excluded from the unique-IP set.
    if (client != "-") client_ips[client]++

    # DICOM endpoints embed study/series UIDs in the path; collapse them so
    # the top-endpoint table reflects logical endpoints, not UID variants.
    ep = uri
    if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/series\//) {
        ep = "/api/NhiPatientImage/studies/{uid}/series/{uid}/..."
    } else if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/series-uid/) {
        ep = "/api/NhiPatientImage/studies/{uid}/series-uid"
    } else if (ep ~ /\/api\/NhiPatientImage\/studies\/[^\/]+\/instances\//) {
        ep = "/api/NhiPatientImage/studies/{uid}/instances/{uid}"
    }
    ep_count[ep]++
    ep_time_ms[ep] += ttms   # accumulate time-taken for the per-endpoint mean

    # Severity / health counters. Note: health-check 503s are deliberately
    # split out from the generic 5xx bucket because they signal a dependency
    # outage (OracleDB unhealthy), not an application fault.
    if (status >= 500)                                error5xx++
    if (ttms >= slow_threshold && uri != health_path) slow++
    if (status == 503 && uri == health_path)          health503++
    if (status == 302)                                redirect++
}

END {
    printf "TOTAL\t%d\n",      total
    printf "5XX\t%d\n",        error5xx+0
    printf "503_HEALTH\t%d\n", health503+0
    printf "SLOW\t%d\n",       slow+0
    printf "REDIRECT\t%d\n",   redirect+0
    printf "UNIQUE_IPS\t%d\n", length(client_ips)

    # Emit raw STATUS counts; render_iis_stats re-sorts in-gawk for display.
    for (s in status_count)
        printf "STATUS\t%d\t%d\n", s, status_count[s]

    # Top-N endpoints by request count (descending). 4th field = mean response
    # time in seconds (time-taken logged in ms). top=0 emits all endpoints.
    n = asorti(ep_count, ep_sorted, "@val_num_desc")
    lim = (top == 0) ? n : (n < top ? n : top)
    for (i = 1; i <= lim; i++) {
        e = ep_sorted[i]
        avg_sec = (ep_count[e] > 0) ? (ep_time_ms[e] / ep_count[e] / 1000.0) : 0
        printf "ENDPOINT\t%s\t%d\t%.2f\n", e, ep_count[e], avg_sec
    }

    # Top-N unique client IPs with request counts, sorted descending.
    # top=0 emits all client IPs.
    m = asorti(client_ips, ip_sorted, "@val_num_desc")
    lim2 = (top == 0) ? m : (m < top ? m : top)
    for (i = 1; i <= lim2; i++)
        printf "CLIENT_IP\t%s\t%d\n", ip_sorted[i], client_ips[ip_sorted[i]]
}
'

# ---------------------------------------------------------------------------
# AGG_CSV_FUNC — RFC-4180 gawk quoter (verbatim from bin/analyze_access.sh)
# ---------------------------------------------------------------------------
# Single source of truth for the q(s) gawk function (C7). Prepend this string
# to any gawk program that needs RFC-4180 CSV quoting, e.g.:
#   gawk "$AGG_CSV_FUNC"'{ print q($1) "," q($2) }' file
AGG_CSV_FUNC='
function q(s) {
    if (s ~ /[",\n]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
    return s
}
'

# ---------------------------------------------------------------------------
# Canonical emit-stats schema constants (D5 contract)
# ---------------------------------------------------------------------------
# IIS_STAT_SCHEMA — row format emitted by analyze_iis --emit-stats.
# Each row: IIS <TAB> region <TAB> role <TAB> server <TAB> TAG [<TAB> fields...]
#
# Tags and trailing fields:
#   TOTAL      <n>
#   5XX        <n>
#   503_HEALTH <n>
#   SLOW       <n>
#   REDIRECT   <n>
#   UNIQUE_IPS <n>
#   STATUS     <code>  <count>
#   ENDPOINT   <uri>   <count>  <avg_sec>
#   CLIENT_IP  <ip>    <count>
IIS_STAT_SCHEMA='IIS\tregion\trole\tserver\tTAG[\tfields...]'

# Field indices for IIS emit-stats rows (1-based, TAB-delimited).
IIS_F_MODULE=1   # "IIS"
IIS_F_REGION=2
IIS_F_ROLE=3     # api | app
IIS_F_SERVER=4
IIS_F_TAG=5      # TOTAL | 5XX | ... | STATUS | ENDPOINT | CLIENT_IP
IIS_F_KEY=6      # code (STATUS) | uri (ENDPOINT) | ip (CLIENT_IP) | n (scalars)
IIS_F_COUNT=7    # count for STATUS / ENDPOINT / CLIENT_IP
IIS_F_AVGSEC=8   # avg_sec for ENDPOINT only

# ACCESS_STAT_SCHEMA — row format emitted by analyze_access --emit-stats.
# Each row: ACCESS <TAB> region <TAB> TAG <TAB> value
#
# Tags:
#   NORMAL  ORPHAN  UNVERIFIED  ORPHAN_OK  ORPHAN_FAIL
#   DELTA_COUNT  DELTA_SUM  DELTA_MIN  DELTA_MAX
ACCESS_STAT_SCHEMA='ACCESS\tregion\tTAG\tvalue'

# Field indices for ACCESS emit-stats rows (1-based, TAB-delimited).
ACC_F_MODULE=1   # "ACCESS"
ACC_F_REGION=2
ACC_F_TAG=3      # NORMAL | ORPHAN | UNVERIFIED | ... | DELTA_*
ACC_F_VALUE=4    # numeric value

# ---------------------------------------------------------------------------
# agg_iis_rows — run AGG_IIS_AWK on a combined IIS log corpus
# ---------------------------------------------------------------------------

# agg_iis_rows COMBINED SLOW_MS [TOP]
#   Purpose : Execute AGG_IIS_AWK against a concatenated IIS log file and emit
#             the raw TAB-delimited kind-tagged rows to stdout.
#   Args    : COMBINED — path to concatenated IIS log file (may be empty → no output).
#             SLOW_MS  — slow-request threshold in milliseconds (role-resolved).
#             TOP      — [optional] max ENDPOINT/CLIENT_IP rows (0=all; default from
#                        $OPT_TOP global when set, else 0).
#   Output  : TAB-delimited rows: TOTAL, 5XX, 503_HEALTH, SLOW, REDIRECT,
#             UNIQUE_IPS, STATUS <code> <count>, ENDPOINT <uri> <count> <avg_sec>,
#             CLIENT_IP <ip> <count>.
#   Returns / Side effects : none (pure stdout pipeline).
#   Errors / Notes : empty COMBINED produces no output (gawk handles gracefully).
agg_iis_rows() {
    local combined="$1" slow_ms="$2" top_n="${3:-${OPT_TOP:-0}}"
    gawk -v slow_ms="$slow_ms" -v top="$top_n" "$AGG_IIS_AWK" "$combined"
}

# ---------------------------------------------------------------------------
# agg_access_rows — single-pass access correlation stats aggregation
# ---------------------------------------------------------------------------

# agg_access_rows RESULT_SORTED
#   Purpose : Aggregate NORMAL/ORPHAN/UNVERIFIED counts, ORPHAN verify results,
#             and NORMAL delta statistics in a SINGLE gawk pass over the sorted
#             correlation output file. Replaces the three separate counting passes
#             at analyze_access.sh:351-353 (agg_access_rows phase — the renders
#             still use the individual counts in the current phase; these will be
#             wired in during the access analyzer refactor phase).
#   Args    : RESULT_SORTED — path to the sorted 12-field correlation TSV file.
#             Schema: $1=STATUS $2=API_TIME $3=APP_TIME $4=DELTA_SEC
#                     $5=VERIFY_STATUS $6=REQUEST_ID $7=API_SERVER $8=APP_SERVER
#                     $9=HOSP_ID $10=PRSN_ID $11=CLIENT_IP $12=PATIENT_ID_AES
#   Output  : TAB-delimited rows on stdout:
#               NORMAL\t<n>
#               ORPHAN\t<n>
#               UNVERIFIED\t<n>
#               ORPHAN_OK\t<n>
#               ORPHAN_FAIL\t<n>
#               DELTA_COUNT\t<n>
#               DELTA_SUM\t<sec>
#               DELTA_MIN\t<sec>
#               DELTA_MAX\t<sec>
#   Returns / Side effects : none (pure stdout pipeline).
#   Errors / Notes : DELTA_MIN/MAX/SUM are 0 when no valid NORMAL delta exists.
agg_access_rows() {
    local result_sorted="$1"
    gawk -F'\t' '
        $1 == "NORMAL"     { normal++ }
        $1 == "ORPHAN"     {
            orphan++
            if ($5 == "OK") orphan_ok++
            else            orphan_fail++
        }
        $1 == "UNVERIFIED" { unverified++ }
        $1 == "NORMAL" && $4 != "N/A" && $4 != "-" {
            d = $4 + 0
            if (d >= 0) {
                delta_sum += d; delta_count++
                if (delta_min == "" || d < delta_min) delta_min = d
                if (d > delta_max) delta_max = d
            }
        }
        END {
            printf "NORMAL\t%d\n",      normal+0
            printf "ORPHAN\t%d\n",      orphan+0
            printf "UNVERIFIED\t%d\n",  unverified+0
            printf "ORPHAN_OK\t%d\n",   orphan_ok+0
            printf "ORPHAN_FAIL\t%d\n", orphan_fail+0
            printf "DELTA_COUNT\t%d\n", delta_count+0
            printf "DELTA_SUM\t%g\n",   delta_sum+0
            if (delta_min == "") delta_min = 0
            printf "DELTA_MIN\t%g\n",   delta_min+0
            printf "DELTA_MAX\t%g\n",   delta_max+0
        }
    ' "$result_sorted"
}
