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

檔案佈局：`<base>/<YYYYMMDD_HHMMSS>/<模組>_<種類>.<副檔名>`，其中：
- `<base>` 為已解析之輸出目錄
- `<YYYYMMDD_HHMMSS>` 為執行子目錄名稱（共用啟動時間戳；同一次執行
  的所有檔案均落在此單一子目錄中）
- `<種類>` 為 `summary`、`detail` 或 `ip_counts`（僅 access）
- `<副檔名>` 的 summary 永遠為 `txt`；detail 依 `--format` 為 `txt`、
  `tsv` 或 `csv`；`access_ip_counts` 為 `tsv`

持久化檔案永遠不含 ANSI 色碼。`--view` 旗標只控制**主控台鏡像**（哪個視圖
串流至 stdout）；不論 `--view` 為何，所有檔案均永遠寫入。
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

### 測試主機過濾

所有 `analyze_iis` 與 `analyze_access` 執行均需要 **`conf/test_hosts.conf`** —
純文字格式的內部 QA / 健康探針客戶端 IP 清單，**每行一筆**。每筆可以是明確
IPv4（`192.168.117.90`），或 IPv4/prefix **CIDR 網段**（`192.168.0.0/16`）以
一行涵蓋整個子網，免去逐一列舉每台主機。shipped 檔為**僅限外部使用者的生產政策**：
內部網段 CIDR `192.168.0.0/16`（涵蓋所有 192.168.x.x 來源——QA、健康探針與內部
閘道一併視為內部）加上明確主機 `10.252.130.178`。即使使用
`--test-hosts all` 模式，若檔案不存在仍會立即失敗（與 `regions.conf` 的
fail-fast 行為一致）；格式錯誤的項目（無效 octet，或 prefix 超出 0–32）會在
載入時逐行報錯並中止執行。

客戶端 IP 只要**等於**某個明確項目，**或落在**任一 CIDR 網段內即算命中（非正規
網路如 `192.168.5.9/16` 的 host bits 會被忽略，仍涵蓋整段 `/16`）。兩種寫法可
自由混用：保留逐一列舉的主機，再以一行 CIDR 一次納入同網段群組。設定
**`LOG_PARSE_TEST_HOSTS_CONF=/path/to/file`** 可改由指定路徑讀取清單，而非
內建的 `conf/test_hosts.conf`。

`--test-hosts` 旗標控制在讀取階段如何處理這些 IP：

| 值 | 行為 |
|---|---|
| `exclude`（預設） | 捨棄來自測試主機 IP 的紀錄 — 報告反映真實外部流量。 |
| `only` | 僅保留來自測試主機 IP 的紀錄 — 稽核內部 QA 或非 /health 客戶端流量。 |
| `all` | 不過濾測試主機 — 納入所有客戶端 IP。 |

**重要說明：** `/health` 在所有三種模式中均**無條件**排除於 IIS 聚合之外
（在測試主機過濾執行之前就已移除）。健康探針流量（`192.168.139.28`，
約佔原始 IIS 流量的 95%）因此在任何模式下**都不會**出現於報告中。
`--test-hosts only` 顯示的是測試主機 IP 的**非 /health 業務請求**
（例如 `192.168.139.110` 在 2026-05-21 的 209 筆業務請求）——
這是對內部 QA 或非健康探針客戶端流量的稽核，**不是**對探針流量的稽核。

`analyze_overview` 與 `log_report` 接受 `--test-hosts` 並轉發給其子行程
`analyze_iis` 與 `analyze_access`。`analyze_errors` **不接受** `--test-hosts`
（應用程式日誌沒有客戶端 IP 欄位；直接傳入會導致致命錯誤）。

整份 IIS 報告中的**總請求數**一律是**業務請求數**（排除 `/health` 及依測試主機
過濾模式所篩除的 IP 後計算）。Summary 的 `資料範圍` 行與 detail 的 `Scope` 行
會明確顯示當前模式。

---

## 0. `bin/analyze_overview.sh`

管理總覽報告，整合存取關聯結果與 IIS 核心功能效能，以兩個面板呈現：

- **總體概況 (Overall)** — 存取 NORMAL/ORPHAN/UNVERIFIED 筆數及其占存取關聯總數之百分比；平均 API→APP 延遲；整體健康判定（判斷依據：P = trunc(NORMAL ÷ 存取關聯總數 × 100)；P ≥ 90 → 正常；70 ≤ P ≤ 89 → 注意；P < 70 → 警告；總數 = 0 → 無資料）；其後緊跟 ■ 核心功能效能 (Core Function Performance) 子區塊，包含三個 IIS 來源、UTC+8 日期修正的類別 — 雲端查詢（`/api/GetLungCancerReportURL`）、報告摘要（`/api/DigestSummary` 前綴）、影像下載（`/api/NhiPatientImage/studies/…` 前綴）— 各列顯示呼叫次數與回應時間（秒，2 位小數），以及核心功能存取合計（純筆數，無百分比）。類別筆數與平均值採全量累計，不受 top-N 截斷影響。
- **分區別 (By Region)** — 每個在範圍內的區域各有一個 ■ 區塊，以散文形式列舉 `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)`（百分比為該區域內部占比），接著呈現同三個核心功能類別（呼叫次數 + 回應時間）。單一區域執行時（例如 `--region taipei`），分區別區塊會刻意與總體概況一致 — 此為 ROLLUP+明細的正確對稱行為，並非重複計算。

**IIS 日期語意（UTC+8）：** `--date D` 代表 UTC+8 業務日 D。IIS W3C 日誌以
UTC+0 時間記錄；本地一天 D = UTC `[D-1 16:00, D 16:00)`。模組讀取 `u_ex(D-1)`
UTC 時間 ≥ 16:00 的資料列與 `u_ex(D)` UTC 時間 < 16:00 的資料列，涵蓋整個本地
日。若 `u_ex(D-1)` 不存在，清晨時段之窗口將靜默不完整（fail-soft）。存取與
.NET 應用程式日誌原生為 UTC+8，不受影響。

overview 為**僅 summary**（無 `--view`）且**僅文字**（無 `--format`）。
它透過 `--emit-stats` 從 `analyze_iis` 與 `analyze_access` 取得指標
（DRY — 零重複解析，零重複指標運算）。執行目錄 `<base>/<YYYYMMDD_HHMMSS>/`
下只寫入 `overview_summary.txt`（無 detail 檔案）。

**單日每小時橫條圖（存取紀錄橫條圖）：** 當 `--date` 或 `--today`
選取恰好一天時，在總體概況（全局）與分區別各 ■ 區域區塊中各附加
一個 `存取紀錄橫條圖 (每小時)` 區段。橫條圖統計 NORMAL+ORPHAN 的
APP_TIME 小時數（UTC+8；單位 = 存取紀錄 = 一筆抵達 APP 的瀏覽器請求）。
橫軸：`00..LAST` 以零填充。過去單日日期：`LAST=23`（完整 00..23 橫軸）。
`--today` 時：`LAST = local_hour() - 1`；小時為 0 時：`LAST=-1` →
輸出 `(今日尚無完整小時資料)` 提示取代橫條圖。
多日視窗（`--from`/`--to`、`--days`）不渲染橫條圖。

**主機時鐘前提條件與 `TZ` 修正方法：** `local_hour()` 讀取主機時鐘
（與 `today()` 相同）。**前提條件：** 主機時鐘必須為 UTC+8。在非 UTC+8
主機上請以 `TZ=Asia/Taipei` 執行 — 此設定同時平移 `today()` 與
`local_hour()`，使觸發條件與截止保持同步。
以 `LOG_PARSE_NOW_HOUR=H` 可在腳本或測試中做確定性覆寫。

### 旗標

