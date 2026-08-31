# report-export — 資料型別與格式契約（data-fidelity.md）

> 本文件是型別／格式的**單一真實來源對照表**：輸入 14 欄 → state 10 欄 →
> 交付 8+5 欄，逐欄列出型別、number_format、與保真理由。完整設計推導見
> [`design.md`](design.md) §1.5 保真基準錨點、§3.1 資料模型；操作手冊見
> [`usage.md`](usage.md)。技術名詞、程式識別字、sheet 名稱一律
> 保留原文。
>
> 全文所有數字/欄位均已對照實作原始碼（`src/report_export/`）與一次真實
> 執行（`template/source-log.csv` → 交付 xlsx）逐項核對，非僅轉述設計文件。

---

## 1. 三層資料流總覽

```
輸入 CSV（14 欄，analyze_access --format csv 契約）
        │  csv_reader（讀入，全 str）→ transform（過濾 NORMAL + 驗證 + 投影）
        ▼
state 層 records.csv（10 欄：2 內部鍵 + 8 payload；累積、持久化）
        │  aggregate（由完整 state 重算 院所分析）
        ▼
交付 xlsx（2 sheet：調閱紀錄 8 欄、院所分析 5 欄；純值、無公式）
```

三層欄數差異的原因：

- 14 → 8 payload：REGION、API_TIME、DELTA_SEC、VERIFY_STATUS、API_SERVER
  五欄在 state/交付從未使用（僅供驗證或人工追蹤，設計文件 §3.1.1）。
- 8 payload + 2 內部鍵 = state 10 欄：`BATCH_ID`、`REQUEST_ID` 是**內部隱藏
  鍵**（去重自然鍵 + 最新批次高亮依據），存於 `records.csv` 但**永不**進
  交付檔。
- state 10 欄 → 交付 8 欄：移除 `BATCH_ID`+`REQUEST_ID`（內部鍵）與
  `BIRTHDAY`（交付不輸出，見 §4.1），並將 `APP_TIME_ISO` 一欄**展開為
  DATE+TIME 兩欄**（同一個 `datetime` 值、兩種 number_format）。
- 交付另有 院所分析 5 欄（CLIENT IP, HOSP_ID, HOSP_ABBR, WEEKLY ACCESS,
  TOTAL ACCESS），是由完整 state**重新聚合**而來（非欄位映射）。

---

## 2. 輸入層（14 欄，`analyze_access --format csv` 契約）

CSV 全部以 `str` 讀入（`csv_reader.py`：`csv.reader`，從不用會做型別推斷的
`csv.DictReader`/pandas）。標題**逐字逐序**比對，不符即 `InputValidationError`
（exit 2）。

| 欄 | 欄名 | 型別／格式 | 用途 | 交付對映 |
|----|------|-----------|------|----------|
| A | `REGION` | TEXT（如 台北/台中） | 不使用 | — |
| B | `STATUS` | TEXT enum：`NORMAL`／`ORPHAN`／`UNVERIFIED` | **過濾鍵**（僅留 NORMAL；`.strip().upper()` 比對，大小寫不敏感） | — |
| C | `API_TIME` | `YYYY-MM-DD HH:MM:SS.mmm` 或 `-` | 不使用 | — |
| D | `APP_TIME` | `YYYY-MM-DD HH:MM:SS.mmm`（NORMAL 列必要；相容無毫秒） | **DATE 與 TIME 唯一來源** | → DATE + TIME |
| E | `DELTA_SEC` | 數字或 `-` | 不使用 | — |
| F | `VERIFY_STATUS` | TEXT（`OK` / `-`） | 不使用 | — |
| G | `REQUEST_ID` | TEXT，UUID(36) | **去重自然鍵**（內部；不進交付） | state 內部鍵 |
| H | `API_SERVER` | TEXT IP 或 `-` | 不使用 | — |
| I | `APP_SERVER` | TEXT IP | 必要（缺值→exit 2） | → SERVER IP |
| J | `HOSP_ID` | TEXT，**前導零顯著**（如 `0937010019`，長度全為 10） | 主檔查表鍵 | → HOSP_ID + 查表出 HOSP_ABBR |
| K | `PRSN_ID` | TEXT，hex32 | — | → PRSN_ID |
| L | `CLIENT_IP` | TEXT IP | 必要（缺值→exit 2）；聚合鍵 | → CLIENT IP |
| M | `PATIENT_ID_AES` | TEXT，hex32（已加密） | — | → PATIENT ID AES |
| N | `BIRTHDAY` | TEXT，`YYYYMMDD`(8)，如 `19560711` | — | → records.csv state（**交付不輸出**，見 §4.1） |

