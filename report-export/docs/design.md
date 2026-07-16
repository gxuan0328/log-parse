# report-export — 設計規格（Design Specification, zh-TW）

> 版本 1.0.0 · 已實作，391 測試全綠，coverage gate `fail_under=80`（實測
> 100%）。技術名詞、程式識別字、sheet 名稱一律保留原文（不譯
> awk/gawk/stdout/openpyxl/Docker/flock/csv 等）。
>
> 本文件描述 `report-export` **目前實際的**系統設計；全部數值錨點已對
> `report-export/template/連線紀錄模板.xlsx`（2.3MB、5 sheets）與
> `report-export/template/source-log.csv`（25 資料列）逐一實測驗證，並
> 對照 `src/report_export/` 原始碼確認一致。CLI 使用方式見
> [`usage.md`](usage.md)；逐欄型別/格式契約見
> [`data-fidelity.md`](data-fidelity.md)；快速上手見
> [`../README.md`](../README.md)。

---

## 1. 系統概觀

### 1.1 定位與範圍

`report-export` 是一個**可選、獨立、非整合**的自動化子工具，位於
`log-parse/report-export/` 之下，取代原本手動每週 Excel「連線紀錄」工作
流程。它**不**與既有 `log-parse` 的 bash/gawk CLI 共用程式碼、**不**改動
`bin/`、`lib/`、`conf/`；是一支一次性批次程式（非常駐、非服務、非資料
庫）。全部程式碼、測試、文件均位於 `report-export/` 之下。

本規格涵蓋：系統概觀與目標（§1）、架構（§2）、模組規格（§3：資料模型、
讀取轉換、查表、去重、狀態持久化、聚合、xlsx 產生、管線階段、CLI 契
約）、橫切關注（§4：冪等性、錯誤處理、日誌、並行、效能、安全、Docker、
資料保真）、能力矩陣（§5）、邊界案例（§6）、測試策略（§7）、已知限制與
風險（§8）。

### 1.2 取代的手動流程與模板語意

模板 `連線紀錄模板.xlsx` 以 Excel 365 動態陣列公式串起 5 張 sheet：

1. `紀錄匯入`（貼上區，14 欄，無公式）— 貼上 analyze_access `--format csv` 輸出。
2. `格式轉換`（自動）— `FILTER(紀錄匯入, STATUS=="NORMAL")`，投影為 9 欄，其中 HOSP_ABBR 以 `XLOOKUP(HOSP_ID, HOSP_ID對照表)` 補齊。
3. `HOSP_ID對照表`（靜態 93,781 列參照，占檔案主要體積）。
4. `調閱紀錄`（持久累積）— 每週把 NORMAL 列附加於此，DATE/TIME 存為 Excel datetime 序列。
5. `院所分析`（報表）— 對 `調閱紀錄` 的 CLIENT IP 做 `UNIQUE`，逐一 `XLOOKUP`（對調閱紀錄自身 first-match）補 HOSP_ID/HOSP_ABBR，並 `COUNTIF` 計數。

### 1.3 設計目標

- **正確性優先**：完整重現模板的過濾、投影、查表、聚合語意（見 §1.5、§3.1 實測基準）。
- **資料保真**：前導零全程 TEXT、DATE/TIME 同存一個 datetime 兩種 number_format、僅 NORMAL、per-IP WEEKLY ACCESS + TOTAL ACCESS（最新批次列數／全 state 列數；本週無存取之院所 WEEKLY 填 `-`）、**最新批次黃底**（最新批次高亮、歷史批次無底；每次執行由完整 state 重建 → per-run 重置語意）。兩張交付 sheet 全表儲存格置中（horizontal/vertical center）、資料列四面細框線、表頭粗下框線（+細左右上框線構成連續格線）、欄寬依現有資料＋表頭字串顯示寬度自動 ×1.2（每次執行動態計算，非硬編常數）。
- **可重複／冪等**：state 為單一真實來源；相同輸入重跑不重複追加、不破壞 state、產生等價交付檔。
- **營運簡單**：單一 batch CLI、安全預設、無守護程序/DB；主機零安裝（依賴全入 Docker 映像）；精瘦 CLI（僅必要旗標）。
- **精瘦 + 專案 ethos**：stdlib 為主僅引入 openpyxl；fail-fast loud、顯式型別、結構化日誌至 stderr、結果至 stdout/檔案。

### 1.4 執行環境

Python 3.12.12、openpyxl 3.1.5、Docker 可用；openpyxl 純 Python（相依 et_xmlfile、無 C 擴充）。

### 1.5 保真基準錨點

本節為後續設計的錨點。所有數值均以 openpyxl 3.1.5 直接讀取模板核對；
`source-log.csv` 以逐位元組檢視核對。

#### 1.5.1 列數流（e2e 不變量）

25 輸入列（NORMAL 19 / ORPHAN 1 / UNVERIFIED 5）→ `調閱紀錄` **19** 列 → `院所分析` **11** 個唯一 CLIENT IP。

#### 1.5.2 院所分析（實測，首見序）

| # | CLIENT IP | HOSP_ID | HOSP_ABBR | COUNT |
|---|-----------|---------|-----------|-------|
| 1 | 10.243.129.44 | 1145010038 | 門諾醫院 | 1 |
| 2 | 10.249.8.10 | 1101150011 | 新光醫院 | 1 |
| 3 | 10.249.10.249 | 1301170017 | 台北醫大 | 1 |
| 4 | 10.238.3.1 | 1532061065 | 大園敏盛 | 1 |
| 5 | 10.241.189.173 | 3831014971 | 晨軒中醫 | 1 |
| 6 | 10.241.93.164 | 1111060015 | 基隆長庚 | 1 |
| 7 | 192.168.117.104 | 3501200000 | 臺北虛擬診 | **3** |
| 8 | 10.251.166.61 | 3505070032 | 誼仁診所 | 1 |
| 9 | 10.245.1.125 | 0937010019 | 秀傳醫院 | **7** |
| 10 | 10.245.11.141 | 1137080017 | 彰基二林醫 | 1 |
| 11 | 10.238.23.241 | 1503190020 | 長安醫院 | 1 |

COUNT = `[1,1,1,1,1,1,3,1,7,1,1]`，合計 **19**。`10.243.129.44` COUNT=1 證明 ORPHAN（row7，共用同一 IP）被排除；若誤含則變 2。

> 院所分析將模板單一 COUNT 欄拆為兩欄：`TOTAL ACCESS`（= 全 state 該 IP
> 列數，即上表數值本身）與 `WEEKLY ACCESS`（= 最新批次該 IP 列數）。
> E2E-1 為單一批次（全 19 列 BATCH_ID=1）首次執行，故 WEEKLY == TOTAL ==
> 上表數值、**無** `-` 出現；多批次情境（WEEKLY 只計最新批次、older-only
> IP WEEKLY 顯示 `-`）見 §7.2 E2E-3/E2E-7。

#### 1.5.3 聚合語意（實測公式）

- A：`=UNIQUE(FILTER(調閱紀錄!C2:C…, 調閱紀錄!C2:C…<>""))`
- B：`=IFERROR(XLOOKUP(ANCHORARRAY(A2), 調閱紀錄!$C:$C, 調閱紀錄!$E:$E, ""), "")`
- C：`=IFERROR(XLOOKUP(ANCHORARRAY(A2), 調閱紀錄!$C:$C, 調閱紀錄!$F:$F, ""), "")`
- D：`=COUNTIF(調閱紀錄!$C:$C, ANCHORARRAY(A2))`（模板原始語意；本工具將此拆為 §3.1 之 WEEKLY/TOTAL 兩欄——`TOTAL = COUNTIF(全部)`、`WEEKLY = COUNTIFS(該 IP AND BATCH_ID==max(BATCH_ID))`；模板本身無此拆分，為本工具在模板語意之上的增強）

**關鍵**：院所分析的 HOSP_ID/HOSP_ABBR 是對「調閱紀錄自身」以 CLIENT IP 做 XLOOKUP **first-match**（取該 IP 首見列之值），**不是**再查 93k 主檔。主檔 XLOOKUP 只發生在 `格式轉換` 的 F 欄（`XLOOKUP(E2, HOSP_ID對照表!$A:$A, $B:$B, "")`）與 A/B 欄 `FILTER(…, 紀錄匯入!$B$2:$B$100000="NORMAL", "")`。

#### 1.5.4 型別與 number_format（實測）

`調閱紀錄`（= 交付來源）逐欄實測：

| 欄 | 標題 | 值型別 | number_format（模板 調閱紀錄 實測） |
|----|------|--------|-------------------------------------|
| A | DATE | `d` datetime | `yyyy\-mm\-dd;@` |
| B | TIME | `d` datetime（與 A 同值） | `h:mm:ss;@` |
| C | CLIENT IP | `s` | `General` |
| D | SERVER IP | `s` | `General` |
| E | HOSP_ID | `s` | `@` |
| F | HOSP_ABBR | `s` | `General` |
| G | PRSN_ID | `s` | `General` |
| H | BIRTHDAY | `s`（字串 "19560711"） | `General` |
| I | PATIENT ID AES | `s` | `General` |

**注意**：`格式轉換` sheet 的 C–I 才全部是 `@`；`調閱紀錄` sheet 僅
E=`@`，其餘文字欄為 `General`，靠**值為字串型別（type='s'）**避免數值
化。本工具刻意對全部文字欄寫 `@`（主動硬化），比模板更穩健（見
§3.7）。

#### 1.5.5 填色（實測）

`調閱紀錄` 表頭 A1 為 solid、theme=9、tint≈0.7999816…（淺綠）；資料列
A2 `fill_type=None`（無填色）——theme9/tint0.8 solid fill 屬**表頭**，
模板既有 19 列示範資料**無填色**。讀 theme 色之 `fgColor.rgb` 會拋
`Values must be of type str`（已實測確認）；故 §3.7 一律用顯式 RGB。

#### 1.5.6 輸入精度與換行（實測）

- `source-log.csv` 為**完整精度**（`2026-07-05 16:03:34.359`），**非** mm:ss.d 失真版 → 可直接作 e2e 輸入 fixture；輸入契約即完整精度 analyze_access 輸出。此檔（25 列、**CRLF、無 BOM、末列無換行**）為入庫基線之一（見 §4.7.7）。
- `source-log.csv` 行尾為 **CRLF（\r\n）、無 BOM**（首 8 bytes = `REGION,S`）。故讀檔須 `newline=''`（見 §3.2、§3.8 S3）。

#### 1.5.7 BIRTHDAY 型別

`紀錄匯入` N 欄（BIRTHDAY）以 **int 儲存**（type='n'，值如 19560711），且 19 列全為 19xx，**永不以 0 開頭**。故 BIRTHDAY 需 TEXT 的真正理由是「**避免被當數字/日期強制轉型**、對齊模板 `調閱紀錄` H 的文字輸出」，**不是**「前導零顯著」。前導零顯著僅適用於 HOSP_ID（531 個前導零鍵、代表值 0937010019）。

#### 1.5.8 HOSP_ID對照表（實測）

93,781 列（+1 表頭 = 93,782）、鍵長全為 10、531 前導零、**0 重複鍵、0 空白簡稱**；表頭 `(HOSP_ID, HOSP_ABBR)`。openpyxl 一次性讀取數秒 → **絕不**作為執行期查表來源（見 §3.3）。

