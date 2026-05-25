# log-parse

> LUNG-CANCER-REPORT 系統的跨區域日誌分析工具組。
> 比對存取 Token、揭露 IIS 異常、追蹤應用程式生命週期事件，
> 涵蓋兩個區域共六台 API / APP 伺服器。

[![Tests](https://img.shields.io/badge/tests-103%2F103-brightgreen)](tests/run_tests.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-lightgrey)](https://www.gnu.org/software/bash/)

**語言**：[English](README.md) · **繁體中文**

---

## 工具用途

本工具讀取六台伺服器（台北 / 台中兩個區域）每日產生的原始日誌，
產出三份交叉比對後的分析報告：

| 模組             | 輸入資料                                | 偵測內容                                                          |
|------------------|----------------------------------------|-------------------------------------------------------------------|
| `analyze_access` | API + APP 存取 CSV                     | Token 簽發 ↔ 驗證流程、孤兒存取、未使用簽發                       |
| `analyze_iis`    | IIS W3C 擴充欄位日誌                   | 5xx 錯誤、慢請求、健康檢查 503 異常                               |
| `analyze_errors` | `app-all` / `app-error` / `app-lifetime` | OracleDB 中斷、Top 錯誤模式、應用程式重啟停機時間                 |
| `log_report`     | 上述全部                                | 統籌排程器，可輸出單一檔案或分模組檔案                            |

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
# 每日例行 — 指定日期的完整快照
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG --date 2026-05-21

# 資安調查 — 檢視台北區最近 7 天的孤兒 Token
bash bin/analyze_access.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taipei --days 7

# DB 故障排查 — 台中區 Top 20 錯誤模式
bash bin/analyze_errors.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --region taichung --top 20

# 週報 — 每模組輸出為獨立檔案
bash bin/log_report.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --from 2026-05-18 --to 2026-05-25 --output-dir ./reports

# 效能稽核 — IIS 慢請求門檻 3 秒
bash bin/analyze_iis.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \
    --slow-ms 3000
```

---

## 專案目錄

```
.
├── bin/                  CLI 進入點
│   ├── analyze_access.sh API/APP Token 交叉比對
│   ├── analyze_iis.sh    IIS W3C 日誌分析
│   ├── analyze_errors.sh 應用程式錯誤與生命週期分析
│   └── log_report.sh     主控統籌器
├── lib/                  可重複使用之 shell 模組
│   ├── common.sh         日誌、暫存目錄、依賴檢查
│   ├── date_utils.sh     日期範圍生成與檔名轉換
│   ├── csv_utils.sh      Access / IIS / app log 欄位擷取
│   └── fmt_utils.sh      報告版面格式化
├── conf/
│   └── regions.conf      區域 ↔ 伺服器對應表
├── docs/
│   ├── design.md / design.zh-TW.md   架構與資料流規格
│   └── usage.md  / usage.zh-TW.md    完整 CLI 參考
├── examples/
│   ├── sample-logs/      範例日誌資料集（隨專案附帶）
│   ├── sample-outputs/   範例輸出報告
│   └── *.sh              情境驅動腳本
├── tests/
│   └── run_tests.sh      103 項功能測試套件
├── .claude/
│   ├── CLAUDE.md         程式碼慣例與設計理念
│   └── skills/           專案層級自動化技能（如 feature-workflow）
├── CHANGELOG.md          版本紀錄
├── LICENSE               MIT 授權
└── Makefile              常用任務（test / lint / report）
```

---

## 執行環境需求

- **Bash** ≥ 4.0
- **GNU awk** (`gawk`) — 所有欄位擷取與聯結均仰賴
- **GNU date** — 處理日期運算（Linux 內建；macOS 請安裝 `coreutils` 並
  將 `gdate` 別名為 `date`）
- **coreutils**：`sort`、`mktemp`、`head`、`tail`

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

測試套件涵蓋四隻腳本、兩個區域、所有參數組合、驗證路徑，以及六種終端
使用者情境模擬。所有基準值皆取自隨專案附帶的
`examples/sample-logs/LUNG-CANCER-REPORT-LOG/` 範例資料。

---

## 文件導覽

| 文件                                                              | 適用對象            | 內容主旨                                  |
|-------------------------------------------------------------------|---------------------|-------------------------------------------|
| [`docs/design.md`](docs/design.md) · [中文](docs/design.zh-TW.md) | 新進貢獻者          | 架構、模組、資料流、輸出欄位語意          |
| [`docs/usage.md`](docs/usage.md) · [中文](docs/usage.zh-TW.md)    | 系統營運 / SRE      | 每個旗標的完整參考與可貼上的範例命令      |
| [`.claude/CLAUDE.md`](.claude/CLAUDE.md)                          | AI 助理與開發人員   | 程式碼慣例、bash 寫法、awk 模板           |
| [`CHANGELOG.md`](CHANGELOG.md)                                    | 所有人              | 版本紀錄（Keep a Changelog 格式）         |

---

## 授權

[MIT](LICENSE) © 2026 log-parse contributors
