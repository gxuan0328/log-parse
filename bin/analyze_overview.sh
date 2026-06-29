#!/usr/bin/env bash
# bin/analyze_overview.sh
# ----------------------------------------------------------------------------
# DRY management overview: spawns analyze_iis + analyze_access in --emit-stats
# mode, buckets the emitted rows via OVERVIEW_AWK, and renders three management
# cuts: 總體概況 / 分區別 / 核心功能效能.
#
# Summary-only (no --view), text-only (no --format), cross-cut always
# (no --merge). Persist: summary-only via output_utils (no detail file).
#
# Accepted flags:
#   --log-dir, --region, --today/--date/--from/--to/--days (interval),
#   --slow-api-ms, --slow-app-ms, --output-dir, --conf, -v, -h.
#
# Rejected flags (die with clear message):
#   --view, --format, --merge, --top, --emit-stats.
#
# DRY sourcing (C2): split arg vectors:
#   IIS_ARGS    = BASE_ARGS + --slow-api-ms + --slow-app-ms
#   ACCESS_ARGS = BASE_ARGS only  (analyze_access dies on unknown --slow-*-ms)
#
# Numeric placement (C5):
#   Access totals + % → 總體概況 only (no IIS general totals).
#   Region shares     → 分區別 (fixed-width CJK; no grand totals).
#   Core-function KPIs (count/avg) → 核心功能效能 only.
#   Verdict line      → numeric-free (words only).
#
# See docs/design.md §3.0 for full specification.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/date_utils.sh"
source "${SCRIPT_DIR}/../lib/fmt_utils.sh"
source "${SCRIPT_DIR}/../lib/aggregate_utils.sh"
source "${SCRIPT_DIR}/../lib/output_utils.sh"

REGIONS_CONF="${SCRIPT_DIR}/../conf/regions.conf"

# ---------------------------------------------------------------------------
# Defaults (C1: OPT_OUTPUT_DIR="" — the ./log-parse literal lives in persist_init)
# ---------------------------------------------------------------------------
OPT_LOG_DIR=""
OPT_DAYS=7
OPT_FROM="" OPT_TO="" OPT_DATE=""
OPT_REGION="all"
OPT_OUTPUT_DIR=""
OPT_TODAY=0
OPT_DAYS_SET=0
OPT_SLOW_API_MS=2000
OPT_SLOW_APP_MS=5000
OPT_TEST_HOSTS="exclude"

# ---------------------------------------------------------------------------
# Renderer context globals (set in main, read by overview_render)
# ---------------------------------------------------------------------------
_OVW_DATE_START=""
_OVW_DATE_END=""
_OVW_N_DATES=0

declare -a REGION_IDS=()
declare -A REGION_NAMES=() REGION_APIS=() REGION_APPS=()

# ---------------------------------------------------------------------------
# OVERVIEW_AWK — bucket IIS + ACCESS emit-stats rows into aggregated stats
# ---------------------------------------------------------------------------
OVERVIEW_AWK='
# ----------------------------------------------------------------------------
# Purpose : Bucket IIS CATEGORY rows + ACCESS emit-stats rows into pooled
#           category stats and per-region access counts for the three-cut
#           overview render. IIS rows are business-only (child filtered /health
#           and test-hosts before emitting); no re-filter needed here.
#           IIS general aggregates (TOTAL/SLOW/UNIQUE_IPS/REGION) are dropped;
#           only CATEGORY rows are consumed from the IIS file.
# Input   : iis_stats.tsv then acc_stats.tsv (per FILENAME == iis_file guard).
# Vars    : iis_file — path to IIS stats (for two-file join per awk.md).
# Output  : TAB-delimited structured rows for bash to parse:
#             CAT        <key:glcr|ds|nhi>  <count>  <avg_sec>
#               avg_sec = cat_ms/cat_cnt/1000 (single division, exact pooled mean)
#             ACC_TOTAL  <n>
#             ACC_NORMAL <n>
#             ACC_ORPHAN <n>
#             ACC_UNVER  <n>
#             ACC_DC     <n>     (grand DELTA_COUNT)
#             ACC_DS     <sum>   (grand DELTA_SUM)
#             ACC_REGION <rid>   <normal>   <orphan>   <unver>
# ----------------------------------------------------------------------------
FILENAME == iis_file {
    if ($5 == "CATEGORY") {
        c = $6
        cat_cnt[c] += $7 + 0
        cat_ms[c]  += $8 + 0          # raw summed ms => pooled mean = cat_ms/cat_cnt/1000
    }
    next
}
{
    region=$2; tag=$3; val=$4+0
    if (tag == "NORMAL")      { acc_norm  += val; acc_rn[region] += val }
    if (tag == "ORPHAN")      { acc_orph  += val; acc_ro[region] += val }
    if (tag == "UNVERIFIED")  { acc_unver += val; acc_ru[region] += val }
    if (tag == "DELTA_COUNT") { acc_dc    += val }
    if (tag == "DELTA_SUM")   { acc_ds    += val }
}
END {
    # Emit CAT rows (always all three for stable downstream parsing).
    # Single division per category => exact cross-server pooled mean (no intermediate rounding).
    split("glcr ds nhi", _co, " ")
    for (i = 1; i <= 3; i++) {
        c = _co[i]
        cavg = (cat_cnt[c] > 0) ? (cat_ms[c] / cat_cnt[c] / 1000.0) : 0
        printf "CAT\t%s\t%d\t%.2f\n", c, cat_cnt[c]+0, cavg
    }
    # ACCESS aggregates (unchanged).
    printf "ACC_TOTAL\t%d\n",    acc_norm+acc_orph+acc_unver
    printf "ACC_NORMAL\t%d\n",   acc_norm+0
    printf "ACC_ORPHAN\t%d\n",   acc_orph+0
    printf "ACC_UNVER\t%d\n",    acc_unver+0
    printf "ACC_DC\t%d\n",       acc_dc+0
    printf "ACC_DS\t%g\n",       acc_ds+0
    for (r in acc_rn) printf "ACC_REGION\t%s\t%d\t%d\t%d\n", r, acc_rn[r]+0, acc_ro[r]+0, acc_ru[r]+0
}
'

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Management overview: IIS health + cross-correlation summary across roles and
regions. Summary-only (no --view) and text-only (no --format).