#### 1.5.9 openpyxl round-trip 行為（測試斷言依據）

- `"0937010019"`／`"19560711"` 維持 type='s'、前導零保留。
- 同一 `datetime` 物件寫入 A、B 兩格、兩種 number_format 可完整還原（A2==B2）。
- WEEKLY/TOTAL int 寫入為 type='n'；WEEKLY 為本週無存取（`weekly_access==0`）時寫 `-`（str，type='s'，number_format `@`）。
- 寫入空字串 `""` 的 HOSP_ABBR **回讀為 `None`**（openpyxl 正規化）→ 測試須斷言「空或 None」，不可嚴格斷言 `""`。
- 6 碼填色 `'FFFF00'` 會被存為 `00FFFF00`（alpha=00）→ 一律用 8 碼 `FFFFFF00`。

---

## 2. 架構

### 2.1 設計取向

採**單向資料流管線 + 純函式核心 + I/O 邊界隔離**。核心轉換無副作用；
唯一具狀態元件為 `state`；I/O（CSV/xlsx/state/lock/reference）集中於
邊界模組，利於單元測試、確定性重放與冪等。

```
INPUT CSV ─▶ csv_reader ─▶ transform(filter NORMAL→parse APP_TIME→project 9) ─▶ lookup(HOSP_ABBR 凍結)
                                                                                        │
  state.load(空或既有 + 尾列完整性驗證/crash-tolerant) ─▶ dedup(REQUEST_ID 跨狀態/批次內) ◀──┘
                                              │ new_records（配 BATCH_ID = max_seq+1）
                                              ▼
                aggregate(full state → 院所分析)
                                              │
    xlsx_writer → deliverable.tmp(fsync, 最新批次黃底) ─▶ state.commit(records.csv.tmp→fsync→.bak→os.replace, 含 #META 尾列)
                                              │                          │
                                              └▶ os.replace(deliverable) ─┴▶ append runs.jsonl ─▶ cli: stdout JSON 摘要
```

### 2.2 語言／執行期選型

純 Python 3.12 + openpyxl，封裝為 Docker 映像；分析以 stdlib（`csv`,
`datetime`, `argparse`, `logging`, `pathlib`, `tempfile`, `os`, `json`,
`gzip`, `hashlib`, `fcntl`, `errno`）完成。

- **採 openpyxl（justify）**：交付需寫「datetime 序列 + number_format + 純文字型別 + 黃底 + 表頭樣式」的 OOXML；stdlib 無法可靠產生，手刻 zipfile+XML 脆弱且違反 fail-fast。openpyxl 為純 Python（僅相依 et_xmlfile、無 C 擴充/lxml 硬依賴），且同時可讀（dev 匯出主檔、測試讀回產出皆需要）→ 單一相依覆蓋讀寫。
- **拒絕 pandas/numpy**：本量級（每週數十至低千列）不需要；numpy 使映像 +~50MB；pandas 的 dtype 推斷正是造成前導零數值化（本工具要根除的 bug 類別）的來源。**stdlib csv 全讀為 str → 前導零天生保留**，是本工具相對手動流程的核心優勢。不採 xlsxwriter（write-only，測試/匯出仍需讀能力）。

### 2.3 模組分解

模組（`src/report_export/`，職責單一）：

| 模組 | 職責 | 依賴 |
|------|------|------|
| `__main__.py` | `python -m report_export` → `cli.main()` | cli |
| `cli.py` | argparse（精瘦：位置 INPUT + --state-dir/--out-dir）、退出碼、stdout JSON 摘要 | pipeline, config, logging_setup |
| `config.py` | `@dataclass(frozen=True) Config`；路徑正規化/校驗（防 CWE-22）、內建預設 | errors |
| `errors.py` | 型別化例外：`UsageError`/`InputValidationError`/`StateIntegrityError`/`LockBusyError`/`WriteError`/`ReferenceError` | — |
| `logging_setup.py` | 結構化日誌至 **stderr**（key=val 或 JSON、TTY/NO_COLOR 感知），INFO 預設、無遮罩 | — |
| `models.py` | `InputRow`(14)、`StateRecord`(BATCH_ID+REQUEST_ID+8 payload)、`ReportRow`(5)、`Status`(Enum) | — |
| `csv_reader.py` | 讀/驗 14 欄 CSV（`newline=''`、utf-8-sig、標題精確比對、嚴格欄數、dash 正規化） | models, errors |
| `transform.py` | 過濾 NORMAL（大小寫不敏感）→ 解析 APP_TIME → 投影 9 欄（純函式） | models, errors |
| `lookup.py` | 載入 `hosp_id_map.csv.gz`→`dict[str,str]`；`get(hosp_id, "")`（IFERROR 語意） | errors |
| `dedup.py` | REQUEST_ID 跨狀態 + 批次內去重；warn-skip（內建唯一策略） | models, errors |
| `statelock.py` | 檔案鎖抽象：flock 優先，O_CREAT\|O_EXCL 備援 + stale 偵測（見 §4.4） | errors |
| `state.py` | canonical state 讀寫、原子寫、**in-file 完整性尾列**、crash-tolerant 復原、`.bak`、`runs.jsonl`、BATCH_ID 配號 | models, errors, transform, lookup, statelock |
| `aggregate.py` | 由完整 state 重算院所分析（首見序、first-HOSP、WEEKLY=最新批次列數/TOTAL=全 state 列數） | models |
| `xlsx_writer.py` | 建 2-sheet 純值工作簿：TEXT/datetime 型別、number_format、**最新批次黃底**、表頭樣式、檔名、全表置中+資料細框線+表頭粗下框線+自動欄寬 | openpyxl, models |
| `pipeline.py` | 串接各階段、回傳 `RunSummary`（接受內部 `run_date` 參數供測試注入） | 全部 |

### 2.4 專案 ethos 對應

fail-fast loud（型別化例外、無 `except: pass`、邊界即拋）｜顯式型別
（frozen dataclass + type hints、mypy --strict）｜stdout=結果、
stderr=結構化日誌｜確定性可重放（**內部 `run_date` 參數供測試注入**、
state 存原始 app_time 字串避免浮點漂移、`PYTHONHASHSEED=0`）｜最小依賴
（僅 openpyxl）｜文件化。

---

## 3. 模組規格

### 3.1 資料模型

#### 3.1.1 輸入（analyze_access `--format csv`，14 欄；CSV 全部以 str 讀入）

| # | 欄名 | 型別/格式 | 輸出用途 |
|---|------|-----------|----------|
| A | REGION | TEXT（如 台北/台中） | 不使用 |
| B | STATUS | TEXT enum：NORMAL / ORPHAN / UNVERIFIED | **過濾鍵（僅 NORMAL；大小寫不敏感）** |
| C | API_TIME | `YYYY-MM-DD HH:MM:SS.mmm` 或 `-` | 不使用 |
| D | APP_TIME | `YYYY-MM-DD HH:MM:SS.mmm`（NORMAL 必有；非 NORMAL 可為 `-`） | **DATE 與 TIME 皆源自此欄** |
| E | DELTA_SEC | NUMERIC(decimal) 或 `-` | 不使用（僅驗證） |
| F | VERIFY_STATUS | TEXT（OK / `-`） | 不使用 |
| G | REQUEST_ID | TEXT UUID(36) | **去重自然鍵（內部；不進交付欄）** |
| H | API_SERVER | TEXT IP 或 `-` | 不使用 |
| I | APP_SERVER | TEXT IP | → SERVER IP |
| J | HOSP_ID | **TEXT 前導零** 如 `0937010019`（長度全為 10） | → HOSP_ID + 主檔查表 |
| K | PRSN_ID | TEXT hex32 | → PRSN_ID |
| L | CLIENT_IP | TEXT IP | → CLIENT IP（聚合鍵） |
| M | PATIENT_ID_AES | TEXT hex32（加密） | → PATIENT ID AES |
| N | BIRTHDAY | **TEXT** `YYYYMMDD`(8) 如 `19560711` | → BIRTHDAY |

> 驗證：25 列 STATUS = NORMAL 19 / ORPHAN 1 / UNVERIFIED 5；25 列 REQUEST_ID 全唯一。dash（`-`）APP_TIME 僅出現於非 NORMAL 列 → **先過濾 NORMAL 再解析 APP_TIME** 可避開全部 dash 解析錯誤。
>
> **TEXT 理由分類（資料保真）**：HOSP_ID = 前導零顯著（531 鍵）。PRSN_ID / PATIENT_ID_AES = hex32，可含前導零 hex 位、須 TEXT。BIRTHDAY = **防數值/日期強制轉型**（YYYYMMDD 永為 19xx/20xx、無前導零；模板 紀錄匯入 N 為 int），對齊模板 調閱紀錄 之字串輸出。CLIENT_IP / REQUEST_ID 含點/破折號、本質非數值，仍以 TEXT 儲存。

#### 3.1.2 調閱紀錄輸出（9 欄，交付 sheet 1；表頭精確字面 A1:I1）

| 欄 | 標題(精確) | 來源 | 交付值型別 | 模板 調閱紀錄 實測 numFmt | 工具寫入 numFmt（設計/硬化） |
|----|-----------|------|-----------|---------------------------|------------------------------|
| A | `DATE` | APP_TIME(D) | datetime（含 microsecond） | `yyyy\-mm\-dd;@` | `yyyy\-mm\-dd;@` |
| B | `TIME` | APP_TIME(D) **同一值** | datetime（與 A 同值） | `h:mm:ss;@` | `h:mm:ss;@` |
| C | `CLIENT IP` | CLIENT_IP(L) | TEXT(type='s') | `General` | `@` |
| D | `SERVER IP` | APP_SERVER(I) | TEXT | `General` | `@` |
| E | `HOSP_ID` | HOSP_ID(J) | TEXT | `@` | `@` |
| F | `HOSP_ABBR` | 主檔查表(HOSP_ID)；未命中→`""` | TEXT | `General` | `@` |
| G | `PRSN_ID` | PRSN_ID(K) | TEXT | `General` | `@` |
| H | `BIRTHDAY` | BIRTHDAY(N) | TEXT | `General` | `@` |
| I | `PATIENT ID AES` | PATIENT_ID_AES(M) | TEXT | `General` | `@` |

> **模板 vs 工具寫入**：模板僅 E=`@`、DATE/TIME 為日期/時間格式、其餘為 `General`（靠 type='s' 字串保存文字）；「全 `@`」屬 `格式轉換` sheet。本工具刻意對全部文字欄寫 `@` 為主動硬化——即使某環境重算或另存，字串欄仍鎖定文字語意，不數值化。
>
> **核心保真**：A、B 同存一個完整 `datetime`（含毫秒，如 `datetime(2026,7,5,16,3,34,359000)`），差異僅 number_format。必須指派 `datetime.datetime` 物件（非 `date`）才能保留亞秒序列。C–I 以 Python `str` 指派（openpyxl 寫 type='s'）+ number_format `@` 雙保險。

#### 3.1.3 院所分析輸出（5 欄，交付 sheet 2；表頭 A1:E1）

