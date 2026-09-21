#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/workload_common.sh"

PINNED_WORKLOAD_PARTITIONS="${FORMAL_WORKLOAD_PINNED_PARTITIONS:-all}"
PINNED_WORKLOAD_CLIENT_ID_PREFIX="${FORMAL_WORKLOAD_PINNED_CLIENT_ID_PREFIX:-formal-pinned-worker}"
PINNED_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION="${FORMAL_WORKLOAD_PINNED_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION:-1}"

pwk_output_prefix() {
    printf '%s.formal_pinned_partition_workload' "$(wk_topic_safe_name)"
}

pwk_stdout_file() {
    printf '%s/%s.stdout.log\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_timestamped_stdout_file() {
    printf '%s/%s.stdout.timestamped.log\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_report_time_csv_file() {
    printf '%s/%s.report_time.csv\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_meta_file() {
    printf '%s/%s.meta.txt\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_command_file() {
    printf '%s/%s.command.txt\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_worker_summary_csv_file() {
    printf '%s/%s.worker_summary.csv\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

pwk_stderr_file() {
    printf '%s/%s.stderr.log\n' "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(pwk_output_prefix)"
}

main() {
    local bootstrap_server=''
    local num_records=''
    local stdout_file=''
    local timestamped_stdout_file=''
    local report_time_csv_file=''
    local worker_summary_csv_file=''
    local stderr_file=''
    local meta_file=''
    local command_file=''
    local java_source_file=''
    local java_classpath=''

    wk_require_root
    wk_require_commands java
    wk_prepare_output_dir

    bootstrap_server="$(wk_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        wk_warn "BOOTSTRAP_SERVER not set; using ${bootstrap_server}"
    fi

    wk_wait_for_bootstrap_server "${bootstrap_server}"
    num_records="$(wk_num_records)"
    stdout_file="$(pwk_stdout_file)"
    timestamped_stdout_file="$(pwk_timestamped_stdout_file)"
    report_time_csv_file="$(pwk_report_time_csv_file)"
    worker_summary_csv_file="$(pwk_worker_summary_csv_file)"
    stderr_file="$(pwk_stderr_file)"
    meta_file="$(pwk_meta_file)"
    command_file="$(pwk_command_file)"
    java_source_file="${SCRIPT_DIR}/FixedPartitionProducerWorkload.java"
    java_classpath="${KAFKA_BIN_DIR}/../libs/*"

    [[ -f "${java_source_file}" ]] || \
        wk_die "java workload source not found: ${java_source_file}"

    cat > "${meta_file}" <<EOF
mode=fixed_partition_workers
topic=${FORMAL_WORKLOAD_TOPIC}
bootstrap_server=${bootstrap_server}
partitions=${PINNED_WORKLOAD_PARTITIONS}
record_size=${FORMAL_WORKLOAD_RECORD_SIZE}
throughput_records_per_sec=${FORMAL_WORKLOAD_THROUGHPUT}
reporting_interval_ms=${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}
run_secs=${FORMAL_WORKLOAD_RUN_SECS}
warmup_secs=${FORMAL_WORKLOAD_WARMUP_SECS}
num_records=${num_records}
acks=${FORMAL_WORKLOAD_ACKS}
batch_size=${FORMAL_WORKLOAD_BATCH_SIZE}
linger_ms=${FORMAL_WORKLOAD_LINGER_MS}
compression_type=${FORMAL_WORKLOAD_COMPRESSION_TYPE}
request_timeout_ms=${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}
delivery_timeout_ms=${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}
max_block_ms=${FORMAL_WORKLOAD_MAX_BLOCK_MS}
max_in_flight_requests_per_connection=${PINNED_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}
client_id_prefix=${PINNED_WORKLOAD_CLIENT_ID_PREFIX}
stdout_file=${stdout_file}
timestamped_stdout_file=${timestamped_stdout_file}
report_time_csv_file=${report_time_csv_file}
worker_summary_csv_file=${worker_summary_csv_file}
stderr_file=${stderr_file}
start_time_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

    cat > "${command_file}" <<EOF
java --class-path '${java_classpath}' '${java_source_file}' \
  --bootstrap-server '${bootstrap_server}' \
  --topic '${FORMAL_WORKLOAD_TOPIC}' \
  --partitions '${PINNED_WORKLOAD_PARTITIONS}' \
  --record-size '${FORMAL_WORKLOAD_RECORD_SIZE}' \
  --throughput '${FORMAL_WORKLOAD_THROUGHPUT}' \
  --reporting-interval-ms '${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}' \
  --run-secs '${FORMAL_WORKLOAD_RUN_SECS}' \
  --acks '${FORMAL_WORKLOAD_ACKS}' \
  --batch-size '${FORMAL_WORKLOAD_BATCH_SIZE}' \
  --linger-ms '${FORMAL_WORKLOAD_LINGER_MS}' \
  --compression-type '${FORMAL_WORKLOAD_COMPRESSION_TYPE}' \
  --request-timeout-ms '${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}' \
  --delivery-timeout-ms '${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}' \
  --max-block-ms '${FORMAL_WORKLOAD_MAX_BLOCK_MS}' \
  --max-in-flight-requests-per-connection '${PINNED_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}' \
  --client-id-prefix '${PINNED_WORKLOAD_CLIENT_ID_PREFIX}' \
  --worker-summary-csv '${worker_summary_csv_file}' \
  2> >(tee -a '${stderr_file}' >&2)
EOF

    wk_log "Starting fixed-partition worker workload for topic ${FORMAL_WORKLOAD_TOPIC}"
    wk_log "Partition spec: ${PINNED_WORKLOAD_PARTITIONS}"
    wk_log "Target write rate: ${FORMAL_WORKLOAD_THROUGHPUT} records/s, record size ${FORMAL_WORKLOAD_RECORD_SIZE} bytes"
    wk_log "Per-worker max.in.flight.requests.per.connection=${PINNED_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}"
    wk_log "Raw output will be saved to ${stdout_file}"
    wk_log "Timestamped output will be saved to ${timestamped_stdout_file}"
    wk_log "Structured report-time CSV will be saved to ${report_time_csv_file}"
    wk_log "Per-partition summary CSV will be saved to ${worker_summary_csv_file}"
    wk_log "Java stderr log will be saved to ${stderr_file}"

    : > "${stderr_file}"

    java --class-path "${java_classpath}" "${java_source_file}" \
        --bootstrap-server "${bootstrap_server}" \
        --topic "${FORMAL_WORKLOAD_TOPIC}" \
        --partitions "${PINNED_WORKLOAD_PARTITIONS}" \
        --record-size "${FORMAL_WORKLOAD_RECORD_SIZE}" \
        --throughput "${FORMAL_WORKLOAD_THROUGHPUT}" \
        --reporting-interval-ms "${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}" \
        --run-secs "${FORMAL_WORKLOAD_RUN_SECS}" \
        --acks "${FORMAL_WORKLOAD_ACKS}" \
        --batch-size "${FORMAL_WORKLOAD_BATCH_SIZE}" \
        --linger-ms "${FORMAL_WORKLOAD_LINGER_MS}" \
        --compression-type "${FORMAL_WORKLOAD_COMPRESSION_TYPE}" \
        --request-timeout-ms "${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}" \
        --delivery-timeout-ms "${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}" \
        --max-block-ms "${FORMAL_WORKLOAD_MAX_BLOCK_MS}" \
        --max-in-flight-requests-per-connection "${PINNED_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}" \
        --client-id-prefix "${PINNED_WORKLOAD_CLIENT_ID_PREFIX}" \
        --worker-summary-csv "${worker_summary_csv_file}" \
        2> >(tee -a "${stderr_file}" >&2) \
        | wk_capture_producer_output \
            "${stdout_file}" \
            "${timestamped_stdout_file}" \
            "${report_time_csv_file}"

    wk_log "Fixed-partition worker workload finished"
    wk_log "Meta file: ${meta_file}"
    wk_log "Command file: ${command_file}"
}

main "$@"