Options:
  --log-dir PATH     [required] root log directory
  --region REGION    taipei | taichung | all       (default: all)
  --today            alias for --date \$(today); sets single-day window
  --days N           integer >= 1                  (default: 7)  [implicit fallback]
  --from / --to DATE YYYY-MM-DD inclusive range    (use together)
  --date DATE        YYYY-MM-DD single day
  --slow-api-ms N    API slow threshold in ms      (default: 2000)
  --slow-app-ms N    APP slow threshold in ms      (default: 5000)
  --output-dir DIR   persistence dir               (default: env > ./log-parse)
  --conf FILE        regions config                (default: conf/regions.conf)
  -v, --verbose / -h, --help

NOT accepted (summary-only, text-only, cross-cut always):
  --view  --format  --merge  --top  --emit-stats

Interval flags are mutually exclusive (choose exactly ONE):
  --today | --date | --from/--to | --days (explicit)

Common scenarios:
  # Daily management overview, all regions
  bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --date 2026-05-21

  # Weekly overview with tightened API SLA
  bash bin/analyze_overview.sh --log-dir ./examples/sample-logs/LUNG-CANCER-REPORT-LOG \\
       --from 2026-05-18 --to 2026-05-25 --slow-api-ms 1000
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-dir)      OPT_LOG_DIR="$2";                  shift 2 ;;
            --days)         OPT_DAYS="$2"; OPT_DAYS_SET=1;     shift 2 ;;
            --from)         OPT_FROM="$2";                     shift 2 ;;
            --to)           OPT_TO="$2";                       shift 2 ;;
            --date)         OPT_DATE="$2";                     shift 2 ;;
            --today)        OPT_TODAY=1;                       shift ;;
            --region)       OPT_REGION="$2";                   shift 2 ;;
            --slow-api-ms)  OPT_SLOW_API_MS="$2";             shift 2 ;;
            --slow-app-ms)  OPT_SLOW_APP_MS="$2";             shift 2 ;;
            --test-hosts)   OPT_TEST_HOSTS="$2";               shift 2 ;;
            --output-dir)   OPT_OUTPUT_DIR="$2";               shift 2 ;;
            --conf)         REGIONS_CONF="$2";                 shift 2 ;;
            -v|--verbose)   LOG_LEVEL=DEBUG;                   shift ;;
            -h|--help)      usage; exit 0 ;;
            --view|--format|--merge|--top|--emit-stats)
                die "analyze_overview does not accept '$1' (summary-only, text-only, cross-cut always)" ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    if [[ -z "$OPT_LOG_DIR" ]]; then die "--log-dir is required"; fi
    if [[ ! -d "$OPT_LOG_DIR" ]]; then die "Log directory not found: $OPT_LOG_DIR"; fi
    if [[ ! -f "$REGIONS_CONF" ]]; then die "conf file not found: $REGIONS_CONF"; fi
    assert_uint "--slow-api-ms" "$OPT_SLOW_API_MS"
    assert_uint "--slow-app-ms" "$OPT_SLOW_APP_MS"
    assert_enum "--test-hosts"  "$OPT_TEST_HOSTS" exclude only all
}

