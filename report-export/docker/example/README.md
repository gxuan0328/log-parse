# `docker/example` — 開箱即用快速驗證 fixtures

> 完整 CLI/Docker 使用參考見 [`../../docs/usage.md`](../../docs/usage.md)；
> 設計依據見 [`../../docs/design.md`](../../docs/design.md) §4.7.7、§7.2 E2E-7。

## 情境

這裡入庫了一組固定的 seed state + this-week 輸入，讓你**不需要準備
任何自己的資料**就能實際跑一次 `report-export`，同時驗證兩件事：

1. 院所分析（「院所分析」sheet）的 `WEEKLY ACCESS`／`TOTAL ACCESS`／
   `-` 三種情形——本週全新 IP（weekly == total）、既有 IP 本週亦有
   新列（weekly < total）、既有 IP 本週無存取（weekly 顯示 `-`）。
2. 調閱紀錄（「調閱紀錄」sheet）的**本批整列黃底**：本次匯入的 4 列
   全部黃底 `FFFFFF00`，既有的 19 列 seed 全部無底色。

這組 fixtures 與
[`../../tests/e2e/test_end_to_end.py`](../../tests/e2e/test_end_to_end.py)
之 `test_e2e7_docker_example_scenario_demonstrates_weekly_vs_total`
驅動的是同一份資料——手動跑一次與自動化測試斷言的是同一組數字。

## 目錄結構

```
docker/example/
├── input/
│   └── week-2026-07-13.csv   入庫、PRISTINE。this-week 14 欄輸入，
│                              CRLF，4 列全為 NORMAL，REQUEST_ID 為
│                              全新的 60000001..60000004。唯讀掛載
│                              （:ro），本節任何指令都不會寫入它。
├── state/
│   └── records.csv           入庫、PRISTINE 的 seed state。10 欄表
│                              頭 + 19 列，皆 BATCH_ID=1，位元組同
│                              tests/fixtures/expected_records_e2e1.csv。
│                              從不直接掛載——quickstart 一律先把它
│                              「複製」進 run/state/，工具只讀寫那份
│                              複製。
├── run/                      .gitignore 排除的執行期 scratch（唯一
│   │                         允許在 docker/example/ 內產生執行期資
│   │                         料的位置）。由 quickstart 的 `mkdir -p`
│   │                         建立，從不入庫。
│   ├── state/                 quickstart 把 seed 複製進這裡；工具
│   │                          會就地變動這份複製（records.csv 19 ->
│   │                          23 列、新增 records.csv.bak、
│   │                          runs.jsonl、暫時性 .lock）。掛載為
│   │                          /data/state（讀寫）。
│   └── output/                 交付檔 {今日日期}_連線紀錄.xlsx 落地
│                                於此。掛載為 /data/output（讀寫）。
└── README.md                  本檔。
```

**入庫（來源）／執行期（`run/` scratch）分離的理由**：`input/` 與
`state/records.csv` 是本節的**唯一真實來源**、必須保持 pristine 才
能無限次重複示範；若讓工具直接讀寫這兩者，跑一次就會把 seed 從 19
列變成 23 列、並在入庫樹裡留下 `output/`／`.lock`／`runs.jsonl` 等執
行期殘留（這正是本節存在之前的問題）。因此執行期資料一律落在
`run/`——一個 `.gitignore` 已排除、由 quickstart 當場建立、可隨時
`rm -rf` 重來的 scratch 目錄，`input/`＋`state/records.csv` 因而永遠
保持乾淨。

## 快速驗證（CWD = `report-export/docker`）

若尚未建置映像，先於 `report-export/` 執行一次：

```bash
cd report-export
docker build -t report-export:1.0.0 -f docker/Dockerfile .
```

以下兩種形式擇一，效果相同；CWD 皆為 `report-export/docker`。

### 形式一：docker run

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

# Reset between runs (committed fixtures are never touched):
#   rm -rf example/run
```

### 形式二：docker compose

```bash
cd report-export/docker
mkdir -p example/run/state example/run/output
cp example/state/records.csv example/run/state/    # protect the committed seed
HOST_INPUT_DIR="$PWD/example/input" \
HOST_STATE_DIR="$PWD/example/run/state" \
HOST_OUTPUT_DIR="$PWD/example/run/output" \
  docker compose run --rm report-export /data/input/week-2026-07-13.csv

