# report-export — CLI 與 Docker 操作手冊（usage.zh-TW.md）

> 完整設計、資料模型、管線階段推導見 [`design.md`](design.md)；型別/格式
> 契約逐欄對照表見 [`data-fidelity.zh-TW.md`](data-fidelity.zh-TW.md)。
> 快速上手見 [`../README.md`](../README.md)。
>
> 本文件是**維運手冊（runbook）**：CLI 語法、Docker 每週執行、host 權限
> 前置條件、NAS 鎖注意事項、交付檔名規則、復原程序、參考主檔更新程序。
> 全部指令與輸出範例均對照實際執行結果核對，可直接複製貼上操作。

---

## 0. 這是什麼／不是什麼

`report-export` 是**一次性批次程式**：讀入一批「本週」原始 14 欄 CSV
（`analyze_access --format csv` 輸出），過濾 NORMAL 列、去重、累積進自管
canonical state，重新產生一份「調閱紀錄＋院所分析」兩張 sheet 的交付
xlsx。它取代目前手動複製貼上進 Excel 模板的每週流程。

- 不是常駐服務、不是資料庫、沒有 HTTP/RPC 介面。
- 與 `log-parse` 既有 bash/gawk CLI **完全解耦**：不共用程式碼、不動
  `bin/`/`lib/`/`conf/`。
- 每週跑一次，通常就是本文件 §3.3 的**單一一行 `docker run` 指令**。

---

## 1. 快速開始（TL;DR）

```bash
cd report-export

# 建置映像（僅需一次；主檔或依賴更新後重建）
docker build -t report-export:1.0.0 -f docker/Dockerfile .

# 準備目錄（僅需一次；由「將要執行 docker run 的你」建立，見 §4）
mkdir -p inbox state output

# 每週：把本週輸入 CSV 放進 inbox/，然後一行指令
cp /path/to/this-weeks-export.csv inbox/week-2026-07-13.csv
docker run --rm --network none --read-only --tmpfs /tmp \
  --user "$(id -u):$(id -g)" -e TZ=Asia/Taipei \
  -v "$PWD/inbox:/data/input:ro" \
  -v "$PWD/state:/data/state" \
  -v "$PWD/output:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

交付檔出現在 `output/{今日日期}_連線紀錄.xlsx`；`state/records.csv` 累積
本次新批次；stdout 印出一行 JSON 摘要，stderr 印出結構化日誌。

---

## 2. CLI 介面

### 2.1 語法

```
report-export INPUT [--state-dir PATH] [--out-dir PATH]
report-export --version
report-export --help

