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
        ft_die "formal topic ${FORMAL_TOPIC_NAME} partition count mismatch"
    printf '%s\n' "${describe_output}" | grep -Eq "ReplicationFactor:[[:space:]]*${FORMAL_TOPIC_REPLICATION_FACTOR}" || \
        ft_die "formal topic ${FORMAL_TOPIC_NAME} replication factor mismatch"
}

main() {
    local bootstrap_server=''
    local describe_output=''
    local logdirs_output=''
    local describe_file=''
    local logdirs_file=''
    local summary_file=''

    ft_require_root
    ft_require_tools kafka-topics.sh kafka-log-dirs.sh
    command -v python3 >/dev/null 2>&1 || ft_die "python3 is required for layout analysis"
    ft_prepare_output_dir

    bootstrap_server="$(ft_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        ft_warn "BOOTSTRAP_SERVER not set; using local broker ${bootstrap_server}"
    fi

    ft_wait_for_bootstrap_server "${bootstrap_server}"

    ft_log "Describing formal topic ${FORMAL_TOPIC_NAME}"
    describe_output="$("${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}")"
    validate_topic_metadata "${describe_output}"

    describe_file="$(ft_topic_describe_file)"
    printf '%s\n' "${describe_output}" > "${describe_file}"

    ft_log "Collecting kafka-log-dirs layout for ${FORMAL_TOPIC_NAME}"
    logdirs_output="$("${KAFKA_BIN_DIR}/kafka-log-dirs.sh" \
        --describe \
        --bootstrap-server "${bootstrap_server}" \
        --broker-list 1,2,3 \
        --topic-list "${FORMAL_TOPIC_NAME}")"
    logdirs_file="$(ft_topic_logdirs_file)"
    printf '%s\n' "${logdirs_output}" > "${logdirs_file}"

    summary_file="$(ft_topic_summary_file)"
    python3 - \
        "${FORMAL_TOPIC_NAME}" \
        "${FORMAL_TOPIC_TARGET_BROKER_ID}" \
        "${FORMAL_TOPIC_TARGET_LOG_DIR}" \
        "${FORMAL_TOPIC_MIN_TARGET_PARTITIONS}" \
        "${FORMAL_TOPIC_MIN_TARGET_LEADERS}" \
        "${describe_file}" \
        "${logdirs_file}" <<'PY' | tee "${summary_file}"
import json
import os
import re
import sys

topic_name = sys.argv[1]
target_broker = int(sys.argv[2])
target_log_dir = os.path.normpath(sys.argv[3])
min_target_partitions = int(sys.argv[4])
min_target_leaders = int(sys.argv[5])
describe_file = sys.argv[6]
logdirs_file = sys.argv[7]

leader_by_partition = {}

with open(describe_file, "r", encoding="utf-8") as f:
    for raw_line in f:
        line = raw_line.strip()
        if f"Topic: {topic_name}" not in line or "Partition:" not in line:
            continue
        match = re.search(r"Partition:\s*(\d+)\s+Leader:\s*(-?\d+)", line)
        if not match:
            continue
        partition_id = int(match.group(1))
        leader_id = int(match.group(2))
        leader_by_partition[f"{topic_name}-{partition_id}"] = leader_id

if not leader_by_partition:
    raise SystemExit(f"[kafka-formal-topic][error] failed to parse leader mapping for topic {topic_name}")

with open(logdirs_file, "r", encoding="utf-8") as f:
    raw_logdirs_text = f.read()

if not raw_logdirs_text.strip():
    raise SystemExit(
        "[kafka-formal-topic][error] kafka-log-dirs output is empty; "
        "check broker reachability and the raw logdirs output file"
    )

json_start = raw_logdirs_text.find("{")
if json_start < 0:
    preview = raw_logdirs_text[:400].replace("\n", "\\n")
    raise SystemExit(
        "[kafka-formal-topic][error] kafka-log-dirs output does not contain a JSON payload; "
        f"output begins with: {preview}"
    )

try:
    logdirs_data = json.loads(raw_logdirs_text[json_start:])
except json.JSONDecodeError as exc:
    preview = raw_logdirs_text[:400].replace("\n", "\\n")
    raise SystemExit(
        "[kafka-formal-topic][error] failed to parse kafka-log-dirs JSON payload: "
        f"{exc}; output begins with: {preview}"
    )

brokers = logdirs_data.get("brokers", [])
if not brokers:
    raise SystemExit("[kafka-formal-topic][error] kafka-log-dirs JSON payload has no brokers")

per_broker = {}
expected_log_dirs = {
    os.path.normpath("/data/kafka-1/kafka-logs"),
    os.path.normpath("/data/kafka-2/kafka-logs"),
    os.path.normpath("/data/kafka-3/kafka-logs"),
}

for broker in brokers:
    broker_id = broker.get("broker")
    per_broker.setdefault(broker_id, {})
    for logdir in broker.get("logDirs", []):
        log_dir_path = os.path.normpath(logdir.get("logDir", ""))
        replicas = []
        for partition in logdir.get("partitions", []):
            partition_name = partition.get("partition")
            if not partition_name or not partition_name.startswith(f"{topic_name}-"):
                continue
            replicas.append(partition_name)
        per_broker[broker_id][log_dir_path] = sorted(replicas)

print(f"Topic: {topic_name}")
print("Formal topic layout across brokers / log.dirs:")

target_summary = {}
sibling_total_leaders = 0

for broker_id in sorted(per_broker):
    print(f"broker {broker_id}:")
    per_logdir = per_broker[broker_id]
    for log_dir in sorted(per_logdir):
        partitions = per_logdir[log_dir]
        leaders = [p for p in partitions if leader_by_partition.get(p) == broker_id]
        print(f"  {log_dir}")
        print(f"    replica count: {len(partitions)}")
        print(f"    leader partition count: {len(leaders)}")
        if partitions:
            print(f"    partitions: {', '.join(partitions)}")
        if leaders:
            print(f"    leaders: {', '.join(leaders)}")

        if broker_id == target_broker:
            target_summary[log_dir] = (len(partitions), len(leaders))
            if log_dir != target_log_dir:
                sibling_total_leaders += len(leaders)

missing_log_dirs = [d for d in expected_log_dirs if d not in target_summary]
if missing_log_dirs:
    raise SystemExit(
        "[kafka-formal-topic][error] target broker is missing expected log.dirs: "
        + ", ".join(missing_log_dirs)
    )

for log_dir in expected_log_dirs:
    partition_count, _ = target_summary[log_dir]
    if partition_count <= 0:
        raise SystemExit(
            f"[kafka-formal-topic][error] target broker log.dir {log_dir} has no replicas of topic {topic_name}"
        )

target_partitions, target_leaders = target_summary[target_log_dir]
if target_partitions < min_target_partitions:
    raise SystemExit(
        f"[kafka-formal-topic][error] target log.dir {target_log_dir} has only {target_partitions} partitions; "
        f"need at least {min_target_partitions} to make the first fault-injection round meaningful"
    )

if target_leaders < min_target_leaders:
    raise SystemExit(
        f"[kafka-formal-topic][error] target log.dir {target_log_dir} has only {target_leaders} leader partitions; "
        f"need at least {min_target_leaders} for a clear first-round fault signal"
    )

if sibling_total_leaders <= 0:
    print(
        "[kafka-formal-topic][warn] sibling log.dirs on the target broker currently hold no leader partitions; "
        "the experiment is still runnable, but the healthy-sibling comparison will be weaker"
    )

print("Layout check: PASS")
print(
    f"Conclusion: broker {target_broker} target fault log.dir {target_log_dir} has {target_partitions} partition replicas,"
    f" {target_leaders} leader partitions, and can be used as the first-round single-disk fault target"
)
PY

    ft_log "Saved formal topic describe output to ${describe_file}"
    ft_log "Saved kafka-log-dirs output to ${logdirs_file}"
    ft_log "Saved layout summary to ${summary_file}"
    ft_log "Formal topic layout check finished successfully"
}

main "$@"
