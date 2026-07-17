# report-export

> LUNG-CANCER-REPORT 週報「連線紀錄」Excel 匯出子工具 —— 以自動化取代
> 每週手動複製貼上進 Excel 模板的流程。

[![Tests](https://img.shields.io/badge/tests-391%2F391-brightgreen)](tests/)
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
  計，含 WEEKLY ACCESS 本週存取數 + TOTAL ACCESS 歷史累計）。
- 相同輸入重跑**冪等**：不會重複追加、不會破壞既有 state，會產生等價
  的交付檔。

**這不是**常駐服務、不是資料庫，也**不**與本儲存庫既有的 `log-parse`
bash/gawk CLI 共用任何程式碼或設定——兩者完全解耦，各自獨立執行。

**PII**：關係人已確認本工具處理的所有欄位皆可正常操作與記錄，**不**含
資料遮罩、靜態加密或合規緩解機制；安全姿態聚焦於一般工程衛生（hash
鎖定依賴；選配加回唯讀根檔案系統、無網路等硬化旗標）。詳見
[`docs/design.md`](docs/design.md) §4.6。

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

# 1. 建置映像（僅需一次；主檔或依賴更新後才需重建，見 docs/usage.md
#    「參考主檔（HOSP_ID對照表）更新程序」）
docker build -t report-export:1.0.0 -f docker/Dockerfile .

# 2. 準備你自己的資料目錄（僅需一次；哪裡都可以，只要存在即可；容
#    器以 root 執行，目錄擁有者為誰皆可寫入，見 docs/usage.md「HOST
#    權限說明」）
export HOST_INPUT_DIR=/path/to/your/input-dir
export HOST_STATE_DIR=/path/to/your/state-dir
export HOST_OUTPUT_DIR=/path/to/your/output-dir
mkdir -p "$HOST_INPUT_DIR" "$HOST_STATE_DIR" "$HOST_OUTPUT_DIR"

# 3. 每週：把本週輸入 CSV 放進 HOST_INPUT_DIR，然後一行指令
cp /path/to/this-weeks-export.csv "$HOST_INPUT_DIR/week-2026-07-13.csv"
docker run --rm \
  -v "$HOST_INPUT_DIR:/data/input:ro" \
  -v "$HOST_STATE_DIR:/data/state" \
  -v "$HOST_OUTPUT_DIR:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

容器以 root 執行（docs/usage.md「HOST 權限說明」），`--rm` 是唯一功
能性必要旗標；`--network none`/`--read-only`/`--tmpfs /tmp`/
`-e TZ=Asia/Taipei` 四項純屬選配硬化（預設不加，映像已內建
`TZ=Asia/Taipei`），安全敏感站點可自行加回，詳見
[`docs/usage.md`](docs/usage.md)「每週單一指令執行」。**注意**：容
器寫入 host 的檔案（`state/`、`output/`）歸屬 root，如需以一般使用
者身分刪除／編輯請用 `sudo`。

### 開箱即用快速驗證（`docker/example`）

不想先準備自己的資料？CWD 切到 `report-export/docker/`，直接用入庫
的 `docker/example/` 固定 fixtures 跑一次——輸出寫進 `.gitignore`
排除的 `example/run/` scratch，入庫的 `example/input/`＋
`example/state/records.csv` 全程保持乾淨、不受影響：

```bash
cd report-export/docker
mkdir -p example/run/state example/run/output
cp example/state/records.csv example/run/state/    # protect the committed seed
docker run --rm \
  -v "$PWD/example/input:/data/input:ro" \
  -v "$PWD/example/run/state:/data/state" \
  -v "$PWD/example/run/output:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

預期結果：stdout JSON `new_records=4`／`state_total=23`／
`unique_ips=12`／`batch_seq=2`；交付檔「調閱紀錄」第 21-24 列整列黃
底、第 2-20 列無底色。`docker compose` 版本、完整 12 列院所分析對照
表、重跑／重置步驟，見
[`docker/example/README.md`](docker/example/README.md) 與
[`docs/usage.md`](docs/usage.md)「開箱即用快速驗證」。

執行成功時 stdout 會印出一行 JSON 摘要（新增筆數、去重跳過數、唯一 IP
數等），stderr 印出結構化日誌；exit code `0` 代表成功（詳見
[`docs/usage.md`](docs/usage.md)「stdout 摘要」）。

### 正式運行（production）

固定用 `report-export/production/{input,state,output}` 目錄樹（CWD =
`report-export/`）跑真實週資料，`production/` 可改用任何絕對路徑：

```bash
cd report-export
mkdir -p production/input production/state production/output
# 把本週 CSV 放進 production/input/
docker run --rm --network none --read-only --tmpfs /tmp \
  -v "$PWD/production/input:/data/input:ro" \
  -v "$PWD/production/state:/data/state" \
  -v "$PWD/production/output:/data/output" \
  report-export:1.0.0 /data/input/week-YYYY-MM-DD.csv
```

`production/state` 須**跨週固定為同一目錄**（累積 canonical
state）；交付檔落在 `production/output`；`production/` 存放真實資
料，已 `.gitignore` 排除、不入庫。docker compose 形式與完整補充說
明，見 [`docs/usage.md`](docs/usage.md)「正式運行（production）」。

---

## 輸出落地位置

| 位置 | 內容 |
|------|------|
| `{out_dir}/{今日日期}_連線紀錄.xlsx`（同日第二個不同批次自動加 `_02` 消歧） | 本次交付檔：「調閱紀錄」+「院所分析」兩張 sheet，純值、無公式，全表儲存格置中、資料細框線、表頭粗下框線、欄寬自動 fit，本次新增批次整列黃底。「院所分析」5 欄：CLIENT IP/HOSP_ID/HOSP_ABBR 外，`WEEKLY ACCESS`（本週存取數）與 `TOTAL ACCESS`（歷史累計）；本週無存取之院所 `WEEKLY ACCESS` 顯示 `-`。 |
| `{state_dir}/records.csv` | 累積中的 canonical state（單一真實來源），**機器託管，勿用 Excel 開啟編輯**。 |
| `{state_dir}/runs.jsonl` | 每次執行一行的 append-only 稽核紀錄。 |

`{out_dir}`/`{state_dir}` 由你透過 `-v`/`--state-dir`/`--out-dir` 指
向自己選定的目錄（容器內固定掛載點為 `/data/output`/`/data/state`）；
`docker/example/input/`＋`docker/example/state/records.csv` 是入庫的
固定示範 fixtures，不受 `.gitignore` 影響；其 `example/run/` 執行期
scratch 則相反、已被 `.gitignore` 排除，見
[`docker/example/README.md`](docker/example/README.md) 與
[`docs/usage.md`](docs/usage.md)「開箱即用快速驗證」。

---

## 文件

| 文件 | 內容 |
|------|------|
| [`docs/design.md`](docs/design.md) | 設計規格：系統概觀、架構、模組規格（資料模型、管線階段、CLI 契約）、橫切關注（冪等性、錯誤處理、日誌、並行、效能、安全、Docker）、能力矩陣、邊界案例、測試策略、已知限制。 |
| [`docs/usage.md`](docs/usage.md) | **CLI 使用參考**：CLI 語法/選項/範例、stdout/stderr/結束碼、Docker 每週執行、host 權限說明、NAS 鎖注意事項、交付檔名規則、復原程序、參考主檔更新程序。 |
| [`docs/data-fidelity.md`](docs/data-fidelity.md) | 型別/格式契約逐欄對照表（輸入 14 欄 → state 10 欄 → 交付 9+5 欄）、TEXT/datetime/int 型別理由、落地錨點、openpyxl round-trip 行為、機器託管檔案警告。 |

---

## 測試

```bash
cd report-export
python3 -m ruff check src tests tools
python3 -m mypy --strict src tests
python3 -m coverage run -m pytest -q      # 391 個測試全綠
python3 -m coverage report                # gate >= 80%，實測 100%
```

CI 階段對齊 lint → test → analyze → build → deploy：`ruff`(lint) →
`mypy --strict`(analyze) → `pytest --cov`(test) → `docker build` →
容器內 `--network none` 跑一次 smoke test。

---

## 目錄結構速覽

```
report-export/
├─ README.md                # 本檔
├─ src/report_export/       # 套件本體（純函式核心 + I/O 邊界模組）
├─ reference/               # 捆綁的 HOSP_ID -> HOSP_ABBR 查表（入庫）
├─ template/                # 入庫基線：來源模板 xlsx + e2e 輸入 fixture
├─ tools/export_hosp_table.py  # 一次性 dev/ops 匯出工具（不進執行期映像）
├─ tests/                   # 單元 + 端對端測試
├─ docker/                  # Dockerfile + docker-compose.yml
│  └─ example/              # 入庫開箱即用快速驗證 fixtures（seed state + this-week 輸入，見 docs/usage.md「開箱即用快速驗證」）
└─ docs/                    # design.md + usage.md + data-fidelity.md（zh-TW）
```

canonical state、交付 xlsx、輸入投放目錄皆為**使用者自訂、置於本儲存
庫之外**的執行期資料（透過 `--state-dir`/`--out-dir`/`-v` 指定）；本
專案不預先規範任何固定的 host 資料目錄。以上即完整目錄結構；各模組職
責對照見 [`docs/design.md`](docs/design.md) §2.3 模組分解。
