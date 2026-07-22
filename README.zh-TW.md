# log-parse

> LUNG-CANCER-REPORT 系統的跨區域日誌分析工具組。
> 比對存取 Token、揭露 IIS 異常、追蹤應用程式生命週期事件，
> 涵蓋兩個區域共六台 API / APP 伺服器。

[![Tests](https://img.shields.io/badge/tests-356%2F356-brightgreen)](tests/run_tests.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-lightgrey)](https://www.gnu.org/software/bash/)

**語言**：[English](README.md) · **繁體中文**

---

## 工具用途

本工具讀取六台伺服器（台北 / 台中兩個區域）每日產生的原始日誌，
產出多份交叉比對後的分析報告：

| 模組                  | 輸入資料                                       | 產出內容                                                                        |
|-----------------------|----------------------------------------------|---------------------------------------------------------------------------------|
| `analyze_overview`    | 透過 `--emit-stats` 取得 IIS + Access 統計數據 | 管理總覽：兩切面版面 — ▶ 總體概況（存取 NORMAL/ORPHAN/UNVERIFIED 筆數+%；整體健康判定 >=90 正常/>=70 注意/<70 警告；■ 核心功能效能子區塊：雲端查詢/報告摘要/影像下載 呼叫次數+回應時間；核心功能存取合計）/ ▶ 分區別（各區 存取關聯 N 筆 N/O/U 散文 + 同三類別 呼叫次數+回應時間）；僅摘要、純文字 |
| `analyze_access`      | API + APP 存取 CSV                            | Token 簽發 ↔ 驗證流程、孤兒存取、未使用簽發；`--view summary|detail`           |
| `analyze_iis`         | IIS W3C 擴充欄位日誌                          | 純業務請求指標：慢請求、端點分析、狀態碼分布；`--view summary|detail`          |
| `analyze_errors`      | `app-all` / `app-error` / `app-lifetime`     | OracleDB 中斷、Top 錯誤模式、應用程式重啟停機時間                               |
| `log_report`          | 上述全部                                      | 統籌排程器；預設模組：`overview,iis,access`；errors 須透過 `--modules` 明確加入；可選擇透過 `--notify` 將持久化報告包寄出（見[通知功能](docs/usage.zh-TW.md#通知功能)），亦可透過 `--report-export` 匯出 `連線紀錄.xlsx` 交付檔（見[報表匯出](docs/usage.zh-TW.md#報表匯出)） |

所有報告預設僅反映**真實業務流量**：`/health` 請求無條件從所有 IIS 聚合中排除，`conf/test_hosts.conf` 所列的內部測試主機 IP 則透過 `--test-hosts exclude|only|all`（預設：`exclude`）在讀取階段即予以預先過濾。因此 `Total requests` / `IIS 總請求數` 僅反映真實外部用戶流量。

每次執行均會自動將報告寫入當前工作目錄下的 `./log-parse/`（可透過
`--output-dir DIR` 或 `$LOG_PARSE_OUTPUT_DIR` 覆寫）。佈局：
`<base>/<YYYYMMDD_HHMMSS>/<模組>_<類型>.<副檔名>`，其中時間戳為執行子目錄
名稱（同一次執行的所有檔案共用同一時間戳，並非附加於檔名之後）。檔案
永遠為無色彩純文字；stdout 始終輸出所選視圖（`--view summary|detail`）
的可管線化報告。

完整資料流與欄位語意請參閱 [`docs/design.zh-TW.md`](docs/design.zh-TW.md)，
每個 CLI 旗標說明請參閱 [`docs/usage.zh-TW.md`](docs/usage.zh-TW.md)。

---

## 快速上手

```bash
# 1. 驗證執行環境依賴項
make install-deps

# 2. 對範例資料集執行完整報告
make report LOG_DIR=./examples/sample-logs/LUNG-CANCER-REPORT-LOG REGION=all DAYS=7

# 3. 或單獨呼叫某一個分析模組
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --date 2026-05-21 --region taipei
```

### 常見使用情境

```bash
# 管理總覽 — 全區域、最近 7 天（兩切面：總體概況+核心功能 / 分區別+N/O/U）
bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG

# 每日例行 — 指定日期的完整快照（預設模組：overview→iis→access）
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21

# 資安調查 — 檢視台北區最近 7 天的孤兒 Token
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7

# DB 故障排查 — 台中區 Top 20 錯誤模式（errors 須明確列入 --modules）
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --top 20

# 週報含錯誤分析；報告寫入 ./reports/
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --modules overview,iis,access,errors \
    --output-dir ./reports

# 效能稽核 — IIS 詳細記錄匯出為 CSV（API >3s、APP >3s）
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-api-ms 3000 --slow-app-ms 3000 --format csv --view detail
```

---

## 專案目錄

```
.
├── bin/                     CLI 進入點
│   ├── analyze_access.sh    API/APP Token 交叉比對
│   ├── analyze_iis.sh       IIS W3C 日誌分析
│   ├── analyze_errors.sh    應用程式錯誤與生命週期分析
│   ├── analyze_overview.sh  管理總覽（兩切面：總體概況 / 分區別；核心功能子區塊）
│   └── log_report.sh        主控統籌器（預設：overview→iis→access）
├── lib/                     可重複使用之 shell 模組（sourced-only）
│   ├── common.sh            日誌、暫存目錄、依賴檢查、色彩狀態
│   ├── date_utils.sh        日期範圍生成、時間區間互斥驗證器
│   ├── csv_utils.sh         Access / IIS / app log 欄位擷取
│   ├── fmt_utils.sh         報告版面格式化
│   ├── output_utils.sh      常時持久化輸出（persist_init / persist_views）
│   ├── aggregate_utils.sh   共用指標計算與 CSV quoter（AGG_IIS_AWK）
│   ├── notify_utils.sh      SMTP-API 報告寄送（--notify；curl/base64 為選配）
│   └── report_export_utils.sh  report-export 容器整合（--report-export；docker 為選配）
├── conf/
│   ├── regions.conf         區域 ↔ 伺服器對應表
│   ├── test_hosts.conf      QA / 健康探針用戶端 IP（搭配 --test-hosts 使用）
│   └── receivers.conf       --notify 收件者清單（DISPLAY_NAME|ADDRESS）
├── docs/
│   ├── design.md / design.zh-TW.md   架構與資料流規格
│   └── usage.md  / usage.zh-TW.md    完整 CLI 參考
├── examples/
│   ├── sample-logs/         範例日誌資料集（隨專案附帶）
│   ├── sample-outputs/      範例輸出報告
│   └── *.sh                 情境驅動腳本
├── tests/
│   └── run_tests.sh         356 項功能測試套件
├── report-export/           獨立 Python 子工具：週報 xlsx 匯出
│   ├── src/report_export/   套件本體（純函式核心 + I/O 邊界）
│   ├── docs/                design.md · usage.md · data-fidelity.md（zh-TW）
│   ├── reference/           內建 HOSP_ID→HOSP_ABBR 對照表（gz）
│   ├── docker/              Dockerfile + compose + 入庫 example/ 示範
│   ├── tests/               391 項 pytest 套件（單元 + e2e）
│   └── README.md            子工具快速上手（zh-TW）
├── .claude/
│   ├── CLAUDE.md            核心慣例（每個 session 自動載入）
│   ├── rules/               路徑範圍細項慣例（按需載入）
│   └── skills/              專案層級自動化技能（如 feature-workflow）
├── CHANGELOG.md             版本紀錄
├── LICENSE                  MIT 授權
└── Makefile                 常用任務（test / lint / report）
```

---

## 執行環境需求

- **Bash** ≥ 4.0
- **GNU awk** (`gawk`) — 所有欄位擷取與聯結均仰賴
- **GNU date** — 處理日期運算（Linux 內建；macOS 請安裝 `coreutils` 並
  將 `gdate` 別名為 `date`）
- **coreutils**：`sort`、`mktemp`、`head`、`tail`
- **選配**（僅 `--notify` 使用時需要）：`curl`（HTTP POST）、`base64`
  （附件編碼）——延遲檢查；其餘所有工作流程即使未安裝兩者亦不受影響。
  詳見[通知功能](docs/usage.zh-TW.md#通知功能)。
- **選配**（僅 `--report-export` 使用時需要）：`docker`（執行附屬的
  `report-export` 映像）——延遲檢查；其餘所有工作流程即使未安裝亦不
  受影響。詳見[報表匯出](docs/usage.zh-TW.md#報表匯出)。

執行 `make install-deps` 可一次驗證。

---

## 設定檔

區域 ↔ 伺服器對應表存放於 [`conf/regions.conf`](conf/regions.conf)：

```
# REGION_ID|REGION_NAME|API_SERVERS|APP_SERVERS
taipei|台北|10.22.63.37|10.21.3.35,10.21.3.36
taichung|台中|10.1.73.37|10.1.72.35,10.1.72.36
```

執行時可加上 `--conf /path/to/custom.conf` 覆寫。

---

## 測試

```bash
make test            # 執行 tests/run_tests.sh
```

測試套件涵蓋五隻腳本、兩個區域、所有參數組合、驗證路徑、時間區間互斥
檢查、持久化輸出斷言，以及情境模擬。所有基準值皆取自隨專案附帶的
`examples/sample-logs/LUNG-CANCER-REPORT-LOG/` 範例資料。

---

## 附屬子工具 — report-export

獨立、與 log-parse 完全解耦的 Python 子工具，將每週「連線紀錄」Excel
交付自動化；讀入 `analyze_access --format csv` 的 14 欄 CSV、過濾
`STATUS=NORMAL`、以 `REQUEST_ID` 去重累積進自管 canonical CSV
state，每次執行皆重生 2-sheet 純值 `.xlsx`（調閱紀錄 + 院所分析）。

[![report-export tests](https://img.shields.io/badge/tests-391%2F391-brightgreen)](report-export/tests/)
[![report-export coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)](report-export/pyproject.toml)

不共用上述 bash/gawk 工具組任何程式碼；透過 Docker 或 Python 3.12+ 獨
立執行，與本儲存庫其餘部分完全解耦。快速上手見
[`report-export/README.md`](report-export/README.md)；完整設計與操作
參考見 [`report-export/docs/`](report-export/docs/)（`design.md` /
`usage.md` / `data-fidelity.md`，zh-TW）。

---

## 文件導覽

| 文件                                                              | 適用對象            | 內容主旨                                  |
|-------------------------------------------------------------------|---------------------|-------------------------------------------|
| [`docs/design.md`](docs/design.md) · [中文](docs/design.zh-TW.md) | 新進貢獻者          | 架構、模組、資料流、輸出欄位語意          |
| [`docs/usage.md`](docs/usage.md) · [中文](docs/usage.zh-TW.md)    | 系統營運 / SRE      | 每個旗標的完整參考與可貼上的範例命令      |
| [`.claude/CLAUDE.md`](.claude/CLAUDE.md)                          | AI 助理與開發人員   | 程式碼慣例、bash 寫法、awk 模板           |
| [`CHANGELOG.md`](CHANGELOG.md)                                    | 所有人              | 版本紀錄（Keep a Changelog 格式）         |
| [`report-export/README.md`](report-export/README.md)              | 維運（週報 xlsx 匯出） | 獨立 Python 子工具；NORMAL→去重→2-sheet xlsx；zh-TW 文件 |

---

## 授權

[MIT](LICENSE) © 2026 log-parse contributors
