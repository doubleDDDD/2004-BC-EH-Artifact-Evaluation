#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_OUTPUT_DIR="${SCRIPT_DIR}/workload/output"
FORMAL_TOPIC_OUTPUT_DIR="${SCRIPT_DIR}/formal_topic/output"
FAULT_OUTPUT_DIR="${SCRIPT_DIR}/fault_injection/output"

log() {
    printf '[cleanup-kafka-jbod-experiment] %s\n' "$*"
}

warn() {
    printf '[cleanup-kafka-jbod-experiment][warn] %s\n' "$*" >&2
}

die() {
    printf '[cleanup-kafka-jbod-experiment][error] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "this script must run as root"
    fi
}

show_producer_state() {
    log "Current producer-perf processes:"
    ps -ef | grep -E '[k]afka\.tools\.ProducerPerformance|[k]afka-producer-perf-test\.sh' || true
}

stop_formal_producer() {
    local retries=10
    local pids=''

    log "Stopping producer-perf processes if present"
    pkill -f 'kafka\.tools\.ProducerPerformance' || true
    pkill -f 'kafka-producer-perf-test\.sh' || true

    for _ in $(seq 1 "${retries}"); do
        pids="$(pgrep -f 'kafka\.tools\.ProducerPerformance|kafka-producer-perf-test\.sh' || true)"
        if [[ -z "${pids}" ]]; then
            break
        fi
        sleep 1
    done

    pids="$(pgrep -f 'kafka\.tools\.ProducerPerformance|kafka-producer-perf-test\.sh' || true)"
    if [[ -n "${pids}" ]]; then
        warn "Graceful stop did not finish; sending SIGKILL to: ${pids}"
        kill -9 ${pids} || true
        sleep 1
    fi

    pids="$(pgrep -f 'kafka\.tools\.ProducerPerformance|kafka-producer-perf-test\.sh' || true)"
    if [[ -n "${pids}" ]]; then
        warn "Producer-perf processes still present after SIGKILL: ${pids}"
        return 1
    fi

    log "Producer-perf processes are fully stopped"
}

cleanup_output_dir() {
    local dir="$1"

    mkdir -p "${dir}"
    log "Cleaning directory contents: ${dir}"
    find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

main() {
    require_root

    show_producer_state
    stop_formal_producer

    cleanup_output_dir "${WORKLOAD_OUTPUT_DIR}"
    cleanup_output_dir "${FORMAL_TOPIC_OUTPUT_DIR}"
    cleanup_output_dir "${FAULT_OUTPUT_DIR}"

    log "Post-cleanup producer state:"
    show_producer_state
    log "Kafka JBOD experiment output cleanup finished"
}

main "$@"
