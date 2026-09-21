#!/usr/bin/env bash
set -euo pipefail

WORKLOAD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAFKA_BIN_DIR="/root/kafka_2.13-4.2.0/bin"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-}"
BOOTSTRAP_WAIT_SECS="${BOOTSTRAP_WAIT_SECS:-60}"

FORMAL_WORKLOAD_TOPIC="${FORMAL_WORKLOAD_TOPIC:-jbod-hot}"
FORMAL_WORKLOAD_RECORD_SIZE="${FORMAL_WORKLOAD_RECORD_SIZE:-4096}"
FORMAL_WORKLOAD_THROUGHPUT="${FORMAL_WORKLOAD_THROUGHPUT:-600}"
FORMAL_WORKLOAD_REPORTING_INTERVAL_MS="${FORMAL_WORKLOAD_REPORTING_INTERVAL_MS:-1000}"
FORMAL_WORKLOAD_RUN_SECS="${FORMAL_WORKLOAD_RUN_SECS:-1200}"
FORMAL_WORKLOAD_WARMUP_SECS="${FORMAL_WORKLOAD_WARMUP_SECS:-300}"
FORMAL_WORKLOAD_ACKS="${FORMAL_WORKLOAD_ACKS:-all}"
FORMAL_WORKLOAD_BATCH_SIZE="${FORMAL_WORKLOAD_BATCH_SIZE:-16384}"
FORMAL_WORKLOAD_LINGER_MS="${FORMAL_WORKLOAD_LINGER_MS:-0}"
FORMAL_WORKLOAD_PARTITIONER_CLASS="${FORMAL_WORKLOAD_PARTITIONER_CLASS:-org.apache.kafka.clients.producer.RoundRobinPartitioner}"
FORMAL_WORKLOAD_COMPRESSION_TYPE="${FORMAL_WORKLOAD_COMPRESSION_TYPE:-none}"
FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS="${FORMAL_WORKLOAD_REQUEST_TIMEOUT_MS:-60000}"
FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS="${FORMAL_WORKLOAD_DELIVERY_TIMEOUT_MS:-120000}"
FORMAL_WORKLOAD_MAX_BLOCK_MS="${FORMAL_WORKLOAD_MAX_BLOCK_MS:-120000}"
FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION="${FORMAL_WORKLOAD_MAX_IN_FLIGHT_REQUESTS_PER_CONNECTION:-5}"
FORMAL_WORKLOAD_CLIENT_ID="${FORMAL_WORKLOAD_CLIENT_ID:-formal-producer-baseline}"
FORMAL_WORKLOAD_OUTPUT_DIR="${FORMAL_WORKLOAD_OUTPUT_DIR:-${WORKLOAD_SCRIPT_DIR}/output}"
FORMAL_WORKLOAD_ENABLE_PRODUCER_JMX_SAMPLER="${FORMAL_WORKLOAD_ENABLE_PRODUCER_JMX_SAMPLER:-1}"
FORMAL_WORKLOAD_JMX_HOST="${FORMAL_WORKLOAD_JMX_HOST:-127.0.0.1}"
FORMAL_WORKLOAD_JMX_PORT="${FORMAL_WORKLOAD_JMX_PORT:-9998}"
FORMAL_WORKLOAD_JMX_SAMPLING_INTERVAL_MS="${FORMAL_WORKLOAD_JMX_SAMPLING_INTERVAL_MS:-1000}"
FORMAL_WORKLOAD_JMX_TOPIC_QUERY_ATTRIBUTES="${FORMAL_WORKLOAD_JMX_TOPIC_QUERY_ATTRIBUTES:-byte-total,record-send-total,record-error-total,record-retry-total}"
FORMAL_WORKLOAD_JMX_CLIENT_QUERY_ATTRIBUTES="${FORMAL_WORKLOAD_JMX_CLIENT_QUERY_ATTRIBUTES:-request-latency-avg,request-latency-max,requests-in-flight}"

WK_JMX_TOOL_IMPL=''
WK_PRODUCER_JMX_SAMPLER_PID=''

wk_log() {
    printf '[kafka-workload] %s\n' "$*"
}

wk_warn() {
    printf '[kafka-workload][warn] %s\n' "$*" >&2
}