# 或（容器內即此形式）
python -m report_export INPUT [--state-dir PATH] [--out-dir PATH]
```

`report-export` 是 `pyproject.toml` 註冊的 `console_script`；容器
entrypoint 固定用 `python -m report_export`。兩者行為完全相同。

### 2.2 引數

**精瘦 CLI**：只有以下三項；其餘一切行為（去重策略、同日檔名消歧、完整性
檢查、`.bak` 備份、交付檔重建、鎖等待策略、摘要格式、日誌層級）全部烘焙
為內部預設，**沒有旗標可調**（YAGNI，design.md §11）。

| 引數 | 必填 | 預設 | 說明 |
|------|------|------|------|
| `INPUT`（位置引數） | 是 | — | 本批原始 14 欄 CSV 路徑。 |
| `--state-dir PATH` | 否 | `/data/state`（容器掛載點） | canonical state 目錄；host 直跑（無 Docker）時必須自行覆寫，例如 `--state-dir report-export/state`。 |
| `--out-dir PATH` | 否 | `/data/output`（容器掛載點） | 交付 xlsx 目錄；host 直跑時同樣必須覆寫。 |
| `--version` | 否 | — | 印出 `report-export 1.0.0` 並結束（exit 0）。 |
| `--help` / `-h` | 否 | — | 標準 argparse 說明並結束（exit 0）。 |

容器化執行（§3）時 `--state-dir`/`--out-dir` 的預設值恰好等於容器內掛載
點，因此**每週執行都不需要傳這兩個旗標**，只需换輸入檔路徑。

### 2.3 stdout — 單行 JSON 摘要

成功執行（exit 0）時，stdout **恰印出一行**（無其他文字）JSON 物件，欄位
依英文字母序排序：

```json
{"batch_seq": 1, "deliverable": "/data/output/2026-07-16_連線紀錄.xlsx", "dropped_nonnormal": 6, "input": "/data/input/week-2026-07-13.csv", "input_sha256": "2895c8f8bd8f3ed1e8cea6020f17d95374060bb9ddd04029a268ae0d0db5fdf3", "new_records": 19, "normal": 19, "rows_in": 25, "run_date": "2026-07-16", "skipped_cross_state": 0, "skipped_intra_batch": 0, "state_total": 19, "unique_ips": 11, "unknown_status_skipped": 0, "unmapped_hosp_ids": 0}
```

（以上為對 `template/source-log.csv` 之真實空 state 首次執行的實測輸出，
逐字截取。）

| 欄位 | 意義 |
|------|------|
| `deliverable` | 本次交付 xlsx 的完整路徑（容器內路徑）。 |
| `run_date` | 業務日（容器 `TZ=Asia/Taipei` 之今日），決定交付檔名。 |
| `batch_seq` | 交付檔中「最新批次」的 `BATCH_ID`；0 新增的冪等重跑也會回報**現有**最新批次號，而非虛構的下一號。 |
| `input` / `input_sha256` | 本次輸入檔路徑與 sha256（用於同日消歧比對、稽核）。 |
| `rows_in` | 輸入檔資料列總數（含未知 STATUS 被跳過者）。 |
| `normal` | 過濾後 NORMAL 列數。 |
| `dropped_nonnormal` | 被過濾掉的 ORPHAN/UNVERIFIED 列數。 |
| `new_records` | 本次真正新增進 state 的列數（去重後）。 |
| `skipped_cross_state` | 因 REQUEST_ID 已存在於既有 state 而跳過的列數。 |
| `skipped_intra_batch` | 因 REQUEST_ID 在本批次內重複而跳過的列數。 |
| `unknown_status_skipped` | STATUS 不屬於 NORMAL/ORPHAN/UNVERIFIED 而被跳過的列數。 |
| `state_total` | 執行後 state（`records.csv`）總列數。 |
| `unique_ips` | 院所分析的唯一 CLIENT IP 數。 |
| `unmapped_hosp_ids` | 本批中 HOSP_ID 查表未命中（HOSP_ABBR 解析為空）的列數。 |

摘要 JSON 適合直接餵給排程系統／監控（例如：`unmapped_hosp_ids > 0` 時發
通知去更新參考主檔，見 §8）。

### 2.4 stderr — 結構化日誌

所有日誌一律輸出到 stderr，格式為
`TIMESTAMP LEVEL logger=NAME msg=MESSAGE [key=val ...]`：

```
2026-07-16T10:16:27+0800 INFO     logger=report_export.transform msg=filtered to NORMAL rows dropped_nonnormal=6 normal=19
2026-07-16T10:16:27+0800 INFO     logger=report_export.pipeline msg=run complete deliverable='/data/output/2026-07-16_連線紀錄.xlsx' new_records=19
```

- 預設層級 `INFO`；可用環境變數 `REPORT_EXPORT_LOG_LEVEL`（非 CLI 旗標，
  內部/除錯用）提升，例如 `REPORT_EXPORT_LOG_LEVEL=DEBUG`。
- TTY 且未設 `NO_COLOR` 時上色，重導向/管線時自動變回純文字（stream 分
  離對排程系統友善）。
- **無遮罩**：REQUEST_ID／CLIENT_IP／HOSP_ID 等一律原樣記錄（design.md
  §14：關係人已確認無 PII 顧慮，本工具不做任何資料遮罩機制）。
- 去重警告會標明 `REQUEST_ID` + 輸入行號；HOSP_ID 未命中、同一 CLIENT IP
  對映多個 HOSP_ID 等資料品質訊號也是 WARNING 層級，**不會**讓程序失敗
  （exit 0）。

### 2.5 結束碼

`cli.py` 是全程式**唯一**攔截例外並轉換為結束碼的地方；其餘模組一律讓
型別化例外原樣往上拋（fail-fast、無 `except: pass`）。

| 碼 | 例外類別 | 觸發情境 | 操作者動作 |
|----|----------|----------|-----------|
| `0` | — | 成功；**含**有去重跳過（warn-skip）的情形——重複是重跑/重匯的預期結果，不算失敗。 | 無需動作；檢查摘要中 `skipped_*` 是否符合預期。 |
| `1` | `UsageError` | CLI 用法/參數錯誤（未知旗標、缺 `INPUT`、路徑含 NUL 位元組或無法正規化）。 | 修正指令，重新執行。 |
| `2` | `InputValidationError` | 輸入 CSV 驗證失敗：標題不符、欄數不符、編碼非 UTF-8、NORMAL 列缺/壞 APP_TIME、缺 APP_SERVER/CLIENT_IP。 | 檢視 stderr 錯誤訊息中的行號/欄名，修正上游輸出或本批輸入檔，重跑；state **未被異動**。 |
| `3` | `StateIntegrityError` | `records.csv` 尾列完整性驗證失敗，且 `.bak` 復原也失敗（見 §7.2）。 | 依 §7.2 手動排除；這是本工具最嚴重的失敗模式，需人工介入。 |
| `4` | `LockBusyError` | `state_dir` 已被另一執行中的程序鎖住；**立即失敗，不等待、不重試**。 | 確認是否真有另一批次在跑（見 §5）；若確定是殘留鎖，依 §7.3 排除後重跑。 |
| `5` | `WriteError` / `ReferenceError` | 交付檔或 state 寫入/IO 失敗（含 host 權限問題，見 §4）；或 `reference/hosp_id_map.csv.gz` 缺失/不可讀/格式錯誤。 | 依 §4（權限）或 §7.1（交付檔重建）排除；`reference/` 缺失通常代表映像建置不完整，需重建映像。 |

---

## 3. Docker 部署

### 3.1 建置映像

```bash
cd report-export
docker build -t report-export:1.0.0 -f docker/Dockerfile .
```

- **build context 必須是 `report-export/`**（不是 `docker/`）——Dockerfile
  的 `COPY src/ ...`、`COPY reference/... ...` 都是相對這個 context 根目
  錄解析。
- 基底映像 `python:3.12-slim` 以 **digest pin**（`Dockerfile` 內
  `ARG PYTHON_DIGEST`），非浮動 tag——數個月後重建仍解析到同一組位元組。
- 多階段：`builder` 用 `pip install --require-hashes -r requirements.lock`
  解析出 hash 鎖定的 venv（僅 `openpyxl` + `et_xmlfile`）；`runtime` 只複
  製這個 venv + `src/` + `reference/`，不含編譯工具鏈、pip cache、
  dev/test 依賴。
- 映像內建**非 root**使用者（`APP_UID`/`APP_GID`，預設 `10001:10001`，可
  用 `--build-arg` 覆寫）；`ENTRYPOINT ["python","-m","report_export"]`。
- 有效期較長的部署可加上 OCI label 追蹤：`hosp-data-version`（見 §8）、
  `org.opencontainers.image.version`。

### 3.2 Volumes

| 容器內掛載點 | 模式 | 用途 | 對應 CLI 預設 |
|--------------|------|------|----------------|
| `/data/input` | 唯讀（`:ro`） | 本批原始 14 欄輸入 CSV | 由指令列位置引數指定 |
| `/data/state` | 讀寫 | canonical state（`records.csv` 等） | `--state-dir` 預設值 |
| `/data/output` | 讀寫 | 交付 xlsx | `--out-dir` 預設值 |
| `/app/reference` | 映像內建、不掛載 | 捆綁的 HOSP 查表（build 時已 `COPY` 進映像） | — |

`/data/seed` 不存在——本工具**無 seeding 機制**（design.md §6.8），
canonical state 從空目錄起步，第一次真正批次即 `BATCH_ID=1`。

### 3.3 每週單一指令執行

```bash
docker run --rm --network none --read-only --tmpfs /tmp \
  --user "$(id -u):$(id -g)" -e TZ=Asia/Taipei \
  -v "$PWD/report-export/inbox:/data/input:ro" \
  -v "$PWD/report-export/state:/data/state" \
  -v "$PWD/report-export/output:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

