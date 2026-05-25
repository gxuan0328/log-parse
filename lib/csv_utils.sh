#!/usr/bin/env bash
# lib/csv_utils.sh — Field-extraction helpers for the three log formats
# consumed by the toolkit: access CSV, IIS W3C, and pipe-delimited app logs.
#
# All extractors:
#   - emit TAB-delimited records on stdout for downstream awk joins,
#   - strip carriage returns (logs are written from Windows servers),
#   - skip rows that lack the required join keys,
#   - return 0 on a missing input file (caller's loop just sees an empty stream).
#
# Source this file; do not execute directly.

# ---------------------------------------------------------------------------
# Column index resolution (header-driven)
# ---------------------------------------------------------------------------

# csv_col_index FILE HEADER_NAME
#   Purpose : Resolve 1-based column index of HEADER_NAME from FILE's first row.
#   Args    : FILE — path to CSV (must exist); HEADER_NAME — exact text match.
#   Output  : Index (e.g. "9") or empty string when not found.
#   Notes   : Strips \r from header cells so files saved on Windows match.
#             Currently unused by the production extractors (they use fixed
#             positions per the documented schema) but kept for ad-hoc tooling.
csv_col_index() {
    local file="$1" col_name="$2"
    gawk -F',' -v col="$col_name" '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                gsub(/\r/, "", $i)
                if ($i == col) { print i; exit }
            }
            exit 1
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# Access CSV extractors
# ---------------------------------------------------------------------------
# Access CSV schema (fixed positional layout):
#   1: REQUEST_ID         per-request UUID
#   2: TOKEN              URL token presented to APP (empty on API server)
#   3: VERIFY_STATUS      OK / FAIL (APP only)
#   4: PATIENT_ID_AES     AES-encrypted patient identifier
#   5: HOSP_ID            hospital code
#   6: PRSN_ID            clinician identifier (encrypted)
#   7: CLIENT_IP          browser-side IP
#   8: SERVER_IP          server that handled the request
#   9: ISSUE_TOKEN        URL token issued by API (empty on APP server)
#  10: REQUEST_TIME       YYYY-MM-DD HH:MM:SS.mmm (contains a literal space)
#
# The two sides of the correlation join meet at:
#   API.ISSUE_TOKEN (col 9)  ≡  APP.TOKEN (col 2)
# ---------------------------------------------------------------------------

# extract_api_records FILE
#   Purpose : Project the API-issuance side of the join.
#   Args    : FILE — path to an API server's app-access-<date>.csv.
#   Output  : TAB-delimited rows on stdout:
#               ISSUE_TOKEN | REQUEST_ID | PATIENT_ID_AES | HOSP_ID |
#               PRSN_ID     | CLIENT_IP  | SERVER_IP      | REQUEST_TIME
#   Skipped : Header row (NR==1); rows with empty ISSUE_TOKEN (col 9).
#   Returns : 0 silently when FILE is missing (allows callers to loop over a
#             list that may include yet-unrotated dates).
extract_api_records() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    gawk -F',' '
        NR == 1 { next }
        $9 == "" { next }
        {
            gsub(/\r/, "")
            print $9 "\t" $1 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $10
        }
    ' "$file"
}

# extract_app_records FILE
#   Purpose : Project the APP-verification side of the join.
#   Args    : FILE — path to an APP server's app-access-<date>.csv.
#   Output  : TAB-delimited rows on stdout:
#               TOKEN  | REQUEST_ID | VERIFY_STATUS | PATIENT_ID_AES |
#               HOSP_ID| PRSN_ID    | CLIENT_IP     | SERVER_IP      |
#               REQUEST_TIME
#   Skipped : Header row; rows with empty TOKEN (col 2).
extract_app_records() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    gawk -F',' '
        NR == 1 { next }
        $2 == "" { next }
        {
            gsub(/\r/, "")
            print $2 "\t" $1 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $10
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# IIS W3C log filter
# ---------------------------------------------------------------------------

# extract_iis_records FILE
#   Purpose : Strip W3C directive lines (#) and truncated rows; pass the rest
#             through unchanged so downstream awk can use positional fields.
#   Args    : FILE — path to u_exYYMMDD.log.
#   Filter  : Lines starting with # → comment. NF < 17 → truncated row.
#   Output  : Original line (space-delimited) for every kept row.
extract_iis_records() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    gawk '
        /^#/ { next }
        NF >= 17 {
            print $0
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# App log helpers — pipe-delimited records emitted by the .NET application's
# structured logger (Serilog-style expression template).
# Format (literal pipes, spaces around them are NOT trimmed):
#   YYYY-MM-DD HH:MM:SS.mmm|eventId: N|level: LEVEL|traceId: …|logger: …|message: …|
# ---------------------------------------------------------------------------

# extract_error_records FILE
#   Purpose : Stream rows tagged level=ERROR for downstream pattern analysis.
#   Args    : FILE — app-all-<date>.log or app-error-<date>.log.
#   Output  : Original line (with \r stripped) for every matching record.
extract_error_records() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    gawk -F'|' '
        /\|level: ERROR\|/ {
            gsub(/\r/, "")
            print
        }
    ' "$file"
}

# extract_lifetime_records FILE
#   Purpose : Stream Microsoft.Hosting.Lifetime events (start / shutdown).
#   Args    : FILE — app-lifetime-<date>.log (or app-all-<date>.log).
#   Output  : Original line with \r stripped.
extract_lifetime_records() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    gawk -F'|' '
        /Microsoft\.Hosting\.Lifetime/ {
            gsub(/\r/, "")
            print
        }
    ' "$file"
}