wk_die() {
    printf '[kafka-workload][error] %s\n' "$*" >&2
    exit 1
}

wk_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        wk_die "this script must run as root"
    fi
}

wk_require_tools() {
    local tool_name=''

    for tool_name in "$@"; do
        [[ -x "${KAFKA_BIN_DIR}/${tool_name}" ]] || \
            wk_die "${tool_name} not found: ${KAFKA_BIN_DIR}/${tool_name}"
    done
}

wk_require_commands() {
    local command_name=''

    for command_name in "$@"; do
        command -v "${command_name}" >/dev/null 2>&1 || \
            wk_die "required command not found: ${command_name}"
    done
}

wk_detect_local_cluster_ip() {
    local cluster_ip=''

    cluster_ip="$(
        ip -4 -o addr show dev "${CLUSTER_NET_IF}" 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -n 1
    )"

    [[ -n "${cluster_ip}" ]] || return 1
    printf '%s\n' "${cluster_ip}"
}

wk_resolve_bootstrap_server() {
    local cluster_ip=''

    if [[ -n "${BOOTSTRAP_SERVER}" ]]; then
        printf '%s\n' "${BOOTSTRAP_SERVER}"
        return 0
    fi

    if cluster_ip="$(wk_detect_local_cluster_ip)"; then
        case "${cluster_ip}" in
            10.20.0.11|10.20.0.12|10.20.0.13)
                printf '%s:9092\n' "${cluster_ip}"
                return 0
                ;;
            10.20.0.21)
                printf '10.20.0.11:9092\n'
                return 0
                ;;
        esac
    fi

    wk_die "cannot infer bootstrap server from ${CLUSTER_NET_IF}; set BOOTSTRAP_SERVER explicitly"
}

wk_wait_for_bootstrap_server() {
    local bootstrap_server="$1"
    local host="${bootstrap_server%:*}"
    local port="${bootstrap_server##*:}"
    local attempt=''

    wk_log "Waiting for bootstrap server ${bootstrap_server}"
    for attempt in $(seq 1 "${BOOTSTRAP_WAIT_SECS}"); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    wk_die "bootstrap server ${bootstrap_server} is not reachable within ${BOOTSTRAP_WAIT_SECS}s"
}

wk_prepare_output_dir() {
    mkdir -p "${FORMAL_WORKLOAD_OUTPUT_DIR}"
}

wk_producer_jmx_sampler_enabled() {
    [[ "${FORMAL_WORKLOAD_ENABLE_PRODUCER_JMX_SAMPLER}" = "1" ]]
}

wk_topic_safe_name() {
    local safe_name="${FORMAL_WORKLOAD_TOPIC//[^A-Za-z0-9._-]/_}"
    printf '%s\n' "${safe_name}"
}

wk_stdout_file() {
    printf '%s/%s.formal_producer_baseline.stdout.log\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_timestamped_stdout_file() {
    printf '%s/%s.formal_producer_baseline.stdout.timestamped.log\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_report_time_csv_file() {
    printf '%s/%s.formal_producer_baseline.report_time.csv\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_producer_topic_jmx_csv_file() {
    printf '%s/%s.formal_producer_baseline.producer_topic_jmx_1s.csv\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_producer_client_jmx_csv_file() {
    printf '%s/%s.formal_producer_baseline.producer_client_jmx_1s.csv\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_meta_file() {
    printf '%s/%s.formal_producer_baseline.meta.txt\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_command_file() {
    printf '%s/%s.formal_producer_baseline.command.txt\n' \
        "${FORMAL_WORKLOAD_OUTPUT_DIR}" "$(wk_topic_safe_name)"
}

wk_producer_jmx_url() {
    printf 'service:jmx:rmi:///jndi/rmi://%s:%s/jmxrmi\n' \
        "${FORMAL_WORKLOAD_JMX_HOST}" "${FORMAL_WORKLOAD_JMX_PORT}"
}

wk_producer_jmx_opts() {
    printf '%s' \
        "-Dcom.sun.management.jmxremote=true "\
        "-Dcom.sun.management.jmxremote.local.only=true "\
        "-Dcom.sun.management.jmxremote.authenticate=false "\
        "-Dcom.sun.management.jmxremote.ssl=false "\
        "-Dcom.sun.management.jmxremote.port=${FORMAL_WORKLOAD_JMX_PORT} "\
        "-Dcom.sun.management.jmxremote.rmi.port=${FORMAL_WORKLOAD_JMX_PORT} "\
        "-Djava.rmi.server.hostname=${FORMAL_WORKLOAD_JMX_HOST}"
}

