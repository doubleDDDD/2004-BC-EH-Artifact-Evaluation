#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Row:
    partition: int
    target_rps: int
    records_sent: int
    error_count: int
    bytes_sent: int
    avg_latency_ms: float
    max_latency_ms: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize pinned workload worker_summary.csv by partition groups.")
    parser.add_argument("--worker-summary-csv", required=True)
    parser.add_argument("--pre-logdirs-json", required=True)
    parser.add_argument("--pre-topic-describe", required=True)
    parser.add_argument("--fault-log-dir", default="/data/kafka-1/kafka-logs")
    parser.add_argument("--fault-broker-id", type=int, default=1)
    parser.add_argument("--output-csv", required=True)
    return parser.parse_args()


def load_worker_rows(path: Path) -> list[Row]:
    rows: list[Row] = []
    with path.open() as f:
        for row in csv.DictReader(f):
            rows.append(
                Row(
                    partition=int(row["partition"]),
                    target_rps=int(row["target_rps"]),
                    records_sent=int(row["records_sent"]),
                    error_count=int(row["error_count"]),
                    bytes_sent=int(row["bytes_sent"]),
                    avg_latency_ms=float(row["avg_latency_ms"]),
                    max_latency_ms=float(row["max_latency_ms"]),
                )
            )
    return rows


def load_bad_logdir_partitions(path: Path, broker_id: int, fault_log_dir: str) -> set[int]:
    obj = json.loads(path.read_text())
    for broker in obj["brokers"]:
        if broker["broker"] != broker_id:
            continue
        for logdir in broker["logDirs"]:
            if logdir["logDir"] != fault_log_dir:
                continue
            return {int(part["partition"].split("-")[-1]) for part in logdir["partitions"]}
    raise ValueError(f"cannot locate broker={broker_id} logDir={fault_log_dir}")


def load_leader_partitions(path: Path, broker_id: int) -> set[int]:
    leader_parts: set[int] = set()
    pattern = re.compile(r"Topic: .*?Partition: (\d+)\s+Leader: (\d+)\s+Replicas: ([0-9,]+)\s+Isr: ([0-9,]+)")
    for line in path.read_text().splitlines():
        match = pattern.search(line)
        if not match:
            continue
        partition = int(match.group(1))
        leader = int(match.group(2))
        if leader == broker_id:
            leader_parts.add(partition)
    return leader_parts


def weighted_avg(rows: list[Row], attr: str, weight_attr: str) -> float:
    total_weight = sum(getattr(row, weight_attr) for row in rows)
    if total_weight == 0:
        return 0.0
    weighted_sum = sum(getattr(row, attr) * getattr(row, weight_attr) for row in rows)
    return weighted_sum / total_weight


def summarize_group(name: str, rows: list[Row]) -> dict[str, str]:
    return {
        "group_name": name,
        "partition_count": str(len(rows)),
        "target_rps_sum": str(sum(row.target_rps for row in rows)),
        "records_sent_sum": str(sum(row.records_sent for row in rows)),
        "error_count_sum": str(sum(row.error_count for row in rows)),
        "bytes_sent_sum": str(sum(row.bytes_sent for row in rows)),
        "avg_latency_ms_weighted_by_records": f"{weighted_avg(rows, 'avg_latency_ms', 'records_sent'):.3f}",
        "max_latency_ms_max": f"{max((row.max_latency_ms for row in rows), default=0.0):.3f}",
        "partitions": ",".join(str(row.partition) for row in sorted(rows, key=lambda item: item.partition)),
    }


def main() -> None:
    args = parse_args()

    worker_rows = load_worker_rows(Path(args.worker_summary_csv))
    bad_logdir_partitions = load_bad_logdir_partitions(
        Path(args.pre_logdirs_json), args.fault_broker_id, args.fault_log_dir
    )
    leader_partitions = load_leader_partitions(Path(args.pre_topic_describe), args.fault_broker_id)

    bad_leader = bad_logdir_partitions & leader_partitions
    bad_follower_only = bad_logdir_partitions - leader_partitions

    groups = {
        "bad_logdir_leader": [],
        "bad_logdir_follower_only": [],
        "healthy_other": [],
    }

    for row in worker_rows:
        if row.partition in bad_leader:
            groups["bad_logdir_leader"].append(row)
        elif row.partition in bad_follower_only:
            groups["bad_logdir_follower_only"].append(row)
        else:
            groups["healthy_other"].append(row)

    out_path = Path(args.output_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="") as f:
        fieldnames = [
            "group_name",
            "partition_count",
            "target_rps_sum",
            "records_sent_sum",
            "error_count_sum",
            "bytes_sent_sum",
            "avg_latency_ms_weighted_by_records",
            "max_latency_ms_max",
            "partitions",
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for group_name in ("bad_logdir_leader", "bad_logdir_follower_only", "healthy_other"):
            writer.writerow(summarize_group(group_name, groups[group_name]))

    print(out_path)


if __name__ == "__main__":
    main()
