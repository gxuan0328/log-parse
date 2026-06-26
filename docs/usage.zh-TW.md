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

### 日期挑選優先順序

當同時提供多個日期旗標時，優先順序為 **`--date` > `--from`/`--to` > `--days`**。

| 提供之旗標                          | 實際範圍                                  |
|-------------------------------------|-------------------------------------------|
| `--date 2026-05-21`                 | 僅 2026-05-21                             |
| `--from 2026-05-18 --to 2026-05-25` | 2026-05-18 → 2026-05-25（共 8 天）        |
| `--from 2026-05-20`（無 `--to`）    | 2026-05-20 → 今天                         |
| `--to 2026-05-22`（無 `--from`）    | （今天 − 預設 days） → 2026-05-22         |
| `--days 3`                          | 至今日為止之最後 3 天                     |
| （皆未提供）                        | 至今日為止之最後 7 天                     |

### 更名與移除的旗標

| 舊旗標 | 狀態 | 替換 | 備注 |
|---|---|---|---|
| `--slow-ms N`（iis） | **已移除** | `--slow-api-ms N` · `--slow-app-ms N` | 依伺服器角色分離。API 預設 2000 ms，APP 預設 5000 ms。傳入舊旗標將以 `Unknown option` 錯誤退出。 |
| `--format text\|tsv`（access） | **已擴充** | `--format text\|tsv\|csv` | 新增 `csv`（RFC-4180 條件式引號）。四支腳本皆接受此旗標；iis 與 errors 遇到非 `text` 值時仍輸出文字並記錄 notice。 |
| `--top N`（僅 errors） | **已統一** | `--top N`（iis + errors） | `0` 現在代表 ALL（端點、客戶端 IP、錯誤模式）。舊版 errors 中 `0` 會輸出零筆。 |

---

## 1. `bin/analyze_access.sh`

交叉比對 API ↔ APP 存取日誌，揭露 NORMAL / ORPHAN / UNVERIFIED 三類 Token。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。設定 `--date` 或 `--from` 時忽略。 |
| `--from YYYY-MM-DD` | date | — | 否 | 起始日期（含）。搭配 `--to` 使用。 |
| `--to YYYY-MM-DD` | date | — | 否 | 結束日期（含）。搭配 `--from` 使用。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。覆寫 `--days` 與日期範圍。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--merge` | flag | 關閉 | 否 | 跨區域合併關聯，輸出單一合併區塊。**需要 `--region all`**（明確指定或使用預設值）；否則錯誤退出。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | `text` = 人類可讀；`tsv` = 分隔符為 tab 的平面檔；`csv` = RFC-4180 逗號分隔。 |
| `--output FILE` | path | stdout | 否 | 將報告寫入檔案。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 範例

```bash
# 1. 最近 7 天、全區域、預設文字輸出
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. 指定日期、僅台北
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei

# 3. 一週日期範圍、CSV 輸出供下游 ETL / SIEM 進一步處理
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
    --output ./reports/access_w21.csv

# 4. TSV 平面檔輸出
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format tsv \
    --output ./reports/access_w21.tsv

# 5. 跨區域合併關聯（所有伺服器一次性比對）
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge

# 6. 一週日期範圍、僅台中、寫入檔案
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taichung \
    --output ./reports/access_taichung_w21.txt

# 7. 自訂區域對應表
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --conf ./conf/regions.staging.conf
```

### 範例輸出（text）

```
========================================================================
  Access Log Cross-Correlation Report
========================================================================
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  Region filter                           taipei

