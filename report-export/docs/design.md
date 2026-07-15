> 文件：`report-export/docs/design.md`（設計文件，zh-TW）／狀態：**鎖定設計、僅規劃（PLANNING ONLY）**
> 本文件描述在使用者下達開工指令後「將要」建置的內容。此工作流**不**產生任何程式碼、**不**建立 Docker 映像、**不**新增執行期檔案。所有事實均已對 `report-export/template/連線紀錄模板.xlsx`（2.3MB、5 sheets）與 `report-export/template/source-log.csv`（25 資料列）於本次逐一實測驗證。這兩份輸入檔連同其衍生之參考資料與建置期產生之預期輸出 fixtures，於建置時一併**入庫作為可追溯基線**（見 §9.5）。技術名詞、程式識別字、sheet 名稱一律保留原文。

# report-export 週報匯出子工具 — 研究與架構設計（design.md, zh-TW）

## 0. 文件範圍與定位

`report-export` 是一個**可選、獨立、非整合**的自動化子工具，位於 `log-parse/report-export/` 之下，取代目前的手動每週 Excel 連線紀錄工作流程。它**不**與既有 `log-parse` 的 bash/gawk CLI 共用程式碼、**不**改動 `bin/`、`lib/`、`conf/`；它是一個一次性批次程式（非常駐、非服務、非資料庫）。所有研究與產出物均位於 `report-export/` 之下。

本設計涵蓋：系統概觀與目標、模組/架構、資料模型、管線階段、持久化（含 seeding 評估與決策）、去重、xlsx 產生規格、參考資料處理、Docker 規格、CLI、測試策略、邊界案例、安全、目錄結構、分階段建置序列、開放風險。文末第 18 章保留評審意見處置對照，並標註因「無 PII 顧慮」「移除 seeding」而作廢或修訂之條目。

### 0.1 相對前版之四項關鍵決策

1. **無 PII 顧慮**：關係人確認所有資料/欄位皆可正常操作與記錄。全面移除敏感資訊機制（BIRTHDAY 遮罩、CLIENT_IP 敏感化、映像 PII-free 限制、日誌遮罩、靜態加密/合規緩解）。安全章節簡化為「內部授權資料、無特殊 PII 處理；僅保留一般檔案權限衛生」。
2. **canonical state 從空起步**：移除整個 seeding 機制（無 `export_seed.py`、無 seed 掛載、無 `BATCH_ID=0`）。state 自第一個真實批次開始累積，run 1 不特殊（見 §6.8）。
3. **精瘦 CLI**：僅暴露必要旗標（位置引數 `INPUT` + 選配 `--state-dir`/`--out-dir`）；其餘行為全部烘焙為內部預設（YAGNI，見 §11）。
4. **入庫基線**：`template/source-log.csv` 與 `template/連線紀錄模板.xlsx`（以及衍生參考資料、建置期預期輸出 fixtures）入庫作為可追溯基線（見 §9.5；實際 commit 由 orchestrator 執行）。

---

## 1. 系統概觀與目標

### 1.1 取代的手動流程（模板語意）

模板 `連線紀錄模板.xlsx` 以 Excel 365 動態陣列公式串起 5 張 sheet：

1. `紀錄匯入`（貼上區，14 欄，無公式）— 貼上 analyze_access `--format csv` 輸出。
2. `格式轉換`（自動）— `FILTER(紀錄匯入, STATUS=="NORMAL")`，投影為 9 欄，其中 HOSP_ABBR 以 `XLOOKUP(HOSP_ID, HOSP_ID對照表)` 補齊。
3. `HOSP_ID對照表`（靜態 93,781 列參照，占檔案主要體積）。
4. `調閱紀錄`（持久累積）— 每週把 NORMAL 列附加於此，DATE/TIME 存為 Excel datetime 序列。
5. `院所分析`（報表）— 對 `調閱紀錄` 的 CLIENT IP 做 `UNIQUE`，逐一 `XLOOKUP`（對調閱紀錄自身 first-match）補 HOSP_ID/HOSP_ABBR，並 `COUNTIF` 計數。

### 1.2 子工具目標

- **正確性優先**：完整重現模板的過濾、投影、查表、聚合語意（見第 2、4 章實測基準）。
- **資料保真**：前導零全程 TEXT、DATE/TIME 同存一個 datetime 兩種 number_format、僅 NORMAL、per-IP COUNT、**最新批次黃底**（最新批次高亮、歷史批次無底；每次執行由完整 state 重建 → per-run 重置語意）。
- **可重複／冪等**：state 為單一真實來源；相同輸入重跑不重複追加、不破壞 state、產生等價交付檔。
- **營運簡單**：單一 batch CLI、安全預設、無守護程序/DB；主機零安裝（依賴全入 Docker 映像）；精瘦 CLI（僅必要旗標）。
- **精瘦 + 專案 ethos**：stdlib 為主僅引入 openpyxl；fail-fast loud、顯式型別、結構化日誌至 stderr、結果至 stdout/檔案。

### 1.3 執行環境（已確認）

Python 3.12.12、openpyxl 3.1.5、Docker 可用；openpyxl 純 Python（相依 et_xmlfile、無 C 擴充）。

---

## 2. 經真實檔案驗證的事實基準（並修正上游 parse-agent 錯誤）

> 本章為後續設計的錨點。所有數值本次以 openpyxl 3.1.5 直接讀取模板核對。`source-log.csv` 以逐位元組檢視核對。

### 2.1 列數流（e2e 不變量）

25 輸入列（NORMAL 19 / ORPHAN 1 / UNVERIFIED 5）→ `調閱紀錄` **19** 列 → `院所分析` **11** 個唯一 CLIENT IP。

### 2.2 院所分析（實測，首見序）

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

**修正 parse-agent**：其宣稱 `[1×10, 7]`（合計 17、漏「3」）為錯誤。

### 2.3 聚合語意（實測公式）

- A：`=UNIQUE(FILTER(調閱紀錄!C2:C…, 調閱紀錄!C2:C…<>""))`
- B：`=IFERROR(XLOOKUP(ANCHORARRAY(A2), 調閱紀錄!$C:$C, 調閱紀錄!$E:$E, ""), "")`
- C：`=IFERROR(XLOOKUP(ANCHORARRAY(A2), 調閱紀錄!$C:$C, 調閱紀錄!$F:$F, ""), "")`
- D：`=COUNTIF(調閱紀錄!$C:$C, ANCHORARRAY(A2))`

**關鍵**：院所分析的 HOSP_ID/HOSP_ABBR 是對「調閱紀錄自身」以 CLIENT IP 做 XLOOKUP **first-match**（取該 IP 首見列之值），**不是**再查 93k 主檔。主檔 XLOOKUP 只發生在 `格式轉換` 的 F 欄（`XLOOKUP(E2, HOSP_ID對照表!$A:$A, $B:$B, "")`）與 A/B 欄 `FILTER(…, 紀錄匯入!$B$2:$B$100000="NORMAL", "")`。

### 2.4 型別與 number_format（實測，關鍵修正）

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

**修正 parse-agent / 草稿**：草稿於 data_model 表 B 將 C–I 全部標為「模板實測 `@`」是錯誤——那是 `格式轉換` sheet（C–I 皆 `@`）。`調閱紀錄` 僅 E=`@`，其餘文字欄為 `General`，靠**值為字串型別（type='s'）**避免數值化。本工具刻意對全部文字欄寫 `@`（主動硬化），比模板更穩健（見第 8 章）。

### 2.5 填色（實測，修正）

`調閱紀錄` 表頭 A1 為 solid、theme=9、tint≈0.7999816…（淺綠）；資料列 A2 `fill_type=None`（無填色）。**修正 parse-agent**：其指的 theme9/tint0.8 solid fill 其實是**表頭**，模板既有 19 示範資料列**無填色**。（另註：讀 theme 色之 `fgColor.rgb` 會拋 `Values must be of type str`，本次實測確認；故第 8 章一律用顯式 RGB。）

### 2.6 輸入精度與換行（實測，修正）

- `source-log.csv` 為**完整精度**（`2026-07-05 16:03:34.359`），**非** mm:ss.d 失真版 → 可直接作 e2e 輸入 fixture；輸入契約即完整精度 analyze_access 輸出。此檔（25 列、**CRLF、無 BOM、末列無換行**）為入庫基線之一（見 §9.5）。
- `source-log.csv` 行尾為 **CRLF（\r\n）、無 BOM**（首 8 bytes = `REGION,S`）。故讀檔須 `newline=''`（見第 5 章 S3、第 12 章）。

### 2.7 BIRTHDAY 型別（實測，修正理由）

`紀錄匯入` N 欄（BIRTHDAY）以 **int 儲存**（type='n'，值如 19560711），且 19 列全為 19xx，**永不以 0 開頭**。故 BIRTHDAY 需 TEXT 的真正理由是「**避免被當數字/日期強制轉型**、對齊模板 `調閱紀錄` H 的文字輸出」，**不是**「前導零顯著」。前導零顯著僅適用於 HOSP_ID（531 個前導零鍵、代表值 0937010019）。

### 2.8 HOSP_ID對照表（實測）

93,781 列（+1 表頭 = 93,782）、鍵長全為 10、531 前導零、**0 重複鍵、0 空白簡稱**；表頭 `(HOSP_ID, HOSP_ABBR)`。openpyxl 一次性讀取數秒 → **絕不**作為執行期查表來源（見第 9 章）。

### 2.9 openpyxl round-trip 行為（實測，供測試斷言）

- `"0937010019"`／`"19560711"` 維持 type='s'、前導零保留。
- 同一 `datetime` 物件寫入 A、B 兩格、兩種 number_format 可完整還原（A2==B2）。
- COUNT int 寫入為 type='n'。
- 寫入空字串 `""` 的 HOSP_ABBR **回讀為 `None`**（openpyxl 正規化）→ 測試須斷言「空或 None」，不可嚴格斷言 `""`。
- 6 碼填色 `'FFFF00'` 會被存為 `00FFFF00`（alpha=00）→ 一律用 8 碼 `FFFFFF00`。