| 欄 | 標題 | 計算（對映模板公式語意） | 型別 |
|----|------|--------------------------|------|
| A | `CLIENT IP` | 完整 state 的 CLIENT IP **首見順序去重**（= `UNIQUE(FILTER(...))`） | TEXT |
| B | `HOSP_ID` | 該 IP **首見 state 列**的 HOSP_ID（= `XLOOKUP(IP, 調閱紀錄!C:C, E:E)` first-match，**取自調閱紀錄自身**） | TEXT |
| C | `HOSP_ABBR` | 該 IP 首見 state 列的 HOSP_ABBR（= `XLOOKUP(..., F:F)`；可為 `""`） | TEXT |
| D | `WEEKLY ACCESS` | 該 CLIENT IP 於**最新批次**（`batch_id == max(BATCH_ID)`）之列數；0 → render `-`，否則 int | NUMERIC(int) 或 `-`（render） |
| E | `TOTAL ACCESS` | 完整 state 中該 CLIENT IP 之列數（= 舊 COUNT = `COUNTIF(調閱紀錄!C:C, IP)`） | NUMERIC(int) |

模板本身只有單一 COUNT 欄（= 本表 E TOTAL ACCESS）；D WEEKLY ACCESS 是
本工具在模板語意之上的增強，模板無對應公式（見 §1.5.3）。落地錨點見
§1.5.2；WEEKLY/TOTAL 分離之多批次錨點見 §7.2 E2E-3、E2E-7。

### 3.2 讀取與轉換（`csv_reader.py` + `transform.py`）

`csv_reader.py`：`open(path, newline='', encoding='utf-8-sig')`（**CRLF
輸入必須 `newline=''`，最後一欄不得殘留 `\r`**；utf-8-sig 容忍可能的
BOM，實測輸入無 BOM）；標題精確比對 14 欄名與順序（不符→
`InputValidationError` exit 2，列出期望 vs 實得）；逐列嚴格 14 欄（欄
數不符→帶行號拋出）；STATUS 值 `.strip().upper()` 後若非三種已知 enum
（NORMAL/ORPHAN/UNVERIFIED）→ WARN + skip + 計數
（`unknown_status_skipped`）；dash（`-`）正規化為 sentinel。此階段
**不**解析 datetime，產生 `InputRow` 串流。

`transform.py`：`filter_normal()` 以 `status.strip().upper() ==
"NORMAL"` 判定（**對齊 Excel `=` 之大小寫不敏感語意**，`Normal`/
`normal`/`NORMAL` 皆納入）；記錄丟棄之 ORPHAN/UNVERIFIED 數（INFO，
`dropped_nonnormal`）。過濾後才解析每 NORMAL 列 APP_TIME：
`%Y-%m-%d %H:%M:%S.%f`（相容無毫秒 `%Y-%m-%d %H:%M:%S`）。NORMAL 列若
APP_TIME 為 `-`/不可解析，或 APP_SERVER/CLIENT_IP/REQUEST_ID 缺失 →
資料契約違反 → `InputValidationError`（exit 2；只報行號+欄名，不回顯
欄值；空/缺 REQUEST_ID 同樣視為違規，不以合成鍵掩蓋，見 §3.4.4）。
`project()` 建 9 欄 payload；`app_time_iso` 存**完整字串**（DATE/TIME
唯一來源）；`hosp_abbr = lookup.get(hosp_id, "")`（IFERROR 語意；**於
ingest 當下解析並凍結入 state**，歷史列不因日後主檔變動而改寫）；累計
`unmapped_hosp_ids` 供摘要 WARN。

逐欄型別/格式契約見 [`data-fidelity.md`](data-fidelity.md) §2。

### 3.3 參考查表（`lookup.py`）

**落地事實**：模板 HOSP_ID對照表：93,781 筆、鍵長全為 10、531 前導
零、0 重複鍵、0 空白簡稱。**絕不**在執行期用 2.3MB xlsx 查表。

**捆綁形式**（runtime；自由入映像與入庫）：`reference/hosp_id_map.csv.gz`
（2 欄 `HOSP_ID,HOSP_ABBR`、UTF-8、QUOTE_MINIMAL、全 TEXT、前導零原
樣；估 gzip 後 ~0.4–0.8MB）。`lookup.load()` 以 `gzip.open` +
`csv.reader` 讀入 `dict[str,str]`（全 str → 前導零保留；<0.1s、記憶體
<20MB）。查詢 `dict.get(hosp_id, "")` 實現 IFERROR/XLOOKUP-not-found
語意。此檔為醫院代碼對照、可自由捆綁進映像並入庫。

**一次性匯出工具**（dev/ops，不進 runtime 映像）：
`tools/export_hosp_table.py`：讀模板 `HOSP_ID對照表`（openpyxl
read_only）→ 寫 `hosp_id_map.csv.gz`（全欄轉 str）→ 產
`hosp_id_map.manifest.json`（`{source, exported_utc, row_count, sha256,
key_len_hist, dup_keys, blank_abbr, tool_version}`）→ **fail-loud 驗證
器**：斷言 `row_count==93781`、`dup_keys==0`、`blank_abbr==0`、
`key_len_hist=={10:93781}`、`leading_zero==531`，違反則非零退出。

**更新程序**（主檔演進）：1. 取得新版主檔。2. 跑
`export_hosp_table.py` 重生 `hosp_id_map.csv.gz` + `manifest.json`。
3. 檢視 manifest 差異（列數、sha256）。4. 提交入庫。5. 重建 Docker 映
像（bump tag 與 `hosp-data-version` label）。**更新路徑即重建映像**
（無執行期熱修覆寫；主檔更新頻率低，rebuild-redeploy 為標準做法）。
執行期對未命中 HOSP_ID 累計 WARN（stale 主檔的可觀測訊號）。

**入庫基線與版控界線**：見 §4.7.7。

### 3.4 去重（`dedup.py`；自然鍵 = REQUEST_ID）

#### 3.4.1 為何用 REQUEST_ID

落地驗證：source-log 25 列 REQUEST_ID 全唯一，標準 UUID(36) 不透明鍵
（如 `40000930-0002-7a00-b63f-84710c7967bb`），天然去重鍵。**交付欄約
束**：交付「調閱紀錄」9 欄**不含 REQUEST_ID**（模板 sheet 結構如
此）；state 層把 REQUEST_ID 當**內部隱藏鍵**保留（records.csv 第 2
欄），交付投影時剔除。

#### 3.4.2 演算法（`dedup.apply(new_rows, existing_request_ids)`）

1. 由 state 建 `existing_request_ids: set[str]`。
2. 逐一處理本批（已過 NORMAL 過濾+投影）列，維護 `seen_in_batch: set`：
   - **批次內重複** → WARN（記 REQUEST_ID + 行號）→ skip、`skipped_intra++`。
   - **跨 state 重複** → WARN（記 REQUEST_ID + 行號）→ skip、`skipped_cross++`。
   - 否則 → 收為 `new_record`，加入 `seen_in_batch`。
3. 回傳 `(new_records, skipped_intra, skipped_cross)`；計數進 stdout 摘要與 runs.jsonl。

#### 3.4.3 策略

去重一律 `warn-skip`（fail-loud WARN 至 stderr + SKIP）。重複屬「重
跑/重匯」的**預期情形**而非錯誤 → 退出碼維持 0（摘要註記 skipped
數）；嚴格 CI 場景可改為斷言摘要之 `skipped_*` 計數。

#### 3.4.4 邊界與非鍵衝突

- REQUEST_ID 假設跨週全域唯一且穩定；若上游回收/改寫 ID → 去重可能過度/不足 → 以 `runs.jsonl`（含 input_sha256）監控，於風險記載（見 §8 R1）。
- 空/缺 REQUEST_ID 的 NORMAL 列 → 視為輸入違規（fail-fast，exit 2），不以合成鍵掩蓋。
- CLIENT IP 對映多個相異 HOSP_ID **不影響去重**（去重只看 REQUEST_ID），但於 aggregate 觸發資料品質 WARN（見 §6-11）。

### 3.5 狀態持久化（`state.py` + `statelock.py`）

#### 3.5.1 格式與位置

主 state：`{state_dir}/records.csv`（`--state-dir` 決定路徑，容器預設
`/data/state`；無預設 host 慣例位置，見 §4.7.5）。UTF-8、帶表頭、
`QUOTE_MINIMAL`、`\n` 換行、固定欄序；**全欄字串**，一律
`csv.reader`/`csv.writer` 讀寫（全 str → 前導零永遠保留）。交付 xlsx
為其快照/檢視（每執行由 state 重生）。

**選 CSV 而非 xlsx/JSONL 之理由**：可 git diff、人類可讀（惟末尾一列
為機器完整性尾列，見 §3.5.3）、stdlib、無數值化風險、對齊 log-parse
專案 CSV ethos。

#### 3.5.2 state schema（10 欄；前 2 欄為內部隱藏鍵，不進交付檔）

```
BATCH_ID, REQUEST_ID, APP_TIME_ISO, CLIENT_IP, SERVER_IP, HOSP_ID, HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT_ID_AES
```

- **10 存欄 → 9 交付欄映射**：移除 `BATCH_ID`+`REQUEST_ID`（內部
  鍵）、將 `APP_TIME_ISO` 展開為 `DATE`+`TIME`（同值兩格式），即得交
  付 9 欄——state 保留 REQUEST_ID 為內部鍵、交付僅顯 9 欄。
- `BATCH_ID`：整數序（字串儲存），**由 1 起算**（第 n 次 ingest =
  `n`）。用途：使「最新批次黃底」可由持久化 state 推導
  （`batch_id == max(BATCH_ID)`），令交付檔可由 state 重生（見
  §4.1）。
- `REQUEST_ID`：去重自然鍵（內部；剔除於交付）。
- `APP_TIME_ISO`：保留**原始完整字串** `YYYY-MM-DD HH:MM:SS.mmm`
  （DATE/TIME 唯一來源），避免 Excel 浮點序列往返漂移 → 確定性。
- `HOSP_ABBR`：ingest 當下解析並凍結（歷史列不可變、可重現）。

#### 3.5.3 完整性：內嵌尾列

`records.csv` 的**最後一實體列**為機器完整性描述子（非 CSV 資料列，
以 `#META` 前綴辨識）：

```
#META	schema=1	records=N	last_batch_seq=M	sha256=<hex over header+all data rows>
```

完整性描述子**內嵌**於 records.csv（而非獨立 manifest 檔）：獨立
manifest 會產生「records.csv 已 os.replace、manifest 尚未更新」的視
窗——崩潰後下次載入會把完整無誤的 state 誤判為毀損並 exit 3，且復原
.bak 反而丟棄已提交批次。內嵌設計下，**單一 `os.replace` 原子涵蓋資
料與其完整性描述子**，跨檔不一致視窗徹底消失（`os.replace` 保證
records.csv 永非半寫）。讀取器先分離 `#META` 尾列再 csv-parse 前段；
records.csv 為機器託管，文件明訂勿手改（見 §4.6、
[`data-fidelity.md`](data-fidelity.md) §8）。

#### 3.5.4 載入時 crash-tolerant 復原

`state.load()` 判定序（完整性檢查恆為 on，內建）：

