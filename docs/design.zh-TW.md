# log-parse — 設計規格說明書

> 版本 2.2 · 2026-06-30 · 對象：開發者、SRE、值班工程師
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
| UC6 | 管理層           | 給我一頁跨區域、跨角色的系統健康概況                                 | `analyze_overview`    |

---

## 2. 系統架構

```
                       ┌──────────────────────────┐
                       │     log_report.sh        │  (統籌器)
                       └────────┬─────────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         ▼                      ▼                      ▼
 ┌──────────────┐   ┌───────────────┐   ┌───────────────────┐
 │ analyze_     │   │ analyze_iis   │   │ analyze_overview  │
 │   access.sh  │   │       .sh     │   │         .sh       │
 └──────┬───────┘   └───────┬───────┘   └─────────┬─────────┘
        │                   │                     │ --emit-stats
        │                   │               ┌─────┴──────┐
        │                   │               ▼            ▼
        │                   │      analyze_iis  analyze_access
        │                   │       (僅 --emit-stats，不持久化)
        │                   │
 ┌──────────────┐
 │ analyze_     │
 │   errors.sh  │
 └──────┬───────┘
        │
        └──────────────────────┬─────────────────────────┘
                               │ source
                               ▼
  ┌──────────────────────────────────────────────────────┐
  │  lib/common.sh        日誌 / 暫存目錄 / 依賴檢查、   │
  │                        load_test_hosts、TH_FILTER_FUNC│
  │  lib/date_utils.sh    日期範圍、resolve_interval      │
  │  lib/csv_utils.sh     欄位擷取（awk）                │
  │  lib/fmt_utils.sh     文字版面、fmt_set_color_state  │
  │  lib/output_utils.sh  常開式持久化（D6）              │
  │  lib/aggregate_utils.sh  AGG_IIS_AWK、AGG_CSV_FUNC、 │
  │                           agg_iis_rows、agg_access_rows│
  └──────────────────────────────────────────────────────┘
                               │ read
                               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │   conf/regions.conf    （區域 → 伺服器 對應表）             │
  │   conf/test_hosts.conf （QA/探測用戶端 IP — 單一事實來源）  │
  └─────────────────────────────────────────────────────────────┘
```

### 2.1 分層原則

1. **CLI 層**（`bin/`） — 解析參數、驅動流程、輸出報告，不含解析邏輯，
   解析邏輯均委派至 `lib/`。
2. **共用函式庫層**（`lib/`） — 純函式：日期計算、CSV 擷取、版面格式、
   日誌、持久化、共用指標計算；不含 CLI 解析，僅變更已記錄之已核可全域
   狀態（`WORK_TMPDIR`、`LOG_LEVEL`、區域陣列、`RUN_BASE_DIR`、
   `RUN_OUTPUT_DIR`、`RUN_TS`、`INTERVAL_ARGS`）。
3. **設定檔層**（`conf/`） — 純文字檔，不含可執行內容。`regions.conf`
   為管道字元分隔格式，由各 bin 內的 `load_regions()` 讀取。
   `test_hosts.conf` 每行一個 IPv4，由 `lib/common.sh` 中的
   `load_test_hosts` 讀取（見 §3.2.14）。

### 2.2 程序模型

每個 CLI 為單一 bash 程序。繁重工作（聯結、群組、排序）透過 pipe 與
位於 `WORK_TMPDIR` 內的暫存檔交給 `gawk` 處理。暫存檔由 `init_tmpdir`
安裝的 `EXIT`/`INT`/`TERM` trap 自動清除。

統籌器（`log_report.sh`）以**子程序**方式呼叫各 `analyze_*.sh`，而非
透過 `source` 共用記憶體狀態；這樣可確保某一個模組崩潰不會污染統籌
器內部狀態。

`analyze_overview.sh` 另以 `--emit-stats` 模式衍生 `analyze_iis.sh` 與
`analyze_access.sh`，讀取其聚合統計列。這兩個子衍生程序不產生持久化
檔案、不印出標題橫幅，僅將 TAB 分隔的原始統計列串流至 stdout。

### 2.3 新增函式庫模組

#### `lib/output_utils.sh` — 常開式持久化（D6）

提供 `persist_init`、`persist_ext`、`persist_path`、`persist_views`。
每個分析器模組在計算完統計後呼叫此函式庫。全域變數：`RUN_OUTPUT_DIR`
（已解析之絕對路徑）、`RUN_TS`（固定啟動時間戳 `YYYYMMDD_HHMMSS`）。

目錄優先順序（C1）：`--output-dir` 旗標 > `$LOG_PARSE_OUTPUT_DIR` 環境
變數 > `./log-parse`。`./log-parse` 字串常值**僅存在**於 `persist_init`
之內；所有 CLI 預設 `OPT_OUTPUT_DIR=""` 以確保旗標 > 環境變數優先序成立。

#### `lib/aggregate_utils.sh` — 共用指標計算 + CSV 引號處理器（D5）

IIS 指標 awk 與 RFC-4180 CSV 引號處理器的單一事實來源：

- **`AGG_IIS_AWK`** — IIS W3C 日誌分析器。依序套用：UTC 時區視窗過濾器
  （tz guard，見 §3.2.14）、`/health` 排除、測試主機模式過濾、DICOM
  端點分組、核心功能類別分類。除標準標籤化列外，亦輸出
  `CATEGORY <key> <count> <sum_ms>` 列（三個類別均固定輸出以確保下游
  穩定解析；`sum_ms` 為原始整數累積值，下游可跨伺服器加總後單次除法
  得到精確平均值，無中間捨入誤差）。透過 `agg_iis_rows` 呼叫。
- **`AGG_CSV_FUNC`** — RFC-4180 gawk `q(s)` 函式（逐字從
  `bin/analyze_access.sh` 搬移）。以字串串接方式前置於 access
  `render_csv` 與 iis csv-detail 兩個 gawk 程式。**不建立 bash 端
  `fmt_csv_field`**——`q()` 是 gawk 函式；bash 重新實作會產生第三份
  平行副本，正是單一事實來源規則要防止的問題。
- **`agg_iis_rows COMBINED SLOW_MS [TOP] [TH_MODE] [TH_SET] [TZ_LO] [TZ_HI]`** —
  執行 `AGG_IIS_AWK`；可選的 `TZ_LO`/`TZ_HI` 參數為由 `iis_utc_window`
  計算的半開放 UTC 時間邊界（空值表示不做時區過濾，向舊版相容）。
- **`agg_access_rows RESULT_SORTED`** — 單一 gawk 步驟，取代原先
  `analyze_access.sh:351-353` 的三個分開計數步驟。
- **Schema 常數** `IIS_STAT_SCHEMA` / `ACCESS_STAT_SCHEMA` 及欄位索引
  輔助（`IIS_F_REGION`、`IIS_F_TAG` 等），讓分析器、渲染器、overview
  共享同一契約。`IIS_STAT_SCHEMA` 包含 `CATEGORY` 列定義；`IIS_F_AVGSEC`
  （位置 8）為重載欄位：對 `ENDPOINT` 列為 `avg_sec`，對 `CATEGORY` 列
  為 `sum_ms`（整數毫秒，**非** avg_sec）——已記錄於 schema 說明中。
  `IIS_F_SUMMS=9`（僅限 `ENDPOINT` 列）提供 `sum_ms` 整數累積值的欄位
  索引，供摘要視圖跨伺服器平均值聚合使用。
- **`overview_health_verdict NORMAL TOTAL`** — 將整數截斷後的 NORMAL 比率
  映射為整體健康判定的判定文案（判定單一事實來源，D1）。封裝
  `trunc(NORMAL/TOTAL×100)`（以 `printf "%d"` 實作）及帶區間映射
  （`>=90 → 正常`、`>=70 → 注意`、`<70 → 警告`、`TOTAL==0 → 無資料`）。
  輸出不含數字（保護 H11 測試）。由 `bin/analyze_overview.sh` 中的
  `overview_render` 呼叫。

#### `lib/date_utils.sh` — IIS 時區偏移常數與視窗輔助函式

為支援 IIS UTC→UTC+8 時區修正（見 §3.2.14）新增兩項：

- **`IIS_UTC_OFFSET_HOURS=8`** — +8h 偏移的單一事實來源（UTC 截止時刻
  = 24 − 8 = 16:00:00）。在 source 時設定。
- **`IIS_TZ_CUTOFF_UTC`** — 由上述常數衍生為 `16:00:00`。
- **`iis_utc_window START END`** — 將 UTC+8 含頭含尾日期範圍映射為半開放
  UTC 字串邊界 `"LO|HI"`，供 `agg_iis_rows` 使用。純 stdout；無副作用。

#### `lib/common.sh` — 測試主機載入器與謂詞（單一事實來源）

`load_test_hosts(conf)` 讀取 `conf/test_hosts.conf`，去除 `#` 註解與空行，
以空格串接 IP 集合後輸出，供 gawk 透過 `-v th_set=...` 接收（以精確字串
相等方式比對，從不使用正規表達式）。若檔案不存在，`load_test_hosts` 以
`die` 中止——與 `regions.conf` 的 fail-fast 行為一致。

