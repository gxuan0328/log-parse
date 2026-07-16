# report-export

> LUNG-CANCER-REPORT 週報「連線紀錄」Excel 匯出子工具 —— 以自動化取代
> 每週手動複製貼上進 Excel 模板的流程。

[![Tests](https://img.shields.io/badge/tests-377%2F377-brightgreen)](tests/)
[![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)](pyproject.toml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](../LICENSE)
[![Python 3.12+](https://img.shields.io/badge/python-3.12%2B-blue)](https://www.python.org/)

---

## 這是什麼

每週維運人員原本要把 `analyze_access --format csv` 的輸出手動貼進
`連線紀錄模板.xlsx`，靠 Excel 365 動態陣列公式（`FILTER`/`UNIQUE`/
`XLOOKUP`）過濾、累積、聚合出「調閱紀錄」與「院所分析」兩張報表。
`report-export` 把這個流程整個自動化成**一支一次性批次程式**：

- 讀入本週原始 14 欄 CSV，過濾出 `STATUS=NORMAL` 的列。
- 以 `REQUEST_ID` 為自然鍵去重，累積進自己管理的持久化 state
  （`records.csv`，單一真實來源）。
- 由完整 state 重新產生一份 2-sheet 純值交付 xlsx：「調閱紀錄」（累積明
  細，本次新增批次整列黃底）與「院所分析」（按 CLIENT IP 聚合的院所統
  計）。
- 相同輸入重跑**冪等**：不會重複追加、不會破壞既有 state，會產生等價
  的交付檔。

**這不是**常駐服務、不是資料庫，也**不**與本儲存庫既有的 `log-parse`
bash/gawk CLI 共用任何程式碼或設定——兩者完全解耦，各自獨立執行。

**PII**：關係人已確認本工具處理的所有欄位皆可正常操作與記錄，**不**含
資料遮罩、靜態加密或合規緩解機制；安全姿態聚焦於一般工程衛生（非 root
容器、唯讀根檔案系統、無網路、hash 鎖定依賴）。詳見
[`docs/design.md`](docs/design.md) 第 14 章。

---

## 需求

**建議路徑：Docker（主機零安裝）**

- Docker（本專案以 29.x 驗證；只需能 `docker build`/`docker run`）。
- 除此之外，主機不需要安裝 Python 或任何套件——所有依賴（`openpyxl` +
  `et_xmlfile`）與參考資料（HOSP 對照表）都已烘焙進映像。

**替代路徑：host 直接執行（不經 Docker）**

- Python 3.12+。
- `pip install -r requirements.lock`（hash 鎖定，需要 `--require-hashes`
  相容的 pip）。
- 執行時必須自行指定 `--state-dir`/`--out-dir`（host 沒有容器預設的
  `/data/state`/`/data/output` 掛載點）。

---

## 快速開始

```bash
cd report-export

# 1. 建置映像（僅需一次；主檔或依賴更新後才需重建，見 docs/usage.zh-TW.md §8）
docker build -t report-export:1.0.0 -f docker/Dockerfile .

# 2. 準備目錄（僅需一次；務必由「將要執行 docker run 的你」建立，
#    否則會撞上 host 權限前置條件，見 docs/usage.zh-TW.md §4）
mkdir -p inbox state output

# 3. 每週：把本週輸入 CSV 放進 inbox/，然後一行指令
cp /path/to/this-weeks-export.csv inbox/week-2026-07-13.csv
docker run --rm --network none --read-only --tmpfs /tmp \
  --user "$(id -u):$(id -g)" -e TZ=Asia/Taipei \
  -v "$PWD/inbox:/data/input:ro" \
  -v "$PWD/state:/data/state" \
  -v "$PWD/output:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

執行成功時 stdout 會印出一行 JSON 摘要（新增筆數、去重跳過數、唯一 IP
數等），stderr 印出結構化日誌；exit code `0` 代表成功（詳見
[`docs/usage.zh-TW.md`](docs/usage.zh-TW.md) §2）。

---

## 輸出落地位置

| 目錄 | 內容 |
|------|------|
| `output/{今日日期}_連線紀錄.xlsx`（同日第二個不同批次自動加 `_02` 消歧） | 本次交付檔：「調閱紀錄」+「院所分析」兩張 sheet，純值、無公式，本次新增批次整列黃底。 |
| `state/records.csv` | 累積中的 canonical state（單一真實來源），**機器託管，勿用 Excel 開啟編輯**。 |
| `state/runs.jsonl` | 每次執行一行的 append-only 稽核紀錄。 |

`inbox/`、`state/`、`output/` 三個目錄皆為執行期機器產生/消費的內容，已
在 `.gitignore` 中排除，不會被提交入庫。

---

## 文件

| 文件 | 內容 |
|------|------|
| [`docs/design.md`](docs/design.md) | 完整設計文件：系統概觀、資料模型、管線階段、持久化/去重/xlsx 產生規格、Docker 規格、CLI、測試策略、邊界案例、安全、分階段建置序列。 |
| [`docs/usage.zh-TW.md`](docs/usage.zh-TW.md) | **操作手冊（runbook）**：CLI 語法、stdout/stderr/結束碼、Docker 每週執行、host 權限前置條件、NAS 鎖注意事項、交付檔名規則、復原程序、參考主檔更新程序。 |
| [`docs/data-fidelity.zh-TW.md`](docs/data-fidelity.zh-TW.md) | 型別/格式契約逐欄對照表（輸入 14 欄 → state 10 欄 → 交付 9+4 欄）、TEXT/datetime/int 型別理由、落地錨點、openpyxl round-trip 行為、機器託管檔案警告。 |

---

## 目錄結構速覽

```
report-export/
├─ README.md                # 本檔
├─ src/report_export/       # 套件本體（純函式核心 + I/O 邊界模組）
├─ reference/                # 捆綁的 HOSP_ID -> HOSP_ABBR 查表（入庫）
├─ template/                 # 入庫基線：來源模板 xlsx + e2e 輸入 fixture
├─ tools/export_hosp_table.py  # 一次性 dev/ops 匯出工具（不進執行期映像）
├─ tests/                    # 單元 + 端對端測試
├─ docker/                   # Dockerfile + docker-compose.yml（選配）
├─ docs/                     # design.md + usage.zh-TW.md + data-fidelity.zh-TW.md
├─ state/                    # 執行期 canonical state（.gitignore，執行後才出現）
├─ output/                   # 執行期交付檔（.gitignore，執行後才出現）
└─ inbox/                    # 選配的每週輸入投放區（.gitignore）
```

完整目錄結構與各檔案職責見 [`docs/design.md`](docs/design.md) 第 15 章。
