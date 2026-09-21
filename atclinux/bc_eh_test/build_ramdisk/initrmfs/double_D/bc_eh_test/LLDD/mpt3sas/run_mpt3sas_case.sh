#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/mpt3sas_common.sh"

: "${BC_EH_PROFILE:?BC_EH_PROFILE is required}"
: "${BC_EH_MODE_VALUE:?BC_EH_MODE_VALUE is required}"
: "${BC_EH_CASE:?BC_EH_CASE is required}"

readonly BC_EH_MPT_PREFAULT_SECS="${BC_EH_MPT_PREFAULT_SECS:-15}"
readonly BC_EH_MPT_FAULT_RUNTIME="${BC_EH_MPT_FAULT_RUNTIME:-360}"
readonly BC_EH_MPT_HEALTHY_RUNTIME="${BC_EH_MPT_HEALTHY_RUNTIME:-420}"
readonly BC_EH_MPT_FAULT_IODEPTH="${BC_EH_MPT_FAULT_IODEPTH:-64}"
readonly BC_EH_MPT_HEALTHY_IODEPTH="${BC_EH_MPT_HEALTHY_IODEPTH:-64}"
readonly BC_EH_MPT_QUEUE_DEPTH="${BC_EH_MPT_QUEUE_DEPTH:-64}"
readonly BC_EH_MPT_NR_REQUESTS="${BC_EH_MPT_NR_REQUESTS:-64}"
readonly BC_EH_MPT_RW="${BC_EH_MPT_RW:-randread}"
readonly BC_EH_MPT_BS="${BC_EH_MPT_BS:-4k}"
readonly BC_EH_MPT_LOG_AVG_MSEC="${BC_EH_MPT_LOG_AVG_MSEC:-1000}"
readonly BC_EH_MPT_FAULT_CPU="${BC_EH_MPT_FAULT_CPU:-2}"
readonly BC_EH_MPT_HEALTHY_CPU="${BC_EH_MPT_HEALTHY_CPU:-3}"
readonly BC_EH_MPT_FAULT_RANDSEED="${BC_EH_MPT_FAULT_RANDSEED:-2026060301}"
readonly BC_EH_MPT_HEALTHY_RANDSEED="${BC_EH_MPT_HEALTHY_RANDSEED:-2026060302}"

bc_eh_mpt_case_has_healthy_stream()
{
    case "$1" in
        P2|P3|P5)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

bc_eh_mpt_case_fault_iodepth()
{
    printf '%s\n' "${BC_EH_MPT_FAULT_IODEPTH}"
}

bc_eh_wait_pid()
{
    local pid="$1"
    wait "${pid}" || return $?
}

bc_eh_start_fio_job()
{
    local stdout_file="$1"
    local name="$2"
    local filename="$3"
    local runtime="$4"
    local iodepth="$5"
    local log_prefix="$6"
    local cpu_id="$7"
    local randseed="$8"
    local fifo="${stdout_file}.fifo"

    rm -f "${fifo}"
    mkfifo "${fifo}"

    (
        tee "${stdout_file}" < "${fifo}"
    ) &
    BC_EH_TEE_PID="$!"

    (
        bc_eh_mpt_fio_job \
            "${name}" \
            "${filename}" \
            "${runtime}" \
            "${iodepth}" \
            "${log_prefix}" \
            "${BC_EH_MPT_RW}" \
            "${BC_EH_MPT_BS}" \
            "${BC_EH_MPT_LOG_AVG_MSEC}" \
            "${cpu_id}" \
            "${randseed}"
    ) > "${fifo}" 2>&1 &
    BC_EH_FIO_PID="$!"

    rm -f "${fifo}"
}