**csv_reader / transform 實際執行的驗證**（`src/report_export/csv_reader.py`、
`transform.py`）：

- 標題 14 欄名稱＋順序精確比對；否則 `InputValidationError`（exit 2，訊息
  列出 expected vs got）。
- 每筆資料列欄數必須恰為 14；否則帶行號 `InputValidationError`（exit 2）。
- `STATUS` 正規化 (`.strip().upper()`) 後若不在 `NORMAL/ORPHAN/UNVERIFIED`
  三者之一 → WARN + 跳過該列（計入摘要 `unknown_status_skipped`），**不**
  中止整批。
- NORMAL 列的 `APP_TIME` 為 `-`／空白／無法以兩種既定格式解析 → `InputValidationError`（exit 2，僅報行號＋欄名，不回顯欄值）。
- NORMAL 列的 `APP_SERVER`／`CLIENT_IP` 為 `-`／空白 → 同上，`InputValidationError`（exit 2）。
- NORMAL 列的 `REQUEST_ID` 為 `-`／空白 → 同上，`InputValidationError`（exit 2，不以空字串／合成鍵掩蓋，對齊 `design.md` §3.4.4）。

---

## 3. state 層（`records.csv`，10 欄）

```
BATCH_ID, REQUEST_ID, APP_TIME_ISO, CLIENT_IP, SERVER_IP, HOSP_ID, HOSP_ABBR, PRSN_ID, BIRTHDAY, PATIENT_ID_AES
```

| 欄 | 型別（CSV 儲存） | 說明 |
|----|-------------------|------|
| `BATCH_ID` | 整數的字串表示，**由 1 起算** | 本列所屬批次序號；決定交付檔哪些列上黃底（見 §6）。無 seeding、無 0 號批次。 |
| `REQUEST_ID` | TEXT | 去重自然鍵；**內部鍵，不進交付**。 |
| `APP_TIME_ISO` | TEXT，**原始完整字串**（如 `2026-07-05 16:03:34.359`） | 刻意**不**存已解析的 `datetime`／Excel 序列值——避免每次寫入都重新解析/重算造成的浮點漂移；xlsx_writer 在**每次寫交付檔時重新 parse** 這個字串。 |
| `CLIENT_IP` | TEXT | 院所分析聚合鍵。 |
| `SERVER_IP` | TEXT | 原樣保留。 |
| `HOSP_ID` | TEXT，前導零顯著 | 原樣保留（如 `0937010019`）。 |
| `HOSP_ABBR` | TEXT，可為空字串 | **於 ingest 當下解析並凍結**（`hosp_table.get(hosp_id, "")`，IFERROR 語意）；日後參考主檔更新**不會**回頭改寫已入 state 的歷史列。 |
| `PRSN_ID` | TEXT，hex32 | 原樣保留。 |
| `BIRTHDAY` | TEXT，`YYYYMMDD`(8) | 原樣保留為文字（理由見 §5）。 |
| `PATIENT_ID_AES` | TEXT，hex32 | 原樣保留。 |