`TH_FILTER_FUNC` 為 gawk 程式片段（shell 變數），實作三種過濾模式。呼叫
方以 `"$TH_FILTER_FUNC$AWK_PROG"` 前置方式注入至任何需按用戶端 IP 過濾
的 gawk 程式，並傳入 `-v _th_mode=exclude|only|all` 與 `-v th_set="ip ip
..."`，在 `BEGIN` 區塊呼叫 `th_init(th_set)`，在讀取階段以
`if (th_skip(ip)) next` 過濾紀錄。`th_skip` 回傳 1（丟棄）或 0（保留）：
- `exclude`（預設）— 丟棄用戶端 IP 位於測試主機集合中的請求。
- `only` — 僅保留來自測試主機 IP 的請求。
- `all` — 不論 IP 為何，保留所有請求。

此為 **`common.sh` 中第一個真正共用的載入器 / 謂詞**，遵循
`assert_enum`/`die` 的放置模式。`load_regions` 定義於各 bin，**並非**
共用載入器；請勿將兩者混淆。

#### `lib/fmt_utils.sh` + `lib/common.sh` — 可重入色碼狀態（C3）

原先位於 `lib/common.sh:49` 的一次性內嵌色碼決策，已提取為
**`fmt_set_color_state()`** 並在 source 時呼叫一次（保留現有行為），
同時由 `persist_views` 再次呼叫以清除色碼後寫入檔案：

```bash
fmt_set_color_state() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET='\033[0m';    C_BOLD='\033[1m'
        C_RED='\033[0;31m';   C_YELLOW='\033[0;33m'
        C_GREEN='\033[0;32m'; C_CYAN='\033[0;36m';  C_GREY='\033[0;90m'
    else
        C_RESET='' C_BOLD='' C_RED='' C_YELLOW='' C_GREEN='' C_CYAN='' C_GREY=''
    fi
}
```

`C_CYAN` 為必要——`fmt_h3`（`fmt_utils.sh`）以此變數繪製 `■` 子標題。
保留單引號 `\033` 字串常值；`printf "%b"` 與 gawk `-v C_*=...` 皆在
輸出時將其展開為真實 ESC 位元組。此單一切換涵蓋所有 ANSI 發射點：
`fmt_h1/h2/h3`、`fmt_kv/fmt_kv_color`、`fmt_ok/warn/err`、`_log`，
以及 `analyze_access.sh` 內的直接 `-v C_*="$C_*"` gawk 參數傳遞。

---

## 3. 模組規格

### 3.0 `analyze_overview.sh` — 管理層概覽（新增）

#### 3.0.1 目的

提供跨所有區域與服務角色的單頁管理層系統健康概況。僅摘要、僅文字；
無 `--view` 或 `--format` 旗標。預設 `--region all`、7 天視窗。

#### 3.0.2 DRY 資料來源——`--emit-stats` 交接，分離參數向量（C2）

`analyze_overview.sh` 內部**零**日誌收集、**零**解析、**零**指標 awk。
它以 `--emit-stats` 模式衍生 `analyze_iis.sh` 與 `analyze_access.sh`
並讀取其 TAB 分隔統計列。參數向量**必須分離**，因為 `analyze_access.sh`
不接受 `--slow-*-ms`：

```bash
IIS_ARGS=("${BASE_ARGS[@]}" --slow-api-ms "$OPT_SLOW_API_MS" \
                             --slow-app-ms "$OPT_SLOW_APP_MS")
ACCESS_ARGS=("${BASE_ARGS[@]}")   # 不含慢速閾值（C2）

analyze_iis.sh    "${IIS_ARGS[@]}"    --emit-stats > "$iis_stats"
analyze_access.sh "${ACCESS_ARGS[@]}" --emit-stats > "$acc_stats"
```

若將 `--slow-*-ms` 傳給 `analyze_access.sh`，其失敗快速的 `die`（未知
參數）會中止第二個衍生程序。

#### 3.0.3 `--emit-stats` 的標準 schema

兩個分析器依據下列契約（定義於 `lib/aggregate_utils.sh` 中的常數）
輸出 TAB 分隔列：

**IIS schema**（`IIS_STAT_SCHEMA`）：
```
IIS  <region>  <role>  <server>  TOTAL      <n>
IIS  ...                         SLOW       <n>
IIS  ...                         UNIQUE_IPS <n>
IIS  ...                         STATUS     <code>  <count>
IIS  ...                         ENDPOINT   <uri>   <count>  <avg_sec>  <sum_ms:int>
IIS  ...                         CLIENT_IP  <ip>    <count>
IIS  ...                         CATEGORY   <key:glcr|ds|nhi>  <count>  <sum_ms:int>
  注意：ENDPOINT 位置 9 = 各伺服器 --top N 輸出列的累積耗時毫秒（整數；
        見 §3.2.5 GAP-3 說明）。欄位 8（avg_sec）不變，供所有現有下游
        消費端使用（摘要平均值聚合除外）。
  注意：CATEGORY 位置 8 = 累積耗時毫秒（整數，非 avg_sec）。
        avg_sec = sum_ms/count/1000（單次除法 → 跨伺服器精確平均值）。
        CATEGORY 聚合不受 --top 截斷，涵蓋完整請求母體。
```

**OVERVIEW_AWK**（`bin/analyze_overview.sh`）亦從 CATEGORY 列跨伺服器聚合
中額外輸出一種 row 類型，供 `overview_render` 內部使用：
```
  CAT_REGION  <region>  <key:glcr|ds|nhi>  <count>  <avg_sec>
```
此列攜帶各區域每個類別鍵的筆數與精確平均值（Σsum_ms / Σcount / 1000）。
並非由 `AGG_IIS_AWK` 發出，而是 `OVERVIEW_AWK` 自身的區域聚合步驟。

所有列均反映**業務流量**：`/health` 請求已無條件排除，且已依 `--test-hosts`
模式（§3.2.14）套用測試主機過濾。`TOTAL` 因此僅計業務請求。`STATUS` 列為
描述性 Top-N 狀態碼分布（業務流量，302/404 可能出現——此為刻意設計，代表
真實業務回應）。原先的 `5XX`、`503_HEALTH`、`REDIRECT` 聚合列已移除；
相依服務健康偵測現在僅存在於 `analyze_errors`（見 §3.3）。

`role` 為 `api` 或 `app`（由 `conf/regions.conf` 解析）。`region` 為
`taipei` 或 `taichung`；合併模式標記 `region=all, server=API_SERVERS|APP_SERVERS`。
逐伺服器粒度讓 overview 可以加總 CATEGORY 的 `sum_ms`/`count`，再單次
除法（精確跨伺服器平均值，無中間捨入誤差）。

**Access schema**（`ACCESS_STAT_SCHEMA`）：
```
ACCESS  <region>  NORMAL        <n>
ACCESS  ...       ORPHAN        <n>
ACCESS  ...       UNVERIFIED    <n>
ACCESS  ...       ORPHAN_OK     <n>
ACCESS  ...       ORPHAN_FAIL   <n>
ACCESS  ...       DELTA_COUNT   <n>
ACCESS  ...       DELTA_SUM     <sec>
ACCESS  ...       DELTA_MIN     <sec>
ACCESS  ...       DELTA_MAX     <sec>
```

#### 3.0.4 兩視角版面——數值字面值單一放置規則（C5）

報告呈現兩種獨立的分解維度。**任一數值字面值不得跨視角重複出現。**

- **總體概況**：存取業務大總計（含值 + 百分比）、平均 API→APP 延遲、定性
  判定。`存取關聯總數` **僅出現於此處**。判定行不含數字（僅文字）。IIS 一般
  總計（`IIS 總請求數`、不重複 IP）**不顯示**——概覽以存取業務為焦點。緊
  接著在總體概況內部呈現一個 **■ 核心功能效能 (Core Function Performance)**
  子區塊，列出三個 IIS 來源、UTC+8 日期修正的類別（雲端查詢 / 報告摘要 /
  影像下載），各顯示 `呼叫次數 <筆數>` 與 `回應時間 <平均>s`（無逐列百分比），
  以及純筆數 `核心功能存取合計 <總計>`（無百分比）。類別定義見 §3.0.7。
- **分區別**：每個在範圍內的區域各有一個 ■ 區塊，以散文形式開頭：
  `存取關聯 N 筆 — NORMAL n (p%) · ORPHAN n (p%) · UNVERIFIED n (p%)`
  （百分比為該區域總筆數之比率），接著呈現同三個核心功能類別（呼叫次數 +
  回應時間）。類別筆數與平均值採全量累計，不受 `--top` 截斷影響。
  **單一區域範圍（D8）：** 執行 `--region taipei` 時，分區別 台北 區塊
  刻意顯示與總體概況相同的 N/O/U 總計與類別筆數——這是正確的 ROLLUP+明細
  對稱行為（非重複計算）；區域標籤與框架才是附加價值。若針對單一區域範圍
  隱藏分區別，將破壞回歸測試並引入不必要的分支。

獨立的**核心功能效能**視角已溶入總體概況（全局）與分區別（各區域），
無資訊遺失；逐列百分比與速度子標籤已移除（見 §3.0.7）。

