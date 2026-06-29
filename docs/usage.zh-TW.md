# log-parse — CLI 使用參考手冊

> 每個指令的每個旗標，附上可直接複製貼上的範例命令。
> 架構與欄位語意請見 [`design.zh-TW.md`](design.zh-TW.md)。
> **語言**：[English](usage.md) · **繁體中文**

---

## 慣例

- `LOG_DIR` 一律是「包含六個伺服器子目錄」的根路徑
  （例如：`examples/sample-logs/LUNG-CANCER-REPORT-LOG/10.22.63.37/...`）。
- 日期統一使用 `YYYY-MM-DD`；日期範圍含頭含尾。
- 區域值：`taipei`、`taichung`、`all`（預設）。
- 結束代碼：`0` = 成功；`1` = 用法錯誤或驗證失敗。

### 區間選擇 — 請擇一使用

五支 CLI 均對日期選擇器實施**互斥**限制：同時提供超過一個明確選擇器時，
腳本會立即終止並輸出：

```
interval flags are mutually exclusive
  (priority --date > --from/--to > --today > --days): choose exactly ONE (got N)
```

錯誤訊息中的優先順序僅供辨識衝突之用；執行行為一律是「衝突即終止」，
不會靜默採用最高優先者。

| 旗標 | 實際範圍 |
|------|---------|
| `--date 2026-05-21` | 僅 2026-05-21 |
| `--today` | 僅今天（等同 `--date <今日日期>`） |
| `--from 2026-05-18 --to 2026-05-25` | 2026-05-18 → 2026-05-25（共 8 天） |
| `--days 3` | 至今日為止之最後 3 天 |
| （皆未提供） | 至今日為止之最後 7 天（隱式 `--days 7` 回退） |

`--from` 與 `--to` 必須成對使用；單獨提供其中一個也會終止。

### 永遠開啟的持久化

每次執行都會自動把報告檔案寫入**輸出目錄**（不只輸出到 stdout）。
預設目錄為 `./log-parse`（不存在時自動建立）。
可用 `--output-dir DIR` 旗標或 `LOG_PARSE_OUTPUT_DIR` 環境變數覆寫。
優先順序：`--output-dir` 旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。

檔案命名規則：`<模組>_<種類>_<時間戳>.<副檔名>`，其中：
- `<種類>` 為 `summary` 或 `detail`
- `<時間戳>` 格式為 `YYYYmmdd_HHMMSS`；同一次執行的所有檔案共用相同後綴
- `<副檔名>` 的 summary 永遠為 `txt`；detail 依 `--format` 為 `txt`、`tsv` 或 `csv`

持久化檔案永遠不含 ANSI 色碼。`--view` 旗標只控制**主控台鏡像**（哪個視圖
串流至 stdout）；不論 `--view` 為何，兩個檔案均永遠寫入。
建議在 `.gitignore` 加入 `/log-parse/`，以免誤提交執行產物。

### 更名與移除的旗標

| 旗標 | 狀態 | 備注 |
|---|---|---|
| `--output FILE`（所有 CLI） | **已移除** | 由永遠開啟之目錄持久化取代。改用 `--output-dir DIR` 指定目錄。 |
| iis 的 `--format text\|tsv` | **已升級為真實功能** | 原先接受後輸出 notice；tsv/csv 現在會產生正式的長格式 detail 表格。 |
| errors 的 `--format text\|tsv\|csv` | 接受（輸出警告） | errors 只輸出文字；非 `text` 值記錄 notice 後繼續執行。 |
| `--slow-ms N`（iis） | **已移除** | 改用 `--slow-api-ms N` 與 `--slow-app-ms N`。 |
| `--top N` | **已統一** | 現在適用於 iis（端點 + 客戶端 IP）與 errors（模式）。`0` = ALL。 |
| log_report 的 `--modules LIST` | **預設值已更改** | 預設由 `access,iis,errors` 改為 `overview,iis,access`；errors 須手動加入。 |

---