儲存細節（`src/report_export/state.py`）：UTF-8、`\n` 換行、
`csv.QUOTE_MINIMAL`、**全欄一律字串讀寫**（從不用會做型別推斷的
API）。最後一實體列是機器完整性描述子 `#META\tschema=1\trecords=N\t
last_batch_seq=M\tsha256=<hex>`（涵蓋表頭+全部資料列的 sha256）——這
不是資料列，讀取器會先切掉它再解析本體（見
[`usage.md`](usage.md)「`state_dir` / `out_dir` 檔案總覽」一節與本文
件 §8）。

---

## 4. 交付層（xlsx，2 sheet，恰 2 張、零公式）

工作簿只含 `調閱紀錄`、`院所分析` 兩張 sheet（順序固定），不含
`紀錄匯入`／`格式轉換`／`HOSP_ID對照表`，也不含 openpyxl 預設的
`Sheet`。每一格都是 Python 直接算好的字面值（`datetime`／`str`／`int`），
**沒有任何公式字串**——模板的 `UNIQUE`/`FILTER`/`XLOOKUP`/`ANCHORARRAY`/
`COUNTIF` 動態陣列公式，由 Python 於寫檔前全部預先算成純值（design.md
§3.7.1、§8 R5）。

### 4.1 Sheet 1「調閱紀錄」（1 表頭 + 完整 state N 列；舊列在前、本次新批次接在最後）

表頭字面（A1:H1）：`DATE, TIME, CLIENT IP, SERVER IP, HOSP_ID, HOSP_ABBR,
PRSN_ID, PATIENT ID AES`

| 欄 | 標題 | 來源 | 值型別 | 工具寫入 number_format | 模板 調閱紀錄 實測 |
|----|------|------|--------|--------------------------|---------------------|
| A | `DATE` | `APP_TIME_ISO`（重新 parse） | `datetime`（含 microsecond） | `yyyy\-mm\-dd;@` | `yyyy\-mm\-dd;@`（一致） |
| B | `TIME` | 與 A **同一個** `datetime` 物件 | `datetime`（與 A 同值） | `h:mm:ss;@` | `h:mm:ss;@`（一致） |
| C | `CLIENT IP` | `CLIENT_IP` | `str`（type='s'） | `@` | `General`（見下方說明） |
| D | `SERVER IP` | `SERVER_IP` | `str` | `@` | `General` |
| E | `HOSP_ID` | `HOSP_ID` | `str` | `@` | `@`（一致） |
| F | `HOSP_ABBR` | `HOSP_ABBR`（未命中為 `""`） | `str` | `@` | `General` |
| G | `PRSN_ID` | `PRSN_ID` | `str` | `@` | `General` |
| H | `PATIENT ID AES` | `PATIENT_ID_AES` | `str` | `@` | `General` |

> **BIRTHDAY 不進交付**：BIRTHDAY 雖完整保留於 records.csv state（見 §3），
> 但**不投影至交付 xlsx**；原 H 欄移除、PATIENT ID AES 左移為 H。

**黃底（最新批次高亮）**：`batch_id == max(BATCH_ID in 完整 state)` 的列，
A:H 八格整列套用 `PatternFill(fill_type='solid', fgColor='FFFFFF00')`；
其餘列**不設 fill**。每次執行都由完整 state **重新計算整表**，因此天然
具備「每次執行僅標本次新增」的 per-run 重置語意（不是記憶體 delta、不是
累加標記）。

**表頭樣式**：`Font(bold=True, size=12)` + 顯式 RGB
`PatternFill(fill_type='solid', fgColor='FFE2EFDA')`（淺綠，非 bold；
bold 是本工具附加的可讀性微調）。

### 4.2 Sheet 2「院所分析」（1 表頭 + 每唯一 CLIENT IP 一列，依首見序）

表頭字面（A1:E1）：`CLIENT IP, HOSP_ID, HOSP_ABBR, WEEKLY ACCESS, TOTAL ACCESS`

