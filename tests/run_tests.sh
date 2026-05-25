#!/usr/bin/env bash
# tests/run_tests.sh — Functional test suite for log-parse analysis scripts.
#
# Covers all four scripts, all regions, all parameter modes, output formats,
# and error handling. Baselines are derived from the examples/sample-logs/LUNG-CANCER-REPORT-LOG
# sample data included in the project (dates 2026-05-18 ~ 2026-05-25).
#
# Usage:  bash tests/run_tests.sh
# Exit:   0 = all passed,  1 = one or more failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_DIR}/examples/sample-logs/LUNG-CANCER-REPORT-LOG"

ACCESS="${PROJECT_DIR}/bin/analyze_access.sh"
IIS="${PROJECT_DIR}/bin/analyze_iis.sh"
ERRORS="${PROJECT_DIR}/bin/analyze_errors.sh"
REPORT="${PROJECT_DIR}/bin/log_report.sh"

PASS=0
FAIL=0

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

for bin in "$ACCESS" "$IIS" "$ERRORS" "$REPORT"; do
    [[ -x "$bin" ]] || chmod +x "$bin"
done

# ─────────────────────────────────────────────────────────────────────────────
# Section A — analyze_access.sh  存取日誌交叉比對
# Baselines (fixed dates):
#   taipei  2026-05-21 : Total=6   NORMAL=1  ORPHAN=5  UNVERIFIED=0
#   taipei  2026-05-25 : Total=2   NORMAL=1  ORPHAN=1  UNVERIFIED=0
#   taipei  range 21~25: Total=8   NORMAL=2  ORPHAN=6
#   taichung 2026-05-21: Total=6   NORMAL=6  ORPHAN=0  UNVERIFIED=0
#   taichung 2026-05-25: (無 CSV — 乾淨空輸出)
# ─────────────────────────────────────────────────────────────────────────────

section "A  analyze_access.sh — 存取日誌交叉比對"

