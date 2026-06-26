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

使用 `--merge` 時，`correlate_merged` 將所有已設定區域之 API 伺服器日誌
串接為單一 `api_tsv`、APP 伺服器日誌串接為單一 `app_tsv`，再對合併語料
執行一次 CORRELATE_AWK — 詳見 §3.1.9。

#### 3.1.4 輸出類別

| 類別        | 意義                                                                                              | 嚴重性       |
|-------------|---------------------------------------------------------------------------------------------------|--------------|
| NORMAL      | APP 收到之 Token 由語料庫中某台 API 伺服器簽發（預設為同區域；`--merge` 下可跨區域）             | 綠色（正常）|
| ORPHAN      | APP 收到在語料庫中找不到對應 API 簽發紀錄之 Token                                                | 黃色（警告）|
| UNVERIFIED  | API 簽發但 APP 從未收到驗證請求                                                                   | 灰色（資訊）|

可能造成 ORPHAN 的原因：跨區域 Token 重播（未使用 `--merge` 時）、手動
拼湊 URL、CSV 入庫延遲。UNVERIFIED 通常是使用者在開啟檢視器前放棄。

#### 3.1.5 內部 schema — CORRELATE_AWK 輸出

雙檔 gawk 聯結每筆紀錄產生 12 個 TAB 分隔欄位。欄位順序遵循「時間 →
結果 → 身分 → 伺服器 → 病患」，將時間排序鍵置於前段，可變寬度之
`PATIENT_ID_AES` 置於末段。

| # | 欄位 | NORMAL | ORPHAN | UNVERIFIED |
|---|------|--------|--------|------------|
| $1 | `STATUS` | `NORMAL` | `ORPHAN` | `UNVERIFIED` |
| $2 | `API_TIME` | `api_ts` | `-` | `api_time[tok]` |
| $3 | `APP_TIME` | `app_ts` | `app_ts` | `-` |
| $4 | `DELTA_SEC` | `delta` / `N/A` | `-` | `-` |
| $5 | `VERIFY_STATUS` | `verify` | `verify` | `-` |
| $6 | `REQUEST_ID` | `coalesce(api_req_id, app_req)` | `app_req` | `api_req_id` |
| $7 | `API_SERVER` | `api_server` | `-` | `api_server` |
| $8 | `APP_SERVER` | `app_srv` | `app_srv` | `-` |
| $9 | `HOSP_ID` | coalesced | coalesced | `api_hosp` |
| $10 | `PRSN_ID` | coalesced | coalesced | `api_prsn` |
| $11 | `CLIENT_IP` | coalesced | coalesced | `api_client_ip` |
| $12 | `PATIENT_ID_AES` | coalesced（完整） | coalesced（完整） | `api_patient`（完整） |

`REQUEST_ID` 合併原先之 `API_REQUEST_ID` 與 `APP_REQUEST_ID`；合併規則為
「優先取 API id，回退取 APP id」。三種類別均包含 `PRSN_ID` 與 `CLIENT_IP`。
`PATIENT_ID_AES` 完整輸出，先前之 `substr(…, 1, 16)"..."` 截斷已移除。`-`
表示該類別中不存在之欄位。

#### 3.1.6 決定性排序前置步驟

CORRELATE_AWK 執行完畢後，由單一共用 gawk 步驟（`sort_records`）將全部
12 欄紀錄排序為 `result_sorted`，再由各渲染器讀取。此步驟確保 text、tsv、
csv 三種格式共享同一組位元組穩定（byte-stable）的輸出順序。

**複合排序鍵（四層）：**

1. `STATUS`（$1）— 將 NORMAL、ORPHAN、UNVERIFIED 各自群組。
2. 依類別取時間欄 — NORMAL 與 UNVERIFIED 取 `API_TIME`（$2）；ORPHAN
   取 `APP_TIME`（$3）（對應各類別 text 顯示之前導時間欄）。
3. `REQUEST_ID`（$6）— 區別時間戳相同之紀錄。
4. 整列完整內容 — 穩定 tie-break，消除 UNVERIFIED `for (tok in api_time)`
   gawk hash 迭代的不確定順序。