# `docker compose` (no -f) auto-discovers docker-compose.yml in CWD (report-export/docker/);
# its `build.context: ..` resolves to report-export/. No compose-file edit needed.
# Reset between runs:  rm -rf example/run
```

CWD 就在 `report-export/docker/`（`docker-compose.yml` 所在目錄），
`docker compose` 因此不需要 `-f` 就能自動找到這份 compose 檔；其
`build.context: ..` 相對 `docker/` 解析回 `report-export/`——套用這
組 example 路徑**不需要修改 `docker-compose.yml` 本身**。

## 預期結果

stdout 摘要關鍵欄位（完整欄位說明見
[`../../docs/usage.md`](../../docs/usage.md)「stdout 摘要」）：

| 欄位 | 值 |
|------|-----|
| `new_records` | `4` |
| `state_total` | `23` |
| `unique_ips` | `12` |
| `batch_seq` | `2` |
| `rows_in` / `normal` | `4` / `4` |
| `dropped_nonnormal` / `skipped_cross_state` / `skipped_intra_batch` / `unmapped_hosp_ids` / `unknown_status_skipped` | 皆 `0` |
| `input_sha256` | `e9275483547bb3dbeaf120484a7b5d41cdabaf5eba709acf2788d38b9706252c` |
| `run_date` / `deliverable` | 容器今日業務日（`TZ=Asia/Taipei`），交付檔名隨之而定 |

交付檔 `example/run/output/{今日日期}_連線紀錄.xlsx` 的「院所分析」
sheet（12 列）：

| CLIENT IP | HOSP_ABBR | WEEKLY ACCESS | TOTAL ACCESS | 情形 |
|-----------|-----------|----------------|----------------|------|
| `10.250.77.10` | 瀚田診所 | `1` | `1` | 本週全新 IP——WEEKLY == TOTAL |
| `192.168.117.104` | 臺北虛擬診 | `1` | `4` | 既有 IP、本週亦有新列——WEEKLY < TOTAL |
| `10.245.1.125` | 秀傳醫院 | `2` | `9` | 既有 IP、本週亦有新列——WEEKLY < TOTAL |
| 其餘 9 個 IP（如 `10.243.129.44` 門諾醫院） | — | `-` | `1` | 本週無存取（僅存在於 seed 批次）——WEEKLY 顯示 `-` |

（即 WEEKLY = `['-','-','-','-','-','-',1,'-',2,'-','-',1]`、
TOTAL = `[1,1,1,1,1,1,4,1,9,1,1,1]`，首見序為 11 個 seed IP + 1 個本
週全新 IP。）

「調閱紀錄」sheet（表頭 + 23 列）—— REQ4 黃底驗證：

- **第 21-24 列**（本批 4 列，`BATCH_ID=2`）**整列黃底 `FFFFFF00`**；
  **第 2-20 列**（19 列 seed，`BATCH_ID=1`）**皆無底色**
  （`fill.patternType is None`）。這正是
  `tests/e2e/test_end_to_end.py::test_e2e7_docker_example_scenario_demonstrates_weekly_vs_total`
  以 `_highlighted_rows(records_sheet) == [21, 22, 23, 24]` 明確斷言
  的同一個觀察（design.md §3.7.3、§4.7.7）。

## 重跑／重置

```bash
cd report-export/docker   # 若尚未在此目錄
rm -rf example/run
```

`docker/example/input/`、`docker/example/state/records.csv` 兩個入庫
fixture 全程不受影響——`rm -rf example/run` 之後即回到最初的乾淨狀
態，可再次從「形式一」或「形式二」重新開始。

## 相關文件

- [`../../docs/usage.md`](../../docs/usage.md)「開箱即用快速驗證」——
  同一份 quickstart，含更完整的欄位說明與疑難排解連結。
- [`../../docs/design.md`](../../docs/design.md) §4.7.7（封裝與版控
  界線）、§7.2（E2E-7 測試規格）。
- [`../../tests/e2e/test_end_to_end.py`](../../tests/e2e/test_end_to_end.py)
  `::test_e2e7_docker_example_scenario_demonstrates_weekly_vs_total` ——
  驅動同一組 fixtures 的自動化回歸測試。