# A1: taipei 2026-05-21 基準值
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
_ok  A01 "taipei 2026-05-21 執行成功"  "$rc"
_eq  A02 "taipei 2026-05-21  NORMAL=1"      "$(_pick "$out" "NORMAL  (")"       "1"
_eq  A03 "taipei 2026-05-21  ORPHAN=5"      "$(_pick "$out" "ORPHAN  (")"       "5"
_eq  A04 "taipei 2026-05-21  UNVERIFIED=0"  "$(_pick "$out" "UNVERIFIED (")"    "0"
_eq  A05 "taipei 2026-05-21  Total=6"       "$(_pick "$out" "Total correlation")" "6"

# A2: NORMAL 記錄包含 API→APP 時間差與醫院欄位
_has A06 "NORMAL 記錄包含時間差欄位"   "$out" "HOSP:1234567890"
_has A07 "NORMAL 記錄包含 CLIENT IP"   "$out" "CLIENT:192.168.139.110"

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
# Both region NORMAL totals: 1+6=7
total_normal=$(_sum "$out" "NORMAL  (")
_eq  A15 "all regions 兩區域 NORMAL 合計=7"  "$total_normal"  "7"

# A5: taipei 日期範圍 2026-05-21 ~ 2026-05-25 (累計)
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-25 --region taipei 2>/dev/null); rc=$?
_ok  A16 "taipei --from 2026-05-21 --to 2026-05-25 執行成功"  "$rc"
_eq  A17 "taipei 5日範圍  NORMAL=2"   "$(_pick "$out" "NORMAL  (")"       "2"
_eq  A18 "taipei 5日範圍  ORPHAN=6"   "$(_pick "$out" "ORPHAN  (")"       "6"
_eq  A19 "taipei 5日範圍  Total=8"    "$(_pick "$out" "Total correlation")" "8"

# A6: taipei 2026-05-25 單日
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-25 --region taipei 2>/dev/null); rc=$?
_ok  A20 "taipei 2026-05-25 執行成功"  "$rc"
_eq  A21 "taipei 2026-05-25  NORMAL=1" "$(_pick "$out" "NORMAL  (")"  "1"
_eq  A22 "taipei 2026-05-25  ORPHAN=1" "$(_pick "$out" "ORPHAN  (")"  "1"

# A7: taichung 2026-05-25 無 CSV 資料 — 乾淨結束，Total=0
out=$(bash "$ACCESS" --log-dir "$LOG_DIR" \
    --date 2026-05-25 --region taichung 2>/dev/null); rc=$?
_ok  A23 "taichung 2026-05-25 (無 CSV) 乾淨結束"  "$rc"
total="$(_pick "$out" "Total correlation")"; total="${total:-0}"
_eq  A24 "taichung 2026-05-25 無資料 Total=0"  "$total"  "0"

# A8: --days 相對日期不崩潰
bash "$ACCESS" --log-dir "$LOG_DIR" --days 3 --region taipei >/dev/null 2>&1; rc=$?
_ok  A25 "--days 3 --region taipei 執行不崩潰"  "$rc"

# A9: --output 寫入檔案
TMPF=$(mktemp /tmp/lp_access.XXXXXX)
bash "$ACCESS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --output "$TMPF" >/dev/null 2>&1; rc=$?
_ok  A26 "--output FILE 執行成功"  "$rc"
[[ -s "$TMPF" ]] && _pass "A27  --output FILE 產生非空白報告檔案" \
                 || _fail "A27  --output FILE 檔案不存在或為空"
rm -f "$TMPF"

# ─────────────────────────────────────────────────────────────────────────────
# Section B — analyze_iis.sh  IIS W3C 存取日誌分析
# Baselines (2026-05-21):
#   taipei  10.22.63.37 : Total=483  5xx=0  503=0
#   taipei  10.21.3.35  : Total=741  5xx=0  503=0  302=3
#   taipei  10.21.3.36  : Total=730  5xx=0  503=0  302=3
#   taichung 10.1.73.37 : Total=478  5xx=17  503=17
#   taichung 10.1.72.35 : Total=533  5xx=17  503=17  slow=1
#   taichung 10.1.72.36 : Total=769  5xx=16  503=16  slow=1
# ─────────────────────────────────────────────────────────────────────────────

section "B  analyze_iis.sh — IIS W3C 日誌分析"

# B1: taipei 2026-05-21 各伺服器請求總數
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei 2>/dev/null); rc=$?
_ok  B01 "taipei 2026-05-21 執行成功"  "$rc"
# First server block: 10.22.63.37 = 483
first_total=$(printf '%s\n' "$out" | grep "Total requests" | awk '{print $NF}' | head -1)
_eq  B02 "taipei 10.22.63.37 Total requests=483"  "$first_total"  "483"
# Sum across all 3 servers: 483+741+730=1954
sum_total=$(_sum "$out" "Total requests")
_eq  B03 "taipei 三伺服器 Total requests 合計=1954"  "$sum_total"  "1954"

# B2: taipei 無 5xx errors
sum_5xx=$(_sum "$out" "5xx errors")
_eq  B04 "taipei 2026-05-21 5xx errors=0"  "$sum_5xx"  "0"

# B3: taichung 2026-05-21 health 503 故障偵測
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null); rc=$?
_ok  B05 "taichung 2026-05-21 執行成功"  "$rc"
# Sum Health 503: 17+17+16=50
sum_503=$(_sum "$out" "Health 503")
_eq  B06 "taichung Health 503 合計=50"  "$sum_503"  "50"
sum_5xx=$(_sum "$out" "5xx errors")
_gte B07 "taichung 5xx errors >= 1"  "$sum_5xx"  "1"

# B4: all 2026-05-21 兩區域合併輸出
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region all 2>/dev/null); rc=$?
_ok  B08 "all regions 2026-05-21 執行成功"  "$rc"
# Total across all 6 servers: 1954+478+533+769=3734
sum_all=$(_sum "$out" "Total requests")
_eq  B09 "all regions Total requests 合計=3734"  "$sum_all"  "3734"

# B5: STATUS 表格依 count 降序排序 — 200 (最高量) 應排在 503 之前
# Verify for taichung where both 200 and 503 appear
out_tc=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung 2>/dev/null)
line_200=$(printf '%s\n' "$out_tc" | grep -n "^    200 " | head -1 | cut -d: -f1)
line_503=$(printf '%s\n' "$out_tc" | grep -n "^    503 " | head -1 | cut -d: -f1)
if [[ -n "$line_200" && -n "$line_503" && "$line_200" -lt "$line_503" ]]; then
    _pass "B10  STATUS 表格 200 (高 count) 排在 503 之前"
    PASS=$(( PASS + 1 ))
else
    _fail "B10  STATUS 表格排序錯誤 (200 應在 503 前: line_200=${line_200} line_503=${line_503})"
fi

# B6: --slow-ms 自訂門檻 (1ms 應偵測到大量慢請求)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --slow-ms 1 2>/dev/null); rc=$?
_ok  B11 "--slow-ms 1 執行成功"  "$rc"
any_slow=$(_sum "$out" "Slow (>1ms)")
_gte B12 "--slow-ms 1 偵測到慢請求 >= 1"  "$any_slow"  "1"

# B7: 日期範圍 累計請求量 >= 單日
out_range=$(bash "$IIS" --log-dir "$LOG_DIR" \
    --from 2026-05-21 --to 2026-05-22 --region taipei 2>/dev/null); rc=$?
_ok  B13 "taipei --from --to 日期範圍執行成功"  "$rc"
range_sum=$(_sum "$out_range" "Total requests")
_gte B14 "兩日累計 Total requests >= 單日 1954"  "$range_sum"  "1954"

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
# Section D — log_report.sh  整合報告腳本
# ─────────────────────────────────────────────────────────────────────────────

section "D  log_report.sh — 整合報告腳本"

# D1: 所有模組，taipei，單日
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access,iis,errors 2>/dev/null); rc=$?
_ok  D01 "all modules taipei 2026-05-21 執行成功"  "$rc"
_has D02 "整合報告含 Access 段落"   "$out" "Total correlation"
_has D03 "整合報告含 IIS 段落"      "$out" "Total requests"
_has D04 "整合報告含 Errors 段落"   "$out" "Total ERROR"

