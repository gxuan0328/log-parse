# log-parse — 設計規格說明書

> 版本 1.0 · 2026-05-25 · 對象：開發者、SRE、值班工程師
> **語言**：[English](design.md) · **繁體中文**

本文件描述系統「做了什麼」與「為什麼這樣設計」。CLI 用法請見
[`usage.zh-TW.md`](usage.zh-TW.md)；程式碼慣例請見 [`../.claude/CLAUDE.md`](../.claude/CLAUDE.md)。

---

## 1. 系統概觀

### 1.1 領域背景

LUNG-CANCER-REPORT 系統為兩家醫院（台北 / 台中）提供臨床研究報告之
影像檢視服務。每個區域配置三台伺服器：

| 角色  | 功能                                                | 台北 (IP)                       | 台中 (IP)                       |
|-------|-----------------------------------------------------|---------------------------------|---------------------------------|
| API   | HIS 驗證通過後簽發短效期 URL Token                  | `10.22.63.37`                   | `10.1.73.37`                    |
| APP   | 驗證 URL Token，將 DICOM 檢視器送達臨床端           | `10.21.3.35`, `10.21.3.36`      | `10.1.72.35`, `10.1.72.36`      |

每台伺服器產生三類日誌：

| 類型         | 路徑樣式                                                       | 格式            | 產生者          |
|--------------|----------------------------------------------------------------|-----------------|-----------------|
| Access CSV   | `<server>/app/<YYYY-MM-DD>/app-access-<date>.csv`              | RFC 4180 CSV    | API & APP 應用  |
| IIS W3C      | `<server>/iis/u_ex<YYMMDD>.log`                                | W3C 擴充、空白  | IIS             |
| App logs     | `<server>/app/<YYYY-MM-DD>/app-{all,error,lifetime}-<d>.log`   | 管道字元分隔    | .NET 應用       |

### 1.2 涵蓋使用情境

| ID  | 角色             | 解答的問題                                                           | 對應模組              |
|-----|------------------|----------------------------------------------------------------------|-----------------------|
| UC1 | 資安分析師       | 是否有人未通過 API 驗證即存取 APP？                                  | `analyze_access`      |
| UC2 | 容量規劃人員     | 請求量 / 狀態碼分佈 / 慢請求比率為何？                               | `analyze_iis`         |
| UC3 | DBA / 值班       | OracleDB 何時不健康？應用程式多久當機重啟一次？                      | `analyze_errors`      |
| UC4 | 維運主管         | 給我一份每日 / 每週完整摘要                                          | `log_report`          |
| UC5 | 法遵稽核員       | API 簽發 Token 後使用者多久才實際呈遞？                              | `analyze_access`      |

---

## 2. 系統架構

```
                       ┌──────────────────────────┐
                       │     log_report.sh        │  (統籌器)
                       └────────┬─────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
      ┌───────────────┐ ┌───────────────┐ ┌───────────────┐
      │ analyze_      │ │ analyze_iis   │ │ analyze_      │
      │   access.sh   │ │       .sh     │ │   errors.sh   │
      └───────┬───────┘ └───────┬───────┘ └───────┬───────┘
              │                 │                 │
              └─────────────────┼─────────────────┘
                                │ source
                                ▼
        ┌────────────────────────────────────────────────┐
        │  lib/common.sh      日誌 / 暫存目錄 / 依賴檢查 │
        │  lib/date_utils.sh  日期範圍與檔名對應         │
        │  lib/csv_utils.sh   欄位擷取（awk）            │
        │  lib/fmt_utils.sh   文字版面格式化             │
        └────────────────────────────────────────────────┘
                                │ read
                                ▼
        ┌────────────────────────────────────────────────┐
        │   conf/regions.conf  （區域 → 伺服器 對應表）  │
        └────────────────────────────────────────────────┘
```

### 2.1 分層原則

1. **CLI 層**（`bin/`） — 解析參數、驅動流程、輸出報告，不含解析邏輯，
   解析邏輯均委派至 `lib/`。
2. **共用函式庫層**（`lib/`） — 純函式：日期計算、CSV 擷取、版面格式、
   日誌；不含 CLI 解析，僅變更已記錄之 `WORK_TMPDIR` / `LOG_LEVEL` /
   區域陣列等全域狀態。