**服務別（By Service Role）已退役。** 其 IIS 一般請求內容因需以存取業務
為焦點而移除（req5）；其僅剩的存取角色訊號（UNVERIFIED/ORPHAN）現已在
總體概況以值 + % 呈現，因此保留會違反 C5 數值單一放置規則。無資訊遺失。

**整體健康判定基準**（req4）：判定由 `lib/aggregate_utils.sh` 中的
`overview_health_verdict` 函式計算（單一事實來源，D1），基準視窗為已完整
解析的分析期間。比率：`P = trunc(NORMAL ÷ 存取關聯總數 × 100)` ——
**整數截斷（趨零截斷）**（以 `printf "%d"` 實作，非銀行家捨入；
P = 89.5% → trunc → 89 → 注意，非正常；P = 90.0% → 90 → 正常）。
IIS 請求量**不**納入判定。

| 條件（整數 P = trunc(NORMAL ÷ 存取關聯總數 × 100)） | 判定 | 文案 |
|---|---|---|
| 存取關聯總數 = 0 | 無資料 | 無資料 — 本期間無存取關聯記錄 |
| P ≥ 90 | 正常 | 正常 — 系統整體運作健康 |
| 70 ≤ P ≤ 89 | 注意 | 注意 — 存在異常存取，建議持續監控 |
| P < 70 | 警告 | 警告 — 存取異常比例偏高，建議立即調查 |

下界含頭（`>=`）。P = 89.5% → trunc → 89 → 注意（非正常；90 為臨界值）。
P = 90.0% → 90 → 正常。

輸出範例（單日 `--date 2026-05-21`，全區域，
`--test-hosts exclude` 預設——僅業務流量）：
```
========================================================================
  營運總覽報告 (Management Overview)
========================================================================
  分析期間                                2026-05-21  →  2026-05-21  (1 天)
  涵蓋範圍                                2 區域 / 6 伺服器 (2 API · 4 APP)

▶ 總體概況 (Overall)
------------------------------------------------------------------------
  存取關聯總數                            9
  NORMAL 正常流程                         6 (66.7%)
  ORPHAN 無對應簽發                       3 (33.3%)
  UNVERIFIED 簽發未使用                   0 (0.0%)
  平均 API→APP 延遲                       19.5s
  整體健康判定                            警告 — 存取異常比例偏高，建議立即調查

    ■ 核心功能效能 (Core Function Performance)
      雲端查詢    呼叫次數 11       回應時間 0.11s
      報告摘要    呼叫次數 186      回應時間 0.38s
      影像下載    呼叫次數 427      回應時間 0.93s
      核心功能存取合計 624

▶ 分區別 (By Region)
------------------------------------------------------------------------

    ■ 台北 (taipei)
      存取關聯 3 筆 — NORMAL 0 (0.0%) · ORPHAN 3 (100.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 5        回應時間 0.02s
      報告摘要    呼叫次數 71       回應時間 0.22s
      影像下載    呼叫次數 220      回應時間 1.48s

    ■ 台中 (taichung)
      存取關聯 6 筆 — NORMAL 6 (100.0%) · ORPHAN 0 (0.0%) · UNVERIFIED 0 (0.0%)
      雲端查詢    呼叫次數 6        回應時間 0.19s
      報告摘要    呼叫次數 115      回應時間 0.47s
      影像下載    呼叫次數 207      回應時間 0.34s
```

#### 3.0.5 接受 / 拒絕的旗標

接受：`--log-dir`、`--region`、`--today`、`--date`、`--from`/`--to`、
`--days`、`--slow-api-ms`、`--slow-app-ms`、`--test-hosts`、`--output-dir`、
`--conf`、`-v`、`-h`。

收到即 die（不接受）：`--view`、`--format`、`--merge`、`--top`、
`--emit-stats`。

#### 3.0.6 持久化

僅摘要：`persist_views overview summary text overview_render ''`。
僅在執行目錄 `<base>/<RUN_TS>/` 下寫入 `overview_summary.txt`
（`DETAIL_FN=""` → 無詳細檔案）。
空時間視窗邊界：百分比以 `N/A` / `0.0%` 呈現，正常 exit 0。

#### 3.0.7 核心功能效能 — 類別定義（單一事實來源：`AGG_IIS_AWK`）

三個類別以**大小寫不敏感的錨定正規表達式**對原始 `cs-uri-stem` 進行比對，
模式定義一次於 `AGG_IIS_AWK`（`lib/aggregate_utils.sh`），同時供
`analyze_iis` 與 `analyze_overview` 使用：

| 鍵 | 標籤 | 比對模式 | 角色 |
|----|------|---------|------|
| `glcr` | 雲端查詢 | `^/api/GetLungCancerReportURL$`（精確） | APP |
| `ds` | 報告摘要 | `^/api/DigestSummary(/|$)`（前綴） | API |
| `nhi` | 影像下載 | `^/api/NhiPatientImage/studies/`（前綴） | API |

類別比對與端點 Top-N 上限（`--top`）無關；所有命中列均納入計算，不受上限
截斷。`nhi` 前綴涵蓋完整 DICOM 下載家族（series、series-uid、instances、jpg）；
非下載類 `NhiPatientImage` 子路徑依設計不納入統計。

`glcr` 流量完全由 APP 角色伺服器承接（範例資料驗證：台中 APP 6 筆 + 台北 APP
5 筆 = 11 筆）。`ds` 與 `nhi` 為 API 角色。

**精確平均值：** `AGG_IIS_AWK` 輸出原始整數 `sum_ms` 累積值。`OVERVIEW_AWK`
跨伺服器加總 `Σsum_ms` 與 `Σcount`，再**單次除法**（`sum_ms / count / 1000.0`）
——無中間每伺服器捨入，無末位誤差漂移。

**`--slow-api-ms` / `--slow-app-ms` 與 overview：** 這兩個閾值由
`analyze_overview` 接受並轉傳給 IIS 子程序，用於控制全局 IIS `SLOW` 統計桶。
然而，overview 僅消費 `CATEGORY` 列（含 `count` + `sum_ms`，無慢速欄位），
因此這兩個閾值**不影響** overview 任何顯示值。

#### 3.0.8 單日每小時橫條圖 — 存取紀錄橫條圖

當分析視窗恰好為**一天**（`_OVW_N_DATES==1`）時，`overview_render`
透過 `_render_hour_chart` 附加 `存取紀錄橫條圖 (每小時)` 區段：

- **資料來源**：由 `analyze_access --emit-stats` 中的 `agg_access_records`
  輸出的 `HOUR` 列；`OVERVIEW_AWK` 將其收集至 `acc_hour[HH]`（全局）與
  `acc_hour_r[region,HH]`（各區域）。
- **統計單位**：NORMAL+ORPHAN 的 APP_TIME 小時數（與 REQ2 使用相同謂詞；
  APP_TIME 已為 UTC+8，無需再轉換）。UNVERIFIED 列無 APP_TIME，排除在外。
- **橫軸**：`00..LAST`，以零填充。過去單日日期（如 `--date 2026-05-21`）
  `LAST=23`（完整橫軸）。`--today` 時 `LAST = local_hour() - 1`；
  當小時為 0 時 `LAST=-1` → 顯示 `(今日尚無完整小時資料)` 提示而非橫條圖。
- **今日截止與 TZ 前提條件**：`local_hour()`（位於 `lib/date_utils.sh`）
  與 `today()` 讀取同一主機時鐘，因此觸發條件（`_OVW_DATE_START == today()`）
  與截止（`LAST = local_hour()-1`）永遠讀取同一個時鐘，不會產生偏差。
  **前提條件**（繼承，非新增）：主機時鐘必須為 UTC+8（與 `today()` 已
  做的假設相同）。在非 UTC+8 主機上，請以 `TZ=Asia/Taipei` 執行 —
  此設定同時平移 `today()` 與 `local_hour()`，使觸發條件與截止保持正確。
  請勿只把 `local_hour()` 固定為 Asia/Taipei；此做法會在 UTC 主機上使
  觸發條件與截止產生偏差。
- **渲染**：`lib/fmt_utils.sh` 中的 `fmt_bar` 將 stdin 上的標籤+計數對
  渲染為比例式 U+2588 橫條圖（LC_ALL=C；最多 40 格；當 val>0 時最少 1 格；
  U+2588 以 `sprintf "%c%c%c", 226, 150, 136` 輸出）。
- **多日閘控**：`_OVW_N_DATES > 1`（如 `--from`/`--to` 或 `--days`）時
  不渲染橫條圖。週報固定檔案保持無橫條圖。
- **版面**：一個全局橫條圖接在 `▶ 總體概況` 的 `核心功能存取合計` 之後；
  各 `■ 台北` / `■ 台中` 區塊中各區域類別列之後各有一個每區域橫條圖。

**已驗證基準值（2026-05-21，全區域，預設 exclude）：**

| 範圍 | 小時 | 計數 |
|------|------|------|
| 全局 | 13 | 1 |
| 全局 | 14 | 4 |
| 全局 | 15 | 4 |
| 台北 | 15 | 3 |
| 台中 | 13 | 1 |
| 台中 | 14 | 4 |
| 台中 | 15 | 1 |

