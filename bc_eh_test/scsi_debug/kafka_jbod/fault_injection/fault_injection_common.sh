#!/usr/bin/env bash
set -euo pipefail

readonly KAFKA_FAULT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KAFKA_JBOD_DIR="$(cd "${KAFKA_FAULT_SCRIPT_DIR}/.." && pwd)"
readonly KAFKA_BIN_DIR="/root/kafka_2.13-4.2.0/bin"
readonly KAFKA_SERVER_LOG_PATH="/root/kafka_2.13-4.2.0/logs/server.log"

CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-}"
BOOTSTRAP_WAIT_SECS="${BOOTSTRAP_WAIT_SECS:-60}"
SNAPSHOT_CMD_TIMEOUT_SECS="${SNAPSHOT_CMD_TIMEOUT_SECS:-30}"
FORMAL_TOPIC_NAME="${FORMAL_TOPIC_NAME:-jbod-hot}"
FAULT_OUTPUT_DIR="${FAULT_OUTPUT_DIR:-${KAFKA_FAULT_SCRIPT_DIR}/output}"

FAULT_TARGET_BROKER_ID="${FAULT_TARGET_BROKER_ID:-1}"
FAULT_TARGET_BROKER_IP="${FAULT_TARGET_BROKER_IP:-10.20.0.11}"
FAULT_TARGET_TARGET="${FAULT_TARGET_TARGET:-0}"
FAULT_TARGET_MOUNT_DIR="${FAULT_TARGET_MOUNT_DIR:-/data/kafka-1}"
FAULT_TARGET_LOG_DIR="${FAULT_TARGET_LOG_DIR:-/data/kafka-1/kafka-logs}"
FAULT_EH_MODE="${FAULT_EH_MODE:-sdev}"

OFFLINE_WAIT_SECS="${OFFLINE_WAIT_SECS:-180}"
STALL_MID_SNAPSHOT_SECS="${STALL_MID_SNAPSHOT_SECS:-45}"
RECOVERY_WAIT_SECS="${RECOVERY_WAIT_SECS:-60}"
POST_FAULT_SETTLE_TIMEOUT_SECS="${POST_FAULT_SETTLE_TIMEOUT_SECS:-30}"
POST_FAULT_SETTLE_POLL_INTERVAL_SECS="${POST_FAULT_SETTLE_POLL_INTERVAL_SECS:-1}"
POST_FAULT_SETTLE_STABLE_ROUNDS="${POST_FAULT_SETTLE_STABLE_ROUNDS:-3}"
SNAPSHOT_SERVER_LOG_LINES="${SNAPSHOT_SERVER_LOG_LINES:-400}"
REMOTE_BROKER_LOG_ARCHIVE="${REMOTE_BROKER_LOG_ARCHIVE:-1}"
REMOTE_BROKER_LOG_IPS="${REMOTE_BROKER_LOG_IPS:-10.20.0.11 10.20.0.12 10.20.0.13}"
REMOTE_BROKER_LOG_SSH_USER="${REMOTE_BROKER_LOG_SSH_USER:-root}"
REMOTE_BROKER_LOG_PASSWORD="${REMOTE_BROKER_LOG_PASSWORD:-1}"
REMOTE_BROKER_LOG_CONNECT_TIMEOUT_SECS="${REMOTE_BROKER_LOG_CONNECT_TIMEOUT_SECS:-5}"

# shellcheck source=/dev/null
. "${KAFKA_JBOD_DIR}/kafka_jbod_common.sh"

readonly FAULT_OFFLINE_VALIDATE_RULES="$(cat <<'EOF'
device timeout 1
target timeout 1
bus timeout 1
host timeout 1
EOF
)"

# Recoverable stall is intentionally P5-like on the Kafka JBOD topology:
# a single long command timeout first lets device reset return, then the
# post-device TUR validation times out, and the target reset finally
# succeeds and recovery completes. Because this topology is 1 target / 1 lun
# per Kafka data disk, the target scope still maps to the single fault
# disk's target and does not couple the three sibling targets.
readonly FAULT_STALL_VALIDATE_RULES="$(cat <<'EOF'
device timeout 1
EOF
)"

