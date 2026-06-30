# 範例輸出

> **語言**：[English](README.md) · **繁體中文**

針對隨專案附帶之範例資料集（`examples/sample-logs/LUNG-CANCER-REPORT-LOG/`，
日期區間 2026-05-18 → 2026-05-25）預先產生之分析報告。

此目錄之內容已隨原始碼一併提交，便於審閱者在未建置執行環境前即可瀏覽
本工具組之輸出樣貌。可隨時依下表所列指令重新產生，或執行 `make samples-regen`
以確定性方式重建全部固定檔案。

> **預設行為 — 僅業務流量。**
> 所有報告均以 `--test-hosts exclude`（預設值）產生。
> 這代表：(1) 列於 `conf/test_hosts.conf` 中的內部 QA / 測試用戶端 IP
> （192.168.139.79、.110、.28）在聚合前即被排除；
> (2) `/health` 端點請求無論任何模式，均無條件從所有 IIS 聚合中排除。
> 因此 `Total requests` / `IIS 總請求數` 僅反映真實外部用戶流量。
> 若要顯示 QA 用戶端流量（非健康檢查部分），可使用 `--test-hosts only`；
> 若要同時包含業務與測試主機流量，則使用 `--test-hosts all`。

## 持久化輸出模型

每次執行均會將報告寫入指定目錄（預設為 `./log-parse/`，可透過 `--output-dir DIR`
或環境變數 `$LOG_PARSE_OUTPUT_DIR` 覆寫）。執行時產生的檔案名稱含啟動時間戳記：
`<模組>_<類型>_<YYYYMMDD_HHMMSS>.<副檔名>`。下表中提交的固定檔案採用去除時間戳記
的描述性名稱。如需產生名稱完全一致的檔案，可設定
`LOG_PARSE_RUN_TS=20260521_000000`。

所有輸出皆以 `NO_COLOR=1` 產生，以維持純文字可讀性。於 TTY 即時執行時
會以對應顏色呈現同樣內容。

## 總覽

總覽報告（`analyze_overview.sh`）呈現兩個切面：
- **總體概況 (Overall)：** 存取 NORMAL/ORPHAN/UNVERIFIED 筆數及其占存取關聯總數之百分比；平均 API→APP 延遲；整體健康判定（>=90 正常；>=70 注意；<70 警告；rate = trunc(NORMAL/存取關聯總數 × 100)）；其後緊跟 **■ 核心功能效能 (Core Function Performance)** 子區塊，包含三個 IIS 來源、UTC+8 日期修正的類別 — 雲端查詢（`/api/GetLungCancerReportURL`）、報告摘要（`/api/DigestSummary` 前綴）、影像下載（`/api/NhiPatientImage/studies/…` 前綴）— 各顯示呼叫次數與回應時間（秒，2 位小數），以及核心功能存取合計（純筆數，無百分比）。
- **分區別 (By Region)：** 每個在範圍內的區域各有一個 ■ 區塊，以散文形式列舉 `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)`，接著呈現同三個類別（呼叫次數 + 回應時間）。類別筆數與平均值採全量累計，不受 top-N 截斷影響。單一區域執行時（例如 `--region taipei`），分區別區塊會刻意與總體概況一致：此為 ROLLUP+明細的正確對稱行為，並非重複計算。

> **IIS UTC+8 日語意。** IIS W3C 日誌以 UTC+0 時間記錄。`--date D`（及 `--from`/`--to`）選取 UTC+8 業務日：讀取 `u_ex(D−1)`（UTC ≥ 16:00）與 `u_ex(D)`（UTC < 16:00）的資料列，涵蓋本地時間 00:00 至 23:59。存取與 .NET 應用程式日誌原生為 UTC+8，不受影響。

