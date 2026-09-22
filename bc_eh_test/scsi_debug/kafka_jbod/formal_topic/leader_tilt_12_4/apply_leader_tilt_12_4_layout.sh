#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/leader_tilt_12_4_common.sh"

topic_exists() {
    local bootstrap_server="$1"

    "${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}" >/dev/null 2>&1
}

validate_existing_topic_shape() {
    local bootstrap_server="$1"
    local describe_output=''

    describe_output="$("${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}")"

    printf '%s\n' "${describe_output}" | grep -Eq "PartitionCount:[[:space:]]*${FORMAL_TOPIC_PARTITIONS}" || \
        ft_die "existing topic ${FORMAL_TOPIC_NAME} partition count mismatch"
    printf '%s\n' "${describe_output}" | grep -Eq "ReplicationFactor:[[:space:]]*${FORMAL_TOPIC_REPLICATION_FACTOR}" || \
        ft_die "existing topic ${FORMAL_TOPIC_NAME} replication factor mismatch"
}

wait_for_reassignment() {
    local bootstrap_server="$1"
    local verify_file=''
    local output=''
    local attempt=''

    verify_file="$(lt12_reassign_verify_file)"

    for attempt in $(seq 1 "${LT12_REASSIGN_VERIFY_ATTEMPTS}"); do
        output="$("${KAFKA_BIN_DIR}/kafka-reassign-partitions.sh" \
            --bootstrap-server "${bootstrap_server}" \
            --verify \
            --reassignment-json-file "$(lt12_reassignment_file)" 2>&1 || true)"
        printf '%s\n' "${output}" > "${verify_file}"

        if printf '%s\n' "${output}" | grep -qi "failed"; then
            ft_die "partition reassignment reported failure; see ${verify_file}"
        fi
        if printf '%s\n' "${output}" | grep -qi "still in progress"; then
            sleep "${LT12_REASSIGN_VERIFY_INTERVAL_SECS}"
            continue
        fi
        return 0
    done

    ft_die "partition reassignment did not finish within the expected time; see ${verify_file}"
}

run_preferred_leader_election() {
    local bootstrap_server="$1"

    if [[ -x "${KAFKA_BIN_DIR}/kafka-leader-election.sh" ]]; then
        "${KAFKA_BIN_DIR}/kafka-leader-election.sh" \
            --bootstrap-server "${bootstrap_server}" \
            --election-type PREFERRED \
            --path-to-json-file "$(lt12_preferred_election_file)"
        return 0
    fi

    if [[ -x "${KAFKA_BIN_DIR}/kafka-preferred-replica-election.sh" ]]; then
        "${KAFKA_BIN_DIR}/kafka-preferred-replica-election.sh" \
            --bootstrap-server "${bootstrap_server}" \
            --path-to-json-file "$(lt12_preferred_election_file)"
        return 0
    fi

    ft_die "neither kafka-leader-election.sh nor kafka-preferred-replica-election.sh is available in ${KAFKA_BIN_DIR}"
}

wait_for_exact_layout() {
    local bootstrap_server="$1"
    local attempt=''

    for attempt in $(seq 1 "${LT12_LAYOUT_VERIFY_ATTEMPTS}"); do
        if BOOTSTRAP_SERVER="${bootstrap_server}" bash "${SCRIPT_DIR}/check_leader_tilt_12_4_layout.sh" >/dev/null 2>&1; then
            return 0
        fi
        sleep "${LT12_LAYOUT_VERIFY_INTERVAL_SECS}"
    done

    BOOTSTRAP_SERVER="${bootstrap_server}" bash "${SCRIPT_DIR}/check_leader_tilt_12_4_layout.sh"
    ft_die "leader_tilt_12_4 exact layout was not observed within the expected time"
}

main() {
    local bootstrap_server=''
    local assignment=''

    ft_require_root
    ft_require_tools kafka-topics.sh kafka-reassign-partitions.sh
    command -v python3 >/dev/null 2>&1 || ft_die "python3 is required for leader_tilt_12_4 planning"
    ft_prepare_output_dir
    lt12_generate_plan_files

    bootstrap_server="$(ft_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        ft_warn "BOOTSTRAP_SERVER not set; using local broker ${bootstrap_server}"
    fi

    ft_wait_for_bootstrap_server "${bootstrap_server}"

    if topic_exists "${bootstrap_server}"; then
        ft_log "Formal topic ${FORMAL_TOPIC_NAME} already exists; reusing it and converging to leader_tilt_12_4"
        validate_existing_topic_shape "${bootstrap_server}"
    else
        assignment="$(tr -d '\n' < "$(lt12_replica_assignment_file)")"
        ft_log "Creating formal topic ${FORMAL_TOPIC_NAME} with deterministic replica ordering for leader_tilt_12_4"
        "${KAFKA_BIN_DIR}/kafka-topics.sh" \
            --create \
            --topic "${FORMAL_TOPIC_NAME}" \
            --bootstrap-server "${bootstrap_server}" \
            --replica-assignment "${assignment}"
    fi

    ft_log "Executing deterministic replica/log.dir reassignment for leader_tilt_12_4"
    "${KAFKA_BIN_DIR}/kafka-reassign-partitions.sh" \
        --bootstrap-server "${bootstrap_server}" \
        --execute \
        --reassignment-json-file "$(lt12_reassignment_file)"

    ft_log "Waiting for replica/log.dir reassignment to finish"
    wait_for_reassignment "${bootstrap_server}"

    ft_log "Running preferred leader election so broker-1 leaders land on the planned 12/4 layout"
    run_preferred_leader_election "${bootstrap_server}"

    ft_log "Waiting for exact 12/4 layout to converge"
    wait_for_exact_layout "${bootstrap_server}"

    ft_log "leader_tilt_12_4 layout apply finished"
    ft_log "Plan summary: $(lt12_layout_plan_summary_file)"
    ft_log "Exact-layout summary: $(lt12_actual_summary_file)"
}

main "$@"
