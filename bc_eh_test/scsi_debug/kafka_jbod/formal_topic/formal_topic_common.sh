#!/usr/bin/env bash
set -euo pipefail

FORMAL_TOPIC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAFKA_BIN_DIR="/root/kafka_2.13-4.2.0/bin"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-}"
BOOTSTRAP_WAIT_SECS="${BOOTSTRAP_WAIT_SECS:-60}"

FORMAL_TOPIC_NAME="${FORMAL_TOPIC_NAME:-jbod-hot}"
FORMAL_TOPIC_PARTITIONS="${FORMAL_TOPIC_PARTITIONS:-48}"
FORMAL_TOPIC_REPLICATION_FACTOR="${FORMAL_TOPIC_REPLICATION_FACTOR:-3}"
FORMAL_TOPIC_OUTPUT_DIR="${FORMAL_TOPIC_OUTPUT_DIR:-${FORMAL_TOPIC_SCRIPT_DIR}/output}"

FORMAL_TOPIC_TARGET_BROKER_ID="${FORMAL_TOPIC_TARGET_BROKER_ID:-1}"
FORMAL_TOPIC_TARGET_LOG_DIR="${FORMAL_TOPIC_TARGET_LOG_DIR:-/data/kafka-1/kafka-logs}"
FORMAL_TOPIC_MIN_TARGET_PARTITIONS="${FORMAL_TOPIC_MIN_TARGET_PARTITIONS:-8}"
FORMAL_TOPIC_MIN_TARGET_LEADERS="${FORMAL_TOPIC_MIN_TARGET_LEADERS:-3}"

ft_log() {
    printf '[kafka-formal-topic] %s\n' "$*"
}

ft_warn() {
    printf '[kafka-formal-topic][warn] %s\n' "$*" >&2
}

ft_die() {
    printf '[kafka-formal-topic][error] %s\n' "$*" >&2
    exit 1
}

ft_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        ft_die "this script must run as root"
    fi
}

ft_require_tools() {
    local tool_name=''

    for tool_name in "$@"; do
        [[ -x "${KAFKA_BIN_DIR}/${tool_name}" ]] || \
            ft_die "${tool_name} not found: ${KAFKA_BIN_DIR}/${tool_name}"
    done
}

ft_detect_local_broker_ip() {
    local cluster_ip=''

    cluster_ip="$(
        ip -4 -o addr show dev "${CLUSTER_NET_IF}" 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -n 1
    )"

    case "${cluster_ip}" in
        10.20.0.11|10.20.0.12|10.20.0.13)
            printf '%s\n' "${cluster_ip}"
            ;;
        *)
            return 1
            ;;
    esac
}

ft_resolve_bootstrap_server() {
    local cluster_ip=''

    if [[ -n "${BOOTSTRAP_SERVER}" ]]; then
        printf '%s\n' "${BOOTSTRAP_SERVER}"
        return 0
    fi

    if cluster_ip="$(ft_detect_local_broker_ip)"; then
        printf '%s:9092\n' "${cluster_ip}"
        return 0
    fi

    ft_die "cannot infer local bootstrap server from ${CLUSTER_NET_IF}; set BOOTSTRAP_SERVER explicitly"
}

ft_wait_for_bootstrap_server() {
    local bootstrap_server="$1"
    local host="${bootstrap_server%:*}"
    local port="${bootstrap_server##*:}"
    local attempt=''

    ft_log "Waiting for bootstrap server ${bootstrap_server}"
    for attempt in $(seq 1 "${BOOTSTRAP_WAIT_SECS}"); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    ft_die "bootstrap server ${bootstrap_server} is not reachable within ${BOOTSTRAP_WAIT_SECS}s"
}

ft_prepare_output_dir() {
    mkdir -p "${FORMAL_TOPIC_OUTPUT_DIR}"
}

ft_topic_safe_name() {
    local safe_name="${FORMAL_TOPIC_NAME//[^A-Za-z0-9._-]/_}"
    printf '%s\n' "${safe_name}"
}

ft_topic_describe_file() {
    printf '%s/%s.describe.txt\n' "${FORMAL_TOPIC_OUTPUT_DIR}" "$(ft_topic_safe_name)"
}

ft_topic_logdirs_file() {
    printf '%s/%s.logdirs.json\n' "${FORMAL_TOPIC_OUTPUT_DIR}" "$(ft_topic_safe_name)"
}

ft_topic_summary_file() {
    printf '%s/%s.layout_summary.txt\n' "${FORMAL_TOPIC_OUTPUT_DIR}" "$(ft_topic_safe_name)"
}