3. **設定檔層**（`conf/`） — 管道字元分隔之純文字檔，由 `load_regions()`
   讀取，不含可執行內容。

### 2.2 程序模型

每個 CLI 為單一 bash 程序。繁重工作（聯結、群組、排序）透過 pipe 與
位於 `WORK_TMPDIR` 內的暫存檔交給 `gawk` 處理。暫存檔由 `init_tmpdir`
安裝的 `EXIT`/`INT`/`TERM` trap 自動清除。

統籌器（`log_report.sh`）以**子程序**方式呼叫各 `analyze_*.sh`，而非
透過 `source` 共用記憶體狀態；這樣可確保某一個模組崩潰不會污染統籌
器內部狀態。

---

## 3. 模組規格

### 3.1 `analyze_access.sh` — 存取 Token 交叉比對

#### 3.1.1 目的
驗證每筆 APP 端存取皆能對應至合法的 API 端 Token 簽發，反之亦然，將
異常以三種類別呈現。

#### 3.1.2 輸入

`<log_dir>/<server>/app/<YYYY-MM-DD>/app-access-<YYYY-MM-DD>.csv`

CSV 欄位（含表頭）：

| 編號 | 名稱            | 說明                                                |
|------|-----------------|-----------------------------------------------------|
| 1    | `REQUEST_ID`    | 單次請求 UUID                                       |
| 2    | `TOKEN`         | 呈遞給 APP 之 URL Token（API 端為空）               |
| 3    | `VERIFY_STATUS` | `OK` / `FAIL`（僅 APP 端）                          |
| 4    | `PATIENT_ID_AES`| AES 加密後之病患識別                                |
| 5    | `HOSP_ID`       | 醫院代碼                                            |
| 6    | `PRSN_ID`       | 臨床人員識別（加密）                                |
| 7    | `CLIENT_IP`     | 瀏覽器端 IP                                         |
| 8    | `SERVER_IP`     | 處理此請求之伺服器                                  |
| 9    | `ISSUE_TOKEN`   | API 簽發之 URL Token（APP 端為空）                  |
| 10   | `REQUEST_TIME`  | `YYYY-MM-DD HH:MM:SS.mmm`                           |

#### 3.1.3 比對邏輯

**聯結鍵**：`API.ISSUE_TOKEN (col 9)` ≡ `APP.TOKEN (col 2)`。

每個區域，分析器執行下列步驟：

1. 將每個 API 伺服器、日期範圍內的全部 CSV 串接為一個 TSV (`api_tsv`)。
2. APP 端重複相同動作 (`app_tsv`)。
3. 執行雙檔 gawk 聯結 (`CORRELATE_AWK`)：
   - 第一輪 (`FILENAME == api_file`)：以 ISSUE_TOKEN 為 key 建立 hash。
     使用 `FILENAME` 比對而非慣用之 `FNR == NR`，是因為當 `api_tsv` 為
     空時，後者會在第二檔錯誤地把 `FNR==NR` 視為符合（兩檔 FNR 都會
     從 1 重新開始）。
   - 第二輪（default block）：每筆 APP 紀錄以其 TOKEN 至 API hash 查
     詢；命中 → `NORMAL`；未命中 → `ORPHAN`；並把命中之 API 紀錄標
     記為「已使用」，以便 END 區塊可將剩餘未使用者列為 `UNVERIFIED`。

#### 3.1.4 輸出類別

| 類別        | 意義                                                              | 嚴重性       |
|-------------|-------------------------------------------------------------------|--------------|
| NORMAL      | APP 收到之 Token 由**同區域 API** 簽發                            | 綠色（正常）|
| ORPHAN      | APP 收到無對應 API 簽發紀錄之 Token                               | 黃色（警告）|
| UNVERIFIED  | API 簽發但 APP 從未收到驗證請求                                   | 灰色（資訊）|

可能造成 ORPHAN 的原因：跨區域 Token 重播、手動拼湊 URL、CSV 入庫
延遲。UNVERIFIED 通常是使用者在開啟檢視器前放棄。

#### 3.1.5 輸出欄位（text 模式）

NORMAL 流程：
- `API_TIME`、`APP_TIME` — 簽發與驗證時間
- `DELTA` — `APP_TIME − API_TIME` 秒數（夾鉗 ≥ 0）
- `VERIFY` — APP 端傳回 `OK` 或 `FAIL`
- `HOSP`、`CLIENT` — 醫院代碼與用戶端 IP