---

## 3. 模組 / 架構分解

採**單向資料流管線 + 純函式核心 + I/O 邊界隔離**。核心轉換無副作用；唯一具狀態元件為 `state`；I/O（CSV/xlsx/state/lock/reference）集中於邊界模組，利於單元測試、確定性重放與冪等。

### 3.1 語言 / 執行期（LOCKED）

純 Python 3.12 + openpyxl，封裝為 Docker 映像；分析以 stdlib（`csv`, `datetime`, `argparse`, `logging`, `pathlib`, `tempfile`, `os`, `json`, `gzip`, `hashlib`, `fcntl`, `errno`）完成。

- **採 openpyxl（justify）**：交付需寫「datetime 序列 + number_format + 純文字型別 + 黃底 + 表頭樣式」的 OOXML；stdlib 無法可靠產生，手刻 zipfile+XML 脆弱且違反 fail-fast。openpyxl 為純 Python（僅相依 et_xmlfile、無 C 擴充/lxml 硬依賴），且同時可讀（dev 匯出主檔、測試讀回產出皆需要）→ 單一相依覆蓋讀寫。
- **拒絕 pandas/numpy**：本量級（每週數十至低千列）不需要；numpy 使映像 +~50MB；pandas 的 dtype 推斷正是造成前導零數值化（本工具要根除的 bug 類別）的來源。**stdlib csv 全讀為 str → 前導零天生保留**，是本工具相對手動流程的核心優勢。不採 xlsxwriter（write-only，測試/匯出仍需讀能力）。

### 3.2 模組（`src/report_export/`，職責單一）

| 模組 | 職責 | 依賴 |
|------|------|------|
| `__main__.py` | `python -m report_export` → `cli.main()` | cli |
| `cli.py` | argparse（精瘦：位置 INPUT + --state-dir/--out-dir）、退出碼、stdout JSON 摘要 | pipeline, config, logging_setup |
| `config.py` | `@dataclass(frozen=True) Config`；路徑正規化/校驗（防 CWE-22）、內建預設 | errors |
| `errors.py` | 型別化例外：`UsageError`/`InputValidationError`/`StateIntegrityError`/`LockBusyError`/`WriteError`/`ReferenceError` | — |
| `logging_setup.py` | 結構化日誌至 **stderr**（key=val 或 JSON、TTY/NO_COLOR 感知），INFO 預設、無遮罩 | — |
| `models.py` | `InputRow`(14)、`StateRecord`(BATCH_ID+REQUEST_ID+8 payload)、`ReportRow`(4)、`Status`(Enum) | — |
| `csv_reader.py` | 讀/驗 14 欄 CSV（`newline=''`、utf-8-sig、標題精確比對、嚴格欄數、dash 正規化） | models, errors |
| `transform.py` | 過濾 NORMAL（大小寫不敏感）→ 解析 APP_TIME → 投影 9 欄（純函式） | models, errors |
| `lookup.py` | 載入 `hosp_id_map.csv.gz`→`dict[str,str]`；`get(hosp_id, "")`（IFERROR 語意） | errors |
| `dedup.py` | REQUEST_ID 跨狀態 + 批次內去重；warn-skip（內建唯一策略） | models, errors |
| `statelock.py` | 檔案鎖抽象：flock 優先，O_CREAT\|O_EXCL 備援 + stale 偵測（見 §6.6） | errors |
| `state.py` | canonical state 讀寫、原子寫、**in-file 完整性尾列**、crash-tolerant 復原、`.bak`、`runs.jsonl`、BATCH_ID 配號 | models, errors, transform, lookup, statelock |
| `aggregate.py` | 由完整 state 重算院所分析（首見序、first-HOSP、COUNT） | models |
| `xlsx_writer.py` | 建 2-sheet 純值工作簿：TEXT/datetime 型別、number_format、**最新批次黃底**、表頭樣式、檔名 | openpyxl, models |
| `pipeline.py` | 串接各階段、回傳 `RunSummary`（接受內部 `run_date` 參數供測試注入） | 全部 |

### 3.3 資料流（單向）

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

### 3.4 專案 ethos 對應

fail-fast loud（型別化例外、無 `except: pass`、邊界即拋）｜顯式型別（frozen dataclass + type hints、mypy --strict）｜stdout=結果、stderr=結構化日誌｜確定性可重放（**內部 `run_date` 參數供測試注入**、state 存原始 app_time 字串避免浮點漂移、`PYTHONHASHSEED=0`）｜最小依賴（僅 openpyxl）｜文件化。

---

## 4. 資料模型

### 4.1 輸入（analyze_access `--format csv`，14 欄；CSV 全部以 str 讀入）

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

### 4.2 調閱紀錄輸出（9 欄，交付 sheet 1；表頭精確字面 A1:I1）

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

> **模板 vs 工具寫入**：模板僅 E=`@`、DATE/TIME 為日期/時間格式、其餘為 `General`（靠 type='s' 字串保存文字）；先前所謂「全 `@`」屬 `格式轉換` sheet。本工具刻意對全部文字欄寫 `@` 為主動硬化——即使某環境重算或另存，字串欄仍鎖定文字語意，不數值化。
>
> **核心保真**：A、B 同存一個完整 `datetime`（含毫秒，如 `datetime(2026,7,5,16,3,34,359000)`），差異僅 number_format。必須指派 `datetime.datetime` 物件（非 `date`）才能保留亞秒序列。C–I 以 Python `str` 指派（openpyxl 寫 type='s'）+ number_format `@` 雙保險。

### 4.3 院所分析輸出（4 欄，交付 sheet 2；表頭 A1:D1）

| 欄 | 標題 | 計算（對映模板公式語意） | 型別 |
|----|------|--------------------------|------|
| A | `CLIENT IP` | 完整 state 的 CLIENT IP **首見順序去重**（= `UNIQUE(FILTER(...))`） | TEXT |
| B | `HOSP_ID` | 該 IP **首見 state 列**的 HOSP_ID（= `XLOOKUP(IP, 調閱紀錄!C:C, E:E)` first-match，**取自調閱紀錄自身**） | TEXT |
| C | `HOSP_ABBR` | 該 IP 首見 state 列的 HOSP_ABBR（= `XLOOKUP(..., F:F)`；可為 `""`） | TEXT |
| D | `COUNT` | 完整 state 中該 CLIENT IP 之列數（= `COUNTIF(調閱紀錄!C:C, IP)`） | NUMERIC(int) |

落地錨點見第 2.2 節。

---

## 5. 管線階段（`pipeline.py` 串接；純函式階段可單測，`state` 為唯一副作用者）

**S0 — Bootstrap**：解析 CLI → 建 `Config`（路徑正規化+校驗，防 CWE-22）；設定 stderr 結構化日誌（INFO）；決定 `run_date`（**內建 = 容器 TZ=Asia/Taipei 今日**；`pipeline.run()` 接受內部 `run_date` 參數供測試注入，CLI 不暴露旗標），作為交付檔名與「最新批次」標記基準；取得 `state/.lock`（`statelock`：flock 優先、失敗則 O_CREAT|O_EXCL 備援 + stale 偵測，見 §6.6），忙碌→`LockBusyError`（exit 4）**立即快速失敗**（不等待，內建行為）。啟動清理殘留 `*.tmp`（前次崩潰遺留；records.csv 因原子性必完整或不存在）。

**S1 — 載入參考資料**：`lookup.load(hosp_id_map.csv.gz)` → `dict[str,str]`（gzip+csv.reader 全 str，前導零保留）。健全性檢查：列數約 93k、鍵長多為 10、無重複鍵 → 異常僅 WARN（容忍主檔演進）。缺檔/不可讀 → `ReferenceError`（exit 5）。

**S2 — 載入 state（從空起步；無 seeding）**：`state.load()`：
- `records.csv` 不存在 → **視為空 state**：`existing=[]`、`existing_request_ids=set()`、`max_batch_seq=0`。首次執行即以此空 state 進行第一個真實批次（run 1 不特殊，見 §6.8）；**無 seed、無 `--seed-source`、無特殊路徑**。
- 存在 → 讀入並以 **records.csv 尾列完整性描述子**驗證（見 §6.3）；完整→正常；不完整/毀損→crash-tolerant 復原（見 §6.4），必要時 `StateIntegrityError`（exit 3）。
- 產出 `existing: list[StateRecord]`、`existing_request_ids: set[str]`、`max_batch_seq`。

**S3 — 解析 + 驗證輸入**：`csv_reader.read(INPUT)`：`open(path, newline='', encoding='utf-8-sig')`（**CRLF 輸入必須 `newline=''`，最後一欄不得殘留 `\r`**；utf-8-sig 容忍可能的 BOM，實測輸入無 BOM）；標題精確比對 14 欄名與順序（不符→`InputValidationError` exit 2，列出期望 vs 實得）；逐列嚴格 14 欄（欄數不符→帶行號拋出）；STATUS 值 `.strip().upper()` 後若非三種已知 enum→WARN+skip+計數；dash 正規化為 sentinel。**此階段不解析 datetime**。產生 `InputRow` 串流。

**S4 — 過濾 NORMAL + 解析時間**：`transform.filter_normal()` 以 `status.strip().upper() == "NORMAL"` 判定（**對齊 Excel `=` 之大小寫不敏感語意**）；記錄丟棄之 ORPHAN/UNVERIFIED 數（INFO）。此後才解析每 NORMAL 列 APP_TIME：`%Y-%m-%d %H:%M:%S.%f`（相容無毫秒 `%Y-%m-%d %H:%M:%S`）。NORMAL 列若 APP_TIME 為 `-`/不可解析，或 APP_SERVER/CLIENT_IP 缺失 → 資料契約違反 → `InputValidationError`（exit 2；只報行號+欄名）。

