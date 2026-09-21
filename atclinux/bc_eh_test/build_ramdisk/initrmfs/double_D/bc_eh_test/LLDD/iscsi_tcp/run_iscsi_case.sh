#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/iscsi_tcp_common.sh"

: "${BC_EH_PROFILE:?BC_EH_PROFILE is required}"
: "${BC_EH_MODE_VALUE:?BC_EH_MODE_VALUE is required}"
: "${BC_EH_CASE:?BC_EH_CASE is required}"

readonly BC_EH_ISCSI_PREFAULT_SECS="${BC_EH_ISCSI_PREFAULT_SECS:-5}"
readonly BC_EH_ISCSI_FAULT_RUNTIME="${BC_EH_ISCSI_FAULT_RUNTIME:-90}"
readonly BC_EH_ISCSI_HEALTHY_RUNTIME="${BC_EH_ISCSI_HEALTHY_RUNTIME:-120}"
readonly BC_EH_ISCSI_FAULT_IODEPTH="${BC_EH_ISCSI_FAULT_IODEPTH:-32}"
readonly BC_EH_ISCSI_HEALTHY_IODEPTH="${BC_EH_ISCSI_HEALTHY_IODEPTH:-32}"
readonly BC_EH_ISCSI_QUEUE_DEPTH="${BC_EH_ISCSI_QUEUE_DEPTH:-32}"
readonly BC_EH_ISCSI_NR_REQUESTS="${BC_EH_ISCSI_NR_REQUESTS:-32}"
readonly BC_EH_ISCSI_P1_PREFAULT_SECS="${BC_EH_ISCSI_P1_PREFAULT_SECS:-15}"
readonly BC_EH_ISCSI_P1_FAULT_IODEPTH="${BC_EH_ISCSI_P1_FAULT_IODEPTH:-32}"
readonly BC_EH_ISCSI_P1_HEALTHY_IODEPTH="${BC_EH_ISCSI_P1_HEALTHY_IODEPTH:-32}"
readonly BC_EH_ISCSI_P1_QUEUE_DEPTH="${BC_EH_ISCSI_P1_QUEUE_DEPTH:-32}"
readonly BC_EH_ISCSI_P1_NR_REQUESTS="${BC_EH_ISCSI_P1_NR_REQUESTS:-32}"
readonly BC_EH_ISCSI_P1_LOG_AVG_MSEC="${BC_EH_ISCSI_P1_LOG_AVG_MSEC:-5}"
readonly BC_EH_ISCSI_P1_FAULT_CPU="${BC_EH_ISCSI_P1_FAULT_CPU:-2}"
readonly BC_EH_ISCSI_P1_HEALTHY_CPU="${BC_EH_ISCSI_P1_HEALTHY_CPU:-3}"
readonly BC_EH_ISCSI_P1_FAULT_RANDSEED="${BC_EH_ISCSI_P1_FAULT_RANDSEED:-2026060201}"
readonly BC_EH_ISCSI_P1_HEALTHY_RANDSEED="${BC_EH_ISCSI_P1_HEALTHY_RANDSEED:-2026060202}"

bc_eh_iscsi_case_has_healthy_stream()
{
    case "$1" in
        P1)
            return 0
            ;;
        P5)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

bc_eh_iscsi_case_fault_iodepth()
{
    case "$1" in
        P1)
            printf '%s\n' "${BC_EH_ISCSI_P1_FAULT_IODEPTH}"
            ;;
        *)
            printf '%s\n' "${BC_EH_ISCSI_FAULT_IODEPTH}"
            ;;
    esac
}

bc_eh_iscsi_case_healthy_iodepth()
{
    case "$1" in
        P1)
            printf '%s\n' "${BC_EH_ISCSI_P1_HEALTHY_IODEPTH}"
            ;;
        *)
            printf '%s\n' "${BC_EH_ISCSI_HEALTHY_IODEPTH}"
            ;;
    esac
}

bc_eh_iscsi_case_prefault_secs()
{
    case "$1" in
        P1)
            printf '%s\n' "${BC_EH_ISCSI_P1_PREFAULT_SECS}"
            ;;
        *)
            printf '%s\n' "${BC_EH_ISCSI_PREFAULT_SECS}"
            ;;
    esac
}