NORMAL 區段結尾顯示時間差統計：筆數、平均、最短、最長。

ORPHAN：`APP_TIME`、`APP_SRV`、`VERIFY`、`HOSP`、截斷後之 `PATIENT_ID`。
若至少一筆 ORPHAN 的 `VERIFY=OK`，加註「可能存在有效 Token 重播」警示。

UNVERIFIED：`API_TIME`、`API_SRV`、`HOSP`、截斷後之 `PATIENT_ID`。

#### 3.1.6 輸出格式 `tsv`

加上 `--format tsv` 後，報告改為可被後續 ETL 直接吃進去的 TSV，欄位：
`REGION, STATUS, API_REQUEST_ID, APP_REQUEST_ID, PATIENT_ID_AES,
HOSP_ID, PRSN_ID, CLIENT_IP, API_SERVER, APP_SERVER, API_TIME, APP_TIME,
DELTA_SEC, VERIFY_STATUS`。

---

### 3.2 `analyze_iis.sh` — IIS W3C 日誌分析

#### 3.2.1 目的
揭露 HTTP 層之關鍵指標：流量、錯誤率、慢端點、健康檢查失敗。

#### 3.2.2 輸入

`<log_dir>/<server>/iis/u_ex<YYMMDD>.log` — IIS W3C 擴充格式。

欄位（IIS 預設配置之 1-based 位置）：

| 索引 | 欄位           | 備註                                                  |
|------|----------------|-------------------------------------------------------|
| 1    | `date`         | `YYYY-MM-DD`                                          |
| 2    | `time`         | `HH:MM:SS`（UTC）                                     |
| 4    | `cs-method`    | HTTP 動詞                                             |
| 5    | `cs-uri-stem`  | 不含 query 之路徑                                     |
| 9    | `c-ip`         | 用戶端 IP（透過 `client_ips[]` set 計算唯一值）       |
| 12   | `sc-status`    | HTTP 狀態碼                                           |
| 17   | `time-taken`   | 請求耗時（毫秒）                                      |

`#` 開頭為 W3C 指令列、需略過。欄位數 < 17 之列為截斷紀錄，亦略過。

#### 3.2.3 端點分組

`cs-uri-stem` 內含 DICOM study / series UID，會把端點計數的 cardinality
炸開。分析器在計數前先將下列三類 DICOM 路徑收斂為 template：

```
/api/NhiPatientImage/studies/{uid}/series/{uid}/...
/api/NhiPatientImage/studies/{uid}/series-uid
/api/NhiPatientImage/studies/{uid}/instances/{uid}
```

其他路徑維持原樣。

#### 3.2.4 聚合訊號

| 指標              | 定義                                                                                |
|-------------------|-------------------------------------------------------------------------------------|
| `total`           | 已解析紀錄數（排除註解與短列）                                                      |
| `status_count[]`  | 各狀態碼計數（如 200、302、404、500、503）                                          |
| `error5xx`        | `status >= 500` 之列數                                                              |
| `health503`       | `status == 503` 且 `uri == /health` 之列數                                          |
| `slow`            | `time-taken >= --slow-ms` 且 `uri != /health` 之列數                                |
| `redirect`        | `status == 302` 之列數                                                              |
| `client_ips`      | `c-ip → 請求數` 之 hash；`length()` 得唯一 IP 數，迭代後產出 IP 清單。`-` 排除。   |
| `top endpoints`   | 端點計數 Top 15（DICOM 分組後），各端點附其**平均回應時間**（`time-taken` 以毫秒記錄，換算為秒並四捨五入至 2 位小數） |
| `client_ip_roster`| 每個唯一 `c-ip` 及其請求數與占 `total` 之百分比                                     |

健康檢查 503 之所以**獨立計數**而非合併進 5xx，是因為它代表相依服務
不健康（OracleDB 不健康時應用程式刻意回傳 503），而非應用程式錯誤。

Client IP 清單**刻意不設上限**：醫療營運下單台伺服器的客戶端 cardinality
通常落在數十以內，若意外膨脹（例如掃描器、憑證外洩）本身即是有用之
偵測訊號。若未來情境需要截斷，建議新增 `--top-ips N` 旗標而非靜默裁減。