**S5 — 投影 + 查簡稱**：`transform.project()` 建 9 欄 payload；`app_time_iso` 存**完整字串**（DATE/TIME 唯一來源）；`hosp_abbr = lookup.get(hosp_id, "")`（IFERROR 語意；**於 ingest 當下解析並凍結入 state**，歷史列不因日後主檔變動而改寫）；累計 `unmapped_hosp_ids` 供摘要 WARN。

**S6 — 去重（vs state、批次內）**：`dedup.apply()` 以 REQUEST_ID 判定；跨 state 或批次內重複→WARN(stderr，記 REQUEST_ID + 行號)+SKIP（**內建唯一策略 warn-skip；退出碼維持 0**）；產出 `new_records` 與 `skipped_cross/intra` 計數。

**S7 — 配 BATCH_ID + 重算聚合**：本執行的 ingest 批次配號 `batch_seq = max_batch_seq + 1`（空 state → max=0 → 首批 = 1），每筆 `new_record.batch_id = batch_seq`；建 `full_state = existing + new_records`；`aggregate.build(full_state)`（首見序、first-HOSP 取自調閱紀錄自身、COUNT）。

**S8 — 寫交付 xlsx 至 .tmp**：`xlsx_writer.write(out.tmp)`：建 2 張純值 sheet（調閱紀錄=完整 state 9 欄；院所分析=4 欄）；**最新批次列（`batch_id == max(full_state 之 batch_id)`）整列上 FFFFFF00 黃底、其餘無 fill**；套型別/number_format/表頭樣式；`fsync`。

**S9 — 原子提交**（state-first，保證交付檔為已提交 state 之投影，見 §6.5）：
1. `state.commit(full_state)`：寫 `records.csv.tmp`（含 `#META` 尾列完整性描述子）→ `fsync` → 備份舊檔為 `records.csv.bak` → `os.replace`（POSIX 原子）。
2. `os.replace(out.tmp → 交付檔)`（原子落地）。
3. append 一列 `runs.jsonl`（run_utc、run_date、input_path、input_sha256、各階段計數、batch_seq、deliverable 檔名、appended request_ids）。
若 `len(new_records)==0` → 跳過 state 寫入（冪等，不擾動 .bak），仍產生反映現有 state 的交付檔（黃底落在 state 現有最新批次；空 state 則 0 列 0 黃底）。

**S10 — 摘要 + 收尾**：釋放鎖；stdout 輸出單一 JSON 摘要；依結果設退出碼。

**交付檔重建保證**：交付 xlsx 為完整 state 的純投影，**每次執行由 state 重生**，黃底恆落在最新批次（max BATCH_ID）。若 S9.2 交付檔寫失敗（罕見；同目錄 os.replace 於 fsync 後）→ 程序 exit 5 立即示警；操作者**以最近一次每週輸入重跑**（該輸入去重為 0 新增，但交付檔仍由 state 重生並正確標最新批次黃底）即可復原，**無需任何特殊指令/旗標**（見 §6.5）。

---

## 6. 持久化設計（工具自管 canonical state = single source of truth）

### 6.1 格式與位置

- 主 state：`{state_dir}/records.csv`（容器預設 `/data/state`、host 慣例 `report-export/state/`；`--state-dir` 覆寫）。UTF-8、帶表頭、`QUOTE_MINIMAL`、`\n` 換行、固定欄序；**全欄字串**，一律 `csv.reader/writer` 讀寫（全 str → 前導零永遠保留）。交付 xlsx 為其快照/檢視（每執行由 state 重生）。
- **選 CSV 而非 xlsx/JSONL 之理由**：可 git diff、人類可讀（惟末尾一列為機器完整性尾列，見 §6.3）、stdlib、無數值化風險、對齊 log-parse 專案 CSV ethos。

### 6.2 state schema（10 欄；前 2 欄為內部隱藏鍵，不進交付檔）

```
BATCH_ID, REQUEST_ID, APP_TIME_ISO, CLIENT_IP, SERVER_IP, HOSP_ID, HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT_ID_AES
```

- **10 存欄 → 9 交付欄映射**：移除 `BATCH_ID`+`REQUEST_ID`（內部鍵）、將 `APP_TIME_ISO` 展開為 `DATE`+`TIME`（同值兩格式），即得交付 9 欄。此即 USER-CONFIRMED「state 保留 REQUEST_ID 為內部鍵、交付僅顯 9 欄」的落實。
- `BATCH_ID`：整數序（字串儲存），**由 1 起算**（第 n 次 ingest = `n`；**無 SEED=0**）。**用途**：使「最新批次黃底」可由持久化 state 推導（`batch_id == max(BATCH_ID)`），令交付檔可由 state 重生（見 §6.5）。
- `REQUEST_ID`：去重自然鍵（內部；剔除於交付）。
- `APP_TIME_ISO`：保留**原始完整字串** `YYYY-MM-DD HH:MM:SS.mmm`（DATE/TIME 唯一來源），避免 Excel 浮點序列往返漂移 → 確定性。
- `HOSP_ABBR`：ingest 當下解析並凍結（歷史列不可變、可重現）。

### 6.3 完整性：**內嵌尾列**（核心）

`records.csv` 的**最後一實體列**為機器完整性描述子（非 CSV 資料列，以 `#META` 前綴辨識）：

```
#META	schema=1	records=N	last_batch_seq=M	sha256=<hex over header+all data rows>
```

- **為何內嵌而非獨立 manifest**：草稿以獨立 `state.manifest.json` 存 sha256，導致「records.csv 已 os.replace、manifest 尚未更新」的視窗——崩潰後下次載入會把**完整無誤的 state 誤判為毀損**並 exit 3，且復原 .bak 反而丟棄已提交批次。改為將 record_count + sha256 內嵌 records.csv，**單一 `os.replace` 原子涵蓋資料與其完整性描述子**，跨檔不一致視窗徹底消失（`os.replace` 保證 records.csv 永非半寫）。
- `state.manifest.json` **降為非權威性資訊 sidecar**（僅存 `schema_version`, `last_run_date`, `tool_version`, `record_count` 供人閱讀），**不再用於完整性 gating**——避免任何跨檔提交造成 brick。
- 讀取器先分離 `#META` 尾列再 csv-parse 前段；records.csv 為機器託管，文件明訂勿手改。

### 6.4 載入時 crash-tolerant 復原（完整的 state 絕不被誤判為毀損；內建、無旗標）

`state.load()` 判定序（完整性檢查恆為 on，內建）：
1. records.csv 不存在 → 空 state 起步（見 S2）。
2. **可解析且尾列存在且 sha256/records 相符** → 正常載入。
3. **可解析但尾列缺失**（如舊版/被手改）→ WARN（非致命），即時重算並在下次寫入補上尾列，繼續執行（**不 brick**）。
4. **可解析但尾列 sha256 不符**（真正竄改/損壞）→ 嘗試 `records.csv.bak`：若 .bak 通過驗證 → WARN 並以 .bak 續行；否則 `StateIntegrityError`（exit 3）。
5. **無法解析/欄數不一致** → 同 4 之 .bak 復原路徑；皆失敗 → exit 3。

**原則**：預設優先「完整 state 的可用性」，完整的 state 絕不被視為毀損。（前版之 `--strict-integrity` 嚴格模式已烘焙移除——YAGNI，目前無高保全環境的具體 use-case；容忍復原為唯一模式。）

### 6.5 黃底語意與交付檔重建（最新批次高亮；無 regenerate 旗標）

- **黃底集合 = 最新批次**：交付 xlsx 對 `batch_id == max(BATCH_ID in full_state)` 之列上黃底。此即模板「每次貼上僅標本次新增」的 per-run 重置語意——最新批次高亮、歷史批次無底。
- **提交順序（S9，state-first）**：先原子提交 state（records.csv，含新 BATCH_ID 與 `#META` 尾列），再 os.replace 交付檔。交付檔恆為「已提交 state」之純投影，**不會**出現「交付了尚未入 state 的批次」。
- **交付檔重建（取代前版 `--regenerate-last`）**：交付 xlsx 每執行由 state 重生、黃底恆落最新批次。若交付檔遺失或 S9.2 寫失敗（exit 5 立即示警）→ **以最近一次每週輸入重跑**：該輸入去重為 0 新增、max BATCH_ID 不變，交付檔重生並正確高亮最新批次。無需特殊指令。（**設計取捨**：僅支援重建「最新批次」之交付檔；重建任意歷史批次之黃底刻意不提供——YAGNI，歷史交付檔已於當週交付時由操作者存檔。）
- **冪等**：相同 `INPUT` 重跑 → 全 REQUEST_ID 已存在 → 0 新增 → state 位元不變 → 交付檔為**同一最新批次高亮**的等價檔（兩次執行「儲存格值 + 型別 + number_format + fill」相等）。此為比前版更強的交付檔冪等性質。

### 6.6 並行 / 原子性 / 權限

- **檔案鎖抽象 `statelock`**：優先 `fcntl.flock(LOCK_EX|LOCK_NB)`；**因本專案為 NAS 導向、rw 卷常掛於網路儲存，flock 於 NFSv3/CIFS 可能被模擬、降級或形同無效**，故：
  1. **主保證 = 作業層序列化**（單一維運者/cron 排程序列執行）——文件列為第一守則。
  2. flock 為 best-effort defense-in-depth；偵測到 fs 不支援（或作為可攜路徑）時改用 `O_CREAT|O_EXCL` 哨兵鎖檔，內含 `pid + host + utc`，並做 **stale 偵測**（PID 不存在或超過門檻 → WARN 後回收）。
  3. 無法可靠取得鎖 → fail-loud（`LockBusyError` exit 4，**立即失敗、不等待**），不靜默前進。
  - 文件明訂：`state_dir` 建議置於 **POSIX-local 或 NFSv4(lockd)** 檔案系統。