wk_producer_jmx_sampling_interval_secs() {
    awk "BEGIN { printf \"%.3f\", ${FORMAL_WORKLOAD_JMX_SAMPLING_INTERVAL_MS} / 1000 }"
}

wk_producer_jmx_sampler_source_file() {
    printf '%s/PersistentProducerJmxSampler.java\n' "${WORKLOAD_SCRIPT_DIR}"
}

wk_init_jmx_tool_impl() {
    if [[ -n "${WK_JMX_TOOL_IMPL}" ]]; then
        return 0
    fi

    if [[ -x "${KAFKA_BIN_DIR}/kafka-jmx.sh" ]]; then
        WK_JMX_TOOL_IMPL='script'
        return 0
    fi

    [[ -x "${KAFKA_BIN_DIR}/kafka-run-class.sh" ]] || \
        wk_die "producer JMX sampler requires kafka-jmx.sh or kafka-run-class.sh in ${KAFKA_BIN_DIR}"

    if "${KAFKA_BIN_DIR}/kafka-run-class.sh" kafka.tools.JmxTool --help >/dev/null 2>&1; then
        WK_JMX_TOOL_IMPL='kafka.tools.JmxTool'
        return 0
    fi

    if "${KAFKA_BIN_DIR}/kafka-run-class.sh" org.apache.kafka.tools.JmxTool --help >/dev/null 2>&1; then
        WK_JMX_TOOL_IMPL='org.apache.kafka.tools.JmxTool'
        return 0
    fi

    wk_die "cannot locate a usable Kafka JMX tool under ${KAFKA_BIN_DIR}"
}

wk_run_jmxtool() {
    wk_init_jmx_tool_impl

    if [[ "${WK_JMX_TOOL_IMPL}" = 'script' ]]; then
        "${KAFKA_BIN_DIR}/kafka-jmx.sh" "$@"
        return 0
    fi

    "${KAFKA_BIN_DIR}/kafka-run-class.sh" "${WK_JMX_TOOL_IMPL}" "$@"
}

wk_assert_local_jmx_port_free() {
    if timeout 1 bash -c "exec 3<>/dev/tcp/${FORMAL_WORKLOAD_JMX_HOST}/${FORMAL_WORKLOAD_JMX_PORT}" >/dev/null 2>&1; then
        wk_die "producer JMX port ${FORMAL_WORKLOAD_JMX_HOST}:${FORMAL_WORKLOAD_JMX_PORT} is already in use"
    fi
}

wk_extract_jmx_time_ms() {
    awk -F'"' '$1 == "time," { print $2; exit }'
}

wk_extract_jmx_attr_value() {
    local attr_name="$1"

    awk -F'"' -v attr_token=":""${attr_name}""," '
        index($0, attr_token) {
            print $2
            found = 1
            exit
        }
        END {
            if (!found) {
                print ""
            }
        }
    '
}

wk_write_producer_jmx_csv_headers() {
    local topic_output_file="$1"
    local client_output_file="$2"

    printf 'sample_time_utc,jmx_time_ms,byte_total,record_send_total,record_error_total,record_retry_total\n' \
        > "${topic_output_file}"
    printf 'sample_time_utc,jmx_time_ms,request_latency_avg_ms,request_latency_max_ms,requests_in_flight\n' \
        > "${client_output_file}"
}