## 0. `bin/analyze_overview.sh`

管理總覽報告，透過三個切面整合 IIS 健康狀態與存取關聯指標：

- **總體概況 (Overall)** — 系統全域總量、主要比率、質性健康判定。
- **分區別 (By Region)** — 各區域請求佔比與 NORMAL 率。
- **服務別 (By Service Role)** — API 與 APP 伺服器分開的問題訊號。

overview 為**僅 summary**（無 `--view`）且**僅文字**（無 `--format`）。
它透過 `--emit-stats` 從 `analyze_iis` 與 `analyze_access` 取得指標
（DRY — 零重複解析，零重複指標運算）。輸出目錄只寫入
`overview_summary_<時間戳>.txt`（無 detail 檔案）。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | API 角色伺服器之慢請求門檻。僅轉發給 iis 子行程（不轉發給 access）。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | APP 角色伺服器之慢請求門檻。僅轉發給 iis 子行程。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

**不接受**：`--view`、`--format`、`--merge`、`--top`、`--emit-stats`。

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 每日管理總覽，全區域
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 2. 今日快速總覽
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" --today

# 3. 週報總覽，全區域（預設 7 天窗口）
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25

# 4. 僅台北，收緊 API SLA
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --slow-api-ms 1000

# 5. 指定輸出目錄（避免污染 CWD 的 ./log-parse）
bash bin/analyze_overview.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --output-dir ./reports
```

### 範例輸出

```
========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-21  →  2026-05-21  (1 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  IIS 總請求數                            3734
  不重複用戶端 IP                         15
  存取關聯總數                            12
  NORMAL 正常流程率                       58.3%
  平均 API→APP 延遲                       17.4s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

▶ 分區別 (By Region)
------------------------------------------------------------------------
  [佔比；總量見總體概況]
  台北                                    IIS 佔比 52.3%   NORMAL 16.7%   異常 5
  台中                                    IIS 佔比 47.7%   NORMAL 100.0%   異常 0

▶ 服務別 (By Service Role)
------------------------------------------------------------------------

    ■ API 伺服器 (2 台 · 簽發 Token)
  IIS 請求數 (佔比)                       961 (25.7%)
  5XX 錯誤                                17
  慢速率 (>2000ms)                        0.0%
  UNVERIFIED (簽發未使用)                 0

    ■ APP 伺服器 (4 台 · 驗證 Token / DICOM)
  IIS 請求數 (佔比)                       2773 (74.3%)
  健康檢查 503 (Oracle 相依)              50
  慢速率 (>5000ms)                        0.1%
  ORPHAN (無對應簽發)                     5
```

實作強制執行的內容規則：
- 全域總量（`IIS 總請求數`、`存取關聯總數`）僅出現在總體概況區塊。
- `5XX`、`SLOW`、`503`、`ORPHAN`、`UNVERIFIED` 關鍵字僅出現在服務別區塊。
- `UNVERIFIED` 僅出現在 API 子切面；`ORPHAN` / `503` 僅出現在 APP 子切面。
- 健康判定行永遠不含數字。
- 空窗口（無資料）時輸出零值與 `N/A` 比率；退出碼 0。

> 完整週報範例：[`../examples/sample-outputs/overview_all_week.txt`](../examples/sample-outputs/overview_all_week.txt)。
> 單一區域範例：[`../examples/sample-outputs/overview_taipei_week.txt`](../examples/sample-outputs/overview_taipei_week.txt)。

---

## 1. `bin/analyze_access.sh`

交叉比對 API ↔ APP 存取日誌，揭露 NORMAL / ORPHAN / UNVERIFIED 三類 Token。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--view summary\|detail` | enum | `detail` | 否 | 主控台視圖。`summary` = 精簡管理文字；`detail` = 完整逐筆紀錄表格。不論 `--view` 為何，兩個檔案均永遠寫入。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 控制 **detail** 檔案的副檔名與 detail 主控台鏡像。summary 永遠為文字。`tsv` = tab 分隔；`csv` = RFC-4180。 |
| `--merge` | flag | 關閉 | 否 | 跨區域合併關聯，輸出單一合併區塊。**需要 `--region all`**（明確指定或使用預設值）。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

`--emit-stats` 為內部旗標（供 `analyze_overview` 使用），輸出機器可讀的
`access_stats.tsv` 欄列至 stdout，不持久化，不輸出標頭橫幅，
且僅接受區間 / 區域 / conf / verbose 子集旗標。

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 最近 7 天、全區域、預設 detail 文字輸出
bash bin/analyze_access.sh --log-dir "$LOG_DIR"

# 2. 指定日期、僅台北、管理 summary 視圖
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --view summary

# 3. 一週日期範圍、CSV detail 供下游 ETL / SIEM 進一步處理
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format csv --view detail \
    --output-dir ./reports

# 4. TSV 平面檔 detail 輸出
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --format tsv --view detail \
    --output-dir ./reports

# 5. 跨區域合併關聯（所有伺服器一次性比對）
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge

# 6. 今日存取 summary
bash bin/analyze_access.sh --log-dir "$LOG_DIR" --today --view summary

# 7. 自訂區域對應表
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --conf ./conf/regions.staging.conf
```

### Summary 視圖

```
============ Access Cross-Correlation Summary ============
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  Region filter                           all
  關聯總數                                12
    NORMAL  (正常流程)                    7  (58.3%)
    ORPHAN  (APP無對應API)                5  (41.7%)
    UNVERIFIED (API未被使用)              0  (0.0%)
  ORPHAN 驗證結果                         5 (成功) / 0 (失敗)
  延遲 API→APP                            平均 17.4s · 最短 4.822s · 最長 37.554s

    ■ 分區別 (% within region)
    台北    NORMAL 16.7%     ORPHAN 83.3%     UNVERIFIED 0.0%
    台中    NORMAL 100.0%    ORPHAN 0.0%      UNVERIFIED 0.0%
```

> 完整 summary 範例：[`../examples/sample-outputs/access_summary_all_2026-05-21.txt`](../examples/sample-outputs/access_summary_all_2026-05-21.txt)。

### Detail 視圖（text）

detail 視圖依類別（NORMAL、ORPHAN、UNVERIFIED）分別顯示逐筆紀錄表格。
各類別僅顯示其相關欄位；`PATIENT_ID_AES` 永遠為最後一欄且從不截斷。
各類別內紀錄依主要時間鍵升冪排序。

```
▶ Region: 台北  (10.22.63.37 → 10.21.3.35,10.21.3.36)
------------------------------------------------------------------------
  Total correlation records               6
    NORMAL  (正常流程)                    1
    ORPHAN  (APP無對應API)                5
    UNVERIFIED (API未被使用)              0
    ...
```

> 完整 detail 範例：[`../examples/sample-outputs/access_detail_all_2026-05-21.txt`](../examples/sample-outputs/access_detail_all_2026-05-21.txt)。
> 台北 detail：[`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt)。