1. records.csv 不存在 → 空 state 起步（見 §3.5.5）。
2. **可解析且尾列存在且 sha256/records 相符** → 正常載入。
3. **可解析但尾列缺失**（如舊版/被手改）→ WARN（非致命），即時重算並在下次寫入補上尾列，繼續執行（不 brick）。
4. **可解析但尾列 sha256 不符**（真正竄改/損壞）→ 嘗試 `records.csv.bak`：若 .bak 通過驗證 → WARN 並以 .bak 續行；否則 `StateIntegrityError`（exit 3）。
5. **無法解析/欄數不一致** → 同 4 之 .bak 復原路徑；皆失敗 → exit 3。

**原則**：預設優先「完整 state 的可用性」，完整的 state 絕不被視為毀
損；容忍復原為唯一模式（無嚴格模式旗標）。

**原子寫入**：tmp→fsync→`.bak`→`os.replace`；`records.csv` 之尾列使
資料與完整性同一次 replace 落地，崩潰不留半寫 state。內建保留單一
`records.csv.bak`（每次提交前備份舊檔），換取即時還原。權限：
state_dir/out_dir 以 0700 目錄、0600 檔（`umask 077`）建立（一般
least-privilege 檔案衛生，見 §4.6）。

#### 3.5.5 canonical state 起步方式

canonical state **從空起步**：`records.csv` 不存在即視為空 state
（`existing=[]`、`existing_request_ids=set()`、`max_batch_seq=0`），
自第一個真實批次開始累積，首次執行（run 1）不特殊——它只是「第一個
把 NORMAL 列 append 進空 state 的批次」，無 seeding 機制。若需攜入既
有歷史資料，不需任何特殊步驟：把該段歷史 CSV（14 欄、含 REQUEST_ID
的 analyze_access 輸出）當作一個普通的首批輸入執行即可，經同一
S3–S9 路徑進入 state（自然成為 `BATCH_ID=1`）。

#### 3.5.6 稽核附檔 `runs.jsonl`（append-only）

每次執行一列 JSON：`{run_utc, run_date, input_path, input_sha256,
rows_in, normal, dropped_nonnormal, skipped_cross, skipped_intra,
appended, batch_seq, deliverable_name, appended_request_ids:[...],
state_total, unique_ips, unmapped_hosp_ids}`。供冪等驗證、稽核，以及
同日檔名消歧（比對當日 `input_sha256`，見 §3.7.2）。

### 3.6 聚合（`aggregate.py`）

由**完整 state**（`existing + new_records`）重新計算「院所分析」，而
非增量修補：

1. 以 CLIENT IP **首見順序**去重（對映模板 `UNIQUE(FILTER(...))`）。
2. 每個 IP 取其**首見 state 列**的 HOSP_ID/HOSP_ABBR（對映模板
   `XLOOKUP(IP, 調閱紀錄!C:C, E:E/F:F)` first-match，查的是**調閱紀
   錄自身**，不是 93k 主檔）；同一 IP 對映多個相異 HOSP_ID 時取首見
   值並記一筆 WARNING（含全部相異 HOSP_ID + 該 IP）。
3. 內部一次算出 `max_batch_id = max(BATCH_ID in full_state)`；每
   IP：`TOTAL ACCESS` = 全 state 中該 IP 的列數（對映模板單一 COUNT
   欄）；`WEEKLY ACCESS` = `batch_id == max_batch_id` 的列數（本工具
   在模板語意之上的增強，模板無對應公式）。
4. 單一批次（如首次執行）時 WEEKLY == TOTAL、恆無 `-`；多批次時僅最
   新批次列計入 WEEKLY，older-only IP 之 WEEKLY 為 0（xlsx_writer 呈
   現層 render 為 `-`，見 §3.7）。

複雜度 O(n)（n = state 總列數），見 §4.5。輸出欄位定義見 §3.1.3；落地
錨點見 §1.5.2；多批次驗收見 §7.2 E2E-3、E2E-7。

### 3.7 交付產生（`xlsx_writer.py`）

兩張純值 sheet、無公式，均經 openpyxl 3.1.5 round-trip 實測。

#### 3.7.1 工作簿結構

移除 openpyxl 預設 `Sheet`；建立**恰 2 張**、順序：`調閱紀錄`(1)、
`院所分析`(2)。**絕不**含 紀錄匯入 / 格式轉換 / HOSP_ID對照表（交付
檔精簡、不夾帶 93k 主檔）；**無任何公式**（模板的
`UNIQUE`/`FILTER`/`XLOOKUP`/`ANCHORARRAY`/`COUNTIF` 動態陣列公式，
openpyxl 無法重算，全部由 Python 預算為純值）。唯值化優勢：任何
Excel/LibreOffice 版本開啟皆正確、無需重算、無 spill 相容風險、檔案
小。

#### 3.7.2 檔名規則（同日消歧內建、自動；無旗標）

- 預設 `{run_date:%Y-%m-%d}_連線紀錄.xlsx`（`run_date` = 今日）。
- **同日多批消歧**：若同名檔已存在且 `runs.jsonl` 顯示當日最後一次
  執行之 `input_sha256` **不同**（＝真的第二個不同批次，如補跑漏
  週/更正重匯）→ 自動附序號 `{run_date}_連線紀錄_{seq:02d}.xlsx`
  （seq = 當日 ingest 次數）。相同 `input_sha256`（冪等重跑）→ 同名
  覆寫（確定性）。
- 容器需 `LANG=C.UTF-8` 正確處理中文檔名；先寫 `.tmp`→`os.replace`
  原子落地；out_dir 不存在則 `mkdir(parents=True, exist_ok=True)`。

#### 3.7.3 Sheet 1「調閱紀錄」（1 表頭 + 完整 state N 列，依 state 順序：舊列在前、最新批次 append 在後）

表頭 A1:I1 精確字面：`DATE, TIME, CLIENT IP, SERVER IP, HOSP_ID,
HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT ID AES`。逐欄（實測可還原）：

- **A(DATE)**：`cell.value = datetime.datetime(...)`（含
  microsecond）；`cell.number_format = 'yyyy\-mm\-dd;@'` →
  data_type='d'、is_date=True。
- **B(TIME)**：`cell.value = <與 A 同一 datetime 物件>`；
  `cell.number_format = 'h:mm:ss;@'`。**A、B 同值、僅格式不同**。
- **C–I（文字欄）**：`cell.value = <str>`；`cell.number_format =
  '@'`（硬化；見 §1.5.4）。HOSP_ABBR 未命中寫 `""`（回讀為 None，測
  試須斷言「空或 None」）。
- **黃底（最新批次；每執行重置）**：`PatternFill(fill_type='solid',
  fgColor='FFFFFF00')`（明確 8 碼 ARGB、FF 全不透明；6 碼會被存為
  alpha=00）。**僅** `batch_id == max(BATCH_ID)` 之列，對 A:I 9 格全
  上黃底；其餘列**不設 fill**（每執行由完整 state 重建整表 → 天然
  per-run 重置語意）。

**置中／框線／欄寬（兩 sheet 通用，§3.7.4/§3.7.5 一併適用）**：

- 全部儲存格（表頭 + 資料，兩 sheet）：`Alignment(horizontal='center',
  vertical='center')`。
- 每一資料格（兩 sheet）：`Border(left/right/top/bottom =
  Side(style='thin'))`（所有框線）；黃底 fill 與此 thin 框線、置中對
  齊三者於最新批次列同時存在，互不覆蓋（fill/border/alignment 為儲
  存格三個獨立屬性）。
- 欄寬：`width = round(max(display_width(表頭文字),
  max(display_width(該欄每一資料格 rendered 值))) * 1.2, 2)`。
  `rendered` 值＝儲存格實際顯示的字元：DATE → `"YYYY-MM-DD"`（固定
  10 碼）、TIME → `"HH:MM:SS"`（固定 8 碼，不含毫秒）、int → 其十進
  位數字字串、`-`（WEEKLY 無存取 sentinel）→ 1 碼、`None`（未命中
  HOSP_ABBR 回讀）→ 空字串。`display_width` 以
  `unicodedata.east_asian_width` 為 `W`/`F`（CJK/全形）者計 2、其餘
  計 1（門諾醫院/臺北虛擬診等中文欄正確計寬）。此為每次執行依當下
  實際資料動態計算（非硬編常數）；標頭字串亦納入 max 比較，確保如
  「WEEKLY ACCESS」（13 碼）等寬表頭不被窄資料截斷。作為所有列都已
  寫入後的一次性 post-pass 套用；空（僅表頭）sheet 仍依表頭寬度取
  值。

#### 3.7.4 Sheet 2「院所分析」（1 表頭 + 11 唯一 IP，依首見序；5 欄）

表頭 A1:E1：`CLIENT IP, HOSP_ID, HOSP_ABBR, WEEKLY ACCESS, TOTAL
ACCESS`。

- **A,B,C**：TEXT（`str` + `@`）；HOSP_ABBR 可為 `""`。
- **D(WEEKLY ACCESS)**：`weekly_access == 0` → `cell.value = "-"`
  （str，number_format `@`）；否則 `cell.value = <int>`
  （number_format 維持預設 `General`）。
- **E(TOTAL ACCESS)**：`cell.value = <int>`（NUMERIC，type='n'；
  number_format `General`）。此即模板單一 COUNT 欄。
- 值由 `aggregate`（§3.6）於 Python 算妥（無公式）。
- 全格置中對齊 + 資料格四面 thin 框線 + 自動欄寬（同 §3.7.3 公
  式）。

落地錨點見 §1.5.2；WEEKLY 之 `-` 與 weekly<total 案例見 §7.2 E2E-3、
E2E-7。

#### 3.7.5 表頭樣式（外觀；忠於模板但用顯式 RGB）

模板實測：表頭 solid 淺綠底（theme=9 tint≈0.8）；資料列無 fill；無
freeze_panes、無 auto_filter。交付採：`Font(bold=True, size=12)`
（bold 為可讀性微增，模板本身非 bold）+ solid 淺綠底以**顯式 RGB
`E2EFDA`**（用顯式 RGB 而非 theme index：實測讀 theme 色之
`fgColor.rgb` 會拋 `Values must be of type str`，theme 色亦不隨新工
作簿可靠移植）。表頭每格 `Alignment(horizontal='center',
vertical='center')` + `Border(bottom=Side(style='thick'),
left/right/top=Side(style='thin'))`——粗下框線為強調，thin 三側為與
資料格的連續格線（否則表頭列左右上三側會是無框線斷點）；Fill
（`FFE2EFDA`）+ Font（bold, size=12）+ Border + Alignment 四者於表頭
格同時存在。欄寬依現有資料＋表頭字串顯示寬度每次執行自動 auto-fit
（見 §3.7.3 公式），非硬編常數；freeze_panes/auto_filter 不加。

#### 3.7.6 保真檢核（產出後自我斷言，寫入 e2e 測試）

回讀交付檔斷言：工作簿**恰 2 sheet、零公式**、無 紀錄匯入/格式轉換/
HOSP_ID對照表；表頭字面精確；`A2.value ==
datetime(2026,7,5,16,3,34,359000)` 且 `A2.value == B2.value`（斷言
datetime 值，不斷言浮點序列 repr）；`'yyyy' in A2.number_format`、
`'h:mm' in B2.number_format`；HOSP_ID 回讀為 `"0937010019"`（str，非
int）；未命中 HOSP_ABBR 回讀「空或 None」；WEEKLY/TOTAL 皆為 int
（`type='n'`）；本週無存取 IP 的 WEEKLY 回讀為 `-`（`type='s'`，
`number_format=='@'`）；黃底僅落**最新批次**列（fgColor endswith
`FFFF00`、patternType solid），其餘列無 fill。