| 檔案 | 內容說明 | 重新產生指令 |
|------|----------|-------------|
| `overview_all_week.txt`               | 管理總覽報告 — 全區域，2026-05-18 → 2026-05-25（8 天）；兩切面版面：▶ 總體概況（存取筆數+%、整體健康判定 警告、■ 核心功能效能：雲端查詢 11/0.11s · 報告摘要 186/0.38s · 影像下載 427/0.93s；合計 624）、▶ 分區別（台北：0/3/0 NORMAL/ORPHAN/UNVERIFIED + 5/71/220 筆數；台中：6/0/0 + 6/115/207 筆數） | `bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --output-dir /tmp/sample` |
| `overview_taipei_week.txt`            | 管理總覽報告 — 僅台北，2026-05-18 → 2026-05-25；兩切面版面；分區別 台北 區塊與總體概況一致（單一區域範圍之 ROLLUP+明細對稱）；類別：雲端查詢 5/0.02s · 報告摘要 71/0.22s · 影像下載 220/1.48s；合計 296 | `bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --region taipei --output-dir /tmp/sample` |

## IIS 分析

> **IIS 日期選取。** `--date 2026-05-21` 代表 UTC+8 業務日 2026-05-21。模組讀取 `u_ex260520.log`（UTC ≥ 16:00）與 `u_ex260521.log`（UTC < 16:00），套用半開 UTC 篩選窗 `[2026-05-20 16:00:00, 2026-05-21 16:00:00)`。附帶的範例資料中所有業務資料列的 UTC 時間均 < 16:00（架構層面正確；此資料集數值上無影響）。