---

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

`TOKEN` / `ISSUE_TOKEN` 為 API 伺服器針對病患報告連結（report-url）核發之
compact JWS（JWT）：`<header>.<payload>.<signature>`，其 base64url 編碼之
payload（第 2 段）攜帶 `pid`、`dob`、`typ`、`hospId`、`prsnId`、`clientIp`
等 claim。§3.1.5 說明如何將 `dob` claim 解碼為 `BIRTHDAY` 輸出欄位。

#### 3.1.3 比對邏輯

**聯結鍵**：`API.ISSUE_TOKEN (col 9)` ≡ `APP.TOKEN (col 2)`。

比對前，`CLIENT_IP`（CSV 第 7 欄）符合測試主機集合的紀錄，會在**擷取
階段**（`lib/csv_utils.sh` 中的 `extract_api_records` / `extract_app_records`）
依 `--test-hosts` 模式（§3.2.14）丟棄。由於 Token 的 API 簽發列與 APP
驗證列攜帶相同的 `CLIENT_IP`，兩側會同步被過濾——不會產生 orphan 或
unverified 殘留紀錄。

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
執行一次 CORRELATE_AWK — 詳見 §3.1.10。

#### 3.1.4 輸出類別

| 類別        | 意義                                                                                              | 嚴重性       |
|-------------|---------------------------------------------------------------------------------------------------|--------------|
| NORMAL      | APP 收到之 Token 由語料庫中某台 API 伺服器簽發（預設為同區域；`--merge` 下可跨區域）             | 綠色（正常）|
| ORPHAN      | APP 收到在語料庫中找不到對應 API 簽發紀錄之 Token                                                | 黃色（警告）|
| UNVERIFIED  | API 簽發但 APP 從未收到驗證請求                                                                   | 灰色（資訊）|

可能造成 ORPHAN 的原因：跨區域 Token 重播（未使用 `--merge` 時）、手動
拼湊 URL、CSV 入庫延遲。UNVERIFIED 通常是使用者在開啟檢視器前放棄。

#### 3.1.5 內部 schema — CORRELATE_AWK 輸出

雙檔 gawk 聯結每筆紀錄產生 13 個 TAB 分隔欄位。欄位順序遵循「時間 →
結果 → 身分 → 伺服器 → 病患」，將時間排序鍵置於前段，可變寬度之
`PATIENT_ID_AES` 與 `BIRTHDAY` 置於末段。

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
| $13 | `BIRTHDAY` | `jwt_dob(tok)` | `jwt_dob(tok)` | `jwt_dob(tok)` |

`REQUEST_ID` 合併原先之 `API_REQUEST_ID` 與 `APP_REQUEST_ID`；合併規則為
「優先取 API id，回退取 APP id」。三種類別均包含 `PRSN_ID` 與 `CLIENT_IP`。
`PATIENT_ID_AES` 完整輸出，先前之 `substr(…, 1, 16)"..."` 截斷已移除。
`BIRTHDAY` 以 VERBATIM 方式輸出 8 位數 `YYYYMMDD` 字串，缺失時為 `-`
哨兵值——詳見下方說明。`-` 表示該類別中不存在之欄位。

**BIRTHDAY 解碼 — report-url JWT payload。** `$13` 為解碼所得，並非讀取
自 CSV 欄位。`tok`——比對聯結鍵（API `ISSUE_TOKEN` col 9 / APP `TOKEN`
col 2，§3.1.2）——為 compact JWS `<header>.<payload>.<signature>`。
`jwt_dob(tok)`（一個可前置串接之 gawk 函式字串常數 `JWT_DOB_FUNC`，定義於
`lib/csv_utils.sh`，與 `common.sh` 之 `TH_FILTER_FUNC` 相同模式）以純
gawk 6-bit 累加器對第 2 段進行 base64url 解碼，並以正規表示式擷取 `"dob"`
claim——不呼叫 `base64` / `openssl` / `python` 子行程，符合本工具零新增
執行期依賴之原則。`_run_correlate` 在 `LC_ALL=C` 之下執行整個
`CORRELATE_AWK`（前置串接 `JWT_DOB_FUNC`）步驟，使 `sprintf("%c", byte)`
無論呼叫端 shell 之 locale 為何，皆精確輸出一個位元組——與 `FMT_AWK_WIDTH`
子區塊及 `access_render_summary` 已採用之 `LC_ALL=C` 慣例相同。JWT
**簽章不驗證**：payload 僅供報表讀取，絕不作為驗證或授權之依據。

`dob` 以**逐字（verbatim）**方式擷取（`[^"]*`——無 `/^[0-9]{8}$/` 格式
關卡），僅進行*結構性*淨化：移除 `TAB` / `CR` / `LF`，確保該值永遠不會
拆散 TSV/CSV 資料列。隨附範例資料集中每個 token 均解碼為 8 位數
`YYYYMMDD` 字串；若上游 token 未來攜帶不符格式之 `dob`，逐字輸出會讓此
偏移於 `BIRTHDAY` 欄位中可見浮現，而非靜默地摺疊為 `-` 哨兵值（對應
CLAUDE.md 快速失敗／禁止靜默抑制之原則）。當 token 為空字串、dot-segment
少於兩段、payload 段為空、或解碼後 payload 不含 `dob` claim（或其值為空）
時，`jwt_dob` 回傳 `-` 哨兵值——與其他欄位缺失時使用之哨兵值相同。

**PII 注意事項。** 與 AES 加密之 `PATIENT_ID_AES` 不同，`BIRTHDAY` 為明文
出生日期——屬真正的個人識別資訊（PII）。`analyze_access.sh` 為內部、經
授權之唯讀診斷工具；持久化之 `access_detail.*` 檔案繼承
`<base>/<RUN_TS>/` 之檔案系統權限，應以與 `PATIENT_ID_AES` 相同之謹慎
程度處理。`BIRTHDAY` 未套用任何額外加密或遮蔽。

#### 3.1.6 決定性排序前置步驟

CORRELATE_AWK 執行完畢後，由單一共用 gawk 步驟（`sort_records`）將全部
13 欄紀錄排序為 `result_sorted`，再由各渲染器讀取。此步驟確保 text、tsv、
csv 三種格式共享同一組位元組穩定（byte-stable）的輸出順序。`BIRTHDAY`
（$13）不在下方複合排序鍵範圍內，故其新增不影響排序結果——已驗證新輸出
去除末端欄位後，與新增前之 12 欄排序結果逐位元組相同。

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

#### 3.1.7 視圖

`--view detail`（standalone 預設）：逐筆比對表格，詳見 §3.1.8–3.1.9。
同時控制 console 輸出與持久化的詳細檔案。

`--view summary`（管理文字；格式獨立——永遠為文字）：KPI 區塊，含加總
計數 + 百分比、分區別分解、ORPHAN 驗證結果摘要、API→APP 平均/最短/最長
延遲。不含逐筆 `PATIENT_ID_AES`。

**摘要視圖不論 `--format` 為何，永遠輸出文字**（C10）。`--format` 僅
控制詳細檔案的副檔名與渲染路徑。

#### 3.1.8 文字輸出 — 各類別欄位（detail 視圖）

每個類別僅顯示其實際存在之欄位；對該類別不存在之欄位一律省略。所有類
別均包含 `PRSN_ID`、`CLIENT_IP`、固定寬度 `%-32s` 欄位之完整未截斷
`PATIENT_ID_AES`，以及作為末端可變寬度欄位之 `BIRTHDAY`。每個類別印出
一列灰色表頭。紀錄依 §3.1.6 之決定性升冪順序排列。

共用欄位寬度：`TIME=23 · SERVER=15 · DELTA=8 · VERIFY=7 ·
REQID=13 · HOSP=12 · PRSN=12 · CLIENT=16 · PATIENT=32`。

**NORMAL** — 以雙時間欄開頭，含時間差與驗證狀態：
`API_TIME, APP_TIME, DELTA, VERIFY, REQUEST_ID, API_SRV, APP_SRV, HOSP_ID,
PRSN_ID, CLIENT_IP, PATIENT_ID_AES, BIRTHDAY`。
DELTA 格式為 `%.1fs`（夾鉗 ≥ 0），不存在時顯示 `N/A`。後接時間差統計：
有效筆數、平均、最短、最長。

**ORPHAN** — 以 `APP_TIME` 開頭（無 `API_TIME`、`API_SERVER`、`DELTA`）：
`APP_TIME, VERIFY, REQUEST_ID, APP_SRV, HOSP_ID, PRSN_ID, CLIENT_IP,
PATIENT_ID_AES, BIRTHDAY`。
後接驗證結果摘要；若任一 ORPHAN 之 `VERIFY=OK`，加附警示訊息。

**UNVERIFIED** — 以 `API_TIME` 開頭（無 `APP_TIME`、`APP_SERVER`、`DELTA`、
`VERIFY`）：
`API_TIME, REQUEST_ID, API_SRV, HOSP_ID, PRSN_ID, CLIENT_IP, PATIENT_ID_AES,
BIRTHDAY`。