# D2: --modules access 僅執行 access
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access 2>/dev/null); rc=$?
_ok    D05 "--modules access 執行成功"  "$rc"
_has   D06 "--modules access 輸出含 Access 內容"  "$out" "Total correlation"
_lacks D07 "--modules access 不含 IIS 內容"       "$out" "Total requests"
_lacks D08 "--modules access 不含 Errors 內容"    "$out" "Total ERROR"

# D3: --modules iis,errors
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules iis,errors 2>/dev/null); rc=$?
_ok    D09 "--modules iis,errors 執行成功"  "$rc"
_has   D10 "含 IIS 段落"                    "$out" "Total requests"
_has   D11 "含 Errors 段落"                 "$out" "Total ERROR"
_lacks D12 "不含 Access 段落"               "$out" "Total correlation"

# D4: --output 寫入單一合併報告檔案
TMPF=$(mktemp /tmp/lp_report.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access --output "$TMPF" >/dev/null 2>&1; rc=$?
_ok D13 "--output FILE 執行成功"  "$rc"
[[ -s "$TMPF" ]] && _pass "D14  --output FILE 產生非空白報告檔案" \
                 || _fail "D14  --output FILE 檔案不存在或為空"
# 報告內容應包含 Access 分析資料
file_content=$(cat "$TMPF" 2>/dev/null)
_has D15 "--output FILE 內容含 Total correlation"  "$file_content" "Total correlation"
rm -f "$TMPF"

# D5: --output-dir 各模組分別寫入
TMPD=$(mktemp -d /tmp/lp_outdir.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taipei \
    --modules access,iis,errors --output-dir "$TMPD" >/dev/null 2>&1; rc=$?
_ok D16 "--output-dir 執行成功"  "$rc"
file_count=$(ls "$TMPD" 2>/dev/null | wc -l | tr -d ' ')
_eq  D17 "--output-dir 產生 3 個報告檔案"  "$file_count"  "3"
# 每個檔案均非空
empty_files=$(find "$TMPD" -maxdepth 1 -type f -empty | wc -l | tr -d ' ')
_eq  D18 "--output-dir 所有檔案均非空白"  "$empty_files"  "0"
rm -rf "$TMPD"

# D6: --region 篩選 taichung (透過 log_report.sh)
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 --region taichung \
    --modules access 2>/dev/null); rc=$?
_ok    D19 "--region taichung 執行成功"  "$rc"
_has   D20 "--region taichung 輸出含台中"   "$out" "台中"
_lacks D21 "--region taichung 不含台北"     "$out" "台北"

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

# F4: 情境 — 週報產出至目錄 (定期報告自動化)
TMPD=$(mktemp -d /tmp/lp_weekly.XXXXXX)
bash "$REPORT" --log-dir "$LOG_DIR" --from 2026-05-19 --to 2026-05-25 \
    --modules access,iis,errors --output-dir "$TMPD" >/dev/null 2>&1; rc=$?
_ok  F07 "[情境-週報] --from --to 全模組 --output-dir 執行成功"  "$rc"
file_count=$(ls "$TMPD" 2>/dev/null | wc -l | tr -d ' ')
_eq  F08 "[情境-週報] 產生 3 個週報檔案 (access/iis/errors)"  "$file_count"  "3"
rm -rf "$TMPD"

# F5: 情境 — IIS 效能稽核，自訂慢請求門檻 (效能工程師)
out=$(bash "$IIS" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region all --slow-ms 3000 2>/dev/null); rc=$?
_ok  F09 "[情境-效能稽核] IIS all regions --slow-ms 3000 成功"  "$rc"
_has F10 "[情境-效能稽核] 輸出包含 Slow 門檻資訊"  "$out" "Slow (>3000ms)"

# F6: 情境 — 單一模組單一日期輸出至標準輸出後管線處理
out=$(bash "$REPORT" --log-dir "$LOG_DIR" --date 2026-05-21 \
    --region taichung --modules errors 2>/dev/null)
oracle_count=$(_sum "$out" "OracleDB health failures")
_gte F11 "[情境-管線處理] 可從 log_report 輸出擷取 OracleDB count >= 44"  \
    "$oracle_count"  "44"

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
