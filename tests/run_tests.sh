#!/usr/bin/env bash
# tests/run_tests.sh — Functional test suite for log-parse analysis scripts.
#
# Covers all four scripts, all regions, all parameter modes, output formats,
# and error handling. Baselines are derived from the examples/sample-logs/LUNG-CANCER-REPORT-LOG
# sample data included in the project (dates 2026-05-18 ~ 2026-05-25).
#
# Total: 316 tests across twelve sections (A access · B iis · C errors · D log_report ·
#        E validation · F user scenarios · G CJK alignment · H overview · I persistence ·
#        J test-host/health · K timezone+core-function · L notify SMTP-API delivery).
# Note: Sections J, K and L exist beyond I; K13/K14 are intentionally vacant (gap preserved).
#
# Usage:  bash tests/run_tests.sh
# Exit:   0 = all passed,  1 = one or more failures

# Belt-and-suspenders TZ pin: the string-bounds IIS filter is already host-TZ-
# independent, but this guards any incidental `date` calls in the suite itself.
export TZ=UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG"

ACCESS="${PROJECT_DIR}/bin/analyze_access.sh"
IIS="${PROJECT_DIR}/bin/analyze_iis.sh"
ERRORS="${PROJECT_DIR}/bin/analyze_errors.sh"
REPORT="${PROJECT_DIR}/bin/log_report.sh"
OVERVIEW="${PROJECT_DIR}/bin/analyze_overview.sh"

PASS=0
FAIL=0

# ── Global persistence redirect ───────────────────────────────────────────────
# Always-on persistence writes to this temp dir instead of CWD ./log-parse/.
# Every analyzer inherits LOG_PARSE_OUTPUT_DIR via env; tests that supply
# --output-dir explicitly override it via the flag (flag > env in persist_init).
PERSIST_TMPDIR=$(mktemp -d /tmp/lp_persist.XXXXXX)
export LOG_PARSE_OUTPUT_DIR="$PERSIST_TMPDIR"
trap 'rm -rf "${PERSIST_TMPDIR:-}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_pass() { echo "  [PASS] $*"; PASS=$(( PASS + 1 )); }
_fail() { echo "  [FAIL] $*"; FAIL=$(( FAIL + 1 )); }

# _eq ID DESC ACTUAL EXPECTED
_eq() {
    local id="$1" desc="$2" actual="$3" expected="$4"
    if [[ "$actual" == "$expected" ]]; then
        _pass "${id}  ${desc}  (${actual})"
    else
        _fail "${id}  ${desc}  [expected=${expected}  got=${actual}]"
    fi
}

# _gte ID DESC ACTUAL MIN
_gte() {
    local id="$1" desc="$2" actual="${3:-0}" min="$4"
    if (( actual >= min )); then
        _pass "${id}  ${desc}  (${actual} >= ${min})"
    else
        _fail "${id}  ${desc}  [expected>=${min}  got=${actual}]"
    fi
}

# _has ID DESC OUTPUT PATTERN
_has() {
    local id="$1" desc="$2"
    if printf '%s\n' "$3" | grep -qF "$4" 2>/dev/null; then
        _pass "${id}  ${desc}"
    else
        _fail "${id}  ${desc}  [pattern not found: '${4}']"
    fi
}

# _lacks ID DESC OUTPUT PATTERN
_lacks() {
    local id="$1" desc="$2"
    if printf '%s\n' "$3" | grep -qF "$4" 2>/dev/null; then
        _fail "${id}  ${desc}  [pattern should not be present: '${4}']"
    else
        _pass "${id}  ${desc}"
    fi
}

# _hasre ID DESC OUTPUT EREGEX  — assert an extended-regex match is present.
# Use when fixed-string _has cannot lock column ORDER (e.g. a reordered header
# whose tokens also appear, in a different order, in the old layout).
_hasre() {
    local id="$1" desc="$2"
    if printf '%s\n' "$3" | grep -qE "$4" 2>/dev/null; then
        _pass "${id}  ${desc}"
    else
        _fail "${id}  ${desc}  [regex not found: '${4}']"
    fi
}

# _glob ID DESC GLOB — assert at least one file matches the shell glob.
# Use for persistence tests where the filename contains a timestamp component.
_glob() {
    local id="$1" desc="$2" glob="$3"
    if compgen -G "$glob" > /dev/null 2>&1; then
        _pass "${id}  ${desc}"
    else
        _fail "${id}  ${desc}  [no files match: '${glob}']"
    fi
}

# _ok ID DESC EXIT_CODE
_ok() {
    local id="$1" desc="$2" rc="$3"
    if [[ "$rc" -eq 0 ]]; then
        _pass "${id}  ${desc}"
    else
        _fail "${id}  ${desc}  [exit=${rc}, expected 0]"
    fi
}

# _err ID DESC EXIT_CODE
_err() {
    local id="$1" desc="$2" rc="$3"
    if [[ "$rc" -ne 0 ]]; then
        _pass "${id}  ${desc}  (exit=${rc})"
    else
        _fail "${id}  ${desc}  [expected non-zero exit]"
    fi
}

# Extract last whitespace-separated token from the first matching line.
# _pick OUTPUT "grep-literal-string"
_pick() { printf '%s\n' "$1" | grep "$2" | awk '{print $NF}' | head -1; }

# Sum all last tokens from matching lines.
# _sum OUTPUT "grep-literal-string"
_sum() { printf '%s\n' "$1" | grep "$2" | awk '{s+=$NF} END{print s+0}'; }