`PATIENT_ID_AES` 固定佔用 `%-32s` 欄位，`BIRTHDAY` 接續其後成為末端欄位；
資料列自 `PATIENT_ID_AES` 起維持內部一致之欄位起點，與 12 欄輸出時期已
存在之 `REQUEST_ID` 後方水平位移相同（36 字元 `REQUEST_ID` UUID 會溢出
其 `%-13s` 欄位，故任一類別之表頭與資料列本就不會垂直對齊——此為既有偏移，
與 `BIRTHDAY` 之新增無關且未受其影響）。`BIRTHDAY` 現為末端欄位，於窄
終端可能折行。兩欄皆不套用任何截斷。

#### 3.1.9 機器可讀輸出 — `tsv` 與 `csv`（detail 視圖）

兩種格式均為 `result_sorted` 之平坦輸出（與 text 共享 §3.1.6 之決定性
順序）。每列在最前方加上 `REGION` 欄（區域名稱，`--merge` 時值為
`merged`）。14 欄 schema：

```
REGION  STATUS  API_TIME  APP_TIME  DELTA_SEC  VERIFY_STATUS  REQUEST_ID
API_SERVER  APP_SERVER  HOSP_ID  PRSN_ID  CLIENT_IP  PATIENT_ID_AES  BIRTHDAY
```

`PATIENT_ID_AES` 仍為第 13 欄；`BIRTHDAY` 為新增之第 14 欄——讀取固定
第 1‥13 欄之外部解析器不受此次新增影響。

- **`--format tsv`** — TAB 分隔，不加引號。
- **`--format csv`** — 逗號分隔，RFC-4180 條件式引號（透過
  `lib/aggregate_utils.sh` 中的共用 `q()` 函式 `AGG_CSV_FUNC`）：欄位
  僅在包含 `"`、`,` 或換行時才加引號；內部 `"` 以雙引號跳脫。LF 行結尾。
  不含上述字元之欄位不加引號輸出。

每份輸出僅印一列表頭（tsv 為 TAB 聯結；csv 為逗號聯結）。兩種格式共用
§3.1.6 之位元組穩定順序。

#### 3.1.10 `--merge` 語義

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

#### 3.1.11 `--emit-stats`

將 `access_stats.tsv` 逐字印至 stdout，然後在 `persist_init` 之前返回
（無檔案、無標題橫幅）。這是 `analyze_overview.sh` 的資料來源。
僅接受旗標子集（interval / region / conf / verbose），**不接受**
`--slow-*-ms`（會觸發失敗快速的 `die` 未知參數）。

#### 3.1.12 `access_ip_counts.tsv` — 常開式 IP 歸因檔案

每次**真實**（非 `--emit-stats`）`analyze_access` 執行，會在
`<base>/<RUN_TS>/` 下的 `access_summary.txt` 與 `access_detail.*` 旁
寫入第三個持久化檔案 `access_ip_counts.tsv`：

- **資料來源**：`result_sorted` 中 `$1 == "NORMAL" || $1 == "ORPHAN"` 的列。
  與 `agg_access_records` 使用相同謂詞（REQ2 與 REQ3 的單一共用來源）。
  UNVERIFIED 列排除在外（APP 伺服器從未收到，無存取發生）。
- **IP 鍵**：`$11`（CLIENT_IP）合併值——空白或 `"-"` → 哨兵 `"-"`。
  `"-"` 哨兵用以呈現真實的上游日誌缺失（CLIENT_IP 欄位空白），而非
  靜默略過這些紀錄。
- **排序順序**：計數降冪，IP 升冪（用於平手時的決勝）。
- **Schema**：TSV 表頭 `CLIENT_IP<TAB>REQUEST_COUNT`，後接資料列。
  空語料庫 → 僅含表頭的檔案（恰好 1 行）。
- **範圍**：自動涵蓋 `--region`、`all` 與 `--merge`（讀取 `_ACC_SORTED`，
  即渲染器使用的同一後比對陣列）。
- **從不輸出至 stdout**：此檔案為側向產物；不會出現在主控台鏡像或
  `--emit-stats` 輸出中。
- **`agg_access_records` 防護**：`APP_TIME`（`substr($3,12,2)`）格式錯誤
  （不符 `/^([01][0-9]|2[0-3])$/`）時，向 stderr 輸出 `[WARN]` 並排除
  於小時統計——但該記錄的 IP 仍納入計數（快速失敗、非靜默；與
  `ts_to_epoch` 返回 `N/A` 之現有優雅降級先例一致）。

**已驗證範例（2026-05-21，--region all，預設 --test-hosts exclude）：**
```
CLIENT_IP	REQUEST_COUNT
-	9
```
（在 `exclude` 模式下，所有 9 筆業務記錄的 CLIENT_IP 上游均為空白。
以 `--test-hosts all` 執行時，額外出現 `192.168.139.110<TAB>3` 列。
以 `--test-hosts only` 執行時，只有 `192.168.139.110<TAB>3` 一列。）

---

### 3.2 `analyze_iis.sh` — IIS W3C 日誌分析

#### 3.2.1 目的
揭露**業務流量**之 HTTP 層關鍵指標：請求量、狀態碼分布、慢端點、
唯一用戶端 IP。`/health` 請求無條件排除於所有聚合之外；測試主機 IP
依 `--test-hosts` 模式過濾（預設：`exclude`）。見 §3.2.14。

#### 3.2.2 時區修正（UTC+0 → UTC+8）

IIS W3C 日誌以 **UTC+0** 時間記錄。業務 / 參考時區（存取 CSV 與 .NET
應用程式日誌）為 **UTC+8**。UTC+8 業務日 `D` 等同 UTC 區間
`[D−1 16:00:00, D 16:00:00)`（截止時刻 = 24 − `IIS_UTC_OFFSET_HOURS` = 16）。

**檔案選取：** 對於要求的本地端範圍 `[START, END]`，分析器讀取
`u_ex(START−1) .. u_ex(END)` 的檔案（前置 D−1 檔以涵蓋對應本地時間
00:00–07:59 的 UTC 夜間小時段）。若前一日檔案不存在（例如 START 為最早
可用日期的 `u_ex260517`），現有的 `[[ -f ]]` 防護將靜默跳過——邊界不
完整，但不中止執行。

**列過濾：** 選取檔案後，`AGG_IIS_AWK` 套用半開放 UTC 字串邊界防護：

```
TZ_LO = (START − 1) " 16:00:00"   含頭
TZ_HI =  END        " 16:00:00"   不含尾
保留列  ⟺  TZ_LO ≤ ($1 " " $2) < TZ_HI
```

`$1`（`YYYY-MM-DD`）與 `$2`（`HH:MM:SS`）為固定寬度零補齊的 W3C 欄位，
因此字典序字串比較與時間序完全一致——無需 `mktime`，不依賴主機 `TZ` 設定。

**跨午夜範例**（`--date 2026-05-21`；`TZ_LO="2026-05-20 16:00:00"`，
`TZ_HI="2026-05-21 16:00:00"`）：

| UTC `$1 $2` | 本地時間（+8h） | 結果 |
|---|---|---|
| `2026-05-20 15:59:00` | 2026-05-20 23:59 | 丟棄（前一本地日） |
| `2026-05-20 16:30:00` | 2026-05-21 00:30 | **保留** |
| `2026-05-21 10:48:18` | 2026-05-21 18:48 | **保留** |
| `2026-05-21 16:00:00` | 2026-05-22 00:00 | 丟棄（下一本地日） |

**單一事實來源：** `IIS_UTC_OFFSET_HOURS=8` 與 `iis_utc_window` 定義於
`lib/date_utils.sh`；字串邊界過濾防護定義於 `lib/aggregate_utils.sh` 的
`AGG_IIS_AWK`。這是 +8h 語意唯一存在的兩處。`analyze_iis` 與
`analyze_overview` 為純消費端——無重複的時區 / 類別邏輯。

**`--date D` 語意：** `analyze_iis --date D` 現在代表 UTC+8 業務日 `D`。
顯示視窗（`dates.txt`）不變；IIS 檔案選取清單（`iis_dates.txt`）以
`date_add(START, -1)` 前置。存取與 .NET 應用程式日誌原生為 UTC+8，不受
影響。

**附帶資料集的數值不變性：** 範例資料集中所有非 `/health` 的 IIS 列
UTC 時間均 < 16:00:00——+8h 修正在架構上必要，但對此資料集數值上無影響
（業務計數不變）。

#### 3.2.3 輸入

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

#### 3.2.4 端點分組

`cs-uri-stem` 內含 DICOM study / series UID，會把端點計數的 cardinality
炸開。分析器在計數前先將下列三類 DICOM 路徑收斂為 template：

```
/api/NhiPatientImage/studies/{uid}/series/{uid}/...
/api/NhiPatientImage/studies/{uid}/series-uid
/api/NhiPatientImage/studies/{uid}/instances/{uid}
```

其他路徑維持原樣。

#### 3.2.5 聚合訊號

所有指標均作用於**業務請求**：`/health` 請求無條件排除（精確欄位比對
`cs-uri-stem == "/health"`，大小寫區分；query-string 為獨立欄位，因此
`/health?x=1` 在 stem 上仍命中；`/healthz` 與 `/Health` 不被過濾——此為
刻意設計，沿用原有語義）。在任何計數前，測試主機 IP 已依 `--test-hosts`
模式過濾（§3.2.14）。