- **原子寫入**：tmp→fsync→`.bak`→`os.replace`；`records.csv` 之尾列使資料與完整性同一次 replace 落地。崩潰不留半寫 state。
- **備份**：內建保留單一 `records.csv.bak`（每次提交前備份舊檔；無關閉旗標），換取即時還原。
- **權限**：state_dir/out_dir 以 0700 目錄、0600 檔（`umask 077`）建立——**一般 least-privilege 檔案衛生**（非 PII 驅動；見第 14 章）。
- **成長性**：每週 × 數年 ≈ 10⁴ 列；aggregate O(n) 全掃無虞（封存/輪替列為未來項，見風險）。

### 6.7 稽核附檔 `runs.jsonl`（append-only）

每次執行一列 JSON：`{run_utc, run_date, input_path, input_sha256, rows_in, normal, dropped_nonnormal, skipped_cross, skipped_intra, appended, batch_seq, deliverable_name, appended_request_ids:[...], state_total, unique_ips, unmapped_hosp_ids}`。供冪等驗證、稽核、以及 §8.2 同日檔名消歧（比對當日 `input_sha256`）。

### 6.8 seeding 評估與決策（canonical state 從空起步）

**背景**：模板 `調閱紀錄` 目前含 19 列資料。曾評估是否在首次執行前，以一支 `export_seed.py` 將這 19 列匯出為 `seed_source.csv` 並「種入」初始 state（並以 `BATCH_ID=0` 標記、掛載 `/data/seed`、提供 `--seed-source`/`--no-seed`）。

**評估**：
- 這 19 列與 `source-log.csv` 的 19 筆 NORMAL 列**同源**（REQUEST_ID 集合相同），本質是**示範/範例資料（DEMO）**，並非真實生產歷史。
- 正常營運流程是**每週** transform → dedup → append；state 由工具自管、逐週累積。
- 因此首次執行（run 1）**並不特殊**：它只是「第一個把 NORMAL 列 append 進空 state 的批次」。

**決策：移除整個 seeding 機制**。canonical state **從空起步**（`records.csv` 不存在即空 state，`existing=[]`、`max_batch_seq=0`），自第一個真實批次開始累積。連帶移除：`export_seed.py`、seed 掛載（`/data/seed`）、`--seed-source`/`--no-seed` 旗標、`BATCH_ID=0`(SEED) 記錄、以及所有 seed 相關測試與風險。**保留**工具自管 canonical state、REQUEST_ID 去重、原子提交（僅移除 SEED 這一步）。

**歷史資料的攜入（若未來需要）**：**不需任何特殊機制**——把該段歷史 CSV（14 欄、含 REQUEST_ID 的 analyze_access 輸出）當作**一個普通的首批輸入**執行即可，經同一 S3–S9 路徑進入 state，與後續每週批次一視同仁（它自然成為 `BATCH_ID=1`）。

---

## 7. 去重設計（自然鍵 = REQUEST_ID）

### 7.1 為何用 REQUEST_ID

- 落地驗證：source-log 25 列 REQUEST_ID 全唯一，標準 UUID(36) 不透明鍵（如 `40000930-0002-7a00-b63f-84710c7967bb`），天然去重鍵。
- **交付欄約束（USER-CONFIRMED，非 PII 顧慮）**：交付「調閱紀錄」9 欄**不含 REQUEST_ID**（模板 sheet 結構如此）。故 state 層把 REQUEST_ID 當**內部隱藏鍵**保留（records.csv 第 2 欄），交付投影時剔除。

### 7.2 演算法（`dedup.apply(new_rows, existing_request_ids)`）

1. 由 state 建 `existing_request_ids: set[str]`。
2. 逐一處理本批（已過 NORMAL 過濾+投影）列，維護 `seen_in_batch: set`：
   - **批次內重複** → WARN（記 REQUEST_ID + 行號）→ skip、`skipped_intra++`。
   - **跨 state 重複** → WARN（記 REQUEST_ID + 行號）→ skip、`skipped_cross++`。
   - 否則 → 收為 `new_record`，加入 `seen_in_batch`。
3. 回傳 `(new_records, skipped_intra, skipped_cross)`；計數進 stdout 摘要與 runs.jsonl。

### 7.3 策略（內建 warn-skip；無旗標）

去重一律 `warn-skip`（fail-loud WARN 至 stderr + SKIP）。重複屬「重跑/重匯」的**預期情形**而非錯誤 → **退出碼維持 0**（摘要註記 skipped 數）。（前版 `--on-duplicate=fail`/exit 6 已烘焙移除——YAGNI；嚴格 CI 可改為斷言摘要之 `skipped_*` 計數。）

### 7.4 邊界與非鍵衝突

- REQUEST_ID 假設跨週全域唯一且穩定；若上游回收/改寫 ID → 去重可能過度/不足 → 以 `runs.jsonl`（含 input_sha256）監控、於風險記載（見 §17）。
- 空/缺 REQUEST_ID 的 NORMAL 列 → 視為輸入違規（fail-fast，exit 2），不以合成鍵掩蓋。
- CLIENT IP 對映多個相異 HOSP_ID **不影響去重**（去重只看 REQUEST_ID），但於 aggregate 觸發資料品質 WARN（見 §13-11）。

---

## 8. 交付 xlsx 產生規格（2 張純值 sheet、無公式；均經 openpyxl 3.1.5 round-trip 實測）

### 8.1 工作簿結構

- 移除 openpyxl 預設 `Sheet`；建立**恰 2 張**、順序：`調閱紀錄`(1)、`院所分析`(2)。
- **絕不**含 紀錄匯入 / 格式轉換 / HOSP_ID對照表（交付檔精簡、不夾帶 93k 主檔）；**無任何公式**（模板的 `UNIQUE/FILTER/XLOOKUP/ANCHORARRAY/COUNTIF` 為 Excel 365 動態陣列，openpyxl 無法重算，全部由 Python 預算為純值）。**唯值化優勢**：任何 Excel/LibreOffice 版本開啟皆正確、無需重算、無 spill 相容風險、檔案小。

### 8.2 檔名規則（同日消歧內建、自動；無旗標）

- 預設 `{run_date:%Y-%m-%d}_連線紀錄.xlsx`（`run_date` = 今日）。
- **同日多批消歧**：若同名檔已存在且 `runs.jsonl` 顯示當日最後一次執行之 `input_sha256` **不同**（＝真的第二個不同批次，如補跑漏週/更正重匯）→ 自動附序號 `{run_date}_連線紀錄_{seq:02d}.xlsx`（seq = 當日 ingest 次數）。相同 `input_sha256`（冪等重跑）→ 同名覆寫（確定性）。（前版 `--output-name`/`--no-clobber` 已烘焙移除——YAGNI。）
- 容器需 `LANG=C.UTF-8` 正確處理中文檔名；先寫 `.tmp`→`os.replace` 原子落地；out_dir 不存在則 `mkdir(parents=True, exist_ok=True)`。

### 8.3 Sheet 1「調閱紀錄」（1 表頭 + 完整 state N 列，依 state 順序：舊列在前、最新批次 append 在後）

表頭 A1:I1 精確字面：`DATE, TIME, CLIENT IP, SERVER IP, HOSP_ID, HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT ID AES`。逐欄（實測可還原）：
- **A(DATE)**：`cell.value = datetime.datetime(...)`（含 microsecond）；`cell.number_format = 'yyyy\-mm\-dd;@'` → data_type='d'、is_date=True。
- **B(TIME)**：`cell.value = <與 A 同一 datetime 物件>`；`cell.number_format = 'h:mm:ss;@'`。**A、B 同值、僅格式不同**。
- **C–I（文字欄）**：`cell.value = <str>`；`cell.number_format = '@'`（硬化；見 §4.2）。HOSP_ABBR 未命中寫 `""`（**回讀為 None**，測試須斷言「空或 None」）。
- **黃底（最新批次；每執行重置）**：`PatternFill(fill_type='solid', fgColor='FFFFFF00')`（**明確 8 碼 ARGB、FF 全不透明**；6 碼會被存為 alpha=00）。**僅** `batch_id == max(BATCH_ID)` 之列，對 A:I 9 格全上黃底；其餘列**不設 fill**（每執行由完整 state 重建整表 → 天然 per-run 重置）。

### 8.4 Sheet 2「院所分析」（1 表頭 + 11 唯一 IP，依首見序）

表頭 A1:D1：`CLIENT IP, HOSP_ID, HOSP_ABBR, COUNT`。
- **A,B,C**：TEXT（`str` + `@`）；HOSP_ABBR 可為 `""`。
- **D(COUNT)**：`cell.value = <int>`（NUMERIC，type='n'；number_format `General` 或 `'0'`）。
- 值由 `aggregate` 於 Python 算妥（無公式）。落地錨點見第 2.2 節。

### 8.5 表頭樣式（外觀；忠於模板但用顯式 RGB）

- 模板實測：表頭 solid 淺綠底（theme=9 tint≈0.8）；資料列無 fill；無 freeze_panes、無 auto_filter。
- 交付採：`Font(bold=True, size=12)`（bold 為可讀性微增；模板本身非 bold，屬 cosmetic）+ solid 淺綠底以**顯式 RGB `E2EFDA`**。**用顯式 RGB 而非 theme index**：實測讀 theme 色之 `fgColor.rgb` 會拋 `Values must be of type str`，theme 色亦不隨新工作簿可靠移植。
- 選配（預設關）：欄寬還原（G/I≈40 等）；freeze_panes/auto_filter 不加。

### 8.6 保真檢核（產出後自我斷言，寫入 e2e 測試）

回讀交付檔斷言：工作簿**恰 2 sheet、零公式**、無 紀錄匯入/格式轉換/HOSP_ID對照表；表頭字面精確；`A2.value == datetime(2026,7,5,16,3,34,359000)` 且 `A2.value == B2.value`（**斷言 datetime 值，不斷言浮點序列 repr**）；`'yyyy' in A2.number_format`、`'h:mm' in B2.number_format`；HOSP_ID 回讀為 `"0937010019"`（str，非 int）；未命中 HOSP_ABBR 回讀「空或 None」；COUNT 為 int；黃底僅落**最新批次**列（fgColor endswith `FFFF00`、patternType solid），其餘列無 fill。