#### 3.2.5 輸出區段

每個所選區域之每台伺服器：
1. 頂部計數列（`Total`、`Unique IPs`、`5xx`、`Health 503`、`Slow`）。
2. 狀態碼表（按計數降冪）。
3. Top-15 端點表（按計數降冪），含 `Avg(s)` 欄位，標示各端點之
   平均回應時間（秒，四捨五入至小數兩位）。
4. Client IP 清單 — 列舉每個唯一 client IP 之請求數與占 `total` 之
   百分比（按請求數降冪）；當所有列之 `c-ip = -`（無可解析客戶端）時
   為空。

---

### 3.3 `analyze_errors.sh` — 應用程式錯誤與生命週期

#### 3.3.1 目的
診斷應用程式層：OracleDB 連線中斷、常見錯誤模式、非預期重啟之停機時間。

#### 3.3.2 輸入

`app-all-<d>.log`（首選）或 `app-error-<d>.log` 之管道分隔列：

```
2026-05-21 14:03:44.332|eventId: 0|level: ERROR|traceId: ...|logger: ...|message: <text>|
```

`app-lifetime-<d>.log` 含 `Microsoft.Hosting.Lifetime` 類別，訊息為
`Application started` 或 `Application is shutting down`。

#### 3.3.3 錯誤模式擷取（`ERROR_AWK`）

1. 過濾出包含 `|level: ERROR|` 之列。
2. 擷取 `message:` 欄位，遇到 `--- Exception` 即截斷（避免堆疊塞滿訊息）。
3. 訊息上限 120 字元。
4. 建立**正規化**鍵以利分組：
   - `\d+\.\d+ms` → 字串常值 `Nms`（請求耗時逐筆不同）。
   - 任何 `YYYY-MM-DD` → 字串常值 `DATE`。
   - 其餘 `\d+` → 字串常值 `N`。
5. `error_count[norm]++`，並保留首見訊息為樣本。
6. 結尾：印出 `TOTAL_ERRORS`、`DB_FAILURES`、最多 5 筆 `DB_TIME`、以及
   按計數降冪排列之 Top-N 模式（預設 10，可透過 `--top N` 覆寫）。

#### 3.3.4 OracleDB 失敗判定

一列被歸類為 DB 失敗的條件：
- 訊息含 `OracleDB`
- 訊息含 `Unhealthy` **或** `TaskCanceledException`

範例資料證實此邏輯：每次 DB 中斷皆呈現為健康檢查 `Unhealthy`、或連線
池停滯後查詢之 `TaskCanceledException`。

#### 3.3.5 重啟事件配對（`LIFETIME_AWK` + `pair_restarts`）

1. `LIFETIME_AWK` 掃描 `app-lifetime` 列，輸出 `SHUTDOWN <ts>` 或
   `STARTED <ts>` 事件。
2. `pair_restarts` 走訪（時間序）事件清單：
   - 看到 `STARTED` 且前一筆是未配對之 `SHUTDOWN` → 輸出
     `RESTART <shutdown_ts> <started_ts> <delta_sec>`。
   - 若第二筆 `SHUTDOWN` 抵達前未配對先前的，將先前那筆標為
     `UNMATCHED`；檔尾掛單事件同樣標為 `UNMATCHED`。

停機時間之差值由 `mktime()` 計算（秒級精度，毫秒會被截除）。

#### 3.3.6 輸出

- `Total ERROR entries` — 原始錯誤計數
- `OracleDB health failures` — DB 專屬子集，紅色標示
- 計數 > 0 時，顯示前 5 筆 DB 失敗時間
- Top-N 錯誤模式表
- 重啟事件表（Shutdown / Started / Downtime）
- 若有未配對 SHUTDOWN，以黃色標示其數量，並列出
  `(無對應啟動記錄)` 之列，便於營運人員確認可能的硬性崩潰／待恢復狀態。

---

### 3.4 `log_report.sh` — 統籌器

#### 3.4.1 目的
「我要看全部」的單一入口。可選擇執行哪些模組，以及輸出位置。

#### 3.4.2 模組挑選

`--modules` 接受 `access,iis,errors` 之逗號分隔子集（預設全選）。未知
名稱會以明確錯誤訊息中止。

#### 3.4.3 輸出模式

