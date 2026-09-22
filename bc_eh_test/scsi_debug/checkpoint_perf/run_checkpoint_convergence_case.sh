#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BC_EH_CP_NUM_CHANNELS="${BC_EH_CP_NUM_CHANNELS:-1}"
BC_EH_CP_NUM_TARGETS="${BC_EH_CP_NUM_TARGETS:-128}"
BC_EH_CP_MAX_LUNS="${BC_EH_CP_MAX_LUNS:-1}"
BC_EH_CP_MAX_QUEUE="${BC_EH_CP_MAX_QUEUE:-192}"
BC_EH_CP_DEV_SIZE_MB="${BC_EH_CP_DEV_SIZE_MB:-128}"
BC_EH_CP_RUNNING_POS="${BC_EH_CP_RUNNING_POS:-128}"
BC_EH_CP_ITERS="${BC_EH_CP_ITERS:-1000000}"
BC_EH_CP_WARMUP_RUNS="${BC_EH_CP_WARMUP_RUNS:-10}"
BC_EH_CP_MEASURE_RUNS="${BC_EH_CP_MEASURE_RUNS:-20}"
BC_EH_CP_WAIT_SECS="${BC_EH_CP_WAIT_SECS:-60}"

export BC_EH_TOPOLOGY=complextopo
export BC_EH_COMPLEX_NUM_CHANNELS="${BC_EH_CP_NUM_CHANNELS}"
export BC_EH_COMPLEX_NUM_TARGETS="${BC_EH_CP_NUM_TARGETS}"
export BC_EH_COMPLEX_MAX_LUNS="${BC_EH_CP_MAX_LUNS}"
export BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH="${BC_EH_CP_PER_DISK_QUEUE_DEPTH:-32}"
export BC_EH_COMPLEX_PER_DISK_NR_REQUESTS="${BC_EH_CP_PER_DISK_NR_REQUESTS:-32}"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/checkpoint_common.sh"

readonly BC_EH_CP_NUM_CHANNELS
readonly BC_EH_CP_NUM_TARGETS
readonly BC_EH_CP_MAX_LUNS
readonly BC_EH_CP_MAX_QUEUE
readonly BC_EH_CP_DEV_SIZE_MB
readonly BC_EH_CP_RUNNING_POS
readonly BC_EH_CP_ITERS
readonly BC_EH_CP_WARMUP_RUNS
readonly BC_EH_CP_MEASURE_RUNS
readonly BC_EH_CP_WAIT_SECS

BC_EH_CP_TMP_DIR=""

checkpoint_stat_series_text()
{
    local series_text="$1"

    printf '%s' "${series_text}" | awk '
        NF {
            x[count] = $1 + 0.0;
            count += 1;
        }
        END {
            if (count == 0) {
                printf "0|0";
                exit;
            }

            for (i = 0; i < count - 1; i++) {
                for (j = i + 1; j < count; j++) {
                    if (x[i] > x[j]) {
                        tmp = x[i];
                        x[i] = x[j];
                        x[j] = tmp;
                    }
                }
            }

            if (count % 2 == 1) {
                median = x[(count - 1) / 2];
            } else {
                median = (x[count / 2 - 1] + x[count / 2]) / 2.0;
            }

            idx = int((95 * count + 99) / 100);
            if (idx < 1)
                idx = 1;
            if (idx > count)
                idx = count;

            printf "%.0f|%.0f", median, x[idx - 1];
        }
    '
}