readonly FAULT_OFFLINE_ERROR_RULES="${BC_EH_RULE_IO_TIMEOUT_ABORT}"

readonly FAULT_STALL_ERROR_RULES="${BC_EH_RULE_IO_TIMEOUT_ABORT}"

kf_log() {
    printf '[kafka-fault] %s\n' "$*"
}

kf_warn() {
    printf '[kafka-fault][warn] %s\n' "$*" >&2
}

kf_die() {
    printf '[kafka-fault][error] %s\n' "$*" >&2
    exit 1
}

kf_require_root() {
    kafka_jbod_require_root
}

kf_clear_dmesg_ring() {
    if dmesg -C >/dev/null 2>&1; then
        kf_log "Cleared dmesg ring buffer before fault injection"
        return 0
    fi

    kf_warn "failed to clear dmesg ring buffer; kernel-side logs may include older rounds"
    return 0
}

kf_require_tools() {
    local tool_name=''

    for tool_name in "$@"; do
        [[ -x "${KAFKA_BIN_DIR}/${tool_name}" ]] || \
            kf_die "${tool_name} not found: ${KAFKA_BIN_DIR}/${tool_name}"
    done

    command -v timeout >/dev/null 2>&1 || kf_die "timeout command not found"
    command -v python3 >/dev/null 2>&1 || kf_die "python3 command not found"
    command -v sshpass >/dev/null 2>&1 || kf_die "sshpass command not found"
    command -v scp >/dev/null 2>&1 || kf_die "scp command not found"
}

kf_detect_local_cluster_ip() {
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

kf_detect_local_broker_id() {
    local cluster_ip=''

    cluster_ip="$(kf_detect_local_cluster_ip || true)"

    case "${cluster_ip}" in
        10.20.0.11) printf '1\n' ;;
        10.20.0.12) printf '2\n' ;;
        10.20.0.13) printf '3\n' ;;
        *) return 1 ;;
    esac
}

kf_broker_id_for_cluster_ip() {
    local cluster_ip="$1"

    case "${cluster_ip}" in
        10.20.0.11) printf '1\n' ;;
        10.20.0.12) printf '2\n' ;;
        10.20.0.13) printf '3\n' ;;
        *) return 1 ;;
    esac
}

kf_resolve_bootstrap_server() {
    if [[ -n "${BOOTSTRAP_SERVER}" ]]; then
        printf '%s\n' "${BOOTSTRAP_SERVER}"
        return 0
    fi

    printf '%s:9092\n' "${FAULT_TARGET_BROKER_IP}"
}

kf_wait_for_bootstrap_server() {
    local bootstrap_server="$1"
    local host="${bootstrap_server%:*}"
    local port="${bootstrap_server##*:}"
    local attempt=''

    kf_log "Waiting for bootstrap server ${bootstrap_server}"
    for attempt in $(seq 1 "${BOOTSTRAP_WAIT_SECS}"); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    kf_die "bootstrap server ${bootstrap_server} is not reachable within ${BOOTSTRAP_WAIT_SECS}s"
}

kf_prepare_output_root() {
    mkdir -p "${FAULT_OUTPUT_DIR}"
}

kf_resolve_eh_profile() {
    case "${FAULT_EH_MODE}" in
        host)
            printf 'linux-eh\n'
            ;;
        sdev)
            printf 'bc-eh\n'
            ;;
        *)
            kf_die "unsupported FAULT_EH_MODE: ${FAULT_EH_MODE}"
            ;;
    esac
}

kf_eh_identity() {
    printf '%s (eh_mode=%s)\n' "$(kf_resolve_eh_profile)" "${FAULT_EH_MODE}"
}

kf_timestamp_utc() {
    date -u '+%Y%m%dT%H%M%SZ'
}

kf_prepare_run_dir() {
    local case_name="$1"
    local run_dir=''
    local eh_profile=''

    eh_profile="$(kf_resolve_eh_profile)"
    run_dir="${FAULT_OUTPUT_DIR}/$(kf_timestamp_utc).${case_name}.${eh_profile}.${FAULT_EH_MODE}"
    mkdir -p "${run_dir}"
    printf '%s\n' "${run_dir}"
}

