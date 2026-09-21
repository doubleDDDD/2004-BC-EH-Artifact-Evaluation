#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/fault_injection_common.sh"

readonly CASE_NAME="single_disk_recoverable_stall"

FAULT_SCSI_ID=""

cleanup() {
    if [[ -n "${FAULT_SCSI_ID}" ]]; then
        kf_clear_stall_fault_rules "${FAULT_SCSI_ID}" || true
    fi
}

main() {
    local bootstrap_server=''
    local run_dir=''
    local scsi_debug_host=''
    local dev_path=''
    local target_id=''
    local final_state=''
    local result='timeout'

    trap cleanup EXIT INT TERM

    kf_require_root
    kf_require_tools kafka-topics.sh kafka-log-dirs.sh
    kf_prepare_output_root
    kf_assert_local_target_broker
    kf_verify_fault_target_mount

    bootstrap_server="$(kf_resolve_bootstrap_server)"
    kf_wait_for_bootstrap_server "${bootstrap_server}"

    scsi_debug_host="$(kf_resolve_scsi_debug_host)"
    kf_set_eh_mode "${scsi_debug_host}"
    FAULT_SCSI_ID="$(kf_fault_scsi_id)"
    dev_path="$(kf_fault_dev_path)"
    target_id="$(kf_fault_target_id "${FAULT_SCSI_ID}")"
    run_dir="$(kf_prepare_run_dir "${CASE_NAME}")"

    kf_log "Running ${CASE_NAME} under $(kf_eh_identity)"
    kf_write_run_metadata "${run_dir}" "${CASE_NAME}" "${bootstrap_server}" \
        "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}"

    kf_log "Saving pre-fault snapshot to ${run_dir}/pre_fault"
    kf_collect_snapshot "${run_dir}" "pre_fault" "${bootstrap_server}" \
        "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}"

    kf_clear_dmesg_ring
    printf 'inject_start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        >> "${run_dir}/run.meta.txt"
    kf_log "Injecting one-shot recoverable long-timeout fault on ${FAULT_SCSI_ID} (${dev_path}); expected path is device reset returns -> post-device TUR timeout -> target reset recover"
    kf_apply_stall_fault_rules "${FAULT_SCSI_ID}"

    kf_collect_snapshot "${run_dir}" "fault_start" "${bootstrap_server}" \
        "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}" "light"

    if (( STALL_MID_SNAPSHOT_SECS > 0 )); then
        sleep "${STALL_MID_SNAPSHOT_SECS}"
    fi

    kf_collect_snapshot "${run_dir}" "fault_mid" "${bootstrap_server}" \
        "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}" "light"

    printf 'fault_rules_clear_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        >> "${run_dir}/run.meta.txt"
    kf_log "Clearing residual debugfs fault rules after the one-shot stall window"
    kf_clear_stall_fault_rules "${FAULT_SCSI_ID}"

    kf_collect_snapshot "${run_dir}" "post_clear" "${bootstrap_server}" \
        "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}" "light"

    if (( RECOVERY_WAIT_SECS > 0 )); then
        kf_log "Waiting up to ${RECOVERY_WAIT_SECS}s for the fault disk to return to running"
        if kf_wait_for_scsi_state "${FAULT_SCSI_ID}" "running" "${RECOVERY_WAIT_SECS}"; then
            result='recovered'
        fi
    else
        if [[ "$(kf_read_scsi_state "${FAULT_SCSI_ID}")" = "running" ]]; then
            result='recovered'
        fi
    fi

    if [[ "${result}" = "recovered" ]]; then
        kf_log "Fault disk returned to running state"
        kf_collect_snapshot "${run_dir}" "recovered_observed" "${bootstrap_server}" \
            "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}"
    else
        kf_warn "Fault disk did not return to running within ${RECOVERY_WAIT_SECS}s"
        kf_collect_snapshot "${run_dir}" "timeout_observed" "${bootstrap_server}" \
            "${scsi_debug_host}" "${FAULT_SCSI_ID}" "${dev_path}" "${target_id}"
    fi

    final_state="$(kf_read_scsi_state "${FAULT_SCSI_ID}")"
    kf_capture_final_dmesg "${run_dir}"
    kf_archive_broker_server_logs "${run_dir}"
    cat >> "${run_dir}/run.meta.txt" <<EOF
inject_result=${result}
inject_recovery_path=device_reset_success_then_post_device_tur_timeout_then_target_reset_recover
inject_end_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fault_final_scsi_state=${final_state}
EOF

    kf_log "Recoverable stall case finished with result=${result}, final_state=${final_state}"
    kf_log "Raw outputs are in ${run_dir}"
}

main "$@"