每一資料格（兩 sheet）`alignment.horizontal=='center'` 且
`alignment.vertical=='center'`、四面 `border.*.style=='thin'`；每一
表頭格 `alignment` 同上、`border.bottom.style=='thick'`、
`border.left/right/top.style=='thin'`；黃底列同時具備 fill
`FFFFFF00`、四面 thin 框線、置中對齊（三者互不排斥）；各欄寬等於
§3.7.3 公式之預期值（E2E-1 錨點：調閱紀錄 A=12.0 B=9.6 C=18.0 D=12.0
E=12.0 F=12.0 G=38.4 H=9.6 I=38.4；院所分析 A=18.0 B=12.0 C=12.0
D=15.6 E=14.4——D=15.6 係因表頭「WEEKLY ACCESS」顯示寬度 13 主導單位
數資料，正是「表頭納入 max」設計理由的具體例證）。

### 3.8 管線階段序列（`pipeline.py` 串接；純函式階段可單測，`state` 為唯一副作用者）

**S0 — Bootstrap**：解析 CLI → 建 `Config`（路徑正規化+校驗，防
CWE-22）；設定 stderr 結構化日誌（INFO）；決定 `run_date`（內建 = 容
器 TZ=Asia/Taipei 今日；`pipeline.run()` 接受內部 `run_date` 參數供
測試注入，CLI 不暴露旗標），作為交付檔名與「最新批次」標記基準；取
得 `{state_dir}/.lock`（`statelock`：flock 優先、失敗則
O_CREAT|O_EXCL 備援 + stale 偵測，見 §4.4），忙碌→`LockBusyError`
（exit 4）立即快速失敗（不等待，內建行為）。啟動清理殘留 `*.tmp`
（前次崩潰遺留；records.csv 因原子性必完整或不存在）。

**S1 — 載入參考資料**：`lookup.load(hosp_id_map.csv.gz)` →
`dict[str,str]`（gzip+csv.reader 全 str，前導零保留）。健全性檢查：
列數約 93k、鍵長多為 10、無重複鍵 → 異常僅 WARN（容忍主檔演進）。缺
檔/不可讀 → `ReferenceError`（exit 5）。

**S2 — 載入 state（從空起步；無 seeding）**：`state.load()`：
records.csv 不存在 → 視為空 state：`existing=[]`、
`existing_request_ids=set()`、`max_batch_seq=0`。首次執行即以此空
state 進行第一個真實批次（見 §3.5.5）。存在 → 讀入並以 records.csv
尾列完整性描述子驗證（見 §3.5.3）；完整→正常；不完整/毀損→
crash-tolerant 復原（見 §3.5.4），必要時 `StateIntegrityError`
（exit 3）。產出 `existing: list[StateRecord]`、
`existing_request_ids: set[str]`、`max_batch_seq`。

**S3 — 解析 + 驗證輸入**：`csv_reader.read(INPUT)`（見 §3.2）。

**S4 — 過濾 NORMAL + 解析時間**：`transform.filter_normal()` +
APP_TIME 解析（見 §3.2）。

**S5 — 投影 + 查簡稱**：`transform.project()` 建 9 欄 payload（見
§3.2、§3.3）。

**S6 — 去重（vs state、批次內）**：`dedup.apply()`（見 §3.4）。

**S7 — 配 BATCH_ID + 重算聚合**：本執行的 ingest 批次配號
`batch_seq = max_batch_seq + 1`（空 state → max=0 → 首批 = 1），每筆
`new_record.batch_id = batch_seq`；建 `full_state = existing +
new_records`；`aggregate.build(full_state)`（見 §3.6）。

**S8 — 寫交付 xlsx 至 .tmp**：`xlsx_writer.write(out.tmp)`（見
§3.7）；`fsync`。

**S9 — 原子提交**（state-first，保證交付檔為已提交 state 之投影，見
§4.1）：

1. `state.commit(full_state)`：寫 `records.csv.tmp`（含 `#META` 尾
   列完整性描述子）→ `fsync` → 備份舊檔為 `records.csv.bak` →
   `os.replace`（POSIX 原子）。
2. `os.replace(out.tmp → 交付檔)`（原子落地）。
3. append 一列 `runs.jsonl`（見 §3.5.6）。

若 `len(new_records)==0` → 跳過 state 寫入（冪等，不擾動 .bak），仍
產生反映現有 state 的交付檔（黃底落在 state 現有最新批次；空 state
則 0 列 0 黃底）。

**S10 — 摘要 + 收尾**：釋放鎖；stdout 輸出單一 JSON 摘要（見
§3.9.2）；依結果設退出碼（見 §4.2）。

**交付檔重建保證**：交付 xlsx 為完整 state 的純投影，每次執行由
state 重生，黃底恆落在最新批次（max BATCH_ID）。若 S9.2 交付檔寫失
敗（罕見；同目錄 os.replace 於 fsync 後）→ 程序 exit 5 立即示警；操
作者**以最近一次每週輸入重跑**（該輸入去重為 0 新增，但交付檔仍由
state 重生並正確標最新批次黃底）即可復原，無需任何特殊指令/旗標
（見 §4.1）。

### 3.9 CLI 契約（`cli.py`）

指令：`report-export`（`pyproject.toml` 註冊的 `console_script`）或
`python -m report_export`（容器 entrypoint 固定用此形式）；兩者行為
完全相同。

**設計規則（YAGNI）**：只有當有具體 use-case 需求時，才把行為抽成參
數；否則一律烘焙為內部預設。據此僅暴露以下三項；其餘全部烘焙。

| 引數 | 必填 | 預設 | 說明 |
|------|------|------|------|
| `INPUT`（位置引數） | 是 | — | 本批原始 14 欄 CSV 路徑 |
| `--state-dir PATH` | 否 | `/data/state`（容器掛載點） | canonical state 目錄；host 直跑須自訂（無預設慣例位置，見 §4.7.5） |
| `--out-dir PATH` | 否 | `/data/output`（容器掛載點） | 交付 xlsx 目錄；host 直跑須自訂 |
| `--version` / `--help` | 否 | — | 標準 argparse |

#### 3.9.1 烘焙為內部預設的行為（無旗標）

| 已烘焙行為 | 內建值 / 機制 | 對應內部運作 |
|-----------|---------------|--------------|
| run_date | 今日（容器 TZ=Asia/Taipei） | `pipeline.run()` 接受 `run_date` 參數（預設 `date.today()`）；CLI 恆用今日，**測試注入固定日期**（test seam） |
| 去重策略 | `warn-skip` | 重複 REQUEST_ID → WARN+SKIP、exit 0（見 §3.4.3） |
| 同日檔名消歧 | 自動 | 依 `runs.jsonl` 當日 `input_sha256` 比對加序號或覆寫（見 §3.7.2） |
| 完整性檢查 | 恆 on（crash-tolerant） | `#META` 尾列驗證 + 容忍復原（見 §3.5.4） |
| `.bak` 備份 | 恆保留單一備份 | 每次提交前備份舊 records.csv（見 §3.5.4） |
| 交付檔重建 | 每 run 由 state 重生 | 黃底恆落最新批次；復原＝重跑最近輸入（見 §4.1） |
| 鎖等待 | 立即失敗（不等待） | 鎖忙碌 → `LockBusyError` exit 4（見 §4.4） |
| 摘要格式 | JSON 至 stdout | 單一 JSON 物件（見 §3.9.2） |
| 日誌層級 | INFO 至 stderr | 結構化日誌；除錯可經環境變數提升層級（非旗標、內部用） |

#### 3.9.2 stdout 摘要（JSON，單一物件，欄位依字母序排序）

```json
{"batch_seq":1,"deliverable":".../2026-07-15_連線紀錄.xlsx","dropped_nonnormal":6,
 "input":".../week.csv","input_sha256":"...","new_records":19,"normal":19,
 "rows_in":25,"run_date":"2026-07-15","skipped_cross_state":0,
 "skipped_intra_batch":0,"state_total":19,"unique_ips":11,
 "unknown_status_skipped":0,"unmapped_hosp_ids":0}
```

欄位定義與完整範例見 [`usage.md`](usage.md)「stdout 摘要」一節。

#### 3.9.3 stderr（結構化日誌）

含 dedup 警告（REQUEST_ID + 行號）、unmapped HOSP_ID 警告、多
HOSP_ID 之 IP 警告（以 HOSP_IDs + IP 表述）；解析錯誤報行號 + 欄
名。**無遮罩**（一般結構化日誌，見 §4.6）。

#### 3.9.4 退出碼

見 §4.2 錯誤處理與退出碼。

#### 3.9.5 安全

路徑正規化並校驗 `INPUT`/`--state-dir`/`--out-dir`（防 CWE-22）。無
互動提示。

---

## 4. 橫切關注

### 4.1 冪等性與交付檔重建

- **黃底集合 = 最新批次**：交付 xlsx 對 `batch_id ==
  max(BATCH_ID in full_state)` 之列上黃底。此即模板「每次貼上僅標本
  次新增」的 per-run 重置語意——最新批次高亮、歷史批次無底。
- **提交順序（S9，state-first）**：先原子提交 state（records.csv，
  含新 BATCH_ID 與 `#META` 尾列），再 os.replace 交付檔。交付檔恆為
  「已提交 state」之純投影，**不會**出現「交付了尚未入 state 的批
  次」。
- **交付檔重建**：交付 xlsx 每執行由 state 重生、黃底恆落最新批
  次。若交付檔遺失或 S9.2 寫失敗（exit 5 立即示警）→ **以最近一次
  每週輸入重跑**：該輸入去重為 0 新增、max BATCH_ID 不變，交付檔重
  生並正確高亮最新批次。無需特殊指令/旗標。**設計取捨**：僅支援重
  建「最新批次」之交付檔；重建任意歷史批次之黃底刻意不提供——歷史
  交付檔已於當週交付時由操作者存檔。
- **冪等**：相同 `INPUT` 重跑 → 全 REQUEST_ID 已存在 → 0 新增 →
  state 位元不變 → 交付檔為**同一最新批次高亮**的等價檔（兩次執行
  「儲存格值 + 型別 + number_format + fill」相等）。

### 4.2 錯誤處理與退出碼

`cli.py` 是全程式**唯一**攔截例外並轉換為結束碼的地方（`errors.py`
的例外類別自身文件亦如此記載）；其餘模組一律讓型別化例外原樣往上拋
（fail-fast、無 `except: pass`）。