| 模式            | 觸發條件                            | 行為                                                  |
|-----------------|-------------------------------------|-------------------------------------------------------|
| stdout（預設）  | 未指定 `--output` 與 `--output-dir` | 將每個模組依序串接至 stdout                          |
| 合併檔案        | `--output FILE`                     | 將 FILE 清空後，把每個模組之輸出依序附加              |
| 分模組目錄      | `--output-dir DIR`                  | 在 DIR 內產生 `<module>_<YYYYMMDD_HHMMSS>.txt` 多檔   |

實務上 `--output` 與 `--output-dir` 互斥；若同時提供，`--output-dir`
取勝（分模組分支先觸發）。

#### 3.4.4 參數傳遞

`build_module_args()` 建立共用 `_SHARED_ARGS` 陣列，按樣傳給每個子呼叫。
條件式 append 使用 `if ... then ... fi` 而非 `[[ ]] && cmd`，因為若末
段條件為假，後者會讓函式回傳 1，在 `set -e` 下會中止統籌器。

---

## 4. 共通議題

### 4.1 日期處理

由 `lib/date_utils.sh::build_date_list` 一處供應。優先順序：

1. `--date YYYY-MM-DD` — 單日。
2. `--from YYYY-MM-DD --to YYYY-MM-DD` — 含頭含尾範圍。
3. `--days N` — 至今日為止之最後 N 天（預設 N=7）。

所有日期皆以 `date -d` 驗證；不合法格式直接 `die` 中止。

### 4.2 日誌

`lib/common.sh` 提供 `log_debug` / `log_info` / `log_warn` / `log_error`，
遵守 `LOG_LEVEL`。所有 log 走 **stderr**，使報告本身可被安全管線到檔
案或工具。當 stdout 非 TTY 或設定 `NO_COLOR=1`，色碼自動關閉。

### 4.3 暫存檔管理

`init_tmpdir` 建立 `${TMPDIR:-/tmp}/log_analyze.XXXXXX`，並安裝
`EXIT INT TERM` 之清除 trap。所有中介檔案（每台伺服器合併日誌、區域
聯結輸入、重啟事件 TSV）皆位於此目錄。

### 4.4 錯誤處理

- 每個可執行腳本一律 `set -euo pipefail`。
- 必要參數先驗證；缺少 `--log-dir` 即中止。
- 缺少之每台伺服器子目錄降級為 `log_warn`（單台跳過）而非致命，避免
  某區異常阻擋另一區之分析。
- 空資料以 `無資料` / `No data` 呈現，但不視為錯誤。

### 4.5 效能特徵

- 磁碟 I/O 是主要成本。雙輪 awk 聯結在常見硬體約 100k 列／秒。
- 記憶體上限由**唯一 Token 數量**決定，而非列數（API hash 大小）。
  雙區單日約落在數千 token 量級。
- 統籌器目前以序列方式跑模組。要平行化需為每個子程序自備
  `WORK_TMPDIR`，目前規模尚不需要。

---

## 5. 擴充

### 5.1 新增區域
在 `conf/regions.conf` 多加一列即可，無需改 code。新區域會自動出現
於所有報告中。

### 5.2 新增分析器
1. 依照現有 `parse_args` / `load_regions` / `main` 骨架建立
   `bin/analyze_<name>.sh`。
2. 把 `<name>` 加進 `bin/log_report.sh` 的 `valid_modules` 陣列。
3. 在本文件與 `usage.zh-TW.md` 模組表新增一列。
4. 在 `tests/run_tests.sh` 補上新區段。

### 5.3 修改 Access CSV 欄位
更新 `lib/csv_utils.sh` 內 `extract_api_records` / `extract_app_records`
之欄位索引，並同步更新 §3.1.2 之欄位表。執行測試套件確認基準仍成立
（若需要可有意更新基準）。

---

## 6. 已知限制

- IIS 時間欄位視為 UTC，報告不做本地化轉換。
- 錯誤模式分組為啟發式作法，會把僅以數值 / 時間差異區分之訊息群組
  化；對大多數情境正確，但對僅以字串狀態區分之錯誤族群會喪失辨識度。
- 重啟事件配對假設事件按時間序到達；若日誌跨日輪替於事件中段，可能
  出現假性 `UNMATCHED`。
- 僅支援 Linux/WSL；macOS 需建立 `gdate` 別名為 `date`。
