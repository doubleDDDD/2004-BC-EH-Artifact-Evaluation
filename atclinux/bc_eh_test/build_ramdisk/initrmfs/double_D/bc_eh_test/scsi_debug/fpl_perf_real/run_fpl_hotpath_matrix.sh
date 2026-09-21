#!/bin/sh
set -eu

# 输出：
#   - 原始 5 次结果写入当前目录下的 fpl_raw_results.csv
#   - 每次运行都会覆盖该文件
# 统计口径：
#   - 仅保留原始重复测量结果
#   - 延迟口径统一使用 clat，单位为 us

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly RUN_CASE_SH="${SCRIPT_DIR}/run_fpl_hotpath_case.sh"
readonly RAW_RESULTS_CSV="${SCRIPT_DIR}/fpl_raw_results.csv"
readonly BC_EH_FPL_REPEATS="${BC_EH_FPL_REPEATS:-5}"
readonly BC_EH_FPL_EH_MODE_LIST="${BC_EH_FPL_EH_MODE_LIST:-host sdev}"
readonly BC_EH_FPL_ACTIVE_DISKS_LIST="${BC_EH_FPL_ACTIVE_DISKS_LIST:-1 2 4 8 16}"
readonly BC_EH_FPL_WORKLOAD_LIST="${BC_EH_FPL_WORKLOAD_LIST:-randread_4k randread_16k randread_64k randread_256k randwrite_4k randwrite_16k randwrite_64k randwrite_256k}"

[ -x "${RUN_CASE_SH}" ] || [ -f "${RUN_CASE_SH}" ] || {
    printf 'missing script: %s\n' "${RUN_CASE_SH}" >&2
    exit 1
}

fpl_rw_from_workload()
{
    case "$1" in
        randread_*) printf 'randread\n' ;;
        randwrite_*) printf 'randwrite\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

fpl_bs_from_workload()
{
    case "$1" in
        randread_* ) printf '%s\n' "${1#randread_}" ;;
        randwrite_* ) printf '%s\n' "${1#randwrite_}" ;;
        *) printf 'unknown\n' ;;
    esac
}

fpl_case_id()
{
    local eh_mode="$1"
    local active_disks="$2"
    local workload="$3"
    printf '%s_%02ddev_%s_%s\n' \
        "${eh_mode}" \
        "${active_disks}" \
        "$(fpl_rw_from_workload "${workload}")" \
        "$(fpl_bs_from_workload "${workload}")"
}

fpl_init_raw_results_csv()
{
    {
        printf 'case_id,eh_mode,active_sdev,rw,bs,repeat,iops,avg_clat_us,p99_clat_us\n'
    } > "${RAW_RESULTS_CSV}"
}

fpl_extract_field()
{
    printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"
}

fpl_run_one_measure()
{
    local eh_mode="$1"
    local active_disks="$2"
    local workload="$3"
    local repeat="$4"
    local run_output
    local result_line

    printf '[RUN] repeat=%s eh_mode=%s active_disks=%s workload=%s\n' \
        "${repeat}" "${eh_mode}" "${active_disks}" "${workload}"

    if ! run_output="$(
        BC_EH_FPL_EH_MODE="${eh_mode}" \
        BC_EH_FPL_ACTIVE_DISKS="${active_disks}" \
        BC_EH_FPL_WORKLOAD="${workload}" \
        BC_EH_FPL_REPEAT_INDEX="${repeat}" \
        BC_EH_FPL_OUTPUT_MODE=summary \
        sh "${RUN_CASE_SH}" 2>&1
    )"; then
        printf '%s\n' "${run_output}" >&2
        exit 1
    fi

    result_line="$(printf '%s\n' "${run_output}" | awk '/^FPL_RESULT /{print; exit}')"
    [ -n "${result_line}" ] || {
        printf '%s\n' "${run_output}" >&2
        printf 'missing FPL_RESULT for eh_mode=%s active_disks=%s workload=%s repeat=%s\n' \
            "${eh_mode}" "${active_disks}" "${workload}" "${repeat}" >&2
        exit 1
    }

    printf '%s\n' "${result_line}"
}

fpl_append_raw_result()
{
    local case_id="$1"
    local eh_mode="$2"
    local active_disks="$3"
    local rw="$4"
    local bs="$5"
    local repeat="$6"
    local iops="$7"
    local avg_clat="$8"
    local p99_clat="$9"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${case_id}" \
        "${eh_mode}" \
        "${active_disks}" \
        "${rw}" \
        "${bs}" \
        "${repeat}" \
        "${iops}" \
        "${avg_clat}" \
        "${p99_clat}" \
        >> "${RAW_RESULTS_CSV}"
}

fpl_append_raw_rows_for_case()
{
    local eh_mode="$1"
    local active_disks="$2"
    local workload="$3"
    local case_id="$4"

    local rw
    local bs
    local repeat
    local result_line
    local iops_value
    local avg_clat_value
    local p99_clat_value

    rw="$(fpl_rw_from_workload "${workload}")"
    bs="$(fpl_bs_from_workload "${workload}")"

    repeat=1
    while [ "${repeat}" -le "${BC_EH_FPL_REPEATS}" ]; do
        result_line="$(fpl_run_one_measure "${eh_mode}" "${active_disks}" "${workload}" "${repeat}")"
        iops_value="$(fpl_extract_field "${result_line}" "iops")"
        avg_clat_value="$(fpl_extract_field "${result_line}" "avg_clat_us")"
        p99_clat_value="$(fpl_extract_field "${result_line}" "p99_clat_us")"

        fpl_append_raw_result \
            "${case_id}" \
            "${eh_mode}" \
            "${active_disks}" \
            "${rw}" \
            "${bs}" \
            "${repeat}" \
            "${iops_value}" \
            "${avg_clat_value}" \
            "${p99_clat_value}"

        repeat=$((repeat + 1))
    done
}

main()
{
    local eh_mode
    local active_disks
    local workload
    local case_id

    fpl_init_raw_results_csv

    for eh_mode in ${BC_EH_FPL_EH_MODE_LIST}; do
        for active_disks in ${BC_EH_FPL_ACTIVE_DISKS_LIST}; do
            for workload in ${BC_EH_FPL_WORKLOAD_LIST}; do
                case_id="$(fpl_case_id "${eh_mode}" "${active_disks}" "${workload}")"
                fpl_append_raw_rows_for_case "${eh_mode}" "${active_disks}" "${workload}" "${case_id}"
            done
        done
    done

    printf '[RAW] %s\n' "${RAW_RESULTS_CSV}"
    cat "${RAW_RESULTS_CSV}"
}

main "$@"