| 碼 | 例外類別（`errors.py`） | 觸發情境 |
|----|--------------------------|----------|
| `0` | — | 成功；**含**有去重跳過（warn-skip）的情形——重複是重跑/重匯的預期結果，不算失敗。 |
| `1` | `UsageError` | CLI 用法/參數錯誤（未知旗標、缺 `INPUT`、路徑含 NUL 位元組或無法正規化）。 |
| `2` | `InputValidationError` | 輸入 CSV 驗證失敗：標題不符、欄數不符、編碼非 UTF-8、NORMAL 列缺/壞 APP_TIME、缺 APP_SERVER/CLIENT_IP/REQUEST_ID。 |
| `3` | `StateIntegrityError` | `records.csv` 尾列完整性驗證失敗，且 `.bak` 復原也失敗（見 §3.5.4）。 |
| `4` | `LockBusyError` | `state_dir` 已被另一執行中的程序鎖住；立即失敗，不等待、不重試（見 §4.4）。 |
| `5` | `WriteError` / `ReferenceError` | 交付檔或 state 寫入/IO 失敗（含 host 權限問題，見 §4.7.3）；或 `reference/hosp_id_map.csv.gz` 缺失/不可讀/格式錯誤。 |

操作者對應動作見 [`usage.md`](usage.md)「結束碼」一節。

### 4.3 結構化日誌

所有日誌一律輸出到 **stderr**，stdout 僅單一 JSON 摘要（stream 分
離，對排程系統友善）。格式：`TIMESTAMP LEVEL logger=NAME
msg=MESSAGE [key=val ...]`。預設層級 `INFO`；環境變數
`REPORT_EXPORT_LOG_LEVEL`（非 CLI 旗標，內部/除錯用）可提升層級。
TTY 且未設 `NO_COLOR` 時上色，重導向/管線時自動變回純文字。**無遮
罩**：REQUEST_ID／CLIENT_IP／HOSP_ID 等一律原樣記錄（§4.6：無 PII
顧慮，不做資料遮罩）。去重警告標明 REQUEST_ID + 輸入行號；HOSP_ID
未命中、同一 CLIENT IP 對映多個 HOSP_ID 等資料品質訊號亦為 WARNING
層級，**不會**讓程序失敗（exit 0）。

### 4.4 並行與鎖（`statelock.py`）

- **檔案鎖抽象**：優先 `fcntl.flock(LOCK_EX|LOCK_NB)`；**因本專案為
  NAS 導向、rw 卷常掛於網路儲存，flock 於 NFSv3/CIFS 可能被模擬、
  降級或形同無效**，故：
  1. **主保證 = 作業層序列化**（單一維運者/cron 排程序列執
     行）——第一守則。
  2. flock 為 best-effort defense-in-depth；偵測到 fs 不支援時改用
     `O_CREAT|O_EXCL` 哨兵鎖檔（`.lock.sentinel`，內含
     `pid + host + utc`），並做 **stale 偵測**（PID 不存在或鎖齡超
     過 6 小時 → WARN 後回收）。
  3. 無法可靠取得鎖 → fail-loud（`LockBusyError` exit 4，**立即失
     敗、不等待**），不靜默前進。
  - `state_dir` 建議置於 **POSIX-local** 或 **NFSv4(lockd)** 檔案
    系統，避免 NFSv3/CIFS。
- 啟動時自動清除上次崩潰殘留的 `*.tmp` 檔（`records.csv` 本身因原
  子寫入保證只會「完整存在」或「不存在」，不會半寫殘留）。

### 4.5 效能特性

每週 × 數年 ≈ 10⁴ 列量級；`aggregate.build()` 全掃 O(n) 於此量級充
裕（見 §8 R8）。`lookup.load()` 一次性讀 93,781 列 gzip CSV <0.1s、
記憶體 <20MB。封存/輪替/分割列為未來項，目前不預先實作（見 §8
R8）。

### 4.6 安全

本工具處理**內部授權資料**；所有資料/欄位皆可正常操作與記錄，**無
特殊 PII 處理需求**。安全姿態聚焦於一般工程衛生與供應鏈/攻擊面控
制，不含資料遮罩、靜態加密或合規緩解。

- **無網路**：工具零對外連線；建議 `docker run --network none`（選
  配硬化，見 §4.7.4）。
- **一般日誌**：`logging_setup` 為標準結構化日誌至 stderr（**無遮
  罩**）；stdout 僅單一 JSON 摘要，兩流分離。
- **檔案權限衛生（least privilege）**：state_dir/out_dir 以 0700 目
  錄、0600 檔（`umask 077`）建立——僅一般權限衛生，非資料敏感度驅
  動。
- **最小攻擊面**：非 root、root fs 可選唯讀、`--tmpfs /tmp`（選配硬
  化）；依賴僅 openpyxl（`--require-hashes` 釘選含 et_xmlfile，供應
  鏈完整性）；**無 pickle/eval/動態反序列化**（僅 csv/json，防
  CWE-502）；CI trivy 掃描、基底 digest pin。
- **路徑校驗**：正規化並校驗所有路徑引數（防 CWE-22）。
- **交付檔精簡**：交付檔刻意排除 93k 主檔與 紀錄匯入/格式轉換
  sheet；REQUEST_ID/BATCH_ID 內部鍵不進交付檔（對齊模板 sheet 結
  構，非資料保護）。
- **輸入唯讀**：輸入 CSV 以 `/data/input:ro` 掛載，不複製進映像。
- **可自由捆綁**：`hosp_id_map.csv.gz`、`source-log.csv`、模板等參
  考/範例資料可自由入映像與入庫（見 §4.7.7）。

### 4.7 Docker 封裝與部署

所有依賴入映像、主機零安裝；精簡、非 root、無網路、批次一次性。

#### 4.7.1 基底映像與多階段建置

預設 `python:3.12-slim`（Debian slim、glibc；以 digest pin）。
openpyxl 純 Python → 不需編譯工具。選項（文件註記）：
`python:3.12-alpine`（musl，省 ~30MB）；
`gcr.io/distroless/python3-debian12`（無 shell、攻擊面最小）作最嚴
執行期。

多階段 build 與可鎖定相依：

- **builder**：`FROM python:3.12-slim`；`pip install --no-cache-dir
  --require-hashes -r requirements.lock`。
- **requirements.lock 必須以 pip-compile / uv 產生**，同時釘選
  `openpyxl==3.1.5` **與其 runtime 相依 `et_xmlfile==<ver>`**（及任
  何 transitive）並附 hash——`--require-hashes` 模式下解析集中**每
  一個**套件都須 `==` 且帶 hash，否則安裝中止。
- **runtime**：`FROM python:3.12-slim`；`COPY --from=builder`
  venv；`COPY src/ /app/src/`；`COPY reference/hosp_id_map.csv.gz
  reference/hosp_id_map.manifest.json /app/reference/`（捆綁查表，
  自由入映像）。
- dev 相依（pytest/coverage/ruff/mypy）置 `requirements-dev.txt`，
  **不進**執行期映像。build context = `report-export/`，
  `-f docker/Dockerfile`。

#### 4.7.2 dockerignore

排除 `template/`（2.3MB xlsx + 輸入 fixture；已入庫作基線，執行期映
像不需要）、`state/`、`output/`、`inbox/`（unanchored pattern，任何
深度皆匹配，`docker/inbox`、`docker/state`、`docker/output` 亦明列
以利閱讀）、`docker/example/`（示範/測試 fixtures，不需入映像）、
`tests/`、`docs/`、`tools/`、`.git`、`__pycache__`。build context 精
簡；映像本就只 `COPY src/` + `reference/`。

**命名細節**：BuildKit 僅在 context root（`report-export/`，對齊
`docker build -f docker/Dockerfile .` 的呼叫方式）辨識純檔名
`.dockerignore`；Dockerfile 本身位於子目錄 `docker/` 時，BuildKit 改
採「與該 Dockerfile 同名」慣例 `<Dockerfile 檔名>.dockerignore`，故
實際檔名為 `docker/Dockerfile.dockerignore`——若誤放一個
`docker/.dockerignore`，會被靜默略過、不排除任何內容。

#### 4.7.3 寫入權限可攜性

映像內建非 root 使用者，固定 UID（預設 `10001`）。若 host 上的
`state_dir`/`out_dir` 目錄是**全新建立**、由呼叫者（host 使用者）擁
有，容器內 UID `10001` 對這兩個目錄**沒有寫入權限**——第一次寫
`records.csv`／交付 xlsx 就會失敗（exit 5）。這是典型「在開發機
（bind mount 權限寬鬆）可跑、在正式主機開箱即失敗」陷阱。

修正：

1. **所有 `docker run` 範例預設 `--user "$(id -u):$(id -g)"`**——程
   序以掛載目錄的擁有者身分執行，host 目錄可寫，產出檔亦歸操作
   者。
2. UID/GID 以 build-arg `APP_UID`/`APP_GID`（預設 10001）可調，供標
   準化服務帳號的站點。
3. 因 `--user` 可能對映無 `/etc/passwd` entry 的 uid，映像設 `ENV
   HOME=/tmp`；本工具不做 pwd lookup。主要 `docker run` 範例不帶
   `--read-only`，`/tmp` 由容器一般 rw 根檔案系統即可寫（無需額外
   `--tmpfs /tmp`）——`--tmpfs /tmp` 僅在站點自行加回 `--read-only`
   （選配硬化，見 §4.7.4）時才需要，`ENV HOME=/tmp` 本身不變。
4. named volume 情境：文件提供一次性 `docker run --user 0 ...
   chown` 初始化步驟，或改用 `--user`。
5. [`usage.md`](usage.md)「HOST 權限前置條件」一節明訂 host 權限前置
   條件：`state_dir`/`out_dir` 須由執行 `--user` 指定之 uid 可寫。

#### 4.7.4 安全／確定性環境變數

- 非 root：建 `appuser`(UID/GID `APP_UID`/`APP_GID`)、
  `USER ${APP_UID}`（作為未給 `--user` 時的預設）。
- `ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
  PYTHONHASHSEED=0 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Asia/Taipei
  HOME=/tmp`。
- OCI labels（source、version、`hosp-data-version`=manifest
  sha256）。無 HEALTHCHECK（一次性批次程序，非常駐服務，沒有「健
  康與否」可問）。
- **選配硬化（預設不加）**：`--network none`、`--read-only`、
  `--tmpfs /tmp` 對交付結果無功能性影響，純屬 defense-in-depth；安
  全敏感站點可在下方 §4.7.6 的主要範例上自行加回。CI 以 trivy 掃
  描；基底 digest pin。
- 映像已 `ENV TZ=Asia/Taipei`，故主要範例的 `docker run` 不再額外
  帶 `-e TZ=Asia/Taipei`——該旗標對已烘焙 ENV 的映像是冗餘的（已驗
  證）。

#### 4.7.5 Volumes 與掛載點

| 容器內掛載點 | 模式 | 用途 | 對應 CLI 預設 | host 對應目錄（使用者自訂，`-v` 指定） |
|--------------|------|------|----------------|-------------------------------|
| `/data/input` | 唯讀（`:ro`） | 本批原始 14 欄輸入 CSV | 由指令列位置引數指定 | `$HOST_INPUT_DIR`（使用者自訂） |
| `/data/state` | 讀寫 | canonical state（`records.csv` 等） | `--state-dir` 預設值 | `$HOST_STATE_DIR`（使用者自訂） |
| `/data/output` | 讀寫 | 交付 xlsx | `--out-dir` 預設值 | `$HOST_OUTPUT_DIR`（使用者自訂） |
| `/app/reference` | 映像內建、不掛載 | 捆綁的 HOSP 查表（build 時已 `COPY` 進映像） | — | — |

