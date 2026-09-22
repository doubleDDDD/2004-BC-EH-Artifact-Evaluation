#!/usr/bin/env bash
set -euo pipefail

FIXED_6_16_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMAL_TOPIC_OUTPUT_DIR="${FORMAL_TOPIC_OUTPUT_DIR:-${FIXED_6_16_SCRIPT_DIR}/output}"
# shellcheck source=/dev/null
. "${FIXED_6_16_SCRIPT_DIR}/../formal_topic_common.sh"

FX616_TARGET_LOG_DIR="${FX616_TARGET_LOG_DIR:-/data/kafka-1/kafka-logs}"
FX616_SIBLING_LOG_DIR_A="${FX616_SIBLING_LOG_DIR_A:-/data/kafka-2/kafka-logs}"
FX616_SIBLING_LOG_DIR_B="${FX616_SIBLING_LOG_DIR_B:-/data/kafka-3/kafka-logs}"

FX616_TARGET_PARTITION_COUNT="${FX616_TARGET_PARTITION_COUNT:-16}"
FX616_TARGET_LEADER_COUNT="${FX616_TARGET_LEADER_COUNT:-6}"
FX616_SIBLING_PARTITION_COUNT="${FX616_SIBLING_PARTITION_COUNT:-16}"
FX616_SIBLING_LEADER_COUNT="${FX616_SIBLING_LEADER_COUNT:-5}"

FX616_REASSIGN_VERIFY_ATTEMPTS="${FX616_REASSIGN_VERIFY_ATTEMPTS:-90}"
FX616_REASSIGN_VERIFY_INTERVAL_SECS="${FX616_REASSIGN_VERIFY_INTERVAL_SECS:-2}"
FX616_LAYOUT_VERIFY_ATTEMPTS="${FX616_LAYOUT_VERIFY_ATTEMPTS:-30}"
FX616_LAYOUT_VERIFY_INTERVAL_SECS="${FX616_LAYOUT_VERIFY_INTERVAL_SECS:-2}"

fx616_output_prefix() {
    printf '%s/%s.fixed_6_16' "${FORMAL_TOPIC_OUTPUT_DIR}" "$(ft_topic_safe_name)"
}

fx616_replica_assignment_file() {
    printf '%s.replica_assignment.txt\n' "$(fx616_output_prefix)"
}

fx616_reassignment_file() {
    printf '%s.reassignment.json\n' "$(fx616_output_prefix)"
}

fx616_preferred_election_file() {
    printf '%s.preferred_election.json\n' "$(fx616_output_prefix)"
}

fx616_layout_plan_file() {
    printf '%s.layout_plan.json\n' "$(fx616_output_prefix)"
}

fx616_layout_plan_summary_file() {
    printf '%s.layout_plan.txt\n' "$(fx616_output_prefix)"
}

fx616_actual_describe_file() {
    printf '%s.actual.describe.txt\n' "$(fx616_output_prefix)"
}

fx616_actual_logdirs_file() {
    printf '%s.actual.logdirs.json\n' "$(fx616_output_prefix)"
}

fx616_actual_summary_file() {
    printf '%s.actual.summary.txt\n' "$(fx616_output_prefix)"
}

fx616_reassign_verify_file() {
    printf '%s.reassign_verify.txt\n' "$(fx616_output_prefix)"
}

