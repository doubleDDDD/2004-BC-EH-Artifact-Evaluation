#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/kafka_jbod_common.sh"

main() {
    local host_name=''

    kafka_jbod_require_root

    kafka_jbod_log "Cleaning old Kafka JBOD mounts and stale scsi_debug modules"
    kafka_jbod_umount_data_dirs
    bc_eh_cleanup_scsi_debug_env

    kafka_jbod_log "Loading scsi_debug topology: 1 host / 1 channel / 3 targets / 1 lun"
    kafka_jbod_load_scsi_debug

    host_name="$(kafka_jbod_wait_for_expected_devices "${SDEBUG_WAIT_SECS}")"
    kafka_jbod_log "Detected scsi_debug host: ${host_name}"

    kafka_jbod_set_queue_tuning
    kafka_jbod_print_mapping_summary
}

main "$@"
