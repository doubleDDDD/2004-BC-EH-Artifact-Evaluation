#!/usr/bin/env bash
set -euo pipefail

METADATA_DIR="${METADATA_DIR:-/var/lib/kafka-metadata}"
KAFKA_LOG_SUBDIR="${KAFKA_LOG_SUBDIR:-kafka-logs}"
DATA_MOUNT_DIRS=(
    "${DATA_DIR1:-/data/kafka-1}"
    "${DATA_DIR2:-/data/kafka-2}"
    "${DATA_DIR3:-/data/kafka-3}"
)
LOG_DIR="/root/kafka_2.13-4.2.0/logs"

log() {
    printf '[reset-kafka] %s\n' "$*"
}

warn() {
    printf '[reset-kafka][warn] %s\n' "$*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must run as root." >&2
        exit 1
    fi
}

show_state() {
    log "Current Kafka-related java processes:"
    ps -ef | grep -E '[o]rg\.apache\.kafka|[k]afka\.Kafka' || true

    log "Current listeners on 9092/9093:"
    ss -ltnp | egrep '9092|9093' || true
}

dir_mount_options() {
    local dir="$1"
    findmnt -n -o OPTIONS --target "$dir" 2>/dev/null || true
}

dir_is_on_readonly_mount() {
    local dir="$1"
    local mount_opts=''

    mount_opts="$(dir_mount_options "$dir")"
    [[ ",${mount_opts}," == *,ro,* ]]
}

stop_kafka() {
    log "Stopping Kafka processes if present"
    pkill -f 'org.apache.kafka' || true
    pkill -f 'kafka.Kafka' || true

    local retries=10
    local pids=''
    for _ in $(seq 1 "$retries"); do
        pids="$(pgrep -f 'org.apache.kafka|kafka.Kafka' || true)"
        if [[ -z "$pids" ]]; then
            break
        fi
        sleep 1
    done

    pids="$(pgrep -f 'org.apache.kafka|kafka.Kafka' || true)"
    if [[ -n "$pids" ]]; then
        warn "Graceful stop did not finish; sending SIGKILL to: $pids"
        kill -9 $pids || true
        sleep 1
    fi

    pids="$(pgrep -f 'org.apache.kafka|kafka.Kafka' || true)"
    if [[ -n "$pids" ]]; then
        warn "Kafka processes still present after SIGKILL: $pids"
        return 1
    fi

    log "Kafka processes are fully stopped"
}

cleanup_dir_contents() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if dir_is_on_readonly_mount "$dir"; then
            warn "Directory is on a read-only mount, skipping content cleanup until topology teardown: $dir"
            return 0
        fi

        log "Cleaning directory contents: $dir"
        if ! rm -rf -- "$dir"/*; then
            if dir_is_on_readonly_mount "$dir"; then
                warn "Directory turned read-only during cleanup, skipping remaining contents: $dir"
                return 0
            fi
            warn "Failed to clean directory contents: $dir"
            return 1
        fi
    else
        warn "Directory not found, skipping: $dir"
    fi
}

main() {
    local dir=''

    require_root

    log "Kafka runtime reset started"
    show_state
    stop_kafka

    cleanup_dir_contents "$METADATA_DIR"
    for dir in "${DATA_MOUNT_DIRS[@]}"; do
        cleanup_dir_contents "${dir}/${KAFKA_LOG_SUBDIR}" || \
            warn "Skipping Kafka data-dir cleanup before topology teardown: ${dir}/${KAFKA_LOG_SUBDIR}"
    done
    cleanup_dir_contents "$LOG_DIR"

    log "Post-cleanup process state:"
    show_state

    if ss -ltnp | egrep -q '9092|9093'; then
        warn "Ports 9092/9093 are still listening after cleanup"
        exit 1
    fi

    log "Kafka runtime reset finished successfully"
}

main "$@"
