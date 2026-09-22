# Kafka JBOD scsi_debug experiment guide

## Goal
- This directory contains the guest-side setup, validation, workload, and
  fault-injection scripts for the Kafka JBOD experiment.
- Kafka is installed at `/root/kafka_2.13-4.2.0`.
- Running `setup_kafka_jbod_baseline.sh` once inside each broker VM
  (`kafka-1`, `kafka-2`, and `kafka-3`) should:
  - reset the previous Kafka runtime state;
  - regenerate `kafka-1.properties/kafka-2.properties/kafka-3.properties`;
  - create three independent `scsi_debug` data disks;
  - map them stably to `/data/kafka-1`, `/data/kafka-2`, `/data/kafka-3`;
  - create Kafka log directories at `/data/kafka-1/kafka-logs`, `/data/kafka-2/kafka-logs`, `/data/kafka-3/kafka-logs`;
  - keep `metadata.log.dir` on the system disk;
  - format the local broker storage and start the local Kafka process;
  - make the setup repeatable across the three broker VMs.

<br>

## Current 4-VM setup
- The current setup uses three Kafka broker VMs and one Kafka client VM.
- The three broker VMs use `scsi_debug`-backed Kafka data disks.
- The client VM is used for producer workload generation.
- Each VM uses two NICs.
- `enp0s2` is the management NIC:
  - backed by QEMU `-netdev user`
  - guest side uses `dhcp4: true`
  - host side SSH forwarding is `2201/2202/2203/2204 -> guest:22`
- `enp0s3` is the Kafka cluster NIC:
  - backed by QEMU `-netdev socket,mcast=239.192.168.1:1102`
  - guest side uses static addressing
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

### Netplan inside each guest
`kafka-1`:

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
    enp0s3:
      addresses:
        - 10.20.0.11/24
```

`kafka-2`:

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
    enp0s3:
      addresses:
        - 10.20.0.12/24
```

`kafka-3`:

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
    enp0s3:
      addresses:
        - 10.20.0.13/24
```

`kafka-client`:

```yaml
network:
  version: 2
  ethernets:
    enp0s2:
      dhcp4: true
    enp0s3:
      addresses:
        - 10.20.0.21/24
