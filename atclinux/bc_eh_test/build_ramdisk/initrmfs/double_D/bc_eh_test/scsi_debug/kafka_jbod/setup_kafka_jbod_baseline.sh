#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '[setup-kafka-jbod] %s\n' "$*"
}

main() {
    log "Resetting Kafka runtime state"
    bash "$SCRIPT_DIR/00_reset_kafka_runtime_env.sh"

    log "Cleaning old Kafka JBOD topology"
    bash "$SCRIPT_DIR/99_cleanup_kafka_jbod.sh"

    log "Regenerating Kafka broker configs"
    bash "$SCRIPT_DIR/01_generate_kafka_properties.sh"

    log "Loading Kafka JBOD scsi_debug topology"
    bash "$SCRIPT_DIR/10_load_kafka_jbod_topology.sh"

    log "Preparing Kafka JBOD data mounts"
    bash "$SCRIPT_DIR/11_prepare_kafka_data_mounts.sh"

    log "Verifying Kafka JBOD layout"
    bash "$SCRIPT_DIR/12_verify_kafka_jbod_layout.sh"

    log "Formatting local Kafka storage"
    bash "$SCRIPT_DIR/02_format_local_kafka_storage.sh"

    log "Starting local Kafka broker"
    bash "$SCRIPT_DIR/03_start_local_kafka_broker.sh"

    log "Current baseline setup finished"
}

main "$@"
