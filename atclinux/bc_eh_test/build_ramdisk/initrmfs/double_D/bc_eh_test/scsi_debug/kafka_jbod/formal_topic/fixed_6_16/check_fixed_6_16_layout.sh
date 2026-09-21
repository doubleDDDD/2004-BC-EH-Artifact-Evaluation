#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/fixed_6_16_common.sh"

main() {
    local bootstrap_server=''
    local describe_output=''
    local logdirs_output=''
    local describe_file=''
    local logdirs_file=''
    local summary_file=''
    local plan_file=''

    ft_require_root
    ft_require_tools kafka-topics.sh kafka-log-dirs.sh
    command -v python3 >/dev/null 2>&1 || ft_die "python3 is required for fixed_6_16 layout checks"
    ft_prepare_output_dir
    fx616_generate_plan_files

    bootstrap_server="$(ft_resolve_bootstrap_server)"
    if [[ -z "${BOOTSTRAP_SERVER}" ]]; then
        ft_warn "BOOTSTRAP_SERVER not set; using local broker ${bootstrap_server}"
    fi

    ft_wait_for_bootstrap_server "${bootstrap_server}"

    describe_output="$("${KAFKA_BIN_DIR}/kafka-topics.sh" \
        --describe \
        --topic "${FORMAL_TOPIC_NAME}" \
        --bootstrap-server "${bootstrap_server}")"

    describe_file="$(fx616_actual_describe_file)"
    printf '%s\n' "${describe_output}" > "${describe_file}"

    logdirs_output="$("${KAFKA_BIN_DIR}/kafka-log-dirs.sh" \
        --describe \
        --bootstrap-server "${bootstrap_server}" \
        --broker-list 1,2,3 \
        --topic-list "${FORMAL_TOPIC_NAME}")"
    logdirs_file="$(fx616_actual_logdirs_file)"
    printf '%s\n' "${logdirs_output}" > "${logdirs_file}"

    summary_file="$(fx616_actual_summary_file)"
    plan_file="$(fx616_layout_plan_file)"

    python3 - \
        "${FORMAL_TOPIC_NAME}" \
        "${FORMAL_TOPIC_TARGET_BROKER_ID}" \
        "${plan_file}" \
        "${describe_file}" \
        "${logdirs_file}" <<'PY' | tee "${summary_file}"
import json
import os
import re
import sys

topic_name = sys.argv[1]
target_broker_id = int(sys.argv[2])
plan_file = sys.argv[3]
describe_file = sys.argv[4]
logdirs_file = sys.argv[5]

with open(plan_file, "r", encoding="utf-8") as f:
    plan = json.load(f)

expected_by_partition = {}
group_summaries = plan["group_summaries"]
for item in plan["partition_plan"]:
    expected_by_partition[f"{topic_name}-{item['partition']}"] = item

line_re = re.compile(
    r"Partition:\s*(?P<partition>\d+)\s+Leader:\s*(?P<leader>-?\d+)\s+Replicas:\s*(?P<replicas>[0-9,]+)\s+Isr:"
)

actual_describe = {}
with open(describe_file, "r", encoding="utf-8") as f:
    for raw_line in f:
        if f"Topic: {topic_name}" not in raw_line or "Partition:" not in raw_line:
            continue
        match = line_re.search(raw_line)
        if not match:
            continue
        partition_name = f"{topic_name}-{int(match.group('partition'))}"
        actual_describe[partition_name] = {
            "leader": int(match.group("leader")),
            "replicas": [int(x) for x in match.group("replicas").split(",")],
        }

if len(actual_describe) != len(expected_by_partition):
    raise SystemExit(
        f"[kafka-formal-topic][error] describe output only covers {len(actual_describe)} partitions; "
        f"expected {len(expected_by_partition)}"
    )

with open(logdirs_file, "r", encoding="utf-8") as f:
    raw_logdirs_text = f.read()

json_start = raw_logdirs_text.find("{")
if json_start < 0:
    raise SystemExit("[kafka-formal-topic][error] kafka-log-dirs output does not contain a JSON payload")

logdirs_data = json.loads(raw_logdirs_text[json_start:])
with open(logdirs_file, "w", encoding="utf-8") as f:
    json.dump(logdirs_data, f, indent=2, sort_keys=True)
    f.write("\n")

broker1_logdir_by_partition = {}
for broker_entry in logdirs_data.get("brokers", []):
    broker_id = int(broker_entry.get("broker"))
    if broker_id != target_broker_id:
        continue
    for logdir_entry in broker_entry.get("logDirs", []):
        log_dir = os.path.normpath(logdir_entry.get("logDir", ""))
        for partition_entry in logdir_entry.get("partitions", []):
            partition_name = partition_entry.get("partition")
            if isinstance(partition_name, str) and partition_name.startswith(f"{topic_name}-"):
                broker1_logdir_by_partition[partition_name] = log_dir

if len(broker1_logdir_by_partition) != len(expected_by_partition):
    raise SystemExit(
        f"[kafka-formal-topic][error] broker-{target_broker_id} only reports {len(broker1_logdir_by_partition)} "
        f"topic replicas in kafka-log-dirs; expected {len(expected_by_partition)}"
    )

errors = []
actual_group_stats = {}

for group in group_summaries:
    actual_group_stats[os.path.normpath(group["log_dir"])] = {
        "partition_count": 0,
        "leader_count": 0,
        "partitions": [],
        "leader_partitions": [],
    }

for partition_name, expected in sorted(expected_by_partition.items()):
    if partition_name not in actual_describe:
        errors.append(f"{partition_name}: missing from describe output")
        continue
    if partition_name not in broker1_logdir_by_partition:
        errors.append(f"{partition_name}: missing from broker-{target_broker_id} log-dirs output")
        continue

    actual_leader = actual_describe[partition_name]["leader"]
    actual_replicas = actual_describe[partition_name]["replicas"]
    actual_log_dir = broker1_logdir_by_partition[partition_name]
    expected_leader = int(expected["expected_leader"])
    expected_replicas = expected["replicas"]
    expected_log_dir = os.path.normpath(expected["broker1_log_dir"])

    if actual_leader != expected_leader:
        errors.append(
            f"{partition_name}: leader mismatch, actual={actual_leader}, expected={expected_leader}"
        )
    if actual_replicas != expected_replicas:
        errors.append(
            f"{partition_name}: replicas mismatch, actual={actual_replicas}, expected={expected_replicas}"
        )
    if actual_log_dir != expected_log_dir:
        errors.append(
            f"{partition_name}: broker-{target_broker_id} log.dir mismatch, actual={actual_log_dir}, expected={expected_log_dir}"
        )

    stats = actual_group_stats.setdefault(actual_log_dir, {
        "partition_count": 0,
        "leader_count": 0,
        "partitions": [],
        "leader_partitions": [],
    })
    stats["partition_count"] += 1
    stats["partitions"].append(partition_name)
    if actual_leader == target_broker_id:
        stats["leader_count"] += 1
        stats["leader_partitions"].append(partition_name)

print(f"主题: {topic_name}")
print("布局: fixed_6_16")
for group in group_summaries:
    log_dir = os.path.normpath(group["log_dir"])
    stats = actual_group_stats.get(log_dir, {
        "partition_count": 0,
        "leader_count": 0,
        "partitions": [],
        "leader_partitions": [],
    })
    print(f"log.dir: {log_dir}")
    print(
        f"  实际 partitions={stats['partition_count']}, 期望 partitions={group['partition_count']}"
    )
    print(
        f"  实际 leader={stats['leader_count']}, 期望 leader={group['leader_count']}"
    )
    print(f"  实际 partitions: {', '.join(stats['partitions'])}")
    print(f"  实际 leaders: {', '.join(stats['leader_partitions'])}")

if errors:
    print("[kafka-formal-topic][error] fixed_6_16 exact layout check failed")
    for error in errors:
        print(f"  - {error}")
    raise SystemExit(1)

print("布局判定: 通过")
print("结论: broker-1 已收敛到固定 6/16 布局，可直接用于与 default 和 12/4 两组 layout 做并列 offline 对比")
PY

    ft_log "Saved exact-layout describe output to ${describe_file}"
    ft_log "Saved exact-layout logdirs output to ${logdirs_file}"
    ft_log "Saved exact-layout summary to ${summary_file}"
}

main "$@"