逐旗標說明（**全部**均建議保留，不是可有可無的裝飾）：

| 旗標 | 作用 |
|------|------|
| `--rm` | 容器結束即刪除，不留殘留容器（一次性批次語意）。 |
| `--network none` | 本工具零對外連線需求；杜絕任何非預期網路存取面。 |
| `--read-only` | 容器根檔案系統唯讀；唯一需要寫入的路徑是掛載卷與 `/tmp`。 |
| `--tmpfs /tmp` | 配合 `--read-only`；映像設 `HOME=/tmp`，`--user` 選到的 uid 在容器內多半沒有 `/etc/passwd` 條目，任何需要臨時可寫空間或 home 目錄查找的行為都落在這裡。 |
| `--user "$(id -u):$(id -g)"` | **必要**，見 §4；否則新建的 host 目錄極可能因 UID 不符而寫入失敗（exit 5）。 |
| `-e TZ=Asia/Taipei` | 顯式標明業務時區（映像本身也已內建 `TZ=Asia/Taipei`；此處是雙重保險，不依賴日後映像預設值變動）。 |
| `-v .../inbox:/data/input:ro` | 本週輸入檔目錄，唯讀掛載。 |
| `-v .../state:/data/state` | canonical state，讀寫掛載，**必須跨週使用同一個目錄**（累積用）。 |
| `-v .../output:/data/output` | 交付 xlsx 落地目錄。 |