bc_eh_iscsi_case_log_avg_msec()
{
    case "$1" in
        P1)
            printf '%s\n' "${BC_EH_ISCSI_P1_LOG_AVG_MSEC}"
            ;;
        *)
            printf '1000\n'
            ;;
    esac
}

bc_eh_iscsi_case_stable_mode()
{
    case "$1" in
        P1)
            printf '1\n'
            ;;
        *)
            printf '0\n'
            ;;
    esac
}

bc_eh_iscsi_case_cpu()
{
    case "$1:$2" in
        P1:fault)
            printf '%s\n' "${BC_EH_ISCSI_P1_FAULT_CPU}"
            ;;
        P1:healthy)
            printf '%s\n' "${BC_EH_ISCSI_P1_HEALTHY_CPU}"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

bc_eh_iscsi_case_randseed()
{
    case "$1:$2" in
        P1:fault)
            printf '%s\n' "${BC_EH_ISCSI_P1_FAULT_RANDSEED}"
            ;;
        P1:healthy)
            printf '%s\n' "${BC_EH_ISCSI_P1_HEALTHY_RANDSEED}"
            ;;
        *)
            printf '\n'
            ;;
    esac
}

bc_eh_iscsi_case_prepare_devices()
{
    local case_name="$1"
    local fault_dev="$2"
    local healthy_dev="$3"

    case "${case_name}" in
        P1)
            bc_eh_iscsi_set_queue_depth "${fault_dev}" "${BC_EH_ISCSI_P1_QUEUE_DEPTH}"
            bc_eh_iscsi_set_queue_depth "${healthy_dev}" "${BC_EH_ISCSI_P1_QUEUE_DEPTH}"
            bc_eh_iscsi_set_nr_requests "${fault_dev}" "${BC_EH_ISCSI_P1_NR_REQUESTS}"
            bc_eh_iscsi_set_nr_requests "${healthy_dev}" "${BC_EH_ISCSI_P1_NR_REQUESTS}"
            ;;
        *)
            bc_eh_iscsi_set_queue_depth "${fault_dev}" "${BC_EH_ISCSI_QUEUE_DEPTH}"
            bc_eh_iscsi_set_queue_depth "${healthy_dev}" "${BC_EH_ISCSI_QUEUE_DEPTH}"
            bc_eh_iscsi_set_nr_requests "${fault_dev}" "${BC_EH_ISCSI_NR_REQUESTS}"
            bc_eh_iscsi_set_nr_requests "${healthy_dev}" "${BC_EH_ISCSI_NR_REQUESTS}"
            ;;
    esac
}

bc_eh_wait_pid()
{
    local pid="$1"
    wait "${pid}" || return $?
}