fx616_generate_plan_files() {
    local assignment_file=''
    local reassignment_file=''
    local preferred_election_file=''
    local layout_plan_file=''
    local layout_plan_summary_file=''

    assignment_file="$(fx616_replica_assignment_file)"
    reassignment_file="$(fx616_reassignment_file)"
    preferred_election_file="$(fx616_preferred_election_file)"
    layout_plan_file="$(fx616_layout_plan_file)"
    layout_plan_summary_file="$(fx616_layout_plan_summary_file)"

    python3 - \
        "${FORMAL_TOPIC_NAME}" \
        "${FORMAL_TOPIC_PARTITIONS}" \
        "${FORMAL_TOPIC_REPLICATION_FACTOR}" \
        "${FORMAL_TOPIC_TARGET_BROKER_ID}" \
        "${FX616_TARGET_LOG_DIR}" \
        "${FX616_SIBLING_LOG_DIR_A}" \
        "${FX616_SIBLING_LOG_DIR_B}" \
        "${FX616_TARGET_PARTITION_COUNT}" \
        "${FX616_TARGET_LEADER_COUNT}" \
        "${FX616_SIBLING_PARTITION_COUNT}" \
        "${FX616_SIBLING_LEADER_COUNT}" \
        "${assignment_file}" \
        "${reassignment_file}" \
        "${preferred_election_file}" \
        "${layout_plan_file}" \
        "${layout_plan_summary_file}" <<'PY'
import json
import sys
from pathlib import Path

topic_name = sys.argv[1]
partition_count = int(sys.argv[2])
replication_factor = int(sys.argv[3])
target_broker_id = int(sys.argv[4])
target_log_dir = sys.argv[5]
sibling_log_dir_a = sys.argv[6]
sibling_log_dir_b = sys.argv[7]
target_partition_count = int(sys.argv[8])
target_leader_count = int(sys.argv[9])
sibling_partition_count = int(sys.argv[10])
sibling_leader_count = int(sys.argv[11])
assignment_file = Path(sys.argv[12])
reassignment_file = Path(sys.argv[13])
preferred_election_file = Path(sys.argv[14])
layout_plan_file = Path(sys.argv[15])
layout_plan_summary_file = Path(sys.argv[16])

if replication_factor != 3:
    raise SystemExit("[kafka-formal-topic][error] fixed_6_16 currently requires replication factor = 3")
if partition_count != 48:
    raise SystemExit("[kafka-formal-topic][error] fixed_6_16 currently requires partition count = 48")
if target_broker_id != 1:
    raise SystemExit("[kafka-formal-topic][error] fixed_6_16 currently requires target broker = 1")
if target_partition_count != 16 or sibling_partition_count != 16:
    raise SystemExit("[kafka-formal-topic][error] fixed_6_16 currently requires 16 replicas per broker-1 log.dir")
if target_leader_count != 6 or sibling_leader_count != 5:
    raise SystemExit("[kafka-formal-topic][error] fixed_6_16 currently requires leader counts 6 / 5 / 5")

groups = [
    {
        "name": "target",
        "log_dir": target_log_dir,
        "partitions": list(range(0, 16)),
        "leader_partitions": list(range(0, 6)),
    },
    {
        "name": "sibling_a",
        "log_dir": sibling_log_dir_a,
        "partitions": list(range(16, 32)),
        "leader_partitions": list(range(16, 21)),
    },
    {
        "name": "sibling_b",
        "log_dir": sibling_log_dir_b,
        "partitions": list(range(32, 48)),
        "leader_partitions": list(range(32, 37)),
    },
]


def replicas_for(partition_id: int, leader_id: int):
    if leader_id == 1:
        return [1, 2, 3] if partition_id % 2 == 0 else [1, 3, 2]
    if leader_id == 2:
        return [2, 1, 3] if partition_id % 2 == 0 else [2, 3, 1]
    if leader_id == 3:
        return [3, 1, 2] if partition_id % 2 == 0 else [3, 2, 1]
    raise ValueError(f"unsupported leader id: {leader_id}")


partition_plan = []
group_summaries = []

for group in groups:
    followers = [p for p in group["partitions"] if p not in group["leader_partitions"]]
    follower_leaders = [2 if index % 2 == 0 else 3 for index, _ in enumerate(followers)]
    follower_iter = iter(follower_leaders)

    for partition_id in group["partitions"]:
        leader_id = 1 if partition_id in group["leader_partitions"] else next(follower_iter)
        replicas = replicas_for(partition_id, leader_id)
        log_dirs = ["any", "any", "any"]
        broker1_index = replicas.index(1)
        log_dirs[broker1_index] = group["log_dir"]
        partition_plan.append(
            {
                "partition": partition_id,
                "replicas": replicas,
                "log_dirs": log_dirs,
                "expected_leader": leader_id,
                "broker1_log_dir": group["log_dir"],
                "group": group["name"],
            }
        )

    group_summaries.append(
        {
            "name": group["name"],
            "log_dir": group["log_dir"],
            "partitions": group["partitions"],
            "leader_partitions": group["leader_partitions"],
            "partition_count": len(group["partitions"]),
            "leader_count": len(group["leader_partitions"]),
        }
    )

partition_plan.sort(key=lambda item: item["partition"])

assignment_entries = []
reassignment_entries = []
preferred_entries = []

for item in partition_plan:
    assignment_entries.append(":".join(str(replica) for replica in item["replicas"]))
    reassignment_entries.append(
        {
            "topic": topic_name,
            "partition": item["partition"],
            "replicas": item["replicas"],
            "log_dirs": item["log_dirs"],
        }
    )
    preferred_entries.append(
        {
            "topic": topic_name,
            "partition": item["partition"],
        }
    )

assignment_file.write_text(",".join(assignment_entries) + "\n", encoding="utf-8")
reassignment_file.write_text(
    json.dumps({"version": 1, "partitions": reassignment_entries}, indent=2) + "\n",
    encoding="utf-8",
)
preferred_election_file.write_text(
    json.dumps({"version": 1, "partitions": preferred_entries}, indent=2) + "\n",
    encoding="utf-8",
)

plan_payload = {
    "topic": topic_name,
    "partition_count": partition_count,
    "replication_factor": replication_factor,
    "target_broker_id": target_broker_id,
    "partition_plan": partition_plan,
    "group_summaries": group_summaries,
}
layout_plan_file.write_text(json.dumps(plan_payload, indent=2) + "\n", encoding="utf-8")

summary_lines = [
    f"topic={topic_name}",
    "layout=fixed_6_16",
    f"target_broker_id={target_broker_id}",
]
for group in group_summaries:
    parts = ",".join(str(partition_id) for partition_id in group["partitions"])
    leaders = ",".join(str(partition_id) for partition_id in group["leader_partitions"])
    summary_lines.extend(
        [
            f"group={group['name']}",
            f"  log_dir={group['log_dir']}",
            f"  partition_count={group['partition_count']}",
            f"  leader_count={group['leader_count']}",
            f"  partitions={parts}",
            f"  leader_partitions={leaders}",
        ]
    )
layout_plan_summary_file.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
PY
}
