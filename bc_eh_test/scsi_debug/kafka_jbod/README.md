# Kafka JBOD scsi_debug experiment guide

This directory contains the guest-side setup, validation, workload, and
fault-injection scripts for the Kafka JBOD experiment.

The provided Kafka VM images have Kafka installed at
`/root/kafka_2.13-4.2.0`.

<br>

## Directory Overview

This `README.md` describes the files and subdirectories at this level:

```text
kafka_jbod/
├── basic_validation/
├── formal_topic/
├── workload/
├── fault_injection/
├── setup_kafka_jbod_baseline.sh
├── cleanup_kafka_jbod_baseline.sh
├── cleanup_kafka_jbod_experiment_outputs.sh
├── README.md
├── kafka_jbod_common.sh
├── 00_reset_kafka_runtime_env.sh
├── 01_generate_kafka_properties.sh
├── 02_format_local_kafka_storage.sh
├── 03_start_local_kafka_broker.sh
├── 10_load_kafka_jbod_topology.sh
├── 11_prepare_kafka_data_mounts.sh
├── 12_verify_kafka_jbod_layout.sh
└── 99_cleanup_kafka_jbod.sh
```

- `basic_validation/`
  Broker-side Kafka cluster sanity check, normally run on one broker VM such as
  `kafka-1` after all three brokers are running. It checks bootstrap
  connectivity, KRaft quorum status, and creation/description of a replicated
  `smoke` topic. Run `sudo bash basic_validation/run_basic_validation.sh`.

- `formal_topic/` (run one layout wrapper)
  Cluster-level topic creation and log-directory layout setup/checks for the
  formal Kafka runs, normally run once on one broker VM such as `kafka-1`.
  It provides three layout entries: `default_layout/`, `fixed_6_16/`, and
  `leader_tilt_12_4/`. Select the layout by running the corresponding wrapper
  script; the directory itself is not a single command entry. For one
  experiment round, run one of:
  `sudo bash formal_topic/default_layout/run_formal_topic_layout_check.sh`,
  `sudo bash formal_topic/fixed_6_16/run_fixed_6_16_layout.sh`, or
  `sudo bash formal_topic/leader_tilt_12_4/run_leader_tilt_12_4_layout.sh`.

- `workload/` (run from `kafka-client`)
  Producer workload scripts and helper programs. The main Kafka experiment
  entry is `workload/run_formal_pinned_partition_workload.sh`, normally run on
  `kafka-client` after one `formal_topic/` layout wrapper has completed. Run
  `sudo bash workload/run_formal_pinned_partition_workload.sh`.
  `workload/run_formal_producer_baseline.sh` is the Kafka producer-perf-test
  based workload entry. `workload/FixedPartitionProducerWorkload.java` is the
  Java implementation used by the pinned-partition workload entry.
  `workload/PersistentProducerJmxSampler.java` samples producer JMX counters
  for the producer-baseline path. `workload/summarize_pinned_partition_groups.py`
  post-processes per-partition workload results into fault-target and healthy
  partition groups. `workload/workload_common.sh` contains shared helper
  functions and does not need to be run directly.

- `fault_injection/`
  Linux EH and BC-EH fault-injection entries for the Kafka JBOD experiment.
  The default fault target is broker 1, so these scripts normally run on
  `kafka-1`.

- `setup_kafka_jbod_baseline.sh`
  Main broker-side setup entry. Run `sudo bash setup_kafka_jbod_baseline.sh`
  once on each broker VM: `kafka-1`, `kafka-2`, and `kafka-3`.

- `cleanup_kafka_jbod_baseline.sh`
  Broker-side cleanup entry for stopping Kafka and removing the local
  `scsi_debug` data-disk topology. Run it once on each broker VM when tearing
  down the baseline.

- `cleanup_kafka_jbod_experiment_outputs.sh`
  Clears generated experiment outputs while keeping the broker baseline intact.
  Run it on the VM where previous output files should be removed before a fresh
  measurement round.

- `README.md`
  This detailed Kafka JBOD experiment guide.

- `kafka_jbod_common.sh` (no need to run directly)
  Shared helpers for loading `scsi_debug`, discovering target devices, tuning
  queues, and mapping targets to Kafka data directories.

- `00_reset_kafka_runtime_env.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it resets stale
  Kafka runtime state before a fresh broker setup.

- `01_generate_kafka_properties.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it regenerates
  the three Kafka KRaft broker configuration files.

- `02_format_local_kafka_storage.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it runs
  Kafka-level storage format for the local broker selected by the VM's cluster
  IP, after the data disks have been mounted.

- `03_start_local_kafka_broker.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it starts the
  local Kafka broker process.

- `10_load_kafka_jbod_topology.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it loads the
  three-disk `scsi_debug` JBOD topology inside a broker VM.

- `11_prepare_kafka_data_mounts.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it performs
  filesystem-level preparation for the three `scsi_debug` data disks and mounts
  them under `/data/kafka-*`.

- `12_verify_kafka_jbod_layout.sh` (no need to run directly)
  Internal setup step called by `setup_kafka_jbod_baseline.sh`; it checks that
  the `scsi_debug` topology and Kafka data mounts match the experiment
  assumptions.

- `99_cleanup_kafka_jbod.sh` (no need to run directly)
  Internal cleanup step called by `setup_kafka_jbod_baseline.sh` and
  `cleanup_kafka_jbod_baseline.sh`; it unmounts Kafka data disks and unloads
  `scsi_debug`-related modules.

