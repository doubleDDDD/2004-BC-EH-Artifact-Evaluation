#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
. "${TOP_DIR}/formal_topic_common.sh"

validate_topic_metadata() {
    local describe_output="$1"

    printf '%s\n' "${describe_output}" | grep -q "Topic: ${FORMAL_TOPIC_NAME}" || \
        ft_die "formal topic ${FORMAL_TOPIC_NAME} not found in describe output"
    printf '%s\n' "${describe_output}" | grep -Eq "PartitionCount:[[:space:]]*${FORMAL_TOPIC_PARTITIONS}" || \
        ft_die "formal topic ${FORMAL_TOPIC_NAME} partition count mismatch; if the topic already exists with a different layout, delete it and recreate"
    printf '%s\n' "${describe_output}" | grep -Eq "ReplicationFactor:[[:space:]]*${FORMAL_TOPIC_REPLICATION_FACTOR}" || \
        ft_die "formal topic ${FORMAL_TOPIC_NAME} replication factor mismatch; if the topic already exists with a different layout, delete it and recreate"
}

main() {
    local bootstrap_server=''
    local describe_output=''
    local describe_file=''

    ft_require_root
    ft_require_tools kafka-topics.sh
    ft_prepare_output_dir

    bootstrap_server="$(ft_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        ft_warn "BOOTSTRAP_SERVER not set; using local broker ${bootstrap_server}"
    fi

    ft_wait_for_bootstrap_server "${bootstrap_server}"

    ft_log "Creating or reusing formal topic ${FORMAL_TOPIC_NAME}"
    "${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --create \
        --if-not-exists \
        --topic "${FORMAL_TOPIC_NAME}" \
        --partitions "${FORMAL_TOPIC_PARTITIONS}" \
        --replication-factor "${FORMAL_TOPIC_REPLICATION_FACTOR}" \
        --bootstrap-server "${bootstrap_server}"

    ft_log "Describing formal topic ${FORMAL_TOPIC_NAME}"
    describe_output="$("${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}")"
    describe_file="$(ft_topic_describe_file)"
    printf '%s\n' "${describe_output}" > "${describe_file}"
    printf '%s\n' "${describe_output}"

    validate_topic_metadata "${describe_output}"

    ft_log "Saved formal topic describe output to ${describe_file}"
    ft_log "Formal topic creation/validation finished successfully"
}

main "$@"
