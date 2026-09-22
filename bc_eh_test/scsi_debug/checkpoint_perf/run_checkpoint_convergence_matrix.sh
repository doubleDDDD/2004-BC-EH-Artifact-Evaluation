#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/checkpoint_common.sh"

readonly RUN_CASE_SH="${SCRIPT_DIR}/run_checkpoint_convergence_case.sh"
readonly SUMMARY_MD="${SCRIPT_DIR}/checkpoint_summary.md"
readonly RAW_RESULTS_CSV="${SCRIPT_DIR}/checkpoint_raw_results.csv"
readonly BC_EH_CP_RUNNING_POS_LIST="${BC_EH_CP_RUNNING_POS_LIST:-1 16 64 128}"

[ -f "${RUN_CASE_SH}" ] || bc_cp_die "missing script: ${RUN_CASE_SH}"

matrix_init_summary()
{
    {
        printf '| `running_pos` | `leaf_count` | `iters` | `warmup_runs` | `measure_runs` | `ns_per_invocation` (median / p95) | `ns_per_visited_node` (median / p95) | `visited_nodes_per_invocation` | note |\n'
        printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
    } > "${SUMMARY_MD}"
}

matrix_init_csv()
{
    {
        printf 'running_pos,leaf_count,iters,warmup_runs,measure_runs,visited_nodes_per_invocation,ns_per_invocation_median,ns_per_invocation_p95,ns_per_visited_node_median,ns_per_visited_node_p95,total_exec_ns_median\n'
    } > "${RAW_RESULTS_CSV}"
}

matrix_append_row()
{
    local result_line="$1"
    local running_pos
    local leaf_count
    local iters
    local warmup_runs
    local measure_runs
    local visited_nodes
    local ns_median
    local ns_p95
    local ns_per_visited_median
    local ns_per_visited_p95
    local total_exec_median

    running_pos="$(bc_cp_field_from_line "${result_line}" "running_pos")"
    leaf_count="$(bc_cp_field_from_line "${result_line}" "leaf_count")"
    iters="$(bc_cp_field_from_line "${result_line}" "iters")"
    warmup_runs="$(bc_cp_field_from_line "${result_line}" "warmup_runs")"
    measure_runs="$(bc_cp_field_from_line "${result_line}" "measure_runs")"
    visited_nodes="$(bc_cp_field_from_line "${result_line}" "visited_nodes_per_invocation")"
    ns_median="$(bc_cp_field_from_line "${result_line}" "ns_per_invocation_median")"
    ns_p95="$(bc_cp_field_from_line "${result_line}" "ns_per_invocation_p95")"
    ns_per_visited_median="$(bc_cp_field_from_line "${result_line}" "ns_per_visited_node_median")"
    ns_per_visited_p95="$(bc_cp_field_from_line "${result_line}" "ns_per_visited_node_p95")"
    total_exec_median="$(bc_cp_field_from_line "${result_line}" "total_exec_ns_median")"

    {
        printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s / %s ns` | `%s / %s ns` | `%s` | fixed topology |\n' \
            "${running_pos}" \
            "${leaf_count}" \
            "${iters}" \
            "${warmup_runs}" \
            "${measure_runs}" \
            "${ns_median}" \
            "${ns_p95}" \
            "${ns_per_visited_median}" \
            "${ns_per_visited_p95}" \
            "${visited_nodes}"
    } >> "${SUMMARY_MD}"

    {
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "${running_pos}" \
            "${leaf_count}" \
            "${iters}" \
            "${warmup_runs}" \
            "${measure_runs}" \
            "${visited_nodes}" \
            "${ns_median}" \
            "${ns_p95}" \
            "${ns_per_visited_median}" \
            "${ns_per_visited_p95}" \
            "${total_exec_median}"
    } >> "${RAW_RESULTS_CSV}"
}

main()
{
    local running_pos
    local result_line

    matrix_init_summary
    matrix_init_csv

    for running_pos in ${BC_EH_CP_RUNNING_POS_LIST}; do
        bc_cp_log "sweep running_pos=${running_pos}"
        result_line="$(
            BC_EH_CP_RUNNING_POS="${running_pos}" \
            sh "${RUN_CASE_SH}"
        )"
        printf '%s\n' "${result_line}"
        matrix_append_row "${result_line}"
    done
}

main "$@"