checkpoint_validate_inputs()
{
    local leaf_count

    [ "${BC_EH_CP_NUM_CHANNELS}" -gt 0 ] || bc_cp_die "BC_EH_CP_NUM_CHANNELS must be > 0"
    [ "${BC_EH_CP_NUM_TARGETS}" -gt 0 ] || bc_cp_die "BC_EH_CP_NUM_TARGETS must be > 0"
    [ "${BC_EH_CP_MAX_LUNS}" -gt 0 ] || bc_cp_die "BC_EH_CP_MAX_LUNS must be > 0"
    [ "${BC_EH_CP_MAX_QUEUE}" -gt 0 ] || bc_cp_die "BC_EH_CP_MAX_QUEUE must be > 0"
    [ "${BC_EH_CP_DEV_SIZE_MB}" -gt 0 ] || bc_cp_die "BC_EH_CP_DEV_SIZE_MB must be > 0"
    [ "${BC_EH_CP_RUNNING_POS}" -gt 0 ] || bc_cp_die "BC_EH_CP_RUNNING_POS must be > 0"
    [ "${BC_EH_CP_ITERS}" -gt 0 ] || bc_cp_die "BC_EH_CP_ITERS must be > 0"
    [ "${BC_EH_CP_WARMUP_RUNS}" -ge 0 ] || bc_cp_die "BC_EH_CP_WARMUP_RUNS must be >= 0"
    [ "${BC_EH_CP_MEASURE_RUNS}" -gt 0 ] || bc_cp_die "BC_EH_CP_MEASURE_RUNS must be > 0"

    leaf_count=$((BC_EH_CP_NUM_CHANNELS * BC_EH_CP_NUM_TARGETS * BC_EH_CP_MAX_LUNS))
    [ "${BC_EH_CP_RUNNING_POS}" -le "${leaf_count}" ] || \
        bc_cp_die "BC_EH_CP_RUNNING_POS=${BC_EH_CP_RUNNING_POS} exceeds leaf_count=${leaf_count}"
}

checkpoint_cleanup()
{
    [ -z "${BC_EH_CP_TMP_DIR}" ] || rm -rf "${BC_EH_CP_TMP_DIR}" >/dev/null 2>&1 || true
    bc_cp_cleanup_scsi_debug
}

checkpoint_load_scsi_debug()
{
    export SDEBUG_DEV_SIZE_MB="${BC_EH_CP_DEV_SIZE_MB}"

    bc_eh_load_scsi_debug
}

checkpoint_prepare_env()
{
    local host_no
    local expected_sdevs
    local actual_sdevs
    local cp_dir

    bc_cp_ensure_debugfs
    checkpoint_cleanup
    checkpoint_load_scsi_debug >&2

    host_no="$(bc_cp_wait_scsi_debug_host "${BC_EH_CP_WAIT_SECS}")" || \
        bc_cp_die "failed to find scsi_debug host"

    expected_sdevs=$((BC_EH_CP_NUM_CHANNELS * BC_EH_CP_NUM_TARGETS * BC_EH_CP_MAX_LUNS))
    actual_sdevs="$(bc_cp_wait_for_scsi_devices "${host_no}" "${expected_sdevs}" "${BC_EH_CP_WAIT_SECS}")" || \
        bc_cp_die "timed out waiting for ${expected_sdevs} scsi_debug devices"

    cp_dir="$(bc_cp_checkpoint_dir "${host_no}")"
    [ -d "${cp_dir}" ] || bc_cp_die "checkpoint bench dir not found: ${cp_dir}"

    printf '%s %s %s\n' "${host_no}" "${actual_sdevs}" "${cp_dir}"
}

checkpoint_run_once()
{
    local cp_dir="$1"
    local running_pos="$2"
    local iters="$3"

    printf '%s\n' "${running_pos}" > "${cp_dir}/running_pos"
    printf '%s\n' "${iters}" > "${cp_dir}/iters"
    printf '1\n' > "${cp_dir}/run"
}