---

## 9. 參考資料處理（HOSP_ID → HOSP_ABBR 主檔）

### 9.1 落地事實

模板 HOSP_ID對照表：93,781 筆、鍵長全為 10、531 前導零、0 重複鍵、0 空白簡稱。**絕不**在執行期用 2.3MB xlsx 查表。

### 9.2 捆綁形式（runtime；自由入映像與入庫）

`reference/hosp_id_map.csv.gz`（2 欄 `HOSP_ID,HOSP_ABBR`、UTF-8、QUOTE_MINIMAL、全 TEXT、前導零原樣；估 gzip 後 ~0.4–0.8MB）。`lookup.load()` 以 `gzip.open` + `csv.reader` 讀入 `dict[str,str]`（全 str → 前導零保留；<0.1s、記憶體 <20MB）。查詢 `dict.get(hosp_id, "")` 實現 IFERROR/XLOOKUP-not-found 語意。此檔為醫院代碼對照、可自由捆綁進映像並入庫。

### 9.3 一次性匯出工具（dev/ops，不進 runtime 映像）

- `tools/export_hosp_table.py`：讀模板 `HOSP_ID對照表`（openpyxl read_only）→ 寫 `hosp_id_map.csv.gz`（全欄轉 str）→ 產 `hosp_id_map.manifest.json`（`{source, exported_utc, row_count, sha256, key_len_hist, dup_keys, blank_abbr, tool_version}`）→ **fail-loud 驗證器**：斷言 `row_count==93781`、`dup_keys==0`、`blank_abbr==0`、`key_len_hist=={10:93781}`、`leading_zero==531`，違反則非零退出。
- （前版 `tools/export_seed.py` 已移除——見 §6.8，無 seeding。）

### 9.4 更新程序（主檔演進）

1. 取得新版主檔。2. 跑 `export_hosp_table.py` 重生 `hosp_id_map.csv.gz` + `manifest.json`。3. 檢視 manifest 差異（列數、sha256）。4. 提交入庫。5. 重建 Docker 映像（bump tag 與 `hosp-data-version` label）。**更新路徑即重建映像**（前版執行期 `--hosp-table` 熱修覆寫已烘焙移除——YAGNI；主檔更新頻率低，rebuild-redeploy 為標準做法）。執行期對未命中 HOSP_ID 累計 WARN（stale 主檔的可觀測訊號）。

### 9.5 入庫界線與可追溯基線（governance）

因**無 PII 顧慮**，資料檔可自由入庫。入庫政策如下（實際 baseline commit 由 orchestrator 執行）：

- **入庫（可追溯基線）**：
  - `template/連線紀錄模板.xlsx` — 來源模板 + 93,781 列 HOSP 參考之來源；
  - `template/source-log.csv` — e2e 輸入 fixture（25 列、CRLF、無 BOM）；
  - `reference/hosp_id_map.csv.gz` + `hosp_id_map.manifest.json` — 由模板匯出之查表；
  - **建置期產生之預期輸出 fixtures**（各 Phase 步驟產生的 expected records.csv / 交付 xlsx 值快照等）亦入庫，作為回歸基準。
- **不入庫（`.gitignore`；執行期機器產生、逐 run 變動）**：`state/`、`output/`、`inbox/`。
- **機器託管、勿用 Excel 編輯**：`hosp_id_map.csv.gz` 與 `records.csv` 含前導零鍵（如 `0937010019`）；**維運者若以 Excel 開啟編輯會數值化毀損** → 文件明訂此類檔為機器託管、勿用 Excel 直接編輯（見 §17 風險）。

---

## 10. Docker 規格（所有依賴入映像、主機零安裝；精簡、非 root、無網路、批次一次性）

### 10.1 基底映像

預設 `python:3.12-slim`（Debian slim、glibc；以 digest pin）。openpyxl 純 Python → 不需編譯工具。選項（文件註記）：`python:3.12-alpine`（musl，省 ~30MB）；`gcr.io/distroless/python3-debian12`（無 shell、攻擊面最小）作最嚴執行期。

### 10.2 多階段 build 與**可鎖定相依**

- **builder**：`FROM python:3.12-slim`；`pip install --no-cache-dir --require-hashes -r requirements.lock`。
- **requirements.lock 必須以 pip-compile / uv 產生**，同時釘選 `openpyxl==3.1.5` **與其 runtime 相依 `et_xmlfile==<ver>`**（及任何 transitive）並附 hash——`--require-hashes` 模式下解析集中**每一個**套件都須 `==` 且帶 hash，否則安裝中止。
- **runtime**：`FROM python:3.12-slim`；`COPY --from=builder` venv；`COPY src/ /app/src/`；`COPY reference/hosp_id_map.csv.gz reference/hosp_id_map.manifest.json /app/reference/`（捆綁查表，自由入映像）。
- dev 相依（pytest/coverage/ruff/mypy）置 `requirements-dev.txt`，**不進**執行期映像。build context = `report-export/`，`-f docker/Dockerfile`。

### 10.3 `.dockerignore`

排除 `template/`（2.3MB xlsx + 輸入 fixture；已入庫作基線，執行期映像不需要）、`state/`、`output/`、`inbox/`、`tests/`、`docs/`、`tools/`、`.git`、`__pycache__`。

### 10.4 寫入權限可攜性（HIGH）

- **問題**：映像固定 `USER 10001` + host bind mount 時，全新 host state/output 目錄由呼叫者（host user）擁有，UID 10001 無法寫入 → 首次寫 records.csv/xlsx 即 EACCES（exit 5）；named volume 預設 root-owned 亦然。此為典型「在作者 WSL2/Docker-Desktop（bind mount 強制 0777）可跑、在正式 RHEL 主機開箱即失敗」陷阱。
- **修正**：
  1. **所有 `docker run` 範例預設 `--user "$(id -u):$(id -g)"`**——程序以掛載目錄的擁有者身分執行，host 目錄可寫，產出檔亦歸操作者。
  2. UID/GID 以 build-arg `APP_UID`/`APP_GID`（預設 10001）可調，供標準化服務帳號的站點。
  3. 因 `--user` 可能對映無 `/etc/passwd` entry 的 uid，映像設 `ENV HOME=/tmp` 並確保 `--tmpfs /tmp` 可寫；本工具不做 pwd lookup。
  4. named volume 情境：文件提供一次性 `docker run --user 0 ... chown` 初始化步驟，或改用 `--user`。
  5. **usage.zh-TW.md 明訂 host 權限前置條件**：`state_dir`/`out_dir` 須由執行 `--user` 指定之 uid 可寫。

### 10.5 安全 / 確定性

- 非 root：建 `appuser`(UID/GID `APP_UID`/`APP_GID`)、`USER ${APP_UID}`（作為未給 `--user` 時的預設）。
- `ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONHASHSEED=0 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=Asia/Taipei HOME=/tmp`。
- OCI labels（source、version、`hosp-data-version`=manifest sha256）。無 HEALTHCHECK。
- 建議 `docker run` 加 `--network none`、`--read-only`、`--tmpfs /tmp`。CI 以 trivy 掃描；基底 digest pin。

### 10.6 Volumes

| 掛載 | 模式 | 用途 |
|------|------|------|
| `/data/input` | ro | 本批原始 14 欄 CSV |
| `/data/state` | rw | canonical state（`--state-dir` 預設指向此） |
| `/data/output` | rw | 交付 xlsx（`--out-dir` 預設指向此） |
| `/app/reference` | 映像內唯讀 | 捆綁 HOSP 查表 |

（前版 `/data/seed` 掛載已移除——無 seeding。）

### 10.7 Entrypoint / CMD 與執行範例

```
WORKDIR /app
ENV PATH="/opt/venv/bin:$PATH" PYTHONPATH=/app/src
ENTRYPOINT ["python","-m","report_export"]
CMD []
```

每週執行（單一指令；state 自動從空起步/累積，run 1 不特殊）：
```
docker run --rm --network none --read-only --tmpfs /tmp \
  --user "$(id -u):$(id -g)" -e TZ=Asia/Taipei \
  -v "$PWD/report-export/inbox:/data/input:ro" \
  -v "$PWD/report-export/state:/data/state" \
  -v "$PWD/report-export/output:/data/output" \
  report-export:1.0.0 \
  /data/input/week-2026-07-13.csv
```
容器內 `--state-dir`/`--out-dir` 預設即 `/data/state`、`/data/output`（與掛載點一致），故無需傳旗標；每週只換輸入檔即可。選配 `docker/docker-compose.yml` 預接卷（含 `--user` 註記）。

---

## 11. CLI 介面（精瘦：僅必要旗標；安全預設、非互動；stdout=結果、stderr=日誌）

指令：`report-export`（console_script）或 `python -m report_export`。

**設計規則（YAGNI）**：只有當有具體 use-case 需求時，才把行為抽成參數；否則一律烘焙為內部預設。據此僅暴露以下三項；其餘全部烘焙。

| 引數 | 預設 | 說明 |
|------|------|------|
| `INPUT`（位置引數，**必填**） | — | 本批原始 14 欄 CSV 路徑 |
| `--state-dir PATH` | 容器 `/data/state`；host `report-export/state/` | canonical state 目錄（僅在需要遷移/host 直跑時使用） |
| `--out-dir PATH` | 容器 `/data/output`；host `report-export/output/` | 交付 xlsx 目錄（僅在需要遷移/host 直跑時使用） |
| `--version` / `--help` | — | 標準 argparse |

### 11.1 烘焙為內部預設的行為（無旗標；如何運作）