`/data/seed` 不存在——本工具無 seeding 機制（見 §3.5.5），canonical
state 從空目錄起步，第一次真正批次即 `BATCH_ID=1`。

**容器內掛載點與 `--state-dir`/`--out-dir` 預設值固定不變**；host 側
目錄由使用者自訂並以 `-v`/`--volume` 掛入——本文件不預設任何 host
路徑慣例，範例一律以 `HOST_INPUT_DIR`/`HOST_STATE_DIR`/
`HOST_OUTPUT_DIR` 三個環境變數代稱使用者自己選定的路徑（見
§4.7.6、[`usage.md`](usage.md)「Docker 部署」一節）。

#### 4.7.6 Entrypoint／CMD 與執行範例

```
WORKDIR /app
ENV PATH="/opt/venv/bin:$PATH" PYTHONPATH=/app/src
ENTRYPOINT ["python","-m","report_export"]
CMD []
```

每週執行（單一指令；state 自動從空起步/累積，首次執行不特殊）：

```bash
export HOST_INPUT_DIR=/path/to/your/input-dir    # 使用者自訂，僅需存在且可寫
export HOST_STATE_DIR=/path/to/your/state-dir     # 使用者自訂，須跨週使用同一目錄
export HOST_OUTPUT_DIR=/path/to/your/output-dir   # 使用者自訂

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$HOST_INPUT_DIR:/data/input:ro" \
  -v "$HOST_STATE_DIR:/data/state" \
  -v "$HOST_OUTPUT_DIR:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```

`--rm`（一次性批次語意）與 `--user "$(id -u):$(id -g)"`（host
bind-mount 可寫性**必要**，見 §4.7.3）保留；`--network none`、
`--read-only`、`--tmpfs /tmp`、`-e TZ=Asia/Taipei` 四個旗標預設不
加——前三者純屬 defense-in-depth、對交付結果無功能性影響，
`-e TZ=Asia/Taipei` 對已 `ENV TZ=Asia/Taipei` 的映像是冗餘的。容器內
`--state-dir`/`--out-dir` 預設即 `/data/state`、`/data/output`（與掛
載點一致），故無需傳旗標；每週只換輸入檔即可。

> **選配硬化**（安全敏感站點可自行加回，預設不加）：
> `--network none --read-only --tmpfs /tmp -e TZ=Asia/Taipei`。

選配 `docker/docker-compose.yml` 預接卷
（`HOST_INPUT_DIR`/`HOST_STATE_DIR`/`HOST_OUTPUT_DIR` +
`DOCKER_UID`/`DOCKER_GID`，含 `--user` 對應設定；同樣不含上述四個
硬化選項，見 [`usage.md`](usage.md)「docker compose（選配）」一
節）。

#### 4.7.7 封裝與版控界線

因**無 PII 顧慮**，資料檔可自由入庫。入庫政策如下：

- **入庫（可追溯基線）**：
  - `template/連線紀錄模板.xlsx` — 來源模板 + 93,781 列 HOSP 參考之
    來源；
  - `template/source-log.csv` — e2e 輸入 fixture（25 列、CRLF、無
    BOM）；
  - `reference/hosp_id_map.csv.gz` + `hosp_id_map.manifest.json` —
    由模板匯出之查表；
  - **建置期產生之預期輸出 fixtures**（各階段產生的 expected
    records.csv / 交付 xlsx 值快照等）亦入庫，作為回歸基準；
  - **可重複示範 fixtures**：`docker/example/state/records.csv`
    （seed state，19 列 batch1，位元組同
    `expected_records_e2e1.csv`）+
    `docker/example/input/week-2026-07-13.csv`（this-week 14 欄
    CRLF 輸入）——可重複示範三種 WEEKLY ACCESS 情形（brand-new
    weekly==total、overlap weekly<total、older-only weekly 顯示
    `-`），供 `tests/e2e` E2E-7 與 [`usage.md`](usage.md) 手動示範
    共用同一組固定 fixtures。
- **不入庫（`.gitignore`；使用者自訂、置於庫外的執行期資料）**：
  canonical state（`records.csv` 等）、交付 xlsx、輸入投放目錄，皆
  由使用者於 `--state-dir`/`--out-dir`/`-v` 指向庫外任意路徑；
  `.gitignore` 因此**僅涵蓋工具/快取產物**（`.venv/`、
  `__pycache__/`、`*.egg-info/`、`.pytest_cache/`、`.mypy_cache/`、
  `.ruff_cache/`、`.coverage`、`htmlcov/`），不再錨定任何執行期資料
  目錄——`docker/example/**` 是入庫 fixture，不受影響。
- **機器託管、勿用 Excel 編輯**：`hosp_id_map.csv.gz` 與
  `records.csv` 含前導零鍵（如 `0937010019`）；維運者若以 Excel 開
  啟編輯會數值化毀損 → 文件明訂此類檔為機器託管、勿用 Excel 直接編
  輯（見 §8 風險 R7）。

### 4.8 資料保真

逐欄型別、number_format、TEXT/datetime/int 理由分類、openpyxl
round-trip 行為、機器託管檔案警告，見 [`data-fidelity.md`](data-fidelity.md)
（單一真實來源對照表）。

---

## 5. 能力矩陣

| 能力 | 狀態／機制 | 參照 |
|------|------------|------|
| NORMAL 過濾 | 大小寫不敏感（`.strip().upper()=="NORMAL"`，對齊 Excel `=` 語意） | §3.2 |
| REQUEST_ID 去重 | 跨 state + 批次內；warn-skip，exit 0 | §3.4 |
| WEEKLY + TOTAL 雙欄聚合 | 首見序 + first-HOSP + 最新批次/全 state 雙計數 | §3.6 |
| 最新批次黃底 | 每執行由持久化 BATCH_ID 推導，per-run 重置 | §3.7.3 |
| 全表置中＋框線＋自動欄寬 | Alignment center、資料 thin border、表頭 thick 下框線、CJK 感知 auto-fit ×1.2 | §3.7.3–§3.7.5 |
| 原子 `#META` state | 單一 `os.replace` 涵蓋資料+完整性描述子 | §3.5.3 |
| Crash-tolerant 復原 | 尾列缺失 WARN+補寫；sha 不符→`.bak`；皆壞→exit 3 | §3.5.4 |
| 冪等重跑 | 相同輸入 → 0 新增、state 位元不變、交付檔等價 | §4.1 |
| 同日多批消歧 | `input_sha256` 比對；不同→自動 `_NN`；相同→冪等覆寫 | §3.7.2 |
| 交付檔重建 | 每 run 由 state 重生；復原＝重跑最近輸入 | §4.1 |
| Docker 非 root | `APP_UID`/`APP_GID`（預設 10001），可 build-arg 覆寫 | §4.7.3 |
| Host 可寫性 | `--user "$(id -u):$(id -g)"`（必要） | §4.7.3 |
| NAS 鎖降級因應 | flock 優先、O_CREAT\|O_EXCL 備援＋stale 偵測；主保證為作業層序列化 | §4.4 |
| 供應鏈完整性 | `requirements.lock` 全套件 `--require-hashes` | §4.7.1 |
| 依賴最小化 | 僅 openpyxl（+ et_xmlfile 傳遞相依） | §2.2 |

---

## 6. 邊界案例

1. **空輸入（僅表頭）** → 0 NORMAL → 不追加、state 不變；空 state 首次執行仍產生反映（空）state 的交付檔（0 列、0 黃底）；exit 0 + INFO。表頭缺失/錯序才 fail-loud（exit 2）。
2. **全非 NORMAL** → 0 追加；WARN「本批 0 筆 NORMAL」；交付檔反映既有 state（黃底落現有最新批次；空 state 則 0 黃底）；exit 0。
3. **未命中 HOSP_ID** → HOSP_ABBR `""`（IFERROR）；累計 unmapped WARN；不失敗；交付檔回讀該格為 None。
4. **重複匯入（REQUEST_ID 已在 state）** → 每筆 WARN（REQUEST_ID + 行號）+SKIP；退出碼 0；完全冪等（交付檔等價，黃底落現有最新批次）。
5. **批次內重複 REQUEST_ID** → 保留首見、後續 WARN+skip。
6. **前導零/文字保留**：HOSP_ID `0937010019`、BIRTHDAY `19560711`、PRSN_ID、PATIENT_ID_AES 全程 TEXT（csv→state csv→xlsx `@`）；回讀仍為 str。
7. **毫秒時間戳**：`…34.359`→`datetime(…,359000)`，相容無毫秒；TIME 顯示僅到秒。
8. **NORMAL 列 APP_TIME=`-`/不可解析** → 契約違反 → exit 2（只報行號/欄名）。實測 dash APP_TIME 僅出現於非 NORMAL 列。
9. **ORPHAN 列（row7）** APP_TIME 有效但 API 欄 dash → 因非 NORMAL 被過濾；其 CLIENT IP（10.243.129.44）不得灌入聚合（該 IP TOTAL ACCESS=1；WEEKLY ACCESS 視其是否在最新批次而定，E2E-1 單一批次時亦=1）。
10. **首次執行（空 state）**：無 records.csv → 直接以空 state 進行第一個真實批次（`BATCH_ID=1`）；**無 seeding、無特殊路徑**（見 §3.5.5）。
11. **同一 CLIENT IP 對映多個相異 HOSP_ID** → 取首見列自身值（XLOOKUP first-match）並 WARN（以 HOSP_IDs + IP 表述）。
12. **毀損/被竄改 state** → 循 §3.5.4 crash-tolerant 復原；.bak 亦壞才 exit 3。
13. **並行執行** → statelock 阻擋（flock 或 O_EXCL 備援）；第二執行立即 exit 4；程序死亡自動釋放/stale 回收；啟動清 *.tmp。
14. **HOSP_ID 長度非 10** → 軟性 WARN，仍處理（查表多半回 `""`）。
15. **CSV 編碼/BOM/CRLF** → `newline='' + utf-8-sig`；非法位元組 `errors='strict'` → exit 2。
16. **中文交付檔名** → 容器 `LANG/LC_ALL=C.UTF-8`。
17. **接近午夜的 run_date** → 以容器 TZ=Asia/Taipei 決定業務日（內建今日；測試可注入固定日期求確定性）。
18. **同日重跑 / 同日不同批** → 相同 input_sha256 覆寫；不同 input_sha256 自動加序號（§3.7.2）。
19. **out-dir/state-dir 不存在** → `mkdir(parents=True, exist_ok=True)`（0700）；bind mount 掛載點權限見 §4.7.3。
20. **輸入精度歧異** → 現行檔為完整精度可直接用；若誤把 Excel 失真匯出（mm:ss.d）當輸入，DATE/TIME 失去亞秒 → 輸入契約須為完整精度 analyze_access 輸出（見 §8）。
21. **state 長期成長（~10⁴ 列）** → aggregate O(n) 充裕；封存/分割為未來項（見 §8）。
22. **交付檔寫失敗但 state 已提交** → exit 5 示警；以最近輸入重跑重建交付檔（§4.1）。

---

## 7. 測試策略

