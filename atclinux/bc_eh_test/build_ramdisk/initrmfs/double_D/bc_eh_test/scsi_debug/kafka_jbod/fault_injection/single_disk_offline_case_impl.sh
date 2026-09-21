#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/fault_injection_common.sh"

readonly CASE_NAME="single_disk_offline"

main() {
    local bootstrap_server=''
    local run_dir=''
    local scsi_debug_host=''
    local scsi_id=''
    local dev_path=''
    local target_id=''
    local final_state=''
    local result='timeout'
    local inject_start_epoch=''
    local elapsed_secs=''
    local fault_state=''
    local settle_result='not_run'

    kf_require_root
    kf_require_tools kafka-topics.sh kafka-log-dirs.sh
    kf_prepare_output_root
    kf_assert_local_target_broker
    kf_verify_fault_target_mount

    bootstrap_server="$(kf_resolve_bootstrap_server)"
    kf_wait_for_bootstrap_server "${bootstrap_server}"

    scsi_debug_host="$(kf_resolve_scsi_debug_host)"
    kf_set_eh_mode "${scsi_debug_host}"
    scsi_id="$(kf_fault_scsi_id)"
    dev_path="$(kf_fault_dev_path)"
    target_id="$(kf_fault_target_id "${scsi_id}")"
    run_dir="$(kf_prepare_run_dir "${CASE_NAME}")"

    kf_log "Running ${CASE_NAME} under $(kf_eh_identity)"
    kf_write_run_metadata "${run_dir}" "${CASE_NAME}" "${bootstrap_server}" \
        "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}"

    kf_log "Saving pre-fault snapshot to ${run_dir}/pre_fault"
    kf_collect_snapshot "${run_dir}" "pre_fault" "${bootstrap_server}" \
        "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}"

    kf_clear_dmesg_ring
    printf 'inject_start_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        >> "${run_dir}/run.meta.txt"
    inject_start_epoch="$(date +%s)"
    kf_log "Injecting unrecoverable single-disk fault on ${scsi_id} (${dev_path})"
    kf_apply_offline_fault_rules "${scsi_id}"

    kf_log "Saving inject-armed snapshot to ${run_dir}/inject_armed"
    kf_collect_snapshot "${run_dir}" "inject_armed" "${bootstrap_server}" \
        "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}" "meta"

    while :; do
        elapsed_secs="$(( $(date +%s) - inject_start_epoch ))"
        fault_state="$(kf_read_scsi_state "${scsi_id}")"

        if [[ "${fault_state}" = "offline" ]]; then
            result='offline'
            break
        fi

        if (( elapsed_secs >= OFFLINE_WAIT_SECS )); then
            break
        fi

        sleep 1
    done

    if [[ "${result}" = "offline" ]]; then
        kf_log "Fault disk reached offline state"
        kf_collect_snapshot "${run_dir}" "offline_observed" "${bootstrap_server}" \
            "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}" "light"

        kf_log "Waiting for Kafka topic state to settle after offline"
        if kf_wait_for_topic_describe_stable \
            "${bootstrap_server}" \
            "${POST_FAULT_SETTLE_TIMEOUT_SECS}" \
            "${POST_FAULT_SETTLE_POLL_INTERVAL_SECS}" \
            "${POST_FAULT_SETTLE_STABLE_ROUNDS}"; then
            settle_result='stable'
        else
            settle_result='timeout'
            kf_warn "Kafka topic state did not settle within ${POST_FAULT_SETTLE_TIMEOUT_SECS}s; capturing best-effort final snapshot"
        fi

        printf '%s\n' \
            "post_fault_settle_result=${settle_result}" \
            "post_fault_settle_timeout_secs=${POST_FAULT_SETTLE_TIMEOUT_SECS}" \
            "post_fault_settle_poll_interval_secs=${POST_FAULT_SETTLE_POLL_INTERVAL_SECS}" \
            "post_fault_settle_stable_rounds=${POST_FAULT_SETTLE_STABLE_ROUNDS}" \
            >> "${run_dir}/run.meta.txt"

        kf_log "Saving post-fault settled snapshot to ${run_dir}/post_fault_settled"
        kf_collect_snapshot "${run_dir}" "post_fault_settled" "${bootstrap_server}" \
            "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}"
    else
        kf_warn "Fault disk did not reach offline within ${OFFLINE_WAIT_SECS}s"
        kf_collect_snapshot "${run_dir}" "timeout_observed" "${bootstrap_server}" \
            "${scsi_debug_host}" "${scsi_id}" "${dev_path}" "${target_id}"
    fi

    final_state="$(kf_read_scsi_state "${scsi_id}")"
    kf_capture_final_dmesg "${run_dir}"
    kf_archive_broker_server_logs "${run_dir}"
    cat >> "${run_dir}/run.meta.txt" <<EOF
inject_result=${result}
inject_end_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fault_final_scsi_state=${final_state}
EOF

    kf_log "Offline case finished with result=${result}, final_state=${final_state}"
    kf_log "Raw outputs are in ${run_dir}"
    kf_warn "This case does not auto-recover the faulted disk; rerun setup_kafka_jbod_baseline.sh before the next round"
}

main "$@"