▶ Region: 台北  (10.22.63.37 → 10.21.3.35,10.21.3.36)
------------------------------------------------------------------------
  Total correlation records               6
    NORMAL  (正常流程)                1
    ORPHAN  (APP無對應API)             5
    UNVERIFIED (API未被使用)          0

    ■ 正常流程 (NORMAL) — API 簽發後由 APP 驗證
    API_TIME                 APP_TIME                 DELTA     VERIFY   REQUEST_ID     API_SRV          APP_SRV          HOSP_ID       PRSN_ID       CLIENT_IP         PATIENT_ID_AES
    2026-05-21 10:48:18.802  2026-05-21 10:48:23.624  4.8s      OK       4000000a-0001-fb00-b63f-84710c7967bb  10.22.63.37      10.21.3.35       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E

    驗證筆數 (有效時間差)                            1
    平均 API→APP 時間差                          4.8s
    最短時間差                                   4.8s
    最長時間差                                   4.8s


    ■ 非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token
    APP_TIME                 VERIFY   REQUEST_ID     APP_SRV          HOSP_ID       PRSN_ID       CLIENT_IP         PATIENT_ID_AES
    2026-05-21 15:16:35.342  OK       40000336-0003-ff00-b63f-84710c7967bb  10.21.3.36       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 15:19:53.610  OK       400001ce-0007-fd00-b63f-84710c7967bb  10.21.3.35       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 15:28:17.947  OK       40000092-0005-fe00-b63f-84710c7967bb  10.21.3.36       -             -             -                 2EDEBACB75D9FA547F2018E13E695AF1
    2026-05-21 17:12:53.004  OK       40000216-0001-fe00-b63f-84710c7967bb  10.21.3.35       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E
    2026-05-21 17:14:43.624  OK       400000a6-0005-fe00-b63f-84710c7967bb  10.21.3.36       1234567890    Z123123123    192.168.139.110   EBD71A864A0F7E6A355827754B89259E

    ORPHAN 驗證結果                             5 (成功) / 0 (失敗)
    >> [WARN] 存在可能來自其他區域或重播的有效 Token
```

每個類別僅顯示其相關欄位；`PATIENT_ID_AES` 永遠為最後一欄且從不截斷。
各類別內之紀錄依該類別主要時間鍵升冪排序（NORMAL 與 UNVERIFIED 依
`API_TIME`；ORPHAN 依 `APP_TIME`）。

> 完整輸出存於 [`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt)。

### 平面輸出（tsv / csv）

兩種格式均以 13 個欄位輸出每筆關聯結果，欄位順序如下：

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

`csv` 使用 RFC-4180 條件式引號：僅含 `"`、`,` 或換行之欄位才加引號；
內部 `"` 以雙引號表示。標頭列永遠為第一行。