| 指標              | 定義                                                                                                                                                   |
|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|
| `total`           | 業務請求數（/health 排除及測試主機模式套用後）                                                                                                         |
| `status_count[]`  | 各狀態碼計數（如 200、302、404）——描述性 Top-N 分布，業務流量                                                                                         |
| `slow`            | `time-taken >= threshold` 之列數；threshold 為 API 角色用 `--slow-api-ms`（預設 2000 ms）、APP 角色用 `--slow-app-ms`（預設 5000 ms）                  |
| `client_ips`      | `c-ip → 請求數` 之 hash；`length()` 得唯一 IP 數，迭代後產出 IP 表格。`-` 排除。                                                                      |
| `top endpoints`   | 請求數 Top-N 端點（DICOM 分組後），N 由 `--top` 控制（預設 10，0=全部）；各端點附**平均回應時間**（秒，四捨五入至 2 位小數）。**GAP-3 說明：** 每台伺服器僅輸出自身的 top-N 端點列，因此摘要視圖的逐端點 avg / pct / count 聚合自**各伺服器截斷後的子集**，而非落在各伺服器 top N 之外的端點的完整請求母體。CATEGORY 聚合（雲端查詢 / 報告摘要 / 影像下載）不受截斷，涵蓋所有命中列。外部重現逐端點平均值時，必須重現相同的 per-server cap 才能得到一致的數字。 |
| `client_ip_roster`| 請求數 Top-N 唯一 `c-ip` 及其請求數與占 `total` 之百分比，N 由 `--top` 控制（0=全部）                                                                |

三張表格之 `% of total` 分母均為該伺服器或語料桶之 `total` 業務請求數。
當 `--top` 截斷端點或 Client IP 清單時，可見列之百分比加總不會達到 100%。

#### 3.2.6 單一計算來源

`main()` 為每台伺服器建立 `$combined` 一次，對每個語料執行一次
`agg_iis_rows`（以 `region role server` 前置詞將維度化列寫入
`iis_stats.tsv`），之後不再重新解析日誌。純渲染器讀取 `iis_stats.tsv`。

#### 3.2.7 視圖

`--view detail`（standalone 預設——D2）：§3.2.8–3.2.9 所述之逐伺服器
報告版面。無資訊遺失。

`--view summary`（管理文字；格式獨立——永遠為文字）：每個範圍（整體
標題，然後是每區域→伺服器，或合併語料桶）的簡潔 KPI + %。含`資料範圍`
管理橫幅（業務請求；排除 /health；測試主機模式）。僅顯示 Top-3 列舉；
省略完整表格。每行皆含百分比。

摘要的 **Top 端點 (佔比 · 平均回應時間)** 子區塊列出最多 `--top` 個
端點，含靠右對齊序號（` 1.`…`10.`，固定寬度 `%2d.`，避免排名 ≥ 10
時欄位錯位）、佔比百分比及各端點平均回應時間（秒）。avg / pct / count
聚合自各伺服器 top-N 截斷子集（見 §3.2.5 GAP-3 說明）。

**摘要視圖不論 `--format` 為何，永遠輸出文字**（C10）。`--format` 僅
控制詳細檔案的副檔名與渲染路徑。

#### 3.2.8 詳細文字輸出（--format text）

每個所選區域之每台伺服器，或 `--merge` 下之每個角色語料桶：

1. `Scope`（資料範圍）橫幅——`business requests (excl. /health; test-hosts=MODE)`
   ——讓讀者明確知曉所呈現流量的宇集範圍。
2. 頂部計數列：`Total requests`、`Unique client IPs`、`Slow (>Nms)` —
   標籤中之閾值反映該伺服器之角色。
3. HTTP 狀態碼表 — 欄位 `["Status", "Count", "% of total"]`，按計數降冪。
   排序在 gawk 內完成（不使用外部 `sort`）。
4. 端點表 — 欄位 `["Endpoint", "Avg(s)", "Count", "% of total"]`，按計數
   降冪。以 `--top` 列數上限（預設 10；0=全部）。
5. Client IP 表 — 欄位 `["Client IP", "Count", "% of total"]`，按計數降冪。
   以 `--top` 列數上限。當所有列之 `c-ip = -` 時為空。

IIS 各表均為純計數降冪排名清單；不存在逐筆時間序詳細清單。

#### 3.2.9 詳細機器可讀輸出（--format tsv|csv）

真實長格式表格（**新功能**——此重構前為 no-op + 警告）。每個指標列一
筆紀錄；表頭輸出一次；`--top` 上限套用於 ENDPOINT 與 CLIENT_IP 列。
欄位 schema：

```
REGION  ROLE  SERVER       METRIC    KEY                COUNT  AVG_SEC  PCT
taipei  api   10.22.63.37  SUMMARY   TOTAL              723    -        100.0
taipei  api   10.22.63.37  SUMMARY   SLOW               2      -        0.3
taipei  api   10.22.63.37  STATUS    200                631    -        87.3
taipei  api   10.22.63.37  ENDPOINT  /api/Auth/IssueTok 5000   0.12     12.5
taipei  api   10.22.63.37  CLIENT_IP 192.168.139.119    712    -        98.5
```

`TOTAL` 及所有衍生列均計業務請求。`SUMMARY` 列為 `TOTAL`、`SLOW`、
`UNIQUE_IPS`；原先的 `5XX`、`503_HEALTH`、`REDIRECT` SUMMARY 列已移除。

CSV 使用共用 `q()` RFC-4180 引號處理器（`AGG_CSV_FUNC`）。TSV 使用
TAB 分隔不加引號。兩種持久化檔案均不含 ANSI 色碼。

#### 3.2.10 依角色分流之慢請求閾值

`--slow-api-ms`（預設 2000 ms）適用於 `REGION_APIS` 中的伺服器；
`--slow-app-ms`（預設 5000 ms）適用於 `REGION_APPS` 中的伺服器。角色
歸屬由 `conf/regions.conf` 解析。預設值反映 API Token 簽發端點比 APP DICOM
服務端點更嚴格之 SLA 要求。報告中 `Slow (>Nms)` 標籤顯示該伺服器實際採
用之閾值。

#### 3.2.11 `--top` 旗標

控制端點表與 Client IP 表各自最多顯示之列數（預設 10；0=全部）。同一次
執行中兩張表套用相同上限。此旗標在 `analyze_iis` 與 `analyze_errors` 之
間統一（名稱相同、0=all 語義相同，作用對象不同）。

#### 3.2.12 `--merge` — 雙語料桶跨區域合併

使用 `--merge` 時，對所有已設定區域執行迭代，建立兩份語料：

- **API 語料**：串接所有區域之 `REGION_APIS` 伺服器的 IIS 日誌。
- **APP 語料**：串接所有區域之 `REGION_APPS` 伺服器的 IIS 日誌。

`agg_iis_rows` 對每份語料各執行一次，產生兩個輸出區塊：
1. `IIS — API_SERVERS (merged, all regions)` — 使用 `--slow-api-ms` 閾值。
2. `IIS — APP_SERVERS (merged, all regions)` — 使用 `--slow-app-ms` 閾值。

#### 3.2.13 `--emit-stats`

將 `iis_stats.tsv` 逐字印至 stdout，然後在 `persist_init` 之前返回
（無檔案、無標題橫幅）。這是 `analyze_overview.sh` 的資料來源。

#### 3.2.14 測試主機過濾與 `/health` 排除

`agg_iis_rows`（位於 `lib/aggregate_utils.sh`）在讀取階段依**固定順序**
套用兩道前置過濾器：

1. **`/health` 無條件排除** — `cs-uri-stem == "/health"` 之列（精確、大小
   寫區分的欄位比對）在任何 `--test-hosts` 模式下都先於所有計數被丟棄。
   這是業務宇集邊界：樣本資料集中 95.4% 的原始 IIS 流量為健康探測請求，
   代表基礎設施檢查而非業務請求。注意：`/healthz`、`/Health`、及帶有
   query string 的 `/health?...` 不被過濾（query-string 是獨立欄位；僅 stem
   命中）。

2. **測試主機 IP 過濾** — `/health` 丟棄後，對 `c-ip`（欄位 9）套用
   `--test-hosts` 模式，使用 `lib/common.sh` 中的 `TH_FILTER_FUNC` 謂詞：
   - `exclude`（預設） — 丟棄 `c-ip` 位於 `conf/test_hosts.conf` 中的列。
   - `only` — 僅保留 `conf/test_hosts.conf` 中 IP 的列（適合稽核內部
     QA 非健康用戶端流量）。
   - `all` — 不論 IP 為何，保留所有列（等同不套用 IP 過濾）。

**`conf/test_hosts.conf`** — 每行一個 IPv4，可加 `#` 註解。預植 IP：
`192.168.139.79`、`192.168.139.110`、`192.168.139.28`。
`192.168.139.28` 為健康探測主機（IIS 流量 95.4% 為其 `/health` 請求，
已由過濾器 1 排除）。`192.168.139.110` 為 QA 主機（每週 209 筆業務請求）。
注意：`192.168.139.119` 為生產閘道（每週 712 筆業務命中），**不得**加入
此檔案。