每週只需更換指令最後一行的輸入檔路徑（即 `/data/input/<本週檔名>`），其
餘完全不變。

### 3.4 docker compose（選配）

`docker/docker-compose.yml` 預接好上述三個掛載與硬化旗標，把每週執行縮成
一行 `docker compose run`。**注意**：compose 不會自動讀你 shell 的
`uid:gid`；且 `UID` 是 bash 唯讀特殊變數，`export UID=$(id -u)` 本身就會
失敗，因此必須改用（此檔已設計為接受）明確命名的 `DOCKER_UID`/
`DOCKER_GID`：

```bash
cd report-export
mkdir -p inbox state output
cp /path/to/this-weeks-export.csv inbox/

DOCKER_UID=$(id -u) DOCKER_GID=$(id -g) \
  docker compose -f docker/docker-compose.yml run --rm report-export \
  /data/input/this-weeks-export.csv
```

首次使用可省略手動 `docker build`——`docker compose run` 會在映像不存在
時自動建置（`build: {context: .., dockerfile: docker/Dockerfile}`）。

---

## 4. HOST 權限前置條件（務必先讀，HIGH）

**問題**：映像內建非 root 使用者，固定 UID（預設 `10001`）。若 host 上的
`state/`、`output/` 目錄是**全新建立**、由呼叫者（host 使用者）擁有，容
器內 UID `10001` 對這兩個目錄**沒有寫入權限**——第一次寫 `records.csv`／
交付 xlsx 就會失敗。這是典型「在開發機（bind mount 權限寬鬆）可跑、在正
式主機開箱即失敗」陷阱。

實測重現（未加 `--user` 覆寫時的真實失敗訊息）：

