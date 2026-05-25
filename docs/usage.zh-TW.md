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

---

## 1. `bin/analyze_access.sh`

交叉比對 API ↔ APP 存取日誌，揭露 NORMAL / ORPHAN / UNVERIFIED 三類 Token。

### 旗標

| 旗標                              | 預設                 | 說明                                                       |
|-----------------------------------|----------------------|------------------------------------------------------------|
| `--log-dir PATH`                  | —                    | **必要**。根日誌目錄。                                     |
| `--days N`                        | `7`                  | 至今日為止之最後 N 天。                                    |
| `--from YYYY-MM-DD`               | —                    | 起始日期（含）。                                           |
| `--to YYYY-MM-DD`                 | —                    | 結束日期（含）。                                           |
| `--date YYYY-MM-DD`               | —                    | 單日分析。                                                 |
| `--region taipei\|taichung\|all`  | `all`                | 區域過濾。                                                 |
| `--output FILE`                   | stdout               | 將報告寫入檔案（同時 echo 到 stdout）。                    |
| `--format text\|tsv`              | `text`               | `text` = 人類可讀；`tsv` = 機器可讀。                      |
| `--conf FILE`                     | `conf/regions.conf`  | 覆寫區域對應表。                                           |
| `-v`, `--verbose`                 | 關閉                 | 啟用 DEBUG 等級日誌。                                      |
| `-h`, `--help`                    | —                    | 顯示說明後以 0 退出。                                      |

### 範例

```bash
# 1. 最近 7 天、全區域、預設文字輸出
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. 指定日期、僅台北
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei

# 3. 一週日期範圍、僅台中、寫入檔案
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taichung \
    --output ./reports/access_taichung_w21.txt

# 4. TSV 輸出 — 供下游 ETL / SIEM 進一步處理
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-21 --to 2026-05-25 --format tsv \
    --output ./reports/access_w21.tsv

# 5. 詳細 debug 日誌
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 -v

# 6. 自訂區域對應表
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
    NORMAL  (正常流程)                    1
    ORPHAN  (APP無對應API)                5
    UNVERIFIED (API未被使用)              0

    ■ 正常流程 (NORMAL) — API 簽發後由 APP 驗證
    2026-05-21 10:48:18.802  2026-05-21 10:48:23.624  4.8s  OK  HOSP:1234567890  CLIENT:192.168.139.110

    驗證筆數 (有效時間差)                    1
    平均 API→APP 時間差                  4.8s

    ■ 非正常流程 (ORPHAN) — APP 收到無對應 API 簽發的 Token
    2026-05-21 15:19:53.610  APP:10.21.3.35  VERIFY:OK  HOSP:-  PATIENT:2EDEBACB75D9FA54...
    ...
    ORPHAN 驗證結果                         5 (成功) / 0 (失敗)
    >> [WARN] 存在可能來自其他區域或重播的有效 Token
```

> 完整輸出存於 [`../examples/sample-outputs/access_taipei_2026-05-21.txt`](../examples/sample-outputs/access_taipei_2026-05-21.txt)。

---

## 2. `bin/analyze_iis.sh`

分析 IIS W3C 擴充欄位日誌：請求量、狀態分佈、慢請求、健康檢查 503 異常。

### 旗標

| 旗標                  | 預設                | 說明                                                     |
|-----------------------|---------------------|----------------------------------------------------------|
| `--log-dir PATH`      | —                   | **必要**。根日誌目錄。                                   |
| `--days N`            | `7`                 | 至今日為止之最後 N 天。                                  |
| `--from YYYY-MM-DD`   | —                   | 起始日期（含）。                                         |
| `--to YYYY-MM-DD`     | —                   | 結束日期（含）。                                         |
| `--date YYYY-MM-DD`   | —                   | 單日分析。                                               |
| `--region`            | `all`               | `taipei` / `taichung` / `all`。                          |
| `--slow-ms N`         | `5000`              | 慢請求門檻（毫秒）。                                     |
| `--output FILE`       | stdout              | 寫入檔案。                                               |
| `--conf FILE`         | `conf/regions.conf` | 覆寫區域對應表。                                         |
| `-v`, `--verbose`     | 關閉                | 啟用 DEBUG 日誌。                                        |
| `-h`, `--help`        | —                   | 顯示說明後以 0 退出。                                    |

### 範例

```bash
# 1. 預設 7 天彙總
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. 單日效能稽核 — 將慢請求門檻收緊為 3 秒
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --slow-ms 3000

# 3. 單區一週彙總
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 4. 完整報告存檔
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/iis_2026-05-21.txt
```

### 範例輸出

```
▶ IIS — Server: 10.22.63.37
  Total requests                          483
  Unique client IPs                       3
  302 Redirects                           0
  5xx errors                              0
    Health 503                            0
  Slow (>5000ms)                          0

    Status     Count
    --------------------
    200        480
    204        3

    Count  Endpoint
    -------------------------------------------------------------------
    472    /health
    11     /api/GetLungCancerReportURL

    Count  Client IP          % of total
    ------------------------------------------
    472    192.168.139.28      97.7%
    6      192.168.139.110      1.2%
    5      10.22.63.37          1.0%
```