bc_eh_start_fio_job()
{
    local stream_name="$1"
    local stdout_file="$2"
    local name="$3"
    local filename="$4"
    local runtime="$5"
    local iodepth="$6"
    local log_prefix="$7"
    local cpu_id="$8"
    local log_avg_msec="$9"
    local stable_mode="${10}"
    local randseed="${11}"
    local fifo="${stdout_file}.fifo"

    rm -f "${fifo}"
    mkfifo "${fifo}"

    (
        tee "${stdout_file}" < "${fifo}"
    ) &
    BC_EH_TEE_PID="$!"

    (
        bc_eh_iscsi_fio_job \
            "${name}" \
            "${filename}" \
            "${runtime}" \
            "${iodepth}" \
            "${log_prefix}" \
            "${log_avg_msec}" \
            "${stable_mode}" \
            "${randseed}" \
            "${cpu_id}"
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
    local dmesg_pid=""
    local fault_pid=""
    local fault_tee_pid=""
    local healthy_pid=""
    local healthy_tee_pid=""
    local fault_rc=0
    local healthy_rc=0
    local inject_epoch
    local finish_epoch
    local auto_session_started=0
    local run_healthy_stream=1
    local prefault_secs
    local fault_iodepth
    local healthy_iodepth
    local fault_cpu
    local healthy_cpu
    local fault_log_avg_msec
    local healthy_log_avg_msec
    local fault_stable_mode
    local healthy_stable_mode
    local fault_randseed
    local healthy_randseed
    local fault_queue_depth=""
    local healthy_queue_depth=""
    local fault_nr_requests=""
    local healthy_nr_requests=""

    bc_eh_require_root
    bc_eh_require_portal_ip
    bc_eh_require_fio

    run_dir="${BC_EH_ISCSI_ROOT}/${BC_EH_PROFILE}/${BC_EH_CASE}/$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "${run_dir}"

    if bc_eh_iscsi_session_exists; then
        bc_eh_log "reuse existing iscsi session"
    else
        bc_eh_log "no existing iscsi session, login automatically"
        bc_eh_iscsi_guest_cleanup_session
        bc_eh_iscsi_guest_login
        auto_session_started=1
    fi
    host_name="$(bc_eh_iscsi_wait_host "${BC_EH_ISCSI_HOST_TARGET_TIMEOUT}")" || bc_eh_die "failed to find iscsi_tcp host"
    bc_eh_iscsi_set_eh_mode "${host_name}" "${BC_EH_MODE_VALUE}"

    fault_dev="$(bc_eh_iscsi_wait_lun_device 0)"
    healthy_dev="$(bc_eh_iscsi_wait_lun_device 1)"
    bc_eh_iscsi_case_prepare_devices "${BC_EH_CASE}" "${fault_dev}" "${healthy_dev}"
    bc_eh_iscsi_clear_injection
    prefault_secs="$(bc_eh_iscsi_case_prefault_secs "${BC_EH_CASE}")"
    fault_iodepth="$(bc_eh_iscsi_case_fault_iodepth "${BC_EH_CASE}")"
    healthy_iodepth="$(bc_eh_iscsi_case_healthy_iodepth "${BC_EH_CASE}")"
    fault_cpu="$(bc_eh_iscsi_case_cpu "${BC_EH_CASE}" "fault")"
    healthy_cpu="$(bc_eh_iscsi_case_cpu "${BC_EH_CASE}" "healthy")"
    fault_log_avg_msec="$(bc_eh_iscsi_case_log_avg_msec "${BC_EH_CASE}")"
    healthy_log_avg_msec="$(bc_eh_iscsi_case_log_avg_msec "${BC_EH_CASE}")"
    fault_stable_mode="$(bc_eh_iscsi_case_stable_mode "${BC_EH_CASE}")"
    healthy_stable_mode="$(bc_eh_iscsi_case_stable_mode "${BC_EH_CASE}")"
    fault_randseed="$(bc_eh_iscsi_case_randseed "${BC_EH_CASE}" "fault")"
    healthy_randseed="$(bc_eh_iscsi_case_randseed "${BC_EH_CASE}" "healthy")"
    fault_queue_depth="$(bc_eh_iscsi_get_queue_depth "${fault_dev}")"
    healthy_queue_depth="$(bc_eh_iscsi_get_queue_depth "${healthy_dev}")"
    fault_nr_requests="$(bc_eh_iscsi_get_nr_requests "${fault_dev}")"
    healthy_nr_requests="$(bc_eh_iscsi_get_nr_requests "${healthy_dev}")"
    if ! bc_eh_iscsi_case_has_healthy_stream "${BC_EH_CASE}"; then
        run_healthy_stream=0
    fi

    {
        printf 'profile=%s\n' "${BC_EH_PROFILE}"
        printf 'eh_mode=%s\n' "${BC_EH_MODE_VALUE}"
        printf 'case=%s\n' "${BC_EH_CASE}"
        printf 'portal=%s:%s\n' "${BC_EH_ISCSI_PORTAL_IP}" "${BC_EH_ISCSI_PORTAL_PORT}"
        printf 'iqn=%s\n' "${BC_EH_ISCSI_TARGET_IQN}"
        printf 'scsi_host=%s\n' "${host_name}"
        printf 'fault_dev=%s\n' "${fault_dev}"
        printf 'healthy_dev=%s\n' "${healthy_dev}"
        printf 'healthy_stream=%s\n' "${run_healthy_stream}"
        printf 'prefault_secs=%s\n' "${prefault_secs}"
        printf 'fault_runtime=%s\n' "${BC_EH_ISCSI_FAULT_RUNTIME}"
        printf 'healthy_runtime=%s\n' "${BC_EH_ISCSI_HEALTHY_RUNTIME}"
        printf 'fault_iodepth=%s\n' "${fault_iodepth}"
        printf 'healthy_iodepth=%s\n' "${healthy_iodepth}"
        printf 'fault_queue_depth=%s\n' "${fault_queue_depth}"
        printf 'healthy_queue_depth=%s\n' "${healthy_queue_depth}"
        printf 'fault_nr_requests=%s\n' "${fault_nr_requests}"
        printf 'healthy_nr_requests=%s\n' "${healthy_nr_requests}"
        printf 'fault_cpu=%s\n' "${fault_cpu}"
        printf 'healthy_cpu=%s\n' "${healthy_cpu}"
        printf 'fault_log_avg_msec=%s\n' "${fault_log_avg_msec}"
        printf 'healthy_log_avg_msec=%s\n' "${healthy_log_avg_msec}"
        printf 'fault_randseed=%s\n' "${fault_randseed}"
        printf 'healthy_randseed=%s\n' "${healthy_randseed}"
    } > "${run_dir}/metadata"

    dmesg -C >/dev/null 2>&1 || true
    dmesg --ctime --follow > "${run_dir}/dmesg_follow.log" 2>&1 &
    dmesg_pid="$!"

    bc_eh_iscsi_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=start"

    bc_eh_start_fio_job \
        "fault" \
        "${run_dir}/fault_fio.stdout" \
        "fault_${BC_EH_CASE}" \
        "${fault_dev}" \
        "${BC_EH_ISCSI_FAULT_RUNTIME}" \
        "${fault_iodepth}" \
        "${run_dir}/fault" \
        "${fault_cpu}" \
        "${fault_log_avg_msec}" \
        "${fault_stable_mode}" \
        "${fault_randseed}"
    fault_pid="${BC_EH_FIO_PID}"
    fault_tee_pid="${BC_EH_TEE_PID}"

    if [ "${run_healthy_stream}" -eq 1 ]; then
        bc_eh_start_fio_job \
            "healthy" \
            "${run_dir}/healthy_fio.stdout" \
            "healthy_${BC_EH_CASE}" \
            "${healthy_dev}" \
            "${BC_EH_ISCSI_HEALTHY_RUNTIME}" \
            "${healthy_iodepth}" \
            "${run_dir}/healthy" \
            "${healthy_cpu}" \
            "${healthy_log_avg_msec}" \
            "${healthy_stable_mode}" \
            "${healthy_randseed}"
        healthy_pid="${BC_EH_FIO_PID}"
        healthy_tee_pid="${BC_EH_TEE_PID}"
    else
        printf 'healthy stream skipped for case %s\n' "${BC_EH_CASE}" > "${run_dir}/healthy_fio.stdout"
    fi

    sleep "${prefault_secs}"
    inject_epoch="$(date '+%s.%N')"
    printf 'inject_epoch=%s\n' "${inject_epoch}" >> "${run_dir}/metadata"
    bc_eh_iscsi_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=inject epoch=${inject_epoch}"
    bc_eh_iscsi_arm_case "${BC_EH_CASE}"

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
    bc_eh_iscsi_mark "case=${BC_EH_CASE} profile=${BC_EH_PROFILE} event=finish epoch=${finish_epoch}"

    bc_eh_iscsi_clear_injection
    sleep 2

    if [ -n "${dmesg_pid}" ] && kill -0 "${dmesg_pid}" >/dev/null 2>&1; then
        kill "${dmesg_pid}" >/dev/null 2>&1 || true
        wait "${dmesg_pid}" >/dev/null 2>&1 || true
    fi

    dmesg --ctime > "${run_dir}/dmesg_after.log" 2>&1 || true
    if [ "${auto_session_started}" -eq 1 ]; then
        bc_eh_iscsi_guest_cleanup_session
    fi

    bc_eh_log "run finished: ${run_dir}"
    printf 'RESULT run_dir=%s profile=%s case=%s fault_rc=%s healthy_rc=%s\n' \
        "${run_dir}" "${BC_EH_PROFILE}" "${BC_EH_CASE}" "${fault_rc}" "${healthy_rc}"
}

main "$@"