```
exit code: 5
stderr: ... msg=cannot prepare state_dir for locking: /data/state
        ([Errno 1] Operation not permitted: '/data/state') exit_code=5
```

**前置條件（務必遵守）**：

1. **每一次 `docker run`／`docker compose run` 都帶
   `--user "$(id -u):$(id -g)"`**（compose 用法見 §3.4 的
   `DOCKER_UID`/`DOCKER_GID`）——容器程序即以「掛載目錄的擁有者」身分執
   行，host 目錄天生可寫，產出檔案也歸操作者所有，而非歸 `10001`。
2. `state_dir`／`out_dir` 必須由**執行 `docker run` 這個指令的使用者自
   己**先 `mkdir -p` 建立（或至少存在且該使用者可寫）——即 §1/§3.3 範例
   中的 `mkdir -p inbox state output` 這一步不可省略。本工具本身也會在
   目錄存在時把權限收斂為 `0700`（`os.chmod`，只要你是該目錄擁有者就一
   定成功），但**前提是你已經擁有這個目錄**。
3. 若你的站點有標準化服務帳號、不想用 `$(id -u):$(id -g)`，可在
   **建置映像時**用 `--build-arg APP_UID=<uid> --build-arg APP_GID=<gid>`
   把映像預設非 root 使用者換成該服務帳號，並確保 host 目錄改由該帳號
   建立/擁有。
4. 若一定要用 named volume（而非本文件示範的 bind mount）：先以
   `docker run --user 0 ... chown <uid>:<gid> /data/state /data/output`
   之類的一次性指令初始化擁有者，或乾脆改用 bind mount（本文件的標準做
   法）。

---

## 5. NAS 鎖與並行注意事項

本專案的 `state_dir` 慣例上放在 NAS（網路儲存）掛載卷。`report-export`
在每次執行一開始就對 `{state_dir}/.lock` 取獨佔鎖，執行完畢釋放；取不到
鎖**立即**以 `LockBusyError`（exit 4）失敗，**從不等待、從不重試**。

- **主要保證來自維運層，不是這把鎖本身**：務必確保**同一時間只有一個操
  作者／一支 cron 排程**會對同一個 `state_dir` 呼叫本工具。這是第一守
  則，不是可選的最佳實踐。
- 原因：`fcntl.flock()` 在 NFSv3／CIFS 這類網路檔案系統上可能被模擬、降
  級、甚至靜默失效——鎖機制本身無法在這類檔案系統上提供強保證。
- 本工具的因應（defense-in-depth，非取代維運紀律）：優先嘗試
  `flock(LOCK_EX|LOCK_NB)`；偵測到檔案系統不支援 flock 時，自動退回
  `O_CREAT|O_EXCL` 哨兵鎖檔（`.lock.sentinel`，內含 `pid`/`host`/`utc`），
  並具備 **stale 偵測**（持鎖行程已不存在，或鎖齡超過 6 小時 → WARN 後
  自動回收）。
- **建議**：`state_dir` 置於 **POSIX-local** 磁碟，或至少是支援
  `lockd` 的 **NFSv4**；避免 NFSv3／CIFS。
- 啟動時會自動清除上次崩潰殘留的 `*.tmp` 檔（`records.csv` 本身因原子
  寫入保證只會「完整存在」或「不存在」，不會半寫殘留）。

---

## 6. 交付檔名規則與同日消歧

- 基本檔名：`{run_date:%Y-%m-%d}_連線紀錄.xlsx`（`run_date` = 容器
  `TZ=Asia/Taipei` 之今日）。
- **該檔名在 `out_dir` 中尚不存在**（當天第一次執行，最常見情形）→ 直
  接使用基本檔名。