section() {
    echo ""
    echo "▶ $*"
    echo "────────────────────────────────────────────────────────────────────────"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo ""
echo "========================================================================"
echo "  Log-Parse Functional Test Suite"
echo "  Project : ${PROJECT_DIR}"
echo "  Log data: ${LOG_DIR}"
echo "========================================================================"

if [[ ! -d "$LOG_DIR" ]]; then
    echo ""
    echo "  [ERROR] Sample data not found: ${LOG_DIR}"
    echo "  Ensure examples/sample-logs/LUNG-CANCER-REPORT-LOG is present."
    exit 1
fi

for bin in "$ACCESS" "$IIS" "$ERRORS" "$REPORT" "$OVERVIEW"; do
    [[ -x "$bin" ]] || chmod +x "$bin"
done

# ─────────────────────────────────────────────────────────────────────────────
# Section A — analyze_access.sh  存取日誌交叉比對
# Baselines (fixed dates, --test-hosts exclude default):
#   taipei  2026-05-21 : Total=3   NORMAL=0  ORPHAN=3  UNVERIFIED=0
#   taipei  2026-05-25 : Total=0   (全為測試主機 .110/.79，已排除)
#   taipei  range 21~25: Total=3   NORMAL=0  ORPHAN=3
#   taichung 2026-05-21: Total=6   NORMAL=6  ORPHAN=0  UNVERIFIED=0
#   taichung 2026-05-25: (無 CSV — 乾淨空輸出)
#   BIRTHDAY (JWT dob, field 14 of tsv/csv, trailing column of text tables):
#     taichung NORMAL  PATIENT_ID_AES=B67EDA342C22CD73F88571E0E54CFE81 -> 19700404
#     taichung NORMAL  PATIENT_ID_AES=EBD71A864A0F7E6A355827754B89259E -> 19410712
#     taipei   ORPHAN  PATIENT_ID_AES=2EDEBACB75D9FA547F2018E13E695AF1 -> 19560711
# ─────────────────────────────────────────────────────────────────────────────

section "A  analyze_access.sh — 存取日誌交叉比對"

# A1: taipei 2026-05-21 基準值
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
_ok  A01 "taipei 2026-05-21 執行成功"  "$rc"
_eq  A02 "taipei 2026-05-21  NORMAL=0"      "$(_pick "$out" "NORMAL  (")"       "0"
_eq  A03 "taipei 2026-05-21  ORPHAN=3"      "$(_pick "$out" "ORPHAN  (")"       "3"
_eq  A04 "taipei 2026-05-21  UNVERIFIED=0"  "$(_pick "$out" "UNVERIFIED (")"    "0"
_eq  A05 "taipei 2026-05-21  Total=3"       "$(_pick "$out" "Total correlation")" "3"

# A2: NORMAL 欄位標頭包含 HOSP_ID / CLIENT_IP 獨立欄位 (新格式；舊 HOSP:/CLIENT: 前綴已移除)
_has A06 "NORMAL 欄位標頭含 HOSP_ID"   "$out" "HOSP_ID"
_has A07 "NORMAL 欄位標頭含 CLIENT_IP"  "$out" "CLIENT_IP"

# A3: taichung 2026-05-21 基準值 (全部 NORMAL，無 HOSP/CLIENT)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null); rc=$?
_ok  A08 "taichung 2026-05-21 執行成功"  "$rc"
_eq  A09 "taichung 2026-05-21  NORMAL=6"     "$(_pick "$out" "NORMAL  (")"       "6"
_eq  A10 "taichung 2026-05-21  ORPHAN=0"     "$(_pick "$out" "ORPHAN  (")"       "0"
_eq  A11 "taichung 2026-05-21  UNVERIFIED=0" "$(_pick "$out" "UNVERIFIED (")"    "0"

# A4: all 2026-05-21 含兩個區域標頭
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null); rc=$?
_ok  A12 "all 2026-05-21 執行成功"  "$rc"
_has A13 "all regions 包含台北區域"   "$out" "台北"
_has A14 "all regions 包含台中區域"   "$out" "台中"
# Both region NORMAL totals: 0+6=6 (taipei .110 records excluded, taichung unaffected)
total_normal=$(_sum "$out" "NORMAL  (")
_eq  A15 "all regions 兩區域 NORMAL 合計=6"  "$total_normal"  "6"

# A5: taipei 日期範圍 2026-05-21 ~ 2026-05-25 (累計)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-25 --region taipei 2>/dev/null); rc=$?
_ok  A16 "taipei --from 2026-05-21 --to 2026-05-25 執行成功"  "$rc"
_eq  A17 "taipei 5日範圍  NORMAL=0"   "$(_pick "$out" "NORMAL  (")"       "0"
_eq  A18 "taipei 5日範圍  ORPHAN=3"   "$(_pick "$out" "ORPHAN  (")"       "3"
_eq  A19 "taipei 5日範圍  Total=3"    "$(_pick "$out" "Total correlation")" "3"

# A6: taipei 2026-05-25 單日 (under exclude: both .110 NORMAL + .79 ORPHAN are test hosts → Total=0)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-25 --region taipei 2>/dev/null); rc=$?
_ok  A20 "taipei 2026-05-25 執行成功"  "$rc"
total="$(_pick "$out" "Total correlation")"; total="${total:-0}"
_eq  A21 "taipei 2026-05-25  Total=0 (全業務記錄為測試主機)"  "$total"  "0"
_lacks A22 "taipei 2026-05-25 業務輸出不含 .110 測試主機 IP"  "$out"  "192.168.139.110"

# A7: taichung 2026-05-25 無 CSV 資料 — 乾淨結束，Total=0
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --date 2026-05-25 --region taichung 2>/dev/null); rc=$?
_ok  A23 "taichung 2026-05-25 (無 CSV) 乾淨結束"  "$rc"
total="$(_pick "$out" "Total correlation")"; total="${total:-0}"
_eq  A24 "taichung 2026-05-25 無資料 Total=0"  "$total"  "0"

# A8: --days 相對日期不崩潰
bash "$ACCESS" --log-dir "$LOG_DIR" --days 3 --region taipei >/dev/null 2>&1; rc=$?
_ok  A25 "--days 3 --region taipei 執行不崩潰"  "$rc"

# A9: persistence model — access 持久化寫入目錄 (--output 已移除; 改用 --output-dir 持久化)
TMPD_A26=$(mktemp -d /tmp/lp_a26.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --output-dir "$TMPD_A26" >/dev/null 2>&1; rc=$?
_ok  A26 "--output-dir 持久化執行成功"  "$rc"
det_file=$(ls "$TMPD_A26"/*/access_detail*.txt 2>/dev/null | head -1)
if [[ -n "$det_file" && -s "$det_file" ]]; then
    _pass "A27  access_detail*.txt 已產生且非空白"
else
    _fail "A27  access_detail*.txt 不存在或為空"
fi
rm -rf "$TMPD_A26"

# ─────────────────────────────────────────────────────────────────────────────
# Section A (continued) — A28–A34  新增行為回歸
# Baselines (fixed dates, --test-hosts exclude default):
#   taipei week NORMAL = 0 (全為測試主機 .110，已排除); ORPHAN = 3
#   PATIENT_ID_AES: taichung week B67EDA342C22CD73F88571E0E54CFE81 (NORMAL record)
#   week tsv/csv header: REQUEST_ID (merged); no API_REQUEST_ID / APP_REQUEST_ID
#   --merge week: merged NORMAL=6 (taipei=0, taichung=6)
# ─────────────────────────────────────────────────────────────────────────────

# A10: 遞增排序 (ASC sort by API_TIME)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --region taipei 2>/dev/null)
# Extract first two NORMAL API_TIME tokens; lexical ASC on fixed-width timestamp == chronological
t1=$(printf '%s\n' "$out" | gawk '/■ 正常流程/{p=1;next} p && /^    [0-9]{4}/ {print $1" "$2; exit}')
t2=$(printf '%s\n' "$out" | gawk '/■ 正常流程/{p=1;next} p && /^    [0-9]{4}/ {n++;if(n==2){print $1" "$2;exit}}')
sorted_first=$(printf '%s\n' "$t1" "$t2" | sort | head -1)
_eq A28 "NORMAL 記錄以 API_TIME 遞增排序 (t1≤t2)" "$t1" "$sorted_first"

# A11: 完整 PATIENT_ID_AES，無截斷 (repointed to taichung week: 排除後仍有 NORMAL 記錄)
out29=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --region taichung 2>/dev/null)
_has A29 "NORMAL 記錄含完整 PATIENT_ID_AES (32 hex，無截斷)" "$out29" "B67EDA342C22CD73F88571E0E54CFE81"

# A12: per-category 欄位標頭含 PRSN_ID
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
_has A30 "per-category 欄位標頭含 PRSN_ID (NORMAL/ORPHAN 均出現)" "$out" "PRSN_ID"

# A13: tsv 標頭含 REQUEST_ID (合併欄位)；不含舊 API_REQUEST_ID
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format tsv 2>/dev/null)
_lacks A31 "tsv 標頭已移除舊欄位 API_REQUEST_ID (合併為 REQUEST_ID)" "$out" "API_REQUEST_ID"

# A14: --format csv 標頭以逗號分隔
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format csv 2>/dev/null)
_has A32 "--format csv 標頭含 'REGION,STATUS,API_TIME'" "$out" "REGION,STATUS,API_TIME"

# A15: --merge 合區塊 (merged NORMAL >= Σ per-region NORMAL)
# Baselines: per-region taipei-week=0, taichung-week=6, sum=6; merged-week NORMAL=6
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --merge 2>/dev/null)
merged_normal=$(printf '%s\n' "$out" | grep "NORMAL  (" | awk '{print $NF}' | head -1)
_gte A33 "--merge NORMAL 數量 >= Σ per-region (taipei=0 taichung=6 sum=6)" "${merged_normal:-0}" "6"

# A16: --merge 無資料日期 — 乾淨結束
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-20 --merge >/dev/null 2>&1; rc=$?
_ok A34 "--merge 無資料日期 (2026-05-20) 乾淨結束" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section B — analyze_iis.sh  IIS W3C 存取日誌分析
# Baselines (2026-05-21, business-only: /health excluded, --test-hosts exclude):
#   taipei  10.22.63.37 (API): Total=5    slow(>2000ms)=0
#   taipei  10.21.3.35  (APP): Total=117  slow(>5000ms)=0
#   taipei  10.21.3.36  (APP): Total=209  slow(>5000ms)=0
#   taichung 10.1.73.37 (API): Total=6    slow(>2000ms)=0
#   taichung 10.1.72.35 (APP): Total=88   slow(>5000ms)=0
#   taichung 10.1.72.36 (APP): Total=298  slow(>5000ms)=1
#   taipei --top 0 (2026-05-21): 32 total endpoint rows (10.22.63.37=1, .35=16, .36=15)
#   taipei --top 10 (default):   21 total endpoint rows (1+10+10)
# ─────────────────────────────────────────────────────────────────────────────

section "B  analyze_iis.sh — IIS W3C 日誌分析"

# B1: taipei 2026-05-21 各伺服器業務請求總數 (business-only: /health excluded, --test-hosts exclude)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
_ok  B01 "taipei 2026-05-21 執行成功"  "$rc"
# First server block: 10.22.63.37 = 5 (business requests only)
first_total=$(printf '%s\n' "$out" | grep "Total requests" | awk '{print $NF}' | head -1)
_eq  B02 "taipei 10.22.63.37 Total requests=5"  "$first_total"  "5"
# Sum across all 3 servers: 5+117+209=331
sum_total=$(_sum "$out" "Total requests")
_eq  B03 "taipei 三伺服器 Total requests 合計=331"  "$sum_total"  "331"

# B3: taichung 2026-05-21 基準 (5xx/503 KPI 已移除; business-only)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null); rc=$?
_ok  B05 "taichung 2026-05-21 執行成功"  "$rc"

# B4: all 2026-05-21 兩區域合併輸出 (business-only)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null); rc=$?
_ok  B08 "all regions 2026-05-21 執行成功"  "$rc"
# Total across all 6 servers: 5+117+209+6+88+298=723
sum_all=$(_sum "$out" "Total requests")
_eq  B09 "all regions Total requests 合計=723"  "$sum_all"  "723"

# B5: STATUS 表格依 count 降序排序 — 200 (最高量) 應排在 302 之前
# Verify for taichung 10.1.72.36 where both 200 and 302 appear (503 removed with /health)
out_tc=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null)
line_200=$(printf '%s\n' "$out_tc" | grep -n "^    200 " | head -1 | cut -d: -f1)
line_302=$(printf '%s\n' "$out_tc" | grep -n "^    302 " | head -1 | cut -d: -f1)
if [[ -n "$line_200" && -n "$line_302" && "$line_200" -lt "$line_302" ]]; then
    _pass "B10  STATUS 表格 200 (高 count) 排在 302 之前"
else
    _fail "B10  STATUS 表格排序錯誤 (200 應在 302 前: line_200=${line_200} line_302=${line_302})"
fi

# B6: --slow-api-ms 自訂 API 門檻 (1ms 應偵測到大量慢請求)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --slow-api-ms 1 2>/dev/null); rc=$?
_ok  B11 "--slow-api-ms 1 執行成功"  "$rc"
any_slow=$(_sum "$out" "Slow (>1ms)")
_gte B12 "--slow-api-ms 1 偵測到慢請求 >= 1"  "$any_slow"  "1"

# B7: 日期範圍 累計請求量 >= 單日
out_range=$(bash "$IIS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-22 --region taipei 2>/dev/null); rc=$?
_ok  B13 "taipei --from --to 日期範圍執行成功"  "$rc"
range_sum=$(_sum "$out_range" "Total requests")
_gte B14 "兩日累計 Total requests >= 單日 331"  "$range_sum"  "331"

# B8: Client IP 清單區段（新格式：IP 優先，舊 'Count  Client IP' 已改為 'Client IP  Count  % of total'）
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
# IP-first 表頭順序鎖定 (regex)：'Client IP' 必須排在 'Count' 之前，
# 否則舊版 'Count  Client IP' 也含子字串 'Client IP' 會誤判通過。
_hasre B15 "Client IP 表頭為 IP-first (Client IP→Count→% of total)" "$out" "Client IP +Count +% of total"
_has B16 "Client IP 清單含 % of total 欄位"  "$out" "% of total"
# 台北 10.21.3.35/.36 主要客戶端 192.168.139.119 (real gateway; .28 is test host, excluded)
_has B17 "Client IP 清單列出主要客戶端"  "$out" "192.168.139.119"
# 計數列至少 9 行（taipei 3 台伺服器各列出多個 IP）。IP-first 列以點分四段
# IP 開頭，與 Status 列（純數字）/Endpoint 列（/ 開頭）區隔，避免誤計。
ip_lines=$(printf '%s\n' "$out" | gawk '/^    [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+  +[0-9]/{c++} END{print c+0}')
_eq B18 "Client IP 計數列數 == 3 (taipei 排除測試主機後每台伺服器各 1 IP)"  "$ip_lines"  "3"

# B9: Client IP 區段在台中 OracleDB 中斷日仍正確呈現 (IP-first 新格式)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null); rc=$?
_hasre B19 "taichung Client IP 表頭為 IP-first"  "$out" "Client IP +Count +% of total"

# B10: Endpoint 平均回應時間欄位（新格式：Endpoint-first，欄位順序 Endpoint Avg(s) Count % of total）
# Baselines (taipei 2026-05-21):
#   10.22.63.37 /health  : count=472  avg=0.06s   (次秒級邊界)
#   10.21.3.35  series   : count=146  avg=1.03s   (慢速 DICOM 影像端點)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
_has B20 "Endpoint 表含 Avg(s) 平均回應時間欄位表頭"  "$out" "Avg(s)"
# 慢速 DICOM series 端點：business-only avg (test hosts excluded) = 1.87s
series_avg=$(printf '%s\n' "$out" | gawk '/series\/\{uid\}\/\.\.\./ {print $2; exit}')
_eq  B21 "DICOM series 端點平均回應時間=1.87s (業務請求 business-only)"  "$series_avg"  "1.87"
# 次秒級業務端點 /api/GetLungCancerReportURL 在 10.22.63.37 仍以兩位小數呈現
api_avg=$(printf '%s\n' "$out" | gawk '$1=="/api/GetLungCancerReportURL" {print $2; exit}')
_eq  B22 "/api/GetLungCancerReportURL 端點平均回應時間=0.02s (業務端點兩位小數)"  "$api_avg"  "0.02"

# ─────────────────────────────────────────────────────────────────────────────
# Section B (continued) — B23–B31  新增行為回歸
# ─────────────────────────────────────────────────────────────────────────────

# B11: Endpoint 表格 Endpoint-first 欄位順序
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
_hasre B23 "Endpoint 表頭順序 Endpoint→Avg(s)→Count→% of total" "$out" "Endpoint +Avg\(s\) +Count +% of total"

# B12: Status 表格含 % of total
_has B24 "Status 表格含 '% of total' 欄位" "$out" "% of total"

# B13: Client IP 表格新欄位順序 (IP-first，鎖定順序)
_hasre B25 "Client IP 表頭順序 Client IP→Count→% of total" "$out" "Client IP +Count +% of total"

# B14: --top 3 端點上限 (每伺服器最多 3 行)
# Baseline: all regions 2026-05-21 --top 3 → max endpoint rows per block = 3
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --top 3 2>/dev/null)
max_ep3=$(printf '%s\n' "$out" | gawk '
/^▶ IIS —/{if(srv!="" && ep_cnt>m) m=ep_cnt; srv=$3; ep_cnt=0; in_ep=0; next}
/Endpoint.*Avg/{in_ep=1; next}
/Client IP/{in_ep=0}
in_ep && /^    \// {ep_cnt++}
END{if(ep_cnt>m) m=ep_cnt; print m+0}
')
_eq B26 "--top 3 每伺服器端點列數上限=3" "$max_ep3" "3"

# B15: --top 0 顯示全部端點
# Baseline: taipei 2026-05-21 --top 0 → 42 endpoint rows (2+22+18)
#           taipei 2026-05-21 default  → 22 endpoint rows (2+10+10)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei --top 0 2>/dev/null)
ep0=$(printf '%s\n' "$out" | grep -c "^    /" || true)
_eq B27 "--top 0 顯示所有端點 (taipei 2026-05-21 = 32 rows, business-only)" "$ep0" "32"

# B16: --slow-api-ms 自訂 API 門檻標籤
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --slow-api-ms 1234 2>/dev/null)
_has B28 "--slow-api-ms 1234 API 塊顯示 'Slow (>1234ms)'" "$out" "Slow (>1234ms)"

# B17: --slow-app-ms 自訂 APP 門檻標籤
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --slow-app-ms 5678 2>/dev/null)
_has B29 "--slow-app-ms 5678 APP 塊顯示 'Slow (>5678ms)'" "$out" "Slow (>5678ms)"

# B18: 預設門檻 API=2000ms APP=5000ms 均顯示 (both must be present)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
if printf '%s\n' "$out" | grep -qF "Slow (>2000ms)" 2>/dev/null && \
   printf '%s\n' "$out" | grep -qF "Slow (>5000ms)" 2>/dev/null; then
    _pass "B30  預設門檻 API(>2000ms) AND APP(>5000ms) 均出現"
else
    _fail "B30  預設門檻 API(>2000ms) AND APP(>5000ms) 均出現"
fi

# B19: --merge 輸出兩個合併服務塊 (API_SERVERS + APP_SERVERS)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --merge 2>/dev/null)
if printf '%s\n' "$out" | grep -qF "API_SERVERS (merged" 2>/dev/null && \
   printf '%s\n' "$out" | grep -qF "APP_SERVERS (merged" 2>/dev/null; then
    _pass "B31  --merge 輸出 API_SERVERS(merged) AND APP_SERVERS(merged)"
else
    _fail "B31  --merge 輸出 API_SERVERS(merged) AND APP_SERVERS(merged)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section B (continued) — B32–B38  summary/detail/emit-stats/format 新功能
# ─────────────────────────────────────────────────────────────────────────────

# B20: --view summary 輸出摘要 KPI 區塊（含 CJK 標籤與 %）
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --view summary 2>/dev/null); rc=$?
_has B32 "iis --view summary 含 '總請求數' KPI 標籤" "$out" "總請求數"

# B21: --format tsv --view detail 輸出長格式 header（含 REGION ROL SERVER METRIC 欄位順序）
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --view detail --format tsv 2>/dev/null)
_hasre B33 "tsv detail header 含 REGION.*ROLE.*SERVER.*METRIC 欄位順序" "$out" "REGION.*ROLE.*SERVER.*METRIC"

# B22: --format csv detail 各資料列欄位數均為 8（與 header 一致）
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --view detail --format csv 2>/dev/null)
# header NF=8; verify first data row also has NF=8
col_check=$(printf '%s\n' "$out" | gawk -F',' 'NR==2{print NF; exit}')
_eq B34 "csv detail 第一筆資料列欄位數=8" "$col_check" "8"

# B23: --emit-stats 輸出 IIS TOTAL 列且無 fmt_h1 標頭橫幅
em=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --emit-stats 2>/dev/null)
if printf '%s\n' "$em" | grep -qE $'IIS\t.*\tTOTAL' 2>/dev/null && \
   ! printf '%s\n' "$em" | grep -qF "IIS Log Analysis Report" 2>/dev/null; then
    _pass "B35  --emit-stats 含 IIS TOTAL 列且無 fmt_h1 標頭"
else
    _fail "B35  --emit-stats 含 IIS TOTAL 列且無 fmt_h1 標頭"
fi

# B24: --view summary --top 3 端點清單上限 = 3
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --view summary --top 3 2>/dev/null)
ep_n=$(printf '%s\n' "$out" | grep -cE "^ +[0-9]+\. " 2>/dev/null || true)
_eq B36 "summary --top 3 端點列數 = 3" "$ep_n" "3"

# B25: 預設執行（無 --view）等同 detail — 含每台伺服器 per-server 表格
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
_has B37 "預設（無 --view）等同 detail：含 'Total requests'" "$out" "Total requests"

# B26: --format csv 不應再出現 'non-text not supported' 警告
err=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --format csv 2>&1 >/dev/null)
_lacks B38 "--format csv 不輸出 'not supported' 警告到 stderr" "$err" "not supported"

# B39: summary Top-端點 rank-1 行含 avg 令牌且落在 [1.00, 1.10]s 區間
# Rank-1 (nhi-series, ~1.05s) is uncapped (cnt=367=full pop), so band [1.00,1.10] is
# reproducible without replicating the per-server --top N cap (GAP-3 safe anchor).
out39=$(NO_COLOR=1 bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --view summary 2>/dev/null)
rank1_s=$(printf '%s\n' "$out39" | grep -E '^ +1\.' | grep -oE '[0-9]+\.[0-9]+s' | tail -1)
rank1_v="${rank1_s%s}"
if [[ -n "$rank1_v" ]]; then
    b39_chk=$(gawk -v v="$rank1_v" 'BEGIN{print (v>=1.00 && v<=1.10) ? "ok" : "fail"}')
else
    b39_chk="fail"
fi
_eq B39 "summary Top-端點 rank-1 avg 落在 [1.00,1.10]s" "$b39_chk" "ok"

# B40: --top 0 rank-prefix 寬度唯一 = 1 (no row-10 跑版 with %2d. format)
out40=$(NO_COLOR=1 bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --view summary --top 0 2>/dev/null)
distinct_widths=$(printf '%s\n' "$out40" | grep -oE '^ +[0-9]+\. ' \
    | awk '{print length($0)}' | sort -u | wc -l | tr -d ' ')
_eq B40 "--top 0 rank-prefix 寬度唯一=1（無 跑版）" "$distinct_widths" "1"

# ─────────────────────────────────────────────────────────────────────────────
# Section C — analyze_errors.sh  應用程式錯誤與重啟事件
# Baselines (2026-05-21):
#   taipei  10.22.63.37 : ERROR=0   OracleDB=0  Restart=N/A
#   taipei  10.21.3.35  : ERROR=60  OracleDB=0  Restart=2
#   taipei  10.21.3.36  : ERROR=80  OracleDB=0  Restart=3
#   taichung 10.1.73.37 : ERROR=16  OracleDB=15 Restart=0
#   taichung 10.1.72.35 : ERROR=16  OracleDB=15 Restart=4
#   taichung 10.1.72.36 : ERROR=14  OracleDB=14 Restart=5
# ─────────────────────────────────────────────────────────────────────────────

section "C  analyze_errors.sh — 應用程式錯誤與重啟事件"

# C1: taipei 2026-05-21 基準值
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
_ok  C01 "taipei 2026-05-21 執行成功"  "$rc"
# Total ERROR: 0+60+80=140
sum_err=$(_sum "$out" "Total ERROR entries")
_eq  C02 "taipei Total ERROR entries 合計=140"  "$sum_err"  "140"
# OracleDB: all 0
sum_db=$(_sum "$out" "OracleDB health failures")
_eq  C03 "taipei OracleDB health failures=0"  "$sum_db"  "0"
# Restarts: 2+3=5 (10.22.63.37 has no lifetime log)
sum_restart=$(_sum "$out" "Restart count")
_eq  C04 "taipei Restart count 合計=5"  "$sum_restart"  "5"

# C2: taichung 2026-05-21 — OracleDB 故障
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null); rc=$?
_ok  C05 "taichung 2026-05-21 執行成功"  "$rc"
# OracleDB: 15+15+14=44
sum_db=$(_sum "$out" "OracleDB health failures")
_eq  C06 "taichung OracleDB health failures 合計=44"  "$sum_db"  "44"
# Restarts: 0+4+5=9
sum_restart=$(_sum "$out" "Restart count")
_eq  C07 "taichung Restart count 合計=9"  "$sum_restart"  "9"
# 首次 OracleDB 失敗時間段落應出現
_has C08 "taichung 顯示首次 OracleDB 失敗時間"  "$out" "首次 OracleDB 失敗時間"

# C3: all 2026-05-21 兩區域合併
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null); rc=$?
_ok  C09 "all regions 2026-05-21 執行成功"  "$rc"
_has C10 "all regions 包含台北錯誤分析"   "$out" "台北"
_has C11 "all regions 包含台中錯誤分析"   "$out" "台中"
# Combined OracleDB: 0+44=44
sum_db=$(_sum "$out" "OracleDB health failures")
_eq  C12 "all regions OracleDB failures 合計=44"  "$sum_db"  "44"

# C4: --top 5 自訂 Top N 錯誤排名
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --top 5 2>/dev/null); rc=$?
_ok  C13 "--top 5 執行成功"  "$rc"
_has C14 "--top 5 輸出包含 Top Error Patterns 段落"  "$out" "Top Error Patterns"

# C5: 日期範圍 — 多日累計 Restart 數量 >= 單日
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-25 --region taipei 2>/dev/null); rc=$?
_ok  C15 "taipei --from --to 日期範圍執行成功"  "$rc"
sum_restart=$(_sum "$out" "Restart count")
_gte C16 "台北多日 Restart count >= 5"  "$sum_restart"  "5"

# C6: 未配對 SHUTDOWN 偵測 (多日範圍應出現)
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-25 --region taipei 2>/dev/null)
_has C17 "多日範圍偵測到未配對 SHUTDOWN 記錄"  "$out" "未配對 SHUTDOWN"

# ─────────────────────────────────────────────────────────────────────────────
# Section C (continued) — C18–C21  新增行為回歸
# Baselines:
#   taichung 2026-05-21 : distinct error patterns per run = 5 (all < default 10)
#                         --top 0 pattern rows = 5 (ERROR_AWK 0=ALL fix; pre-fix: 0)
#   taipei week (05-18~25): 10.21.3.35=4 patterns, 10.21.3.36=3 patterns
#                         --top 2 → max per-server = 2 (cap); --top 0 → max = 4
# ─────────────────────────────────────────────────────────────────────────────

# C7: --format tsv 為 no-op，仍輸出文字報告
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --format tsv 2>/dev/null); rc=$?
_ok C18 "--format tsv 執行成功 (非文字格式 no-op，仍輸出文字)" "$rc"

# C8: --top 5 OPT_TOP 重命名後仍正確運作
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --top 5 2>/dev/null)
_has C19 "--top 5 輸出含 Top Error Patterns 區段" "$out" "Top Error Patterns"

# C9: --top 0 顯示所有錯誤模式 (Decision-B 0=ALL 修復，taichung 2026-05-21 = 5 patterns)
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --top 0 2>/dev/null)
pat0=$(printf '%s\n' "$out" | grep -c "^    [0-9]\+  " || true)
_eq C20 "--top 0 顯示所有錯誤模式 (taichung 2026-05-21 = 5 patterns)" "$pat0" "5"

# C10: --top N capping 伴隨測試 (證明 --top 為真正上限，而非與 0=ALL 等價)。
# taipei week 某台伺服器有 4 種模式，--top 2 須將每台上限壓到 2。
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --region taipei --top 2 2>/dev/null)
max_pat2=$(printf '%s\n' "$out" | gawk '
    /Server:/{ if(c>m)m=c; c=0; next }
    /^    [0-9]+  /{ c++ }
    END{ if(c>m)m=c; print m+0 }')
_eq C21 "errors --top 2 每台伺服器模式數上限=2 (capping)" "$max_pat2" "2"

# ─────────────────────────────────────────────────────────────────────────────
# Section C (continued) — C23–C25  interval + persistence + format 新功能
# ─────────────────────────────────────────────────────────────────────────────

# C11: --today 解析為單日期間標頭含 "(1 days)"
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --today --region taipei 2>/dev/null)
_has C23 "--today 單日期間標頭含 '(1 days)'" "$out" "(1 days)"

# C12: 持久化 summary file 含 "Total ERROR" 欄位
TMPD_C24=$(mktemp -d /tmp/lp_c24.XXXXXX)
bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --output-dir "$TMPD_C24" >/dev/null 2>&1
_sum_file=$(ls "$TMPD_C24"/*/errors_summary.txt 2>/dev/null | head -1)
_has C24 "errors_summary file 含 'Total ERROR' 欄位" \
    "$(cat "${_sum_file:-/dev/null}" 2>/dev/null)" "Total ERROR"
rm -rf "$TMPD_C24"

# C13: --format csv 警告後仍正常執行 (exit 0; warn + text)
bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --format csv >/dev/null 2>&1; rc=$?
_ok C25 "--format csv 警告後仍正常執行 (exit 0)" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section D — log_report.sh  整合報告腳本
# ─────────────────────────────────────────────────────────────────────────────

section "D  log_report.sh — 整合報告腳本"

# D1: 所有模組，taipei，單日
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access,iis,errors 2>/dev/null); rc=$?
_ok  D01 "all modules taipei 2026-05-21 執行成功"  "$rc"
_has D02 "整合報告含 Access 段落"   "$out" "關聯總數"
_has D03 "整合報告含 IIS 段落"      "$out" "總請求數"
_has D04 "整合報告含 Errors 段落"   "$out" "Total ERROR"

# D2: --modules access 僅執行 access
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access 2>/dev/null); rc=$?
_ok    D05 "--modules access 執行成功"  "$rc"
_has   D06 "--modules access 輸出含 Access 內容"  "$out" "關聯總數"
_lacks D07 "--modules access 不含 IIS 內容"       "$out" "Total requests"
_lacks D08 "--modules access 不含 Errors 內容"    "$out" "Total ERROR"

# D3: --modules iis,errors
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules iis,errors 2>/dev/null); rc=$?
_ok    D09 "--modules iis,errors 執行成功"  "$rc"
_has   D10 "含 IIS 段落"                    "$out" "總請求數"
_has   D11 "含 Errors 段落"                 "$out" "Total ERROR"
_lacks D12 "不含 Access 段落"               "$out" "Total correlation"

# D4 (rewritten L4): --output FILE 已移除; 改以持久化模式驗證 access 模組輸出
TMPD_D13=$(mktemp -d /tmp/lp_d13.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access --output-dir "$TMPD_D13" >/dev/null 2>&1; rc=$?
_ok D13 "log_report --modules access --output-dir 執行成功 (L4 持久化模式)"  "$rc"
_glob D14 "access_summary.txt 持久化檔案已產生" "${TMPD_D13}/*/access_summary.txt"
# access summary 含 '關聯總數' KPI 標籤 (summary view, format-independent)
_sum_f_d15=$(ls "${TMPD_D13}"/*/access_summary.txt 2>/dev/null | head -1)
_has D15 "access_summary 持久化檔案含 '關聯總數' KPI" \
    "$(cat "${_sum_f_d15:-/dev/null}" 2>/dev/null)" "關聯總數"
rm -rf "$TMPD_D13"

# D5: --output-dir 各模組分別寫入 (access 3 + iis 2 + errors 2 = 7 個)
TMPD=$(mktemp -d /tmp/lp_outdir.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access,iis,errors --output-dir "$TMPD" >/dev/null 2>&1; rc=$?
_ok D16 "--output-dir 執行成功"  "$rc"
file_count=$(find "$TMPD" -type f 2>/dev/null | wc -l | tr -d ' ')
_eq  D17 "--output-dir 產生 7 個報告檔案 (access 3 + iis 2 + errors 2)"  "$file_count"  "7"
# 每個檔案均非空
empty_files=$(find "$TMPD" -type f -empty | wc -l | tr -d ' ')
_eq  D18 "--output-dir 所有檔案均非空白"  "$empty_files"  "0"
rm -rf "$TMPD"

# D6: --region 篩選 taichung (透過 log_report.sh; --view detail 顯示 CJK 區域名)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --modules access --view detail 2>/dev/null); rc=$?
_ok    D19 "--region taichung 執行成功"  "$rc"
_has   D20 "--region taichung 輸出含台中"   "$out" "台中"
_lacks D21 "--region taichung 不含台北"     "$out" "台北"

# ─────────────────────────────────────────────────────────────────────────────
# Section D (continued) — D22–D26  新增轉發行為回歸
# ─────────────────────────────────────────────────────────────────────────────

# D7: --top 3 轉發至 iis (端點上限) 與 errors; --view detail 以呈現 per-server 端點表
# Baseline: all 2026-05-21 --top 3 → max endpoint rows per IIS block = 3
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --top 3 --view detail 2>/dev/null)
maxep=$(printf '%s\n' "$out" | gawk '
/^▶ IIS —/{if(srv!="" && ep_cnt>m) m=ep_cnt; srv=$3; ep_cnt=0; in_ep=0; next}
/Endpoint.*Avg/{in_ep=1; next}
/Client IP/{in_ep=0}
in_ep && /^    \// {ep_cnt++}
END{if(ep_cnt>m) m=ep_cnt; print m+0}
')
_eq D22 "--top 3 轉發 iis：每塊端點列數最多 3" "$maxep" "3"

# D8: --slow-api-ms 轉發至 iis; --view detail 以呈現 per-server Slow 標籤
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --slow-api-ms 1500 --view detail 2>/dev/null)
_has D23 "--slow-api-ms 1500 --view detail 轉發至 iis：顯示 'Slow (>1500ms)'" "$out" "Slow (>1500ms)"

# D9: --format csv 轉發至 access; --view detail 以呈現 csv 標頭行
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --format csv --view detail 2>/dev/null)
_has D24 "--format csv --view detail 轉發 access：輸出含 csv 標頭 REGION,STATUS,API_TIME" "$out" "REGION,STATUS,API_TIME"

# D10: --merge 轉發至 access 和 iis; --view detail 以呈現 merged 區塊標頭
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --merge --view detail 2>/dev/null)
_has D25 "--merge --view detail 轉發：access 含 'Region: all (merged)'" "$out" "Region: all (merged)"

# D11: --format tsv 轉發 iis/errors → no-op，仍正常執行
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --format tsv >/dev/null 2>&1; rc=$?
_ok D26 "--format tsv 轉發至 iis/errors (no-op) 整合報告仍正常執行" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section D (continued) — D27–D35  新預設值/view/errors opt-in/persistence
# 新預設: --modules overview,iis,access (errors opt-in); --view summary
# 固定執行順序: overview → iis → access → errors (無論輸入順序)
# ─────────────────────────────────────────────────────────────────────────────

# Base run shared by D27, D28, D31, D34
_out_default=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)

# D12: 預設模組輸出順序 overview→iis→access (line-order)
# Use "Cross-Correlation" for access (unique to access section header; overview now also
# contains "存取關聯總數" which would match the old "關聯總數" pattern prematurely).
_line_ovw=$(printf '%s\n' "$_out_default" | grep -n "總體概況" | head -1 | cut -d: -f1)
_line_iis=$(printf '%s\n' "$_out_default" | grep -n "總請求數"  | head -1 | cut -d: -f1)
_line_acc=$(printf '%s\n' "$_out_default" | grep -n "Cross-Correlation"  | head -1 | cut -d: -f1)
if [[ -n "${_line_ovw:-}" && -n "${_line_iis:-}" && -n "${_line_acc:-}" ]] && \
   (( _line_ovw < _line_iis )) && (( _line_iis < _line_acc )); then
    _pass "D27  預設模組輸出順序 overview→iis→access (line-order)"
else
    _fail "D27  預設模組輸出順序 overview→iis→access [ovw=${_line_ovw:-?} iis=${_line_iis:-?} acc=${_line_acc:-?}]"
fi

# D13: errors 預設不含 (errors opt-in)
_lacks D28 "預設不含 errors 模組 ('Total ERROR entries' 不出現)" \
    "$_out_default" "Total ERROR entries"

# D14: --modules overview,iis,access,errors 含 errors
_out29=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules overview,iis,access,errors 2>/dev/null); rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$_out29" | grep -qF "Total ERROR entries" 2>/dev/null; then
    _pass "D29  --modules overview,iis,access,errors 含 errors 模組"
else
    _fail "D29  --modules overview,iis,access,errors 含 errors 模組 [rc=$rc]"
fi

# D15: --view detail 轉發至 iis 顯示 per-server 表格
_out30=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view detail 2>/dev/null)
_has D30 "--view detail 轉發 iis：含 per-server 'Total requests' 表格" \
    "$_out30" "Total requests"

# D16: 預設 --view summary 含 '總請求數' 且無 per-server 'Total requests'
if printf '%s\n' "$_out_default" | grep -qF "總請求數" 2>/dev/null && \
   ! printf '%s\n' "$_out_default" | grep -qF "Total requests" 2>/dev/null; then
    _pass "D31  預設 --view summary：含 '總請求數' 且無 per-server 'Total requests'"
else
    _fail "D31  預設 --view summary：含 '總請求數' 且無 per-server 'Total requests'"
fi

# D17: 未知模組應 die
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --modules overview,bogus >/dev/null 2>&1; rc=$?
_err D32 "--modules bogus 未知模組應 die (非零 exit)" "$rc"

# D18: 所有模組持久化檔案共享同一 RUN_TS
TMPD_D33=$(mktemp -d /tmp/lp_d33.XXXXXX)
LOG_PARSE_RUN_TS="20260521_133300" bash "$REPORT" --log-dir "$LOG_DIR" \
    --date 2026-05-21 --output-dir "$TMPD_D33" >/dev/null 2>&1
_ts_uniq=$(ls "$TMPD_D33" 2>/dev/null | grep -oE '[0-9]{8}_[0-9]{6}' | sort -u | wc -l | tr -d ' ')
_eq D33 "所有模組持久化檔案共享同一 RUN_TS (20260521_133300)" "$_ts_uniq" "1"
rm -rf "$TMPD_D33"

# D19: overview 出現在整合報告中且排在 iis 之前
_line_ovw2=$(printf '%s\n' "$_out_default" | grep -n "總體概況" | head -1 | cut -d: -f1)
_line_iis2=$(printf '%s\n' "$_out_default" | grep -n "總請求數"  | head -1 | cut -d: -f1)
if [[ -n "${_line_ovw2:-}" && -n "${_line_iis2:-}" ]] && (( _line_ovw2 < _line_iis2 )); then
    _pass "D34  整合報告含 overview 且出現在 iis 之前 (first module)"
else
    _fail "D34  整合報告含 overview 且出現在 iis 之前 [ovw=${_line_ovw2:-?} iis=${_line_iis2:-?}]"
fi

# D20: 各模組持久化配對均已建立 (overview+iis+access)
TMPD_D35=$(mktemp -d /tmp/lp_d35.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_D35" >/dev/null 2>&1
if [[ -f "${TMPD_D35}/*/overview_summary.txt" ]] 2>/dev/null || \
   ls "${TMPD_D35}"/*/overview_summary.txt > /dev/null 2>&1; then
    _ovw_ok=1; else _ovw_ok=0; fi
if ls "${TMPD_D35}"/*/iis_summary.txt      > /dev/null 2>&1; then _iis_s_ok=1; else _iis_s_ok=0; fi
if ls "${TMPD_D35}"/*/iis_detail.txt       > /dev/null 2>&1; then _iis_d_ok=1; else _iis_d_ok=0; fi
if ls "${TMPD_D35}"/*/access_summary.txt   > /dev/null 2>&1; then _acc_s_ok=1; else _acc_s_ok=0; fi
if ls "${TMPD_D35}"/*/access_detail.txt    > /dev/null 2>&1; then _acc_d_ok=1; else _acc_d_ok=0; fi
if [[ "$_ovw_ok$_iis_s_ok$_iis_d_ok$_acc_s_ok$_acc_d_ok" == "11111" ]]; then
    _pass "D35  各模組持久化配對均已建立 (overview+iis+access)"
else
    _fail "D35  各模組持久化配對均已建立 (overview+iis+access)"
fi
rm -rf "$TMPD_D35"

# ─────────────────────────────────────────────────────────────────────────────
# Section E — 輸入驗證與錯誤處理
# ─────────────────────────────────────────────────────────────────────────────

section "E  輸入驗證與錯誤處理"

# E1: 遺漏必要參數 --log-dir
bash "$ACCESS" --date 2026-05-21 >/dev/null 2>&1; rc=$?
_err E01 "analyze_access.sh 遺漏 --log-dir 返回非零 exit code"  "$rc"

bash "$IIS" --date 2026-05-21 >/dev/null 2>&1; rc=$?
_err E02 "analyze_iis.sh 遺漏 --log-dir 返回非零 exit code"  "$rc"

bash "$ERRORS" --date 2026-05-21 >/dev/null 2>&1; rc=$?
_err E03 "analyze_errors.sh 遺漏 --log-dir 返回非零 exit code"  "$rc"

bash "$REPORT" --date 2026-05-21 >/dev/null 2>&1; rc=$?
_err E04 "log_report.sh 遺漏 --log-dir 返回非零 exit code"  "$rc"

# E2: 無效的 --log-dir 路徑
bash "$ACCESS" --log-dir /nonexistent/path >/dev/null 2>&1; rc=$?
_err E05 "無效 --log-dir 路徑返回非零 exit code"  "$rc"

# E3: log_report.sh 未知模組名稱
bash "$REPORT" --log-dir "$LOG_DIR" --modules unknown_module >/dev/null 2>&1; rc=$?
_err E06 "log_report.sh 未知模組返回非零 exit code"  "$rc"

# E4: --help 顯示說明並正常退出
bash "$ACCESS"  --help >/dev/null 2>&1; rc=$?; _ok E07 "analyze_access.sh  --help exit 0"  "$rc"
bash "$IIS"     --help >/dev/null 2>&1; rc=$?; _ok E08 "analyze_iis.sh     --help exit 0"  "$rc"
bash "$ERRORS"  --help >/dev/null 2>&1; rc=$?; _ok E09 "analyze_errors.sh  --help exit 0"  "$rc"
bash "$REPORT"  --help >/dev/null 2>&1; rc=$?; _ok E10 "log_report.sh      --help exit 0"  "$rc"

# E5: --verbose 旗標不崩潰 (stderr 含 DEBUG 輸出)
err=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --verbose >/dev/null 2>&1); rc=$?
_ok E11 "analyze_access.sh --verbose 不崩潰"  "$rc"

bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --verbose >/dev/null 2>&1; rc=$?
_ok E12 "analyze_errors.sh --verbose 不崩潰"  "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section E (continued) — E13–E18  新增驗證路徑
# ─────────────────────────────────────────────────────────────────────────────

# E6: access --merge --region taipei -> die (--merge requires --region all)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --merge --region taipei >/dev/null 2>&1; rc=$?
_err E13 "access --merge --region taipei 應返回非零 exit (--merge requires --region all)" "$rc"

# E7: access --format 無效值 -> die
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --format zzz >/dev/null 2>&1; rc=$?
_err E14 "access --format zzz 應返回非零 exit" "$rc"

# E8: iis --top 負數 -> die
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --top -1 >/dev/null 2>&1; rc=$?
_err E15 "iis --top -1 應返回非零 exit" "$rc"

# E9: iis --slow-api-ms 非整數 -> die
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --slow-api-ms abc >/dev/null 2>&1; rc=$?
_err E16 "iis --slow-api-ms abc 應返回非零 exit" "$rc"

# E10: iis --slow-ms (已移除旗標) -> Unknown option -> die
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --slow-ms 1 >/dev/null 2>&1; rc=$?
_err E17 "iis --slow-ms 1 (已移除) 應返回非零 exit" "$rc"

# E11: log_report --format 無效值 -> die
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --format bogus >/dev/null 2>&1; rc=$?
_err E18 "log_report --format bogus 應返回非零 exit" "$rc"

# E12: iis --format 無效值 -> die (assert_enum)
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --format bogus >/dev/null 2>&1; rc=$?
_err E24 "iis --format bogus 應返回非零 exit" "$rc"

# E13: analyze_overview 拒絕未知旗標 -> die (非零 exit)
bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --view summary >/dev/null 2>&1; rc=$?
_err E25 "overview --view summary 應返回非零 exit (拒絕 --view)" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section E (continued) — E19–E23, E26  interval mutex + view/module 驗證 (D3)
# ─────────────────────────────────────────────────────────────────────────────

# E14: --today + --date 同時指定 → die (D3 mutex)
bash "$REPORT" --log-dir "$LOG_DIR" --today --date 2026-05-21 >/dev/null 2>&1; rc=$?
_err E19 "--today + --date 同時指定應 die (D3 mutex)" "$rc"

# E15: --date + explicit --days 同時指定 → die (D3 mutex)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --days 3 >/dev/null 2>&1; rc=$?
_err E20 "--date + explicit --days 同時指定應 die (D3 mutex)" "$rc"

# E16: --from 缺 --to → die
bash "$REPORT" --log-dir "$LOG_DIR" --from 2026-05-21 >/dev/null 2>&1; rc=$?
_err E21 "--from 缺 --to 應 die" "$rc"

# E17: --from/--to + --today → die (D3 mutex)
bash "$REPORT" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-25 --today >/dev/null 2>&1; rc=$?
_err E22 "--from/--to + --today 同時指定應 die (D3 mutex)" "$rc"

# E18: log_report --view bogus → die (assert_enum --view)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --view bogus >/dev/null 2>&1; rc=$?
_err E23 "log_report --view bogus 應 die (assert_enum)" "$rc"

# E19: log_report --modules foo → die (unknown module)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --modules foo >/dev/null 2>&1; rc=$?
_err E26 "log_report --modules foo 未知模組應 die" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section E (continued) — E27–E37  --notify validation paths (D12)
# All offline, and ALL die in parse_args before persist_init ever runs (FIX F:
# receivers.conf CONTENT + LOG_PARSE_NOTIFY_FROM_ADDR validation moved there
# too, alongside notify_assert_url/notify_preflight, so a config typo now
# surfaces before any analysis module runs -- matching docs/usage.md's
# exit-code table. Previously E31-E35/E37 died only inside notify_send's
# load_receivers/From-address checks, after a full bundled-dataset analysis
# pass; E38 below proves the "zero subdirectories" half of the new timing
# directly, mirroring E36's existing dependency-gate idiom). None resolves a
# real curl except E36, which proves the opposite (dependency gate fires
# first).
# ─────────────────────────────────────────────────────────────────────────────

# E27: --notify --notify-attach bogus → assert_enum message naming --notify-attach
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --notify --notify-attach bogus 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF -- "--notify-attach must be one of:"; then
    _pass "E27  --notify --notify-attach bogus 應 die (assert_enum 訊息含 --notify-attach)"
else
    _fail "E27  --notify --notify-attach bogus 應 die [rc=$rc]"
fi

# E28: --notify-attach summary without --notify → "...require --notify"
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --notify-attach summary 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF "require --notify"; then
    _pass "E28  --notify-attach summary 缺少 --notify 應 die (…require --notify)"
else
    _fail "E28  --notify-attach summary 缺少 --notify 應 die [rc=$rc]"
fi

# E29: --notify --notify-dry-run --notify-url ftp://x/y → URL validated even in dry-run
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --notify --notify-dry-run --notify-url ftp://x/y 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF "unsupported endpoint URL: ftp://x/y"; then
    _pass "E29  --notify-url ftp://x/y 應 die (URL 於 dry-run 亦驗證)"
else
    _fail "E29  --notify-url ftp://x/y 應 die [rc=$rc]"
fi

# E30: --notify --receivers-conf /nonexistent/receivers.conf → "conf file not found:"
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --notify --receivers-conf /nonexistent/receivers.conf 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | \
   grep -qF "conf file not found: /nonexistent/receivers.conf"; then
    _pass "E30  --receivers-conf 指向不存在檔案應 die"
else
    _fail "E30  --receivers-conf 指向不存在檔案應 die [rc=$rc]"
fi

# ---- Shared malformed-receivers.conf fixtures for E31-E34, E37 -------------
TMPD_ECONF=$(mktemp -d /tmp/lp_econf.XXXXXX)

# E31: receivers.conf containing only comments/blank lines → "no recipient defined"
printf '# comment\n\n   \n' > "${TMPD_ECONF}/e31.conf"
TMPD_E31=$(mktemp -d /tmp/lp_e31.XXXXXX)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E31" \
    --notify --notify-dry-run --receivers-conf "${TMPD_ECONF}/e31.conf" 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF "receivers.conf: no recipient defined"; then
    _pass "E31  receivers.conf 僅含註解/空白行應 die (no recipient defined)"
else
    _fail "E31  receivers.conf 僅含註解/空白行應 die [rc=$rc]"
fi
rm -rf "$TMPD_E31"

# E32: a 3-field row → "expected 2 pipe-separated fields ..., got 3", names the line
printf 'A|B|C\n' > "${TMPD_ECONF}/e32.conf"
TMPD_E32=$(mktemp -d /tmp/lp_e32.XXXXXX)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E32" \
    --notify --notify-dry-run --receivers-conf "${TMPD_ECONF}/e32.conf" 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | \
   grep -qF "receivers.conf:1: expected 2 pipe-separated fields (DISPLAY_NAME|ADDRESS), got 3"; then
    _pass "E32  receivers.conf 3 欄位應 die (含行號)"
else
    _fail "E32  receivers.conf 3 欄位應 die [rc=$rc]"
fi
rm -rf "$TMPD_E32"

# E33: address 'jason.chao@' (no TLD) → "invalid address"
printf 'Jason|jason.chao@\n' > "${TMPD_ECONF}/e33.conf"
TMPD_E33=$(mktemp -d /tmp/lp_e33.XXXXXX)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E33" \
    --notify --notify-dry-run --receivers-conf "${TMPD_ECONF}/e33.conf" 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF "invalid address"; then
    _pass "E33  receivers.conf 無效 address 應 die"
else
    _fail "E33  receivers.conf 無效 address 應 die [rc=$rc]"
fi
rm -rf "$TMPD_E33"

# E34: display name 'Bad"Name' → "display name contains"
printf 'Bad"Name|jason.chao@cohesiondata.com\n' > "${TMPD_ECONF}/e34.conf"
TMPD_E34=$(mktemp -d /tmp/lp_e34.XXXXXX)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E34" \
    --notify --notify-dry-run --receivers-conf "${TMPD_ECONF}/e34.conf" 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -qF "display name contains"; then
    _pass "E34  receivers.conf 無效 display name 應 die"
else
    _fail "E34  receivers.conf 無效 display name 應 die [rc=$rc]"
fi
rm -rf "$TMPD_E34"

# E35: LOG_PARSE_NOTIFY_FROM_ADDR=not-an-address with --notify → validated From address
TMPD_E35=$(mktemp -d /tmp/lp_e35.XXXXXX)
out=$(LOG_PARSE_NOTIFY_FROM_ADDR='not-an-address' bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E35" \
    --notify --notify-dry-run 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | \
   grep -qF "LOG_PARSE_NOTIFY_FROM_ADDR is not a valid address: not-an-address"; then
    _pass "E35  LOG_PARSE_NOTIFY_FROM_ADDR 無效應 die"
else
    _fail "E35  LOG_PARSE_NOTIFY_FROM_ADDR 無效應 die [rc=$rc]"
fi
rm -rf "$TMPD_E35"

# E36: --notify with curl missing → 3-line dependency-gate message; run aborts
# BEFORE any module executes (no RUN_OUTPUT_DIR subdirectory ever created)
TMPD_E36=$(mktemp -d /tmp/lp_e36.XXXXXX)
out=$(LOG_PARSE_NOTIFY_CURL_BIN=curl-does-not-exist bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E36" \
    --notify 2>&1 >/dev/null); rc=$?
e36_subdirs=$(find "$TMPD_E36" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc" -ne 0 ]] \
   && printf '%s\n' "$out" | grep -qF "needs the optional dependency 'curl'" \
   && printf '%s\n' "$out" | grep -qF "missing required commands: curl" \
   && [[ "$e36_subdirs" -eq 0 ]]; then
    _pass "E36  curl 缺失應 die (3 行訊息) 且未建立任何 run 目錄 (before any module)"
else
    _fail "E36  curl 缺失應 die 且未建立任何 run 目錄 [rc=$rc subdirs=$e36_subdirs]"
fi
rm -rf "$TMPD_E36"

# E37: same address twice, differing case → "duplicate address", naming both lines
printf 'Jason|Jason.Chao@Cohesiondata.com\nBob|jason.chao@cohesiondata.com\n' > "${TMPD_ECONF}/e37.conf"
TMPD_E37=$(mktemp -d /tmp/lp_e37.XXXXXX)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E37" \
    --notify --notify-dry-run --receivers-conf "${TMPD_ECONF}/e37.conf" 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | \
   grep -qF "receivers.conf:2: duplicate address 'jason.chao@cohesiondata.com' (first seen on line 1)"; then
    _pass "E37  receivers.conf 重複 address (大小寫不同) 應 die (含兩行行號)"
else
    _fail "E37  receivers.conf 重複 address 應 die [rc=$rc]"
fi
rm -rf "$TMPD_E37" "$TMPD_ECONF"

# E38: FIX F regression -- receivers.conf CONTENT validation (not merely its
# existence, already covered by E30) now happens in parse_args, BEFORE
# persist_init ever runs: zero subdirectories are created under
# --output-dir, exactly like E36's curl-dependency-gate proof. Previously
# this died only after a full (fast, bundled-dataset) analysis pass, inside
# notify_send's load_receivers call.
TMPD_E38=$(mktemp -d /tmp/lp_e38.XXXXXX)
printf '# comment only, no recipient rows\n' > "${TMPD_E38}/bad.conf"
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_E38" \
    --notify --notify-dry-run --receivers-conf "${TMPD_E38}/bad.conf" 2>&1 >/dev/null); rc=$?
e38_subdirs=$(find "$TMPD_E38" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc" -ne 0 ]] \
   && printf '%s\n' "$out" | grep -qF "receivers.conf: no recipient defined" \
   && [[ "$e38_subdirs" -eq 0 ]]; then
    _pass "E38  FIX F：無效 receivers.conf 於 parse_args 即 die，未建立任何 run 目錄 (before any module)"
else
    _fail "E38  FIX F 提前失敗檢查失敗 [rc=$rc subdirs=$e38_subdirs]"
fi
rm -rf "$TMPD_E38"

# ─────────────────────────────────────────────────────────────────────────────
# Section F — 使用情境模擬 (User Scenario Smoke Tests)
# 模擬真實使用者日常操作，只驗證執行成功且輸出非空白
# ─────────────────────────────────────────────────────────────────────────────

section "F  使用情境模擬 — 日常應用場景驗證"

# F1: 情境 — 指定日期完整報告 (運維人員每日例行)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null); rc=$?
_ok  F01 "[情境-每日例行] 完整報告 --date 2026-05-21 執行成功"  "$rc"
_gte F02 "[情境-每日例行] 報告非空白 (行數 >= 50)"  \
    "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"  "50"

# F2: 情境 — 僅查詢台北異常 (資安事件初步調查)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region taipei 2>/dev/null); rc=$?
_ok  F03 "[情境-資安調查] taipei access 分析成功"  "$rc"
_has F04 "[情境-資安調查] 輸出含 ORPHAN 警告區段"  "$out" "ORPHAN"

# F3: 情境 — 台中 OracleDB 故障排查 (DBA 指令)
out=$(bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region taichung --top 3 2>/dev/null); rc=$?
_ok  F05 "[情境-DB故障排查] taichung errors --top 3 成功"  "$rc"
_has F06 "[情境-DB故障排查] 偵測到 OracleDB 失敗記錄"  "$out" "OracleDB"

# F4: 情境 — 週報產出至目錄 (定期報告自動化; 各模組 summary+detail = 6 個)
TMPD=$(mktemp -d /tmp/lp_weekly.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --from 2026-05-19 --to 2026-05-25 \
    --modules access,iis,errors --output-dir "$TMPD" >/dev/null 2>&1; rc=$?
_ok  F07 "[情境-週報] --from --to 全模組 --output-dir 執行成功"  "$rc"
file_count=$(find "$TMPD" -type f 2>/dev/null | wc -l | tr -d ' ')
_eq  F08 "[情境-週報] 產生 7 個週報檔案 (access 3 + iis 2 + errors 2)"  "$file_count"  "7"
rm -rf "$TMPD"

# F5: 情境 — IIS 效能稽核，自訂慢請求門檻 (效能工程師，--slow-ms 已分為 --slow-api-ms/--slow-app-ms)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region all --slow-api-ms 3000 --slow-app-ms 3000 2>/dev/null); rc=$?
_ok  F09 "[情境-效能稽核] IIS all regions --slow-api-ms/--slow-app-ms 3000 成功"  "$rc"
_has F10 "[情境-效能稽核] 輸出包含 Slow 門檻資訊"  "$out" "Slow (>3000ms)"

# F6: 情境 — 單一模組單一日期輸出至標準輸出後管線處理
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region taichung --modules errors 2>/dev/null)
oracle_count=$(_sum "$out" "OracleDB health failures")
_gte F11 "[情境-管線處理] 可從 log_report 輸出擷取 OracleDB count >= 44"  \
    "$oracle_count"  "44"

# ─────────────────────────────────────────────────────────────────────────────
# Section F (continued) — F12–F13  新增使用情境
# ─────────────────────────────────────────────────────────────────────────────

# F7: 情境 — 合併週報 (運維人員跨區域整合視角)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 \
    --merge --top 5 --format text 2>/dev/null); rc=$?
_ok F12 "[情境-合併週報] log_report --merge --top 5 --format text 執行成功" "$rc"

# F8: 情境 — IIS 按角色區分慢請求門檻 (效能工程師確認 API/APP 門檻已分離)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null)
if printf '%s\n' "$out" | grep -qF "Slow (>2000ms)" 2>/dev/null && \
   printf '%s\n' "$out" | grep -qF "Slow (>5000ms)" 2>/dev/null; then
    _pass "F13  [情境-效能稽核] iis 預設門檻 API(>2000ms) AND APP(>5000ms) 均存在"
else
    _fail "F13  [情境-效能稽核] iis 預設門檻 API(>2000ms) AND APP(>5000ms) 均存在"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section F (continued) — F14–F18  新增使用情境
# ─────────────────────────────────────────────────────────────────────────────

# F9: 情境 — overview 獨立執行顯示三個切面 (總體概況/分區別/核心功能效能)
out_f14=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null); rc_f14=$?
if [[ "$rc_f14" -eq 0 ]] && \
   printf '%s\n' "$out_f14" | grep -qF "總體概況" && \
   printf '%s\n' "$out_f14" | grep -qF "分區別" && \
   printf '%s\n' "$out_f14" | grep -qF "核心功能效能"; then
    _pass "F14  [情境-overview獨立] 三切面 (總體概況/分區別/核心功能效能) 均存在"
else
    _fail "F14  [情境-overview獨立] 三切面 (總體概況/分區別/核心功能效能) 均存在 [rc=$rc_f14]"
fi

# F10: 情境 — log_report 預設模組產生 6 個持久化檔案且無 .plain 殘留 (C4)
TMPD_F15=$(mktemp -d /tmp/lp_f15.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_F15" >/dev/null 2>&1; rc_f15=$?
_f15_cnt=$(find "$TMPD_F15" -type f 2>/dev/null | wc -l | tr -d ' ')
_f15_plain=$(find "$TMPD_F15" -type f -name "*.plain" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc_f15" -eq 0 && "$_f15_cnt" -eq 6 && "$_f15_plain" -eq 0 ]]; then
    _pass "F15  [情境-週報] 預設模組產生恰好 6 個持久化檔案 (無 .plain 殘留 C4)"
else
    _fail "F15  [情境-週報] 預設模組產生恰好 6 個持久化檔案 (無 .plain 殘留 C4) [rc=$rc_f15 files=$_f15_cnt plain=$_f15_plain]"
fi
rm -rf "$TMPD_F15"

# F11: 情境 — access --view detail --format csv 記錄匯出 + 持久化 csv 檔
TMPD_F16=$(mktemp -d /tmp/lp_f16.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view detail --format csv --output-dir "$TMPD_F16" >/dev/null 2>&1; rc_f16=$?
if [[ "$rc_f16" -eq 0 ]] && ls "${TMPD_F16}"/*/access_detail.csv > /dev/null 2>&1; then
    _pass "F16  [情境-記錄匯出] access --view detail --format csv 成功且持久化 csv 存在"
else
    _fail "F16  [情境-記錄匯出] access --view detail --format csv 成功且持久化 csv 存在 [rc=$rc_f16]"
fi
rm -rf "$TMPD_F16"

# F12: 情境 — 週報含錯誤稽核 (全模組) 產生 8 個持久化檔案
TMPD_F17=$(mktemp -d /tmp/lp_f17.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 \
    --modules overview,iis,access,errors \
    --output-dir "$TMPD_F17" >/dev/null 2>&1; rc_f17=$?
_f17_cnt=$(find "$TMPD_F17" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc_f17" -eq 0 && "$_f17_cnt" -eq 8 ]]; then
    _pass "F17  [情境-週報稽核] 全模組週報產生 8 個持久化檔案"
else
    _fail "F17  [情境-週報稽核] 全模組週報產生 8 個持久化檔案 [rc=$rc_f17 files=$_f17_cnt]"
fi
rm -rf "$TMPD_F17"

# F13: 情境 — log_report --today 快速單日回報
bash "$REPORT" --log-dir "$LOG_DIR" --today >/dev/null 2>&1; rc_f18=$?
_ok F18 "[情境-今日] log_report --today 執行成功 (exit 0)" "$rc_f18"

# ─────────────────────────────────────────────────────────────────────────────
# Section G — CJK display-width alignment (wcwidth)
# Verifies that KV blocks and stat blocks pad CJK labels by display width,
# not byte count, so value columns align vertically in the terminal.
#
# Uses the PRODUCTION FMT_AWK_WIDTH engine sourced from lib/fmt_utils.sh
# (single source of truth — do NOT re-implement wcwidth here).
#
# Date constraint for C22: --date 2026-05-25 --region taipei has
# Restart count=0; only UNMATCHED rows exist.  Their Downtime col is the
# single-token "?".  RESTART rows' "Xm Ys" Downtime is multi-token and
# would break the strip-last-token logic in _aligncols.
# ─────────────────────────────────────────────────────────────────────────────

section "G  CJK display-width alignment (wcwidth)"

# shellcheck source=/dev/null
source "${PROJECT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_DIR}/lib/fmt_utils.sh"

# _aligncols — pipe line(s) through this to count DISTINCT value-start columns.
# Strips the trailing value token (final run of non-space) from each line,
# KEEPING the pad spaces, then measures dwidth of the remaining prefix under
# LC_ALL=C.  An aligned block produces exactly one distinct width => prints "1".
_aligncols() {
    LC_ALL=C gawk "$FMT_AWK_WIDTH"'
        { line = $0; sub(/[^ \t]+[ \t]*$/, "", line); seen[dwidth(line)] = 1 }
        END { print length(seen) }
    '
}

# A35: access 摘要 KV 區塊數值欄對齊
# Baseline: taipei 2026-05-21 Total=3 NORMAL=0 ORPHAN=3 UNVERIFIED=0 -> 4 KV rows.
# The grep pattern also matches the h3 header lines "■ 正常流程 (NORMAL)…" and
# "■ 非正常流程 (ORPHAN)…"; exclude them with | grep -v '■' (critique fix HIGH).
out=$(NO_COLOR=1 bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei)
block=$(printf '%s\n' "$out" | grep -E 'correlation records|正常流程|無對應API|API未被使用' \
    | grep -v '■')
_eq A35 "access 摘要 KV 區塊數值欄對齊 (display-col 一致)" \
    "$(printf '%s' "$block" | _aligncols)" "1"

# A36: access delta-stats 區塊數值欄對齊
# Baseline: taichung 2026-05-21 has 6 NORMAL records -> delta-stats block renders (4 rows).
# (taipei 0521 NORMAL=0 under exclude; switch to taichung for non-vacuous alignment test.)
out36=$(NO_COLOR=1 bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung)
block=$(printf '%s\n' "$out36" | grep -E '驗證筆數|平均 API|最短時間差|最長時間差')
_eq A36 "access delta-stats 區塊數值欄對齊 (display-col 一致)" \
    "$(printf '%s' "$block" | _aligncols)" "1"

# ─────────────────────────────────────────────────────────────────────────────
# Section A (continued) — A37–A41  --view summary/detail 新功能 + --today 回歸
# Baselines (fixed dates):
#   taipei 2026-05-21: Total=6  NORMAL=1  ORPHAN=5  UNVERIFIED=0
#   --view detail --format csv: 1 header + 6 data = 7 rows
# ─────────────────────────────────────────────────────────────────────────────

# A17: --view summary 含 NORMAL 標籤與百分比
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view summary 2>/dev/null)
_hasre A37 "access --view summary 含 NORMAL 標籤與百分比 (%)" "$out" "NORMAL.*%"

# A18: --view detail text 含 NORMAL 段落標頭 (使用 taichung: NORMAL=6 > 0)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --view detail 2>/dev/null)
_has A38 "access --view detail 含 NORMAL 段落標頭 (輸出與基準線一致)" "$out" "正常流程 (NORMAL)"

# A19: --view detail --format csv 列數 == 既有 csv 基準線 (taipei 2026-05-21 = 4)
# 1 header row + 3 data records (0 NORMAL + 3 ORPHAN + 0 UNVERIFIED; --test-hosts exclude)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view detail --format csv 2>/dev/null)
csv_rows=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
_eq A39 "access --view detail --format csv 列數=4 (1 header+3 records)" "$csv_rows" "4"

# A20: --view summary 不含 per-record PATIENT_ID_AES (管理摘要應省略個別記錄欄位)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view summary 2>/dev/null)
_lacks A40 "access --view summary 不含 per-record PATIENT_ID_AES" "$out" "PATIENT_ID_AES"

# A21: --today 單日期間標頭含 '(1 days)'
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --today --region taipei \
    --view summary 2>/dev/null)
_has A41 "access --today 單日期間標頭含 '(1 days)'" "$out" "(1 days)"

# ─────────────────────────────────────────────────────────────────────────────
# Section A (continued) — A42–A44  access_ip_counts.tsv 持久化 + 隔離
# Baselines: --date 2026-05-21 --region all (all ground truth pinned from spec):
#   --test-hosts all  -> 2 data rows: '-' 9  then  192.168.139.110 3 (sort count desc/IP asc)
#   --test-hosts exclude (default) -> 1 data row: '-' 9
#   column sum (NORMAL+ORPHAN) = 12 under --test-hosts all
# ─────────────────────────────────────────────────────────────────────────────

# A42: access --test-hosts all 持久化 access_ip_counts.tsv 含 192.168.139.110 = 3
TMPD_A42=$(mktemp -d /tmp/lp_a42.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --test-hosts all --output-dir "$TMPD_A42" >/dev/null 2>&1
_a42_file=$(ls "$TMPD_A42"/*/access_ip_counts.tsv 2>/dev/null | head -1)
if [[ -z "$_a42_file" ]]; then
    _fail "A42  access_ip_counts.tsv 不存在"
else
    _a42_hdr=$(head -1 "$_a42_file")
    _a42_ip=$(gawk -F'\t' '$1=="192.168.139.110"{print $2; exit}' "$_a42_file")
    _a42_sum=$(gawk -F'\t' 'NR>1{s+=$2} END{print s+0}' "$_a42_file")
    _a42_first=$(sed -n '2p' "$_a42_file" | cut -f1)
    if [[ "$_a42_hdr" == "CLIENT_IP	REQUEST_COUNT" && \
          "$_a42_ip" == "3" && \
          "$_a42_sum" == "12" && \
          "$_a42_first" == "-" ]]; then
        _pass "A42  access_ip_counts.tsv: 標頭 + 192.168.139.110=3 + sum=12 + 首行='-'"
    else
        _fail "A42  access_ip_counts.tsv: 標頭/IP/sum/首行不符 [hdr=$_a42_hdr ip=$_a42_ip sum=$_a42_sum first=$_a42_first]"
    fi
fi
rm -rf "$TMPD_A42"

# A43: empty corpus (2026-05-20 無存取 CSV) → access_ip_counts.tsv 僅含標頭 (1 行, 0 data rows)
TMPD_A43=$(mktemp -d /tmp/lp_a43.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-20 --region all \
    --output-dir "$TMPD_A43" >/dev/null 2>&1
_a43_file=$(ls "$TMPD_A43"/*/access_ip_counts.tsv 2>/dev/null | head -1)
if [[ -z "$_a43_file" ]]; then
    _fail "A43  access_ip_counts.tsv 不存在 (空語料庫日期)"
else
    _a43_lines=$(wc -l < "$_a43_file" | tr -d ' ')
    if [[ "$_a43_lines" -eq 1 ]]; then
        _pass "A43  空語料庫 access_ip_counts.tsv 僅含 1 行標頭 (0 data rows)"
    else
        _fail "A43  空語料庫 access_ip_counts.tsv 行數應為 1，得 $_a43_lines"
    fi
fi
rm -rf "$TMPD_A43"

# A44: (a) stdout 不含 REQUEST_COUNT; (b) --emit-stats 無子目錄且無 access_ip_counts.tsv
TMPD_A44=$(mktemp -d /tmp/lp_a44.XXXXXX)
_a44_stdout=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --test-hosts all --output-dir "$TMPD_A44" 2>/dev/null)
_a44_no_rc=$(printf '%s\n' "$_a44_stdout" | grep -cF "REQUEST_COUNT" 2>/dev/null || true)
rm -rf "$TMPD_A44"
TMPD_A44b=$(mktemp -d /tmp/lp_a44b.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --emit-stats --output-dir "$TMPD_A44b" >/dev/null 2>&1
_a44_emit_cnt=$(find "$TMPD_A44b" -type f 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$TMPD_A44b"
if [[ "$_a44_no_rc" -eq 0 && "$_a44_emit_cnt" -eq 0 ]]; then
    _pass "A44  stdout 不含 REQUEST_COUNT; --emit-stats 無持久化檔案"
else
    _fail "A44  stdout 不含 REQUEST_COUNT; --emit-stats 無持久化檔案 [rc_in_stdout=$_a44_no_rc emit_files=$_a44_emit_cnt]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section A (continued) — A45–A52  BIRTHDAY (JWT dob) 附加欄位
# Baselines: --date 2026-05-21 --region all (default --test-hosts exclude, 9 records):
#   taichung NORMAL PATIENT_ID_AES B67EDA...->19700404 (x3), EBD71A...->19410712 (x3)
#   taipei   ORPHAN PATIENT_ID_AES 2EDEBACB...->19560711 (x3)
#   BIRTHDAY is the trailing column: tsv/csv field 14 ($13 after REGION strip);
#   text tables append it after PATIENT_ID_AES (now fixed %-32s for a stable start col).
# ─────────────────────────────────────────────────────────────────────────────

# shellcheck source=/dev/null
source "${PROJECT_DIR}/lib/csv_utils.sh"

# A45: --format tsv header 附加 BIRTHDAY (NF=14, $14=BIRTHDAY)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --format tsv 2>/dev/null)
_a45_hdr=$(printf '%s\n' "$out" | head -1)
_a45_nf=$(printf '%s\n' "$_a45_hdr" | gawk -F'\t' '{print NF}')
_a45_f14=$(printf '%s\n' "$_a45_hdr" | gawk -F'\t' '{print $14}')
if [[ "$_a45_nf" == "14" && "$_a45_f14" == "BIRTHDAY" ]]; then
    _pass "A45  access --format tsv header NF=14 且 \$14=BIRTHDAY"
else
    _fail "A45  access --format tsv header 不符 [nf=$_a45_nf f14=$_a45_f14]"
fi

# A46: tsv NORMAL BIRTHDAY 值 — taichung B67EDA...=19700404, EBD71A...=19410712
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung --format tsv 2>/dev/null)
_a46_b67=$(printf '%s\n' "$out" | gawk -F'\t' '$13=="B67EDA342C22CD73F88571E0E54CFE81"{print $14; exit}')
_a46_ebd=$(printf '%s\n' "$out" | gawk -F'\t' '$13=="EBD71A864A0F7E6A355827754B89259E"{print $14; exit}')
if [[ "$_a46_b67" == "19700404" && "$_a46_ebd" == "19410712" ]]; then
    _pass "A46  access taichung NORMAL BIRTHDAY: B67EDA...=19700404, EBD71A...=19410712"
else
    _fail "A46  access taichung NORMAL BIRTHDAY 不符 [B67EDA=$_a46_b67 EBD71A=$_a46_ebd]"
fi

# A47: tsv ORPHAN BIRTHDAY 值 — taipei 2EDEBACB...=19560711
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei --format tsv 2>/dev/null)
_a47_2ede=$(printf '%s\n' "$out" | gawk -F'\t' '$13=="2EDEBACB75D9FA547F2018E13E695AF1"{print $14; exit}')
_eq A47 "access taipei ORPHAN BIRTHDAY: 2EDEBACB...=19560711" "$_a47_2ede" "19560711"

# A48: text detail (all regions) 含 BIRTHDAY 標頭 + NORMAL dob 19410712 + ORPHAN dob 19560711
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
if printf '%s\n' "$out" | grep -qF "BIRTHDAY" && \
   printf '%s\n' "$out" | grep -qF "19410712" && \
   printf '%s\n' "$out" | grep -qF "19560711"; then
    _pass "A48  access text detail 含 BIRTHDAY 標頭 + dob 19410712(NORMAL) + 19560711(ORPHAN)"
else
    _fail "A48  access text detail 缺少 BIRTHDAY 標頭或 dob 值"
fi

# A49: jwt_dob 邊界 — 空字串/非JWT/無dob claim/dob空值 均回傳 "-" 哨兵
# 修正版 harness：$JWT_DOB_FUNC 與 BEGIN 程式以「相鄰字串」串接成單一 gawk 參數
# (gawk "$JWT_DOB_FUNC" 'BEGIN{...}' 會把 BEGIN{...} 誤判為檔名 — 絕不可用此寫法)。
_a49_out=$(LC_ALL=C gawk "$JWT_DOB_FUNC"'BEGIN {
    n = 0
    if (jwt_dob("") != "-") n++
    if (jwt_dob("notajwt") != "-") n++
    if (jwt_dob("h.eyJmb28iOiJiYXIifQ.s") != "-") n++
    if (jwt_dob("h.eyJkb2IiOiIifQ.s") != "-") n++
    print n
}' </dev/null)
_eq A49 "jwt_dob 邊界: 空字串/非JWT/無dob claim/dob空值 均回傳 - (0 個例外)" "$_a49_out" "0"

# A50: jwt_dob 正向 — 真實長 token (6-bit overflow 縮減路徑) + pretty-space + dobby-trap
_a50_apicsv="${LOG_DIR}/10.1.73.37/app/2026-05-21/app-access-2026-05-21.csv"
_a50_tok=$(gawk -F',' 'NR==2{print $9}' "$_a50_apicsv")
_a50_real=$(LC_ALL=C gawk -v TOK="$_a50_tok" "$JWT_DOB_FUNC"'BEGIN{ print jwt_dob(TOK) }' </dev/null)
_a50_pretty=$(LC_ALL=C gawk "$JWT_DOB_FUNC"'BEGIN{ print jwt_dob("h.eyJkb2IiIDogIjE5OTkwOTA5In0.s") }' </dev/null)
_a50_dobby=$(LC_ALL=C gawk "$JWT_DOB_FUNC"'BEGIN{ print jwt_dob("h.eyJkb2JieSI6IngiLCJkb2IiOiIyMDAwMTIzMSJ9.s") }' </dev/null)
if [[ "$_a50_real" == "19700404" && "$_a50_pretty" == "19990909" && "$_a50_dobby" == "20001231" ]]; then
    _pass "A50  jwt_dob 正向: 真實token(req 4000031c)=19700404, pretty-space=19990909, dobby-trap=20001231"
else
    _fail "A50  jwt_dob 正向不符 [real=$_a50_real pretty=$_a50_pretty dobby=$_a50_dobby]"
fi

# A51: 欄位索引不變 (append 而非 insert) — header $2/$7/$13 位置不變 + 全部列 NF=14
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --from 2026-05-18 --to 2026-05-25 --format tsv 2>/dev/null)
_a51_hdr=$(printf '%s\n' "$out" | head -1)
_a51_h2=$(printf '%s\n' "$_a51_hdr" | gawk -F'\t' '{print $2}')
_a51_h7=$(printf '%s\n' "$_a51_hdr" | gawk -F'\t' '{print $7}')
_a51_h13=$(printf '%s\n' "$_a51_hdr" | gawk -F'\t' '{print $13}')
_a51_hnf=$(printf '%s\n' "$_a51_hdr" | gawk -F'\t' '{print NF}')
_a51_baddata=$(printf '%s\n' "$out" | tail -n +2 | gawk -F'\t' 'NF!=14{c++} END{print c+0}')
if [[ "$_a51_h2" == "STATUS" && "$_a51_h7" == "REQUEST_ID" && "$_a51_h13" == "PATIENT_ID_AES" \
      && "$_a51_hnf" == "14" && "$_a51_baddata" == "0" ]]; then
    _pass "A51  欄位索引不變: \$2=STATUS \$7=REQUEST_ID \$13=PATIENT_ID_AES; header+全部資料列 NF=14"
else
    _fail "A51  欄位索引/NF 不符 [h2=$_a51_h2 h7=$_a51_h7 h13=$_a51_h13 hnf=$_a51_hnf baddata_rows=$_a51_baddata]"
fi

# A52: csv header/NF=14 一致 + summary 不含 BIRTHDAY (NORMAL=6) + access_ip_counts.tsv 不變 ('-'<TAB>9)
_a52_csv=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --format csv 2>/dev/null)
_a52_csvhdr=$(printf '%s\n' "$_a52_csv" | head -1)
_a52_csv_ok=0
if [[ "$_a52_csvhdr" == *",PATIENT_ID_AES,BIRTHDAY" ]]; then _a52_csv_ok=1; fi
_a52_csv_baddata=$(printf '%s\n' "$_a52_csv" | tail -n +2 | gawk -F',' 'NF!=14{c++} END{print c+0}')
_a52_sum=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --view summary 2>/dev/null)
_a52_sum_normal=$(printf '%s\n' "$_a52_sum" | grep "NORMAL  (正常流程)" | awk '{print $(NF-1)}')
TMPD_A52=$(mktemp -d /tmp/lp_a52.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_A52" >/dev/null 2>&1
_a52_ipfile=$(ls "$TMPD_A52"/*/access_ip_counts.tsv 2>/dev/null | head -1)
_a52_ipline=$(gawk -F'\t' '$1=="-"{print $1"\t"$2; exit}' "$_a52_ipfile" 2>/dev/null)
rm -rf "$TMPD_A52"
if [[ "$_a52_csv_ok" == "1" && "$_a52_csv_baddata" == "0" && "$_a52_sum_normal" == "6" \
      && "$_a52_ipline" == $'-\t9' ]] && ! printf '%s\n' "$_a52_sum" | grep -qF "BIRTHDAY"; then
    _pass "A52  csv header/NF=14 一致; summary 不含 BIRTHDAY 且 NORMAL=6; access_ip_counts.tsv 仍為 '-<TAB>9'"
else
    _fail "A52  regression 不符 [csv_ok=$_a52_csv_ok csv_bad=$_a52_csv_baddata sum_normal=$_a52_sum_normal ipline=$_a52_ipline]"
fi

# C22: errors 重啟表 (含 UNMATCHED CJK 列) 第三欄對齊
# Use --date 2026-05-25 --region taipei: Restart count=0 => only UNMATCHED rows exist.
# Extract header + UNMATCHED-only rows (col3 = single-token "?") to avoid the
# multi-token "Xm Ys" Downtime values on RESTART rows that break _aligncols.
out=$(NO_COLOR=1 bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-25 --region taipei)
block=$(printf '%s\n' "$out" | awk '
    /Shutdown Time .* Downtime/ { grab=1; print; next }
    grab && /無對應啟動記錄/    { print }
    grab && /^[[:space:]]*$/    { grab=0 }
')
if ! printf '%s\n' "$block" | grep -qF "無對應啟動記錄" 2>/dev/null; then
    _fail "C22  errors 重啟表 UNMATCHED CJK 列存在 (non-vacuous guard failed: 輸出無 CJK 行)"
else
    _eq C22 "errors 重啟表 (含 UNMATCHED CJK 列) 第三欄對齊" \
        "$(printf '%s' "$block" | _aligncols)" "1"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section G (continued) — G01–G03  新增 CJK 對齊案例 (overview + iis)
# ─────────────────────────────────────────────────────────────────────────────

# G01: overview 總體概況 KV 區塊數值欄對齊 (label 40-col → value starts same column)
# Baseline: 存取關聯總數 (value "9") + 平均 API→APP 延遲 (value "19.5s") — both single-token.
# NORMAL/ORPHAN/UNVERIFIED lines have multi-token values "N (P%)" so _aligncols would
# strip only the last token "(P%)", leaving "N " in the prefix and give got=2.
# Single-token lines correctly verify fmt_kv display-width alignment.
out_g=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
_g01_block=$(printf '%s\n' "$out_g" | sed -n '/▶ 總體概況/,/▶ 分區別/p' \
    | grep -E '關聯總數|延遲')
_eq G01 "overview 總體概況 KV 數值欄對齊 (display-col 一致)" \
    "$(printf '%s' "$_g01_block" | _aligncols)" "1"

# G02: iis summary KV 區塊數值欄對齊 (業務模式: 5XX/503/302 KPI 已移除)
# Baseline: 總請求數 / 不重複用戶端 IP (503/302 KPI lines removed from business-only summary)
out_g2=$(NO_COLOR=1 bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --view summary 2>/dev/null)
_g02_block=$(printf '%s\n' "$out_g2" | grep -E '總請求數|用戶端 IP' | grep -v '■')
_eq G02 "iis summary KV 數值欄對齊 (display-col 一致)" \
    "$(printf '%s' "$_g02_block" | _aligncols)" "1"

# G03: overview category rows 回應時間欄對齊 (req1/R3 — 回應時間 column at fixed display position)
# Baseline: 雲端查詢/報告摘要/影像下載 — rpad(name,12)+rpad("呼叫次數 "count,18) are fixed;
# so "回應時間" starts at the same display column in all 9 rows (3 global + 6 per-region).
# _aligncols strips the last token (avg value e.g. "0.11s") and measures the prefix.
# sed is a no-op guard (慢速 column removed; left in to keep test portable).
_g03_block=$(printf '%s\n' "$out_g" | grep -E '雲端查詢|報告摘要|影像下載')
_g03_pre=$(printf '%s\n' "$_g03_block" | sed 's/慢速.*//')
_eq G03 "overview 核心功能效能 平均欄位固定寬度對齊 (display-col 一致)" \
    "$(printf '%s' "$_g03_pre" | _aligncols)" "1"

# ─────────────────────────────────────────────────────────────────────────────
# Section G (continued) — G04–G05  fmt_bar + agg_access_records 新行為
# G04 empirically verified: max bucket 4 -> 40 cells; 1 -> 10 cells; U+2588=3 bytes.
#   byte-len(row "14") - byte-len(row "13") = 30 cells x 3 bytes = 90.
# G05 guard: NORMAL with empty APP_TIME -> no HOUR-00 row; WARN on stderr; IP still counted.
# ─────────────────────────────────────────────────────────────────────────────

# G04: fmt_bar 比例縮放 + U+2588 3-byte UTF-8 排放 (LC_ALL=C 下 byte-diff == 90)
# max bucket 4 -> 40 cells; count 1 -> 10 cells; 30 cells x 3 bytes each = 90.
# fmt_utils already sourced above.
_g04_out=$(printf '13\t1\n14\t4\n15\t4\n' | fmt_bar)
_g04_r13=$(printf '%s\n' "$_g04_out" | gawk '$1=="13"{print; exit}')
_g04_r14=$(printf '%s\n' "$_g04_out" | gawk '$1=="14"{print; exit}')
# Use wc -c (byte count), not ${#var} (character count), to measure UTF-8 bytes correctly
_g04_len13=$(printf '%s' "$_g04_r13" | wc -c | tr -d ' ')
_g04_len14=$(printf '%s' "$_g04_r14" | wc -c | tr -d ' ')
_g04_diff=$(( _g04_len14 - _g04_len13 ))
_eq G04 "fmt_bar LC_ALL=C: row14 byte-len - row13 byte-len == 90 (30 cells x 3 bytes U+2588)" \
    "$_g04_diff" "90"

# G05: agg_access_records: malformed APP_TIME (empty) -> no HOUR-00 row; WARN on stderr; IP counted
_g05_tmpdir=$(mktemp -d /tmp/lp_g05.XXXXXX)
_g05_file="${_g05_tmpdir}/result_sorted.tsv"
# row1: NORMAL with empty APP_TIME ($3), CLIENT_IP 10.0.0.1
printf 'NORMAL\t2026-05-21 14:00:00.000\t\t0\tOK\treq001\t10.22.63.37\t10.21.3.35\tH01\tP01\t10.0.0.1\tENC001\n' \
    > "$_g05_file"
# row2: ORPHAN with valid APP_TIME 2026-05-21 14:05:00.000, CLIENT_IP 10.0.0.2
printf 'ORPHAN\t-\t2026-05-21 14:05:00.000\t-\t-\treq002\t-\t10.21.3.35\t-\t-\t10.0.0.2\t-\n' \
    >> "$_g05_file"
_g05_out=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/aggregate_utils.sh'
    agg_access_records '${_g05_file}'
" 2>"${_g05_tmpdir}/err.txt")
_g05_hour00=$(printf '%s\n' "$_g05_out" | gawk -F'\t' '$1=="HOUR"&&$2=="00"{print $3; exit}')
_g05_hour14=$(printf '%s\n' "$_g05_out" | gawk -F'\t' '$1=="HOUR"&&$2=="14"{print $3; exit}')
_g05_ip_sum=$(printf '%s\n' "$_g05_out" | gawk -F'\t' '$1=="IP"{s+=$3} END{print s+0}')
_g05_warn=$(grep -c "WARN" "${_g05_tmpdir}/err.txt" 2>/dev/null || echo 0)
if [[ -z "$_g05_hour00" && "$_g05_hour14" == "1" && "$_g05_ip_sum" -eq 2 && "$_g05_warn" -ge 1 ]]; then
    _pass "G05  malformed APP_TIME: 無 HOUR-00、HOUR-14=1、IP sum=2、stderr WARN 存在"
else
    _fail "G05  malformed APP_TIME guard 不符 [hour00=${_g05_hour00:-NONE} hour14=${_g05_hour14:-0} ip_sum=$_g05_ip_sum warn=$_g05_warn]"
fi
rm -rf "$_g05_tmpdir"

# ─────────────────────────────────────────────────────────────────────────────
# Section H — analyze_overview.sh  管理總覽 (H01–H21)
# Baselines (fixed dates):
#   --date 2026-05-21 --region all (exclude):
#     IIS business total = 723 (external anchor H13; +8h window verified by raw grep)
#     ACCESS all: NORMAL=6 ORPHAN=3 UNVERIFIED=0 total=9; NORMAL率 66.7% → verdict 警告
#     ACCESS taipei: NORMAL=0 ORPHAN=3 UNVERIFIED=0; ACCESS taichung: NORMAL=6 ORPHAN=0
#     核心功能 global: glcr=11/0.11s ds=186/0.38s nhi=427/0.93s sum=624
#     核心功能 taipei: glcr=5/0.02s ds=71/0.22s nhi=220/1.48s (distinct 3 nhi avgs → K-section)
#     核心功能 taichung: glcr=6/0.19s ds=115/0.47s nhi=207/0.34s
#     verdict bands: >=90 正常; >=70 注意; <70 警告 (overview_health_verdict in aggregate_utils)
# ─────────────────────────────────────────────────────────────────────────────

section "H  analyze_overview.sh — 管理總覽"

# Base run for H01–H08, H11, H13, H14
out=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null); rc=$?

# H01: 三個主要區塊均存在 (exit 0 + 總體概況 + 存取關聯總數 + NORMAL 正常流程)
if [[ "$rc" -eq 0 ]] && \
   printf '%s\n' "$out" | grep -qF "總體概況" && \
   printf '%s\n' "$out" | grep -qF "存取關聯總數" && \
   printf '%s\n' "$out" | grep -qF "NORMAL 正常流程"; then
    _pass "H01  overview exit 0 且含 總體概況 + 存取關聯總數 + NORMAL 正常流程"
else
    _fail "H01  overview exit 0 且含 總體概況 + 存取關聯總數 + NORMAL 正常流程 [rc=$rc]"
fi

# H02: 分區別 含 台北 + 台中 + NORMAL + ORPHAN + UNVERIFIED; IIS 佔比 不出現 (req5)
# New structure: per-region ■ blocks with N/O/U prose line (no combined 異常 lump).
if printf '%s\n' "$out" | grep -qF "台北" && \
   printf '%s\n' "$out" | grep -qF "台中" && \
   printf '%s\n' "$out" | grep -qF "NORMAL" && \
   printf '%s\n' "$out" | grep -qF "ORPHAN" && \
   printf '%s\n' "$out" | grep -qF "UNVERIFIED"; then
    if ! printf '%s\n' "$out" | grep -qF "IIS 佔比"; then
        _pass "H02  分區別 含 台北+台中+NORMAL+ORPHAN+UNVERIFIED; IIS 佔比 不出現"
    else
        _fail "H02  分區別 含 台北+台中+NORMAL+ORPHAN+UNVERIFIED; IIS 佔比 不應出現"
    fi
else
    _fail "H02  分區別 缺少 台北/台中 或 NORMAL/ORPHAN/UNVERIFIED"
fi

# H03: 總體概況 block 含 雲端查詢 + 報告摘要 + 影像下載 (categories merged into Overall)
h03_block=$(printf '%s\n' "$out" | sed -n '/▶ 總體概況/,/▶ 分區別/p')
if printf '%s\n' "$h03_block" | grep -qF "雲端查詢" && \
   printf '%s\n' "$h03_block" | grep -qF "報告摘要" && \
   printf '%s\n' "$h03_block" | grep -qF "影像下載"; then
    _pass "H03  總體概況 block 含 雲端查詢+報告摘要+影像下載"
else
    _fail "H03  總體概況 block 含 雲端查詢+報告摘要+影像下載"
fi

# H04: 總體概況的 存取關聯總數 不重複出現於 分區別/核心功能效能 區塊 (C5 line-range scoped)
h04_acc_total=$(_pick "$out" "存取關聯總數")
after_overall=$(printf '%s\n' "$out" | sed -n '/▶ 分區別/,$p')
# "存取關聯總數" as a KV key must not appear after 總體概況 (the value "9" may appear elsewhere)
if printf '%s\n' "$after_overall" | grep -qF "存取關聯總數"; then
    _fail "H04  存取關聯總數 (KV key) 不應重複出現於 分區/核心功能 區塊 (C5)"
else
    _pass "H04  存取關聯總數 (KV key) 不重複出現於 分區/核心功能 區塊 (C5)"
fi

# H05: category rows 不含百分比 token (req1 % 移除 regression guard)
# Repurposed from "佔比之和 >= 99" to "no ([N.N%]) token on category rows".
pct_count=$(printf '%s\n' "$out" | grep -E '雲端查詢|報告摘要|影像下載' | \
    grep -cE '\([0-9]+\.[0-9]+%\)' || true)
_eq H05 "category rows 不含 ([N.N%]) 百分比 token (req1 % 移除)" "${pct_count:-0}" "0"

# H06: ■ 核心功能效能 sub-block 含 呼叫次數 AND 回應時間 (window anchored on ■ h3)
# The sed window anchors on the ■ line (which is below the ORPHAN KV line in 總體概況),
# so the old ORPHAN-absence check was vacuous (always true). It is removed per spec §7.
core_block=$(printf '%s\n' "$out" | sed -n '/■ 核心功能效能/,/^$/p')
if printf '%s\n' "$core_block" | grep -qF "呼叫次數" && \
   printf '%s\n' "$core_block" | grep -qF "回應時間"; then
    _pass "H06  ■ 核心功能效能 sub-block 含 呼叫次數 AND 回應時間"
else
    _fail "H06  ■ 核心功能效能 sub-block 含 呼叫次數 AND 回應時間"
fi

# H07: DRY — overview 核心功能存取合計 == analyze_iis --emit-stats CATEGORY count 之和
# Use grep -oE '[0-9]+' | head -1 to extract the count (first number on the line).
# _pick ($NF) would return "(100.0%)" since the value is "624 (100.0%)" — multi-token.
iis_emit=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --emit-stats 2>/dev/null)
h07_cat_sum=$(printf '%s\n' "$iis_emit" | gawk -F'\t' '$5=="CATEGORY"{s+=$7} END{print s+0}')
h07_ovw=$(printf '%s\n' "$out" | grep "核心功能存取合計" | grep -oE '[0-9]+' | head -1)
_eq H07 "overview 核心功能存取合計 == iis emit-stats CATEGORY count 之和 (DRY)" "$h07_ovw" "$h07_cat_sum"

# H08: EXTERNAL anchor — overview NORMAL 正常流程 == 獨立計算值 (DRY 內部一致性)
# Extract the "(66.7%)" token from the NORMAL 正常流程 line; compare to computed baseline.
acc_emit=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --emit-stats 2>/dev/null)
h08_norm=$(printf '%s\n' "$acc_emit" | gawk -F'\t' '$3=="NORMAL"{s+=$4} END{print s+0}')
h08_tot=$( printf '%s\n' "$acc_emit" | gawk -F'\t' \
    '$3~/^(NORMAL|ORPHAN|UNVERIFIED)$/{s+=$4} END{print s+0}')
h08_expected="($(gawk -v n="$h08_norm" -v d="$h08_tot" \
    'BEGIN{if(d>0) printf "%.1f%%", n/d*100; else print "N/A"}'))"
h08_line=$(printf '%s\n' "$out" | grep "NORMAL 正常流程" | head -1)
h08_tok=$(printf '%s\n' "$h08_line" | awk '{print $NF}')
_eq H08 "overview NORMAL 正常流程 (66.7%) == access emit-stats 計算值" "$h08_tok" "$h08_expected"

# H09: --region taipei → 只含 台北; 不含 台中
out09=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
_has  H09a "overview --region taipei 含 台北" "$out09" "台北"
_lacks H09 "overview --region taipei 不含 台中" "$out09" "台中"

# H10: 空窗期 → exit 0; 無除零錯誤; 含 N/A 或 0
out10=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-01 2>/dev/null); rc10=$?
_ok H10 "overview 空窗期 exit 0 (無除零崩潰)" "$rc10"

# H11: 整體健康判定 列不含數字 (C5 verdict numeric-free)
verdict_line=$(printf '%s\n' "$out" | grep "整體健康判定")
if printf '%s\n' "$verdict_line" | grep -qE '[0-9]'; then
    _fail "H11  整體健康判定 列含數字 (違反 C5)"
else
    _pass "H11  整體健康判定 列無數字 (C5 verdict numeric-free)"
fi

# H12: --today → exit 0 且期間標頭含 (1 天)
out12=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --today 2>/dev/null); rc12=$?
_ok  H12a "overview --today exit 0" "$rc12"
_has H12  "overview --today 期間含 '(1 天)'" "$out12" "(1 天)"

# H13: EXTERNAL anchor — IIS business total == raw grep count (+8h UTC window, 獨立驗算)
# Independent baseline: +8h window = u_ex260520 rows $2>="16:00:00" + u_ex260521 rows $2<"16:00:00"
# Filters: NF>=17, !/^#/, $5!="/health", exclude test-host IPs .79/.110/.28
_h13_total=0
for _h13_srv in 10.1.72.35 10.1.72.36 10.1.73.37 10.21.3.35 10.21.3.36 10.22.63.37; do
    _h13_f20="${LOG_DIR}/${_h13_srv}/iis/u_ex260520.log"
    _h13_f21="${LOG_DIR}/${_h13_srv}/iis/u_ex260521.log"
    _h13_n=0
    if [[ -f "$_h13_f20" ]]; then
        _h13_n20=$(gawk 'NF>=17 && !/^#/ && $2>="16:00:00" && $5!="/health" && $9!="192.168.139.79" && $9!="192.168.139.110" && $9!="192.168.139.28" {c++} END{print c+0}' "$_h13_f20")
        _h13_n=$(( _h13_n + _h13_n20 ))
    fi
    if [[ -f "$_h13_f21" ]]; then
        _h13_n21=$(gawk 'NF>=17 && !/^#/ && $2<"16:00:00" && $5!="/health" && $9!="192.168.139.79" && $9!="192.168.139.110" && $9!="192.168.139.28" {c++} END{print c+0}' "$_h13_f21")
        _h13_n=$(( _h13_n + _h13_n21 ))
    fi
    _h13_total=$(( _h13_total + _h13_n ))
done
# Re-point assertion: raw total should == analyze_iis emit-stats TOTAL (K03 also tests this)
# and the result (723) should equal the 核心功能存取合計 denominator (IIS total, not overview KV)
h13_emit=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --emit-stats 2>/dev/null)
h13_iis_total=$(printf '%s\n' "$h13_emit" | gawk -F'\t' '$5=="TOTAL"{s+=$6} END{print s+0}')
_eq H13 "IIS business total == 獨立 +8h raw grep (${_h13_total})" "$h13_iis_total" "$_h13_total"

# H14: EXTERNAL anchor — NORMAL 正常流程 (66.7%) == 獨立計算基準
# Independent baseline: taipei 0521 NORMAL=0 ORPHAN=3; taichung 0521 NORMAL=6 ORPHAN=0 → 6/9
_h14_expected="($(gawk 'BEGIN{printf "%.1f%%", 6/9*100}'))"   # "(66.7%)"
h14_line=$(printf '%s\n' "$out" | grep "NORMAL 正常流程" | head -1)
h14_tok=$(printf '%s\n' "$h14_line" | awk '{print $NF}')      # last token = "(66.7%)"
_eq H14 "overview NORMAL 正常流程 == 獨立基準 ${_h14_expected}" "$h14_tok" "$_h14_expected"

# H15: --slow-api-ms + --slow-app-ms → exit 0 且 核心功能效能 存在 (C2 forwarding guard)
# Proves ACCESS spawn does NOT receive --slow-*-ms (access would die on unknown flag).
# Custom thresholds influence 核心功能效能 慢速 column (ds/nhi use api threshold, glcr uses app).
out15=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --slow-api-ms 1000 --slow-app-ms 3000 2>/dev/null); rc15=$?
if [[ "$rc15" -eq 0 ]] && \
   printf '%s\n' "$out15" | grep -qF "核心功能效能" && \
   printf '%s\n' "$out15" | grep -qF "雲端查詢"; then
    _pass "H15  --slow-api/app-ms exit 0 且 核心功能效能 存在 (C2 forwarding guard)"
else
    _fail "H15  --slow-api/app-ms exit 0 且 核心功能效能 存在 (C2 forwarding guard) [rc=$rc15]"
fi

# H16: 分區別 台北 存取關聯 行含明確 N/O/U 計數 (req3 prose enumeration)
# Anchor: taipei 0521: NORMAL=0 ORPHAN=3 UNVERIFIED=0 (total=3)
h16_out=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
h16_line=$(printf '%s\n' "$h16_out" | sed -n '/■ 台北/,/■ 台中/p' | grep "存取關聯")
if printf '%s\n' "$h16_line" | grep -qF "NORMAL 0 (0.0%)" && \
   printf '%s\n' "$h16_line" | grep -qF "ORPHAN 3 (100.0%)" && \
   printf '%s\n' "$h16_line" | grep -qF "UNVERIFIED 0 (0.0%)"; then
    _pass "H16  分區別 台北 存取關聯 含 NORMAL 0 (0.0%), ORPHAN 3 (100.0%), UNVERIFIED 0 (0.0%)"
else
    _fail "H16  分區別 台北 存取關聯 含 NORMAL 0 (0.0%), ORPHAN 3 (100.0%), UNVERIFIED 0 (0.0%) [got: '${h16_line}']"
fi

# H17: 分區別 台北 影像下載 per-region row (proves CAT_REGION != global)
# Anchor: taipei nhi 220/1.48s (distinct from global 427/0.93s)
h17_taipei=$(printf '%s\n' "$h16_out" | sed -n '/■ 台北/,/■ 台中/p' | grep "影像下載")
if printf '%s\n' "$h17_taipei" | grep -qF "呼叫次數 220" && \
   printf '%s\n' "$h17_taipei" | grep -qF "回應時間 1.48s"; then
    _pass "H17  分區別 台北 影像下載 呼叫次數 220 回應時間 1.48s (per-region CAT_REGION correct)"
else
    _fail "H17  分區別 台北 影像下載 呼叫次數 220 回應時間 1.48s [got: '${h17_taipei}']"
fi

# H18: verdict >=90 boundary — overview_health_verdict 9/10 = 90% → 正常
_v() { bash -c "source '${PROJECT_DIR}/lib/aggregate_utils.sh'; overview_health_verdict $1 $2" 2>/dev/null; }
_eq H18 "verdict 90% (9/10) -> 正常 — 系統整體運作健康" "$(_v 9 10)" "正常 — 系統整體運作健康"

# H19: verdict 89 → 注意 (89 < 90; upper 注意 boundary)
h19_v=$(_v 89 100)
_hasre H19 "verdict 89% (89/100) starts 注意" "$h19_v" "^注意"

# H20: verdict >=70 boundary — overview_health_verdict 7/10 = 70% → 注意
h20_v=$(_v 7 10)
_hasre H20 "verdict 70% (7/10) starts 注意" "$h20_v" "^注意"

# H21: verdict <70 boundary — overview_health_verdict 69/100 = 69% → 警告
h21_v=$(_v 69 100)
_hasre H21 "verdict 69% (69/100) starts 警告" "$h21_v" "^警告"

# ─────────────────────────────────────────────────────────────────────────────
# Section H (continued) — H22–H25  存取紀錄橫條圖 (每小時) 單日 + 多日 + today-cap
# Baselines (verified from spec pinned_numbers, exclude mode 2026-05-21):
#   global: hour 13=1, 14=4, 15=4; taipei: 15=3; taichung: 13=1, 14=4, 15=1
#   Three charts total in single-day run (global + taipei + taichung).
#   Multi-day run: NO chart (gate: _OVW_N_DATES==1 only).
#   today-cap: LOG_PARSE_NOW_HOUR=3 -> hours 00-02 only; =0 -> "今日尚無完整小時資料".
# ─────────────────────────────────────────────────────────────────────────────

# H22: 單日 overview (2026-05-21) 總體概況: 含 存取紀錄橫條圖 + hour-14 count=4 + U+2588 存在
out_h22=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
_h22_global_sec=$(printf '%s\n' "$out_h22" | sed -n '/▶ 總體概況/,/▶ 分區別/p')
_h22_has_chart=$(printf '%s\n' "$_h22_global_sec" | grep -cF "存取紀錄橫條圖" 2>/dev/null || true)
# Bar row format: "      14    4  [bars]" — $1=label, $2=count (awk default whitespace split)
_h22_h14=$(printf '%s\n' "$_h22_global_sec" | gawk '$1=="14"{print $2+0; exit}')
_h22_has_block=$(printf '%s\n' "$_h22_global_sec" | LC_ALL=C od -An -tx1 | grep -c "e2 96 88" 2>/dev/null || true)
if [[ "$_h22_has_chart" -ge 1 && "$_h22_h14" == "4" && "$_h22_has_block" -ge 1 ]]; then
    _pass "H22  總體概況: 含 存取紀錄橫條圖 + hour-14=4 + U+2588 FULL BLOCK 存在"
else
    _fail "H22  總體概況: 含 存取紀錄橫條圖 + hour-14=4 + U+2588 [chart=$_h22_has_chart h14=${_h22_h14:-?} block=$_h22_has_block]"
fi

# H23: 存取紀錄橫條圖 出現 3 次; 台北 hour-15=3; 台中 hour-14=4 (ACC_HOUR_REGION distinct from global)
_h23_chart_cnt=$(printf '%s\n' "$out_h22" | grep -cF "存取紀錄橫條圖" 2>/dev/null || true)
_h23_taipei_sec=$(printf '%s\n' "$out_h22" | sed -n '/■ 台北/,/■ 台中/p')
_h23_tp15=$(printf '%s\n' "$_h23_taipei_sec" | gawk '$1=="15"{print $2+0; exit}')
_h23_taichung_sec=$(printf '%s\n' "$out_h22" | sed -n '/■ 台中/,$p')
_h23_tc14=$(printf '%s\n' "$_h23_taichung_sec" | gawk '$1=="14"{print $2+0; exit}')
if [[ "$_h23_chart_cnt" -eq 3 && "$_h23_tp15" == "3" && "$_h23_tc14" == "4" ]]; then
    _pass "H23  橫條圖 3 次; 台北 hour-15=3; 台中 hour-14=4 (per-region 獨立於 global)"
else
    _fail "H23  橫條圖/台北/台中 [charts=$_h23_chart_cnt tp15=${_h23_tp15:-?} tc14=${_h23_tc14:-?}]"
fi

# H24: 多日 overview (--from --to, _OVW_N_DATES==8) 不含 存取紀錄橫條圖 (gate 保護)
out_h24=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 2>/dev/null)
_lacks H24 "多日 overview 不含 存取紀錄橫條圖 (chart is single-day only)" \
    "$out_h24" "存取紀錄橫條圖"

# H25: today-cap — HOUR=3 -> chart 含 00-02 只; HOUR=0 -> 今日尚無完整小時資料
out_h25=$(NO_COLOR=1 LOG_PARSE_NOW_HOUR=3 bash "$OVERVIEW" --log-dir "$LOG_DIR" --today 2>/dev/null)
_h25_has_chart=$(printf '%s\n' "$out_h25" | grep -cF "存取紀錄橫條圖" 2>/dev/null || true)
_h25_late=$(printf '%s\n' "$out_h25" | grep -cE '^ {6}(0[3-9]|1[0-9]|2[0-3])  ' 2>/dev/null || true)
out_h25z=$(NO_COLOR=1 LOG_PARSE_NOW_HOUR=0 bash "$OVERVIEW" --log-dir "$LOG_DIR" --today 2>/dev/null)
_h25_empty=$(printf '%s\n' "$out_h25z" | grep -cF "今日尚無完整小時資料" 2>/dev/null || true)
if [[ "$_h25_has_chart" -ge 1 && "$_h25_late" -eq 0 && "$_h25_empty" -ge 1 ]]; then
    _pass "H25  today-cap HOUR=3: chart 存在 + hour03-23 缺席; HOUR=0: 今日尚無完整小時資料"
else
    _fail "H25  today-cap [chart=$_h25_has_chart late=$_h25_late empty=$_h25_empty]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section I — 持久化行為 (Persistence I01–I12)
# Baselines: analyze_iis taipei 2026-05-21 (2 files); log_report 6 files.
# Every test uses its own TMPD_Ixx via --output-dir to isolate from
# the global PERSIST_TMPDIR.  I02 uses a subshell + env -u to test default.
# ─────────────────────────────────────────────────────────────────────────────

section "I  持久化行為 — always-on report persistence"

# I01: standalone iis 寫出 iis_summary_*.txt + iis_detail_*.txt (glob, temp dir)
TMPD_I01=$(mktemp -d /tmp/lp_i01.XXXXXX)
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --output-dir "$TMPD_I01" >/dev/null 2>&1
if ls "${TMPD_I01}"/*/iis_summary.txt > /dev/null 2>&1 && \
   ls "${TMPD_I01}"/*/iis_detail.txt  > /dev/null 2>&1; then
    _pass "I01  standalone iis 寫出 iis_summary.txt + iis_detail.txt"
else
    _fail "I01  standalone iis 寫出 iis_summary.txt + iis_detail.txt"
fi
rm -rf "$TMPD_I01"

# I02: 預設持久化目錄 ./log-parse 自動建立 (env/flag 均未設時 C1 → ./log-parse)
TMPD_I02=$(mktemp -d /tmp/lp_i02.XXXXXX)
(cd "$TMPD_I02" && env -u LOG_PARSE_OUTPUT_DIR bash "$IIS" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei >/dev/null 2>&1)
if [[ -d "${TMPD_I02}/log-parse" ]]; then
    _pass "I02  未設 env/flag 時預設持久化目錄 ./log-parse 已建立 (C1)"
else
    _fail "I02  未設 env/flag 時預設持久化目錄 ./log-parse 已建立 (C1)"
fi
rm -rf "$TMPD_I02"

# I03: --output-dir 旗標優先於 LOG_PARSE_OUTPUT_DIR env (C1 flag > env)
TMPD_I03_ENV=$(mktemp -d /tmp/lp_i03e.XXXXXX)
TMPD_I03_FLAG=$(mktemp -d /tmp/lp_i03f.XXXXXX)
LOG_PARSE_OUTPUT_DIR="$TMPD_I03_ENV" bash "$IIS" --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --output-dir "$TMPD_I03_FLAG" >/dev/null 2>&1
_i03_env_cnt=$(ls "$TMPD_I03_ENV" 2>/dev/null | wc -l | tr -d ' ')
_i03_flag_cnt=$(ls "$TMPD_I03_FLAG" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_i03_env_cnt" -eq 0 && "$_i03_flag_cnt" -gt 0 ]]; then
    _pass "I03  --output-dir 優先於 env (C1): env dir 空, flag dir 有檔"
else
    _fail "I03  --output-dir 優先於 env (C1): env dir 空, flag dir 有檔 [env=$_i03_env_cnt flag=$_i03_flag_cnt]"
fi
rm -rf "$TMPD_I03_ENV" "$TMPD_I03_FLAG"

# I04: detail 副檔名跟隨 --format (csv → *.csv；無 *.plain 殘留 C4)
TMPD_I04=$(mktemp -d /tmp/lp_i04.XXXXXX)
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --format csv --output-dir "$TMPD_I04" >/dev/null 2>&1
_i04_csv=$(ls "${TMPD_I04}"/*/iis_detail.csv > /dev/null 2>&1 && echo 1 || echo 0)
_i04_plain=$(find "${TMPD_I04}" -type f -name "*.plain" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_i04_csv" -eq 1 && "$_i04_plain" -eq 0 ]]; then
    _pass "I04  detail 副檔名跟隨 --format csv (*.csv 存在，無 *.plain 殘留 C4)"
else
    _fail "I04  detail 副檔名跟隨 --format csv (*.csv 存在，無 *.plain 殘留 C4) [csv=$_i04_csv plain=$_i04_plain]"
fi
rm -rf "$TMPD_I04"

# I05: summary 檔案永遠為 .txt，即使 --format csv (C10)
TMPD_I05=$(mktemp -d /tmp/lp_i05.XXXXXX)
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --format csv --output-dir "$TMPD_I05" >/dev/null 2>&1
if ls "${TMPD_I05}"/*/iis_summary.txt > /dev/null 2>&1; then
    _pass "I05  summary 檔案永遠為 .txt (即使 --format csv C10)"
else
    _fail "I05  summary 檔案永遠為 .txt (即使 --format csv C10)"
fi
rm -rf "$TMPD_I05"

# I06: --emit-stats 不寫入任何持久化檔案 (dir 空)
TMPD_I06=$(mktemp -d /tmp/lp_i06.XXXXXX)
LOG_PARSE_OUTPUT_DIR="$TMPD_I06" bash "$IIS" --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --emit-stats >/dev/null 2>&1
_i06_cnt=$(ls "$TMPD_I06" 2>/dev/null | wc -l | tr -d ' ')
_eq I06 "--emit-stats 不寫入持久化檔案 (dir 空)" "$_i06_cnt" "0"
rm -rf "$TMPD_I06"

# I07: overview 僅寫出 overview_summary_*.txt (無 overview_detail_*)
TMPD_I07=$(mktemp -d /tmp/lp_i07.XXXXXX)
bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_I07" >/dev/null 2>&1
_i07_sum=$(ls "${TMPD_I07}"/*/overview_summary.txt > /dev/null 2>&1 && echo 1 || echo 0)
_i07_det=$(find "${TMPD_I07}" -type f -name "overview_detail*" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_i07_sum" -eq 1 && "$_i07_det" -eq 0 ]]; then
    _pass "I07  overview 僅寫出 overview_summary.txt (無 overview_detail_*)"
else
    _fail "I07  overview 僅寫出 overview_summary.txt (無 overview_detail_*) [sum=$_i07_sum det=$_i07_det]"
fi
rm -rf "$TMPD_I07"

# I08: 所有持久化檔案均無 ANSI ESC 碼 (C3 color-free)
# Runs all 4 modules to cover overview_summary + iis_summary + iis_detail +
# access_summary + access_detail + access_ip_counts + errors_summary + errors_detail (8 files total).
TMPD_I08=$(mktemp -d /tmp/lp_i08.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --modules overview,iis,access,errors --output-dir "$TMPD_I08" >/dev/null 2>&1
_i08_esc=0
for _f in "$TMPD_I08"/*/*; do
    _c=$(grep -cP '\x1b' "$_f" 2>/dev/null || true)
    _i08_esc=$(( _i08_esc + _c ))
done
_eq I08 "所有持久化檔案均無 ANSI ESC 碼 (C3 color-free)" "$_i08_esc" "0"
rm -rf "$TMPD_I08"

# I09: console stdout 非空 (pipe-safe) 且持久化檔案已同步建立
TMPD_I09=$(mktemp -d /tmp/lp_i09.XXXXXX)
_i09_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --output-dir "$TMPD_I09" 2>/dev/null)
_i09_files=$(ls "$TMPD_I09" 2>/dev/null | wc -l | tr -d ' ')
if [[ -n "$_i09_out" && "$_i09_files" -gt 0 ]]; then
    _pass "I09  stdout 非空 (console mirror) 且持久化檔案已建立 (pipe-safe)"
else
    _fail "I09  stdout 非空 (console mirror) 且持久化檔案已建立 (pipe-safe) [stdout_len=${#_i09_out} files=$_i09_files]"
fi
rm -rf "$TMPD_I09"

# I10: --view detail 鏡像 detail 至 stdout；--view summary 鏡像 summary
# Distinguisher: detail → English "Total requests"; summary → CJK "總請求數"
_i10_det=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view detail 2>/dev/null)
_i10_sum=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --view summary 2>/dev/null)
if printf '%s\n' "$_i10_det" | grep -qF "Total requests" && \
   printf '%s\n' "$_i10_sum" | grep -qF "總請求數" && \
   ! printf '%s\n' "$_i10_sum" | grep -qF "Total requests"; then
    _pass "I10  --view detail 鏡像英文 detail；--view summary 鏡像 CJK summary"
else
    _fail "I10  --view detail 鏡像英文 detail；--view summary 鏡像 CJK summary"
fi

# I11: 固定 LOG_PARSE_RUN_TS → 產生精確檔名 (pinned timestamp)
TMPD_I11=$(mktemp -d /tmp/lp_i11.XXXXXX)
LOG_PARSE_RUN_TS="20260521_000000" bash "$IIS" --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --output-dir "$TMPD_I11" >/dev/null 2>&1
if [[ -f "${TMPD_I11}/20260521_000000/iis_summary.txt" ]]; then
    _pass "I11  固定 LOG_PARSE_RUN_TS=20260521_000000 產生精確子目錄 + 無 TS 檔名"
else
    _fail "I11  固定 LOG_PARSE_RUN_TS=20260521_000000 產生精確子目錄 + 無 TS 檔名 [files: $(ls -R "$TMPD_I11" 2>/dev/null)]"
fi
rm -rf "$TMPD_I11"

# I12: log_report 預設模組 → 6 個檔案落入同一 TS 子目錄；--output-dir 落入自訂目錄 (C1)
TMPD_I12=$(mktemp -d /tmp/lp_i12.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_I12" >/dev/null 2>&1
_i12_cnt=$(find "$TMPD_I12" -type f 2>/dev/null | wc -l | tr -d ' ')
_i12_ts_uniq=$(ls -d "$TMPD_I12"/*/ 2>/dev/null | wc -l | tr -d ' ')
if [[ "$_i12_cnt" -eq 6 && "$_i12_ts_uniq" -eq 1 ]]; then
    _pass "I12  log_report 預設模組 6 個檔案落入同一 TS 子目錄且落入 --output-dir (C1)"
else
    _fail "I12  log_report 預設模組 6 個檔案落入同一 TS 子目錄且落入 --output-dir (C1) [files=$_i12_cnt ts_subdirs=$_i12_ts_uniq]"
fi
rm -rf "$TMPD_I12"

# ─────────────────────────────────────────────────────────────────────────────
# Section J — test-host filter + /health exclusion (J01–J20)
# All tests use --date 2026-05-21.  External anchors (spec 7a):
#   IIS all regions: exclude=723, only=209, all=932
#   access all regions: NORMAL under exclude=6; .110/.79/.28 absent under exclude
# ─────────────────────────────────────────────────────────────────────────────

section "J  test-host filter + /health exclusion"

# J01: iis 預設 (no --test-hosts flag = exclude) all regions Total = 723
j01_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null)
j01_sum=$(_sum "$j01_out" "Total requests")
_eq J01 "iis 預設 (no flag = exclude) all Total = 723" "$j01_sum" "723"

# J02: iis --test-hosts exclude == J01 (idempotent, explicit flag yields same result)
j02_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --test-hosts exclude 2>/dev/null)
j02_sum=$(_sum "$j02_out" "Total requests")
_eq J02 "iis --test-hosts exclude all Total = 723 (idempotent)" "$j02_sum" "723"

# J03: iis --test-hosts only all Total = 209
j03_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --test-hosts only 2>/dev/null)
j03_sum=$(_sum "$j03_out" "Total requests")
_eq J03 "iis --test-hosts only all Total = 209" "$j03_sum" "209"

# J04: iis --test-hosts all all Total = 932 (test hosts included; /health still excluded)
j04_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --test-hosts all 2>/dev/null)
j04_sum=$(_sum "$j04_out" "Total requests")
_eq J04 "iis --test-hosts all all Total = 932" "$j04_sum" "932"

# J05: iis --test-hosts bogus → non-zero exit (assert_enum)
bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --test-hosts bogus >/dev/null 2>&1; rc_j05=$?
_err J05 "iis --test-hosts bogus → non-zero exit (assert_enum)" "$rc_j05"

# J06: iis exclude: no /health endpoint row (unconditional /health exclusion proof)
# Note: "/health" may appear in the scope banner text; check for endpoint-row format ^    /health
if ! printf '%s\n' "$j01_out" | grep -qE "^    /health" 2>/dev/null; then
    _pass "J06  iis exclude: /health 端點列不出現於 Endpoint 表格 (^    /health)"
else
    _fail "J06  iis exclude: /health 端點列不出現於 Endpoint 表格 (^    /health)"
fi

# J07: iis only: no /health endpoint row (proves /health drops in all test-host modes)
if ! printf '%s\n' "$j03_out" | grep -qE "^    /health" 2>/dev/null; then
    _pass "J07  iis only: /health 端點列不出現 (all-mode 均無條件排除)"
else
    _fail "J07  iis only: /health 端點列不出現 (all-mode 均無條件排除)"
fi

# J08: iis all: no /health endpoint row; all Total 932 == raw NF>=17 !/^#/ !=/health grep
_j08_raw=0
for _j08_srv in 10.1.72.35 10.1.72.36 10.1.73.37 10.21.3.35 10.21.3.36 10.22.63.37; do
    _j08_f="${LOG_DIR}/${_j08_srv}/iis/u_ex260521.log"
    if [[ -f "$_j08_f" ]]; then
        _j08_n=$(gawk 'NF>=17 && !/^#/ && $5!="/health" {c++} END{print c+0}' "$_j08_f")
        _j08_raw=$(( _j08_raw + _j08_n ))
    fi
done
if ! printf '%s\n' "$j04_out" | grep -qE "^    /health" 2>/dev/null && \
   [[ "$j04_sum" -eq "$_j08_raw" ]]; then
    _pass "J08  iis all: /health 端點列不出現; Total (${j04_sum}) == raw grep (${_j08_raw})"
else
    _fail "J08  iis all: /health 端點列不出現 OR Total (${j04_sum}) != raw grep (${_j08_raw})"
fi

# J09: iis exclude: .119 in client IP table; .28/.110/.79 absent (test hosts excluded)
j09_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null)
if printf '%s\n' "$j09_out" | grep -qF "192.168.139.119" 2>/dev/null && \
   ! printf '%s\n' "$j09_out" | grep -qF "192.168.139.28" 2>/dev/null && \
   ! printf '%s\n' "$j09_out" | grep -qF "192.168.139.110" 2>/dev/null && \
   ! printf '%s\n' "$j09_out" | grep -qF "192.168.139.79" 2>/dev/null; then
    _pass "J09  iis exclude: .119 在 Client IP 表; .28/.110/.79 已排除"
else
    _fail "J09  iis exclude: .119 在 Client IP 表; .28/.110/.79 已排除"
fi

# J10: iis only: .110 in client IP table; .119 absent (real gateway excluded in only mode)
j10_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei --test-hosts only 2>/dev/null)
if printf '%s\n' "$j10_out" | grep -qF "192.168.139.110" 2>/dev/null && \
   ! printf '%s\n' "$j10_out" | grep -qF "192.168.139.119" 2>/dev/null; then
    _pass "J10  iis only: .110 在 Client IP 表; .119 (real gateway) 已排除"
else
    _fail "J10  iis only: .110 在 Client IP 表; .119 (real gateway) 已排除"
fi

# J11: iis all taichung 10.1.73.37 Total = 6 (/health identity: .73.37 has no test-host clients)
j11_out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung --test-hosts all 2>/dev/null)
j11_first=$(printf '%s\n' "$j11_out" | grep "Total requests" | awk '{print $NF}' | head -1)
_eq J11 "iis all taichung 10.1.73.37 Total = 6 (no test-host clients)" "$j11_first" "6"

# J12: access default exclude: .110 and .79 absent from output
j12_out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null)
if ! printf '%s\n' "$j12_out" | grep -qF "192.168.139.110" 2>/dev/null && \
   ! printf '%s\n' "$j12_out" | grep -qF "192.168.139.79" 2>/dev/null; then
    _pass "J12  access exclude: .110 和 .79 測試主機 IP 不出現於輸出"
else
    _fail "J12  access exclude: .110 和 .79 測試主機 IP 不出現於輸出"
fi

# J13: access --test-hosts only: .110 present in output
j13_out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --test-hosts only 2>/dev/null)
_has J13 "access --test-hosts only: .110 測試主機 IP 出現於輸出" "$j13_out" "192.168.139.110"

# J14: access --test-hosts all: .110 present; NORMAL count >= exclude (all >= exclude)
j14_out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --test-hosts all 2>/dev/null)
j14_norm=$(_sum "$j14_out" "NORMAL  (")
j12_norm=$(_sum "$j12_out" "NORMAL  (")
if printf '%s\n' "$j14_out" | grep -qF "192.168.139.110" 2>/dev/null && \
   (( j14_norm >= j12_norm )); then
    _pass "J14  access all: .110 出現; NORMAL (${j14_norm}) >= exclude (${j12_norm})"
else
    _fail "J14  access all: .110 出現 OR NORMAL (${j14_norm}) < exclude (${j12_norm})"
fi

# J15: access --test-hosts bogus → non-zero exit (assert_enum)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --test-hosts bogus >/dev/null 2>&1; rc_j15=$?
_err J15 "access --test-hosts bogus → non-zero exit (assert_enum)" "$rc_j15"

# J16: load_test_hosts reads exactly 7 test-host IP tokens from conf/test_hosts.conf
th_set=$(bash -c "source \"${PROJECT_DIR}/lib/common.sh\"; load_test_hosts \"${PROJECT_DIR}/conf/test_hosts.conf\"")
th_count=$(printf '%s\n' "$th_set" | wc -w | tr -d ' ')
_eq J16 "load_test_hosts 返回恰好 7 個測試主機 IP tokens" "$th_count" "7"

# J17: analyze_errors --test-hosts only → non-zero exit (Unknown option; no flag support)
bash "$ERRORS" --log-dir "$LOG_DIR" --date 2026-05-21 --test-hosts only >/dev/null 2>&1; rc_j17=$?
_err J17 "analyze_errors --test-hosts only → non-zero exit (Unknown option)" "$rc_j17"

# J18: log_report --test-hosts only: errors module OracleDB count == baseline (no-op on errors)
j18_out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --modules errors --test-hosts only 2>/dev/null)
j18_oracle=$(_sum "$j18_out" "OracleDB health failures")
_eq J18 "log_report --test-hosts only: errors OracleDB 計數 == 基準值 44 (no-op on errors)" "$j18_oracle" "44"

# J19: overview --test-hosts only: 核心功能存取合計 == 179 (glcr6+ds75+nhi98)
# Use grep -oE '[0-9]+' | head -1; _pick ($NF) would return "(100.0%)" for "179 (100.0%)".
j19_out=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 --test-hosts only 2>/dev/null)
j19_total=$(printf '%s\n' "$j19_out" | grep "核心功能存取合計" | grep -oE '[0-9]+' | head -1)
_eq J19 "overview --test-hosts only: 核心功能存取合計 == 179" "$j19_total" "179"

# J20: overview 預設 (exclude): 核心功能存取合計 == 624 (glcr11+ds186+nhi427)
# Use grep -oE '[0-9]+' | head -1; _pick ($NF) would return "(100.0%)" for "624 (100.0%)".
j20_out=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
j20_total=$(printf '%s\n' "$j20_out" | grep "核心功能存取合計" | grep -oE '[0-9]+' | head -1)
_eq J20 "overview 預設 (exclude): 核心功能存取合計 == 624" "$j20_total" "624"

# ─────────────────────────────────────────────────────────────────────────────
# Section K — timezone correction + core-function CATEGORY (K01–K16)
# Anchors (2026-05-21, --region all, +8h window, /health excluded):
#   IIS business total: exclude=723, only=209, all=932
#   CATEGORY (exclude): glcr=11/0.11s, ds=186/0.38s, nhi=427/0.93s, sum=624
#   CATEGORY (only):    glcr=6, ds=75, nhi=98, sum=179
#   Per-region (exclude): taipei glcr=5/0.02s ds=71/0.22s nhi=220/1.48s
#                         taichung glcr=6/0.19s ds=115/0.47s nhi=207/0.34s
#   (慢速 column removed; K13/K14 intentionally vacant — gap preserved)
# ─────────────────────────────────────────────────────────────────────────────

section "K  timezone correction + core-function CATEGORY"

# K01: TZ cross-midnight INCLUDED — synthetic fixture
# Rows: u_ex260520.log 16:30 UTC → local 00:30 (INCLUDED); u_ex260521.log 03:00 UTC → local 11:00 (INCLUDED)
_k01_dir=$(mktemp -d /tmp/lp_k01.XXXXXX)
printf '%s\n' "2026-05-20 16:30:00 10.0.0.1 GET /api/t1 - 443 - 1.2.3.4 - - 200 0 0 100 200 50" \
    > "${_k01_dir}/combined.log"
printf '%s\n' "2026-05-21 03:00:00 10.0.0.1 GET /api/t2 - 443 - 1.2.3.4 - - 200 0 0 100 200 30" \
    >> "${_k01_dir}/combined.log"
_k01_total=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/aggregate_utils.sh'
    agg_iis_rows '${_k01_dir}/combined.log' 2000 0 all '' '2026-05-20 16:00:00' '2026-05-21 16:00:00'
" 2>/dev/null | gawk -F'\t' '$1=="TOTAL"{print $2; exit}')
_eq K01 "TZ 跨午夜 INCLUDED: 16:30 UTC(+8=00:30) 及 03:00 UTC(+8=11:00) 均在窗口 TOTAL==2" \
    "${_k01_total:-0}" "2"
rm -rf "$_k01_dir"

# K02: TZ cross-midnight EXCLUDED — add 16:30 row on u_ex260521 (local 2026-05-22 → outside window)
_k02_dir=$(mktemp -d /tmp/lp_k02.XXXXXX)
printf '%s\n' "2026-05-20 16:30:00 10.0.0.1 GET /api/t1 - 443 - 1.2.3.4 - - 200 0 0 100 200 50" \
    > "${_k02_dir}/combined.log"
printf '%s\n' "2026-05-21 03:00:00 10.0.0.1 GET /api/t2 - 443 - 1.2.3.4 - - 200 0 0 100 200 30" \
    >> "${_k02_dir}/combined.log"
printf '%s\n' "2026-05-21 16:30:00 10.0.0.1 GET /api/t3 - 443 - 1.2.3.4 - - 200 0 0 100 200 20" \
    >> "${_k02_dir}/combined.log"
_k02_total=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/aggregate_utils.sh'
    agg_iis_rows '${_k02_dir}/combined.log' 2000 0 all '' '2026-05-20 16:00:00' '2026-05-21 16:00:00'
" 2>/dev/null | gawk -F'\t' '$1=="TOTAL"{print $2; exit}')
_eq K02 "TZ 跨午夜 EXCLUDED: 16:30 UTC on 0521 (local 2026-05-22) 不在窗口 TOTAL 仍==2" \
    "${_k02_total:-0}" "2"
rm -rf "$_k02_dir"

# K03: tz no-drift on real data — analyze_iis emit-stats Σ TOTAL == 723 (exclude mode)
k03_emit=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all --emit-stats 2>/dev/null)
k03_total=$(printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="TOTAL"{s+=$6} END{print s+0}')
_eq K03 "tz no-drift on real data: emit-stats Σ TOTAL == 723 (exclude)" "$k03_total" "723"

# K04: CATEGORY rows present — emit-stats contains one row per category key
k04_has_glcr=$(printf '%s\n' "$k03_emit" | grep -cF $'\tCATEGORY\tglcr\t' || true)
k04_has_ds=$(  printf '%s\n' "$k03_emit" | grep -cF $'\tCATEGORY\tds\t'   || true)
k04_has_nhi=$( printf '%s\n' "$k03_emit" | grep -cF $'\tCATEGORY\tnhi\t'  || true)
if [[ "$k04_has_glcr" -ge 1 && "$k04_has_ds" -ge 1 && "$k04_has_nhi" -ge 1 ]]; then
    _pass "K04  emit-stats 含 CATEGORY glcr, ds, nhi 各至少一列"
else
    _fail "K04  emit-stats 含 CATEGORY glcr, ds, nhi 各至少一列 [glcr=${k04_has_glcr} ds=${k04_has_ds} nhi=${k04_has_nhi}]"
fi

# K05: glcr anchor — Σ count == 11; Σsum_ms/Σcount/1000 == 0.11 (cross-server exact pooled avg)
k05_cnt=$(printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="glcr"{s+=$7} END{print s+0}')
k05_ms=$( printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="glcr"{s+=$8} END{print s+0}')
k05_avg=$(gawk -v ms="$k05_ms" -v c="${k05_cnt:-1}" 'BEGIN{printf "%.2f", ms/c/1000}')
_eq K05 "CATEGORY glcr count == 11"    "$k05_cnt" "11"
_eq K05b "CATEGORY glcr derived avg == 0.11 (exact pooled mean)" "$k05_avg" "0.11"

# K06: ds anchor — count 186, derived avg 0.38
k06_cnt=$(printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="ds"{s+=$7} END{print s+0}')
k06_ms=$( printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="ds"{s+=$8} END{print s+0}')
k06_avg=$(gawk -v ms="$k06_ms" -v c="${k06_cnt:-1}" 'BEGIN{printf "%.2f", ms/c/1000}')
_eq K06 "CATEGORY ds count == 186"    "$k06_cnt" "186"
_eq K06b "CATEGORY ds derived avg == 0.38 (exact pooled mean)" "$k06_avg" "0.38"

# K07: nhi anchor — count 427, derived avg 0.93; guards cross-server exact pooled mean
k07_cnt=$(printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="nhi"{s+=$7} END{print s+0}')
k07_ms=$( printf '%s\n' "$k03_emit" | gawk -F'\t' '$5=="CATEGORY"&&$6=="nhi"{s+=$8} END{print s+0}')
k07_avg=$(gawk -v ms="$k07_ms" -v c="${k07_cnt:-1}" 'BEGIN{printf "%.2f", ms/c/1000}')
_eq K07 "CATEGORY nhi count == 427"    "$k07_cnt" "427"
_eq K07b "CATEGORY nhi derived avg == 0.93 (cross-server exact pooled mean)" "$k07_avg" "0.93"

# K08: category NOT Top-N capped — --top 1 still emits all 3 distinct CATEGORY keys
# With 6 servers (all regions) each emitting 3 CATEGORY rows, total = 18.  The --top N
# cap limits ENDPOINT/CLIENT_IP rows but must NOT limit CATEGORY rows.  Count distinct
# category KEYS to prove all 3 (glcr, ds, nhi) are present regardless of --top value.
k08_emit=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all \
    --top 1 --emit-stats 2>/dev/null)
k08_cat_keys=$(printf '%s\n' "$k08_emit" | gawk -F'\t' '$5=="CATEGORY"{seen[$6]=1} END{print length(seen)}')
_eq K08 "CATEGORY rows not Top-N capped: --top 1 still emits all 3 distinct category keys" "$k08_cat_keys" "3"

# K09: overview 總體概況 含新格式 category rows (req1)
# New format: 呼叫次數 N / 回應時間 Xs (no share%, no parentheses after count)
# Anchors: glcr global 11/0.11s; 核心功能存取合計 624 (glcr11+ds186+nhi427)
k09_out=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
if printf '%s\n' "$k09_out" | grep -qF "雲端查詢" && \
   printf '%s\n' "$k09_out" | grep -qF "呼叫次數 11" && \
   printf '%s\n' "$k09_out" | grep -qF "回應時間 0.11s" && \
   printf '%s\n' "$k09_out" | grep -qF "核心功能存取合計" && \
   printf '%s\n' "$k09_out" | grep -qF "624"; then
    _pass "K09  overview 總體概況 含 雲端查詢, 呼叫次數 11, 回應時間 0.11s; 核心功能存取合計 624"
else
    _fail "K09  overview 總體概況 含 雲端查詢, 呼叫次數 11, 回應時間 0.11s; 核心功能存取合計 624"
fi

# K10: overview 總體概況 access value+% + lacks IIS 總請求數
if printf '%s\n' "$k09_out" | grep -qF "NORMAL 正常流程" && \
   printf '%s\n' "$k09_out" | grep -qF "6 (66.7%)" && \
   printf '%s\n' "$k09_out" | grep -qF "ORPHAN 無對應簽發" && \
   printf '%s\n' "$k09_out" | grep -qF "3 (33.3%)" && \
   printf '%s\n' "$k09_out" | grep -qF "UNVERIFIED 簽發未使用" && \
   printf '%s\n' "$k09_out" | grep -qF "0 (0.0%)"; then
    if ! printf '%s\n' "$k09_out" | grep -qF "IIS 總請求數"; then
        _pass "K10  總體概況 含 access value+%; 無 IIS 總請求數"
    else
        _fail "K10  總體概況 不應含 IIS 總請求數 (req5)"
    fi
else
    _fail "K10  總體概況 缺少 NORMAL/ORPHAN/UNVERIFIED value+%"
fi

# K11: 分區別 per-region category alignment — 影像下載 rows from both regions aligned
# New: repoint from 異常-column → 回應時間 column fixed via shared _render_cat_rows.
# Extracts 影像下載 rows from 分區別 section (台北 1.48s + 台中 0.34s); both aligned.
_k11_block=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null \
    | sed -n '/▶ 分區別/,$p' | grep "影像下載")
_eq K11 "分區別 per-region 影像下載 rows 回應時間欄 display-col 一致 (shared _render_cat_rows)" \
    "$(printf '%s' "$_k11_block" | _aligncols)" "1"

# K12: label trim (req2) — access NORMAL block has 驗證筆數; does NOT have 有效時間差
k12_out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null)
_has K12a "access NORMAL block 含 驗證筆數" "$k12_out" "驗證筆數"
_lacks K12 "access NORMAL block 不含 有效時間差 (label trimmed req2)" "$k12_out" "有效時間差"

# (K13/K14 intentionally vacant — gap preserved per commit history; K15/K16 continue past gap)

# K15: 分區別 台中 影像下載 per-region exact pooled avg == 0.34s
# Anchor: taichung nhi 207/0.34s (distinct from global 427/0.93s and taipei 220/1.48s)
k15_out=$(NO_COLOR=1 bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
k15_nhi=$(printf '%s\n' "$k15_out" | sed -n '/■ 台中/,$p' | grep "影像下載" | head -1)
_has K15 "分區別 台中 影像下載 回應時間 0.34s (per-region pooled avg distinct from global)" \
    "$k15_nhi" "回應時間 0.34s"

# K16: 總體概況 global category rows 呼叫次數+回應時間 (no share%); nhi anchor 427/0.93s
# (68.4%) was the old share% that must be absent.
k16_out=$(bash "$OVERVIEW" --log-dir "$LOG_DIR" --date 2026-05-21 2>/dev/null)
k16_block=$(printf '%s\n' "$k16_out" | sed -n '/▶ 總體概況/,/▶ 分區別/p')
if printf '%s\n' "$k16_block" | grep -qF "呼叫次數 427" && \
   printf '%s\n' "$k16_block" | grep -qF "回應時間 0.93s"; then
    if ! printf '%s\n' "$k16_block" | grep -qF "(68.4%)"; then
        _pass "K16  總體概況 含 呼叫次數 427 + 回應時間 0.93s; 無 (68.4%) 佔比"
    else
        _fail "K16  總體概況 不應含 (68.4%) 佔比 (req1 % 移除)"
    fi
else
    _fail "K16  總體概況 缺少 呼叫次數 427 或 回應時間 0.93s"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Section L — bin/log_report.sh --notify: SMTP-API report delivery (D12)
# Baselines (fixed date 2026-05-21, default modules overview,iis,access):
#   log_report.sh always persists exactly 6 files: access_detail.txt,
#   access_ip_counts.tsv, access_summary.txt, iis_detail.txt, iis_summary.txt,
#   overview_summary.txt. overview_summary.txt's KEY SUMMARY block contains
#   整體健康判定 and 核心功能存取合計 624 (same H/J/K anchors reused here) and
#   the ■ 存取紀錄橫條圖 bar-chart heading NOTIFY_BODY_AWK must stop before.
#   conf/receivers.conf ships exactly one row: Jason Chao / jason.chao@cohesiondata.com.
#   No test in this section ever contacts a real network endpoint: dry-run
#   never resolves curl at all, and every real-send test pins
#   LOG_PARSE_NOTIFY_CURL_BIN at a local fake-curl shim (below) that only
#   touches the local filesystem, never a socket.
# ─────────────────────────────────────────────────────────────────────────────

section "L  bin/log_report.sh --notify — SMTP-API report delivery (D12)"

# ---- Shared fixtures for this section ---------------------------------------

# _L_SRC_RUN: one real run directory (6 files), built once. Mechanism-3 tests
# below take a fresh `cp -r` copy each via _l_fixture rather than sharing this
# directory directly: a dry-run now writes notify_payload.json INSIDE the
# directory it enumerates (see notify_send's own ORCHESTRATOR OVERRIDE
# docblock comment), so re-using one directory across repeated dry-runs would
# let one test's leftover payload be picked up as a 7th attachment by the next.
_L_SRC=$(mktemp -d /tmp/lp_L_src.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$_L_SRC" >/dev/null 2>&1
_L_SRC_RUN=$(find "$_L_SRC" -mindepth 1 -maxdepth 1 -type d | head -1)

# _l_fixture: echo the path of a fresh, isolated copy of _L_SRC_RUN.
_l_fixture() {
    local d
    d=$(mktemp -d /tmp/lp_Lfix.XXXXXX)
    cp -r "${_L_SRC_RUN}/." "$d/"
    printf '%s' "$d"
}

# _L_SHIMDIR/fake_curl.sh: an offline stand-in for curl (spec §10.1 mechanism
# 2, G05-style inline fixture). Records one space-joined argv line per
# invocation to curl.calls (never the referenced payload file's CONTENT --
# only its "@path" argv token, which is the entire point of
# --data-binary @path, C11); counts invocations in curl.count; writes an
# empty response body to the path following --output; replies on stdout with
# a canned "%{http_code} %{time_total}" (mirrors curl --write-out); exits
# with the code in curl_rc (default 0, i.e. success). Never opens a socket.
_L_SHIMDIR=$(mktemp -d /tmp/lp_Lshim.XXXXXX)
cat > "${_L_SHIMDIR}/fake_curl.sh" <<'SHIMEOF'
#!/usr/bin/env bash
out="" prev=""
for a in "$@"; do
    if [[ "$prev" == "--output" ]]; then out="$a"; fi
    prev="$a"
done
{ printf '%s ' "$@"; printf '\n---\n'; } >> "${SHIM_LOG_DIR}/curl.calls"
printf 'x' >> "${SHIM_LOG_DIR}/curl.count"
if [[ -n "$out" ]]; then : > "$out"; fi
code=200
if [[ -f "${SHIM_LOG_DIR}/curl_code" ]]; then code="$(cat "${SHIM_LOG_DIR}/curl_code")"; fi
printf '%s %s' "$code" "0.010"
rc=0
if [[ -f "${SHIM_LOG_DIR}/curl_rc" ]]; then rc="$(cat "${SHIM_LOG_DIR}/curl_rc")"; fi
exit "$rc"
SHIMEOF
chmod +x "${_L_SHIMDIR}/fake_curl.sh"
export SHIM_LOG_DIR="$_L_SHIMDIR"

# _l_shim_reset: clear the shim's call log + canned response between tests.
_l_shim_reset() {
    : > "${_L_SHIMDIR}/curl.calls"
    : > "${_L_SHIMDIR}/curl.count"
    rm -f "${_L_SHIMDIR}/curl_rc" "${_L_SHIMDIR}/curl_code"
}

# L01: dependency is genuinely conditional -- curl missing never matters
# unless --notify is actually requested.
TMPD_L01=$(mktemp -d /tmp/lp_l01.XXXXXX)
LOG_PARSE_NOTIFY_CURL_BIN=curl-does-not-exist bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L01" \
    >/dev/null 2>/dev/null; rc=$?
l01_cnt=$(find "$TMPD_L01" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc" -eq 0 && "$l01_cnt" -eq 6 ]]; then
    _pass "L01  無 --notify 時 LOG_PARSE_NOTIFY_CURL_BIN 不存在也不影響：exit 0 且 6 檔"
else
    _fail "L01  依賴應為條件式 [rc=$rc files=$l01_cnt]"
fi
rm -rf "$TMPD_L01"

# L02: --notify --notify-dry-run exits 0 and logs an existing, mode-0600 path.
TMPD_L02=$(mktemp -d /tmp/lp_l02.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L02" \
    --notify --notify-dry-run >/dev/null 2>"${TMPD_L02}.stderr"; rc=$?
l02_path=$(grep -oE 'payload written: .*' "${TMPD_L02}.stderr" | sed 's/^payload written: //')
if [[ "$rc" -eq 0 && -n "$l02_path" && -f "$l02_path" \
      && "$(stat -c '%a' "$l02_path" 2>/dev/null)" == "600" ]]; then
    _pass "L02  --notify --notify-dry-run exit 0，payload written: 路徑存在且 mode 0600"
else
    _fail "L02  --notify-dry-run payload 檢查失敗 [rc=$rc path=${l02_path:-NONE}]"
fi
rm -rf "$TMPD_L02" "${TMPD_L02}.stderr"

# L03: GOLDEN PAYLOAD SHAPE -- PascalCase From/To/Subject/Body, Attachments is
# a map, and none of the removed contract tokens ever appear.
_d03=$(_l_fixture)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$_d03'
" >/dev/null 2>&1
_c03="$(cat "${_d03}/notify_payload.json" 2>/dev/null)"
if [[ "$_c03" == '{"From":{"DisplayName":"'* ]] \
   && [[ "$_c03" == *'","Address":"'* ]] \
   && [[ "$_c03" == *'"To":[{"DisplayName":"'* ]] \
   && [[ "$_c03" == *'"Subject":"【肺癌報告】'* ]] \
   && [[ "$_c03" == *'"Body":"'* ]] \
   && [[ "$_c03" == *'"Attachments":{'* ]] \
   && [[ "$_c03" == *'}}' ]] \
   && [[ "$_c03" != *'isBodyHtml'* ]] \
   && [[ "$_c03" != *'"cc"'* ]] \
   && [[ "$_c03" != *'"bcc"'* ]] \
   && [[ "$_c03" != *'fileName'* ]] \
   && [[ "$_c03" != *'contentBase64'* ]]; then
    _pass "L03  GOLDEN PAYLOAD SHAPE：From/To/Subject/Body/Attachments 齊全，無禁用欄位"
else
    _fail "L03  GOLDEN PAYLOAD SHAPE 檢查失敗"
fi
rm -rf "$_d03"

# L04: default attach scope is all -- key count equals the run's 6 files,
# and access_detail.txt is among them.
_d04=$(_l_fixture)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$_d04'
" >/dev/null 2>&1
l04_keys=$(grep -oE '"[^"]+":"[A-Za-z0-9+/=]*"' "${_d04}/notify_payload.json" | wc -l | tr -d ' ')
if [[ "$l04_keys" -eq 6 ]] && grep -qF '"access_detail.txt":"' "${_d04}/notify_payload.json"; then
    _pass "L04  預設 attach scope = all：6 個附件 key，含 access_detail.txt"
else
    _fail "L04  預設 attach scope 應為 all [keys=$l04_keys]"
fi
rm -rf "$_d04"

# L05: --notify-attach summary narrows to the 3 *_summary.txt files;
# access_detail.txt is not a key.
_d05=$(_l_fixture)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=summary
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$_d05'
" >/dev/null 2>&1
l05_keys=$(grep -oE '"[^"]+":"[A-Za-z0-9+/=]*"' "${_d05}/notify_payload.json" | wc -l | tr -d ' ')
if [[ "$l05_keys" -eq 3 ]] && ! grep -qF '"access_detail.txt":"' "${_d05}/notify_payload.json"; then
    _pass "L05  --notify-attach summary：3 個附件 key，access_detail.txt 不在其中"
else
    _fail "L05  --notify-attach summary 應窄化為 3 [keys=$l05_keys]"
fi
rm -rf "$_d05"

# L06: boundary -- fixture dir with only a *_detail file, mode summary ->
# empty Attachments map + explicit "no summary available" body fallback.
TMPD_L06=$(mktemp -d /tmp/lp_l06.XXXXXX)
printf 'hello world\n' > "${TMPD_L06}/foo_detail.tsv"
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=summary
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L06'
" >/dev/null 2>/dev/null; rc=$?
if [[ "$rc" -eq 0 ]] \
   && grep -qF '"Attachments":{}' "${TMPD_L06}/notify_payload.json" \
   && grep -qF '(no summary view available for this run)' "${TMPD_L06}/notify_payload.json"; then
    _pass "L06  邊界：僅 *_detail 檔且 mode=summary -> Attachments:{} 且 body 顯示無摘要可用"
else
    _fail "L06  邊界情境檢查失敗 [rc=$rc]"
fi
rm -rf "$TMPD_L06"

# L07: a 3-byte file abc.txt produces the exact pair "abc.txt":"YWJj".
TMPD_L07=$(mktemp -d /tmp/lp_l07.XXXXXX)
printf 'abc' > "${TMPD_L07}/abc.txt"
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L07'
" >/dev/null 2>/dev/null
_has L07 "3-byte abc.txt -> 精確配對 \"abc.txt\":\"YWJj\"" \
    "$(cat "${TMPD_L07}/notify_payload.json" 2>/dev/null)" '"abc.txt":"YWJj"'
rm -rf "$TMPD_L07"

# L08: body carries the run's real KEY SUMMARY (never boilerplate).
_d08=$(_l_fixture)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$_d08'
" >/dev/null 2>&1
_c08="$(cat "${_d08}/notify_payload.json" 2>/dev/null)"
if [[ "$_c08" == *'整體健康判定'* && "$_c08" == *'核心功能存取合計'* ]]; then
    _pass "L08  body 含真實 KEY SUMMARY (整體健康判定 + 核心功能存取合計)"
else
    _fail "L08  body 缺少 KEY SUMMARY 關鍵字"
fi
rm -rf "$_d08"

# L09: body excludes the hourly bar chart and carries zero ANSI ESC bytes
# (I08 idiom: grep -cP '\x1b').
_d09=$(_l_fixture)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$_d09'
" >/dev/null 2>&1
l09_p="${_d09}/notify_payload.json"
l09_esc=$(grep -cP '\x1b' "$l09_p" 2>/dev/null || true)
if ! grep -qF '存取紀錄橫條圖' "$l09_p" && [[ "${l09_esc:-0}" -eq 0 ]]; then
    _pass "L09  body 不含 存取紀錄橫條圖，且無 ANSI ESC 位元組 (I08 idiom)"
else
    _fail "L09  body 應排除橫條圖且無 ESC [esc=${l09_esc:-?}]"
fi
rm -rf "$_d09"

# L10: stdout of --notify --notify-dry-run is byte-identical to the same run
# without the flags (rule 3 -- notify never touches stdout).
TMPD_L10A=$(mktemp -d /tmp/lp_l10a.XXXXXX)
TMPD_L10B=$(mktemp -d /tmp/lp_l10b.XXXXXX)
out10a=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L10A" 2>/dev/null)
out10b=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L10B" \
    --notify --notify-dry-run 2>/dev/null)
if [[ "$out10a" == "$out10b" ]]; then
    _pass "L10  --notify --notify-dry-run 之 stdout 與未加旗標逐位元組相同 (rule 3)"
else
    _fail "L10  --notify --notify-dry-run 之 stdout 應與未加旗標相同"
fi
rm -rf "$TMPD_L10A" "$TMPD_L10B"

# L11: shimmed real send on a 4-module run -- the shim fires exactly once with
# the expected argv shape, and no module ever received a --notify* argument.
# (Non-forwarding is doubly proven: build_module_args never adds --notify*, and
# if it somehow had, the receiving analyze_* would die on "Unknown option" and
# main() would abort under set -e before ever reaching notify_run -- so the
# shim would show ZERO calls, not one. C11: no payload byte on argv.)
_l_shim_reset
TMPD_L11=$(mktemp -d /tmp/lp_l11.XXXXXX)
LOG_PARSE_NOTIFY_CURL_BIN="${_L_SHIMDIR}/fake_curl.sh" bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L11" \
    --modules overview,iis,access,errors --notify >/dev/null 2>"${TMPD_L11}.stderr"
l11_calls=$(cat "${_L_SHIMDIR}/curl.calls" 2>/dev/null)
l11_ncalls=$(wc -c < "${_L_SHIMDIR}/curl.count" 2>/dev/null | tr -d ' ')
if [[ "${l11_ncalls:-0}" -eq 1 ]] \
   && [[ "$l11_calls" == *'--data-binary @'* ]] \
   && [[ "$l11_calls" == *'http://haididev.intra.nhi.gov.tw:8080/api/email/send'* ]] \
   && [[ "$l11_calls" != *'Attachments'* ]]; then
    _pass "L11  shim curl 恰呼叫一次；argv 含 --data-binary @ 與 URL 且無 payload 位元組；子模組未收到 --notify*"
else
    _fail "L11  shim/非轉發檢查失敗 [ncalls=${l11_ncalls:-0}]"
fi
rm -rf "$TMPD_L11" "${TMPD_L11}.stderr"

# L12: escaping round-trip, keys included -- From identity with a quote+
# backslash (also regression-pins the gawk -v backslash-doubling fix), a
# filename that is itself a JSON key containing a quote, and
# LOG_PARSE_NOTIFY_SUBJECT containing TAB + newline + CJK.
TMPD_L12=$(mktemp -d /tmp/lp_l12.XXXXXX)
printf 'weird\n' > "${TMPD_L12}/we\"ird.txt"
LOG_PARSE_NOTIFY_FROM_NAME='Jason "Bad\Name"' \
LOG_PARSE_NOTIFY_SUBJECT=$'Subj\twith\nCJK 台北' \
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L12'
" >/dev/null 2>&1
_c12="$(cat "${TMPD_L12}/notify_payload.json" 2>/dev/null)"
if [[ "$_c12" == *'Jason \"Bad\\Name\"'* ]] \
   && [[ "$_c12" == *'"we\"ird.txt":"'* ]] \
   && [[ "$_c12" == *'\t'* ]] \
   && [[ "$_c12" == *'\n'* ]] \
   && [[ "$_c12" == *'台北'* ]]; then
    _pass "L12  escaping round-trip：From 引號+反斜線、檔名 key、Subject TAB/換行/CJK 均正確"
else
    _fail "L12  escaping round-trip 檢查失敗"
fi
rm -rf "$TMPD_L12"

# L13: real-send payload is mode 0600 and lives OUTSIDE the run directory
# (under WORK_TMPDIR) -- unlike the dry-run payload, which the documented
# ORCHESTRATOR OVERRIDE deliberately places inside the run dir instead (see
# L02/L14 for that half of the contract).
_l_shim_reset
TMPD_L13=$(mktemp -d /tmp/lp_l13.XXXXXX)
printf 'x' > "${TMPD_L13}/f.txt"
_l13_res=$(SHIM_LOG_DIR="$_L_SHIMDIR" LOG_PARSE_NOTIFY_CURL_BIN="${_L_SHIMDIR}/fake_curl.sh" bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=0; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://haididev.intra.nhi.gov.tw:8080/api/email/send'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L13' >/dev/null 2>&1
    if [[ -f \"\$NOTIFY_PAYLOAD_PATH\" ]]; then
        printf '%s %s\n' \"\$(stat -c '%a' \"\$NOTIFY_PAYLOAD_PATH\")\" \"\$NOTIFY_PAYLOAD_PATH\"
    fi
")
l13_mode="${_l13_res%% *}"
l13_path="${_l13_res#* }"
if [[ "$l13_mode" == "600" && -n "$l13_path" && "$l13_path" != "${TMPD_L13}"/* ]]; then
    _pass "L13  正式送出 payload mode 0600，路徑不在 run dir 內 (WORK_TMPDIR)"
else
    _fail "L13  正式送出 payload mode/路徑檢查失敗 [mode=$l13_mode path=$l13_path]"
fi
rm -rf "$TMPD_L13"

# L14: a real (shimmed) send never changes the run dir's persisted file count
# (preserves the I12 "nothing transient in RUN_OUTPUT_DIR" invariant). Tested
# against a real send rather than dry-run, since Override #1 deliberately
# makes the DRY-RUN payload the one documented exception to that invariant
# (see L02/L13); this test guards the invariant for the path where it still
# holds unconditionally.
_l_shim_reset
TMPD_L14A=$(mktemp -d /tmp/lp_l14a.XXXXXX)
TMPD_L14B=$(mktemp -d /tmp/lp_l14b.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L14A" >/dev/null 2>&1
LOG_PARSE_NOTIFY_CURL_BIN="${_L_SHIMDIR}/fake_curl.sh" bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L14B" --notify >/dev/null 2>&1
l14a_cnt=$(find "$TMPD_L14A" -type f 2>/dev/null | wc -l | tr -d ' ')
l14b_cnt=$(find "$TMPD_L14B" -type f 2>/dev/null | wc -l | tr -d ' ')
_eq L14 "run dir 檔案數與 --notify(正式送出) 無關 (I12 持久化不變量)" "$l14b_cnt" "$l14a_cnt"
rm -rf "$TMPD_L14A" "$TMPD_L14B"

# L15: a 0-byte file is SKIPPED, counted, and never becomes an attachment key.
TMPD_L15=$(mktemp -d /tmp/lp_l15.XXXXXX)
: > "${TMPD_L15}/empty.txt"
printf 'x' > "${TMPD_L15}/nonempty.txt"
out15=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L15'
" 2>&1); rc=$?
_c15="$(cat "${TMPD_L15}/notify_payload.json" 2>/dev/null)"
if [[ "$rc" -eq 0 ]] \
   && printf '%s\n' "$out15" | grep -qF 'skipped_empty=1' \
   && [[ "$_c15" != *'"empty.txt":"'* ]]; then
    _pass "L15  0-byte 檔案 SKIPPED，skipped_empty=1，未成為附件 key (exit 0)"
else
    _fail "L15  0-byte 檔案處理檢查失敗 [rc=$rc]"
fi
rm -rf "$TMPD_L15"

# L16: From identity -- default 系統通知/notify@nhi.gov.tw; env override wins.
TMPD_L16A=$(mktemp -d /tmp/lp_l16a.XXXXXX)
printf 'x' > "${TMPD_L16A}/f.txt"
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L16A'
" >/dev/null 2>&1
TMPD_L16B=$(mktemp -d /tmp/lp_l16b.XXXXXX)
printf 'x' > "${TMPD_L16B}/f.txt"
LOG_PARSE_NOTIFY_FROM_NAME='維運' LOG_PARSE_NOTIFY_FROM_ADDR='ops@nhi.gov.tw' bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L16B'
" >/dev/null 2>&1
_c16a="$(cat "${TMPD_L16A}/notify_payload.json" 2>/dev/null)"
_c16b="$(cat "${TMPD_L16B}/notify_payload.json" 2>/dev/null)"
if [[ "$_c16a" == '{"From":{"DisplayName":"系統通知","Address":"notify@nhi.gov.tw"},'* ]] \
   && [[ "$_c16b" == '{"From":{"DisplayName":"維運","Address":"ops@nhi.gov.tw"},'* ]]; then
    _pass "L16  From 身分：預設 系統通知/notify@nhi.gov.tw；覆寫後 維運/ops@nhi.gov.tw"
else
    _fail "L16  From 身分預設/覆寫檢查失敗"
fi
rm -rf "$TMPD_L16A" "$TMPD_L16B"

# L17: per-file cap breach -- nothing sent, no curl call at all.
_l_shim_reset
TMPD_L17=$(mktemp -d /tmp/lp_l17.XXXXXX)
out17=$(LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES=16 \
    LOG_PARSE_NOTIFY_CURL_BIN="${_L_SHIMDIR}/fake_curl.sh" bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L17" \
    --notify 2>&1 >/dev/null); rc=$?
l17_calls=$(wc -c < "${_L_SHIMDIR}/curl.calls" 2>/dev/null | tr -d ' ')
if [[ "$rc" -ne 0 ]] \
   && printf '%s\n' "$out17" | grep -qF 'status=skipped' \
   && printf '%s\n' "$out17" | grep -qF 'reason=attachment_too_large:' \
   && [[ "${l17_calls:-1}" -eq 0 ]]; then
    _pass "L17  單檔超過上限：status=skipped，curl 從未被呼叫，log_report 非零 exit"
else
    _fail "L17  容量上限檢查失敗 [rc=$rc curl_calls_bytes=${l17_calls:-?}]"
fi
rm -rf "$TMPD_L17"

# L18: fatal on send failure -- shim exit 22 propagates to a die, with the
# NOTIFY_RESULT marker and no stale bin/send_report.sh resend advice.
_l_shim_reset
echo 22 > "${_L_SHIMDIR}/curl_rc"
TMPD_L18=$(mktemp -d /tmp/lp_l18.XXXXXX)
out18=$(LOG_PARSE_NOTIFY_CURL_BIN="${_L_SHIMDIR}/fake_curl.sh" bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L18" \
    --notify 2>&1 >/dev/null); rc=$?
if [[ "$rc" -ne 0 ]] \
   && printf '%s\n' "$out18" | grep -qF 'NOTIFY_RESULT status=failed' \
   && printf '%s\n' "$out18" | grep -qF 'reports are intact in' \
   && ! printf '%s\n' "$out18" | grep -qF 'send_report'; then
    _pass "L18  送出失敗應 fatal：status=failed、reports are intact in，且無 send_report 建議"
else
    _fail "L18  送出失敗 fatal 檢查失敗 [rc=$rc]"
fi
rm -rf "$TMPD_L18"
rm -f "${_L_SHIMDIR}/curl_rc"

# L19: determinism -- two dry-runs over the SAME fixture dir (leftover payload
# removed between runs, restoring the enumerated precondition -- see the
# ORCHESTRATOR OVERRIDE note on L13) produce byte-identical payloads; also
# pins that Subject derives from the resolved interval, never send-time date.
TMPD_L19=$(_l_fixture)
# FIX J: stage the first payload under a dedicated mktemp -d directory --
# never a literal /tmp/<name> path (bash.md: "Never hardcode /tmp/foo").
TMPD_L19STAGE=$(mktemp -d /tmp/lp_l19_stage.XXXXXX)
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L19'
" >/dev/null 2>&1
cp "${TMPD_L19}/notify_payload.json" "${TMPD_L19STAGE}/p1.json"
rm -f "${TMPD_L19}/notify_payload.json"
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L19'
" >/dev/null 2>&1
cmp -s "${TMPD_L19STAGE}/p1.json" "${TMPD_L19}/notify_payload.json"; l19_rc=$?
_eq L19 "同一 fixture 兩次 dry-run 產生逐位元組相同的 payload (determinism)" "$l19_rc" "0"
rm -rf "$TMPD_L19" "$TMPD_L19STAGE"

# L20: load_receivers -- a messy fixture (inline/indented comments,
# whitespace-only line, CRLF, padded fields) normalises identically to a
# clean fixture; the shipped conf/receivers.conf yields exactly one row.
TMPD_L20=$(mktemp -d /tmp/lp_l20.XXXXXX)
printf 'Jason Chao|jason.chao@cohesiondata.com\n' > "${TMPD_L20}/clean.conf"
printf '# whole-line comment\r\n   # indented comment\r\n   \r\nJason Chao   |   jason.chao@cohesiondata.com   # inline comment\r\n' \
    > "${TMPD_L20}/messy.conf"
l20_clean=$(bash -c "source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/notify_utils.sh'; load_receivers '${TMPD_L20}/clean.conf'")
l20_messy=$(bash -c "source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/notify_utils.sh'; load_receivers '${TMPD_L20}/messy.conf'")
l20_shipped=$(bash -c "source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/notify_utils.sh'; load_receivers '${PROJECT_DIR}/conf/receivers.conf'")
if [[ "$l20_messy" == "$l20_clean" ]] \
   && [[ "$l20_shipped" == $'Jason Chao\tjason.chao@cohesiondata.com' ]]; then
    _pass "L20  load_receivers：亂格式 fixture 與乾淨 fixture 輸出相同；已上線 conf 恰一行"
else
    _fail "L20  load_receivers 正規化檢查失敗"
fi
rm -rf "$TMPD_L20"

# L21: subject derivation -- single-day, multi-day, and env-override forms.
l21_single=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    INTERVAL_ARGS=(--date 2026-05-21); notify_subject
")
l21_multi=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    INTERVAL_ARGS=(--from 2026-05-18 --to 2026-05-25); notify_subject
")
l21_override=$(LOG_PARSE_NOTIFY_SUBJECT='X' bash -c "
    source '${PROJECT_DIR}/lib/common.sh'; source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    INTERVAL_ARGS=(--date 2026-05-21); notify_subject
")
if [[ "$l21_single" == "【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-21" ]] \
   && [[ "$l21_multi" == "【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-18 ~ 2026-05-25" ]] \
   && [[ "$l21_override" == "X" ]]; then
    _pass "L21  Subject 推導：單日/多日格式正確，LOG_PARSE_NOTIFY_SUBJECT 覆寫優先"
else
    _fail "L21  Subject 推導檢查失敗 [single=$l21_single multi=$l21_multi override=$l21_override]"
fi

# L22: To is an array built from receivers.conf in file order; an empty
# display name renders as "" (never omitted).
TMPD_L22=$(mktemp -d /tmp/lp_l22.XXXXXX)
printf 'x' > "${TMPD_L22}/f.txt"
TMPD_L22CONF=$(mktemp -d /tmp/lp_l22conf.XXXXXX)
printf '|noname@example.com\nBob Lee|bob@example.com\n' > "${TMPD_L22CONF}/receivers.conf"
bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${TMPD_L22CONF}/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L22'
" >/dev/null 2>&1
_c22="$(cat "${TMPD_L22}/notify_payload.json" 2>/dev/null)"
l22_expect='"To":[{"DisplayName":"","Address":"noname@example.com"},{"DisplayName":"Bob Lee","Address":"bob@example.com"}]'
if [[ "$_c22" == *"$l22_expect"* ]]; then
    _pass "L22  To 陣列依 receivers.conf 檔案順序；空白 DisplayName 呈現為 \"\" (非省略)"
else
    _fail "L22  To 陣列順序/空白 DisplayName 檢查失敗"
fi
rm -rf "$TMPD_L22" "$TMPD_L22CONF"

# ── Regression tests for the multi-lens adversarial-review fixes (below) ────

# L23: FIX A regression (1/2) -- a backslash inside --output-dir (a live risk
# on this OneDrive/WSL-mounted tree) must not corrupt attachment size
# probing. Before the fix, gawk's `-v f="$path"` C-string-unescaped the
# backslash, silently mis-resolving the path, so every report file measured
# 0 bytes, all six were dropped as "empty", Attachments was {}, and the run
# still logged status=sent/dry-run -- a false-success report (CLAUDE.md
# rule 1). raw_bytes in the NOTIFY_RESULT line is cross-checked against the
# files' true on-disk size.
TMPD_L23_BASE=$(mktemp -d /tmp/lp_l23.XXXXXX)
TMPD_L23="${TMPD_L23_BASE}/back\\slash"
mkdir -p "$TMPD_L23"
out23=$(LOG_PARSE_RUN_TS=20260521_150000 bash "$REPORT" \
    --log-dir "$LOG_DIR" --date 2026-05-21 --output-dir "$TMPD_L23" \
    --notify --notify-dry-run 2>&1 >/dev/null); rc23=$?
run23="${TMPD_L23}/20260521_150000"
l23_keys=$(grep -oE '"[^"]+":"[A-Za-z0-9+/=]*"' "${run23}/notify_payload.json" 2>/dev/null | wc -l | tr -d ' ')
l23_disk_bytes=$(cat "${run23}"/access_detail.txt "${run23}"/access_ip_counts.tsv "${run23}"/access_summary.txt \
    "${run23}"/iis_detail.txt "${run23}"/iis_summary.txt "${run23}"/overview_summary.txt 2>/dev/null \
    | wc -c | tr -d ' ')
l23_raw=$(printf '%s\n' "$out23" | grep -oE 'raw_bytes=[0-9]+' | head -1 | cut -d= -f2)
if [[ "$rc23" -eq 0 ]] && [[ "$l23_keys" -eq 6 ]] \
   && [[ -n "$l23_raw" ]] && [[ "${l23_raw:-0}" -gt 0 ]] && [[ "$l23_raw" -eq "$l23_disk_bytes" ]]; then
    _pass "L23  FIX A：--output-dir 含反斜線仍附加全部 6 檔，raw_bytes 與磁碟實際位元組相符 ($l23_raw)"
else
    _fail "L23  FIX A 反斜線路徑檢查失敗 [rc=$rc23 keys=$l23_keys raw=$l23_raw disk=$l23_disk_bytes]"
fi
rm -rf "$TMPD_L23_BASE"

# L24: FIX A regression (2/2) -- an attachment that EXISTS (passes the `-f`
# check) but cannot actually be read must be fatal, never a silent
# "0 bytes -> SKIPPED -> status=sent" false success. Simulated with
# chmod 000 (this suite runs as a non-root user; verified separately that
# chmod 000 genuinely blocks even the owner's read on this host).
TMPD_L24=$(_l_fixture)
chmod 000 "${TMPD_L24}/access_detail.txt"
out24=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L24'
" 2>&1); rc24=$?
chmod 700 "${TMPD_L24}/access_detail.txt"   # restore first so cleanup rm -rf never fails
if [[ "$rc24" -ne 0 ]] \
   && printf '%s\n' "$out24" | grep -qF "could not read attachment for size probe" \
   && ! printf '%s\n' "$out24" | grep -qF "status=sent" \
   && ! printf '%s\n' "$out24" | grep -qF "status=dry-run"; then
    _pass "L24  FIX A：無法讀取的附件應 die，絕不降級為 status=sent/dry-run"
else
    _fail "L24  FIX A 無法讀取附件檢查失敗 [rc=$rc24]"
fi
rm -rf "$TMPD_L24"

# L25: FIX B regression -- two --notify-dry-run runs sharing ONE directory
# via a pinned LOG_PARSE_RUN_TS (a documented, supported knob,
# lib/output_utils.sh) must not let the second run attach the first run's
# leftover notify_payload.json as a 7th attachment.
TMPD_L25=$(mktemp -d /tmp/lp_l25.XXXXXX)
LOG_PARSE_RUN_TS=20260521_160000 bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_L25" --notify --notify-dry-run >/dev/null 2>&1
LOG_PARSE_RUN_TS=20260521_160000 bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --output-dir "$TMPD_L25" --notify --notify-dry-run >/dev/null 2>&1; rc25=$?
run25="${TMPD_L25}/20260521_160000"
l25_keys=$(grep -oE '"[^"]+":"[A-Za-z0-9+/=]*"' "${run25}/notify_payload.json" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$rc25" -eq 0 ]] && [[ "$l25_keys" -eq 6 ]] \
   && ! grep -qF '"notify_payload.json":"' "${run25}/notify_payload.json"; then
    _pass "L25  FIX B：pinned LOG_PARSE_RUN_TS 下第二次 dry-run 不會把前次 payload 當附件 (仍 6 個)"
else
    _fail "L25  FIX B pinned RUN_TS 重跑檢查失敗 [rc=$rc25 keys=$l25_keys]"
fi
rm -rf "$TMPD_L25"

# L26: FIX C regression -- a receivers.conf row with an empty DISPLAY_NAME
# must still produce a correct To entry (shape already covered by L22) AND
# still be considered by the external-recipient audit. Before the fix, TAB
# is bash IFS *whitespace* regardless of what IFS is set to, so
# `IFS=$'\t' read -r rname raddr` silently stripped the leading tab and
# shifted the address into rname, leaving raddr empty and the row silently
# skipped from the audit entirely.
TMPD_L26=$(mktemp -d /tmp/lp_l26.XXXXXX)
printf 'x' > "${TMPD_L26}/f.txt"
TMPD_L26CONF=$(mktemp -d /tmp/lp_l26conf.XXXXXX)
printf '|noname@external-example.com\n' > "${TMPD_L26CONF}/receivers.conf"
out26=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${TMPD_L26CONF}/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L26'
" 2>&1 >/dev/null)
_c26="$(cat "${TMPD_L26}/notify_payload.json" 2>/dev/null)"
if [[ "$_c26" == *'"To":[{"DisplayName":"","Address":"noname@external-example.com"}]'* ]] \
   && printf '%s\n' "$out26" | grep -qF "recipient on external domain: noname@external-example.com"; then
    _pass "L26  FIX C：空白 DisplayName 列同時產生正確 To 項目與外部網域稽核警告"
else
    _fail "L26  FIX C 空白 DisplayName 稽核檢查失敗"
fi
rm -rf "$TMPD_L26" "$TMPD_L26CONF"

# _l_utf8_tail_ok FILE NOTICE -- prints "ok" if FILE's content, with the
# exact trailing string NOTICE first stripped off (if present), does not
# end mid-UTF-8-sequence; prints a "bad_*" diagnostic otherwise. Used only
# by L27 (FIX D); reuses the same byte-ordinal-table trick as this file's
# own jesc_init(), applied here purely for test verification.
_l_utf8_tail_ok() {
    local file="$1" notice="$2"
    LC_ALL=C gawk -v f="$file" -v notice="$notice" '
        BEGIN {
            for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
            while ((getline line < f) > 0) content = (content == "") ? line : content "\n" line
            nlen = length(notice)
            if (nlen > 0 && nlen <= length(content) \
                && substr(content, length(content) - nlen + 1) == notice) {
                content = substr(content, 1, length(content) - nlen)
            }
            n = length(content)
            if (n == 0) { print "ok"; exit }
            i = n; cont = 0
            while (i >= 1 && cont < 4) {
                b = ORD[substr(content, i, 1)]
                if (b < 128 || b > 191) break
                cont++; i--
            }
            if (i < 1) { print "bad_all_continuation"; exit }
            b = ORD[substr(content, i, 1)]
            if (cont == 0) {
                if (b >= 192) { print "bad_dangling_leader"; exit }
                print "ok"; exit
            }
            need = 0
            if (b >= 194 && b <= 223) need = 1
            else if (b >= 224 && b <= 239) need = 2
            else if (b >= 240 && b <= 244) need = 3
            else { print "bad_orphan_continuation"; exit }
            if (need == cont) print "ok"; else print "bad_need" need "_cont" cont
        }
    '
}

# L27: FIX D regression -- body truncation must never split a multi-byte
# UTF-8 sequence. NOTIFY_MAX_BODY_BYTES is reassigned after sourcing (a
# plain var, deliberately not `readonly` -- see this file's own header
# comment) to a small cap so the fixture can stay tiny. Three paddings (0,
# 1, 2 extra ASCII bytes before a long run of the 3-byte CJK character 測)
# shift the naive byte-wise cut through all 3 possible alignments relative
# to a 3-byte character, so at least one iteration would have split a
# character under the pre-fix plain substr().
l27_notice="... [body truncated at 200 bytes]"$'\n'
l27_ok=1
l27_detail=""
for pad in 0 1 2; do
    TMPD_L27=$(mktemp -d /tmp/lp_l27.XXXXXX)
    padstr=""
    for (( _p27 = 0; _p27 < pad; _p27++ )); do padstr="${padstr}X"; done
    gawk -v p="$padstr" 'BEGIN {
        s = p
        for (i = 0; i < 200; i++) s = s "測"
        print "▶ 總體概況"
        print s
    }' > "${TMPD_L27}/overview_summary.txt"
    bash -c "
        source '${PROJECT_DIR}/lib/common.sh'
        source '${PROJECT_DIR}/lib/date_utils.sh'
        source '${PROJECT_DIR}/lib/output_utils.sh'
        source '${PROJECT_DIR}/lib/notify_utils.sh'
        NOTIFY_MAX_BODY_BYTES=200
        RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
        OPT_REGION='all'; OPT_MODULES='overview,iis,access'; OPT_NOTIFY_ATTACH=all
        RUN_OUTPUT_DIR='${TMPD_L27}'
        notify_build_body '${TMPD_L27}' '${TMPD_L27}/body.txt'
    " >/dev/null 2>&1
    l27_res="$(_l_utf8_tail_ok "${TMPD_L27}/body.txt" "$l27_notice")"
    if [[ "$l27_res" != "ok" ]]; then l27_ok=0; l27_detail="pad=${pad}:${l27_res}"; fi
    rm -rf "$TMPD_L27"
done
if [[ "$l27_ok" -eq 1 ]]; then
    _pass "L27  FIX D：body 截斷一律落在合法 UTF-8 邊界 (3 種位移量皆驗證)"
else
    _fail "L27  FIX D：body 截斷可能切斷多位元組 UTF-8 序列 [$l27_detail]"
fi

# L28: FIX E regression -- a file with NO trailing newline must report its
# TRUE byte count, not one byte more. The old `n += length(line) + 1`
# per-line idiom assumed every file ends in LF; `printf 'abc'` (3 bytes, no
# trailing newline) would have been over-counted as 4. Checked both at the
# helper level and end-to-end via a real dry-run's NOTIFY_RESULT line.
TMPD_L28=$(mktemp -d /tmp/lp_l28.XXXXXX)
printf 'abc' > "${TMPD_L28}/noeol.txt"
l28_direct=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    _notify_file_bytes '${TMPD_L28}/noeol.txt'
")
out28=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/date_utils.sh'
    source '${PROJECT_DIR}/lib/output_utils.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    OPT_NOTIFY=1; OPT_NOTIFY_DRY_RUN=1; OPT_NOTIFY_ATTACH=all
    OPT_NOTIFY_URL='http://127.0.0.1:9/x'
    RECEIVERS_CONF='${PROJECT_DIR}/conf/receivers.conf'
    RUN_TS='20260521_090000'; INTERVAL_ARGS=(--date 2026-05-21)
    OPT_REGION='all'; OPT_MODULES='overview,iis,access'
    notify_send '$TMPD_L28'
" 2>&1 >/dev/null)
if [[ "$l28_direct" == "3" ]] && printf '%s\n' "$out28" | grep -qF "raw_bytes=3 "; then
    _pass "L28  FIX E：無結尾換行的 3-byte 檔案於 helper 與完整 dry-run 皆回報真實位元組數 3"
else
    _fail "L28  FIX E 無結尾換行位元組數檢查失敗 [direct=$l28_direct]"
fi
rm -rf "$TMPD_L28"

# L29: FIX I regression -- a filename containing a TAB byte must die at
# collection time (it would otherwise corrupt the manifest's own
# `IFS=$'\t' read -r tag name bytes path` parsing), not silently attach
# with a garbled name.
TMPD_L29=$(mktemp -d /tmp/lp_l29.XXXXXX)
badname="bad$(printf '\t')name.txt"
printf 'x' > "${TMPD_L29}/${badname}"
out29=$(bash -c "
    source '${PROJECT_DIR}/lib/common.sh'
    source '${PROJECT_DIR}/lib/notify_utils.sh'
    notify_collect_attachments '$TMPD_L29' all '${TMPD_L29}/manifest.tsv'
" 2>&1); rc29=$?
if [[ "$rc29" -ne 0 ]] && printf '%s\n' "$out29" | grep -qF "contains a TAB or newline byte"; then
    _pass "L29  FIX I：檔名含 TAB 應於收集階段 die，避免破壞附件清單 TSV"
else
    _fail "L29  FIX I 檔名含 TAB 檢查失敗 [rc=$rc29]"
fi
rm -rf "$TMPD_L29"

# ---- Section L cleanup ------------------------------------------------------
rm -rf "$_L_SRC" "$_L_SHIMDIR"
unset SHIM_LOG_DIR

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "========================================================================"
TOTAL=$(( PASS + FAIL ))
printf "  Results: %d/%d passed\n" "$PASS" "$TOTAL"
if (( FAIL > 0 )); then
    echo "  FAILED: ${FAIL} test(s) — see [FAIL] lines above"
    echo "========================================================================"
    exit 1
else
    echo "  All tests passed."
    echo "========================================================================"
    exit 0
fi