CI 階段（對齊 lint→test→analyze→build→deploy）：`ruff`(lint) →
`mypy --strict`(analyze) → `pytest --cov`(test) → `docker build` →
容器內 `--network none` 跑 E2E-1 smoke → trivy scan。現況：**391 測
試全綠**，coverage gate `fail_under=80`（`pyproject.toml`），實測
100%。

### 7.1 單元測試

- `test_csv_reader`：14 欄標題精確比對（錯序/缺欄/多欄→exit 2）；欄數不符→帶行號；**CRLF 輸入以 `newline=''` 讀取、最後一欄不得殘留 `\r`**；utf-8-sig BOM 容忍；引號內逗號；STATUS 未知值→WARN+skip。
- `test_transform`：NORMAL 過濾（25→19）；**大小寫不敏感（`Normal`/`normal`/`NORMAL` 皆納入，對齊 Excel `=`）**；投影對映；APP_TIME `…34.359`→`datetime(…,359000)`，相容無毫秒；NORMAL 列 APP_TIME=`-`→exit 2；前導零 `0937010019` 維持 str。
- `test_lookup`：`0937010019`→`秀傳醫院`、`3501200000`→`臺北虛擬診`；未命中→`""`；前導零鍵；gz 載入。
- `test_dedup`：跨 state / 批次內重複→WARN+skip；重跑同輸入→0 新增。（無 fail 模式。）
- `test_state`：寫→讀往返（APP_TIME_ISO 毫秒不漂移）；**尾列完整性：寫入後尾列 records/sha 相符；竄改 body→情況4 復原/exit 3；尾列缺失→情況3 WARN+補寫（非致命）**；原子寫入（tmp→replace、產 .bak）；**空 state 起步（無 records.csv → existing=[]、max_batch_seq=0）**；首批 `BATCH_ID=1`；權限 0600/0700；殘留 .tmp 清理；**flock 不可用時 O_CREAT|O_EXCL 備援 + stale 偵測**。
- `test_aggregate`：11 唯一 IP、首見序 == 模板 A2:A12；單一批次（全 BATCH_ID=1）WEEKLY==TOTAL==`[1,1,1,1,1,1,3,1,7,1,1]` 合計 19；多批次時 WEEKLY 只計 `max(BATCH_ID)` 之列、older-only IP `weekly_access==0`、latest-batch 新 IP `weekly_access==total_access`；first-HOSP 取自調閱紀錄自身；多 HOSP_ID 之 IP→WARN + 取首見。
- `test_xlsx_writer`：A2==B2 datetime（非浮點序列 repr）；`'yyyy' in A2.number_format`、`'h:mm' in B2.number_format`；ID 欄回讀 str；**未命中 HOSP_ABBR 回讀空或 None**；WEEKLY/TOTAL int；`weekly_access==0` → 回讀 `-`（str, `@`）；表頭 5 欄（`CLIENT IP, HOSP_ID, HOSP_ABBR, WEEKLY ACCESS, TOTAL ACCESS`）；黃底 `FFFFFF00`、僅 `batch_id==max(BATCH_ID)` 列、其餘列無 fill；恰 2 sheet、零公式；表頭字面精確；**同日不同 input_sha256 → 檔名加序號**；全格置中、資料格四面 thin 框線、表頭 thick 下框線（+thin 左右上）、欄寬 auto-fit（依 §3.7.3 公式，於代表性資料上核對 E2E-1 錨點欄寬）。
- `test_logging`：stdout 為單一 JSON 摘要、stderr 為結構化日誌（**stream 分離**）；log record 型別/欄位正確。
- `test_pipeline` / `test_cli`：退出碼對應各例外；stdout JSON 欄位齊全；**內部 `run_date` 注入決定檔名**；精瘦 CLI 僅接受 INPUT/`--state-dir`/`--out-dir`（未知旗標→exit 1）。

### 7.2 端對端（驗收）測試

- **E2E-1（複現落地結果；空 state 首次執行）**：空 state + `INPUT=fixtures/source-log.csv`(25) → state 19 列（皆 `BATCH_ID=1`）；交付 調閱紀錄 19 資料列**全黃底**（皆最新批次）；院所分析 11 IP、WEEKLY 欄==TOTAL 欄==`[1,1,1,1,1,1,3,1,7,1,1]` 皆合計 19、無 `-`（單一批次 → WEEKLY==TOTAL）、秀傳醫院=7、臺北虛擬診=3、`10.243.129.44`=1（**證 ORPHAN 排除**）；全格置中、資料格四面 thin 框線、表頭 thick 下框線、欄寬 auto-fit（§3.7.6 錨點數值）。
- **E2E-2（冪等）**：重跑同輸入 → 0 新增、19 dup 警告、state **尾列/位元不變**；兩次交付檔「儲存格值 + data_type + number_format + fill」**相等**（非 bytes，因 xlsx zip/docProps 時戳非位元組確定），黃底皆落該單一批次 19 列。
- **E2E-3（新批次；per-run 黃底重置；新增 `-` 案例）**：於 E2E-1 之 state（19 列 batch1）後，ingest N=3 筆全新 REQUEST_ID（`batch_new.csv`）→ state 19+3=22（新列 `BATCH_ID=2`）→ 交付**恰 3 列黃底（batch2）、19 列 batch1 無 fill**；院所分析重算為 12 IP：TOTAL 10.245.1.125==8、192.168.117.104==4、10.250.77.10==1；WEEKLY（該批各 IP 恰 1 列）10.245.1.125==1、192.168.117.104==1、10.250.77.10==1；older-only IP（如 `10.243.129.44`）本批 0 列 → WEEKLY render `-`；brand-new `10.250.77.10` → hosp `1301170017`/`台北醫大`。
- **E2E-4（重匯重疊）**：於 E2E-3 後，再餵 source-log(19) → 19 皆去重 → state 不變、交付黃底仍落**最新真實批次（batch2 的 N 列）**、重匯的 19 不高亮。
- **E2E-5（交付檔重建）**：ingest 一批成功提交 state 後，模擬交付檔遺失，**以最近輸入重跑**（去重 0 新增）→ 交付檔由 state 重生、正確高亮最新批次（無特殊旗標）。
- **E2E-6（crash-tolerant state）**：手動使 records.csv 尾列與 body 不一致（模擬 manifest-lag 舊模型）→ 驗證載入**不 brick**、循情況 3/4 復原。
- **E2E-7（docker/example 可重複示範）**：載入 `docker/example/state`（複製至 tmp，保持入庫檔案不變）+ 餵 `docker/example/input/week-2026-07-13.csv`（4 列，其中 2 列 IP 為既有 `10.245.1.125`、1 列 IP 為既有 `192.168.117.104`、1 列為全新 IP `10.250.77.10`）→ 12 IP、`state_total` 23、`unique_ips` 12、`batch_seq` 2；WEEKLY render=`['-'×6, 1, '-', 2, '-', '-', 1]`、TOTAL=`[1×6, 4, 1, 9, 1, 1, 1]`；三種 WEEKLY 情形（brand-new weekly==total、overlap weekly<total、older-only weekly=`-`）齊備於同一次執行，且可無限次重複執行（seed 檔案不受測試影響）。
- **不變量**：`transform(source-log NORMAL)` == 預期 19 筆 StateRecord。

### 7.3 fixtures（`tests/fixtures/`）

以入庫基線 `template/source-log.csv`（25 列、**CRLF、無 BOM**）為主
e2e 輸入（可直接引用或複製至 fixtures）；另備 `hosp_map_small.csv`
（含 `0937010019` 與一未命中鍵）、`batch_new.csv`（全新
REQUEST_ID，供 E2E-3）、`empty.csv`（僅表頭）、`all_nonnormal.csv`
（僅 ORPHAN/UNVERIFIED）、`status_mixed_case.csv`（含
`Normal`/`normal` 驗大小寫不敏感）。**建置期產生之預期輸出
fixtures**（expected records.csv、交付值快照）入庫作回歸基準（見
§4.7.7）。**決定論**：內部注入固定 `run_date`；斷言儲存格值集合而
非 bytes。

**docker/example fixtures**：`docker/example/state/records.csv`
（seed，位元組同 `expected_records_e2e1.csv`）+
`docker/example/input/week-2026-07-13.csv`（this-week 14 欄 CRLF 輸
入）為 E2E-7 與 [`usage.md`](usage.md)「開箱即用快速驗證」手動示範共用的固定
fixtures；byte-exact 由 repo-root `.gitattributes` 的
`report-export/docker/example/** -text` 規則保證（this-week 輸入保
留 CRLF、seed state 保留 LF，不受 repo 預設 `* text=auto eol=lf` 正
規化影響）。

---

## 8. 已知限制與風險

| # | 風險 | 說明 | 緩解 |
|---|------|------|------|
| R1 | **去重鍵穩定性** | 若上游回收/改寫 REQUEST_ID，去重可能過度（漏收）或不足（重收） | 以 `runs.jsonl`（含 input_sha256、appended_request_ids）監控；REQUEST_ID 為 UUID 假設跨週全域唯一；異常於稽核附檔可追。 |
| R2 | **HOSP 主檔陳舊** | 捆綁 `hosp_id_map.csv.gz` 為建置時快照；新醫院代碼在重建映像前查不到 | 執行期對未命中 HOSP_ID 累計 WARN（可觀測訊號）；未命中→HOSP_ABBR `""`（IFERROR 語意、不失敗）；更新＝重跑 export + 重建映像（§3.3）。 |
| R3 | **NAS 鎖可靠性** | flock 於 NFSv3/CIFS 可能失效 → 兩程序同時「持鎖」互毀 state | 主保證改為**作業層序列化**（cron/單一維運者）；flock best-effort + O_EXCL 哨兵 + stale 偵測；無法可靠取鎖→fail-loud（exit 4）；state_dir 建議置 POSIX-local/NFSv4(lockd)。 |
| R4 | **datetime 亞秒捨入** | Excel 以浮點序列存 datetime，亞秒往返可能漂移 | state 以 `APP_TIME_ISO` 存**原始完整字串**（非序列），每 run 由字串重建 datetime → 確定性；測試斷言 `datetime` 值（非序列 repr）。 |
| R5 | **交付為值非公式** | 交付 xlsx 為預算純值、無 UNIQUE/FILTER/XLOOKUP 公式 | 為刻意設計（唯值化 → 跨版本可開、無 spill 相容風險）；聚合語意於 Python 精確重現並經 §3.7.6/§1.5.3 錨點驗證。 |
| R6 | **輸入 schema 飄移** | analyze_access 若改欄名/欄序/精度，契約破裂 | 標題精確 14 欄比對（不符→exit 2）；輸入契約明訂為完整精度 analyze_access 輸出；schema 版本可於未來擴充。 |
| R7 | **records.csv 非供 Excel 編輯** | 含前導零鍵（`0937010019`），維運者以 Excel 開啟會數值化毀損；且末列 `#META` 為機器完整性描述子 | 文件明訂為機器託管、勿用 Excel 編輯（§4.7.7）；state 為 CSV 便於 git diff/程式讀寫，非人手編輯介面。 |
| R8 | **state 長期成長** | 每週累積，數年後 ~10⁴ 列 | aggregate O(n) 全掃於此量級充裕；封存/輪替/分割列為未來項（目前不預先實作，YAGNI）。 |