`asorti(buf, idx, "@ind_str_asc")` 安全無虞，因為所有時間戳均為固定寬度
零補齊格式（`YYYY-MM-DD HH:MM:SS.mmm`），詞典序升冪與時間序升冪完全一致。

三種渲染器均讀取 `result_sorted`；無任何渲染器自行重排。

#### 3.1.7 文字輸出 — 各類別欄位

每個類別僅顯示其實際存在之欄位；對該類別不存在之欄位一律省略。所有類
別均包含 `PRSN_ID`、`CLIENT_IP`，以及完整未截斷之 `PATIENT_ID_AES` 作為
末端可變寬度欄位。每個類別印出一列灰色表頭。紀錄依 §3.1.6 之決定性升冪
順序排列。

共用欄位寬度：`TIME=23 · SERVER=15 · DELTA=8 · VERIFY=7 ·
REQID=13 · HOSP=12 · PRSN=12 · CLIENT=16`。

**NORMAL** — 以雙時間欄開頭，含時間差與驗證狀態：
`API_TIME, APP_TIME, DELTA, VERIFY, REQUEST_ID, API_SRV, APP_SRV, HOSP_ID,
PRSN_ID, CLIENT_IP, PATIENT_ID_AES`。
DELTA 格式為 `%.1fs`（夾鉗 ≥ 0），不存在時顯示 `N/A`。後接時間差統計：
有效筆數、平均、最短、最長。

**ORPHAN** — 以 `APP_TIME` 開頭（無 `API_TIME`、`API_SERVER`、`DELTA`）：
`APP_TIME, VERIFY, REQUEST_ID, APP_SRV, HOSP_ID, PRSN_ID, CLIENT_IP,
PATIENT_ID_AES`。
後接驗證結果摘要；若任一 ORPHAN 之 `VERIFY=OK`，加附警示訊息。

**UNVERIFIED** — 以 `API_TIME` 開頭（無 `APP_TIME`、`APP_SERVER`、`DELTA`、
`VERIFY`）：
`API_TIME, REQUEST_ID, API_SRV, HOSP_ID, PRSN_ID, CLIENT_IP, PATIENT_ID_AES`。

`PATIENT_ID_AES` 欄位永遠在末端，於窄終端可能折行。不套用任何截斷。

#### 3.1.8 機器可讀輸出 — `tsv` 與 `csv`

兩種格式均為 `result_sorted` 之平坦輸出（與 text 共享 §3.1.6 之決定性
順序）。每列在最前方加上 `REGION` 欄（區域名稱，`--merge` 時值為
`merged`）。13 欄 schema：

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES
```

- **`--format tsv`** — TAB 分隔，不加引號。
- **`--format csv`** — 逗號分隔，RFC-4180 條件式引號：欄位僅在包含 `"`、
  `,` 或換行時才加引號；內部 `"` 字元以雙引號跳脫。LF 行結尾。不含上述
  字元之欄位不加引號輸出。

每份輸出僅印一列表頭（tsv 為 TAB 聯結；csv 為逗號聯結）。兩種格式共用
§3.1.6 之位元組穩定順序。

#### 3.1.9 `--merge` 語義

`--merge` 要求 `--region all`（明確指定或預設值皆可）。同時指定單一區域
之 `--region` 與 `--merge` 將以錯誤中止。

`correlate_merged` 從所有已設定區域之 API 伺服器日誌建立一份 `api_tsv`，
從所有區域之 APP 伺服器日誌建立一份 `app_tsv`，再對合併語料執行一次
CORRELATE_AWK。X 區域 API 伺服器簽發、由 Y 區域 APP 伺服器驗證之 Token
歸類為 **NORMAL**（而非 ORPHAN），因為合併語料不區分主機所屬區域。合併
後之 NORMAL 筆數 ≥ 各區域 NORMAL 筆數之總和，差值即為資料集中跨區域
Token 交換之筆數。

逐區域分析（預設）保留區域身分識別。`--merge` 是刻意捨棄區域區分、用於
稽核跨區域端對端 Token 流量之模式。

