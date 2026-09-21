#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/workload_common.sh"

main() {
    local bootstrap_server=''
    local num_records=''
    local stdout_file=''
    local timestamped_stdout_file=''
    local report_time_csv_file=''
    local producer_topic_jmx_csv_file='disabled'
    local producer_client_jmx_csv_file='disabled'
    local producer_jmx_url='disabled'
    local producer_jmx_opts=''
    local meta_file=''
    local command_file=''

    wk_require_root
    wk_require_tools kafka-producer-perf-test.sh
    wk_prepare_output_dir

    if wk_producer_jmx_sampler_enabled; then
        wk_require_commands java tee
        wk_assert_local_jmx_port_free
    fi

    bootstrap_server="$(wk_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        wk_warn "BOOTSTRAP_SERVER not set; using ${bootstrap_server}"
    fi

    wk_wait_for_bootstrap_server "${bootstrap_server}"
    num_records="$(wk_num_records)"
    stdout_file="$(wk_stdout_file)"
    timestamped_stdout_file="$(wk_timestamped_stdout_file)"
    report_time_csv_file="$(wk_report_time_csv_file)"
    if wk_producer_jmx_sampler_enabled; then
        producer_topic_jmx_csv_file="$(wk_producer_topic_jmx_csv_file)"
        producer_client_jmx_csv_file="$(wk_producer_client_jmx_csv_file)"
        producer_jmx_url="$(wk_producer_jmx_url)"
        producer_jmx_opts="$(wk_producer_jmx_opts)"
    fi
    meta_file="$(wk_meta_file)"
    command_file="$(wk_command_file)"

    cat > "${meta_file}" <<EOF
topic=${FORMAL_WORKLOAD_TOPIC}
bootstrap_server=${bootstrap_server}
record_size=${FORMAL_WORKLOAD_RECORD_SIZE}
throughput_records_per_sec=${FORMAL_WORKLOAD_THROUGHPUT}
reporting_interval_ms=${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}
run_secs=${FORMAL_WORKLOAD_RUN_SECS}
warmup_secs=${FORMAL_WORKLOAD_WARMUP_SECS}
num_records=${num_records}
acks=${FORMAL_WORKLOAD_ACKS}
batch_size=${FORMAL_WORKLOAD_BATCH_SIZE}
linger_ms=${FORMAL_WORKLOAD_LINGER_MS}
partitioner_class=${FORMAL_WORKLOAD_PARTITIONER_CLASS}
compression_type=${FORMAL_WORKLOAD_COMPRESSION_TYPE}
request_timeout_ms=${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}
delivery_timeout_ms=${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}
max_block_ms=${FORMAL_WORKLOAD_MAX_BLOCK_MS}
max_in_flight_requests_per_connection=${FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}
client_id=${FORMAL_WORKLOAD_CLIENT_ID}
stdout_file=${stdout_file}
timestamped_stdout_file=${timestamped_stdout_file}
report_time_csv_file=${report_time_csv_file}
producer_jmx_sampler_enabled=${FORMAL_WORKLOAD_ENABLE_PRODUCER_JMX_SAMPLER}
producer_jmx_host=${FORMAL_WORKLOAD_JMX_HOST}
producer_jmx_port=${FORMAL_WORKLOAD_JMX_PORT}
producer_jmx_url=${producer_jmx_url}
producer_jmx_sampling_interval_ms=${FORMAL_WORKLOAD_JMX_SAMPLING_INTERVAL_MS}
producer_topic_jmx_csv_file=${producer_topic_jmx_csv_file}
producer_client_jmx_csv_file=${producer_client_jmx_csv_file}
start_time_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

    cat > "${command_file}" <<EOF
KAFKA_JMX_OPTS='${producer_jmx_opts}' \
${KAFKA_BIN_DIR}/kafka-producer-perf-test.sh \
  --topic ${FORMAL_WORKLOAD_TOPIC} \
  --num-records ${num_records} \
  --record-size ${FORMAL_WORKLOAD_RECORD_SIZE} \
  --throughput ${FORMAL_WORKLOAD_THROUGHPUT} \
  --reporting-interval ${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS} \
  --producer-props \
    bootstrap.servers=${bootstrap_server} \
    acks=${FORMAL_WORKLOAD_ACKS} \
    batch.size=${FORMAL_WORKLOAD_BATCH_SIZE} \
    linger.ms=${FORMAL_WORKLOAD_LINGER_MS} \
    partitioner.class=${FORMAL_WORKLOAD_PARTITIONER_CLASS} \
    compression.type=${FORMAL_WORKLOAD_COMPRESSION_TYPE} \
    request.timeout.ms=${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS} \
    delivery.timeout.ms=${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS} \
    max.block.ms=${FORMAL_WORKLOAD_MAX_BLOCK_MS} \
    max.in.flight.requests.per.connection=${FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION} \
    client.id=${FORMAL_WORKLOAD_CLIENT_ID}
EOF

    wk_log "Starting formal producer baseline for topic ${FORMAL_WORKLOAD_TOPIC}"
    wk_log "Warmup reference window: ${FORMAL_WORKLOAD_WARMUP_SECS}s"
    wk_log "Planned run window: ${FORMAL_WORKLOAD_RUN_SECS}s"
    wk_log "Target write rate: ${FORMAL_WORKLOAD_THROUGHPUT} records/s, record size ${FORMAL_WORKLOAD_RECORD_SIZE} bytes"
    wk_log "Raw output will be saved to ${stdout_file}"
    wk_log "Timestamped output will be saved to ${timestamped_stdout_file}"
    wk_log "Structured report-time CSV will be saved to ${report_time_csv_file}"
    if wk_producer_jmx_sampler_enabled; then
        wk_log "Producer-topic JMX 1s CSV will be saved to ${producer_topic_jmx_csv_file}"
        wk_log "Producer-client JMX 1s CSV will be saved to ${producer_client_jmx_csv_file}"
        wk_log "Producer JMX endpoint: ${producer_jmx_url}"
    fi

    if wk_producer_jmx_sampler_enabled; then
        wk_start_producer_jmx_samplers \
            "${producer_jmx_url}" \
            "${producer_topic_jmx_csv_file}" \
            "${producer_client_jmx_csv_file}"
        trap 'wk_stop_all_producer_jmx_samplers' EXIT INT TERM
    fi

    if wk_producer_jmx_sampler_enabled; then
        KAFKA_JMX_OPTS="${producer_jmx_opts}" \
        "${KAFKA_BIN_DIR}/kafka-producer-perf-test.sh" \
            --topic "${FORMAL_WORKLOAD_TOPIC}" \
            --num-records "${num_records}" \
            --record-size "${FORMAL_WORKLOAD_RECORD_SIZE}" \
            --throughput "${FORMAL_WORKLOAD_THROUGHPUT}" \
            --reporting-interval "${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}" \
            --producer-props \
            "bootstrap.servers=${bootstrap_server}" \
            "acks=${FORMAL_WORKLOAD_ACKS}" \
            "batch.size=${FORMAL_WORKLOAD_BATCH_SIZE}" \
            "linger.ms=${FORMAL_WORKLOAD_LINGER_MS}" \
            "partitioner.class=${FORMAL_WORKLOAD_PARTITIONER_CLASS}" \
            "compression.type=${FORMAL_WORKLOAD_COMPRESSION_TYPE}" \
            "request.timeout.ms=${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}" \
            "delivery.timeout.ms=${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}" \
            "max.block.ms=${FORMAL_WORKLOAD_MAX_BLOCK_MS}" \
            "max.in.flight.requests.per.connection=${FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}" \
            "client.id=${FORMAL_WORKLOAD_CLIENT_ID}" \
            | wk_capture_producer_output \
                "${stdout_file}" \
                "${timestamped_stdout_file}" \
                "${report_time_csv_file}"
    else
        "${KAFKA_BIN_DIR}/kafka-producer-perf-test.sh" \
            --topic "${FORMAL_WORKLOAD_TOPIC}" \
            --num-records "${num_records}" \
            --record-size "${FORMAL_WORKLOAD_RECORD_SIZE}" \
            --throughput "${FORMAL_WORKLOAD_THROUGHPUT}" \
            --reporting-interval "${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS}" \
            --producer-props \
            "bootstrap.servers=${bootstrap_server}" \
            "acks=${FORMAL_WORKLOAD_ACKS}" \
            "batch.size=${FORMAL_WORKLOAD_BATCH_SIZE}" \
            "linger.ms=${FORMAL_WORKLOAD_LINGER_MS}" \
            "partitioner.class=${FORMAL_WORKLOAD_PARTITIONER_CLASS}" \
            "compression.type=${FORMAL_WORKLOAD_COMPRESSION_TYPE}" \
            "request.timeout.ms=${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS}" \
            "delivery.timeout.ms=${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS}" \
            "max.block.ms=${FORMAL_WORKLOAD_MAX_BLOCK_MS}" \
            "max.in.flight.requests.per.connection=${FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION}" \
            "client.id=${FORMAL_WORKLOAD_CLIENT_ID}" \
            | wk_capture_producer_output \
                "${stdout_file}" \
                "${timestamped_stdout_file}" \
                "${report_time_csv_file}"
    fi

    wk_stop_all_producer_jmx_samplers
    trap - EXIT INT TERM

    wk_log "Formal producer baseline finished"
    wk_log "Meta file: ${meta_file}"
    wk_log "Command file: ${command_file}"
}

main "$@"