| 已烘焙行為 | 內建值 / 機制 | 對應內部運作 |
|-----------|---------------|--------------|
| run_date | 今日（容器 TZ=Asia/Taipei） | `pipeline.run()` 接受 `run_date` 參數（預設 `date.today()`）；CLI 恆用今日，**測試注入固定日期**（test seam） |
| 去重策略 | `warn-skip` | 重複 REQUEST_ID → WARN+SKIP、exit 0（見 §7.3） |
| 同日檔名消歧 | 自動 | 依 `runs.jsonl` 當日 `input_sha256` 比對加序號或覆寫（見 §8.2） |
| 完整性檢查 | 恆 on（crash-tolerant） | `#META` 尾列驗證 + 容忍復原（見 §6.4） |
| `.bak` 備份 | 恆保留單一備份 | 每次提交前備份舊 records.csv（見 §6.6） |
| 交付檔重建 | 每 run 由 state 重生 | 黃底恆落最新批次；復原＝重跑最近輸入（見 §6.5，取代 regenerate 旗標） |
| 鎖等待 | 立即失敗（不等待） | 鎖忙碌 → `LockBusyError` exit 4（見 §6.6） |
| 摘要格式 | JSON 至 stdout | 單一 JSON 物件（見 §11.2） |
| 日誌層級 | INFO 至 stderr | 結構化日誌；除錯可經環境變數提升層級（非旗標、內部用） |

（相對前版移除的旗標：`--hosp-table`、`--seed-source`、`--no-seed`、`--run-date`、`--regenerate-last`、`--regenerate-batch`、`--on-duplicate`、`--output-name`、`--no-clobber`、`--dry-run`、`--lock-timeout`、`--strict-integrity`、`--no-backup`、`--summary-format`、`--log-level`/`-v`/`--quiet`。）

### 11.2 stdout 摘要（JSON，單一物件）

```json
{"deliverable":".../2026-07-15_連線紀錄.xlsx","run_date":"2026-07-15",
 "batch_seq":1,"input":".../week.csv","input_sha256":"...","rows_in":25,
 "normal":19,"dropped_nonnormal":6,"new_records":19,"skipped_cross_state":0,
 "skipped_intra_batch":0,"unknown_status_skipped":0,"state_total":19,
 "unique_ips":11,"unmapped_hosp_ids":0}
```

### 11.3 stderr（結構化日誌）

含 dedup 警告（REQUEST_ID + 行號）、unmapped HOSP_ID 警告、多 HOSP_ID 之 IP 警告（以 HOSP_IDs + IP 表述）；解析錯誤報行號 + 欄名。**無遮罩**（一般結構化日誌）。

### 11.4 退出碼（fail-fast、可區分）

`0` 成功（含 warn-skip 有跳過）｜`1` 使用/參數錯誤｜`2` 輸入/驗證錯誤（標題/欄數/型別/時間戳/編碼）｜`3` state 完整性錯誤（尾列不符且 .bak 亦壞）｜`4` 併發/鎖錯誤｜`5` 參考資料缺失或寫出/IO 錯誤。（前版 exit 6 `--on-duplicate=fail` 已移除。）

### 11.5 安全

路徑正規化並校驗 `INPUT/--state-dir/--out-dir`（防 CWE-22）。無互動提示。

---

## 12. 測試策略（pytest + coverage；mypy --strict；ruff。覆蓋率目標 ≥ 80%）

CI 階段（對齊 lint→test→analyze→build→deploy）：`ruff`(lint) → `mypy --strict`(analyze) → `pytest --cov`(test，≥80%) → `docker build` → 容器內 `--network none` 跑 E2E-1 smoke → trivy scan。所有 file-touching 於使用者核可後才進行（本工作流僅 PLAN）。

### 12.1 單元測試

- `test_csv_reader`：14 欄標題精確比對（錯序/缺欄/多欄→exit 2）；欄數不符→帶行號；**CRLF 輸入以 `newline=''` 讀取、最後一欄不得殘留 `\r`**；utf-8-sig BOM 容忍；引號內逗號；STATUS 未知值→WARN+skip。
- `test_transform`：NORMAL 過濾（25→19）；**大小寫不敏感（`Normal`/`normal`/`NORMAL` 皆納入，對齊 Excel `=`）**；投影對映；APP_TIME `…34.359`→`datetime(…,359000)`，相容無毫秒；NORMAL 列 APP_TIME=`-`→exit 2；前導零 `0937010019` 維持 str。
- `test_lookup`：`0937010019`→`秀傳醫院`、`3501200000`→`臺北虛擬診`；未命中→`""`；前導零鍵；gz 載入。
- `test_dedup`：跨 state / 批次內重複→WARN+skip；重跑同輸入→0 新增。（無 fail 模式。）
- `test_state`：寫→讀往返（APP_TIME_ISO 毫秒不漂移）；**尾列完整性：寫入後尾列 records/sha 相符；竄改 body→情況4 復原/exit 3；尾列缺失→情況3 WARN+補寫（非致命）**；原子寫入（tmp→replace、產 .bak）；**空 state 起步（無 records.csv → existing=[]、max_batch_seq=0）**；首批 `BATCH_ID=1`；權限 0600/0700；殘留 .tmp 清理；**flock 不可用時 O_CREAT|O_EXCL 備援 + stale 偵測**。
- `test_aggregate`：11 唯一 IP、首見序 == 模板 A2:A12、COUNT=[1,1,1,1,1,1,3,1,7,1,1] 合計 19；first-HOSP 取自調閱紀錄自身；多 HOSP_ID 之 IP→WARN + 取首見。
- `test_xlsx_writer`：A2==B2 datetime（非浮點序列 repr）；`'yyyy' in A2.number_format`、`'h:mm' in B2.number_format`；ID 欄回讀 str；**未命中 HOSP_ABBR 回讀空或 None**；COUNT int；黃底 `FFFFFF00`、僅 `batch_id==max(BATCH_ID)` 列、其餘列無 fill；恰 2 sheet、零公式；表頭字面精確；**同日不同 input_sha256 → 檔名加序號**。
- `test_logging`：stdout 為單一 JSON 摘要、stderr 為結構化日誌（**stream 分離**）；log record 型別/欄位正確。
- `test_pipeline` / `test_cli`：退出碼對應各例外；stdout JSON 欄位齊全；**內部 `run_date` 注入決定檔名**；精瘦 CLI 僅接受 INPUT/`--state-dir`/`--out-dir`（未知旗標→exit 1）。

### 12.2 端對端（驗收）測試

- **E2E-1（複現落地結果；空 state 首次執行）**：空 state + `INPUT=fixtures/source-log.csv`(25) → state 19 列（皆 `BATCH_ID=1`）；交付 調閱紀錄 19 資料列**全黃底**（皆最新批次）；院所分析 11 IP、COUNT 合計 19、秀傳醫院=7、臺北虛擬診=3、`10.243.129.44`=1（**證 ORPHAN 排除**）。
- **E2E-2（冪等）**：重跑同輸入 → 0 新增、19 dup 警告、state **尾列/位元不變**；兩次交付檔「儲存格值 + data_type + number_format + fill」**相等**（非 bytes，因 xlsx zip/docProps 時戳非位元組確定），黃底皆落該單一批次 19 列。
- **E2E-3（新批次；per-run 黃底重置）**：於 E2E-1 之 state（19 列 batch1）後，ingest N 筆全新 REQUEST_ID → state 19+N（新列 `BATCH_ID=2`）→ 交付**恰 N 列黃底（batch2）、19 列 batch1 無 fill**；院所分析重算。
- **E2E-4（重匯重疊）**：於 E2E-3 後，再餵 source-log(19) → 19 皆去重 → state 不變、交付黃底仍落**最新真實批次（batch2 的 N 列）**、重匯的 19 不高亮。
- **E2E-5（交付檔重建）**：ingest 一批成功提交 state 後，模擬交付檔遺失，**以最近輸入重跑**（去重 0 新增）→ 交付檔由 state 重生、正確高亮最新批次（無特殊旗標）。
- **E2E-6（crash-tolerant state）**：手動使 records.csv 尾列與 body 不一致（模擬 manifest-lag 舊模型）→ 驗證載入**不 brick**、循情況 3/4 復原。
- **不變量**：`transform(source-log NORMAL)` == 預期 19 筆 StateRecord。

### 12.3 fixtures（`tests/fixtures/`）

以入庫基線 `template/source-log.csv`（25 列、**CRLF、無 BOM**）為主 e2e 輸入（可直接引用或複製至 fixtures）；另備 `hosp_map_small.csv`（含 `0937010019` 與一未命中鍵）、`batch_new.csv`（全新 REQUEST_ID，供 E2E-3）、`empty.csv`（僅表頭）、`all_nonnormal.csv`（僅 ORPHAN/UNVERIFIED）、`status_mixed_case.csv`（含 `Normal`/`normal` 驗大小寫不敏感）。**建置期產生之預期輸出 fixtures**（expected records.csv、交付值快照）入庫作回歸基準（見 §9.5）。**決定論**：內部注入固定 `run_date`；斷言儲存格值集合而非 bytes。

---

## 13. 邊界案例