| 欄 | 標題 | 計算語意 | 型別 | number_format |
|----|------|----------|------|----------------|
| A | `CLIENT IP` | 完整 state 之 CLIENT IP **首見順序去重** | `str` | `@` |
| B | `HOSP_ID` | 該 IP **首見列**（調閱紀錄自身）之 HOSP_ID | `str` | `@` |
| C | `HOSP_ABBR` | 該 IP 首見列之 HOSP_ABBR（可為 `""`） | `str` | `@` |
| D | `WEEKLY ACCESS` | 該 IP 於**最新批次**（`batch_id == max(BATCH_ID)`）之列數；0 → render `-` | `int` 或 `-`（本週無存取） | `General`；`-` 時為 `@` |
| E | `TOTAL ACCESS` | 完整 state 中該 CLIENT IP 之列數（即模板單一 COUNT 欄） | `int`（type='n'） | `General` |

**關鍵語意**：B/C 欄是對「調閱紀錄自身」以 CLIENT IP 做 first-match 查找
（對映模板 `XLOOKUP(IP, 調閱紀錄!C:C, 調閱紀錄!E:E)`），**不是**再查
93,781 列的 HOSP_ID對照表主檔。一個 CLIENT IP 若對映到多個不同 HOSP_ID，
取首見列的值，並記一筆 WARNING（含該 IP 與全部相異 HOSP_ID 清單）——資料
品質訊號，不會失敗。D、E 兩欄是本工具在模板單一 COUNT 語意之上的增強
（模板本身無 WEEKLY/TOTAL 之分）；單一批次（如首次執行）時 D==E，恆無
`-`；多批次時 D 僅計最新批次、E 恆計全 state（見 §6 落地錨點）。

**呈現層設定（不影響值/型別保真）**：兩張交付 sheet 全表儲存格皆
`Alignment(horizontal='center', vertical='center')`；每一資料格四面
`Border(style='thin')`；表頭每格 `Border(bottom=Side('thick'),
left/right/top=Side('thin'))`；各欄寬依現有資料＋表頭字串顯示寬度（CJK/
全形計 2）自動 ×1.2 動態設定（非硬編常數）。以上四項純屬呈現層外觀，與
本文件逐欄記載的值／型別／number_format／fill 保真**完全獨立、互不影
響**（design.md §3.7.3-§3.7.6）。

---

## 5. TEXT／datetime／int 型別理由分類

| 欄位 | 型別 | 理由 |
|------|------|------|
| `HOSP_ID` | TEXT | **前導零顯著**：93,781 列主檔中 531 列鍵值以 `0` 開頭（如 `0937010019`）。若被當數字讀入，前導零會被靜默丟棄 → 主檔查表 miss → HOSP_ABBR 錯誤地解析為空，即使主檔其實有該鍵。 |
| `PRSN_ID` / `PATIENT_ID_AES` | TEXT | hex32 不透明識別碼，可能含前導零的 hex 位元；本質非算術量，任何情況都不該數值化。 |
| `BIRTHDAY` | TEXT | **不是**前導零理由（來源 `紀錄匯入` sheet 實測以 `int` 儲存，19 列全為 19xx、永不以 0 開頭）。真正理由是**防止被強制轉型為數字或日期序列**，並對齊模板 `調閱紀錄` 本身即以文字形式儲存 BIRTHDAY 的既有語意。（本欄僅存於 records.csv state；交付 xlsx 已不輸出 BIRTHDAY，見 §4.1。） |
| `CLIENT_IP` / `REQUEST_ID` | TEXT | 內含點號／連字號，本質非數值，即使無前導零疑慮也理當存文字。 |
| `DATE` / `TIME` | `datetime` | 全交付檔**唯二**的 datetime 型別欄。A、B 存同一個 Python `datetime` 物件（含 microsecond），差異僅 `number_format`——刻意如此設計，讓 `A2.value == B2.value` 成為**保證**的往返不變量，而非兩次獨立解析可能各自漂移的結果。 |
| `WEEKLY ACCESS` / `TOTAL ACCESS` | `int`（`type='n'`，`General`） | 全交付檔**唯二**的整數型別欄；由 Python 於 `aggregate.build()` 算妥，非公式。`WEEKLY ACCESS` 於本週 0 存取時改 render 為 `-`（`type='s'`，`@`）——模型欄位本身仍是 `int`（`weekly_access=0`），是否顯示 `-` 純屬 xlsx_writer 的呈現層決策。 |