> 範例：[`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

---

## 2. `bin/analyze_iis.sh`

分析 IIS W3C 擴充欄位日誌：請求量、狀態分佈、慢請求、健康檢查 503 異常。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。設定 `--date` 或 `--from` 時忽略。 |
| `--from YYYY-MM-DD` | date | — | 否 | 起始日期（含）。搭配 `--to` 使用。 |
| `--to YYYY-MM-DD` | date | — | 否 | 結束日期（含）。搭配 `--from` 使用。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。覆寫 `--days` 與日期範圍。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 每個伺服器區塊之端點表**與** Client-IP 表顯示筆數。`0` = ALL。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | API 角色伺服器之慢請求門檻。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | APP 角色伺服器之慢請求門檻。 |
| `--merge` | flag | 關閉 | 否 | 跨區域主機合併；輸出一個 API-servers 區塊與一個 APP-servers 區塊。**需要 `--region all`**。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 解析器接受；iis 永遠輸出文字。非 `text` 值記錄 notice 後繼續執行。 |
| `--output FILE` | path | stdout | 否 | 將報告寫入檔案。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 範例

```bash
# 1. 每日健康檢查，全區域，使用預設各角色慢請求門檻
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. 每週稽核，將 API SLA 收緊為 1 秒，顯示所有端點
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000 --top 0

# 3. 跨區域合併檢視（API vs APP 兩桶），全區域
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge

# 4. 僅台北，顯示前 5 個端點與客戶端 IP
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei --top 5

# 5. 完整報告存檔
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/iis_2026-05-21.txt
```

### 範例輸出（text）

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

    Client IP           Count     % of total
    ----------------------------------------
    192.168.139.28      472        97.7%
    192.168.139.110     6           1.2%
    10.22.63.37         5           1.0%
```

**Endpoint** 表欄位依序為：Endpoint、Avg(s)（平均回應時間，秒，四捨五入至
小數兩位；IIS 之 `time-taken` 以毫秒記錄）、Count、% of total。**Status**
表為每個 HTTP 狀態碼新增 `% of total` 欄位。兩者均以 count 降冪排序。
Endpoint 與 Client-IP 表之列數受 `--top` 限制（預設 10）；`--top 0` 顯示全部。

每個 API 角色伺服器區塊的慢請求標籤為 `Slow (>2000ms)`，每個 APP 角色
伺服器區塊標籤為 `Slow (>5000ms)`，除非透過 `--slow-api-ms` / `--slow-app-ms`
覆寫。`/health` 請求永遠排除在慢請求計數之外。

> 含三台伺服器之完整輸出見
> [`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt)（台北）
> 與 [`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt)（台中，呈現 OracleDB 中斷引發之 50 筆 Health-503 事件）。

---

## 3. `bin/analyze_errors.sh`

分析應用程式錯誤日誌與生命週期事件。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。設定 `--date` 或 `--from` 時忽略。 |
| `--from YYYY-MM-DD` | date | — | 否 | 起始日期（含）。搭配 `--to` 使用。 |
| `--to YYYY-MM-DD` | date | — | 否 | 結束日期（含）。搭配 `--from` 使用。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。覆寫 `--days` 與日期範圍。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 顯示的錯誤模式列數。`0` = ALL 模式。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 解析器接受；errors 永遠輸出文字。非 `text` 值記錄 notice 後繼續執行。 |
| `--output FILE` | path | stdout | 否 | 將報告寫入檔案。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 範例

```bash
# 1. 預設 7 天錯誤彙總
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. 台中 DB 故障排查 — 顯示 Top 20 模式
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --date 2026-05-21 --top 20

# 3. 顯示所有錯誤模式（不限筆數）
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --top 0

# 4. 日期範圍內之重啟稽核
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 5. 快速 Top-3 抽檢
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --top 3
```

### 範例輸出

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

> 台中三台伺服器加總基準值為 ERROR=46、OracleDB=44、Restart=9
> （已被 `tests/run_tests.sh` 之 C06/C07 驗證）。完整輸出見
> [`../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt`](../examples/sample-outputs/errors_taichung_top20_2026-05-21.txt)。

---

## 4. `bin/log_report.sh`

統籌器：依序執行 `analyze_access`、`analyze_iis`、`analyze_errors`。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。設定 `--date` 或 `--from` 時忽略。 |
| `--from YYYY-MM-DD` | date | — | 否 | 起始日期（含）。搭配 `--to` 使用。 |
| `--to YYYY-MM-DD` | date | — | 否 | 結束日期（含）。搭配 `--from` 使用。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。覆寫 `--days` 與日期範圍。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾，轉發給所有子模組。 |
| `--modules LIST` | csv | `access,iis,errors` | 否 | 逗號分隔之模組子集。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 轉發給 iis（端點 + Client-IP 上限）與 errors（模式上限）。`0` = ALL。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | 僅轉發給 iis；API 角色慢請求門檻。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | 僅轉發給 iis；APP 角色慢請求門檻。 |
| `--merge` | flag | 關閉 | 否 | 轉發給 access 與 iis。**需要 `--region all`**。 |
| `--format text\|tsv\|csv` | enum | `text` | 否 | 轉發給所有模組。access 實際輸出 tsv/csv；iis/errors 永遠輸出文字並記錄 notice。 |
| `--output FILE` | path | stdout | 否 | 將**合併**報告寫入單一檔案。 |
| `--output-dir DIR` | path | — | 否 | 將**每個模組**寫成含時間戳之獨立檔案至 DIR。 |
| `--conf FILE` | path | — | 否 | 覆寫區域對應表，明確指定時才轉發與驗證。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 把 `--verbose` 一併轉發給所有子模組。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

### 旗標轉發矩陣

| 旗標 | access | iis | errors |
|---|:---:|:---:|:---:|
| `--log-dir`, `--region`, `--days`, `--from`, `--to`, `--date`, `--verbose`, `--conf` | F | F | F |
| `--format` | F | F（no-op，記錄 notice） | F（no-op，記錄 notice） |
| `--top` | — | F | F |
| `--slow-api-ms` | — | F | — |
| `--slow-app-ms` | — | F | — |
| `--merge` | F | F | — |
| `--output`, `--output-dir`, `--modules` | 自身 | 自身 | 自身 |

F = 轉發並由子模組執行（或 iis/errors 非 `text` 格式時接受並記錄 notice）。

### 範例

```bash
# 1. 全模組、全區域、單日完整報告
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. 僅 access 模組 — 台北、3 天
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access --region taipei --days 3

# 3. 合併運維覽況 — access + iis 跨區域，前 5 筆
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5

# 4. CSV 匯出（access 輸出 csv；iis + errors 輸出文字並記錄 notice）
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
    --output ./reports/week_access.csv

# 5. 各角色慢請求稽核 — API 收緊為 3 秒，APP 維持預設 5 秒
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --slow-api-ms 3000

# 6. 合併報告 → 單一檔案
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/daily_2026-05-21.txt

# 7. 週報 — 各模組獨立檔案（檔名含時間戳）
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports/weekly

# 產出：
#   ./reports/weekly/analyze_access_20260525_140312.txt
#   ./reports/weekly/analyze_iis_20260525_140312.txt
#   ./reports/weekly/analyze_errors_20260525_140312.txt

# 8. 僅 errors 模組 + debug 日誌
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules errors --region taichung -v

# 9. 未知模組名稱會早期失敗
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access,unknown
#   → Unknown module: 'unknown' (valid: access iis errors)
#     退出碼 1
```

> 完整合併報告範例見 [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt)。

---

## 5. 情境劇本

下列命令與測試套件 Section F 涵蓋之情境一致。

### 5.1 每日例行快照
```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date $(date +%F)
```

### 5.2 資安調查（最近一週、台北、孤兒 Token）
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7 \
    --output ./reports/security_$(date +%F).txt
```

### 5.3 DB 故障排查（台中、最近一天、Top 20 模式）
```bash
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --days 1 --top 20
```

### 5.4 週報（上週一 ~ 上週日）寫入目錄
```bash
START=$(date -d 'last monday' +%F)
END=$(date -d 'last sunday' +%F)
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from "$START" --to "$END" --output-dir ./reports/weekly
```

### 5.5 各角色慢請求稽核（API ≤ 1 秒，APP ≤ 3 秒，全伺服器）
```bash
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 1000 --slow-app-ms 3000
```

### 5.6 合併運維覽況 — 跨區域關聯 + IIS 雙桶拆分
```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --merge --top 5
```

### 5.7 機器可讀 CSV 管線（取出 ORPHAN 的 CLIENT_IP + PATIENT_ID_AES）
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --format csv \
| awk -F',' '$2 == "ORPHAN" { print $12 "," $13 }' \
| sort -u
```

TSV/CSV 欄位參考（共 13 欄，依序）：
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)`。

---

## 6. 退出碼

| 代碼 | 意義                                                                                  |
|------|---------------------------------------------------------------------------------------|
| 0    | 成功（即使所請求之期間無資料）。                                                       |
| 1    | 用法 / 驗證錯誤（缺 `--log-dir`、旗標值非法、未知區域或模組、區域設定檔不存在、`--merge` 未搭配 `--region all`）。 |

---

## 7. 環境變數

| 變數         | 效果                                                              |
|--------------|-------------------------------------------------------------------|
| `LOG_LEVEL`  | `DEBUG` / `INFO`（預設）/ `WARN` / `ERROR`。`-v` 會覆寫為 DEBUG。 |
| `NO_COLOR`   | 設定後關閉所有輸出之 ANSI 色碼。                                  |
| `TMPDIR`     | `mktemp -d` 之根目錄；預設 `/tmp`。                               |