此檔案在**所有** `analyze_iis` / `analyze_access` 執行中皆為必要，包括
`--test-hosts all`（此模式不查詢集合，但仍需檔案存在）。若檔案不存在，
以 `die` 中止——與 `regions.conf` 的 fail-fast 行為一致。

**`load_test_hosts`** 與 **`TH_FILTER_FUNC`** 定義於 `lib/common.sh`
（置於 `assert_enum`/`die` 旁）。它們是 `common.sh` 中第一個真正共用
的載入器 / 謂詞。`load_regions` 定義於各 bin，並非共用載入器。

**相依服務健康偵測**（Oracle 中斷）：原本用於偵測 Oracle 相依中斷的
IIS 503-on-`/health` 訊號，已作為業務流量排除政策的一部分被刻意移除。
Oracle 相依失敗仍可完整透過 `analyze_errors`（§3.3）觀測（讀取 .NET 應用
日誌）。未遺失任何可操作訊號——偵測現在僅存在於 errors 模組中。

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

#### 3.3.6 視圖與持久化

`analyze_errors` **無 `--view` 旗標**。Console 永遠顯示詳細視圖。持久
化的 `errors_summary.txt` 存在於執行目錄磁碟中但不可選擇輸出至 stdout
（刻意降低強調：errors 在 `log_report` 中為選配且預設關閉）。

- **`errors_render_summary`**（精簡管理文字）：每區域 / 伺服器之
  `Total ERROR`、`OracleDB health failures`（含佔錯誤總數之百分比）、
  `Restart count`、`Unmatched SHUTDOWN`。
- **`errors_render_detail`**：完整報告——Top 模式、DB 首次失敗時間、
  重啟事件表——與重構前行為相同。

`--format` 接受 `text|tsv|csv`（為旗標轉傳相容性），但僅 `text` 渲染
（非 text 值觸發 `log_warn` 後退為 text；C25）。`errors_summary_*.txt`
與 `errors_detail_*.txt` 均固定寫入。

#### 3.3.7 輸出（detail 視圖）

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
「我要看全部」的單一入口。可選擇執行哪些模組、將適當旗標轉傳給各子
程序，並管理共用的持久化狀態。

#### 3.4.2 模組挑選

`--modules` 接受 `overview,iis,access,errors` 之逗號分隔子集。預設：
`overview,iis,access`（此順序；errors 為**選配 / 預設關閉**）。未知
名稱會以 `die` 中止。模組依所列順序執行。

#### 3.4.3 持久化模型

`log_report.sh` 呼叫 `persist_init "$OPT_OUTPUT_DIR"` **一次**，然後
匯出已解析的目錄與時間戳，讓每個子程序使用相同的值：

```bash
persist_init "$OPT_OUTPUT_DIR"
export LOG_PARSE_RUN_TS="$RUN_TS"
export LOG_PARSE_OUTPUT_DIR="$RUN_BASE_DIR"   # 基底目錄，非子目錄
for m in "${MODULES[@]}"; do run_module "analyze_${m}"; done
```

子程序預設 `OPT_OUTPUT_DIR=""` 並讀取 `$LOG_PARSE_OUTPUT_DIR`（C1）；
`--output-dir` **不**以旗標形式轉傳——環境變數承載已解析的基底目錄。
每個子程序呼叫 `persist_init ""` 時，讀取 `$LOG_PARSE_OUTPUT_DIR` 作為
`RUN_BASE_DIR`、`$LOG_PARSE_RUN_TS` 作為 `RUN_TS`，推導出
`RUN_OUTPUT_DIR = <base>/<RUN_TS>`，不會產生雙重巢狀。
`log_report --output-dir /custom` 執行後，每個子程序的檔案均正確落在
`/custom/<RUN_TS>/`。每個子程序自行持久化其本身的檔案對。`log_report`
本身的 stdout 是每個子程序之所選視圖 console 鏡像的串接。

一次預設執行在單一 `<base>/<RUN_TS>/` 子目錄下產生恰好六個檔案：
`overview_summary.txt`、`iis_summary.txt`、`iis_detail.txt`、
`access_summary.txt`、`access_detail.txt`、`access_ip_counts.tsv`。

#### 3.4.4 預設視圖

`OPT_VIEW="summary"` — 僅轉傳給 `analyze_iis` 與 `analyze_access`。
`analyze_overview` 為僅摘要；`analyze_errors` 無 `--view`。呼叫端可
傳入 `--view detail` 以在 console 鏡像中看到逐筆表格。

#### 3.4.5 參數傳遞

`build_module_args()` 為每個模組建立個別之 `_MOD_ARGS` 陣列，按樣傳給
子程序呼叫。條件式 append 使用 `if ... then ... fi` 而非 `[[ ]] && cmd`，
因為若末段條件為假，後者會讓函式回傳 1，在 `set -e` 下會中止統籌器。

`--output-dir` 刻意**不**以旗標形式轉傳；環境變數承載已解析的目錄
（見 §3.4.3）。

#### 3.4.6 選項轉傳矩陣

| 旗標 | log_report | overview | access | iis | errors | 備註 |
|---|---|---|---|---|---|---|
| `--log-dir` | own | F | F | F | F | 必要 |
| `--region` | own | F | F | F | F | 控制 `--merge` |
| `--today` | own | F | F | F | F | 時間區間選擇器 |
| `--date` / `--from` / `--to` / `--days` | own | F | F | F | F | 時間區間 |
| `--conf` | own（僅明確傳入時驗證） | F | F | F | F | |
| `--output-dir` | own | env | env | env | env | 不以旗標轉傳（C1） |
| `--modules` | own | — | — | — | — | 統籌器專用 |
| `--verbose` | own | F | F | F | F | |
| `--view` | own | — (僅摘要) | F | F | — (無 view) | 預設 summary |
| `--format` | own | — (僅文字) | F | F | 警告+文字 | 僅控制詳細視圖 |
| `--top` | F→{iis,errors} | — | — | 端點+Client IP | 模式計數 | 0=全部 |
| `--slow-api-ms` | F→{overview,iis} | F | — | API 角色伺服器 | — | 預設 2000 ms |
| `--slow-app-ms` | F→{overview,iis} | F | — | APP 角色伺服器 | — | 預設 5000 ms |
| `--merge` | F→{access,iis} | — | 跨區域 | 雙語料桶 | — | 需要 `--region all` |
| `--test-hosts` | F→{overview,iis,access} | F | F | F | **不接受** | `exclude`；errors 無 client IP |

圖例：`own` = log_report 自身處理 · `F` = 轉傳至子模組 ·
`env` = 透過 `LOG_PARSE_OUTPUT_DIR` 環境變數傳遞 · `—` = 不接受。

---

### 3.5 `--output FILE` — 已移除（重大變更）

`--output FILE` 已從**所有** CLI 移除。其用途被常開式目錄持久化模型取
代（與每模組雙檔案 + 多模組設計不相容）。不提供別名。遷移方式：使用
`--output-dir DIR` 並從該目錄存取產生的檔案。

---

## 4. 共通議題

### 4.1 時間區間選擇（互斥，D3）

全部五個 CLI 接受相同的時間區間旗標集合，由 `resolve_interval`（位於
`lib/date_utils.sh`）強制執行：

| 旗標 | 意義 | 備註 |
|---|---|---|
| `--today` | 單日 = 今日日期 | 等同於 `--date $(today)` |
| `--date YYYY-MM-DD` | 指定單日 | |
| `--from D --to D` | 含頭含尾範圍（兩者皆必填） | 計為一個選擇器 |
| `--days N` | 至今日為止之最後 N 天 | 預設隱式回退（N=7） |

**規則：恰好選擇一個明確選擇器。** 提供超過一個者以 `die` 中止。錯誤
訊息引用標準優先順序，告知使用者應保留哪一個：

```
interval flags are mutually exclusive
(priority --date > --from/--to > --today > --days): choose exactly ONE (got N)
```

`--days` 是**唯一的隱式回退**；除非與其他選擇器明確同時提供，否則不
計為衝突。`resolve_interval` 填充全域 `INTERVAL_ARGS[]`，呼叫端按樣
轉傳給 `build_date_list`。

錯誤訊息中的優先順序排名為資訊性說明（指出常見的預期解決方式），但
行為永遠是硬性互斥——工具不會靜默地選擇一個選擇器後繼續執行。這符合
專案規則 #1（「失敗快速、大聲；不靜默壓制」）。

### 4.2 持久化與檔名

每次執行任何分析器模組都會將報告檔案寫入目錄。檔案佈局：
`<base>/<RUN_TS>/<module>_<kind>.<ext>`。

| 元件 | 值 |
|---|---|
| `base` | 已解析之輸出目錄（`--output-dir` \| `$LOG_PARSE_OUTPUT_DIR` \| `./log-parse`） |
| `RUN_TS` | `YYYYMMDD_HHMMSS` — 執行子目錄名稱（每次執行共用之時間戳） |
| `module` | `overview`、`iis`、`access`、`errors` |
| `kind` | `summary`、`detail` 或 `ip_counts`（僅 access） |
| `ext` | 摘要永遠為 `txt`；詳細可為 `txt`、`tsv`、`csv`；ip_counts 為 `tsv` |