文字輸出：含三份升冪排列類別清單之單一 `Region: all (merged)` 區塊。
tsv / csv 輸出：`REGION` 欄值為 `merged`。

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

| 指標              | 定義                                                                                                                                                   |
|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| `total`           | 已解析紀錄數（排除註解與短列）                                                                                                                         |
| `status_count[]`  | 各狀態碼計數（如 200、302、404、500、503）                                                                                                             |
| `error5xx`        | `status >= 500` 之列數                                                                                                                                 |
| `health503`       | `status == 503` 且 `uri == /health` 之列數                                                                                                             |
| `slow`            | `time-taken >= threshold` 且 `uri != /health` 之列數；threshold 為 API 角色伺服器用 `--slow-api-ms`（預設 2000 ms）、APP 角色用 `--slow-app-ms`（預設 5000 ms） |
| `redirect`        | `status == 302` 之列數                                                                                                                                 |
| `client_ips`      | `c-ip → 請求數` 之 hash；`length()` 得唯一 IP 數，迭代後產出 IP 表格。`-` 排除。                                                                      |
| `top endpoints`   | 請求數 Top-N 端點（DICOM 分組後），N 由 `--top` 控制（預設 10，0=全部）；各端點附**平均回應時間**（秒，四捨五入至 2 位小數）                           |
| `client_ip_roster`| 請求數 Top-N 唯一 `c-ip` 及其請求數與占 `total` 之百分比，N 由 `--top` 控制（0=全部）                                                                |

健康檢查 503 之所以**獨立計數**而非合併進 5xx，是因為它代表相依服務
不健康（OracleDB 不健康時應用程式刻意回傳 503），而非應用程式錯誤。

三張表格之 `% of total` 分母均為該伺服器或語料桶之 `total` 請求數（含
`/health` 與轉址）。當 `--top` 截斷端點或 Client IP 清單時，可見列之
百分比加總不會達到 100%。

#### 3.2.5 輸出區段

每個所選區域之每台伺服器，或 `--merge` 下之每個角色語料桶：

1. 頂部計數列：`Total requests`、`Unique client IPs`、`302 Redirects`、
   `5xx errors`、`Health 503`、`Slow (>Nms)` — 標籤中之閾值反映該伺服器
   之角色。
2. HTTP 狀態碼表 — 欄位 `["Status", "Count", "% of total"]`，按計數降冪。
   排序在 gawk 內完成（不使用外部 `sort`）。
3. 端點表 — 欄位 `["Endpoint", "Avg(s)", "Count", "% of total"]`，按計數
   降冪。以 `--top` 列數上限（預設 10；0=全部）。
4. Client IP 表 — 欄位 `["Client IP", "Count", "% of total"]`，按計數降冪。
   以 `--top` 列數上限。當所有列之 `c-ip = -` 時為空。

IIS 各表均為純計數降冪排名清單；不存在逐筆時間序詳細清單，因此
`analyze_access` 引入之決定性升冪排序不適用於此。

#### 3.2.6 依角色分流之慢請求閾值

`--slow-api-ms`（預設 2000 ms）適用於 `REGION_APIS` 中的伺服器；
`--slow-app-ms`（預設 5000 ms）適用於 `REGION_APPS` 中的伺服器。角色
歸屬由 `conf/regions.conf` 解析。預設值反映 API Token 簽發端點比 APP DICOM
服務端點更嚴格之 SLA 要求。報告中 `Slow (>Nms)` 標籤顯示該伺服器實際採
用之閾值。

#### 3.2.7 `--top` 旗標

控制端點表與 Client IP 表各自最多顯示之列數（預設 10；0=全部）。同一次
執行中兩張表套用相同上限。此旗標在 `analyze_iis` 與 `analyze_errors` 之
間統一（名稱相同、0=all 語義相同，作用對象不同）。

#### 3.2.8 `--merge` — 雙語料桶跨區域合併

使用 `--merge` 時，`analyze_merged_iis` 對所有已設定區域執行迭代，建立
兩份語料：