# ---------------------------------------------------------------------------
# Region loading
# ---------------------------------------------------------------------------
load_regions() {
    while IFS='|' read -r rid rname apis apps; do
        if [[ "$rid" =~ ^# || -z "$rid" ]]; then continue; fi
        REGION_IDS+=("$rid")
        REGION_NAMES["$rid"]="$rname"
        REGION_APIS["$rid"]="$apis"
        REGION_APPS["$rid"]="$apps"
    done < "$REGIONS_CONF"
}

# ---------------------------------------------------------------------------
# overview_render — render the 3-cut management overview to stdout
# ---------------------------------------------------------------------------

# overview_render
#   Purpose : Read iis_stats.tsv + acc_stats.tsv (cached under WORK_TMPDIR),
#             run OVERVIEW_AWK to pool CATEGORY stats and bucket ACCESS rows,
#             and render three management cuts:
#               總體概況 (access value+%)
#               分區別   (CJK fixed-width access value+% per region)
#               核心功能效能 (glcr/ds/nhi count+%+avg).
#             Summary-only; text-only; format-independent (C10).
#   Args    : none (uses globals: _OVW_*, OPT_*, REGION_*, WORK_TMPDIR).
#   Output  : formatted overview report on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : Gracefully handles empty stats (zeros/N/A, no divide-by-zero).
#             CJK labels use fmt_kv under LC_ALL=C (never raw printf "%-Ns" on CJK).
#             Numeric placement (C5): access totals+% in 總體概況 only;
#             per-region decomposition in 分區別 only (fixed-width via rpad);
#             core-function KPIs in 核心功能效能 only; verdict numeric-free.
overview_render() {
    local iis_stats="${WORK_TMPDIR}/iis_stats.tsv"
    local acc_stats="${WORK_TMPDIR}/acc_stats.tsv"

    # Bucket stats from both emit-stats files via OVERVIEW_AWK (two-file join)
    local agg_out
    agg_out=$(LC_ALL=C gawk -F'\t' -v iis_file="$iis_stats" \
        "$OVERVIEW_AWK" "$iis_stats" "$acc_stats")

    # ── Parse ACCESS scalar aggregates ───────────────────────────────────────
    local acc_total acc_normal acc_orphan acc_unver acc_dc acc_ds

    acc_total=$(  printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_TOTAL"  {print $2; exit}')
    acc_normal=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_NORMAL" {print $2; exit}')
    acc_orphan=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_ORPHAN" {print $2; exit}')
    acc_unver=$(  printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_UNVER"  {print $2; exit}')
    acc_dc=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_DC"     {print $2; exit}')
    acc_ds=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_DS"     {print $2; exit}')

    # Safe defaults for empty windows (empty stats → all zeros → no divide-by-zero)
    acc_total="${acc_total:-0}";   acc_normal="${acc_normal:-0}"
    acc_orphan="${acc_orphan:-0}"; acc_unver="${acc_unver:-0}"
    acc_dc="${acc_dc:-0}";         acc_ds="${acc_ds:-0}"

    # ── Access percentages (fmt_pct handles denominator=0 → "N/A") ───────────
    local pct_normal pct_orphan pct_unver
    pct_normal=$(fmt_pct "$acc_normal" "$acc_total")
    pct_orphan=$(fmt_pct "$acc_orphan" "$acc_total")
    pct_unver=$( fmt_pct "$acc_unver"  "$acc_total")

    # ── Average API→APP delta ─────────────────────────────────────────────────
    local avg_delta="N/A"
    if (( acc_dc > 0 )); then
        avg_delta=$(gawk -v s="$acc_ds" -v c="$acc_dc" \
            'BEGIN{printf "%.1f", s/c}')
        avg_delta="${avg_delta}s"
    fi

    # ── Server counts in scope ────────────────────────────────────────────────
    local n_regions=0 n_api_srv=0 n_app_srv=0
    local _rid
    for _rid in "${REGION_IDS[@]}"; do
        if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$_rid" ]]; then continue; fi
        n_regions=$((n_regions + 1))
        local _apis="${REGION_APIS[$_rid]}" _apps="${REGION_APPS[$_rid]}"
        local -a _api_arr _app_arr
        IFS=',' read -ra _api_arr <<< "$_apis"
        IFS=',' read -ra _app_arr <<< "$_apps"
        n_api_srv=$((n_api_srv + ${#_api_arr[@]}))
        n_app_srv=$((n_app_srv + ${#_app_arr[@]}))
    done
    local n_total_srv=$((n_api_srv + n_app_srv))

    # ── Verdict (numeric-free per C5; words only) ─────────────────────────────
    local verdict
    if (( acc_total == 0 )); then
        verdict="無資料 — 本期間無存取關聯記錄"
    else
        local _pct_int
        _pct_int=$(gawk -v n="$acc_normal" -v d="$acc_total" \
            'BEGIN{printf "%d", n/d*100}')
        if (( _pct_int >= 98 )); then
            verdict="正常 — 系統整體運作健康"
        elif (( _pct_int >= 90 )); then
            verdict="注意 — 存在異常存取，建議持續監控"
        else
            verdict="警告 — 存取異常比例偏高，建議立即調查"
        fi
    fi

    # ═════════════════════════════════════════════════════════════════════════
    # Header
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h1 "營運總覽報告 (Management Overview)"
    fmt_kv "分析期間" "${_OVW_DATE_START}  →  ${_OVW_DATE_END}  (${_OVW_N_DATES} 天)"
    fmt_kv "涵蓋範圍" "${n_regions} 區域 / ${n_total_srv} 伺服器 (${n_api_srv} API · ${n_app_srv} APP)"

    # ═════════════════════════════════════════════════════════════════════════
    # 總體概況 (Overall) — access totals + value+% appear ONLY here (C5)
    # IIS general totals (總請求數/不重複IP) removed (req5).
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "總體概況 (Overall)"
    fmt_kv "存取關聯總數"           "$acc_total"
    fmt_kv "NORMAL 正常流程"        "${acc_normal} (${pct_normal})"
    fmt_kv "ORPHAN 無對應簽發"      "${acc_orphan} (${pct_orphan})"
    fmt_kv "UNVERIFIED 簽發未使用"  "${acc_unver} (${pct_unver})"
    fmt_kv "平均 API→APP 延遲"      "$avg_delta"
    fmt_kv "整體健康判定"           "$verdict"

    # ═════════════════════════════════════════════════════════════════════════
    # 分區別 (By Region) — access value+% per region; fixed-width CJK (req4)
    # Rendered through FMT_AWK_WIDTH rpad so "異常" column aligns regardless of
    # NORMAL% width (e.g. "0.0%" vs "100.0%"). No IIS 佔比 (req5).
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "分區別 (By Region)"

    local _region_rows=""
    for _rid in "${REGION_IDS[@]}"; do
        if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$_rid" ]]; then continue; fi
        local _rname="${REGION_NAMES[$_rid]}" _r_line _r_norm _r_orph _r_unver
        _r_line=$(printf '%s\n' "$agg_out" | gawk -F'\t' -v r="$_rid" \
            '$1=="ACC_REGION" && $2==r {print $3, $4, $5; exit}')
        _r_norm=$( printf '%s\n' "$_r_line" | awk '{print $1+0}')
        _r_orph=$( printf '%s\n' "$_r_line" | awk '{print $2+0}')
        _r_unver=$(printf '%s\n' "$_r_line" | awk '{print $3+0}')
        local _r_tot=$(( _r_norm + _r_orph + _r_unver ))
        local _r_anom=$(( _r_orph + _r_unver ))
        local _np _ap
        _np=$(fmt_pct "$_r_norm" "$_r_tot"); _ap=$(fmt_pct "$_r_anom" "$_r_tot")
        _region_rows+="${_rname}	${_r_norm}	${_np}	${_r_anom}	${_ap}"$'\n'
    done

    LC_ALL=C gawk -F'\t' "$FMT_AWK_WIDTH"'
        NF > 0 { printf "  %s%s%s\n",
              rpad($1, 12),
              rpad("正常 " $2 " (" $3 ")", 22),
              "異常 " $4 " (" $5 ")" }
    ' <<< "$_region_rows"

    # ═════════════════════════════════════════════════════════════════════════
    # 核心功能效能 (Core Function Performance).
    # Consumes CAT rows (IIS-sourced, tz-corrected, test-host-mode aware).
    # % of the 3-category sum (D5). avg = exact pooled mean (sum_ms/count/1000).
    # No 慢速 column: category-slow was out-of-scope and misled on role SLAs.
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "核心功能效能 (Core Function Performance)"
    printf "  %s\n" "[佔比為三大核心功能合計之占比 (三者為核心功能子集，非全體業務請求)；回應時間為平均值]"

    local _g_c _g_a _d_c _d_a _n_c _n_a
    IFS=' ' read -r _g_c _g_a <<< "$(printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="CAT"&&$2=="glcr"{print $3,$4;exit}')"
    IFS=' ' read -r _d_c _d_a <<< "$(printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="CAT"&&$2=="ds"{print $3,$4;exit}')"
    IFS=' ' read -r _n_c _n_a <<< "$(printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="CAT"&&$2=="nhi"{print $3,$4;exit}')"
    _g_c=${_g_c:-0}; _d_c=${_d_c:-0}; _n_c=${_n_c:-0}
    _g_a=${_g_a:-0.00}; _d_a=${_d_a:-0.00}; _n_a=${_n_a:-0.00}
    local _cat_sum=$(( _g_c + _d_c + _n_c ))
    local _gp _dp _npc
    _gp=$( fmt_pct "$_g_c" "$_cat_sum"); _dp=$(fmt_pct "$_d_c" "$_cat_sum"); _npc=$(fmt_pct "$_n_c" "$_cat_sum")

    LC_ALL=C gawk -F'\t' "$FMT_AWK_WIDTH"'
        { printf "  %s%s%s\n",
              rpad($1, 24),
              rpad($2 " (" $3 ")", 14),
              "平均 " $4 "s" }
    ' <<< "雲端查詢 (前端轉跳速度)	${_g_c}	${_gp}	${_g_a}
報告摘要 (摘要載入速度)	${_d_c}	${_dp}	${_d_a}
影像下載 (影像載入速度)	${_n_c}	${_npc}	${_n_a}"
    fmt_kv "核心功能存取合計" "${_cat_sum} ($(fmt_pct "$_cat_sum" "$_cat_sum"))"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_tmpdir
    load_regions

    # Resolve interval (mutex: die on >1 selector per D3/C8)
    resolve_interval \
        --today "$OPT_TODAY" --date "$OPT_DATE" \
        --from  "$OPT_FROM"  --to   "$OPT_TO" \
        --days-set "$OPT_DAYS_SET" --days "$OPT_DAYS"

    local date_list_file="${WORK_TMPDIR}/dates.txt"
    build_date_list "${INTERVAL_ARGS[@]}" > "$date_list_file"

    _OVW_DATE_START=$(head -1 "$date_list_file")
    _OVW_DATE_END=$(tail -1 "$date_list_file")
    _OVW_N_DATES=$(count_lines "$date_list_file")

    log_info "Period: ${_OVW_DATE_START} → ${_OVW_DATE_END} (${_OVW_N_DATES} days)"
    log_info "Region: $OPT_REGION"

    # ── Build split arg vectors (C2) ─────────────────────────────────────────
    # BASE_ARGS: interval + region + conf + verbose (common to both children)
    # IIS_ARGS:  BASE_ARGS + slow thresholds (iis accepts --slow-*-ms)
    # ACCESS_ARGS: BASE_ARGS only (access dies on unknown --slow-*-ms — fail-fast)
    local -a BASE_ARGS=(--log-dir "$OPT_LOG_DIR" --region "$OPT_REGION")
    BASE_ARGS+=("${INTERVAL_ARGS[@]}")
    BASE_ARGS+=(--test-hosts "$OPT_TEST_HOSTS")
    if [[ -n "${REGIONS_CONF:-}" ]]; then BASE_ARGS+=(--conf "$REGIONS_CONF"); fi
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then BASE_ARGS+=(--verbose); fi

    local -a IIS_ARGS=("${BASE_ARGS[@]}" \
        --slow-api-ms "$OPT_SLOW_API_MS" \
        --slow-app-ms "$OPT_SLOW_APP_MS")
    local -a ACCESS_ARGS=("${BASE_ARGS[@]}")   # NO slow thresholds (C2)

    # ── Spawn children in --emit-stats mode (no persistence, no banners) ─────
    local iis_stats="${WORK_TMPDIR}/iis_stats.tsv"
    local acc_stats="${WORK_TMPDIR}/acc_stats.tsv"

    log_info "Collecting IIS stats..."
    "${SCRIPT_DIR}/analyze_iis.sh"    "${IIS_ARGS[@]}"    --emit-stats > "$iis_stats"

    log_info "Collecting access stats..."
    "${SCRIPT_DIR}/analyze_access.sh" "${ACCESS_ARGS[@]}" --emit-stats > "$acc_stats"

    # ── Persist summary-only (DETAIL_FN="" → no detail file, I07) ────────────
    persist_init "$OPT_OUTPUT_DIR"
    persist_views overview summary text overview_render ''
}

main "$@"
