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
# JWT_DOB_FUNC — report-url token payload decoder (extracts dob).
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
JWT_DOB_FUNC='
# ----------------------------------------------------------------------------
# Purpose : Decode a report-url JWT (segment 2, base64url) -> "dob" (YYYYMMDD).
# Input   : token -- compact JWS "<hdr>.<payload>.<sig>"; field1 of the api/app
#           extract (col9 ISSUE_TOKEN on API side / col2 TOKEN on APP side).
# Output  : verbatim dob string, or "-" when empty/malformed/absent.
# Notes   : Pure-gawk base64 (6-bit accumulate) -- no base64/openssl/python
#           (CLAUDE.md hard-no on new deps). Signature NOT verified (payload is
#           read for reporting, never trusted for auth). MUST run under LC_ALL=C
#           so sprintf("%c",byte) emits one exact byte. dob is captured VERBATIM
#           ([^"]* -- fail-loud on format drift) then structurally sanitized
#           (TAB/CR/LF stripped) so a value can never break a TSV/CSV row.
# ----------------------------------------------------------------------------
function jwt_dob(token,   segn, seg, payload, b64, i, c, p, val, bits, nbits, byte, decoded, m, dob) {
    if (token == "") return "-"
    segn = split(token, seg, ".")
    if (segn < 2) return "-"
    payload = seg[2]
    if (payload == "") return "-"
    gsub(/-/, "+", payload)                 # base64url -> base64 alphabet
    gsub(/_/, "/", payload)
    b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    bits = 0; nbits = 0; decoded = ""
    for (i = 1; i <= length(payload); i++) {
        c = substr(payload, i, 1)
        if (c == "=") break                 # padding terminates the stream
        p = index(b64, c)
        if (p == 0) continue                # skip any stray non-alphabet byte
        val = p - 1                          # 0..63
        bits = bits * 64 + val               # shift-left 6 and OR-in the sextet
        nbits += 6
        if (nbits >= 8) {                    # a whole byte is available
            nbits -= 8
            byte = int(bits / (2 ^ nbits)) % 256
            bits = bits % (2 ^ nbits)        # keep low nbits (bounded < 2^13)
            decoded = decoded sprintf("%c", byte)
        }
    }
    if (match(decoded, /"dob"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) {
        dob = m[1]
        gsub(/[\t\r\n]/, "", dob)            # structural sanitize: never break TSV/CSV
        return (dob != "") ? dob : "-"
    }
    return "-"
}
'

# extract_api_records FILE [TH_MODE] [TH_SET]
#   Purpose : Project the API-issuance side of the join, filtered by test-host mode.
#   Args    : FILE    — path to an API server's app-access-<date>.csv.
#             TH_MODE — [optional] test-host mode: exclude (default) | only | all.
#             TH_SET  — [optional] space-joined IP string from load_test_hosts.
#   Output  : TAB-delimited rows on stdout:
#               ISSUE_TOKEN | REQUEST_ID | PATIENT_ID_AES | HOSP_ID |
#               PRSN_ID     | CLIENT_IP  | SERVER_IP      | REQUEST_TIME
#   Skipped : Header row (NR==1); rows with empty ISSUE_TOKEN (col 9);
#             rows whose CLIENT_IP (col 7) fails th_skip per TH_MODE.
#   Returns : 0 silently when FILE is missing (allows callers to loop over a
#             list that may include yet-unrotated dates).
#   Notes   : Requires $TH_FILTER_FUNC from common.sh (sourced before any call).
#             CLIENT_IP = source column $7. $7 is mid-row (CR rides on $10),
#             so the exact match is CR-safe.
extract_api_records() {
    local file="$1" th_mode="${2:-exclude}" th_set="${3:-}"
    [[ -f "$file" ]] || return 0
    gawk -F',' -v _th_mode="$th_mode" -v th_set="$th_set" \
        "$TH_FILTER_FUNC"'
        BEGIN { th_init(th_set) }
        NR == 1 { next }
        $9 == "" { next }
        th_skip($7) { next }                 # CLIENT_IP = source col 7
        { gsub(/\r/, ""); print $9 "\t" $1 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $10 }
    ' "$file"
}

# extract_app_records FILE [TH_MODE] [TH_SET]
#   Purpose : Project the APP-verification side of the join, filtered by test-host mode.
#   Args    : FILE    — path to an APP server's app-access-<date>.csv.
#             TH_MODE — [optional] test-host mode: exclude (default) | only | all.
#             TH_SET  — [optional] space-joined IP string from load_test_hosts.
#   Output  : TAB-delimited rows on stdout:
#               TOKEN  | REQUEST_ID | VERIFY_STATUS | PATIENT_ID_AES |
#               HOSP_ID| PRSN_ID    | CLIENT_IP     | SERVER_IP      |
#               REQUEST_TIME
#   Skipped : Header row; rows with empty TOKEN (col 2);
#             rows whose CLIENT_IP (col 7) fails th_skip per TH_MODE.
#   Notes   : Requires $TH_FILTER_FUNC from common.sh (sourced before any call).
#             CLIENT_IP = source column $7. Both issuance and verification rows
#             for a test-host token share CLIENT_IP, so filtering both sides
#             removes the whole correlation record cleanly (no orphan artifacts).
extract_app_records() {
    local file="$1" th_mode="${2:-exclude}" th_set="${3:-}"
    [[ -f "$file" ]] || return 0
    gawk -F',' -v _th_mode="$th_mode" -v th_set="$th_set" \
        "$TH_FILTER_FUNC"'
        BEGIN { th_init(th_set) }
        NR == 1 { next }
        $2 == "" { next }
        th_skip($7) { next }                 # CLIENT_IP = source col 7
        { gsub(/\r/, ""); print $2 "\t" $1 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $10 }
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