<br>

## Current 4-VM setup
- The current setup uses three Kafka broker VMs and one Kafka client VM.
- The three broker VMs use `scsi_debug`-backed Kafka data disks.
- The client VM is used for producer workload generation.
- Each VM uses two NICs.
- `enp0s2` is the management NIC:
  - backed by QEMU `-netdev user`
  - guest-side uses `dhcp4: true`
  - host-side SSH forwarding is `2201/2202/2203/2204 -> guest:22`
- `enp0s3` is the Kafka cluster NIC:
  - backed by QEMU `-netdev socket,mcast=239.192.168.1:1102`
  - guest-side uses static addressing
  - Kafka `advertised.listeners` and `controller.quorum.voters` bind to this NIC, not `enp0s2`

| VM | OS overlay | host SSH port | `enp0s2` MAC | `enp0s3` MAC | `enp0s3` IP |
| --- | --- | --- | --- | --- | --- |
| `kafka-1` | `./kafka1-os.qcow2` | `2201` | `52:54:00:10:10:11` | `52:54:00:20:20:11` | `10.20.0.11/24` |
| `kafka-2` | `./kafka2-os.qcow2` | `2202` | `52:54:00:10:10:12` | `52:54:00:20:20:12` | `10.20.0.12/24` |
| `kafka-3` | `./kafka3-os.qcow2` | `2203` | `52:54:00:10:10:13` | `52:54:00:20:20:13` | `10.20.0.13/24` |
| `kafka-client` | `./kafka-client-os.qcow2` | `2204` | `52:54:00:10:10:21` | `52:54:00:20:20:21` | `10.20.0.21/24` |

Notes:
- `enp0s2` is only for host management and outbound access from the guest.
- Under QEMU user networking, each guest may see the same NAT-side address such as `10.0.2.15`; this is normal and is not used for broker identity.
- The stable broker identity comes from `enp0s3` plus the forwarded SSH port.
- The OS overlays are expected at the artifact root directory, next to the top-level `Makefile`.

Host-side SSH entry points:

```bash
ssh -p 2201 root@127.0.0.1   # kafka-1
ssh -p 2202 root@127.0.0.1   # kafka-2
ssh -p 2203 root@127.0.0.1   # kafka-3
ssh -p 2204 root@127.0.0.1   # kafka-client
```

<br>

### QEMU startup
Start the Kafka VM set from the artifact root directory:

```bash
cd 2004-BC-EH-Artifact-Evaluation
make kafka
```

The top-level `Makefile` also provides individual targets:

```bash
make kafka1
make kafka2
make kafka3
make kafka-client
```

<br>

## Expected Setup Result
After `setup_kafka_jbod_baseline.sh` finishes on a broker VM, that VM should
show the following state.

<br>

### Data Disks

The broker should have three `scsi_debug` data disks mounted for Kafka:

```text
target 0 -> /data/kafka-1
target 1 -> /data/kafka-2
target 2 -> /data/kafka-3
```

The `scsi_debug` topology printed by the setup script should show:

```text
1 host / 1 channel / 3 targets / 1 lun per target
```

<br>

### Kafka Storage

Kafka topic data should be under:

```text
/data/kafka-1/kafka-logs
/data/kafka-2/kafka-logs
/data/kafka-3/kafka-logs
```

Kafka KRaft metadata should remain on the system disk:

```text
/var/lib/kafka-metadata
```

<br>

### Queue Settings

The setup script configures symmetric queue settings for the three
`scsi_debug` Kafka data disks:

```text
queue_depth = 64 per disk
nr_requests = 64 per disk
host_max_queue = 192
max_queue = 192
```

Here `192 = 64 * 3`, matching the three Kafka data disks created for each
broker VM.

<br>

### Cluster Readiness

- After `setup_kafka_jbod_baseline.sh` has finished on `kafka-1`, `kafka-2`,
  and `kafka-3`, each broker VM should expose the same three-disk Kafka data
  layout.
- After all three brokers finish setup,
  `basic_validation/run_basic_validation.sh` should succeed on one broker VM.
- Before starting the producer workload, one `formal_topic/` layout wrapper
  should succeed on one broker VM.

<br>

## Fault-Injection Stage
Run fault-injection scripts after broker setup, basic validation, and formal
topic layout have completed, and after the producer workload has started. The
default fault target is broker 1, target 0, corresponding to
`/data/kafka-1/kafka-logs`; run these scripts on `kafka-1`.

Linux EH entries:

```bash
sudo bash fault_injection/linux-eh/run_single_disk_offline_case.sh
sudo bash fault_injection/linux-eh/run_single_disk_recoverable_stall_case.sh
```

BC-EH entries:

```bash
sudo bash fault_injection/bc-eh/run_single_disk_offline_case.sh
sudo bash fault_injection/bc-eh/run_single_disk_recoverable_stall_case.sh
```

The `linux-eh/` entries select the `host` recovery path, and the `bc-eh/`
entries select the `sdev` recovery path. The `offline` case injects one
unrecoverable single-disk fault. The `recoverable_stall` case injects one
long-timeout single-disk fault that eventually recovers.

These fault-injection scripts do not start or stop the producer workload. Raw
outputs are written to:

```text
fault_injection/output/<timestamp>.<case>.<eh_profile>.<eh_mode>/
```

<br>