```

After editing netplan:

```bash
netplan apply
ip -4 a show enp0s2
ip -4 a show enp0s3
```

Host-side SSH entry points:

```bash
ssh -p 2201 root@127.0.0.1
ssh -p 2202 root@127.0.0.1
ssh -p 2203 root@127.0.0.1
ssh -p 2204 root@127.0.0.1
```

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

## Baseline invariants
- After the setup scripts finish, each broker guest should expose exactly three Kafka data disks under one `shost`:
  - disk A -> `/data/kafka-1`
  - disk B -> `/data/kafka-2`
  - disk C -> `/data/kafka-3`
- The three disks must be independent fault targets from the SCSI topology point of view.
- The topology should remain:
  - `1 host / 1 channel / 3 targets / 1 lun per target`
- Kafka metadata must not be placed on these disks.

<br>

## Why this topology is the right baseline
- Kafka `JBOD` wants multiple independent `log.dirs` on the same broker.
- Putting all three disks under the same `shost` preserves the core Linux-EH vs BC-EH comparison:
  - one failed disk may still amplify into host-wide disturbance under Linux-EH;
  - BC-EH should try to keep the disturbance local.
- Putting them under different `starget`s makes each disk a separate recovery boundary.
- Do not use `1 target / 3 luns` as the main topology:
  - a target reset would legitimately couple the three Kafka data disks;
  - that weakens the "one failed log.dir should not drag the other two" claim.
- Do not use `3 channels` or `3 hosts` as the main topology:
  - that would give isolation from topology alone;
  - it would make BC-EH's contribution less convincing.

<br>

## Recommended scripted workflow
The broker initialization chain is implemented per broker VM.
- Run it once inside `kafka-1`, once inside `kafka-2`, and once inside `kafka-3`.
- Each broker VM uses the same scripts, and the local broker identity is inferred from `enp0s3`.
- Run producer workload scripts from `kafka-client`.

### `01_generate_kafka_properties.sh`
Purpose:
- regenerate Kafka KRaft broker configs on every initialization;
- overwrite `/root/kafka_2.13-4.2.0/config/kafka-1.properties`;
- overwrite `/root/kafka_2.13-4.2.0/config/kafka-2.properties`;
- overwrite `/root/kafka_2.13-4.2.0/config/kafka-3.properties`.

Behavior:
- the script writes the three files from the current `kafkaJBOD.md` template that uses:
  - broker IPs `10.20.0.11/12/13`
  - `controller.quorum.voters=1@10.20.0.11:9093,2@10.20.0.12:9093,3@10.20.0.13:9093`
  - `log.dirs=/data/kafka-1/kafka-logs,/data/kafka-2/kafka-logs,/data/kafka-3/kafka-logs`
  - `metadata.log.dir=/var/lib/kafka-metadata`
- the separate `kafka-logs` subdirectories are intentional; do not point Kafka at the ext4 mount roots `/data/kafka-1..3`, or Kafka will fail on `lost+found`.
- it does not try to preserve local edits; regeneration is always overwrite-by-design.
- it also tries to infer the local broker id from `enp0s3` and prints which `kafka-X.properties` the current VM should use.

Expected usage:

```bash
bash 01_generate_kafka_properties.sh
```

### `02_format_local_kafka_storage.sh`
Purpose:
- infer the local broker id from `enp0s3`;
- select `/root/kafka_2.13-4.2.0/config/kafka-X.properties`;
- run `kafka-storage.sh format` for the current VM only.

Behavior:
- the default cluster id is `JfPM4evGQ2e3ZnxRI2iSmA`;
- you can override it with `CLUSTER_ID=...`;
- by default the script requires `/data/kafka-1..3` to be mounted filesystems;
- if any of them is not mounted, the script fails fast to avoid accidentally formatting the system-disk view of `/data`.

Expected usage:

```bash
bash 02_format_local_kafka_storage.sh
```

### `03_start_local_kafka_broker.sh`
Purpose:
- infer the local broker id from `enp0s3`;
- start only the current VM's Kafka process;
- wait until local ports `9092/9093` are listening.

Behavior:
- the script starts `kafka-server-start.sh -daemon config/kafka-X.properties`;
- if the matching Kafka process is already running, it exits without starting a duplicate;
- if the ports are not ready yet but the Kafka process is still alive, it returns with a warning so the remaining VMs can continue bootstrapping the 3-node KRaft quorum;
- if startup fails, it prints the tail of `logs/server.log`.

Expected usage:

```bash
bash 03_start_local_kafka_broker.sh
```

#### `10_load_kafka_jbod_topology.sh`
Purpose:
- unload any stale `scsi_debug` instance;
- load the `scsi_debug` module with the Kafka JBOD baseline topology;
- wait until exactly three `scsi_debug` data disks appear.

Expected topology:
- `add_host=1`
- `num_channels=1`
- `num_tgts=3`
- `max_luns=1`
- `host_max_queue=192`
- `max_queue=192`
- `dev_size_mb=4096`

Recommended load command:

```bash
modprobe crc_t10dif
modprobe scsi_debug \
    add_host=1 \
    num_channels=1 \
    num_tgts=3 \
    max_luns=1 \
    host_max_queue=192 \
    max_queue=192 \
    dev_size_mb=4096 \
    sector_size=512 \
    dsense=1 \
    delay=1
```

Notes:
- On the full Ubuntu guest used by Kafka JBOD, the script loads `scsi_debug` from the system module tree with `modprobe`, not from `/double_D/modules`.
- If your patched `scsi_debug` uses different parameter names, the script should use the patched names instead.
- The script fails fast unless it sees exactly one `scsi_debug` host and exactly three `host:0:target:0` devices.
- The script does not assume fixed block letters; it discovers the devices by `target=0/1/2`.

#### `11_prepare_kafka_data_mounts.sh`
Purpose:
- create filesystems if needed;
- create mount points;
- mount the three Kafka data disks;
- create `kafka-logs/` under each mount point for Kafka itself;
- set ownership for the current Kafka runtime user, which is `root:root` by default.

Expected result:
- `target-0 -> /data/kafka-1`
- `target-1 -> /data/kafka-2`
- `target-2 -> /data/kafka-3`

Recommended actions:

```bash
mkfs.ext4 /dev/<target-0-block>
mkfs.ext4 /dev/<target-1-block>
mkfs.ext4 /dev/<target-2-block>