**執行目錄規則**：一次頂層呼叫（或一次 `log_report` 執行）產生的所有
檔案均落在單一 `<base>/<RUN_TS>/` 子目錄中。目錄名稱即為執行時間戳；
各檔案名稱不再含時間戳後綴。`log_report` 呼叫 `persist_init` 一次並匯出
`LOG_PARSE_RUN_TS`，讓每個子程序讀取相同時間戳並自行推導同一子目錄，
不產生雙重巢狀。

**已核可全域變數**（由 `persist_init` 設定，其他地方唯讀）：
`RUN_BASE_DIR` — 已解析基底目錄；`RUN_TS` — 啟動時間戳；
`RUN_OUTPUT_DIR = RUN_BASE_DIR/RUN_TS` — 本次執行之實體目錄。

**目錄優先順序**（C1）：
1. `--output-dir DIR` 旗標（最高）
2. `$LOG_PARSE_OUTPUT_DIR` 環境變數
3. `./log-parse`（預設，不存在則自動建立）

所有 CLI 預設 `OPT_OUTPUT_DIR=""`。`./log-parse` 字串常值**僅存在**於
`persist_init`；這確保旗標 > 環境變數優先序在 `log_report` 衍生子程序
時確實成立。

**無色碼保證**（C3）：所有持久化檔案均以 `NO_COLOR=1` +
`fmt_set_color_state` 寫入，使檔案寫入時 `C_*` 全域為空。Console 鏡像在
還原原始色碼狀態後重新渲染。任何持久化檔案中均不含 ANSI ESC 位元組
（`0x1b`）。

**Overview** 僅在執行目錄下寫入摘要檔（`overview_summary.txt`）；
不產生詳細檔案。

**`--emit-stats`** 模式**不寫入任何檔案**；它在 `persist_init` 之前
提前返回。

### 4.3 日期處理

由 `lib/date_utils.sh::build_date_list` 一處供應日期範圍產生。
`resolve_interval` 是時間區間旗標驗證的單一事實來源（見 §4.1）。

所有日期皆以 `date -d` 驗證；不合法格式直接 `die` 中止。

### 4.4 日誌

`lib/common.sh` 提供 `log_debug` / `log_info` / `log_warn` / `log_error`，
遵守 `LOG_LEVEL`。所有 log 走 **stderr**，使報告本身可被安全管線到檔
案或工具。色碼由 `fmt_set_color_state` 控制（當 stdout 非 TTY 或設定
`NO_COLOR=1` 時自動關閉）。

### 4.5 暫存檔管理

`init_tmpdir` 建立 `${TMPDIR:-/tmp}/log_analyze.XXXXXX`，並安裝
`EXIT INT TERM` 之清除 trap。所有中介檔案（每台伺服器合併日誌、區域
聯結輸入、重啟事件 TSV、`iis_stats.tsv`、`access_stats.tsv`）皆位於
此目錄。

### 4.6 錯誤處理

- 每個可執行腳本一律 `set -euo pipefail`。
- 必要參數先驗證；缺少 `--log-dir` 即中止。
- 缺少之每台伺服器子目錄降級為 `log_warn`（單台跳過）而非致命，避免
  某區異常阻擋另一區之分析。
- 空資料以 `無資料` / `No data` 呈現，但不視為錯誤。

### 4.7 效能特徵

- 磁碟 I/O 是主要成本。雙輪 awk 聯結在常見硬體約 100k 列／秒。
- 記憶體上限由**唯一 Token 數量**決定，而非列數（API hash 大小）。
  雙區單日約落在數千 token 量級。
- 統籌器目前以序列方式跑模組。要平行化需為每個子程序自備
  `WORK_TMPDIR`，目前規模尚不需要。
- `analyze_overview.sh` 衍生兩個子程序重新讀取日誌（一個 IIS、一個
  access）。此二次讀取為程序隔離的可接受代價；綁定的 DRY 要求是單一
  來源計算（`lib/aggregate_utils.sh`），而非單次讀取 I/O。`--agg-cache`
  交接明確列為超出範圍。

### 4.8 CJK 感知版面渲染

KV 與統計區塊以顯示寬度（wcwidth；CJK 全形字 = 2 欄）對齊，由 `lib/fmt_utils.sh` 中的 `FMT_AWK_WIDTH` 引擎統一處理，CJK 與 ASCII 標籤在終端機中正確對齊。

---

## 5. 能力矩陣

| 旗標 / 功能 | analyze_overview | analyze_access | analyze_iis | analyze_errors | log_report | 預設 |
|---|---|---|---|---|---|---|
| `--log-dir` | 必要 | 必要 | 必要 | 必要 | 必要 | — |
| `--region` | 是 | 是 | 是 | 是 | 是 | `all` |
| `--today` | 是 | 是 | 是 | 是 | 是 | 關閉 |
| `--date` | 是 | 是 | 是 | 是 | 是 | `""` |
| `--from`/`--to` | 是 | 是 | 是 | 是 | 是 | `""` |
| `--days` | 是 | 是 | 是 | 是 | 是 | `7` |
| `--view summary\|detail` | — (僅摘要) | 是 | 是 | — (僅詳細) | 是 (轉傳→iis,access) | standalone=`detail`；log_report=`summary` |
| `--format text\|tsv\|csv` | — (僅文字) | 是 | 是（真實） | 警告+文字 | 是 (轉傳) | `text` |
| `--top N` | — | — | 是 | 是 | 轉傳→iis,errors | `10` |
| `--slow-api-ms` | 是 | — | 是 | — | 轉傳→overview,iis | `2000` |
| `--slow-app-ms` | 是 | — | 是 | — | 轉傳→overview,iis | `5000` |
| `--merge` | — | 是 | 是 | — | 轉傳→access,iis | 關閉 |
| `--test-hosts` | 是 | 是 | 是 | **不接受** | 轉傳→overview,iis,access | `exclude` |
| `--output-dir` | 是 | 是 | 是 | 是 | 是 | `""` → `./log-parse` |
| `--emit-stats` | — | 是 | 是 | — | — | 關閉 |
| `--modules` | — | — | — | — | 是 | `overview,iis,access` |
| `--conf` | 是 | 是 | 是 | 是 | 是 | `conf/regions.conf` |
| `-v`/`--verbose`, `-h` | 是 | 是 | 是 | 是 | 是 | 關閉 |
| `--output FILE` | 已移除 | 已移除 | 已移除 | 已移除 | 已移除 | n/a |

`analyze_iis` 上的 `--format` 現為**真實有效**（控制詳細檔案/視圖）；
此前為 no-op + 警告。摘要不論 `--format` 為何永遠輸出文字（C10）。

---

## 6. 擴充

### 6.1 新增區域
在 `conf/regions.conf` 多加一列即可，無需改 code。新區域會自動出現
於所有報告中。

### 6.2 新增分析器
1. 依照現有 `parse_args` / `load_regions` / `main` 骨架建立
   `bin/analyze_<name>.sh`。Source `lib/output_utils.sh`，並在 `main`
   結束時呼叫 `persist_views`。
2. 把 `<name>` 加進 `bin/log_report.sh` 的 `valid_modules` 陣列。
3. 在本文件與 `usage.zh-TW.md` 模組表新增一列。
4. 在 `tests/run_tests.sh` 補上新區段。

### 6.3 修改 Access CSV 欄位
更新 `lib/csv_utils.sh` 內 `extract_api_records` / `extract_app_records`
之欄位索引，並同步更新 §3.1.2 之欄位表。執行測試套件確認基準仍成立
（若需要可有意更新基準）。

---

## 7. 已知限制

- IIS 時間戳為 UTC+0；`analyze_iis` 與 `analyze_overview` 透過半開放
  UTC 視窗過濾器（`lib/date_utils.sh` 中的 `iis_utc_window`）修正為
  UTC+8 業務時間。存取與 .NET 應用程式日誌原生為 UTC+8，不做調整。
  `analyze_errors` 直接讀取 .NET 應用程式日誌（UTC+8），不套用時區修正。
- 錯誤模式分組為啟發式作法，會把僅以數值 / 時間差異區分之訊息群組
  化；對大多數情境正確，但對僅以字串狀態區分之錯誤族群會喪失辨識度。
- 重啟事件配對假設事件按時間序到達；若日誌跨日輪替於事件中段，可能
  出現假性 `UNMATCHED`。
- 僅支援 Linux/WSL；macOS 需建立 `gdate` 別名為 `date`。
- 每次執行都會在輸出目錄寫入檔案。使用 `--output-dir` 或
  `LOG_PARSE_OUTPUT_DIR` 控制放置位置；將 `/log-parse/` 加入 `.gitignore`
  以避免提交預設目錄的輸出。
- `analyze_errors` 摘要持久化於磁碟但不可選擇輸出至 console（errors 無
  `--view` 旗標）。如需對 errors 提供完整視圖同等功能，為加法性變更。
