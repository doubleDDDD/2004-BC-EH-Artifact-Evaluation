#!/usr/bin/env bash
set -euo pipefail

KAFKA_HOME="${KAFKA_HOME:-/root/kafka_2.13-4.2.0}"
KAFKA_BIN_DIR="${KAFKA_HOME}/bin"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-}"
BOOTSTRAP_WAIT_SECS="${BOOTSTRAP_WAIT_SECS:-60}"
SMOKE_TOPIC="${SMOKE_TOPIC:-smoke}"
SMOKE_PARTITIONS="${SMOKE_PARTITIONS:-12}"
SMOKE_REPLICATION_FACTOR="${SMOKE_REPLICATION_FACTOR:-3}"

log() {
    printf '[kafka-basic-validation] %s\n' "$*"
}

warn() {
    printf '[kafka-basic-validation][warn] %s\n' "$*" >&2
}

die() {
    printf '[kafka-basic-validation][error] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "this script must run as root"
    fi
}

require_tools() {
    [[ -x "${KAFKA_BIN_DIR}/kafka-metadata-quorum.sh" ]] || \
        die "kafka-metadata-quorum.sh not found: ${KAFKA_BIN_DIR}/kafka-metadata-quorum.sh"
    [[ -x "${KAFKA_BIN_DIR}/kafka-topics.sh" ]] || \
        die "kafka-topics.sh not found: ${KAFKA_BIN_DIR}/kafka-topics.sh"
}

detect_local_broker_ip() {
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

resolve_bootstrap_server() {
    local cluster_ip=''

    if [[ -n "${BOOTSTRAP_SERVER}" ]]; then
        printf '%s\n' "${BOOTSTRAP_SERVER}"
        return 0
    fi

    if cluster_ip="$(detect_local_broker_ip)"; then
        printf '%s:9092\n' "${cluster_ip}"
        return 0
    fi

    die "cannot infer local bootstrap server from ${CLUSTER_NET_IF}; set BOOTSTRAP_SERVER explicitly"
}

wait_for_bootstrap_server() {
    local bootstrap_server="$1"
    local host="${bootstrap_server%:*}"
    local port="${bootstrap_server##*:}"
    local attempt=''

    log "Waiting for bootstrap server ${bootstrap_server}"
    for attempt in $(seq 1 "${BOOTSTRAP_WAIT_SECS}"); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    die "bootstrap server ${bootstrap_server} is not reachable within ${BOOTSTRAP_WAIT_SECS}s; verify all setup scripts have finished, the local broker is up, and ${CLUSTER_NET_IF} networking is correct"
}

run_quorum_check() {
    local bootstrap_server="$1"
    local quorum_output=''
    local current_voters_line=''

    log "Checking KRaft quorum via ${bootstrap_server}"
    quorum_output="$("${KAFKA_BIN_DIR}/kafka-metadata-quorum.sh" \
        --bootstrap-server "${bootstrap_server}" \
        describe --status)"
    printf '%s\n' "${quorum_output}"

    printf '%s\n' "${quorum_output}" | grep -Eq '^LeaderId:[[:space:]]*[1-9][0-9]*$' || \
        die "quorum output does not show a valid LeaderId"
    current_voters_line="$(
        printf '%s\n' "${quorum_output}" \
        | sed -n 's/^CurrentVoters:[[:space:]]*//p' \
        | head -n 1
    )"
    [[ -n "${current_voters_line//[[:space:]]/}" ]] || \
        die "quorum output does not show CurrentVoters"
    [[ "${current_voters_line}" != *"[]"* ]] || \
        die "quorum output shows an empty CurrentVoters set"
}

run_smoke_topic_check() {
    local bootstrap_server="$1"
    local describe_output=''

    log "Creating or reusing smoke topic ${SMOKE_TOPIC}"
    "${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --create \
        --if-not-exists \
        --topic "${SMOKE_TOPIC}" \
        --partitions "${SMOKE_PARTITIONS}" \
        --replication-factor "${SMOKE_REPLICATION_FACTOR}" \
        --bootstrap-server "${bootstrap_server}"

    log "Describing smoke topic ${SMOKE_TOPIC}"
    describe_output="$("${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${SMOKE_TOPIC}" \
        --bootstrap-server "${bootstrap_server}")"
    printf '%s\n' "${describe_output}"

    printf '%s\n' "${describe_output}" | grep -q "Topic: ${SMOKE_TOPIC}" || \
        die "smoke topic ${SMOKE_TOPIC} not found in describe output"
    printf '%s\n' "${describe_output}" | grep -Eq "PartitionCount:[[:space:]]*${SMOKE_PARTITIONS}" || \
        die "smoke topic ${SMOKE_TOPIC} partition count mismatch"
    printf '%s\n' "${describe_output}" | grep -Eq "ReplicationFactor:[[:space:]]*${SMOKE_REPLICATION_FACTOR}" || \
        die "smoke topic ${SMOKE_TOPIC} replication factor mismatch"
}

main() {
    local bootstrap_server=''

    require_root
    require_tools

    bootstrap_server="$(resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        warn "BOOTSTRAP_SERVER not set; using local broker ${bootstrap_server}"
    fi

    wait_for_bootstrap_server "${bootstrap_server}"
    run_quorum_check "${bootstrap_server}"
    run_smoke_topic_check "${bootstrap_server}"

    log "Basic validation finished successfully"
}

main "$@"