mkdir -p /data/kafka-1 /data/kafka-2 /data/kafka-3
mount -o noatime /dev/<target-0-block> /data/kafka-1
mount -o noatime /dev/<target-1-block> /data/kafka-2
mount -o noatime /dev/<target-2-block> /data/kafka-3
mkdir -p /data/kafka-1/kafka-logs /data/kafka-2/kafka-logs /data/kafka-3/kafka-logs
chown root:root /data/kafka-1 /data/kafka-2 /data/kafka-3
chown root:root /data/kafka-1/kafka-logs /data/kafka-2/kafka-logs /data/kafka-3/kafka-logs
```

Notes:
- For repeated testing, it is better to make this script idempotent:
  - detect whether a filesystem already exists before reformatting;
  - detect whether the mount point is already mounted.
- The current script already supports `FORCE_REFORMAT=1`.
- The default owner/group is `root:root`, matching the current Kafka runtime path under `/root/kafka_2.13-4.2.0`.
- The separate `kafka-logs/` subdirectory is required because the ext4 mount root contains `lost+found`; pointing `log.dirs` at `/data/kafka-1..3` would make Kafka fail during log directory scan.

#### `12_verify_kafka_jbod_layout.sh`
Purpose:
- verify that the topology and mounts match the experiment assumptions.

The script should print at least:
- `lsblk`
- `findmnt`
- `lsscsi` or equivalent device-to-target mapping
- a short mapping summary:
  - `target-0 -> /dev/<block> -> /data/kafka-1`
  - `target-1 -> /dev/<block> -> /data/kafka-2`
  - `target-2 -> /dev/<block> -> /data/kafka-3`

This script should fail if:
- any mount point is missing;
- the three data disks collapse onto an unexpected topology;
- the guest sees more or fewer than three Kafka data disks.

### `99_cleanup_kafka_jbod.sh`
Purpose:
- stop using the Kafka data disks cleanly after a run;
- unmount the three mount points;
- unload `scsi_debug`-related modules.

Recommended actions:

```bash
umount /data/kafka-1 || true
umount /data/kafka-2 || true
umount /data/kafka-3 || true
modprobe -r scsi_debug || true
modprobe -r crc_t10dif || true
```

## Wrapper scripts
The directory also provides three wrapper scripts:

### `setup_kafka_jbod_baseline.sh`
Purpose:
- call the currently implemented initialization steps in order.
- the current baseline wrapper already includes:
  1. `00_reset_kafka_runtime_env.sh`
  2. `99_cleanup_kafka_jbod.sh`
  3. `01_generate_kafka_properties.sh`
  4. `10_load_kafka_jbod_topology.sh`
  5. `11_prepare_kafka_data_mounts.sh`
  6. `12_verify_kafka_jbod_layout.sh`
  7. `02_format_local_kafka_storage.sh`
  8. `03_start_local_kafka_broker.sh`

Expected usage:

```bash
bash setup_kafka_jbod_baseline.sh
```

Notes:
- run it once per broker VM inside `kafka-1`, `kafka-2`, and `kafka-3`;
- after all three VMs finish setup, the cluster should be ready for `basic_validation/run_basic_validation.sh`.

### `cleanup_kafka_jbod_baseline.sh`
Purpose:
- call the currently implemented cleanup steps in order.

Behavior:
  1. `00_reset_kafka_runtime_env.sh`
  2. `99_cleanup_kafka_jbod.sh`

Expected usage:

```bash
bash cleanup_kafka_jbod_baseline.sh
```

Notes:
- stop on first failure;
- run it once per broker VM to stop the local broker and tear down the local topology;
- after cleanup, no Kafka listener should remain on `9092/9093`, and `/data/kafka-1..3` should be unmounted.

### `cleanup_kafka_jbod_experiment_outputs.sh`
Purpose:
- clear only experiment-side outputs without tearing down the broker baseline;
- stop any still-running producer workload on the client VM.

Behavior:
  1. stop `kafka-producer-perf-test.sh` / `kafka.tools.ProducerPerformance` if present
  2. clear `workload/output/`
  3. clear `formal_topic/output/`
  4. clear `fault_injection/output/`

Expected usage:

```bash
bash cleanup_kafka_jbod_experiment_outputs.sh
```

Notes:
- run it on the client VM before a fresh workload round if you want clean producer outputs;
- run it on a broker VM before a fresh topic-layout or fault-injection round if you want clean broker-side outputs;
- it is repeatable and does not stop Kafka brokers or unload `scsi_debug`.

## Validation scripts

### `basic_validation/run_basic_validation.sh`
Purpose:
- provide the lightweight pre-test validation entry;
- check that the KRaft control plane is up;
- check that a small smoke topic can be created and described.

Behavior:
  1. default to the current VM's local broker on `enp0s3:9092`, unless `BOOTSTRAP_SERVER=` is set explicitly
  2. wait until the bootstrap server is reachable
  3. run `kafka-metadata-quorum.sh --bootstrap-server ... describe --status`
  4. create or reuse topic `smoke`
  5. describe topic `smoke` and verify the basic metadata

Expected usage:

```bash
bash basic_validation/run_basic_validation.sh
```

Notes:
- run it after all three VMs finish `setup_kafka_jbod_baseline.sh`;
- running it on one VM is enough for the shared cluster check, but running it on all three is also safe because the script creates topic `smoke` with `--if-not-exists`.
- run it on a broker VM by default; on `kafka-client`, pass `BOOTSTRAP_SERVER=10.20.0.11:9092`.

### `formal_topic/default_layout/create_formal_jbod_topic.sh`
Purpose:
- create or reuse the formal Kafka JBOD experiment topic;
- verify that the topic metadata matches the expected partition count and replication factor.

Behavior:
  1. default to the current VM's local broker on `enp0s3:9092`, unless `BOOTSTRAP_SERVER=` is set explicitly
  2. wait until the bootstrap server is reachable
  3. create or reuse topic `jbod-hot` with `--if-not-exists`
  4. describe topic `jbod-hot`
  5. fail if the existing topic layout does not match the expected formal-topic parameters

Expected usage:

```bash
bash formal_topic/default_layout/create_formal_jbod_topic.sh
```

Notes:
- this is the script counterpart of the "formal Kafka JBOD topic" step in the paper notes;
- if `jbod-hot` already exists with the wrong partition count or replication factor, the script fails and asks you to recreate it cleanly.

### `formal_topic/default_layout/check_formal_jbod_layout.sh`
Purpose:
- export the formal topic's broker/log-dir placement;
- check whether the first-round fault target is meaningful.

Behavior:
  1. describe topic `jbod-hot`
  2. run `kafka-log-dirs.sh --describe` for brokers `1,2,3`
  3. summarize each broker's three Kafka `log.dirs`
  4. count how many topic replicas and leader partitions are on the target log directory, default `broker-1:/data/kafka-1/kafka-logs`
  5. fail if the target log directory does not hold enough partitions to support a meaningful first-round single-disk fault case

Expected usage:

```bash
bash formal_topic/default_layout/check_formal_jbod_layout.sh
```

Notes:
- raw outputs are saved under `formal_topic/output/`;
- the current default pass criteria are intentionally simple:
  - the target broker must expose all three expected `log.dirs`
  - the target fault `log.dir` must hold at least `8` topic replicas
  - the target fault `log.dir` must hold at least `3` leader partitions

### `formal_topic/default_layout/run_formal_topic_layout_check.sh`
Purpose:
- provide the one-shot entry for the formal topic layout step.

Behavior:
  1. create or reuse the formal topic
  2. run the layout analysis and target suitability check

Expected usage:

```bash
bash formal_topic/default_layout/run_formal_topic_layout_check.sh
```

Notes:
- run it after `basic_validation/run_basic_validation.sh` succeeds;
- this is the script that answers "is `broker-1:/data/kafka-1/kafka-logs` a good first fault target right now?"
- unlike the per-VM setup scripts, this cluster-level check only needs to run on one VM;
- prefer running it on `kafka-1` so the exported outputs stay centralized on one guest;
- running it on all three VMs does not add coverage, because the script already queries brokers `1,2,3` in one pass and would only generate duplicate outputs on each guest.
- on `kafka-client`, pass `BOOTSTRAP_SERVER=10.20.0.11:9092`.

### `workload/run_formal_producer_baseline.sh`
Purpose:
- provide the formal producer baseline with fixed topic, record size, throughput, and run window;
- keep workload startup separate from fault injection.

Behavior:
  1. resolve a bootstrap server and wait until it is reachable
  2. derive `num-records = throughput * run_secs`
  3. run `kafka-producer-perf-test.sh` on topic `jbod-hot`
  4. save the raw producer output plus a sidecar meta file and command file under `workload/output/`

Notes:
- this script is intentionally only the workload side of the experiment;
- fault injection should remain a separate script/control path in the next experiment stage;
- the current default baseline is `4 KiB` records, `600` records/s, and `1200s` total run time;
- override parameters with environment variables such as `FORMAL_WORKLOAD_THROUGHPUT=...` or `FORMAL_WORKLOAD_RUN_SECS=...` when tuning the platform.

### `workload/run_formal_pinned_partition_workload.sh`
Purpose:
- provide the formal fixed-partition producer workload used for the Kafka
  healthy-sibling throughput timeline.
- save timestamped producer output and per-partition summaries under
  `workload/output/`.

Expected usage on `kafka-client`:

```bash
bash workload/run_formal_pinned_partition_workload.sh
```

<br>

## Recommended device mapping inside the guest
Use this mapping consistently across all three VMs:
- `target 0 -> discovered block device -> /data/kafka-1`
- `target 1 -> discovered block device -> /data/kafka-2`
- `target 2 -> discovered block device -> /data/kafka-3`

Do not hardcode `/dev/sdb/sdc/sdd` in the experiment scripts.
- In the current VM layout, the system disk is `virtio` and is typically `/dev/vda`.
- The three `scsi_debug` data disks therefore usually become the first three `/dev/sdX` names, but the exact letters are not the experiment invariant.
- The experiment invariant is the `target-0/1/2` identity under one `scsi_debug` `shost`.

This consistency matters because the later fault-injection scripts will refer to a specific Kafka `log.dir` as the primary target, for example:
- fault target disk mount = `/data/kafka-1`, corresponding Kafka `log.dir` = `/data/kafka-1/kafka-logs`
- healthy sibling `log.dirs` = `/data/kafka-2/kafka-logs`, `/data/kafka-3/kafka-logs`

<br>

## Queue settings for the baseline
Suggested baseline queue settings:
- `queue_depth = 64` per disk
- `nr_requests = 64` per disk
- `host_can_queue = 64 * 3 = 192`

When loading `scsi_debug`, prefer:
- `host_max_queue=192`
- `max_queue=192`

The purpose is not to chase peak synthetic throughput, but to keep the three Kafka data disks symmetric and to avoid introducing accidental queue imbalance between the three `log.dirs`.

<br>

## What should stay on the system disk
Do **not** place the following on the three `scsi_debug` Kafka data disks:
- `metadata.log.dir`
- the OS root filesystem
- SSH state and general guest management files

Keep at least:
- `metadata.log.dir=/var/lib/kafka-metadata`

on the system disk.

This is critical. If metadata is placed on the fault injection disk, the experiment stops being "one Kafka data disk fault" and turns into "controller/metadata + data path together damaged", which is not the target claim.

<br>

## What the next experiment stage will consume
After this step succeeds, the Kafka experiment can safely move to the next stage:
- configure Kafka broker `log.dirs=/data/kafka-1/kafka-logs,/data/kafka-2/kafka-logs,/data/kafka-3/kafka-logs`
- create the `jbod-hot` topic
- run the producer workload from `kafka-client`
- record `kafka-log-dirs.sh --describe`
- inject fault into only one data disk, typically mount `/data/kafka-1`, corresponding Kafka `log.dir` `/data/kafka-1/kafka-logs`
- compare Linux-EH vs BC-EH on:
  - affected partition subset
  - healthy sibling `log.dirs`
  - ISR / leader migration / tail latency impact

The fault-injection stage is split into a separate directory:
- `fault_injection/fault_injection_common.sh`
- `fault_injection/single_disk_offline_case_impl.sh`
- `fault_injection/single_disk_recoverable_stall_case_impl.sh`
- `fault_injection/linux-eh/run_single_disk_offline_case.sh`
- `fault_injection/linux-eh/run_single_disk_recoverable_stall_case.sh`
- `fault_injection/bc-eh/run_single_disk_offline_case.sh`
- `fault_injection/bc-eh/run_single_disk_recoverable_stall_case.sh`

There are 7 files in `fault_injection/` in total.
- `fault_injection_common.sh` plus the two `*_impl.sh` files are internal shared pieces.
- the 4 scripts under `linux-eh/` and `bc-eh/` are the only direct user-facing entry points.
- these entry scripts do not start or stop the producer workload.
- the `linux-eh/` wrapper scripts hard-code the `host` path
- the `bc-eh/` wrapper scripts hard-code the `sdev` path
- the `run_single_disk_offline_case.sh` pair injects one unrecoverable P8-style single-disk fault and waits for an `offline`-style result on the target `sdev`
- the `run_single_disk_recoverable_stall_case.sh` pair injects one long-timeout P5-style recoverable fault once, i.e. device reset returns, post-device TUR times out, and target reset finally recovers the disk
- raw outputs are written to `fault_injection/output/<timestamp>.<case>.<eh_profile>.<eh_mode>/`

<br>

## Current core directory contents
The directory currently contains:
- `README.md`
- `00_reset_kafka_runtime_env.sh`
- `01_generate_kafka_properties.sh`
- `02_format_local_kafka_storage.sh`
- `03_start_local_kafka_broker.sh`
- `kafka_jbod_common.sh`
- `10_load_kafka_jbod_topology.sh`
- `11_prepare_kafka_data_mounts.sh`
- `12_verify_kafka_jbod_layout.sh`
- `basic_validation/run_basic_validation.sh`
- `fault_injection/fault_injection_common.sh`
- `fault_injection/single_disk_offline_case_impl.sh`
- `fault_injection/single_disk_recoverable_stall_case_impl.sh`
- `fault_injection/linux-eh/run_single_disk_offline_case.sh`
- `fault_injection/linux-eh/run_single_disk_recoverable_stall_case.sh`
- `fault_injection/bc-eh/run_single_disk_offline_case.sh`
- `fault_injection/bc-eh/run_single_disk_recoverable_stall_case.sh`
- `formal_topic/formal_topic_common.sh`
- `formal_topic/default_layout/create_formal_jbod_topic.sh`
- `formal_topic/default_layout/check_formal_jbod_layout.sh`
- `formal_topic/default_layout/run_formal_topic_layout_check.sh`
- `formal_topic/fixed_6_16/apply_fixed_6_16_layout.sh`
- `formal_topic/fixed_6_16/check_fixed_6_16_layout.sh`
- `formal_topic/fixed_6_16/fixed_6_16_common.sh`
- `formal_topic/fixed_6_16/run_fixed_6_16_layout.sh`
- `formal_topic/leader_tilt_12_4/apply_leader_tilt_12_4_layout.sh`
- `formal_topic/leader_tilt_12_4/check_leader_tilt_12_4_layout.sh`
- `formal_topic/leader_tilt_12_4/leader_tilt_12_4_common.sh`
- `formal_topic/leader_tilt_12_4/run_leader_tilt_12_4_layout.sh`
- `workload/FixedPartitionProducerWorkload.java`
- `workload/PersistentProducerJmxSampler.java`
- `workload/run_formal_pinned_partition_workload.sh`
- `workload/run_formal_producer_baseline.sh`
- `workload/summarize_pinned_partition_groups.py`
- `workload/workload_common.sh`
- `cleanup_kafka_jbod_experiment_outputs.sh`
- `cleanup_kafka_jbod_baseline.sh`
- `99_cleanup_kafka_jbod.sh`
- `setup_kafka_jbod_baseline.sh`

<br>

## Minimal success criteria
The scripted step is considered successful only if all of the following hold:
1. Each broker guest sees exactly three Kafka data disks.
2. The three disks are mounted at `/data/kafka-1..3`.
3. Kafka log directories exist at `/data/kafka-1..3/kafka-logs`.
4. The topology remains `1 host / 1 channel / 3 targets / 1 lun per target`.
5. Kafka metadata stays on the system disk.
6. `basic_validation/run_basic_validation.sh` succeeds after all three VMs finish setup.
7. `formal_topic/default_layout/run_formal_topic_layout_check.sh` succeeds before the formal workload stage.
8. The broker setup is repeatable across `kafka-1`, `kafka-2`, and `kafka-3`.
