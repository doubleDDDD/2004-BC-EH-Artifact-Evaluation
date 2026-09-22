#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/root/kafka_2.13-4.2.0/config"
CLUSTER_ID="${CLUSTER_ID:-JfPM4evGQ2e3ZnxRI2iSmA}"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
METADATA_DIR="${METADATA_DIR:-/var/lib/kafka-metadata}"
REQUIRE_MOUNTED_DATA_DIRS="${REQUIRE_MOUNTED_DATA_DIRS:-1}"
DATA_DIRS=(
    "${DATA_DIR1:-/data/kafka-1}"
    "${DATA_DIR2:-/data/kafka-2}"
    "${DATA_DIR3:-/data/kafka-3}"
)

log() {
    printf '[kafka-format] %s\n' "$*"
}

warn() {
    printf '[kafka-format][warn] %s\n' "$*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must run as root." >&2
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Required command not found: $cmd"
        exit 1
    fi
}

detect_local_broker_id() {
    local cluster_ip=''

    cluster_ip="$(
        ip -4 -o addr show dev "$CLUSTER_NET_IF" 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -n 1
    )"

    case "$cluster_ip" in
        10.20.0.11) echo 1 ;;
        10.20.0.12) echo 2 ;;
        10.20.0.13) echo 3 ;;
        *)
            warn "Cannot infer broker id from $CLUSTER_NET_IF address: ${cluster_ip:-<none>}"
            return 1
            ;;
    esac
}

verify_storage_layout() {
    local dir=''

    mkdir -p "$METADATA_DIR"

    for dir in "${DATA_DIRS[@]}"; do
        mkdir -p "$dir"
        if [[ "$REQUIRE_MOUNTED_DATA_DIRS" == "1" ]] && ! mountpoint -q "$dir"; then
            warn "$dir is not a mounted filesystem"
            warn "Refusing to format Kafka storage on the system disk view"
            warn "If this is intentional, rerun with REQUIRE_MOUNTED_DATA_DIRS=0"
            exit 1
        fi
    done
}

main() {
    local broker_id=''
    local config_file=''

    require_root
    require_command ip
    require_command mountpoint

    if [[ ! -x "/root/kafka_2.13-4.2.0/bin/kafka-storage.sh" ]]; then
        warn "kafka-storage.sh not found or not executable: /root/kafka_2.13-4.2.0/bin/kafka-storage.sh"
        exit 1
    fi

    broker_id="$(detect_local_broker_id)"
    config_file="$CONFIG_DIR/kafka-$broker_id.properties"

    if [[ ! -f "$config_file" ]]; then
        warn "Config file not found: $config_file"
        exit 1
    fi

    verify_storage_layout

    log "Formatting broker $broker_id with cluster id $CLUSTER_ID"
    "/root/kafka_2.13-4.2.0/bin/kafka-storage.sh" format \
        --cluster-id "$CLUSTER_ID" \
        --config "$config_file"

    if [[ -f "$METADATA_DIR/meta.properties" ]]; then
        log "Generated metadata:"
        grep -E '^(cluster\.id|node\.id|version)=' "$METADATA_DIR/meta.properties" || true
    fi

    log "Local Kafka storage format finished"
}

main "$@"