- **該檔名已存在**：
  - 若 `runs.jsonl` 中**當天最後一次**記錄的 `input_sha256` 與本次**相
    同** → 判定為冪等重跑（同一輸入再跑一次）→ **沿用同一檔名覆寫**（確
    定性行為，見 §7.1）。
  - 若不同 → 判定為**當天第二個真正不同的批次**（例如補跑漏週、更正重
    匯）→ 自動加序號 `{run_date}_連線紀錄_{seq:02d}.xlsx`。
- **序號計算的實際行為**：`seq` = 當天**目前為止累計執行次數**（依
  `runs.jsonl` 當日筆數計）+ 1，**不是**「目前為止相異批次的次數」——換
  句話說，若當天先跑過一次冪等重跑（同輸入再跑一次）才接著跑真正不同的
  第二批次，序號會因為那次冪等重跑也被計入總執行次數，而不是單純的
  `_02`。**一般操作流程**（當天不刻意重跑同一輸入）下，第二個不同批次
  就是 `_02`，以此類推。
- 全程 `.tmp` 檔先寫、`fsync`，**在 `state.commit()` 已成功之後**才
  `os.replace` 成正式檔名（state-first 順序）——交付檔不會出現「已交付
  但尚未真正入 state」的批次。
- 容器內建 `LANG=C.UTF-8`/`LC_ALL=C.UTF-8`，確保中文檔名正確寫出。

---

## 7. 復原（Recovery Runbook）

### 7.1 交付檔遺失、被誤刪，或本次寫入失敗（exit 5）

**不需要任何特殊旗標或指令**——直接**用最近一次（也就是最新一批）的輸
入檔，對同一個 `state_dir` 重新執行一次即可**：

```bash
docker run --rm --network none --read-only --tmpfs /tmp \
  --user "$(id -u):$(id -g)" -e TZ=Asia/Taipei \
  -v "$PWD/report-export/inbox:/data/input:ro" \
  -v "$PWD/report-export/state:/data/state" \
  -v "$PWD/report-export/output:/data/output" \
  report-export:1.0.0 \
  /data/input/<最新一批輸入檔>
```

原理：交付 xlsx 每次執行都是由**完整 state 重新生成**的純投影，從不是
增量修補。重跑同一份最新輸入 → 該批 REQUEST_ID 已全數在 state 中 → 0
新增（`new_records:0`，`skipped_cross_state` 等於該批列數）→ state 位元
不變 → 但交付檔仍被完整重建，且黃底仍正確落在（既有的）最新批次。

**限制**：這只能重建**最新批次**的交付檔。重建任意「更早一批」的黃底標
記刻意不支援（YAGNI）——該週的交付檔理應已在當週交付當下由操作者存
檔留存。

### 7.2 state 完整性問題

`state.load()` 對 `records.csv` 尾列（`#META` 完整性描述子）的容忍策略：

| 情況 | 行為 | 需要人工介入？ |
|------|------|----------------|
| `records.csv` 不存在 | 視為空 state（正常首次執行路徑），非錯誤 | 否 |
| 尾列存在且 `records`/`sha256` 相符 | 正常載入 | 否 |
| 尾列**缺失**（如舊版檔案或被手動編輯過但本體未壞） | WARN，照常載入；下次 `commit()` 自動補上正確尾列 | 否（僅留意 WARN 日誌） |
| 尾列存在但 `sha256`/`records` **不符** | 嘗試改用 `records.csv.bak`；`.bak` 驗證通過則 WARN 後續行 | 視 `.bak` 是否有效而定 |
| 本體或 `.bak` 皆無法解析/驗證 | `StateIntegrityError`（**exit 3**） | **是** |

exit 3 時的人工排除步驟：

1. 先查看 `{state_dir}/records.csv.bak` 是否存在且看起來完好（純文字
   CSV，可用 `less`/文字編輯器安全檢視，**不要用 Excel 開啟儲存**，見
   [`data-fidelity.zh-TW.md`](data-fidelity.zh-TW.md) §8）。
2. 確認 `records.csv` 是否曾被非本工具的程序寫入/編輯過（第一守則：
   「機器託管，勿手動編輯」，同上）。