| 檔案 | 內容說明 | 重新產生指令 |
|------|----------|-------------|
| `iis_summary_all_2026-05-21.txt`     | IIS 管理摘要（全區域、單日）；KPI+%、Top 端點（佔比 · 平均回應時間）含靠右對齊序號 1–10 及各端點平均回應時間（聚合自各伺服器 top-N 子集；排名第 1 nhi-series 50.8%/1.05s）；狀態碼 / 用戶端 IP；格式無關文字輸出 | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --view summary --output-dir /tmp/sample` |
| `iis_all_2026-05-21.txt`             | IIS 詳細視圖 — 全區域，預設各角色慢請求門檻（API >2000ms、APP >5000ms）；僅業務流量（exclude）；總計 723 | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `iis_taipei_2026-05-21.txt`          | 台北 IIS 詳細視圖 — 各角色慢請求門檻；端點含 Avg(s)/Count/% of total，狀態碼含 % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `iis_taichung_2026-05-21.txt`        | 台中 IIS 詳細視圖 — 各角色慢請求門檻；端點含 Avg(s)/Count/% of total，狀態碼含 % of total | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --output-dir /tmp/sample` |
| `iis_all_merged_2026-05-21.txt`      | 跨區域合併 IIS 詳細視圖；兩個區塊：API_SERVERS（>2000ms）與 APP_SERVERS（>5000ms） | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge --output-dir /tmp/sample` |
| `iis_detail_all_2026-05-21.tsv`      | IIS 詳細視圖 — TSV 長格式（REGION/ROLE/SERVER/METRIC/KEY/COUNT/AVG_SEC/PCT 欄位）；單一標頭行，涵蓋所有伺服器 | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --format tsv --output-dir /tmp/sample` |
| `iis_detail_all_2026-05-21.csv`      | IIS 詳細視圖 — CSV（RFC-4180）；欄位結構同 TSV；適合試算表匯入 | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --format csv --output-dir /tmp/sample` |
| `iis_only_2026-05-21.txt`            | 模式範例：`--test-hosts only` — 僅顯示 QA / 測試用戶端 IP 的非健康檢查請求（192.168.139.110）；總計 209；台中伺服器均為零（無測試主機流量） | `NO_COLOR=1 LOG_PARSE_RUN_TS=20260521_000000 bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --test-hosts only --view detail --output-dir /tmp/sample` |
| `iis_allmode_2026-05-21.txt`         | 模式範例：`--test-hosts all` — 涵蓋所有非健康檢查用戶端 IP（業務 + 測試主機）；總計 932；適合檢視合併流量 | `NO_COLOR=1 LOG_PARSE_RUN_TS=20260521_000000 bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --test-hosts all --view detail --output-dir /tmp/sample` |

## 存取交叉比對

| 檔案 | 內容說明 | 重新產生指令 |
|------|----------|-------------|
| `access_summary_all_2026-05-21.txt`  | 存取管理摘要（全區域、單日）；NORMAL/ORPHAN/UNVERIFIED 筆數+%、延遲統計、分區別 | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --view summary --output-dir /tmp/sample` |
| `access_detail_all_2026-05-21.txt`   | 存取詳細視圖 — 全區域，2026-05-21；各區域 NORMAL/ORPHAN/UNVERIFIED 記錄資料表含 PATIENT_ID_AES | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `access_taipei_2026-05-21.txt`       | 台北單日存取詳細視圖（3 ORPHAN；已排除測試主機記錄）；各類別標頭、完整 PATIENT_ID_AES、合併 REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `access_taichung_2026-05-21.txt`     | 台中單日存取詳細視圖（全部為 NORMAL 流程）；各類別標頭、完整 PATIENT_ID_AES、合併 REQUEST_ID | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --output-dir /tmp/sample` |
| `access_taipei_week.txt`             | 台北日期範圍 2026-05-18 → 2026-05-25；詳細視圖 | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --region taipei --output-dir /tmp/sample` |
| `access_all_week.tsv`                | TSV 平面輸出（全區域、整週），供下游 ETL / SIEM 進一步處理；確定性 ASC 排序，單一 REQUEST_ID 欄位 | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format tsv --output-dir /tmp/sample` |
| `access_all_week.csv`                | CSV 平面輸出（全區域、整週），符合 RFC-4180 條件式引號；與 TSV 相同之確定性排序 | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-18 --to 2026-05-25 --format csv --output-dir /tmp/sample` |
| `access_all_merged_2026-05-21.txt`   | 跨區域合併交叉比對詳細視圖（所有區域視為單一主機無關語料庫）；合併後 NORMAL 數 >= 各區域加總 | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --merge --output-dir /tmp/sample` |

## 應用程式錯誤

| 檔案 | 內容說明 | 重新產生指令 |
|------|----------|-------------|
| `errors_summary_taipei_2026-05-21.txt` | 錯誤管理摘要（台北、單日）；各伺服器 Total ERROR、OracleDB 失敗次數、重啟次數 — 僅持久化至磁碟（無 `--view`；主控台固定顯示詳細視圖） | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_taipei_2026-05-21.txt`        | 台北錯誤詳細視圖（= 主控台輸出）— 含重啟事件，無 OracleDB 失敗 | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_detail_taipei_2026-05-21.txt` | 台北錯誤詳細視圖持久化檔案（內容同 `errors_taipei_2026-05-21.txt`；呈現持久化檔名規範） | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --output-dir /tmp/sample` |
| `errors_taichung_top20_2026-05-21.txt` | 台中錯誤詳細視圖 — 44 筆 OracleDB 失敗、Top 20 錯誤模式 | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --top 20 --output-dir /tmp/sample` |

## 統籌報告（log_report）

| 檔案 | 內容說明 | 重新產生指令 |
|------|----------|-------------|
| `log_report_full_2026-05-21.txt`          | 完整統籌報告 — 預設模組（overview → iis → access）、摘要視圖、全區域、單日；三個模組主控台鏡像輸出串接 | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --output-dir /tmp/sample` |
| `log_report_taipei_partial_2026-05-21.txt` | 部分模組（iis + access）僅針對台北、摘要視圖；依正規順序執行（iis 後接 access），無論 `--modules` 輸入順序為何 | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --modules iis,access --output-dir /tmp/sample` |
