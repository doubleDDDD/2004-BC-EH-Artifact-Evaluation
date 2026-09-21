#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/kafka_jbod_common.sh"

main() {
    local host_count
    local host_name
    local expected_count
    local actual_count
    local target
    local dev_path
    local mount_dir
    local source
    local qd_file
    local nr_file
    local kafka_log_dir
    local kafka_log_subdir="${KAFKA_LOG_SUBDIR:-kafka-logs}"

    kafka_jbod_require_root

    host_count="$(kafka_jbod_scsi_debug_host_count)"
    [ "${host_count}" -eq 1 ] || kafka_jbod_die "expected exactly 1 scsi_debug host, got ${host_count}"

    host_name="$(kafka_jbod_wait_for_expected_devices "${SDEBUG_WAIT_SECS}")"
    expected_count="$(kafka_jbod_expected_device_count)"
    actual_count="$(kafka_jbod_count_scsi_devices_on_host "${host_name}")"
    [ "${actual_count}" -eq "${expected_count}" ] || \
        kafka_jbod_die "expected ${expected_count} devices on ${host_name}, got ${actual_count}"

    for target in 0 1 2; do
        dev_path="$(kafka_jbod_dev_for_target "${target}")"
        mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"

        mountpoint -q "${mount_dir}" || kafka_jbod_die "${mount_dir} is not mounted"
        source="$(findmnt -n -o SOURCE --target "${mount_dir}" 2>/dev/null || true)"
        [ "${source}" = "${dev_path}" ] || \
            kafka_jbod_die "${mount_dir} expected source ${dev_path}, got ${source:-<none>}"
        kafka_log_dir="${mount_dir}/${kafka_log_subdir}"
        [ -d "${kafka_log_dir}" ] || kafka_jbod_die "missing Kafka log dir ${kafka_log_dir}"

        qd_file="/sys/class/scsi_device/$(kafka_jbod_scsi_id_for_target "${target}")/device/queue_depth"
        nr_file="/sys/block/${dev_path#/dev/}/queue/nr_requests"
        [ -e "${qd_file}" ] || kafka_jbod_die "missing queue_depth file ${qd_file}"
        [ -e "${nr_file}" ] || kafka_jbod_die "missing nr_requests file ${nr_file}"
    done

    kafka_jbod_log "Verification passed"
    kafka_jbod_print_mapping_summary

    kafka_jbod_log "lsblk:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT

    kafka_jbod_print_mount_summary

    kafka_jbod_log "lsscsi:"
    if command -v lsscsi >/dev/null 2>&1; then
        lsscsi
    else
        kafka_jbod_warn "lsscsi not installed; using sysfs-derived mapping only"
    fi
}

main "$@"