### 平面輸出（tsv / csv）

兩種格式均以 13 個欄位輸出每筆關聯結果，欄位順序如下：

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

`csv` 使用 RFC-4180 條件式引號：僅含 `"`、`,` 或換行之欄位才加引號；
內部 `"` 以雙引號表示。標頭列永遠為第一行。summary 檔案永遠為
`.txt`，與 `--format` 無關；僅 detail 檔案使用 `.tsv` / `.csv` 副檔名。

> 範例：[`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

---

## 2. `bin/analyze_iis.sh`

分析 IIS W3C 擴充欄位日誌：請求量、狀態分佈、慢請求、健康檢查 503 異常。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--view summary\|detail` | enum | `detail` | 否 | 主控台視圖。`summary` = 精簡管理文字；`detail` = 完整伺服器表格。不論 `--view` 為何，兩個檔案均永遠寫入。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 控制 **detail** 檔案的副檔名與 detail 主控台鏡像。summary 永遠為文字。`tsv`/`csv` 產生標準化長格式表格（見下方）。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 每個伺服器區塊之端點表與 Client-IP 表顯示列數。`0` = ALL。也限制 summary 之 top 端點清單。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | API 角色伺服器之慢請求門檻。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | APP 角色伺服器之慢請求門檻。 |
| `--merge` | flag | 關閉 | 否 | 跨區域主機合併；輸出一個 API-servers 區塊與一個 APP-servers 區塊。**需要 `--region all`**。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

`--emit-stats` 為內部旗標（供 `analyze_overview` 使用）。

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 每日健康檢查，全區域，使用預設各角色慢請求門檻
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 2. 管理 summary 視圖，全區域，單日
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --view summary

# 3. 每週稽核，將 API SLA 收緊為 1 秒，顯示所有端點
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0

# 4. 每週 detail 匯出為 CSV 供存檔記錄
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --view detail --format csv \
    --output-dir ./reports

# 5. 跨區域合併檢視（API vs APP 兩桶），全區域
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge

# 6. 僅台北，顯示前 5 端點與客戶端 IP，summary 視圖
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei --top 5 --view summary

# 7. 今日快速 IIS summary
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" --today --view summary
```

### Summary 視圖

```
============ IIS Summary — Region: all ============
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  總請求數                                3734
  不重複用戶端 IP                         15
  5xx 錯誤率                              1.3%  (50)
    其中 健康檢查 503                     50
  慢速率                                  0.1%  (2)
  302 轉址率                              0.3%

    ■ Top 端點 (佔比)
    1. /health                                               75.0%
    2. /api/NhiPatientImage/studies/{uid}/series/{uid}/...   12.2%
    3. /api/DigestSummary/hospital                           6.1%
    ...

    ■ 狀態碼分布 (Top 3)
      200 95.7% · 404 1.9% · 503 1.3%

    ■ Top 用戶端 IP
      192.168.139.28 75.0% · 192.168.139.119 19.1% · 192.168.139.110 5.6%
```

> 完整 summary 範例：[`../examples/sample-outputs/iis_summary_all_2026-05-21.txt`](../examples/sample-outputs/iis_summary_all_2026-05-21.txt)。

### Detail 視圖（text）

detail 視圖顯示含狀態碼、端點、Client-IP 百分比表格的逐伺服器 KV 區塊。
API 角色伺服器顯示 `Slow (>2000ms)`；APP 角色伺服器顯示 `Slow (>5000ms)`，
除非透過 `--slow-api-ms` / `--slow-app-ms` 覆寫。`/health` 請求永遠排除在
慢請求計數之外。

```
▶ IIS — 10.22.63.37
------------------------------------------------------------------------
  Total requests                          483
  Unique client IPs                       3
  302 Redirects                           0
  5xx errors                              0
    Health 503                            0
  Slow (>2000ms)                          0

    Status      Count     % of total
    --------------------------------
    200         480        99.4%
    204         3           0.6%

    Endpoint                                                 Avg(s)    Count     % of total
    ---------------------------------------------------------------------------------------
    /health                                                  0.06      472        97.7%
    /api/GetLungCancerReportURL                              0.10      11          2.3%
```

> 完整 detail 範例（全區域）：[`../examples/sample-outputs/iis_all_2026-05-21.txt`](../examples/sample-outputs/iis_all_2026-05-21.txt)。
> 台北：[`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt)。
> 台中：[`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt)
>（呈現 OracleDB 中斷引發之 50 筆 Health-503 事件）。

### Detail 視圖（tsv / csv）

使用 `--format tsv` 或 `--format csv` 時，detail 檔案 / 視圖為標準化長格式表格。
第一行為標頭，之後每個伺服器的每個指標各一列：

```
REGION  ROLE  SERVER         METRIC     KEY     COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37    SUMMARY    TOTAL   483    -        100.0
taipei  api   10.22.63.37    SUMMARY    5XX     0      -        0.0
taipei  api   10.22.63.37    STATUS     200     480    -        99.4
taipei  api   10.22.63.37    ENDPOINT   /health 472    0.06     97.7
taipei  api   10.22.63.37    CLIENT_IP  192.168.139.28  472  -  97.7
```

`METRIC` 可能值：`SUMMARY`（總量）、`STATUS`（各 HTTP 狀態碼）、
`ENDPOINT`（各 URI，受 `--top` 限制）、`CLIENT_IP`（各 IP，受 `--top` 限制）。
summary 視圖永遠為文字，與 `--format` 無關（summary 檔案永遠為 `.txt`）。

> 範例：[`../examples/sample-outputs/iis_detail_all_2026-05-21.tsv`](../examples/sample-outputs/iis_detail_all_2026-05-21.tsv) · [`../examples/sample-outputs/iis_detail_all_2026-05-21.csv`](../examples/sample-outputs/iis_detail_all_2026-05-21.csv)

---

## 3. `bin/analyze_errors.sh`

分析應用程式錯誤日誌與生命週期事件。

此模組**沒有 `--view` 旗標**：主控台永遠顯示 detail 視圖；summary 只寫入
磁碟（`errors_summary_<時間戳>.txt`）。`errors_summary_<時間戳>.txt` 與
`errors_detail_<時間戳>.txt` 兩個檔案均永遠寫入輸出目錄。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 顯示的錯誤模式列數。`0` = ALL 模式。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 接受；errors 永遠輸出文字。非 `text` 值記錄 notice 後繼續執行。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 預設 7 天錯誤彙總
bash bin/analyze_errors.sh --log-dir "$LOG_DIR"

# 2. 台中 DB 故障排查 — 顯示 Top 20 模式
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --region taichung --date 2026-05-21 --top 20

# 3. 顯示所有錯誤模式（不限筆數）
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --top 0

# 4. 日期範圍內之重啟稽核
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 5. 今日錯誤，台北
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --today --region taipei

# 6. 快速 Top-3 抽檢，寫入自訂目錄
bash bin/analyze_errors.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --top 3 --output-dir ./reports
```

### 主控台輸出（detail — 永遠顯示）

```
▶ App Errors — Server: 10.1.72.35
------------------------------------------------------------------------
  Total ERROR entries                     16
  OracleDB health failures                15
    首次 OracleDB 失敗時間:
      2026-05-21 00:10:40.3560
      2026-05-21 00:33:32.0321
      2026-05-21 04:28:16.8366

    Top Error Patterns:
    Count  Message
    --------------------------------------------------------------------
    15     Health check 正式_OracleDB with status Unhealthy completed after 37935.4919ms with
    1      系統在處理請求時發生未預期例外：A task was canceled.

    ■ 應用程式重啟事件
  Restart count                           4

    Shutdown Time                 Started Time                  Downtime
    ------------------------------------------------------------------------
    2026-05-21 08:14:08.221       2026-05-21 08:15:01.992       53s
```

### Summary 檔案（僅磁碟）

`errors_summary_<時間戳>.txt` 寫入輸出目錄，但不鏡像至主控台。
它包含各區域 / 伺服器的精簡訊號計數：

```
  Error Analysis Summary
...
    ■ Server: 10.1.72.35
  Total ERROR                             16
  OracleDB health failures                15
  Restart count                           4
  Unmatched SHUTDOWN                      0
```

> 台中三台伺服器加總基準值為 ERROR=46、OracleDB=44、Restart=9
> （已被 `tests/run_tests.sh` 之 C06/C07 驗證）。完整 detail 範例見
> [`../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt`](../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt)。
> 台北 summary 範例：[`../examples/sample-outputs/errors_summary_taipei_2026-05-21.txt`](../examples/sample-outputs/errors_summary_taipei_2026-05-21.txt)。

---

## 4. `bin/log_report.sh`

統籌器：依正規順序執行所有啟用的分析模組（`overview → iis → access → errors`），
並以每個模組自身持久化檔案對的方式輸出。

預設情況下，`log_report` 執行 **overview、iis 與 access**，使用 **summary** 視圖。
`errors` 模組須明確列入 `--modules` 才會執行（預設關閉）。每個模組將自己的
檔案對寫入共用輸出目錄；所有檔案共用同一個啟動時間戳。

```
[共用輸出目錄]
  overview_summary_<T>.txt
  iis_summary_<T>.txt
  iis_detail_<T>.txt          （text 預設；搭配 --format 可為 tsv/csv）
  access_summary_<T>.txt
  access_detail_<T>.txt       （或 .tsv / .csv 搭配 --format）
  errors_summary_<T>.txt      （僅當 errors 在 --modules 中）
  errors_detail_<T>.txt       （僅當 errors 在 --modules 中）
```

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region REGION` | enum | `all` | 否 | 區域過濾，轉發給所有模組。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--modules LIST` | csv | `overview,iis,access` | 否 | 逗號分隔之模組清單。有效值：`overview`、`iis`、`access`、`errors`。errors 須手動加入（預設關閉）。模組依正規順序執行，與輸入順序無關。未知模組名稱會終止執行。 |
| `--view summary\|detail` | enum | `summary` | 否 | 主控台視圖。僅轉發給 iis 與 access；overview 與 errors 不受影響。summary 永遠為文字（與格式無關）。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 控制 detail 檔案副檔名與 detail 主控台鏡像。轉發給 iis 與 access；overview 與 errors 不受影響。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 轉發給 iis（端點 + Client-IP）與 errors（模式）。`0` = ALL。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | 轉發給 overview 與 iis；適用於 API 角色伺服器。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | 轉發給 overview 與 iis；適用於 APP 角色伺服器。 |
| `--merge` | flag | 關閉 | 否 | 轉發給 access 與 iis。**需要 `--region all`**。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。透過 `$LOG_PARSE_OUTPUT_DIR` 由子模組共用；`--output-dir` 旗標**不**轉發給子模組。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，明確指定時才轉發給所有模組。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 把 `--verbose` 一併轉發給所有子模組。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 旗標轉發矩陣

| 旗標 | overview | iis | access | errors |
|---|:---:|:---:|:---:|:---:|
| `--log-dir`、`--region`、區間旗標、`--verbose`、`--conf` | F | F | F | F |
| `--view` | — | F | F | — |
| `--format` | — | F | F | — |
| `--top` | — | F | — | F |
| `--slow-api-ms`、`--slow-app-ms` | F | F | — | — |
| `--merge` | — | F | F | — |
| `--output-dir`、`--modules` | 自身 | 自身 | 自身 | 自身 |

F = 轉發並由子模組執行。`--output-dir` 由 log_report 解析一次後透過
`$LOG_PARSE_OUTPUT_DIR` 共用；不以旗標形式轉發給子模組（防止指定
自訂 `--output-dir` 時發生分裂腦問題）。

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 預設報告 — overview + iis + access，最近 7 天，summary 視圖
bash bin/log_report.sh --log-dir "$LOG_DIR"

# 2. 單日 summary，全區域
bash bin/log_report.sh --log-dir "$LOG_DIR" --date 2026-05-21

# 3. 今日快速報告
bash bin/log_report.sh --log-dir "$LOG_DIR" --today

# 4. 週報（含 errors），自訂輸出目錄
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --from 2026-05-18 --to 2026-05-25 \
    --modules overview,iis,access,errors \
    --output-dir ./reports/weekly

# 5. Detail 視圖 + CSV 匯出（iis + access detail 檔案為 .csv）
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --view detail --format csv \
    --output-dir ./reports

# 6. 僅台北，含 errors，Top 5 模式
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --region taipei \
    --modules overview,iis,access,errors --top 5

# 7. 收緊 overview 與 iis 的 API SLA
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --slow-api-ms 3000

# 8. 合併運維覽況 — 跨區域關聯 + IIS 雙桶拆分
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --merge --top 5

# 9. 未知模組名稱會早期失敗並終止
bash bin/log_report.sh --log-dir "$LOG_DIR" --modules access,unknown
#   退出碼 1
```

> 完整合併報告範例見 [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt)。
> 台北部分報告：[`../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt`](../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt)。

---

## 5. 情境劇本

下列命令與測試套件 Section F 涵蓋之情境一致。

### 5.1 每日例行快照

```bash
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date "$(date +%F)" \
    --output-dir ./reports/daily
```

### 5.2 資安調查（最近一週、台北、孤兒 Token）

```bash
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7 --view detail \
    --output-dir ./reports/security
```

### 5.3 DB 故障排查（台中、最近一天、Top 20 模式）

```bash
bash bin/analyze_errors.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --days 1 --top 20 \
    --output-dir ./reports/triage
```

### 5.4 週報（上週一 ~ 上週日）寫入目錄，含 errors

```bash
START=$(date -d 'last monday' +%F)
END=$(date -d 'last sunday' +%F)
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from "$START" --to "$END" \
    --modules overview,iis,access,errors \
    --output-dir ./reports/weekly
# 產出（共用時間戳 T）：
#   ./reports/weekly/overview_summary_<T>.txt
#   ./reports/weekly/iis_summary_<T>.txt
#   ./reports/weekly/iis_detail_<T>.txt
#   ./reports/weekly/access_summary_<T>.txt
#   ./reports/weekly/access_detail_<T>.txt
#   ./reports/weekly/errors_summary_<T>.txt
#   ./reports/weekly/errors_detail_<T>.txt
```

### 5.5 各角色慢請求稽核（API ≤ 1 秒，APP ≤ 3 秒，全伺服器）

```bash
bash bin/analyze_iis.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 1000 --slow-app-ms 3000 \
    --output-dir ./reports
```

### 5.6 合併運維覽況 — 跨區域關聯 + IIS 雙桶拆分

```bash
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5 \
    --output-dir ./reports
```

### 5.7 機器可讀 CSV 管線（取出 ORPHAN 的 CLIENT_IP + PATIENT_ID_AES）

```bash
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv --view detail \
    --output-dir ./reports \
| awk -F',' '$2 == "ORPHAN" { print $12 "," $13 }' \
| sort -u
```

TSV/CSV 欄位參考（共 13 欄，依序）：
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)`。

### 5.8 獨立管理總覽（台北，單日）

```bash
bash bin/analyze_overview.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei \
    --output-dir ./reports
```

---

## 6. 退出碼

| 代碼 | 意義 |
|------|------|
| 0 | 成功（即使所請求之期間無資料）。 |
| 1 | 用法 / 驗證錯誤：缺 `--log-dir`、旗標值非法、未知區域或模組、設定檔不存在、`--merge` 未搭配 `--region all`、提供超過一個區間選擇器。 |

---

## 7. 環境變數

| 變數 | 效果 |
|------|------|
| `LOG_LEVEL` | `DEBUG` / `INFO`（預設）/ `WARN` / `ERROR`。`-v` 會覆寫為 DEBUG。 |
| `NO_COLOR` | 設定後關閉所有輸出之 ANSI 色碼。持久化檔案無論此變數為何，永遠不含色碼。 |
| `TMPDIR` | `mktemp -d` 之根目錄；預設 `/tmp`。 |
| `LOG_PARSE_OUTPUT_DIR` | 持久化檔案的預設輸出目錄。`--output-dir DIR` 旗標可覆寫。當此變數與旗標皆未設定時，回退至字面值 `./log-parse`。 |
| `LOG_PARSE_RUN_TS` | 格式 `YYYYmmdd_HHMMSS` 的共用啟動時間戳。由 `log_report` 設定並匯出給子模組，使同一次執行的所有檔案共用相同後綴。在腳本或測試中可覆寫為固定值以產生確定性檔案名稱。 |
