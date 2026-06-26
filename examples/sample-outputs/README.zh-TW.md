# 範例輸出

> **語言**：[English](README.md) · **繁體中文**

針對隨專案附帶之範例資料集（`examples/sample-logs/LUNG-CANCER-REPORT-LOG/`，
日期區間 2026-05-18 → 2026-05-25）預先產生之分析報告。

此目錄之內容已隨原始碼一併提交，便於審閱者在未建置執行環境前即可瀏覽
本工具組之輸出樣貌。可隨時依下表所列指令重新產生。

| 檔案                                       | 內容說明                                                          | 重新產生指令                                                                                                                                                                          |
|--------------------------------------------|-------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `access_taipei_2026-05-21.txt`             | 台北單日存取交叉比對（1 NORMAL、5 ORPHAN）                        | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei`                                                                |
| `access_taichung_2026-05-21.txt`           | 台中單日（全部為 NORMAL 流程）                                    | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung`                                                              |
| `access_taipei_week.txt`                   | 台北日期範圍 2026-05-21 → 2026-05-25                              | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-21 --to 2026-05-25 --region taipei`                                                |
| `access_all_week.tsv`                      | TSV 格式輸出，供下游 ETL / SIEM 進一步處理                        | `bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --from 2026-05-21 --to 2026-05-25 --format tsv`                                                   |
| `iis_taipei_2026-05-21.txt`                | 台北 IIS 指標 — 狀態碼分佈、Top 端點 + 平均回應時間              | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei`                                                                   |
| `iis_taichung_2026-05-21.txt`              | 台中 IIS — 包含 OracleDB 中斷引發之 50 筆 Health-503 事件         | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung`                                                                 |
| `iis_all_slow3000_2026-05-21.txt`          | 效能稽核 — `--slow-ms 3000`（慢請求門檻收緊為 3 秒）              | `bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --slow-ms 3000`                                                                    |
| `errors_taipei_2026-05-21.txt`             | 台北錯誤 — 含重啟事件，無 OracleDB 失敗                           | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei`                                                                |
| `errors_taichung_top20_2026-05-21.txt`     | 台中錯誤 — 44 筆 OracleDB 失敗、Top 20 錯誤模式                   | `bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taichung --top 20`                                                     |
| `log_report_full_2026-05-21.txt`           | 完整統籌報告 — 全模組、兩個區域                                   | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21`                                                                                    |
| `log_report_taipei_partial_2026-05-21.txt` | 部分模組（access + errors）僅針對台北                             | `bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21 --region taipei --modules access,errors`                                            |

所有輸出皆以 `NO_COLOR=1` 產生，以維持純文字可讀性。於 TTY 即時執行時
會以對應顏色呈現同樣內容。