末段 **Client IP 清單** 列舉每個至少發出一筆請求之客戶端 IP，依請求
數降冪排序並標示其占 total 之百分比。可用於檢視健康檢查器是否主導
流量、是否有掃描器爆量、或是否出現未預期之客戶端身分。

> 含三台伺服器之完整輸出見
> [`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt)（台北）
> 與 [`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt)（台中，呈現 OracleDB 中斷引發之 50 筆 Health-503 事件）。

---

## 3. `bin/analyze_errors.sh`

分析應用程式錯誤日誌與生命週期事件。

### 旗標

| 旗標                  | 預設                | 說明                                                     |
|-----------------------|---------------------|----------------------------------------------------------|
| `--log-dir PATH`      | —                   | **必要**。根日誌目錄。                                   |
| `--days N`            | `7`                 | 至今日為止之最後 N 天。                                  |
| `--from YYYY-MM-DD`   | —                   | 起始日期（含）。                                         |
| `--to YYYY-MM-DD`     | —                   | 結束日期（含）。                                         |
| `--date YYYY-MM-DD`   | —                   | 單日分析。                                               |
| `--region`            | `all`               | `taipei` / `taichung` / `all`。                          |
| `--top N`             | `10`                | 顯示 Top-N 錯誤模式。                                    |
| `--output FILE`       | stdout              | 寫入檔案。                                               |
| `--conf FILE`         | `conf/regions.conf` | 覆寫區域對應表。                                         |
| `-v`, `--verbose`     | 關閉                | 啟用 DEBUG 日誌。                                        |
| `-h`, `--help`        | —                   | 顯示說明後以 0 退出。                                    |

### 範例

```bash
# 1. 預設 7 天錯誤彙總
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 2. 台中 DB 故障排查 — 顯示 Top 20 模式
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --date 2026-05-21 --top 20

# 3. 日期範圍內之重啟稽核
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --region taipei

# 4. 快速 Top-3 抽檢
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

| 旗標                       | 預設                     | 說明                                                  |
|----------------------------|--------------------------|-------------------------------------------------------|
| `--log-dir PATH`           | —                        | **必要**。根日誌目錄。                                |
| `--days N`                 | `7`                      | 至今日為止之最後 N 天。                               |
| `--from YYYY-MM-DD`        | —                        | 起始日期。                                            |
| `--to YYYY-MM-DD`          | —                        | 結束日期。                                            |
| `--date YYYY-MM-DD`        | —                        | 單日分析。                                            |
| `--region`                 | `all`                    | `taipei` / `taichung` / `all`。                       |
| `--modules LIST`           | `access,iis,errors`      | 逗號分隔之模組子集。                                  |
| `--output FILE`            | stdout                   | 將**合併**報告寫入單一檔案。                          |
| `--output-dir DIR`         | —                        | 將**每個模組**寫成獨立檔案至 DIR。                    |
| `--conf FILE`              | `conf/regions.conf`      | 覆寫區域對應表。                                      |
| `-v`, `--verbose`          | 關閉                     | 把 `--verbose` 一併轉發給所有子模組。                 |
| `-h`, `--help`             | —                        | 顯示說明後以 0 退出。                                 |

### 範例

```bash
# 1. 全模組、全區域、單日完整報告
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21

# 2. 僅 access 模組 — 台北、3 天
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access --region taipei --days 3

# 3. 合併報告 → 單一檔案
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --output ./reports/daily_2026-05-21.txt

# 4. 週報 — 各模組獨立檔案（檔名含時間戳）
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports/weekly

# 產出：
#   ./reports/weekly/analyze_access_20260525_140312.txt
#   ./reports/weekly/analyze_iis_20260525_140312.txt
#   ./reports/weekly/analyze_errors_20260525_140312.txt

# 5. 僅 errors 模組 + debug 日誌
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules errors --region taichung -v

# 6. 未知模組名稱會早期失敗
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --modules access,unknown
#   → Unknown module: 'unknown' (valid: access iis errors)
#     退出碼 1
```

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

### 5.5 效能稽核（慢請求 > 3 秒，全伺服器、全區域）
```bash
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-ms 3000
```

### 5.6 機器可讀管線（TSV → awk 過濾 → sort）
```bash
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-21 --to 2026-05-25 --format tsv \
| awk -F'\t' '$2 == "ORPHAN" { print $1 "\t" $11 "\t" $14 }' \
| sort -u
```

---

## 6. 退出碼

| 代碼 | 意義                                                                                  |
|------|---------------------------------------------------------------------------------------|
| 0    | 成功（即使所請求之期間無資料）。                                                       |
| 1    | 用法 / 驗證錯誤（缺 `--log-dir`、日期格式錯誤、未知區域或模組、區域設定檔不存在等）。  |

---

## 7. 環境變數

| 變數         | 效果                                                              |
|--------------|-------------------------------------------------------------------|
| `LOG_LEVEL`  | `DEBUG` / `INFO`（預設）/ `WARN` / `ERROR`。`-v` 會覆寫為 DEBUG。 |
| `NO_COLOR`   | 設定後關閉所有輸出之 ANSI 色碼。                                  |
| `TMPDIR`     | `mktemp -d` 之根目錄；預設 `/tmp`。                               |