| 旗標 | 型態 | 預設 | 必要? | 說明 |
|---|---|---|:---:|---|
| `--log-dir PATH` | path | — | **是** | 根日誌目錄，目錄必須存在。 |
| `--region taipei\|taichung\|all` | enum | `all` | 否 | 區域過濾。 |
| `--today` | flag | 關閉 | 否 | 僅分析今天。與其他區間選擇器互斥。 |
| `--date YYYY-MM-DD` | date | — | 否 | 單日分析。 |
| `--from YYYY-MM-DD` / `--to YYYY-MM-DD` | 日期對 | — | 否 | 含頭含尾之日期範圍，必須成對使用。 |
| `--days N` | uint ≥ 1 | `7` | 否 | 至今日為止之最後 N 天。僅為隱式回退。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | API 角色伺服器之慢請求門檻。僅轉發給 iis 子行程（不轉發給 access）。驅動 `analyze_iis` 摘要的每台伺服器 `慢速率` KPI；**不影響** overview（核心功能效能無慢速欄）。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | APP 角色伺服器之慢請求門檻。僅轉發給 iis 子行程。驅動 `analyze_iis` 摘要的每台伺服器 `慢速率` KPI；**不影響** overview。 |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | 否 | 測試主機 IP 過濾模式。轉發給 `analyze_iis` 與 `analyze_access` 子行程。詳見[測試主機過濾](#測試主機過濾)。 |
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

以下範例為 `--date 2026-05-21`、預設 `--test-hosts exclude` 模式（全區域）的輸出。
`存取關聯總數` 為業務請求數（已排除測試主機 IP）。IIS 核心功能筆數已套用 UTC+8 日期修正。

```
========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-21  →  2026-05-21  (1 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  存取關聯總數                            9
  NORMAL 正常流程                         6 (66.7%)
  ORPHAN 無對應簽發                       3 (33.3%)
  UNVERIFIED 簽發未使用                   0 (0.0%)
  平均 API→APP 延遲                       19.5s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

    ■ 核心功能效能 (Core Function Performance)
      雲端查詢    呼叫次數 11       回應時間 0.11s
      報告摘要    呼叫次數 186      回應時間 0.38s
      影像下載    呼叫次數 427      回應時間 0.93s
      核心功能存取合計 624

▶ 分區別 (By Region)
------------------------------------------------------------------------

    ■ 台北 (taipei)
      存取關聯 3 筆 — NORMAL 0 (0.0%) · ORPHAN 3 (100.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 5        回應時間 0.02s
      報告摘要    呼叫次數 71       回應時間 0.22s
      影像下載    呼叫次數 220      回應時間 1.48s

    ■ 台中 (taichung)
      存取關聯 6 筆 — NORMAL 6 (100.0%) · ORPHAN 0 (0.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 6        回應時間 0.19s
      報告摘要    呼叫次數 115      回應時間 0.47s
      影像下載    呼叫次數 207      回應時間 0.34s
```

實作強制執行的內容規則：
- `存取關聯總數` 與 NORMAL/ORPHAN/UNVERIFIED 筆數僅出現在總體概況區塊（不出現在分區別）。
- 分區別每個區域顯示一個 ■ 區塊，以散文形式列舉 `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)`（百分比為該區域內部占比），接著顯示各類別的呼叫次數 + 回應時間。`ORPHAN` 與 `UNVERIFIED` 關鍵字僅出現在散文列舉行，不以 rpad 對齊欄位呈現。
- 核心功能效能列顯示呼叫次數與回應時間（秒，2 位小數）；**不含各列占比百分比**，亦**不含速度子說明**（例如無 `前端轉跳速度`）。overview 中**無慢速欄**（每台伺服器的 `慢速率` 仍保留在 `analyze_iis` 摘要中）。
- 整體健康判定行永遠不含數字。判定邏輯：P = trunc(NORMAL ÷ 存取關聯總數 × 100)；P ≥ 90 → 正常；70 ≤ P ≤ 89 → 注意；P < 70 → 警告；總數 = 0 → 無資料。以 2026-05-21 全區域為例：6/9 → trunc(66.7) = 66 < 70 → 警告。
- 單一區域範圍（例如 `--region taipei`）：分區別 台北 區塊與總體概況呈現相同的 N/O/U 與類別數值。此為刻意設計的 ROLLUP+明細對稱行為，並非重複計算。區域標籤是兩者之間的有意義差異。
- 空窗口（無資料）時輸出零值與 `N/A` 比率；退出碼 0。

> 完整週報範例：[`../examples/sample-outputs/overview_all_week.txt`](../examples/sample-outputs/overview_all_week.txt)。
> 單一區域範例：[`../examples/sample-outputs/overview_taipei_week.txt`](../examples/sample-outputs/overview_taipei_week.txt)。
> 單日範例（含每小時橫條圖）：[`../examples/sample-outputs/overview_all_2026-05-21.txt`](../examples/sample-outputs/overview_all_2026-05-21.txt)。

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
| `--test-hosts exclude\|only\|all` | enum | `exclude` | 否 | 測試主機客戶端 IP 過濾。`conf/test_hosts.conf` **任何模式下均為必要檔案**，包括 `all` 模式。詳見[測試主機過濾](#測試主機過濾)。 |
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

# 8. 稽核內部 QA 非健康探針客戶端流量（only 模式）
#    注意：/health 在模式選擇前即已移除；only 模式顯示測試主機 IP
#    的非 /health 業務請求（例如 192.168.139.110 的業務請求）。
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts only --view summary

# 9. 不過濾測試主機（all 模式）
bash bin/analyze_access.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts all --view summary
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
各類別僅顯示其相關欄位；`PATIENT_ID_AES` 從不截斷，其後接續
`BIRTHDAY`（解碼後之出生日期，`YYYYMMDD`）作為最後一欄。
各類別內紀錄依主要時間鍵升冪排序。
NORMAL 區塊底部標籤為 `驗證筆數`（原 `驗證筆數 (有效時間差)` 的括號後綴已移除）。

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

兩種格式均以 14 個欄位輸出每筆關聯結果，欄位順序如下：

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES  BIRTHDAY
```

`csv` 使用 RFC-4180 條件式引號：僅含 `"`、`,` 或換行之欄位才加引號；
內部 `"` 以雙引號表示。標頭列永遠為第一行。summary 檔案永遠為
`.txt`，與 `--format` 無關；僅 detail 檔案使用 `.tsv` / `.csv` 副檔名。

> 範例：[`../examples/sample-outputs/access_all_week.tsv`](../examples/sample-outputs/access_all_week.tsv) · [`../examples/sample-outputs/access_all_week.csv`](../examples/sample-outputs/access_all_week.csv)

### IP 歸因檔案（access_ip_counts.tsv）

每次 `analyze_access` 執行均會寫入第三個固定檔案：
`<base>/<YYYYMMDD_HHMMSS>/access_ip_counts.tsv`。此檔案永遠不輸出至 stdout；
輸出目錄解析邏輯與 summary/detail 相同。

**內容：** 分析語料庫中 NORMAL+ORPHAN 紀錄的客戶端 IP 計數。
IP 欄位取自欄 11（`CLIENT_IP`）；空值或 `-` 均歸一為哨兵值 `-`。
排序：計數降冪，IP 升冪（次排序）。第一行為標頭。空語料庫 → 僅有 1 行標頭。

```
CLIENT_IP	REQUEST_COUNT
-	3
192.168.139.110	3
10.243.129.44	2
10.238.23.241	1
10.241.93.164	1
10.248.1.29	1
10.249.8.10	1
```

（以上為 2026-05-21、全區域、`--test-hosts all` 之預期值）。
預設 `--test-hosts exclude` 模式：`-\t3` 加上各業務 CLIENT_IP（測試主機 IP `192.168.139.110` 已被預先篩除）。

> 範例：[`../examples/sample-outputs/access_ip_counts_all_2026-05-21.tsv`](../examples/sample-outputs/access_ip_counts_all_2026-05-21.tsv)

---

## 2. `bin/analyze_iis.sh`

分析 IIS W3C 擴充欄位日誌：**業務**請求量、狀態分佈、慢請求與端點細項。
`/health` 端點在所有聚合中**無條件**排除（總請求數、端點列表、狀態分佈、
慢請求計數、不重複客戶端 IP）。測試主機客戶端 IP 依 `--test-hosts` 模式在讀取
階段預先過濾。相依性健康 / Oracle 中斷偵測改由 `analyze_errors` 負責。

**IIS 時區修正（UTC+0 → UTC+8）：** IIS W3C 日誌以 UTC+0 時間記錄；參考時區
（存取 CSV + .NET 應用程式日誌）為 UTC+8。`--date D` 代表 UTC+8 業務日 D：模組
讀取 `u_ex(D-1)` UTC 時間 ≥ 16:00 的資料列與 `u_ex(D)` UTC 時間 < 16:00 的資料
列，涵蓋本地時間 00:00 至 23:59（半開 UTC 篩選窗 `[D-1 16:00, D 16:00)`，
字串字典序比較，不使用 `mktime`；單一來源為 `date_utils.sh` 的
`IIS_UTC_OFFSET_HOURS=8`）。若 `u_ex(D-1)` 不存在，清晨時段之窗口將靜默不完整
（fail-soft）。`--from`/`--to` 日期範圍也以同樣方式修正。存取與錯誤日誌分析器
原生為 UTC+8，不受影響。

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
| `--test-hosts exclude\|only\|all` | enum | `exclude` | 否 | 測試主機客戶端 IP 過濾。`conf/test_hosts.conf` **任何模式下均為必要檔案**，包括 `all` 模式。詳見[測試主機過濾](#測試主機過濾)。 |
| `--output-dir DIR` | path | `""` | 否 | 持久化目錄。解析順序：旗標 > `$LOG_PARSE_OUTPUT_DIR` > `./log-parse`。 |
| `--conf FILE` | path | `conf/regions.conf` | 否 | 覆寫區域對應表，檔案必須存在。 |
| `-v`, `--verbose` | flag | 關閉 | 否 | 啟用 DEBUG 等級日誌。 |
| `-h`, `--help` | flag | — | — | 顯示說明後以 0 退出。 |

`--emit-stats` 為內部旗標（供 `analyze_overview` 使用）。

### 範例

```bash
LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 1. 每日健康確認，全區域，使用預設各角色慢請求門檻
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

# 8. 稽核內部 QA 非健康探針客戶端流量（only 模式）
#    顯示 2026-05-21 測試主機 IP 的 209 筆非 /health 業務請求。
#    健康探針 IP 192.168.139.28 不會出現——/health 在模式選擇前即已移除。
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts only --view summary

# 9. 不過濾測試主機（all 模式）
bash bin/analyze_iis.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --test-hosts all --view summary
```

### Summary 視圖

每份 summary 最上方的 `資料範圍` 行顯示當前有效範圍。`總請求數` 一律是**業務
請求數**（排除 `/health` 及測試主機過濾後計算）。

```
============ IIS Summary — Region: all ============
  Period                                  2026-05-21  →  2026-05-21  (1 days)
  資料範圍                                業務請求 (排除 /health；測試主機=exclude)
  總請求數                                723
  不重複用戶端 IP                         6
  慢速率                                  0.3%  (2)

    ■ Top 端點 (佔比 · 平均回應時間)
     1. /api/NhiPatientImage/studies/{uid}/series/{uid}/...    50.8%   1.05s
     2. /api/DigestSummary/hospital                            21.9%   0.33s
     3. /api/NhiPatientImage/studies/{uid}/series-uid           8.3%   0.18s
    ...

    ■ 狀態碼分布 (Top 3)
      200 87.3% · 404 9.7% · 304 1.8%

    ■ Top 用戶端 IP
      192.168.139.119 98.5% · 10.1.73.37 0.8% · 10.22.63.37 0.7%
```

**Top 端點** 區塊標題為 **佔比 · 平均回應時間**。每列顯示靠右對齊序號（`%2d.`，
使 ` 1.`…` 9.` 與 `10.` 的 URI 欄起始位置一致）、占 summary `總請求數` 之百分比，
以及各端點平均回應時間（秒，2 位小數）。

> **聚合範圍說明（GAP-3）。** 各端點的平均回應時間是從每個伺服器各自的
> `--top N` 輸出列加權聚合而來，並非該端點全量請求的平均值。這與筆數和百分比
> 所反映的母群體一致，因此在內部是自洽的。以外部 raw-gawk 方式重現時，必須先
> 複製各伺服器的 top-N 截斷再進行聚合，才能重現固定值。相較之下，overview 中
> 核心功能效能的類別筆數與平均值採全量累計，不受 `--top N` 截斷影響。

狀態碼分布（Top-N）作為描述性業務狀態統計予以保留。302 或 4xx 代碼可能仍會出現
於其中；此為設計如此（反映業務請求的實際 HTTP 回應分布）。

> 完整 summary 範例：[`../examples/sample-outputs/iis_summary_all_2026-05-21.txt`](../examples/sample-outputs/iis_summary_all_2026-05-21.txt)。

### Detail 視圖（text）

detail 視圖顯示含狀態碼、端點、Client-IP 百分比表格的逐伺服器 KV 區塊。
API 角色伺服器顯示 `Slow (>2000ms)`；APP 角色伺服器顯示 `Slow (>5000ms)`，
除非透過 `--slow-api-ms` / `--slow-app-ms` 覆寫。每個伺服器區塊最上方的
`Scope` 行確認當前有效模式。`/health` 排除在所有計數之外——包括
總請求數、端點、狀態碼、慢請求計數與客戶端 IP。

```
▶ IIS — 10.22.63.37
------------------------------------------------------------------------
  Scope                                   business requests (excl. /health; test-hosts=exclude)
  Total requests                          5
  Unique client IPs                       1
  Slow (>2000ms)                          0

    Status      Count     % of total
    --------------------------------
    200         5         100.0%

    Endpoint                                                 Avg(s)    Count     % of total
    ---------------------------------------------------------------------------------------
    /api/GetLungCancerReportURL                              0.02      5         100.0%

    Client IP           Count     % of total
    ----------------------------------------
    10.22.63.37         5         100.0%
```

> 完整 detail 範例（全區域）：[`../examples/sample-outputs/iis_all_2026-05-21.txt`](../examples/sample-outputs/iis_all_2026-05-21.txt)。
> 台北：[`../examples/sample-outputs/iis_taipei_2026-05-21.txt`](../examples/sample-outputs/iis_taipei_2026-05-21.txt)。
> 台中：[`../examples/sample-outputs/iis_taichung_2026-05-21.txt`](../examples/sample-outputs/iis_taichung_2026-05-21.txt)。

### Detail 視圖（tsv / csv）

使用 `--format tsv` 或 `--format csv` 時，detail 檔案 / 視圖為標準化長格式表格。
第一行為標頭，之後每個伺服器的每個指標各一列：

```
REGION  ROLE  SERVER         METRIC     KEY                      COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37    SUMMARY    TOTAL                    5      -        100.0
taipei  api   10.22.63.37    SUMMARY    SLOW                     0      -        0.0
taipei  api   10.22.63.37    SUMMARY    UNIQUE_IPS               1      -        0.0
taipei  api   10.22.63.37    STATUS     200                      5      -        100.0
taipei  api   10.22.63.37    ENDPOINT   /api/GetLungCancerReportURL  5  0.02     100.0
taipei  api   10.22.63.37    CLIENT_IP  10.22.63.37              5      -        100.0
```

`METRIC` 可能值：`SUMMARY`（總量：`TOTAL`、`SLOW`、`UNIQUE_IPS`）、
`STATUS`（各 HTTP 狀態碼）、`ENDPOINT`（各 URI，受 `--top` 限制）、
`CLIENT_IP`（各 IP，受 `--top` 限制）。`/health` 列不會出現在輸出中。
summary 視圖永遠為文字，與 `--format` 無關（summary 檔案永遠為 `.txt`）。

> 範例：[`../examples/sample-outputs/iis_detail_all_2026-05-21.tsv`](../examples/sample-outputs/iis_detail_all_2026-05-21.tsv) · [`../examples/sample-outputs/iis_detail_all_2026-05-21.csv`](../examples/sample-outputs/iis_detail_all_2026-05-21.csv)

---

## 3. `bin/analyze_errors.sh`

分析應用程式錯誤日誌與生命週期事件。

此模組**沒有 `--view` 旗標**：主控台永遠顯示 detail 視圖；summary 只寫入
磁碟（`errors_summary.txt`）。`errors_summary.txt` 與
`errors_detail.txt` 兩個檔案均永遠寫入執行子目錄。

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

`errors_summary.txt` 寫入執行子目錄，但不鏡像至主控台。
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
[共用輸出目錄]/<T>/
  overview_summary.txt
  iis_summary.txt
  iis_detail.txt              （text 預設；搭配 --format 可為 tsv/csv）
  access_summary.txt
  access_detail.txt           （或 .tsv / .csv 搭配 --format）
  access_ip_counts.tsv
  errors_summary.txt          （僅當 errors 在 --modules 中）
  errors_detail.txt           （僅當 errors 在 --modules 中）
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
| `--report-export` | flag | 關閉 | 否 | 對本次執行的 CSV 執行 `report-export` 容器，並將產出的 `YYYY-MM-DD_連線紀錄.xlsx` 附加至通知郵件。**需要 `--format csv` 與 access 模組。** 需要選配依賴 `docker`。使用 `<output-dir>/production/{input,state,output}`。詳見[報表匯出](#報表匯出)。 |
| `--top N` | uint ≥ 0 | `10` | 否 | 轉發給 iis（端點 + Client-IP）與 errors（模式）。`0` = ALL。 |
| `--slow-api-ms N` | uint ms | `2000` | 否 | 轉發給 overview 與 iis；適用於 API 角色伺服器。 |
| `--slow-app-ms N` | uint ms | `5000` | 否 | 轉發給 overview 與 iis；適用於 APP 角色伺服器。 |
| `--merge` | flag | 關閉 | 否 | 轉發給 access 與 iis。**需要 `--region all`**。 |
| `--test-hosts exclude\|only\|all` | enum | `exclude` | 否 | 轉發給 overview、iis 與 access。**不**轉發給 errors（`analyze_errors` 不接受此旗標——直接傳入為致命錯誤）。詳見[測試主機過濾](#測試主機過濾)。 |
| `--notify` | flag | 關閉 | 否 | 在 `main()` 最後一步、所有請求的模組皆已完成後，將本次執行持久化的報告包透過 SMTP API 寄出。選配依賴 `curl`/`base64` 僅在此旗標被設定時才會檢查。收件者讀自 `conf/receivers.conf`。**寄送失敗為致命錯誤**——如需容忍失敗，請以 `\|\| true` 組合。詳見[通知功能](#通知功能)。 |
| `--notify-dry-run` | flag | 關閉 | 否 | 建構完整 payload 並寫入 `<RUN_OUTPUT_DIR>/notify_payload.json`（權限 `0600`），永不呼叫 `curl`。需搭配 `--notify`。 |
| `--notify-attach all\|summary` | enum | `all` | 否 | 決定哪些持久化檔案成為附件。`all`（預設）附上本次執行產出的每一個檔案，包含 `access_detail.*` 與 `access_ip_counts.tsv`。`summary` 僅收斂為 `*_summary.txt` 檔案。需搭配 `--notify`。 |
| `--notify-url URL` | url | `""` | 否 | 覆寫 SMTP API 端點。解析順序：旗標 > `$LOG_PARSE_NOTIFY_URL` > 內建預設值（`http://haididev.intra.nhi.gov.tw:8080/api/email/send`）。即使在 `--notify-dry-run` 下也會驗證。需搭配 `--notify`。 |
| `--receivers-conf FILE` | path | `conf/receivers.conf` | 否 | 覆寫收件者設定檔，檔案必須存在且至少含一列合法的 `DISPLAY_NAME\|ADDRESS`。需搭配 `--notify`。 |
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
| `--test-hosts` | F | F | F | — |
| `--output-dir`、`--modules` | 自身 | 自身 | 自身 | 自身 |
| `--notify`、`--notify-dry-run`、`--notify-attach`、`--notify-url`、`--receivers-conf` | — | — | — | — |
| `--report-export` | — | — | — | — |

F = 轉發並由子模組執行。`--output-dir` 由 log_report 解析一次後透過
`$LOG_PARSE_OUTPUT_DIR` 共用；不以旗標形式轉發給子模組（防止指定
自訂 `--output-dir` 時發生分裂腦問題）。`--notify*` 旗標家族永不轉發給任
何子模組——它完全在 `log_report.sh` 行程內處理，於 `main()` 最後一步、
所有請求的模組皆已執行完畢後才觸發。詳見[通知功能](#通知功能)。
`--report-export` 同樣永不轉發——它在行程內執行，位於模組迴圈與通知步驟
之間。詳見[報表匯出](#報表匯出)。

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

# 10. 每日報告，寄送至 conf/receivers.conf（附上本次執行的所有持久化檔案）
bash bin/log_report.sh --log-dir "$LOG_DIR" \
    --date 2026-05-21 --notify
```

> 完整合併報告範例見 [`../examples/sample-outputs/log_report_full_2026-05-21.txt`](../examples/sample-outputs/log_report_full_2026-05-21.txt)。
> 台北部分報告：[`../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt`](../examples/sample-outputs/log_report_taipei_partial_2026-05-21.txt)。

### 通知功能

`log_report.sh --notify` 會在 `main()` 的最後一步、所有請求的模組皆已
完成並持久化各自檔案之後，將本次執行的持久化報告包透過內部 SMTP-relay
HTTP API 寄出。此功能為選配（opt-in）、單次寄送（無自動重試），且僅在
明確提供 `--notify` 時才會被觸發——所有既有工作流程完全不受影響。

**預設會寄出什麼。** 一份 JSON 文件，以 `Content-Type: application/json`
標頭 POST 送出：

```json
{
  "From": { "DisplayName": "系統通知", "Address": "notify@nhi.gov.tw" },
  "To": [ { "DisplayName": "Jason Chao", "Address": "jason.chao@cohesiondata.com" } ],
  "Subject": "【肺癌報告】 調閱紀錄彙整資訊 - 2026-05-21",
  "Body": "Run timestamp : 20260521_090000\nAnalysis range: 2026-05-21 ~ 2026-05-21\n...（本次執行的 KEY SUMMARY，見下方）",
  "Attachments": { "access_detail.txt": "<base64>", "overview_summary.txt": "<base64>", "...": "<base64>" }
}
```

`From` 為單一物件（寄件者身分）；`To` 為**陣列**，`conf/receivers.conf`
每一列對應一個物件，順序與檔案內順序一致；`Attachments` 為
**key-value 對照表**——key 為附件檔名，value 為其 base64 內容——
並非物件陣列。整份 payload 中不存在 `isBodyHtml`、`cc`、`bcc`、
`fileName` 或 `contentBase64` 任何一個鍵——該 API 一律將 `Body` 無條件
渲染為 HTML，因此本就沒有任何開關可切換。

`Body` **並非**慣例樣板文字：其內容由 gawk 從本次執行自身的
`overview_summary.txt` 擷取而來的真實 KEY SUMMARY（信封資訊 + 
`▶ 總體概況` 區塊，包含 `整體健康判定` 判定），後接附件清單。由於該 API
將 `Body` 渲染為 HTML，寄出前整份內容會先經過 HTML 跳脫，再包裹於最小化
的 `<html><body><pre>...</pre></body></html>` 骨架中——`<pre>` 正是讓
下方欄位對齊得以在 HTML 郵件用戶端中保持完整、而非摺疊為一行的關鍵；
跳脫機制也代表：若某個附件檔名恰好含有 `<`、`>` 或 `&`，收件者看到的會
是文字 `a&lt;b&gt;&amp;c.txt`，而不會是可執行的標籤。內容本身（收件者
實際閱讀到的文字）並無改變。渲染範例（`--date 2026-05-21`，預設
`--notify-attach all`；為便於閱讀，以下省略 HTML 骨架）：

```
Run timestamp : 20260521_090000
Analysis range: 2026-05-21 ~ 2026-05-21
Region        : all
Modules       : overview, iis, access
Output dir    : ./reports/20260521_090000
Attach mode   : all

========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-21  →  2026-05-21  (1 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  存取關聯總數                            9
  NORMAL 正常流程                         6 (66.7%)
  ORPHAN 無對應簽發                       3 (33.3%)
  UNVERIFIED 簽發未使用                   0 (0.0%)
  平均 API→APP 延遲                       19.5s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

    ■ 核心功能效能 (Core Function Performance)
      雲端查詢    呼叫次數 11       回應時間 0.11s
      報告摘要    呼叫次數 186      回應時間 0.38s
      影像下載    呼叫次數 427      回應時間 0.93s
      核心功能存取合計 624

Attachments (6):
  access_detail.txt            3955 bytes
  access_ip_counts.tsv           28 bytes
  access_summary.txt            732 bytes
  iis_detail.txt               9231 bytes
  iis_summary.txt              1375 bytes
  overview_summary.txt         3821 bytes

Generated by log-parse. Full reports are attached and also retained at
./reports/20260521_090000 on the analysis host.
```

擷取器會在遇到每小時橫條圖（一整片區塊繪製字元，在等寬字型以外的郵件
字型中不可讀）或第二個 `▶ ` 區段標題（兩者以先到者為準）時停止，並
另外設有 60 行的硬上限；整個 Body 在完成 HTML 跳脫與 `<pre>` 包裹**之後**
另外上限為 65536 bytes（超出時以一行明顯的截斷提示截斷——無論如何，
權威檔案本身永遠會完整附上）。若
`overview_summary.txt` 不存在（例如 `--modules iis`），Body 會退回顯示
字典序最前的 `*_summary.txt` 之前 25 行；若完全沒有任何 `*_summary.txt`，
則退回一行文字提示——Body 永不為空，其建構過程也永不中止寄送流程。

**收件者 — `conf/receivers.conf`。** 此檔案僅設定收件者（收件者清單）；
寄件者身分透過環境變數另行設定（見下表），不在此檔案中設定。每行一筆：

```
DISPLAY_NAME|ADDRESS
```

`#` 註解與空行會被忽略；每個欄位的前後留白與 CR 會被去除。至少需要一筆
資料——與 `regions.conf` / `test_hosts.conf` 相同的快速失敗契約：檔案
缺失、為空、或格式錯誤（欄位數錯誤、位址不合法、顯示名稱含
`` | , ; < > " `` 或控制字元、或位址重複）皆會在寄出任何內容前以明確
錯誤訊息中止。以 `--receivers-conf FILE` 覆寫路徑（預設
`conf/receivers.conf`）。隨附檔案預先種入一筆：

```
Jason Chao|jason.chao@cohesiondata.com
```

**環境變數**（全部為選配——每一項皆有可直接使用的預設值，因此單獨使用
`--notify` 永遠可行）：

| 變數 | 預設值 | 效果 |
|---|---|---|
| `LOG_PARSE_NOTIFY_URL` | `http://haididev.intra.nhi.gov.tw:8080/api/email/send` | API 端點；`--notify-url` 可覆寫。 |
| `LOG_PARSE_NOTIFY_SUBJECT` | 自動推導（依日期，見上）| 取代整個 `Subject` 字串；沒有對應旗標。 |
| `LOG_PARSE_NOTIFY_FROM_NAME` | `系統通知` | `From.DisplayName`。 |
| `LOG_PARSE_NOTIFY_FROM_ADDR` | `notify@nhi.gov.tw` | `From.Address`；驗證規則與 `conf/receivers.conf` 每一列相同。 |
| `LOG_PARSE_NOTIFY_CURL_BIN` | `curl` | 鎖定環境下的絕對 curl 路徑；亦為自動化測試替身掛鉤點。 |
| `LOG_PARSE_NOTIFY_INTERNAL_DOMAINS` | （空） | 以空白分隔的網域清單，列於此者豁免「外部網域」警告。 |
| `LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES` | `2097152`（2 MiB） | 單一附件原始位元組上限，於 base64 編碼前檢查。 |
| `LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES` | `8388608`（8 MiB） | 本次執行所有附件原始位元組總上限。 |
| `LOG_PARSE_NOTIFY_CONNECT_TIMEOUT` | `5` | `curl --connect-timeout`（秒）。 |
| `LOG_PARSE_NOTIFY_MAX_TIME` | `60` | `curl --max-time`（秒）。 |

**依賴套件 — 選配、延遲檢查。** `curl` 與 `base64` **不**屬於本工具組
的無條件依賴集合（`bash gawk sort date mktemp`）。兩者僅在
`lib/notify_utils.sh` 中被具名引用，且僅在確實提供 `--notify` 時才會被
檢查：`--notify-dry-run` 只需要 `base64`（絕不觸碰網路）；正式寄送則
兩者皆需。任何未使用 `--notify` 的執行完全不受影響，即使主機上兩者皆未
安裝亦然。若 `curl` 缺失，正式寄送會在任何日誌分析開始之前、於一秒內
即失敗，並輸出：

```
[ERROR] --notify needs the optional dependency 'curl' (HTTP client for the SMTP API).
[ERROR] Install curl, or use --notify-dry-run to build the payload without sending.
[ERROR] missing required commands: curl
```

在完全沒有對外網路存取的主機上，可使用 `--notify-dry-run` 離線驗證
payload 結構與收件者設定。

**退出碼。**

| 情境 | 退出碼 |
|---|---|
| 一切正常 | **0** |
| `--notify-dry-run` | **0** |
| 分析結果為空語料庫 | **0** — 不受影響；報告依然存在並如實反映此狀況，郵件仍會寄出 |
| 設定 / 驗證錯誤（`--notify-attach` 值不合法、URL 不合法、`conf/receivers.conf` 不合法、`LOG_PARSE_NOTIFY_FROM_ADDR` 不合法、`curl` 缺失） | **1** — 於參數解析階段即失敗，任何分析模組皆尚未執行 |
| 單一附件或本次執行附件總量超過上限 | **1** — 不會寄出任何內容 |
| SMTP API 回傳非 2xx 狀態，或請求本身傳輸失敗 | **1** |
| 任一分析模組本身執行失敗 | **1**，且**不會寄出郵件**（執行流程會在抵達通知階段之前就已中止） |

**寄送失敗為刻意設計的致命錯誤。** 既然操作者明確要求了通知功能，若郵件
無法送達，代表這次執行並未完成所要求之事，且沒有另外的「補寄」指令。
若排程執行必須在郵件中繼站無法連線時仍維持成功（綠燈），請以 shell
自行組合容忍行為——這是本專案既有的選配步驟慣例：

```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --notify || true
```

刻意不提供 `--notify-best-effort` 旗標。

**PII — 啟用前請詳閱。** 預設的 `--notify-attach all` 會將本次執行產出
的**每一個**檔案寄出，包含 `access_detail.*`（原始客戶端 IP 與 JWT 解碼
之 `BIRTHDAY` 明文出生日期欄位——見 [`design.zh-TW.md`](design.zh-TW.md)
§3.1.5）與 `access_ip_counts.tsv`（原始客戶端 IP 普查），且會寄給
**`conf/receivers.conf` 中列出的每一個地址**。沒有 `--to` 旗標——變更
收件對象必須編輯該版本控管、附有警告說明的設定檔，而非透過 crontab
打錯字。每次寄送皆會記錄（`WARN` 等級、無法關閉）完整收件者清單與完整
附件清單，並分別針對網域不在 `LOG_PARSE_NOTIFY_INTERNAL_DOMAINS` 中的
每個收件者提出外部網域警告。當收件者清單並非完全可信時，可使用
`--notify-attach summary` 將附件收斂為聚合層級的 `*_summary.txt` 視圖——
不含逐筆 IP，也不含 `BIRTHDAY` 欄位。預設端點為明文 HTTP；每次對
`http://` 端點寄送都會記錄一則明確警告，說明含附件在內的整份 payload
未經加密傳輸。

---

### 報表匯出

`log_report.sh --report-export` 會針對本次執行自身的 `access_detail.csv`
執行獨立的 [`report-export`](../report-export/README.md) Docker 映像，
並將產出的 `YYYY-MM-DD_連線紀錄.xlsx` 交付檔附加至 SMTP 通知郵件。此
功能為選配（opt-in）、單次執行（無自動重試），且執行順序嚴格位於分析
模組迴圈與 `--notify` 之間：所有請求的模組皆已持久化各自檔案之後，
容器才會執行；若匯出失敗，永遠會在任何郵件寄出之前中止（見下方「與
`--notify` 的順序保證」）。

**兩項硬性要求**，皆於參數解析階段強制檢查——早於 `resolve_interval`，
也早於任何分析器子行程啟動：

```
[ERROR] --report-export requires --format csv (got: 'text')
[ERROR] --report-export requires the access module (got --modules 'overview,iis')
```

需要 `--format csv` 是因為 CSV detail 檔案是 `report-export` 唯一接受
的輸入；需要 access 模組是因為 `analyze_access.sh` 是 `access_detail.csv`
的唯一產生者。

**`production/{input,state,output}` 目錄樹。** 與本工具組產出的其他
任何檔案不同，`report-export` 的 state 是**跨執行累積**的（其自身的
`REQUEST_ID` 去重機制仰賴於此），因此下列三個目錄會建立為時間戳執行
目錄的**同層目錄**，絕不巢狀於任一執行目錄內：

```
<--output-dir>/
├── production/
│   ├── input/    week-<WINDOW_START>.csv                 （已暫存的副本；:ro 掛載）
│   ├── state/    records.csv, records.csv.bak, runs.jsonl （跨執行累積）
│   └── output/   <run_date>_連線紀錄.xlsx                 （交付檔）
└── <YYYYMMDD_HHMMSS>/                                     （本次執行自身的報告檔案，不受影響）
    └── ...
```

三個子目錄名稱與 `production/` 本身皆為固定值，不可設定。四個目錄皆以
`mkdir -p` 於 `umask 077` 下建立，每一個目錄若為符號連結皆會被直接拒
絕（防止預先存在的符號連結掛載點，將 `docker -v` 綁定掛載重導向至任
意 host 目錄），接著才盡力（best-effort）`chmod 0700`；若先前**不同 uid** 的執行已
使其不可寫——最常見的情況是先前選擇了 `root`/`-` 選配跳出（見下
方）——本次執行會提早失敗，並附上明確的 `chown` 補救指令，而非一則
含糊的執行中權限錯誤。

**權限並非在每種檔案系統上都能獲得保證。** `chmod 0700`（目錄）與
`chmod 600`（暫存 CSV）皆為盡力而為：在不支援 Unix 權限位元的檔案系
統上——DrvFs/9p/WSL，而本專案自身的 `--output-dir` 就可能座落於此類
掛載點——`chmod` 經常被接受但實際上遭靜默忽略，使得該目錄樹在其他每
一項檢查皆通過的情況下，仍可能可被 owner 以外的人讀取。log-parse 會
將結果模式讀回，不一致時發出一則不可忽視的警告，列出所有受影響的
路徑：

```
[WARN] report-export: SECURITY: chmod 0700 did not take effect on: /srv/log-parse/production ... -- this filesystem may not support Unix permission bits (common on DrvFs/WSL/9p mounts); the PII accumulating under production/ is NOT confidentiality-protected by chmod on this host. Restrict access by another means (host ACL, an encrypted volume, or a --output-dir on a filesystem that honours chmod).
```

此處刻意設計為警告，而非致命錯誤——若在此致命，將使 `--report-export`
在這類掛載點上完全無法使用——但也絕非靜默：在確認此警告未曾出現之
前，切勿將 `chmod 0700`/`600` 視為機密性保證；若部署場景認真看待
`production/state` 中累積的 PII，請優先選用真正支援 Unix 權限的檔案
系統作為 `--output-dir`。

**暫存檔名——分析窗口的起始日，而非執行日。** `access_detail.csv` 會
被複製（絕不移動）進 `production/input/week-<D>.csv`，其中 `<D>` 為
**分析窗口的第一天**：`--date D` → `D`；`--from A --to B` → `A`；
`--days N` → 滾動 N 天窗口中最早的一天；`--today` → 今天。重跑相同窗口
會覆寫同一個暫存檔名（記錄於 `INFO` 層級，「已暫存（內容相同）」）；
在先前暫存檔仍存在的情況下暫存另一個確實不同的窗口，會記錄於 `WARN`
層級（「覆寫既有暫存輸入」）後才覆寫——兩者皆為非致命的修復路徑，絕
不靜默處理。

**交付檔日期不必與分析窗口相符。** `report-export` 以其自身
`TZ=Asia/Taipei` 時鐘下的 `run_date`（容器內的 `date.today()`）為交付
檔命名——此值**無法**透過任何旗標、環境變數或 Docker 引數設定。今天執
行 `--report-export` 去匯出上週的分析窗口（回補）完全正常，會產出一份
以今天為日期的交付檔，暫存來源則是以更早日期命名的 CSV。完整權威範例
見 [`report-export/docs/usage.md`](../report-export/docs/usage.md)
（輸入 `week-2026-07-13.csv`，輸出 `2026-07-16_連線紀錄.xlsx`）。

**映像一次性建置**（於 `report-export/` 執行，而非本目錄）：

```bash
cd report-export
docker build -t report-export:1.0.0 -f docker/Dockerfile .
```

`--report-export` 本身絕不會建置或拉取映像。daemon 未啟動或映像尚未
建置時，會在分析開始前快速失敗：

```
[ERROR] docker image inspect failed for 'report-export:1.0.0' (daemon unreachable, or the image is not built/pulled on this host); build it with: docker build -t report-export:1.0.0 -f docker/Dockerfile .   (run from report-export/)
```

**實際送出的 `docker run` 指令。** 恰為三個固定 bind mount、
`--network none`（容器不需要任何網路存取；此舉杜絕本 CSV 所含 PII 的
任何滲漏路徑），且**預設會**附上呼叫者（invoking）使用者的
`--user <uid>:<gid>`：

```
docker run --rm --network none \
  -v <output-dir>/production/input:/data/input:ro \
  -v <output-dir>/production/state:/data/state \
  -v <output-dir>/production/output:/data/output \
  --user <uid>:<gid> \
  report-export:1.0.0 /data/input/week-<WINDOW_START>.csv
```

`<uid>:<gid>` 即 `${UID}:${GROUPS[0]}`——僅使用 bash 內建功能，不新增
對 `id` 的依賴。`report-export` 映像本身仍然無 `USER` 指令，針對
*獨立、手動*執行時依然依設計以 root 執行（見
[`report-export/docs/usage.md`](../report-export/docs/usage.md)「HOST
權限說明」）——此事實與該份文件皆未變動。但 `log_report.sh
--report-export` 並非獨立執行：當同時提供 `--notify` 時，它會緊接著
在 **host** 端把交付檔讀回，以進行 base64 附加（見下方「將 xlsx 附加
至郵件」）；而容器在完全不帶 `--user` 時所寫出的、歸屬 root、模式
`0600` 的檔案，對執行 `log_report.sh` 的（通常為非 root）使用者而言
是無法讀取的。預設附上 `--user` 正是為了填補這個落差：容器所綁定掛
載的 `production/{input,state,output}` 目錄本就歸屬同一個
uid（見 [`design.zh-TW.md`](design.zh-TW.md) §4.10.3），因此容器自身的寫
入行為完全不受影響，而交付檔回傳時就會歸屬、且可被下一步需要讀取它
的行程讀取。

兩項逃生口，皆透過 `LOG_PARSE_REPORT_EXPORT_USER`（見下表）：以數字
`uid[:gid]` 覆寫預設目標；或以哨符 `root`（不分大小寫）或 `-` 完全選
配跳出 `--user`。選配跳出會恢復原本的取捨——`production/state` 與
`production/output` 下的檔案將**歸屬 root**，需要 `sudo` 才能從 host
端刪除或編輯（與 `report-export` 自身文件針對手動執行所記載的取捨相
同），且因為交付檔此時對非 root 操作者而言無法讀取，`log_report.sh`
本身也必須以 root 執行，`--notify` 才能將其附加。

**環境變數**（全部為選配）：

| 變數 | 預設值 | 效果 |
|---|---|---|
| `LOG_PARSE_REPORT_EXPORT_DOCKER_BIN` | `docker` | 容器執行環境二進位檔；亦為自動化測試替身掛鉤點。 |
| `LOG_PARSE_REPORT_EXPORT_IMAGE` | `report-export:1.0.0` | 映像參照（正式環境可視需要 pin `@sha256:` digest）。支援含 port 的私有 registry，例如 `registry.example.com:5000/report-export:1.0.0`。 |
| `LOG_PARSE_REPORT_EXPORT_USER` | （空） | **預設**（空值）：附上 `--user ${UID}:${GROUPS[0]}`，即呼叫者本身，如上例所示。**覆寫**：符合 `uid[:gid]`（僅限數字，例如 `1000:1000`）的值會逐字傳給 `docker run --user`。**選配跳出**：哨符 `root`（不分大小寫）或 `-` 會完全不附加 `--user`——容器以 root 執行，其輸出歸屬 root。其他任何值皆會在 preflight 階段、分析開始前直接失敗（die）。 |

**依賴套件 — 選配、延遲檢查。** `docker` **不**屬於本工具組的無條件
依賴集合（`bash gawk sort date mktemp`）。它僅在
`lib/report_export_utils.sh` 中被具名引用，且僅在確實提供
`--report-export` 時才會被檢查——一次 `docker image inspect` 往返，
同時確認 daemon 可連線與映像存在，次秒等級、於任何分析模組執行前完
成。任何未使用 `--report-export` 的執行完全不受影響，即使主機上完全
未安裝 `docker` 亦然。若 `docker` 本身缺失：

```
[ERROR] --report-export needs the optional dependency 'docker' (container runtime that runs the report-export image).
[ERROR] Install docker, or drop --report-export to produce the analysis reports only.
[ERROR] missing required commands: docker
```

**與 `--notify` 的順序保證。** `report_export_run` 嚴格先於
`notify_run` 執行。因為每一種匯出失敗都是致命錯誤，凡匯出未成功的
執行**絕不會**寄出通知——反過來的順序（先通知）可能寄出一封承諾附
上 xlsx、實際卻沒有附上的郵件，這對收件者而言是無法察覺的失敗。此時
分析報告早已持久化完成，因此致命處理不會造成任何分析結果損失：以相
同的 `--output-dir` 重跑即可，`report-export` 自身的 `input_sha256`
冪等性會吸收這次重試。`--report-export` 與 `--notify` 在其餘方面完全
**互相獨立**——兩者皆可單獨使用；僅使用 `--report-export` 時，xlsx 會
直接落在 `production/output`，`log_report` 會記錄其 host 路徑供操作
者尋找。

**將 xlsx 附加至郵件。** 當兩個旗標同時提供時，已驗證的交付檔路徑會
被傳入與收集本次執行自身檔案相同的 `notify_collect_attachments` 呼
叫，因此會原封不動地繼承既有的每一項規則：`notify_payload.json` 排
除規則、附件名稱衝突檢查、位元組大小探測、以獨立附件（絕非壓縮檔）
形式的 base64 編碼，以及郵件內文的附件清單。有兩項互動特別值得說明：

- **`--notify-attach summary` 不會隱藏 xlsx。** 該模式原本會將附件
  收斂為 `*_summary.txt` 檔案，但 xlsx 正是操作者傳入 `--report-export`
  的全部目的，因此刻意豁免於該過濾規則之外，永遠會與 summary 檔案一
  併附上。
- **xlsx 不豁免於大小上限。** `LOG_PARSE_NOTIFY_MAX_ATTACH_BYTES`
  （預設 2 MiB）與 `LOG_PARSE_NOTIFY_MAX_TOTAL_BYTES`（預設 8 MiB）
  對其套用方式與其他任何檔案完全相同。超過上限會明確且致命地失敗
  （`NOTIFY_RESULT status=skipped reason=attachment_too_large:<name>`）
  ——絕不會靜默寄出不完整的郵件。若本週的 xlsx 可能超過預設單檔上
  限，請事先調高上限（見[通知功能](#通知功能)）。

```bash
# 週報整合執行：分析、匯出 xlsx、寄出全部內容
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --days 7 --format csv --output-dir /srv/log-parse \
    --report-export --notify
```

**針對內建範例端到端試跑。** 一旦映像建置完成（見上文），無需任何正
式環境資料或網路存取，即可端到端演練完整流程：
`examples/sample-logs/LUNG-CANCER-REPORT-LOG` 中 `--date 2026-05-21`
的範例資料，其六筆 `STATUS=NORMAL` 存取紀錄已附有真實、可被參照表解
析的 `CLIENT_IP`/`HOSP_ID`/`PRSN_ID` 值，因此下列單一指令即會執行分
析、暫存 CSV、呼叫真正的 `report-export:1.0.0` 映像、並選取交付
檔——且因提供了 `--notify-dry-run`，會將郵件 payload 寫入檔案而非寄
出：

```bash
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --format csv --output-dir /tmp/log-parse-demo \
    --report-export --notify --notify-dry-run
```

此指令會在 `/tmp/log-parse-demo/` 下產出
`production/output/<run_date>_連線紀錄.xlsx`（容器摘要：`normal=6,
unique_ips=5, unmapped_hosp_ids=0`），並將本次執行的
`notify_payload.json` 寫出，xlsx 為其第 7 個附件——上文「將 xlsx 附加
至郵件」的每一個步驟皆可在完全不觸及真實 SMTP 端點的情況下直接檢視
（`conf/receivers.conf` 仍需符合平常「至少一列」的要求，
見[通知功能](#通知功能)；`--notify-dry-run` 只是不會真的寄出）。
此舉並不會改變
`analyze_access` 本身針對該日期的 `STATUS` 判定——NORMAL/ORPHAN/UNVERIFIED
仍為 6/9——僅是這些原已為 `NORMAL` 的紀錄上，原本空白的
`CLIENT_IP`/`HOSP_ID`/`PRSN_ID` 欄位如今已有值。

**PII 與資料保留 — 啟用前請詳閱。** `production/state` 會**無限期**
累積每一個不同週次的記錄——它是跨執行的 canonical state，而非單次執
行的暫存資料，本工具組不對其執行任何輪替或清除。資料保留是**操作者**
的責任（排程器明確不在本專案範圍內，見 CLAUDE.md §1）。首次啟用
`--report-export --notify` 前，請重新檢視 `conf/receivers.conf`：該
xlsx 攜帶與 `access_detail.csv` 相同、源自客戶端 IP 的 PII，會寄送給
該檔案列出的每一個地址。

**無內建逾時機制。** 卡住的 Docker daemon 或容器會無限期阻塞——
`timeout(1)` 不在本專案核准的依賴集合內。請以排程層級的逾時機制包裝
排程執行（`systemd` 的 `RuntimeMaxSec=`，或 `cron` 搭配自訂的 `timeout`
包裝）。

**失敗分診。** 每一種失敗皆為致命錯誤（exit 1）；分類方式由訊息內容
與可用 grep 篩選的
`REPORT_EXPORT_RESULT status=ok|failed reason=<slug> deliverable=<name|->`
stderr 行承載（比照 `NOTIFY_RESULT`）：

| `reason=` slug | 情況 | 操作者行動 |
|---|---|---|
| （分析前；尚無 result 行） | `--report-export` 未搭配 `--format csv` / 未搭配 access 模組 / `docker` 缺失 / 映像或 user-spec 覆寫值不合法 / `docker image inspect` 失敗 | 修正對應旗標、環境變數或映像建置後重跑；尚未建立任何執行目錄。 |
| `dirs` | `production/` 無法建立，或其解析後路徑不安全（層級過淺，或 `--output-dir` 解析為 `/`） | 檢查 `--output-dir` 與 host 檔案系統權限。 |
| `dirs_perm` | `production/{input,state,output}` 已存在但此 uid 無法寫入——通常代表**先前有不同 uid 的執行**（最常見為先前的 `root`/`-` 選配跳出） | 執行錯誤訊息中列印的確切 `sudo chown -R <uid>:<gid> .../production` 指令。 |
| `path_colon` | 解析後的 `--output-dir` 路徑含 `:` | `docker -v` 無法解析 host 路徑中的冒號；請改用不含冒號的路徑。 |
| `window_start` | 無法推導分析窗口的起始日 | 僅為防禦性檢查——理論上不應發生，因為 `resolve_interval` 在此步驟執行前早已驗證過區間；請視為統籌邊界缺陷回報。 |
| `source_missing` / `source_empty` | 本次執行的 `access_detail.csv` 缺失或為 0 位元組 | 確認已使用 `--format csv` 且 access 模組確實執行過；僅含表頭的 CSV 是合法的，**不屬於**此錯誤。 |
| `stage_compare` | 與既有的 `week-<D>.csv` 進行逐位元組比對時無法執行（兩檔其中之一無法開啟） | 檢查 `production/input/week-<D>.csv` 與本次執行自身 `access_detail.csv` 的權限/是否存在；通常為權限或暫時性 I/O 問題。 |
| `stage` | 複製/改名進 `production/input/` 失敗 | 檢查 `production/input` 的可用空間與權限。 |
| `container_usage` | 容器以 1 結束（用法錯誤） | 統籌邏輯缺陷——回報錯誤訊息上方列印的 argv。 |
| `container_input` | 容器以 2 結束（輸入驗證） | 暫存的 CSV 被拒絕；容器自身的 stderr（顯示於 die 訊息上方）會指出有問題的行號/欄位。 |
| `container_state` | 容器以 3 結束（state 完整性） | `production/state/records.csv` 完整性驗證失敗，且其 `.bak` 亦無法復原——見 [`report-export/docs/usage.md`](../report-export/docs/usage.md)「state 完整性問題」；需人工介入。 |
| `container_lock` | 容器以 4 結束（鎖被佔用） | 另一個匯出程序已鎖定 `production/state`；本次執行**未**匯出。確認無並行執行後，直接稍後重跑即可——絕不自動重試。 |
| `container_write` | 容器以 5 結束（寫入/參照錯誤） | 檢查 `production/output` 的可用空間與擁有權，或映像內建的參照表是否完整。 |
| `docker` | 其他任何非零 `docker run` 結束碼（例如 125–127） | 檢視顯示出的 stderr；通常屬於 Docker Engine 層級的失敗，而非 report-export 本身的問題。 |
| `summary_shape` | 容器以 0 結束，但 stdout 為空或超過一行 | 對未經修改的映像不應發生；視為統籌邊界缺陷處理，而非用猜測帶過。 |
| `summary_field` | 容器以 0 結束，但其 JSON 摘要的 `deliverable` 欄位數量為 0 或大於 1 | 同上。 |
| `deliverable_shape` | 回報的 `deliverable` 值未通過惡意輸入白名單，或對映後的 host 路徑為符號連結，或其解析結果落在預期輸出目錄之外 | 對未經修改的映像不應發生；予以拒絕，而非用猜測帶過。符號連結或非預期的路徑解析結果，視為潛在的滲漏嘗試（CWE-61），絕不跟隨。 |
| `deliverable_missing` | 回報的交付檔在 host 上不存在（或為空） | 幾乎必為 bind mount 或 uid 不符——請直接檢查 `production/output`。 |
| `deliverable_stale` | 回報的交付檔 mtime 早於本次呼叫 | 容器時鐘可能與 host 不同步，或有殘留舊檔案；請先調查後再信任該附件。 |

以上任一情況，本次執行自身的分析報告皆完好保留於
`<output-dir>/<RUN_TS>/` 之下——匯出失敗絕不會遺失任何已持久化的內容。

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
# 產出（子目錄名稱即為時間戳 T）：
#   ./reports/weekly/<T>/overview_summary.txt
#   ./reports/weekly/<T>/iis_summary.txt
#   ./reports/weekly/<T>/iis_detail.txt
#   ./reports/weekly/<T>/access_summary.txt
#   ./reports/weekly/<T>/access_detail.txt
#   ./reports/weekly/<T>/access_ip_counts.tsv
#   ./reports/weekly/<T>/errors_summary.txt
#   ./reports/weekly/<T>/errors_detail.txt
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

TSV/CSV 欄位參考（共 14 欄，依序）：
`REGION(1)` `STATUS(2)` `API_TIME(3)` `APP_TIME(4)` `DELTA_SEC(5)` `VERIFY_STATUS(6)`
`REQUEST_ID(7)` `API_SERVER(8)` `APP_SERVER(9)` `HOSP_ID(10)` `PRSN_ID(11)`
`CLIENT_IP(12)` `PATIENT_ID_AES(13)` `BIRTHDAY(14)`。

`BIRTHDAY(14)` 為報告連結 Token 之 JWT payload 解碼所得之出生日期
（`YYYYMMDD`；缺失或格式異常時為 `-`）——詳見
[`design.zh-TW.md`](design.zh-TW.md) §3.1.5「內部 schema — CORRELATE_AWK
輸出」。與 AES 加密之 `PATIENT_ID_AES` 不同，此欄位為明文 PII：匯出或
複製 detail 檔案時，請以與 `PATIENT_ID_AES` 相同之標準謹慎處理。

### 5.8 獨立管理總覽（台北，單日）

```bash
bash bin/analyze_overview.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei \
    --output-dir ./reports
```

### 5.9 測試主機稽核（非健康探針之內部 QA 客戶端流量）

使用 `--test-hosts only` 僅查看 `conf/test_hosts.conf` 中測試主機 IP 的
IIS 與存取活動（排除 `/health` 後）。適用於稽核內部 QA 工具行為，
而非查看健康探針流量（任何模式下健康探針都不可見）。

```bash
# 僅限測試主機客戶端 IP 的 IIS 報告（/health 已排除）
bash bin/analyze_iis.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts only --view summary

# 僅限測試主機客戶端 IP 的存取關聯
bash bin/analyze_access.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts only --view summary

# 完整報告，不過濾測試主機（all 模式）
bash bin/log_report.sh \
    --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --test-hosts all \
    --output-dir ./reports
```

`--test-hosts only` 範例請見 [`../examples/sample-outputs/iis_only_2026-05-21.txt`](../examples/sample-outputs/iis_only_2026-05-21.txt)。
`--test-hosts all` 範例請見 [`../examples/sample-outputs/iis_allmode_2026-05-21.txt`](../examples/sample-outputs/iis_allmode_2026-05-21.txt)。

---

## 6. 退出碼

| 代碼 | 意義 |
|------|------|
| 0 | 成功（即使所請求之期間無資料）。 |
| 1 | 用法 / 驗證錯誤：缺 `--log-dir`、旗標值非法、未知區域或模組、設定檔不存在（`regions.conf` 或 `test_hosts.conf`）、`--merge` 未搭配 `--region all`、提供超過一個區間選擇器，或將 `--test-hosts` 傳入 `analyze_errors`。 |

---

## 7. 環境變數

| 變數 | 效果 |
|------|------|
| `LOG_LEVEL` | `DEBUG` / `INFO`（預設）/ `WARN` / `ERROR`。`-v` 會覆寫為 DEBUG。 |
| `NO_COLOR` | 設定後關閉所有輸出之 ANSI 色碼。持久化檔案無論此變數為何，永遠不含色碼。 |
| `TMPDIR` | `mktemp -d` 之根目錄；預設 `/tmp`。 |
| `LOG_PARSE_OUTPUT_DIR` | 持久化檔案的預設輸出目錄。`--output-dir DIR` 旗標可覆寫。當此變數與旗標皆未設定時，回退至字面值 `./log-parse`。 |
| `LOG_PARSE_RUN_TS` | 格式 `YYYYmmdd_HHMMSS` 的共用啟動時間戳。由 `log_report` 設定並匯出給子模組，使同一次執行的所有檔案共用相同後綴。在腳本或測試中可覆寫為固定值以產生確定性檔案名稱。 |