- **API 語料**：串接所有區域之 `REGION_APIS` 伺服器的 IIS 日誌。
- **APP 語料**：串接所有區域之 `REGION_APPS` 伺服器的 IIS 日誌。

共用 `render_iis_stats LABEL COMBINED THRESHOLD` helper 對合併日誌檔執行
一次 IIS_AWK、輸出 KV 摘要區塊，並輸出三張重整後的表格（§3.2.5）。
`analyze_server_iis`（非合併、逐伺服器）與 `analyze_merged_iis`（合併、
雙語料桶）皆委派給此 helper；呼叫端負責 `fmt_h2` 區段標題。

`render_iis_stats` 對每份語料各執行一次，產生兩個輸出區塊：
1. `IIS — API_SERVERS (merged, all regions)` — 使用 `--slow-api-ms` 閾值。
2. `IIS — APP_SERVERS (merged, all regions)` — 使用 `--slow-app-ms` 閾值。

兩個區塊之 KV 摘要與三張表格結構與非合併路徑完全相同，`Slow (>Nms)`
標籤依角色顯示對應閾值。

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
   按計數降冪排列之 Top-N 模式（預設 10，可透過 `--top N` 覆寫；傳入
   `--top 0` 時輸出**全部**模式）。

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

`build_module_args()` 為每個模組建立個別之 `_MOD_ARGS` 陣列，按樣傳給
子程序呼叫。條件式 append 使用 `if ... then ... fi` 而非 `[[ ]] && cmd`，
因為若末段條件為假，後者會讓函式回傳 1，在 `set -e` 下會中止統籌器。

此函式**感知模組**：通用旗標（`--log-dir`、`--region`、`--days`/`--date`/
`--from`/`--to`、`--conf`、`--verbose`、`--format`）對所有模組一律附加；
僅適用於特定模組的旗標則在 `case "$module"` 區塊內附加：

- `analyze_access` 在啟用時接收 `--merge`。
- `analyze_iis` 接收 `--top`、`--slow-api-ms`、`--slow-app-ms`，以及啟用
  時之 `--merge`。
- `analyze_errors` 接收 `--top`。

`--conf` 僅在呼叫端明確傳入時附加（`REGIONS_CONF` 非空）。省略 `--conf`
時，各子模組自行解析預設值（`conf/regions.conf`）。log_report 本身僅在
明確傳入 `--conf` 時才驗證其存在性；省略時不驗證。

`--format` 轉傳給所有子模組。不支援 tsv/csv 渲染之模組（`analyze_iis`、
`analyze_errors`）接受此旗標後，輸出一行警告訊息並繼續以 text 模式執行
— 因此 log_report 傳出之 `--format csv` 可讓 `analyze_access` 渲染 csv，
而 iis 與 errors 維持 text 模式而不中止。

#### 3.4.5 選項轉傳矩陣

| 旗標 | log_report | access | iis | errors | 備註 |
|---|---|---|---|---|---|
| `--log-dir` | own | F | F | F | 必要 |
| `--region` | own | F | F | F | 控制 `--merge` |
| `--days` / `--date` / `--from` / `--to` | own | F | F | F | |
| `--conf` | own（僅明確傳入時驗證） | F | F | F | |
| `--output` / `--output-dir` / `--modules` | own | — | — | — | 統籌器專用 |
| `--verbose` | own | F | F | F | |
| `--format` | F→全部 | 渲染 tsv/csv | no-op+警告 | no-op+警告 | |
| `--top` | F→{iis,errors} | — | 端點+Client IP | 模式計數 | 0=全部 |
| `--slow-api-ms` | F→iis | — | API 角色伺服器 | — | 預設 2000 ms |
| `--slow-app-ms` | F→iis | — | APP 角色伺服器 | — | 預設 5000 ms |
| `--merge` | F→{access,iis} | 跨區域 | 雙語料桶 | — | 需要 `--region all` |

圖例：`own` = log_report 自身處理 · `F` = 轉傳至子模組 ·
`—` = 該模組不接受（未知選項 → `die`）。

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