1. **空輸入（僅表頭）** → 0 NORMAL → 不追加、state 不變；空 state 首次執行仍產生反映（空）state 的交付檔（0 列、0 黃底）；exit 0 + INFO。表頭缺失/錯序才 fail-loud（exit 2）。
2. **全非 NORMAL** → 0 追加；WARN「本批 0 筆 NORMAL」；交付檔反映既有 state（黃底落現有最新批次；空 state 則 0 黃底）；exit 0。
3. **未命中 HOSP_ID** → HOSP_ABBR `""`（IFERROR）；累計 unmapped WARN；不失敗；交付檔回讀該格為 None。
4. **重複匯入（REQUEST_ID 已在 state）** → 每筆 WARN（REQUEST_ID + 行號）+SKIP；退出碼 0；完全冪等（交付檔等價，黃底落現有最新批次）。
5. **批次內重複 REQUEST_ID** → 保留首見、後續 WARN+skip。
6. **前導零/文字保留**：HOSP_ID `0937010019`、BIRTHDAY `19560711`、PRSN_ID、PATIENT_ID_AES 全程 TEXT（csv→state csv→xlsx `@`）；回讀仍為 str。
7. **毫秒時間戳**：`…34.359`→`datetime(…,359000)`，相容無毫秒；TIME 顯示僅到秒。
8. **NORMAL 列 APP_TIME=`-`/不可解析** → 契約違反 → exit 2（只報行號/欄名）。實測 dash APP_TIME 僅出現於非 NORMAL 列。
9. **ORPHAN 列（row7）** APP_TIME 有效但 API 欄 dash → 因非 NORMAL 被過濾；其 CLIENT IP（10.243.129.44）不得灌入 COUNT（該 IP COUNT=1）。
10. **首次執行（空 state）**：無 records.csv → 直接以空 state 進行第一個真實批次（`BATCH_ID=1`）；**無 seeding、無特殊路徑**（見 §6.8）。
11. **同一 CLIENT IP 對映多個相異 HOSP_ID** → 取首見列自身值（XLOOKUP first-match）並 WARN（以 HOSP_IDs + IP 表述）。
12. **毀損/被竄改 state** → 循 §6.4 crash-tolerant 復原；.bak 亦壞才 exit 3。
13. **並行執行** → statelock 阻擋（flock 或 O_EXCL 備援）；第二執行立即 exit 4；程序死亡自動釋放/stale 回收；啟動清 *.tmp。
14. **HOSP_ID 長度非 10** → 軟性 WARN，仍處理（查表多半回 `""`）。
15. **CSV 編碼/BOM/CRLF** → `newline='' + utf-8-sig`；非法位元組 `errors='strict'` → exit 2。
16. **中文交付檔名** → 容器 `LANG/LC_ALL=C.UTF-8`。
17. **接近午夜的 run_date** → 以容器 TZ=Asia/Taipei 決定業務日（內建今日；測試可注入固定日期求確定性）。
18. **同日重跑 / 同日不同批** → 相同 input_sha256 覆寫；不同 input_sha256 自動加序號（§8.2）。
19. **out-dir/state-dir 不存在** → `mkdir(parents=True, exist_ok=True)`（0700）；bind mount 掛載點權限見 §10.4。
20. **輸入精度歧異** → 現行檔為完整精度可直接用；若誤把 Excel 失真匯出（mm:ss.d）當輸入，DATE/TIME 失去亞秒 → 輸入契約須為完整精度 analyze_access 輸出（見風險）。
21. **state 長期成長（~10⁴ 列）** → aggregate O(n) 充裕；封存/分割為未來項（見風險）。
22. **交付檔寫失敗但 state 已提交** → exit 5 示警；以最近輸入重跑重建交付檔（§6.5）。

---

## 14. 安全

本工具處理**內部授權資料**；關係人確認所有資料/欄位皆可正常操作與記錄，**無特殊 PII 處理需求**。安全姿態聚焦於一般工程衛生與供應鏈/攻擊面控制，不含資料遮罩、靜態加密或合規緩解。

- **無網路**：工具零對外連線；建議 `docker run --network none`。
- **一般日誌**：`logging_setup` 為標準結構化日誌至 stderr（**無遮罩**）；stdout 僅單一 JSON 摘要，兩流分離。
- **檔案權限衛生（least privilege）**：state_dir/out_dir 以 0700 目錄、0600 檔（`umask 077`）建立——僅一般權限衛生，非資料敏感度驅動。
- **最小攻擊面**：非 root、root fs 唯讀、`--tmpfs /tmp`；依賴僅 openpyxl（`--require-hashes` 釘選含 et_xmlfile，供應鏈完整性）；**無 pickle/eval/動態反序列化**（僅 csv/json，防 CWE-502）；CI trivy 掃描、基底 digest pin。
- **路徑校驗**：正規化並校驗所有路徑引數（防 CWE-22）。
- **交付檔精簡**：交付檔刻意排除 93k 主檔與 紀錄匯入/格式轉換 sheet；REQUEST_ID/BATCH_ID 內部鍵不進交付檔（對齊模板 sheet 結構，非資料保護）。
- **輸入唯讀**：輸入 CSV 以 `/data/input:ro` 掛載，不複製進映像。
- **可自由捆綁**：`hosp_id_map.csv.gz`、`source-log.csv`、模板等參考/範例資料可自由入映像與入庫（見 §9.5）。

（相對前版移除：資料 PII 分級、BIRTHDAY 遮罩/`--mask-birthday`、CLIENT_IP 敏感化與日誌遮罩、映像 PII-free 限制、靜態加密建議、PII 保留/輪替合規注記。）

---

## 15. 目錄結構（report-export/ 之下；與 log-parse CLI 完全解耦）

```
report-export/
├─ README.md                      # 快速上手、執行指令（zh-TW）
├─ pyproject.toml                 # 套件中繼、console_script、ruff/mypy/pytest 設定
├─ requirements.lock              # 執行期鎖檔：openpyxl==3.1.5 + et_xmlfile==… + hashes（pip-compile/uv）
├─ requirements-dev.txt           # dev：pytest, coverage, ruff, mypy
├─ .gitignore                     # 僅忽略 state/ output/ inbox/（執行期機器產生）
├─ src/
│  └─ report_export/
│     ├─ __init__.py              # __version__
│     ├─ __main__.py              # python -m report_export → cli.main()
│     ├─ cli.py                   # argparse（精瘦：INPUT + --state-dir/--out-dir）、退出碼、stdout 摘要
│     ├─ config.py                # frozen Config、路徑校驗、內建預設
│     ├─ errors.py                # 型別化例外
│     ├─ logging_setup.py         # 結構化 stderr 日誌（INFO、無遮罩）
│     ├─ models.py                # InputRow(14)/StateRecord(10)/ReportRow(4)/Status Enum
│     ├─ csv_reader.py            # 讀/驗 14 欄 CSV（newline='' + utf-8-sig、嚴格欄數、dash）
│     ├─ transform.py             # 過濾 NORMAL（大小寫不敏感）+ 解析 APP_TIME + 投影 9 欄
│     ├─ lookup.py                # 載入 hosp_id_map.csv.gz→dict；get(id,"")
│     ├─ dedup.py                 # REQUEST_ID 跨狀態/批次內去重、warn-skip
│     ├─ statelock.py             # flock + O_CREAT|O_EXCL 備援 + stale 偵測
│     ├─ state.py                 # 讀寫/原子寫/in-file 尾列完整性/crash-tolerant/.bak/runs.jsonl/BATCH_ID（空起步）
│     ├─ aggregate.py             # 院所分析重算（首見序、first-HOSP、COUNT）
│     ├─ xlsx_writer.py           # 2-sheet 純值、型別/number_format、最新批次黃底、表頭、檔名（同日消歧）
│     └─ pipeline.py              # 串接各階段 → RunSummary（接受內部 run_date 參數）
├─ reference/                     # 捆綁參考資料（入庫、烘焙進映像）
│  ├─ hosp_id_map.csv.gz          # 精簡查表（全 TEXT）
│  └─ hosp_id_map.manifest.json   # sha256/rows/key_len_hist/dup/blank/exported_utc/tool_version
├─ state/                         # 執行期 canonical state（.gitignore）
│  └─ (執行後：records.csv[含尾列] / state.manifest.json[非權威] / records.csv.bak / runs.jsonl / .lock)
├─ output/                        # 執行期交付檔（.gitignore）
├─ inbox/                         # 選配：每週輸入投放區（.gitignore）
├─ tools/                         # dev/ops 一次性（不進執行期映像）
│  └─ export_hosp_table.py        # 模板 xlsx→hosp_id_map.csv.gz + manifest（fail-loud 驗證）
├─ tests/
│  ├─ conftest.py
│  ├─ fixtures/                   # source-log.csv(CRLF, 引用基線)、hosp_map_small.csv、batch_new.csv、empty.csv、all_nonnormal.csv、status_mixed_case.csv、預期輸出快照(入庫)
│  ├─ unit/                       # test_{csv_reader,transform,lookup,dedup,statelock,state,aggregate,xlsx_writer,logging,pipeline,cli}.py
│  └─ e2e/                        # test_end_to_end.py（E2E-1..6）
├─ docker/
│  ├─ Dockerfile                  # 多階段、python:3.12-slim digest pin、非 root、venv、烘焙 HOSP 查表
│  ├─ .dockerignore               # 排除 template/、state/、output/、inbox/、tests/、docs/、tools/、.git
│  └─ docker-compose.yml          # 選配：預接卷（含 --user 註記）
├─ docs/
│  ├─ design.md                   # 本設計文件（交付物；本檔）
│  ├─ usage.zh-TW.md              # CLI/Docker 使用與維運 runbook（含 host 權限前置、NAS 鎖注意）
│  └─ data-fidelity.zh-TW.md      # 型別/格式契約表（zh-TW）
└─ template/                      # 入庫基線：連線紀錄模板.xlsx + source-log.csv（.dockerignore 排除、不進映像）
```

---

## 16. 分階段建置序列（於使用者 go-ahead 後才執行；本工作流僅 PLAN）

貫穿原則：TDD（先測後實作，對齊 80% 覆蓋）；每 Phase fail-fast、顯式型別（mypy --strict）、綠燈後才進下一階段；所有 file-touching 於使用者核可後才進行。**Phase 0 先完成入庫基線**（`template/source-log.csv`、`template/連線紀錄模板.xlsx`）；後續各 Phase 產生之預期輸出 fixtures 隨該 Phase 一併入庫（實際 commit 由 orchestrator 執行）。