3. 若能判斷 `.bak` 或某個更早的已知良好副本才是正確狀態，手動
   `cp records.csv.bak records.csv` 後重跑一次，觀察是否恢復正常載入
   （會再次通過同一組驗證邏輯）。
4. 若兩者皆不可信，只能依 `runs.jsonl`（若仍完好）與當週已交付的歷史
   xlsx 交付檔，人工重建 `records.csv`（或就此重新從某個已知批次開始累
   積），這是本工具唯一沒有自動化覆蓋的失敗模式，設計上刻意如此（寧可
   在不確定時要求人工判斷，也不要靜默假設某個版本是對的）。

### 7.3 鎖被佔用（exit 4）

1. 先確認**真的沒有**另一個 `report-export` 執行中（`docker ps` / 對應
   host 上的行程）——這是最常見的合理原因（見 §5 的「同一時間只能一個
   操作者」）。
2. 若確定沒有其他執行中的行程，且錯誤訊息指出的是
   `state lock busy (sentinel): .../.lock.sentinel`，可查看該檔內容
   （`pid`/`host`/`utc`）判斷是否為某次異常中斷留下的殘留鎖；本工具本身
   會在鎖齡超過 6 小時或持鎖 PID 已不存在時**自動**回收，通常不需手動介
   入，只需靜置或稍後重試。
3. 若是 `state lock busy (flock): .../.lock`（真正的 flock 被某個仍存活
   的行程持有）且該行程確認已不會再結束（例如異常掛起），才需要手動介
   入排除該行程，本工具不提供強制奪鎖的旗標（刻意如此，避免競態下的雙
   寫）。

---

## 8. 參考主檔（HOSP_ID對照表）更新程序

執行期**從不**熱修改查表資料（design.md §9.4：更新路徑即重建映像）；未
命中的 HOSP_ID 只會累積為 WARN + 該列 HOSP_ABBR 解析為空字串（IFERROR
語意），不會讓執行失敗——這本身就是「主檔該更新了」的可觀測訊號
（stdout 摘要的 `unmapped_hosp_ids` 欄位）。

更新步驟：

1. 取得新版 `連線紀錄模板.xlsx`（或任何含 `HOSP_ID對照表` sheet、欄位
   為 `HOSP_ID,HOSP_ABBR` 的來源工作簿），置於
   `report-export/template/連線紀錄模板.xlsx`（或用 `--source` 指到別
   處）。
2. 重跑匯出工具（**dev/ops 用，不進執行期映像**）：
   ```bash
   cd report-export
   python3 tools/export_hosp_table.py \
       --source template/連線紀錄模板.xlsx \
       --out-dir reference
   ```
   此工具是 **fail-loud**：若新主檔的形狀（列數、重複鍵數、空白簡稱
   數、鍵長分布、前導零鍵數）與目前程式碼中鎖定的預期值不符，會直接印
   `FATAL: ...` 到 stderr 並以非零結束——這代表主檔的結構本身發生了實
   質變化（不只是內容新增），需要先確認是否也要調整
   `tools/export_hosp_table.py` 內的預期值，而不是略過驗證直接採用。
3. 檢視新舊 `reference/hosp_id_map.manifest.json` 的差異（`row_count`、
   `sha256`、`dup_keys`、`blank_abbr`、`leading_zero` 等），確認變化符合
   預期（例如列數應該只增不減、`dup_keys`/`blank_abbr` 應維持 0）。
4. 將更新後的 `reference/hosp_id_map.csv.gz` + `.manifest.json`（以及
   若一併更新的 `template/連線紀錄模板.xlsx`）提交入庫（git commit）。
