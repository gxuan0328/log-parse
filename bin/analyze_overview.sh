#!/usr/bin/env bash
# bin/analyze_overview.sh
# ----------------------------------------------------------------------------
# DRY management overview: spawns analyze_iis + analyze_access in --emit-stats
# mode, buckets the emitted rows via OVERVIEW_AWK, and renders three management
# cuts: 總體概況 / 分區別 / 服務別.
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
#   Grand totals  → 總體概況 only.
#   Region shares → 分區別 (distinct decomposition; no grand totals).
#   Role signals  → 服務別 only (5XX/SLOW/503/ORPHAN/UNVERIFIED literals here).
#   Verdict line  → numeric-free (words only).
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
# Purpose : Bucket IIS + ACCESS emit-stats rows into grand totals, per-region
#           counts, and per-role IIS counts for the three-cut overview render.
# Input   : iis_stats.tsv then acc_stats.tsv (per FILENAME == iis_file guard).
# Vars    : iis_file — path to IIS stats (for two-file join per awk.md).
# Output  : TAB-delimited structured rows for bash to parse:
#             IIS_TOTAL      <n>
#             IIS_UNIQUE_IPS <n>
#             IIS_API_5XX    <n>  (API-role 5XX only)
#             IIS_503        <n>  (503_HEALTH grand total — APP health checks)
#             IIS_API_TOTAL  <n>
#             IIS_APP_TOTAL  <n>
#             IIS_API_SLOW   <n>
#             IIS_APP_SLOW   <n>
#             IIS_REGION     <rid>  <n>
#             ACC_TOTAL      <n>
#             ACC_NORMAL     <n>
#             ACC_ORPHAN     <n>
#             ACC_UNVER      <n>
#             ACC_DC         <n>     (grand DELTA_COUNT)
#             ACC_DS         <sum>   (grand DELTA_SUM)
#             ACC_REGION     <rid>   <normal>   <orphan>   <unver>
# ----------------------------------------------------------------------------
FILENAME == iis_file {
    region=$2; role=$3; tag=$5; val=$6+0
    if (tag == "TOTAL")      { iis_tot += val; iis_reg[region] += val; iis_role[role] += val }
    if (tag == "5XX")        { iis_5xx_role[role] += val }
    if (tag == "503_HEALTH") { iis_503 += val }
    if (tag == "SLOW")       { iis_slow_role[role] += val }
    if (tag == "UNIQUE_IPS") { iis_uniq += val }
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
    printf "IIS_TOTAL\t%d\n",     iis_tot+0
    printf "IIS_UNIQUE_IPS\t%d\n",iis_uniq+0
    printf "IIS_API_5XX\t%d\n",   iis_5xx_role["api"]+0
    printf "IIS_503\t%d\n",       iis_503+0
    printf "IIS_API_TOTAL\t%d\n", iis_role["api"]+0
    printf "IIS_APP_TOTAL\t%d\n", iis_role["app"]+0
    printf "IIS_API_SLOW\t%d\n",  iis_slow_role["api"]+0
    printf "IIS_APP_SLOW\t%d\n",  iis_slow_role["app"]+0
    for (r in iis_reg) printf "IIS_REGION\t%s\t%d\n", r, iis_reg[r]
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
#             run OVERVIEW_AWK to bucket aggregated stats, and render three
#             management cuts: 總體概況 / 分區別 / 服務別.
#             Summary-only; text-only; format-independent (C10).
#   Args    : none (uses globals: _OVW_*, OPT_*, REGION_*, WORK_TMPDIR).
#   Output  : formatted overview report on stdout.
#   Returns / Side effects : none.
#   Errors / Notes : Gracefully handles empty stats (zeros/N/A, no divide-by-zero).
#             CJK labels use fmt_kv under LC_ALL=C (never raw printf "%-Ns" on CJK).
#             Numeric placement (C5): grand totals only in 總體; role signals
#             (5XX/SLOW/503/ORPHAN/UNVERIFIED) only in 服務別; verdict numeric-free.
overview_render() {
    local iis_stats="${WORK_TMPDIR}/iis_stats.tsv"
    local acc_stats="${WORK_TMPDIR}/acc_stats.tsv"

    # Bucket stats from both emit-stats files via OVERVIEW_AWK (two-file join)
    local agg_out
    agg_out=$(LC_ALL=C gawk -F'\t' -v iis_file="$iis_stats" \
        "$OVERVIEW_AWK" "$iis_stats" "$acc_stats")

    # ── Parse scalar aggregates ───────────────────────────────────────────────
    local iis_total iis_unique_ips iis_api_5xx iis_503
    local iis_api_total iis_app_total iis_api_slow iis_app_slow
    local acc_total acc_normal acc_orphan acc_unver acc_dc acc_ds

    iis_total=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_TOTAL"     {print $2; exit}')
    iis_unique_ips=$(printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_UNIQUE_IPS"{print $2; exit}')
    iis_api_5xx=$(   printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_API_5XX"   {print $2; exit}')
    iis_503=$(       printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_503"       {print $2; exit}')
    iis_api_total=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_API_TOTAL" {print $2; exit}')
    iis_app_total=$( printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_APP_TOTAL" {print $2; exit}')
    iis_api_slow=$(  printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_API_SLOW"  {print $2; exit}')
    iis_app_slow=$(  printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="IIS_APP_SLOW"  {print $2; exit}')
    acc_total=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_TOTAL"     {print $2; exit}')
    acc_normal=$(    printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_NORMAL"    {print $2; exit}')
    acc_orphan=$(    printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_ORPHAN"    {print $2; exit}')
    acc_unver=$(     printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_UNVER"     {print $2; exit}')
    acc_dc=$(        printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_DC"        {print $2; exit}')
    acc_ds=$(        printf '%s\n' "$agg_out" | gawk -F'\t' '$1=="ACC_DS"        {print $2; exit}')

    # Safe defaults for empty windows (empty stats → all zeros → no divide-by-zero)
    iis_total="${iis_total:-0}";         iis_unique_ips="${iis_unique_ips:-0}"
    iis_api_5xx="${iis_api_5xx:-0}";     iis_503="${iis_503:-0}"
    iis_api_total="${iis_api_total:-0}"; iis_app_total="${iis_app_total:-0}"
    iis_api_slow="${iis_api_slow:-0}";   iis_app_slow="${iis_app_slow:-0}"
    acc_total="${acc_total:-0}";         acc_normal="${acc_normal:-0}"
    acc_orphan="${acc_orphan:-0}";       acc_unver="${acc_unver:-0}"
    acc_dc="${acc_dc:-0}";               acc_ds="${acc_ds:-0}"

    # ── Percentages (fmt_pct handles denominator=0 gracefully → "N/A") ────────
    local pct_normal pct_api_slow pct_app_slow pct_api_share pct_app_share
    pct_normal=$(   fmt_pct "$acc_normal"    "$acc_total")
    pct_api_slow=$( fmt_pct "$iis_api_slow"  "$iis_api_total")
    pct_app_slow=$( fmt_pct "$iis_app_slow"  "$iis_app_total")
    pct_api_share=$(fmt_pct "$iis_api_total" "$iis_total")
    pct_app_share=$(fmt_pct "$iis_app_total" "$iis_total")

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
    # 總體概況 (Overall) — grand totals appear ONLY here (C5)
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "總體概況 (Overall)"
    fmt_kv "IIS 總請求數"      "$iis_total"
    fmt_kv "不重複用戶端 IP"   "$iis_unique_ips"
    fmt_kv "存取關聯總數"      "$acc_total"
    fmt_kv "NORMAL 正常流程率" "$pct_normal"
    fmt_kv "平均 API→APP 延遲" "$avg_delta"
    fmt_kv "整體健康判定"      "$verdict"

    # ═════════════════════════════════════════════════════════════════════════
    # 分區別 (By Region) — region decomposition; no grand totals (C5)
    # Shows: per-region IIS share %, per-region NORMAL%, combined anomaly count.
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "分區別 (By Region)"
    printf "  %s\n" "[佔比；總量見總體概況]"

    for _rid in "${REGION_IDS[@]}"; do
        if [[ "$OPT_REGION" != "all" && "$OPT_REGION" != "$_rid" ]]; then continue; fi
        local _rname="${REGION_NAMES[$_rid]}"

        # Per-region IIS share
        local _riis
        _riis=$(printf '%s\n' "$agg_out" | gawk -F'\t' -v r="$_rid" \
            '$1=="IIS_REGION" && $2==r {print $3; exit}')
        _riis="${_riis:-0}"
        local _riis_share
        _riis_share=$(fmt_pct "$_riis" "$iis_total")

        # Per-region ACCESS breakdown
        local _r_line _r_norm _r_orph _r_unver _r_acc_total _r_anomaly _rnormal_pct
        _r_line=$(printf '%s\n' "$agg_out" | gawk -F'\t' -v r="$_rid" \
            '$1=="ACC_REGION" && $2==r {print $3, $4, $5; exit}')
        _r_norm=$( printf '%s\n' "$_r_line" | awk '{print $1+0}')
        _r_orph=$( printf '%s\n' "$_r_line" | awk '{print $2+0}')
        _r_unver=$(printf '%s\n' "$_r_line" | awk '{print $3+0}')
        _r_norm="${_r_norm:-0}"; _r_orph="${_r_orph:-0}"; _r_unver="${_r_unver:-0}"
        _r_acc_total=$(( _r_norm + _r_orph + _r_unver ))
        _r_anomaly=$((   _r_orph + _r_unver ))
        _rnormal_pct=$(fmt_pct "$_r_norm" "$_r_acc_total")

        fmt_kv "$_rname" "IIS 佔比 ${_riis_share}   NORMAL ${_rnormal_pct}   異常 ${_r_anomaly}"
    done

    # ═════════════════════════════════════════════════════════════════════════
    # 服務別 (By Service Role) — role decomposition
    # 5XX/SLOW/503/ORPHAN/UNVERIFIED literals ONLY here (C5).
    # UNVERIFIED in API sub-slice; ORPHAN/503 in APP sub-slice.
    # ═════════════════════════════════════════════════════════════════════════
    fmt_h2 "服務別 (By Service Role)"

    # ── API sub-slice (UNVERIFIED signal; ORPHAN/503 excluded here) ──────────
    fmt_h3 "API 伺服器 (${n_api_srv} 台 · 簽發 Token)"
    fmt_kv "IIS 請求數 (佔比)"          "${iis_api_total} (${pct_api_share})"
    fmt_kv "5XX 錯誤"                   "$iis_api_5xx"
    fmt_kv "慢速率 (>${OPT_SLOW_API_MS}ms)" "$pct_api_slow"
    fmt_kv "UNVERIFIED (簽發未使用)"    "$acc_unver"

    # ── APP sub-slice (ORPHAN/503 signals; UNVERIFIED excluded here) ─────────
    fmt_h3 "APP 伺服器 (${n_app_srv} 台 · 驗證 Token / DICOM)"
    fmt_kv "IIS 請求數 (佔比)"          "${iis_app_total} (${pct_app_share})"
    fmt_kv "健康檢查 503 (Oracle 相依)" "$iis_503"
    fmt_kv "慢速率 (>${OPT_SLOW_APP_MS}ms)" "$pct_app_slow"
    fmt_kv "ORPHAN (無對應簽發)"        "$acc_orphan"
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