| Phase | 內容 | 綠燈準則 / 產出 |
|-------|------|------------------|
| **0. 骨架 + 基線** | pyproject / requirements.lock / requirements-dev；package 骨架；`errors`、`models`、`config`、`logging_setup`。確認 `template/` 兩檔入庫基線。 | ruff+mypy 綠；`config` 路徑校驗單測過；基線檔入庫。 |
| **1. 參考資料** | `tools/export_hosp_table.py` → 產 `hosp_id_map.csv.gz` + manifest（fail-loud 驗證 93781/0 dup/0 blank/531 lz）；`lookup.py`。 | 匯出驗證器通過；`test_lookup` 綠（`0937010019→秀傳醫院`）；查表 gz 入庫。 |
| **2. 讀取 + 轉換** | `csv_reader`（newline=''、utf-8-sig、嚴格 14 欄）；`transform`（NORMAL 大小寫不敏感、APP_TIME 解析、投影 9 欄）。 | `test_csv_reader`/`test_transform` 綠；25→19 不變量；CRLF 尾欄無 `\r`。 |
| **3. 去重 + state** | `dedup`（warn-skip）；`statelock`（flock + O_EXCL + stale）；`state`（空起步、`#META` 尾列、原子寫、.bak、runs.jsonl、BATCH_ID 由 1 起）。 | `test_dedup`/`test_state` 綠；空 state 起步、首批 BATCH_ID=1；crash-tolerant 復原（情況 3/4）。 |
| **4. 聚合 + xlsx** | `aggregate`（首見序、first-HOSP、COUNT）；`xlsx_writer`（2 sheet 純值、型別/numFmt、最新批次黃底、表頭 RGB、同日消歧）。 | `test_aggregate`（COUNT=[…]=19）/`test_xlsx_writer` 綠；§8.6 保真斷言全過。 |
| **5. 管線 + CLI** | `pipeline`（串接、接受內部 run_date）；`cli`（精瘦：INPUT + --state-dir/--out-dir、退出碼、stdout JSON）。 | `test_pipeline`/`test_cli` 綠；退出碼對應例外；未知旗標→exit 1。 |
| **6. E2E + 預期輸出入庫** | `tests/e2e/`（E2E-1..6）；產生並入庫預期輸出快照。 | E2E-1..6 全綠；coverage ≥ 80%；預期輸出 fixtures 入庫。 |
| **7. Docker** | 多階段 Dockerfile（digest pin、非 root、`--user` 可攜、烘焙查表）；.dockerignore；compose（選配）。 | `docker build` 成功；容器內 `--network none --user $(id -u):$(id -g)` 跑 E2E-1 smoke 綠；trivy 掃描。 |
| **8. 文件** | `docs/design.md`（本檔）、`usage.zh-TW.md`（含 host 權限前置、NAS 鎖）、`data-fidelity.zh-TW.md`、`README.md`。 | 文件與程式行為一致；runbook 可依樣執行。 |

---

## 17. 開放風險

| # | 風險 | 說明 | 緩解 |
|---|------|------|------|
| R1 | **去重鍵穩定性** | 若上游回收/改寫 REQUEST_ID，去重可能過度（漏收）或不足（重收） | 以 `runs.jsonl`（含 input_sha256、appended_request_ids）監控；REQUEST_ID 為 UUID 假設跨週全域唯一；異常於稽核附檔可追。 |
| R2 | **HOSP 主檔陳舊** | 捆綁 `hosp_id_map.csv.gz` 為建置時快照；新醫院代碼在重建映像前查不到 | 執行期對未命中 HOSP_ID 累計 WARN（可觀測訊號）；未命中→HOSP_ABBR `""`（IFERROR 語意、不失敗）；更新＝重跑 export + 重建映像（§9.4）。 |
| R3 | **NAS 鎖可靠性** | flock 於 NFSv3/CIFS 可能失效 → 兩程序同時「持鎖」互毀 state | 主保證改為**作業層序列化**（cron/單一維運者）；flock best-effort + O_EXCL 哨兵 + stale 偵測；無法可靠取鎖→fail-loud（exit 4）；state_dir 建議置 POSIX-local/NFSv4(lockd)。 |
| R4 | **datetime 亞秒捨入** | Excel 以浮點序列存 datetime，亞秒往返可能漂移 | state 以 `APP_TIME_ISO` 存**原始完整字串**（非序列），每 run 由字串重建 datetime → 確定性；測試斷言 `datetime` 值（非序列 repr）。 |
| R5 | **交付為值非公式** | 交付 xlsx 為預算純值、無 UNIQUE/FILTER/XLOOKUP 公式 | 為刻意設計（唯值化 → 跨版本可開、無 spill 相容風險）；聚合語意於 Python 精確重現並經 §8.6/§2.2 錨點驗證。 |
| R6 | **輸入 schema 飄移** | analyze_access 若改欄名/欄序/精度，契約破裂 | 標題精確 14 欄比對（不符→exit 2）；輸入契約明訂為完整精度 analyze_access 輸出；schema 版本可於未來擴充。 |
| R7 | **records.csv 非供 Excel 編輯** | 含前導零鍵（`0937010019`），維運者以 Excel 開啟會數值化毀損；且末列 `#META` 為機器完整性描述子 | 文件明訂為機器託管、勿用 Excel 編輯（§9.5）；state 為 CSV 便於 git diff/程式讀寫，非人手編輯介面。 |
| R8 | **state 長期成長** | 每週累積，數年後 ~10⁴ 列 | aggregate O(n) 全掃於此量級充裕；封存/輪替/分割列為未來項（目前不預先實作，YAGNI）。 |

---

## 18. 評審意見處置對照（逐條：修正 / 說明 / 因新決策作廢）

### CRITIQUE 1（fidelity，全 LOW；均經本次實測確認為事實正確）

| # | 議題 | 處置 |
|---|------|------|
| C1-1 | data_model 表 B number_format 標「模板實測」全 `@` 有誤（調閱紀錄實測僅 E=`@`、其餘 General；全 `@` 屬 格式轉換） | **修正**：§2.4、§4.2 分「模板 調閱紀錄 實測」與「工具寫入(設計)」兩欄；工具刻意對文字欄寫 `@` 為主動硬化。 |
| C1-2 | NORMAL 過濾大小寫語意：Excel `=` 不敏感，Python `==` 敏感 | **修正**：§5 S4、§12 明訂 `status.strip().upper()=="NORMAL"`；`status_mixed_case.csv` fixture 測試。 |
| C1-3 | CRLF 輸入未指定 `newline=''`（source-log.csv 實測 CRLF、無 BOM） | **修正**：§5 S3、§12/§13 明訂 `open(path, newline='', encoding='utf-8-sig')`；「最後一欄不得殘留 `\r`」斷言。 |
| C1-4 | BIRTHDAY「前導零顯著」理由不精確（紀錄匯入 N 為 int、永無前導零） | **修正**：§2.7、§4.1 更正 TEXT 理由為「防數值/日期強制轉型 + 對齊模板文字輸出」；前導零顯著限定 HOSP_ID。 |

### CRITIQUE 2（ops/pii）

| # | 嚴重度 | 議題 | 處置 |
|---|--------|------|------|
| C2-1 | HIGH | 跨檔提交非原子（records.csv 與 manifest 分兩次 replace）→ 崩潰後完整 state 被誤判毀損而 brick | **修正（保留）**：§6.3 完整性描述子**內嵌 records.csv 尾列**，單一 os.replace 原子涵蓋；§6.4 crash-tolerant 復原（尾列缺失→WARN+補寫；不符→.bak→皆壞才 exit 3）。（前版 `--strict-integrity` 嚴格模式已烘焙移除——YAGNI。） |
| C2-2 | HIGH | 映像固定 USER 10001 + bind mount → 正式 RHEL 主機首次寫入 EACCES | **修正（保留）**：§10.4 所有 run 範例預設 `--user "$(id -u):$(id -g)"`；UID/GID build-arg 可調；`HOME=/tmp` + `--tmpfs /tmp`；usage 明訂 host 權限前置。 |
| C2-3 | HIGH | 預設把含 PII 的 seed_source.csv 烘焙進映像 | **作廢（superseded）**：關係人確認**無 PII 顧慮**（§0.1、§14），且 **seeding 已整體移除**（§6.8）——本議題不再適用；映像自由捆綁非機密參考資料。 |
| C2-4 | MED | 黃底來自記憶體 delta 且 state 先於 xlsx 提交 → xlsx 失敗後重跑黃底遺失 | **修正（改設計）**：§6.2/§6.5 黃底改由持久化 `BATCH_ID` 推導、**恆落最新批次（max BATCH_ID）**；交付檔每 run 由 state 重生；復原＝以最近輸入重跑（去重 0 新增仍正確重建），**取代前版 `--regenerate-last`**（該旗標已移除——YAGNI）。E2E-5 覆蓋。 |
| C2-5 | MED | 內部矛盾：CLIENT_IP 列為敏感卻寫入 stderr 警告（CWE-532） | **作廢（superseded）**：**無 PII 顧慮**（§14），CLIENT_IP 非敏感、日誌**無遮罩**；矛盾消失，dedup/aggregate 警告可正常記錄 IP。 |
| C2-6 | MED | flock 於 NFS/CIFS 不可靠（本專案 NAS 導向） | **修正（保留）**：§6.6 `statelock`——flock 優先、O_EXCL 備援 + stale 偵測；主保證改為作業層序列化；無法可靠取鎖→fail-loud（exit 4，立即失敗，`--lock-timeout` 已移除）。見 R3。 |
| C2-7 | MED | 檔名僅 run_date + 靜默覆寫 → 同日兩個不同批次互相覆寫 | **修正（保留、烘焙）**：§8.2 同日若 input_sha256 不同→自動附序號 `_NN`；相同→冪等覆寫。（前版 `--output-name`/`--no-clobber` 已烘焙移除——自動消歧為唯一行為。） |
| C2-8 | LOW | `--require-hashes` 下僅 pin openpyxl 會因缺 et_xmlfile 的 pin/hash 而安裝失敗 | **修正（保留）**：§10.2 改用 `requirements.lock`（pip-compile/uv 產生，openpyxl + et_xmlfile + 全 transitive 皆 == 且帶 hash）。 |
| C2-9 | LOW | 首次執行 seed + input 兩次 append 若走同填色路徑會誤標歷史 19 列 | **作廢（removed）**：**seeding 已整體移除**（§6.8）；不存在 seed 批次。空 state 首次執行即單一真實批次（`BATCH_ID=1`），全列同屬最新批次、全黃底（E2E-1），無誤標問題。 |