kf_resolve_scsi_debug_host() {
    kafka_jbod_wait_for_expected_devices "${SDEBUG_WAIT_SECS}" >/dev/null
    bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}" || \
        kf_die "failed to find scsi_debug host"
}

kf_fault_scsi_id() {
    kafka_jbod_scsi_id_for_target "${FAULT_TARGET_TARGET}"
}

kf_fault_dev_path() {
    kafka_jbod_dev_for_target "${FAULT_TARGET_TARGET}"
}

kf_fault_block_name() {
    local dev_path=''

    dev_path="$(kf_fault_dev_path)"
    printf '%s\n' "${dev_path#/dev/}"
}

kf_fault_target_id() {
    local scsi_id="$1"

    bc_eh_target_id_from_scsi_id "${scsi_id}"
}

kf_scsi_state_file() {
    local scsi_id="$1"
    printf '/sys/class/scsi_device/%s/device/state\n' "${scsi_id}"
}

kf_read_scsi_state() {
    local scsi_id="$1"
    local state_file=''

    state_file="$(kf_scsi_state_file "${scsi_id}")"
    if [[ ! -e "${state_file}" ]]; then
        printf 'missing\n'
        return 0
    fi

    cat "${state_file}" 2>/dev/null || printf 'unreadable\n'
}