main()
{
    local run_dir
    local host_name
    local fault_dev
    local healthy_dev
    local fault_scsi_id
    local healthy_scsi_id
    local fault_target_id
    local healthy_target_id
    local fault_channel
    local healthy_channel
    local fault_host
    local healthy_host
    local fault_queue_depth
    local healthy_queue_depth
    local fault_nr_requests
    local healthy_nr_requests
    local fault_iodepth
    local dmesg_pid=""
    local fault_pid=""
    local fault_tee_pid=""
    local healthy_pid=""
    local healthy_tee_pid=""
    local fault_rc=0
    local healthy_rc=0
    local inject_epoch
    local finish_epoch

    bc_eh_require_root
    bc_eh_require_fio

    run_dir="${BC_EH_MPT_ROOT}/${BC_EH_PROFILE}/${BC_EH_CASE}/$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "${run_dir}"

    host_name="$(bc_eh_mpt_wait_host "${BC_EH_MPT_HOST_TIMEOUT}")" || \
        bc_eh_die "failed to find mpt3sas host"

    {
        IFS= read -r fault_dev
        IFS= read -r healthy_dev
    } <<EOF
$(bc_eh_mpt_resolve_devices "${host_name}")
EOF

    fault_dev="$(readlink -f "${fault_dev}")"
    healthy_dev="$(readlink -f "${healthy_dev}")"
    [ "${fault_dev}" != "${healthy_dev}" ] || bc_eh_die "fault_dev and healthy_dev must be different"

    bc_eh_mpt_require_mpt_dev "${fault_dev}"
    bc_eh_mpt_require_mpt_dev "${healthy_dev}"

    fault_host="$(bc_eh_mpt_host_from_dev "${fault_dev}")"
    healthy_host="$(bc_eh_mpt_host_from_dev "${healthy_dev}")"
    [ "${fault_host}" = "${host_name}" ] || bc_eh_die "fault device host mismatch: ${fault_dev} -> ${fault_host}, expected ${host_name}"
    [ "${healthy_host}" = "${host_name}" ] || bc_eh_die "healthy device host mismatch: ${healthy_dev} -> ${healthy_host}, expected ${host_name}"

    fault_scsi_id="$(bc_eh_mpt_scsi_id_from_dev "${fault_dev}")"
    healthy_scsi_id="$(bc_eh_mpt_scsi_id_from_dev "${healthy_dev}")"
    fault_channel="$(bc_eh_mpt_channel_from_dev "${fault_dev}")"
    healthy_channel="$(bc_eh_mpt_channel_from_dev "${healthy_dev}")"
    fault_target_id="$(bc_eh_mpt_target_id_from_dev "${fault_dev}")"
    healthy_target_id="$(bc_eh_mpt_target_id_from_dev "${healthy_dev}")"
    [ "${fault_target_id}" != "${healthy_target_id}" ] || \
        bc_eh_die "fault and healthy devices share the same target id: ${fault_target_id}"

    bc_eh_mpt_set_eh_mode "${host_name}" "${BC_EH_MODE_VALUE}"

    bc_eh_mpt_set_queue_depth "${fault_dev}" "${BC_EH_MPT_QUEUE_DEPTH}"
    bc_eh_mpt_set_queue_depth "${healthy_dev}" "${BC_EH_MPT_QUEUE_DEPTH}"
    bc_eh_mpt_set_nr_requests "${fault_dev}" "${BC_EH_MPT_NR_REQUESTS}"
    bc_eh_mpt_set_nr_requests "${healthy_dev}" "${BC_EH_MPT_NR_REQUESTS}"

    fault_queue_depth="$(bc_eh_mpt_get_queue_depth "${fault_dev}")"
    healthy_queue_depth="$(bc_eh_mpt_get_queue_depth "${healthy_dev}")"
    fault_nr_requests="$(bc_eh_mpt_get_nr_requests "${fault_dev}")"
    healthy_nr_requests="$(bc_eh_mpt_get_nr_requests "${healthy_dev}")"
    fault_iodepth="$(bc_eh_mpt_case_fault_iodepth "${BC_EH_CASE}")"

    bc_eh_mpt_clear_injection

    {
        printf 'profile=%s\n' "${BC_EH_PROFILE}"
        printf 'eh_mode=%s\n' "${BC_EH_MODE_VALUE}"
        printf 'case=%s\n' "${BC_EH_CASE}"
        printf 'host=%s\n' "${host_name}"
        printf 'fault_dev=%s\n' "${fault_dev}"
        printf 'healthy_dev=%s\n' "${healthy_dev}"
        printf 'fault_scsi_id=%s\n' "${fault_scsi_id}"
        printf 'healthy_scsi_id=%s\n' "${healthy_scsi_id}"
        printf 'fault_channel=%s\n' "${fault_channel}"
        printf 'healthy_channel=%s\n' "${healthy_channel}"
        printf 'fault_target_id=%s\n' "${fault_target_id}"
        printf 'healthy_target_id=%s\n' "${healthy_target_id}"
        printf 'prefault_secs=%s\n' "${BC_EH_MPT_PREFAULT_SECS}"
        printf 'fault_runtime=%s\n' "${BC_EH_MPT_FAULT_RUNTIME}"
        printf 'healthy_runtime=%s\n' "${BC_EH_MPT_HEALTHY_RUNTIME}"
        printf 'fault_iodepth=%s\n' "${fault_iodepth}"
        printf 'healthy_iodepth=%s\n' "${BC_EH_MPT_HEALTHY_IODEPTH}"
        printf 'rw=%s\n' "${BC_EH_MPT_RW}"
        printf 'bs=%s\n' "${BC_EH_MPT_BS}"
        printf 'fault_queue_depth=%s\n' "${fault_queue_depth}"
        printf 'healthy_queue_depth=%s\n' "${healthy_queue_depth}"
        printf 'fault_nr_requests=%s\n' "${fault_nr_requests}"
        printf 'healthy_nr_requests=%s\n' "${healthy_nr_requests}"
        printf 'bc_mpt_fault_mode_before=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_mode)"
        printf 'bc_mpt_fault_target_id_before=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_target_id)"
        printf 'bc_mpt_fault_channel_before=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_channel)"
        printf 'bc_mpt_fault_active_before=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_active)"
        printf 'bc_mpt_tur_fail_budget_cfg=%s\n' "$(bc_eh_mpt_case_tur_fail_budget "${BC_EH_CASE}")"
    } > "${run_dir}/metadata"

    dmesg -C >/dev/null 2>&1 || true
    dmesg --ctime --follow > "${run_dir}/dmesg_follow.log" 2>&1 &
    dmesg_pid="$!"

    bc_eh_mpt_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=start"

    bc_eh_start_fio_job \
        "${run_dir}/fault_fio.stdout" \
        "fault_${BC_EH_CASE}" \
        "${fault_dev}" \
        "${BC_EH_MPT_FAULT_RUNTIME}" \
        "${fault_iodepth}" \
        "${run_dir}/fault" \
        "${BC_EH_MPT_FAULT_CPU}" \
        "${BC_EH_MPT_FAULT_RANDSEED}"
    fault_pid="${BC_EH_FIO_PID}"
    fault_tee_pid="${BC_EH_TEE_PID}"

    if bc_eh_mpt_case_has_healthy_stream "${BC_EH_CASE}"; then
        bc_eh_start_fio_job \
            "${run_dir}/healthy_fio.stdout" \
            "healthy_${BC_EH_CASE}" \
            "${healthy_dev}" \
            "${BC_EH_MPT_HEALTHY_RUNTIME}" \
            "${BC_EH_MPT_HEALTHY_IODEPTH}" \
            "${run_dir}/healthy" \
            "${BC_EH_MPT_HEALTHY_CPU}" \
            "${BC_EH_MPT_HEALTHY_RANDSEED}"
        healthy_pid="${BC_EH_FIO_PID}"
        healthy_tee_pid="${BC_EH_TEE_PID}"
    fi

    sleep "${BC_EH_MPT_PREFAULT_SECS}"
    inject_epoch="$(date '+%s.%N')"
    printf 'inject_epoch=%s\n' "${inject_epoch}" >> "${run_dir}/metadata"
    bc_eh_mpt_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=inject epoch=${inject_epoch} channel=${fault_channel} target=${fault_target_id}"
    bc_eh_mpt_arm_case "${BC_EH_CASE}" "${fault_target_id}" "${fault_channel}"

    bc_eh_wait_pid "${fault_pid}" || fault_rc=$?
    if [ -n "${healthy_pid}" ]; then
        bc_eh_wait_pid "${healthy_pid}" || healthy_rc=$?
    fi
    [ -n "${fault_tee_pid}" ] && wait "${fault_tee_pid}" >/dev/null 2>&1 || true
    [ -n "${healthy_tee_pid}" ] && wait "${healthy_tee_pid}" >/dev/null 2>&1 || true

    finish_epoch="$(date '+%s.%N')"
    printf 'finish_epoch=%s\n' "${finish_epoch}" >> "${run_dir}/metadata"
    printf 'fault_fio_rc=%s\n' "${fault_rc}" >> "${run_dir}/metadata"
    printf 'healthy_fio_rc=%s\n' "${healthy_rc}" >> "${run_dir}/metadata"
    printf 'bc_mpt_fault_mode_after=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_mode)" >> "${run_dir}/metadata"
    printf 'bc_mpt_fault_target_id_after=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_target_id)" >> "${run_dir}/metadata"
    printf 'bc_mpt_fault_channel_after=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_channel)" >> "${run_dir}/metadata"
    printf 'bc_mpt_fault_active_after=%s\n' "$(bc_eh_mpt_read_param bc_mpt_fault_active)" >> "${run_dir}/metadata"
    bc_eh_mpt_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=finish epoch=${finish_epoch}"

    bc_eh_mpt_clear_injection
    sleep 2

    if [ -n "${dmesg_pid}" ] && kill -0 "${dmesg_pid}" >/dev/null 2>&1; then
        kill "${dmesg_pid}" >/dev/null 2>&1 || true
        wait "${dmesg_pid}" >/dev/null 2>&1 || true
    fi

    dmesg --ctime > "${run_dir}/dmesg_after.log" 2>&1 || true

    bc_eh_log "run finished: ${run_dir}"
    printf 'RESULT run_dir=%s profile=%s case=%s fault_rc=%s healthy_rc=%s\n' \
        "${run_dir}" "${BC_EH_PROFILE}" "${BC_EH_CASE}" "${fault_rc}" "${healthy_rc}"
}

main "$@"