**模板 vs 本工具寫入的 number_format 差異**：模板 `調閱紀錄` 實測僅 E
（HOSP_ID）欄硬化為 `@`，其餘文字欄是 `General`——僅靠儲存格本身的字串
型別（`type='s'`）避免數值化。本工具刻意對**全部**文字欄（C–I）都寫
`@`，比模板本身更保守：即使未來某個環境重新開啟、重算或另存，字串欄仍
被 number_format 鎖定為文字語意，不會被動地依賴「型別剛好還是字串」這件
事本身。

---

## 6. 落地錨點（Anchors；以 `template/source-log.csv` 為輸入之真實執行結果）

**列數流（e2e 不變量）**：22 輸入列（NORMAL 16 / ORPHAN 1 / UNVERIFIED 5）
→ `調閱紀錄` **16** 列 → `院所分析` **10** 個唯一 CLIENT IP。

**院所分析（首見序，TOTAL ACCESS 合計 16）**：單一批次首次執行（16 列皆
`BATCH_ID=1`）時 `WEEKLY ACCESS` 每列皆等於下表 `TOTAL ACCESS`，無 `-`
出現；多批次案例見 [`usage.md`](usage.md)「開箱即用快速驗證」一節。

| # | CLIENT IP | HOSP_ID | HOSP_ABBR | TOTAL ACCESS（單一批次時 WEEKLY 亦同此值） |
|---|-----------|---------|-----------|-------|
| 1 | 10.243.129.44 | 1145010038 | 門諾醫院 | 1 |
| 2 | 10.249.8.10 | 1101150011 | 新光醫院 | 1 |
| 3 | 10.249.10.249 | 1301170017 | 台北醫大 | 1 |
| 4 | 10.238.3.1 | 1532061065 | 大園敏盛 | 1 |
| 5 | 10.241.189.173 | 3831014971 | 晨軒中醫 | 1 |
| 6 | 10.241.93.164 | 1111060015 | 基隆長庚 | 1 |
| 7 | 10.251.166.61 | 3505070032 | 誼仁診所 | 1 |
| 8 | 10.245.1.125 | 0937010019 | 秀傳醫院 | **7** |
| 9 | 10.245.11.141 | 1137080017 | 彰基二林醫 | 1 |
| 10 | 10.238.23.241 | 1503190020 | 長安醫院 | 1 |

`10.243.129.44` 的 TOTAL ACCESS=1 證明 ORPHAN 列（row 7，與此 IP 共用同一
CLIENT_IP 但 STATUS≠NORMAL）被正確排除於聚合之外；若誤含則該值會變成 2。

以上數值已於本次文件撰寫時，以實際 `python -m report_export` 執行
`template/source-log.csv`（空 state 起步）並用 openpyxl 回讀交付檔重新
核對，與 `design.md` §1.5.1/§1.5.2 記載完全一致。

---

## 7. openpyxl round-trip 行為（測試斷言依據）

寫入交付檔時必須考量的 openpyxl 3.1.5 實際落地行為（全部已在
`tests/unit/test_xlsx_writer.py`、`tests/e2e/test_end_to_end.py` 中斷言）：

- 前導零字串（`"0937010019"`、`"19560711"`）以 Python `str` 指派 → 維持
  `type='s'`，前導零原樣回讀。**前提**：程式必須指派 `str`，而非讓
  openpyxl／Excel 自行猜型別。