checkpoint_measure_case()
{
    local cp_dir="$1"
    local running_pos="$2"
    local iters="$3"
    local warmup_runs="$4"
    local measure_runs="$5"
    local i
    local result_file="${cp_dir}/result"
    local value
    local ns_series=""
    local visited_nodes=""
    local ns_per_visited_series=""
    local total_exec_series=""

    i=0
    while [ "${i}" -lt "${warmup_runs}" ]; do
        checkpoint_run_once "${cp_dir}" "${running_pos}" "${iters}"
        i=$((i + 1))
    done

    i=0
    while [ "${i}" -lt "${measure_runs}" ]; do
        checkpoint_run_once "${cp_dir}" "${running_pos}" "${iters}"

        value="$(bc_cp_read_result_field "${result_file}" "ns_per_invocation")"
        ns_series="${ns_series}${value}
"

        value="$(bc_cp_read_result_field "${result_file}" "visited_nodes_per_invocation")"
        [ -n "${visited_nodes}" ] || visited_nodes="${value}"

        value="$(bc_cp_read_result_field "${result_file}" "ns_per_visited_node")"
        ns_per_visited_series="${ns_per_visited_series}${value}
"

        value="$(bc_cp_read_result_field "${result_file}" "total_exec_ns")"
        total_exec_series="${total_exec_series}${value}
"

        i=$((i + 1))
    done

    local ns_stats
    local ns_median
    local ns_p95
    local ns_per_visited_stats
    local ns_per_visited_median
    local ns_per_visited_p95
    local total_exec_stats
    local total_exec_median

    ns_stats="$(checkpoint_stat_series_text "${ns_series}")"
    ns_median="${ns_stats%|*}"
    ns_p95="${ns_stats#*|}"

    ns_per_visited_stats="$(checkpoint_stat_series_text "${ns_per_visited_series}")"
    ns_per_visited_median="${ns_per_visited_stats%|*}"
    ns_per_visited_p95="${ns_per_visited_stats#*|}"

    total_exec_stats="$(checkpoint_stat_series_text "${total_exec_series}")"
    total_exec_median="${total_exec_stats%|*}"

    printf 'CHECKPOINT_RESULT running_pos=%s iters=%s warmup_runs=%s measure_runs=%s leaf_count=%s visited_nodes_per_invocation=%s ns_per_invocation_median=%s ns_per_invocation_p95=%s ns_per_visited_node_median=%s ns_per_visited_node_p95=%s total_exec_ns_median=%s\n' \
        "${running_pos}" \
        "${iters}" \
        "${warmup_runs}" \
        "${measure_runs}" \
        "$((BC_EH_CP_NUM_CHANNELS * BC_EH_CP_NUM_TARGETS * BC_EH_CP_MAX_LUNS))" \
        "${visited_nodes}" \
        "${ns_median}" \
        "${ns_p95}" \
        "${ns_per_visited_median}" \
        "${ns_per_visited_p95}" \
        "${total_exec_median}"
}

main()
{
    local host_no
    local leaf_count
    local cp_dir
    local measure_output
    local prep_out

    checkpoint_validate_inputs
    trap 'checkpoint_cleanup' EXIT INT TERM

    prep_out="$(checkpoint_prepare_env)" || \
        bc_cp_die "failed to prepare checkpoint benchmark environment"

    set -- ${prep_out}
    [ "$#" -eq 3 ] || bc_cp_die "unexpected checkpoint_prepare_env output: ${prep_out}"

    host_no="$1"
    leaf_count="$2"
    cp_dir="$3"

    bc_cp_log "host=${host_no} leaf_count=${leaf_count} cp_dir=${cp_dir}" >&2
    bc_cp_log "running_pos=${BC_EH_CP_RUNNING_POS} iters=${BC_EH_CP_ITERS} warmup_runs=${BC_EH_CP_WARMUP_RUNS} measure_runs=${BC_EH_CP_MEASURE_RUNS}" >&2

    measure_output="$(checkpoint_measure_case \
        "${cp_dir}" \
        "${BC_EH_CP_RUNNING_POS}" \
        "${BC_EH_CP_ITERS}" \
        "${BC_EH_CP_WARMUP_RUNS}" \
        "${BC_EH_CP_MEASURE_RUNS}")"

    printf '%s\n' "${measure_output}"
}

main "$@"
