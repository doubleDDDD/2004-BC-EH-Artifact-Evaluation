#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/root/kafka_2.13-4.2.0/config"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
START_WAIT_SECS="${START_WAIT_SECS:-20}"
LOG_FILE="/root/kafka_2.13-4.2.0/logs/server.log"

log() {
    printf '[kafka-start] %s\n' "$*"
}

warn() {
    printf '[kafka-start][warn] %s\n' "$*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must run as root." >&2
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

ports_ready() {
    ss -ltnp | grep -q ':9092 ' && ss -ltnp | grep -q ':9093 '
}

broker_process_running() {
    local config_file="$1"

    pgrep -f "kafka\.Kafka.*$config_file" >/dev/null 2>&1
}

main() {
    local broker_id=''
    local config_file=''
    local i=''

    require_root

    if [[ ! -x "/root/kafka_2.13-4.2.0/bin/kafka-server-start.sh" ]]; then
        warn "kafka-server-start.sh not found or not executable: /root/kafka_2.13-4.2.0/bin/kafka-server-start.sh"
        exit 1
    fi

    broker_id="$(detect_local_broker_id)"
    config_file="$CONFIG_DIR/kafka-$broker_id.properties"

    if [[ ! -f "$config_file" ]]; then
        warn "Config file not found: $config_file"
        exit 1
    fi

    if broker_process_running "$config_file"; then
        log "Kafka broker $broker_id already appears to be running"
        ss -ltnp | egrep '9092|9093' || true
        exit 0
    fi

    log "Starting broker $broker_id with $config_file"
    "/root/kafka_2.13-4.2.0/bin/kafka-server-start.sh" -daemon "$config_file"

    for i in $(seq 1 "$START_WAIT_SECS"); do
        if ports_ready; then
            log "Broker $broker_id is listening on 9092/9093"
            ss -ltnp | egrep '9092|9093' || true
            exit 0
        fi
        if ! broker_process_running "$config_file"; then
            break
        fi
        sleep 1
    done

    if broker_process_running "$config_file"; then
        warn "Broker $broker_id did not become ready within ${START_WAIT_SECS}s, but the process is still running"
        warn "In the 3-node KRaft baseline this usually means peers are not all up yet; continue starting the remaining VMs, then run basic_validation/run_basic_validation.sh"
        if [[ -f "$LOG_FILE" ]]; then
            warn "Recent server log:"
            tail -n 20 "$LOG_FILE" >&2 || true
        fi
        exit 0
    fi

    warn "Broker $broker_id exited before becoming ready"
    if [[ -f "$LOG_FILE" ]]; then
        warn "Recent server log:"
        tail -n 40 "$LOG_FILE" >&2 || true
    fi
    exit 1
}

main "$@"