- 同一個 `datetime` 物件寫入 A、B 兩格（僅 number_format 不同）→ 回讀
  `A2.value == B2.value` 為 `True`。測試斷言的是 **datetime 值**，不是
  浮點序列 repr。
- `int`（WEEKLY ACCESS / TOTAL ACCESS）寫入 → 回讀 `type='n'`。WEEKLY
  ACCESS 為 `-`（本週無存取，字串）寫入 → 回讀 `type='s'`，
  `number_format=='@'`。
- 寫入空字串 `""`（HOSP_ABBR 未命中）→ **回讀為 `None`**（openpyxl 對空
  字串的正規化行為）。任何檢查／測試都必須斷言「空字串或 None」，**不可**
  嚴格斷言 `== ""`，否則會在未命中案例上誤判失敗。
- 6 碼填色字串（如 `'FFFF00'`）會被 openpyxl 存成 `'00FFFF00'`（alpha 補
  `00`＝完全透明，Excel 中不可見）。本工具一律使用**明確 8 碼 ARGB**（`FF`
  開頭代表完全不透明）：黃底寫 `'FFFFFF00'`、表頭底色寫 `'FFE2EFDA'`，
  避開「6 碼字串被靜默補上透明 alpha」這個陷阱。
- 讀取 **theme 色**（而非顯式 RGB）之 `fgColor.rgb` 會拋
  `Values must be of type str`（已實測）；且 theme 色不保證能可靠移植到
  新工作簿。因此本工具的表頭填色一律用顯式 RGB，不用 theme index。

---

## 8. 機器託管檔案 — 請勿用 Excel 編輯

以下檔案由本工具的程式碼**獨佔寫入**，一律透過 `csv`/`gzip`/`json`
模組讀寫，**絕不**應以 Excel／LibreOffice 等試算表軟體開啟並「儲存」：

| 檔案 | 由誰產生 | 為何不能用 Excel 編輯 |
|------|----------|------------------------|
| `{state_dir}/records.csv` | `state.commit()`（每次執行） | 含前導零顯著鍵（`HOSP_ID` 如 `0937010019`）；Excel 開啟 CSV 預設會將該欄數值化，存檔即永久丟失前導零。檔案**最後一實體列**是機器完整性描述子 `#META\t...`（見 §3），非資料列；Excel 存檔不保證保留其精確位元組格式，可能觸發下次載入時的完整性 WARN／`.bak` 復原，甚至 `StateIntegrityError`（exit 3，見 [`usage.md`](usage.md)「復原（Recovery Runbook）」一節）。 |
| `reference/hosp_id_map.csv.gz` | `tools/export_hosp_table.py`（一次性 dev/ops 工具，見 §3.3） | 同樣含前導零顯著鍵；且是 gzip 壓縮檔，Excel 無法直接開啟／編輯。**正確更新方式**是重跑匯出工具，見 [`usage.md`](usage.md) 的「參考主檔更新程序」，絕非手動編輯。 |
| `reference/hosp_id_map.manifest.json` | 同上 | 人類可讀的匯出報告（sha256／列數／前導零計數等），由匯出工具的 fail-loud 驗證器一併產生；手改沒有意義，且會與實際 `.csv.gz` 內容不同步。 |

若真的需要人工檢視這些檔案的內容，用純文字編輯器或 `zcat`/`gunzip -c`
即可安全開啟且不落地任何變更；**絕對不要用 Excel「開啟並儲存」**。

---

## 9. 參照

- 型別/格式表推導過程與模板實測原始數據：[`design.md`](design.md) §1.5、§3.1。
- 操作手冊（CLI／Docker／權限前置／NAS 鎖／復原）：[`usage.md`](usage.md)。
- 快速上手：[`../README.md`](../README.md)。