5. **重建 Docker 映像**並 bump 版本標記：
   ```bash
   NEW_SHA256=$(python3 -c "import json; \
     print(json.load(open('reference/hosp_id_map.manifest.json'))['sha256'])")
   docker build \
     --build-arg HOSP_DATA_VERSION="$NEW_SHA256" \
     --build-arg IMAGE_VERSION=1.1.0 \
     -t report-export:1.1.0 \
     -f docker/Dockerfile .
   ```
   之後每週執行改用新 tag（`report-export:1.1.0`）。**更新路徑就是重建
   映像**——沒有執行期熱修查表的旗標（刻意如此，design.md §9.4 YAGNI）。

---

## 9. `state_dir` / `out_dir` 檔案總覽

| 路徑 | 內容 | 由誰產生 | 可否人工開啟檢視 |
|------|------|----------|-------------------|
| `{state_dir}/records.csv` | canonical state（10 欄 + 末列 `#META` 完整性描述子） | `state.commit()`（每次有新增時） | 純文字檢視可，**嚴禁**用 Excel 開啟儲存（見 [`data-fidelity.zh-TW.md`](data-fidelity.zh-TW.md) §8） |
| `{state_dir}/records.csv.bak` | 上一次提交前的 `records.csv` 快照（單一備份） | `state.commit()`（每次提交前自動備份） | 同上 |
| `{state_dir}/runs.jsonl` | append-only 稽核紀錄，每次執行一行 JSON | `state.append_run()`（每次執行） | 可，純文字 JSON Lines |
| `{state_dir}/.lock` | flock 鎖檔（存活期間含 PID） | `statelock.acquire()` | 執行期間存在，正常結束即釋放；不應手動編輯/刪除 |
| `{state_dir}/.lock.sentinel` | flock 不可用時的備援哨兵鎖（`pid`/`host`/`utc`） | 同上（fallback 路徑） | 同上 |
| `{state_dir}/*.tmp` | 崩潰前尚未完成的暫存寫入殘留 | 各原子寫入階段 | 下次啟動自動清除，正常情況不應存在 |
| `{out_dir}/{run_date}_連線紀錄.xlsx`（或 `_NN` 消歧） | 交付檔 | `xlsx_writer.write()` + `pipeline` 的最終 `os.replace` | 可，這是給人看/交付的最終產物 |

`reference/hosp_id_map.csv.gz` + `.manifest.json` 是映像建置時（或本機
執行時 `PYTHONPATH` 相鄰目錄）唯讀捆綁的查表資料，不屬於 `state_dir`/
`out_dir`，更新程序見 §8。

---

## 10. 疑難排解速查表

| 現象 | 最可能原因 | 對應章節 |
|------|-----------|----------|
| exit 5，訊息含 `Operation not permitted` 或 `Permission denied` | 未加 `--user "$(id -u):$(id -g)"`，或 `state_dir`/`out_dir` 不是由該 uid 建立/擁有 | §4 |
| exit 4，訊息含 `state lock busy` | 有其他執行中的批次；或殘留鎖尚未過 stale 門檻 | §5、§7.3 |
| exit 2，訊息含 `header mismatch` | 輸入檔不是 `analyze_access --format csv` 的 14 欄輸出，或欄名/欄序被改動 | [`data-fidelity.zh-TW.md`](data-fidelity.zh-TW.md) §2 |
| exit 2，訊息含 `missing APP_TIME`/`APP_SERVER`/`CLIENT_IP` | 該行是 NORMAL 但缺必要欄位——資料契約違反，非本工具問題 | 同上 |
| exit 3 | `records.csv` 尾列驗證失敗且 `.bak` 也失敗 | §7.2 |
| 交付檔不見了，或本次 `docker run` 在寫交付檔那步失敗 | 直接重跑最新輸入即可自動重建 | §7.1 |
| 同一天第二個批次卻蓋掉了第一個檔名而非產生 `_02` | 檢查兩批 `input_sha256` 是否其實相同（代表真的是冪等重跑，覆寫是正確行為） | §6 |
| `unmapped_hosp_ids` 一直大於 0 | 參考主檔過舊，該 HOSP_ID 不在目前捆綁的 `hosp_id_map.csv.gz` 中 | §8 |