kf_wait_for_scsi_state() {
    local scsi_id="$1"
    local expected_state="$2"
    local timeout_secs="$3"
    local current_state=''

    while [[ "${timeout_secs}" -gt 0 ]]; do
        current_state="$(kf_read_scsi_state "${scsi_id}")"
        if [[ "${current_state}" = "${expected_state}" ]]; then
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

kf_clear_validate_after_reset() {
    local scsi_id="$1"
    local validate_file="/sys/kernel/debug/scsi_debug/${scsi_id}/validate_after_reset"

    [[ -e "${validate_file}" ]] || kf_die "validate_after_reset file not found: ${validate_file}"
    printf 'clear\n' > "${validate_file}"
}

kf_apply_validate_rules() {
    local scsi_id="$1"
    local validate_rules="$2"

    kf_clear_validate_after_reset "${scsi_id}"
    bc_eh_apply_validate_after_reset "${scsi_id}" "${validate_rules}"
}

kf_remove_error_rules() {
    local scsi_id="$1"
    local error_rules="$2"
    local error_file="/sys/kernel/debug/scsi_debug/${scsi_id}/error"
    local rule=''
    local type=''
    local _count=''
    local cmd=''

    [[ -e "${error_file}" ]] || kf_die "debugfs error file not found: ${error_file}"

    while IFS= read -r rule; do
        [[ -n "${rule}" ]] || continue
        type=''
        _count=''
        cmd=''
        read -r type _count cmd _ <<<"${rule}"
        [[ -n "${type}" && -n "${cmd}" ]] || continue
        printf -- '- %s %s\n' "${type}" "${cmd}" > "${error_file}" 2>/dev/null || true
    done <<EOF
${error_rules}
EOF
}

kf_apply_offline_fault_rules() {
    local scsi_id="$1"

    kf_apply_validate_rules "${scsi_id}" "${FAULT_OFFLINE_VALIDATE_RULES}"
    bc_eh_apply_error_rules "${scsi_id}" "${FAULT_OFFLINE_ERROR_RULES}"
    bc_eh_set_target_fail_reset "$(kf_fault_target_id "${scsi_id}")" 0
}

kf_apply_stall_fault_rules() {
    local scsi_id="$1"

    kf_apply_validate_rules "${scsi_id}" "${FAULT_STALL_VALIDATE_RULES}"
    bc_eh_apply_error_rules "${scsi_id}" "${FAULT_STALL_ERROR_RULES}"
    bc_eh_set_target_fail_reset "$(kf_fault_target_id "${scsi_id}")" 0
}

kf_clear_stall_fault_rules() {
    local scsi_id="$1"

    kf_remove_error_rules "${scsi_id}" "${FAULT_STALL_ERROR_RULES}"
    kf_clear_validate_after_reset "${scsi_id}"
    bc_eh_set_target_fail_reset "$(kf_fault_target_id "${scsi_id}")" 0
}

kf_set_eh_mode() {
    local scsi_debug_host="$1"
    local eh_profile=''

    eh_profile="$(kf_resolve_eh_profile)"
    kf_log "Selecting ${eh_profile} path (eh_mode=${FAULT_EH_MODE}) on ${scsi_debug_host}"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "${FAULT_EH_MODE}"
}

kf_assert_local_target_broker() {
    local local_broker_id=''

    local_broker_id="$(kf_detect_local_broker_id || true)"
    [[ -n "${local_broker_id}" ]] || \
        kf_die "cannot infer local broker id from ${CLUSTER_NET_IF}"
    [[ "${local_broker_id}" = "${FAULT_TARGET_BROKER_ID}" ]] || \
        kf_die "this script must run on broker-${FAULT_TARGET_BROKER_ID}, current VM is broker-${local_broker_id}"
}

kf_verify_fault_target_mount() {
    local dev_path=''
    local source=''

    dev_path="$(kf_fault_dev_path)"
    mountpoint -q "${FAULT_TARGET_MOUNT_DIR}" || \
        kf_die "${FAULT_TARGET_MOUNT_DIR} is not mounted"
    source="$(findmnt -n -o SOURCE --target "${FAULT_TARGET_MOUNT_DIR}" 2>/dev/null || true)"
    [[ "${source}" = "${dev_path}" ]] || \
        kf_die "${FAULT_TARGET_MOUNT_DIR} expected source ${dev_path}, got ${source:-<none>}"
}

kf_flatten_file_value() {
    local file_path="$1"

    if [[ ! -r "${file_path}" ]]; then
        printf '\n'
        return 0
    fi

    tr '\n' '|' < "${file_path}" | sed 's/|*$//'
}

kf_write_run_metadata() {
    local run_dir="$1"
    local case_name="$2"
    local bootstrap_server="$3"
    local scsi_debug_host="$4"
    local scsi_id="$5"
    local dev_path="$6"
    local target_id="$7"
    local metadata_file="${run_dir}/run.meta.txt"
    local local_ip=''
    local local_broker_id=''
    local eh_profile=''
    local eh_mode_file="/sys/class/scsi_host/${scsi_debug_host}/eh_mode"
    local host_eh_mode_initial=''

    local_ip="$(kf_detect_local_cluster_ip || true)"
    local_broker_id="$(kf_detect_local_broker_id || true)"
    eh_profile="$(kf_resolve_eh_profile)"
    host_eh_mode_initial="$(cat "${eh_mode_file}" 2>/dev/null || true)"

    cat > "${metadata_file}" <<EOF
case_name=${case_name}
fault_eh_profile=${eh_profile}
fault_eh_mode=${FAULT_EH_MODE}
host_eh_mode_initial=${host_eh_mode_initial}
formal_topic_name=${FORMAL_TOPIC_NAME}
bootstrap_server=${bootstrap_server}
local_broker_id=${local_broker_id:-unknown}
local_cluster_ip=${local_ip:-unknown}
fault_target_broker_id=${FAULT_TARGET_BROKER_ID}
fault_target_broker_ip=${FAULT_TARGET_BROKER_IP}
fault_target_target=${FAULT_TARGET_TARGET}
fault_target_mount_dir=${FAULT_TARGET_MOUNT_DIR}
fault_target_log_dir=${FAULT_TARGET_LOG_DIR}
fault_scsi_debug_host=${scsi_debug_host}
fault_scsi_id=${scsi_id}
fault_dev_path=${dev_path}
fault_target_id=${target_id}
fault_initial_scsi_state=$(kf_read_scsi_state "${scsi_id}")
stall_mid_snapshot_secs=${STALL_MID_SNAPSHOT_SECS}
recovery_wait_secs=${RECOVERY_WAIT_SECS}
offline_wait_secs=${OFFLINE_WAIT_SECS}
fault_offline_case_class=P8
fault_offline_case_path=D+->T+->B+->H+/V-
fault_stall_case_class=P5
fault_stall_case_path=D+_V~_to_T+
script_dir=${KAFKA_FAULT_SCRIPT_DIR}
start_time_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
}

kf_timeout_capture() {
    local output_file="$1"
    shift

    if timeout "${SNAPSHOT_CMD_TIMEOUT_SECS}" "$@" >"${output_file}" 2>&1; then
        return 0
    fi

    printf '[snapshot-warning] command failed or timed out:' >"${output_file}"
    printf ' %q' "$@" >>"${output_file}"
    printf '\n' >>"${output_file}"
    timeout "${SNAPSHOT_CMD_TIMEOUT_SECS}" "$@" >>"${output_file}" 2>&1 || true
}

kf_capture_topic_describe() {
    local output_file="$1"
    local bootstrap_server="$2"

    kf_timeout_capture \
        "${output_file}" \
        "${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}"
}

kf_topic_describe_looks_valid() {
    local topic_describe_file="$1"

    grep -q "Topic: ${FORMAL_TOPIC_NAME}" "${topic_describe_file}" 2>/dev/null
}

kf_wait_for_topic_describe_stable() {
    local bootstrap_server="$1"
    local timeout_secs="${2:-${POST_FAULT_SETTLE_TIMEOUT_SECS}}"
    local poll_interval_secs="${3:-${POST_FAULT_SETTLE_POLL_INTERVAL_SECS}}"
    local stable_rounds="${4:-${POST_FAULT_SETTLE_STABLE_ROUNDS}}"
    local prev_file=''
    local curr_file=''
    local stable_count='0'
    local start_epoch=''
    local elapsed_secs=''

    prev_file="$(mktemp)"
    curr_file="$(mktemp)"
    : > "${prev_file}"
    start_epoch="$(date +%s)"

    while :; do
        kf_capture_topic_describe "${curr_file}" "${bootstrap_server}"

        if kf_topic_describe_looks_valid "${curr_file}"; then
            if [[ "${stable_count}" -gt 0 ]] && cmp -s "${prev_file}" "${curr_file}"; then
                stable_count="$((stable_count + 1))"
            else
                stable_count='1'
            fi

            cp "${curr_file}" "${prev_file}"

            if [[ "${stable_count}" -ge "${stable_rounds}" ]]; then
                rm -f "${prev_file}" "${curr_file}"
                return 0
            fi
        else
            stable_count='0'
        fi

        elapsed_secs="$(( $(date +%s) - start_epoch ))"
        if [[ "${elapsed_secs}" -ge "${timeout_secs}" ]]; then
            rm -f "${prev_file}" "${curr_file}"
            return 1
        fi

        sleep "${poll_interval_secs}"
    done
}

kf_normalize_logdirs_json() {
    local raw_file="$1"
    local json_file="$2"

    python3 - "${raw_file}" "${json_file}" <<'PY'
import json
import sys

raw_file = sys.argv[1]
json_file = sys.argv[2]

with open(raw_file, "r", encoding="utf-8") as f:
    raw = f.read()

if not raw.strip():
    raise SystemExit(0)

start = raw.find("{")
if start < 0:
    raise SystemExit(0)

payload = raw[start:]
try:
    data = json.loads(payload)
except json.JSONDecodeError:
    raise SystemExit(0)

with open(json_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

kf_collect_snapshot() {
    local run_dir="$1"
    local prefix="$2"
    local bootstrap_server="$3"
    local _scsi_debug_host="$4"
    local scsi_id="$5"
    local _dev_path="$6"
    local target_id="$7"
    local snapshot_mode="${8:-full}"
    local base_dir="${run_dir}/${prefix}"
    local error_file="/sys/kernel/debug/scsi_debug/${scsi_id}/error"
    local validate_file="/sys/kernel/debug/scsi_debug/${scsi_id}/validate_after_reset"
    local target_fail_file="/sys/kernel/debug/scsi_debug/${target_id}/fail_reset"
    local logdirs_tmp=''
    local snapshot_time=''
    local fault_scsi_state=''
    local fault_error=''
    local fault_validate_after_reset=''
    local fault_target_fail_reset=''

    mkdir -p "${base_dir}"

    snapshot_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fault_scsi_state="$(kf_read_scsi_state "${scsi_id}")"
    fault_error="$(kf_flatten_file_value "${error_file}")"
    fault_validate_after_reset="$(kf_flatten_file_value "${validate_file}")"
    fault_target_fail_reset="$(kf_flatten_file_value "${target_fail_file}")"

    cat > "${base_dir}/snapshot.meta.txt" <<EOF
snapshot_name=${prefix}
snapshot_time_utc=${snapshot_time}
fault_scsi_state=${fault_scsi_state}
fault_error=${fault_error}
fault_validate_after_reset=${fault_validate_after_reset}
fault_target_fail_reset=${fault_target_fail_reset}
EOF

    tail -n "${SNAPSHOT_SERVER_LOG_LINES}" "${KAFKA_SERVER_LOG_PATH}" \
        > "${base_dir}/server.log.tail.txt" 2>/dev/null || true

    if [[ "${snapshot_mode}" = "meta" ]]; then
        return 0
    fi

    kf_capture_topic_describe \
        "${base_dir}/topic.describe.txt" \
        "${bootstrap_server}"

    if [[ "${snapshot_mode}" = "light" ]]; then
        return 0
    fi

    logdirs_tmp="$(mktemp)"
    {
        kf_timeout_capture \
            "${logdirs_tmp}" \
            "${KAFKA_BIN_DIR}/kafka-log-dirs.sh" \
            --describe \
            --bootstrap-server "${bootstrap_server}" \
            --broker-list 1,2,3 \
            --topic-list "${FORMAL_TOPIC_NAME}"

        kf_normalize_logdirs_json \
            "${logdirs_tmp}" \
            "${base_dir}/logdirs.json" || true
    } || true
    rm -f "${logdirs_tmp}"
}

kf_list_server_log_files() {
    local log_dir="$1"
    local log_base="$2"

    find "${log_dir}" -maxdepth 1 -type f -name "${log_base}*" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n \
        | awk '{ $1=""; sub(/^ /, ""); print }'
}

kf_build_combined_server_log() {
    local parts_dir="$1"
    local output_file="$2"
    local log_base="$3"
    local part_file=''

    : > "${output_file}"
    while IFS= read -r part_file; do
        [[ -n "${part_file}" ]] || continue
        cat "${part_file}" >> "${output_file}"
        printf '\n' >> "${output_file}"
    done < <(kf_list_server_log_files "${parts_dir}" "${log_base}")

    if [[ ! -s "${output_file}" ]]; then
        rm -f "${output_file}"
        return 1
    fi

    return 0
}

kf_archive_local_server_log_parts() {
    local archive_dir="$1"
    local broker_id="$2"
    local log_dir=''
    local log_base=''
    local parts_dir=''
    local archive_file=''
    local src_file=''
    local copied='0'

    log_dir="$(dirname "${KAFKA_SERVER_LOG_PATH}")"
    log_base="$(basename "${KAFKA_SERVER_LOG_PATH}")"
    parts_dir="${archive_dir}/broker-${broker_id}.server.log.parts"
    archive_file="${archive_dir}/broker-${broker_id}.server.log"

    rm -rf "${parts_dir}"
    mkdir -p "${parts_dir}"

    while IFS= read -r src_file; do
        [[ -n "${src_file}" ]] || continue
        cp -p "${src_file}" "${parts_dir}/$(basename "${src_file}")" 2>/dev/null || continue
        copied='1'
    done < <(kf_list_server_log_files "${log_dir}" "${log_base}")

    if [[ "${copied}" != '1' ]]; then
        rm -rf "${parts_dir}"
        return 1
    fi

    kf_build_combined_server_log "${parts_dir}" "${archive_file}" "${log_base}" || return 1
    return 0
}

kf_archive_remote_server_log_parts() {
    local archive_dir="$1"
    local broker_id="$2"
    local ssh_target="$3"
    local stderr_file="$4"
    local log_dir=''
    local log_base=''
    local remote_glob=''
    local tmp_dir=''
    local parts_dir=''
    local archive_file=''
    local copied_file=''
    local copied='0'

    log_dir="$(dirname "${KAFKA_SERVER_LOG_PATH}")"
    log_base="$(basename "${KAFKA_SERVER_LOG_PATH}")"
    remote_glob="${ssh_target}:${log_dir}/${log_base}*"
    tmp_dir="$(mktemp -d)"
    parts_dir="${archive_dir}/broker-${broker_id}.server.log.parts"
    archive_file="${archive_dir}/broker-${broker_id}.server.log"

    rm -rf "${parts_dir}"
    mkdir -p "${parts_dir}"

    if ! timeout "${REMOTE_BROKER_LOG_CONNECT_TIMEOUT_SECS}" \
        sshpass -p "${REMOTE_BROKER_LOG_PASSWORD}" \
        scp -p \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="${REMOTE_BROKER_LOG_CONNECT_TIMEOUT_SECS}" \
        ${remote_glob} \
        "${tmp_dir}/" 2> "${stderr_file}"; then
        rm -rf "${tmp_dir}" "${parts_dir}"
        return 1
    fi

    for copied_file in "${tmp_dir}/${log_base}"*; do
        [[ -e "${copied_file}" ]] || continue
        mv "${copied_file}" "${parts_dir}/$(basename "${copied_file}")"
        copied='1'
    done

    rm -rf "${tmp_dir}"

    if [[ "${copied}" != '1' ]]; then
        rm -rf "${parts_dir}"
        return 1
    fi

    kf_build_combined_server_log "${parts_dir}" "${archive_file}" "${log_base}" || return 1
    return 0
}

kf_archive_broker_server_logs() {
    local run_dir="$1"
    local archive_dir="${run_dir}/broker_logs"
    local local_ip=''
    local local_broker_id=''
    local remote_ip=''
    local remote_broker_id=''
    local ssh_target=''
    local archive_file=''

    if [[ "${REMOTE_BROKER_LOG_ARCHIVE}" != "1" ]]; then
        return 0
    fi

    mkdir -p "${archive_dir}"
    local_ip="$(kf_detect_local_cluster_ip || true)"
    local_broker_id="$(kf_detect_local_broker_id || true)"

    if [[ -n "${local_broker_id}" && -r "${KAFKA_SERVER_LOG_PATH}" ]]; then
        if kf_archive_local_server_log_parts "${archive_dir}" "${local_broker_id}"; then
            kf_log "Archived local server.log* into ${archive_dir}/broker-${local_broker_id}.server.log.parts"
        else
            kf_warn "failed to archive local server.log* into ${archive_dir}/broker-${local_broker_id}.server.log.parts"
        fi
    else
        kf_warn "local server.log is not readable: ${KAFKA_SERVER_LOG_PATH}"
    fi

    for remote_ip in ${REMOTE_BROKER_LOG_IPS}; do
        [[ -n "${remote_ip}" ]] || continue
        [[ "${remote_ip}" = "${local_ip}" ]] && continue

        remote_broker_id="$(kf_broker_id_for_cluster_ip "${remote_ip}" 2>/dev/null || true)"
        [[ -n "${remote_broker_id}" ]] || remote_broker_id="${remote_ip//./_}"
        ssh_target="${REMOTE_BROKER_LOG_SSH_USER}@${remote_ip}"
        archive_file="${archive_dir}/broker-${remote_broker_id}.server.log"

        if kf_archive_remote_server_log_parts \
            "${archive_dir}" \
            "${remote_broker_id}" \
            "${ssh_target}" \
            "${archive_file}.stderr"; then
            rm -f "${archive_file}.stderr"
            kf_log "Archived server.log* from ${ssh_target} into ${archive_dir}/broker-${remote_broker_id}.server.log.parts"
        else
            rm -f "${archive_file}"
            kf_warn "failed to archive server.log from ${ssh_target}; see ${archive_file}.stderr"
        fi
    done
}

kf_capture_final_dmesg() {
    local run_dir="$1"

    dmesg -T > "${run_dir}/dmesg.txt" 2>/dev/null || \
        kf_warn "failed to capture final dmesg into ${run_dir}/dmesg.txt"
}
