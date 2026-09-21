#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/kafka_jbod_common.sh"

main() {
    kafka_jbod_require_root

    kafka_jbod_log "Unmounting Kafka JBOD mount points if present"
    kafka_jbod_umount_data_dirs

    kafka_jbod_log "Unloading scsi_debug-related modules if present"
    bc_eh_cleanup_scsi_debug_env

    if [ "$(kafka_jbod_scsi_debug_host_count)" -ne 0 ]; then
        kafka_jbod_die "scsi_debug host still present after cleanup"
    fi

    kafka_jbod_log "Kafka JBOD cleanup finished"
}

main "$@"