wk_start_producer_jmx_sampler() {
    local jmx_url="$1"
    local topic_output_file="$2"
    local client_output_file="$3"
    local topic_stderr_file="${topic_output_file}.stderr"
    local client_stderr_file="${client_output_file}.stderr"
    local sampler_source_file=''
    local pid=''

    sampler_source_file="$(wk_producer_jmx_sampler_source_file)"
    [[ -f "${sampler_source_file}" ]] || \
        wk_die "persistent producer JMX sampler source not found: ${sampler_source_file}"

    : > "${topic_stderr_file}"
    : > "${client_stderr_file}"
    wk_write_producer_jmx_csv_headers "${topic_output_file}" "${client_output_file}"

    (
        until timeout 1 bash -c "exec 3<>/dev/tcp/${FORMAL_WORKLOAD_JMX_HOST}/${FORMAL_WORKLOAD_JMX_PORT}" >/dev/null 2>&1; do
            sleep 1
        done

        java \
            "${sampler_source_file}" \
            "${jmx_url}" \
            "${FORMAL_WORKLOAD_CLIENT_ID}" \
            "${FORMAL_WORKLOAD_TOPIC}" \
            "${FORMAL_WORKLOAD_JMX_SAMPLING_INTERVAL_MS}" \
            "${topic_output_file}" \
            "${client_output_file}" \
            2> >(tee -a "${topic_stderr_file}" "${client_stderr_file}" >/dev/null)
    ) &
    pid="$!"

    WK_PRODUCER_JMX_SAMPLER_PID="${pid}"
    wk_log "Started producer JMX sampler (pid=${pid}) -> ${topic_output_file}, ${client_output_file}"
}

wk_stop_background_process() {
    local pid="${1:-}"
    local label="${2:-background process}"

    [[ -n "${pid}" ]] || return 0

    if kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        wait "${pid}" >/dev/null 2>&1 || true
        wk_log "Stopped ${label} (pid=${pid})"
    fi
}

wk_start_producer_jmx_samplers() {
    local topic_jmx_url="$1"
    local topic_output_file="$2"
    local client_output_file="$3"

    wk_start_producer_jmx_sampler \
        "${topic_jmx_url}" \
        "${topic_output_file}" \
        "${client_output_file}"
}

wk_stop_all_producer_jmx_samplers() {
    wk_stop_background_process "${WK_PRODUCER_JMX_SAMPLER_PID}" 'producer JMX sampler'
    WK_PRODUCER_JMX_SAMPLER_PID=''
}

wk_num_records() {
    if ! [[ "${FORMAL_WORKLOAD_THROUGHPUT}" =~ ^[0-9]+$ ]] || \
       ! [[ "${FORMAL_WORKLOAD_RUN_SECS}" =~ ^[0-9]+$ ]]; then
        wk_die "FORMAL_WORKLOAD_THROUGHPUT and FORMAL_WORKLOAD_RUN_SECS must be non-negative integers"
    fi

    if [[ "${FORMAL_WORKLOAD_THROUGHPUT}" -le 0 ]]; then
        wk_die "FORMAL_WORKLOAD_THROUGHPUT must be > 0 for a fixed-rate baseline"
    fi

    if [[ "${FORMAL_WORKLOAD_RUN_SECS}" -le 0 ]]; then
        wk_die "FORMAL_WORKLOAD_RUN_SECS must be > 0"
    fi

    printf '%s\n' "$((FORMAL_WORKLOAD_THROUGHPUT * FORMAL_WORKLOAD_RUN_SECS))"
}

wk_capture_producer_output() {
    local raw_file="$1"
    local timestamped_file="$2"
    local report_csv_file="$3"
    local producer_report_re='^([0-9]+) records sent, ([0-9.]+) records/sec \([^)]*\), ([0-9.]+) ms avg latency, ([0-9.]+) ms max latency\.$'
    local line=''
    local report_time_utc=''
    local escaped_line=''

    : > "${raw_file}"
    : > "${timestamped_file}"
    printf 'report_time_utc,records_sent,rate_rps,avg_lat_ms,max_lat_ms,raw_line\n' \
        > "${report_csv_file}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        report_time_utc="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

        printf '%s\n' "${line}" >> "${raw_file}"
        printf '%s\t%s\n' "${report_time_utc}" "${line}" >> "${timestamped_file}"
        printf '%s\n' "${line}"

        if [[ ${line} =~ ${producer_report_re} ]]; then
            escaped_line="${line//\"/\"\"}"
            printf '%s,%s,%s,%s,%s,"%s"\n' \
                "${report_time_utc}" \
                "${BASH_REMATCH[1]}" \
                "${BASH_REMATCH[2]}" \
                "${BASH_REMATCH[3]}" \
                "${BASH_REMATCH[4]}" \
                "${escaped_line}" \
                >> "${report_csv_file}"
        fi
    done
}
