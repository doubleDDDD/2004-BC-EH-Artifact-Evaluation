# 2004-BC-EH-Artifact-Evaluation

## 1. Artifact Contents

```bash
BC-EH Artifact
├── atclinux/       Linux v6.18 + BC-EH source
├── bc_eh_test/     test, VM setup, and experiment scripts
├── Makefile        host-side QEMU experiment launcher
└── README.md
```

This artifact is distributed as a Zenodo archive containing an archival snapshot of the BC-EH source repository, including the kernel source, experiment scripts, setup helpers, and documentation.

Evaluators can run the experiments on QEMU/KVM virtual machines or on physical machines. Nodes running the BC-EH SCSI experiments must boot the BC-EH kernel, and each node should have the dependencies required for its experiment role, such as fio, open-iscsi, targetcli, Java, or Kafka.

- `atclinux/`
  Linux v6.18 source tree with the BC-EH kernel changes and the provided
  `.config` file. The AE-relevant kernel changes are described in the
  `Kernel Source Overview` section.

- `bc_eh_test/`
  Test, runtime setup, and experiment scripts. It contains the `scsi_debug` tests,
  the `LLDD/iscsi_tcp` software iSCSI test scripts, and small host-side setup
  helpers used by the runtime experiments.

The `bc_eh_test/` directory is organized as:

```bash
bc_eh_test/
├── LLDD/
│   └── iscsi_tcp/
└── scsi_debug/
```

- `bc_eh_test/LLDD/iscsi_tcp/`
  Software iSCSI experiments for the `iscsi_tcp` path, including host-side
  target setup/teardown helpers, guest connect/disconnect helpers, and Linux
  EH versus BC-EH P1 test cases.

- `bc_eh_test/scsi_debug/`
  Main AE test suite based on the software `scsi_debug` device. The scripts
  use the installed kernel module through `modprobe scsi_debug`.

- `Makefile`
  Optional host-side QEMU launcher examples for VM-based iSCSI and Kafka
  experiments, including disk-overlay, networking, SSH forwarding, and VM
  topology parameters.

The `bc_eh_test/scsi_debug/` directory contains:

```bash
bc_eh_test/scsi_debug/
├── scsi_debug_common.sh
├── scsi_debug_case.sh
├── funcVer/
├── basictopo/
│   ├── linux-eh/
│   └── bc-eh/
├── complextopo/
│   ├── linux-eh/
│   └── bc-eh/
├── sequence_cases/
│   ├── linux-eh/
│   └── bc-eh/
├── checkpoint_perf/
├── fpl_perf_quick/
├── fpl_perf_real/
└── kafka_jbod/
```

- `scsi_debug_common.sh` and `scsi_debug_case.sh`
  Shared helpers used by the `scsi_debug` experiment scripts.

- `funcVer/`
  Functional validation cases for the BC-EH reset-handler combinations,
  including device, target, bus, host, combined-scope, and no-handler cases.

- `basictopo/`
  Topology A in the paper, i.e., the no-sibling topology used for Figure 10.
  It contains P1-P9 cases with separate `linux-eh/` and `bc-eh/`
  subdirectories.

- `complextopo/`
  Topology B in the paper, i.e., the sibling-enabled topology used for
  Figure 10. It contains P1-P9 cases with separate `linux-eh/` and `bc-eh/`
  subdirectories.

- `sequence_cases/`
  Ordered multi-fault sequence cases that compare Linux EH and BC-EH behavior
  under staggered independent device faults.

- `checkpoint_perf/`
  Checkpoint scanning overhead and convergence microbenchmarks.

- `fpl_perf_quick/`
  Short FPL hot-path overhead runs for quick validation.

- `fpl_perf_real/`
  Full FPL hot-path overhead matrix used for longer measurements.

- `kafka_jbod/`
  Kafka JBOD setup, cleanup, layout validation, workload, and fault-injection
  scripts using `scsi_debug`-backed data disks.

<br>

## 2. Requirements

For QEMU/KVM deployments, the host machine should provide:

- Linux with KVM support enabled.
- `qemu-system-x86_64`, `make`, `ssh`, and standard networking tools from
  `iproute2`.
- Enough memory for the selected QEMU/KVM target. The Kafka QEMU/KVM setup
  starts three 8 GiB broker VMs and one 4 GiB client VM.
- For the iSCSI experiment, the host additionally needs `targetcli` and root
  permission to create the `br-iscsi` bridge, the `tap-iscsi0` tap device, and
  the Linux LIO file-backed target. The setup scripts also use the standard
  `ip` and `ss` commands from `iproute2`.
- The evaluator should choose an unused private host-guest IP address and pass
  it as `BC_EH_ISCSI_PORTAL_IP`; the scripts assign
  `${BC_EH_ISCSI_PORTAL_IP}/24` to `br-iscsi`. The tap name `tap-iscsi0` and
  TCP port `3260` should not already be in use.
- The QEMU process that starts `make iscsi` must have permission to attach to
  `tap-iscsi0`.

<br>

## 3. Prepare Runtime Environments

### 3.1 Prepare a Base Linux System

Prepare Ubuntu 20.04.6 LTS or a compatible Linux system for each experiment node. Ubuntu 20.04.6 LTS images are available from the official Ubuntu releases page: https://releases.ubuntu.com/20.04/. For a QEMU/KVM deployment, we recommend starting from an installer ISO: create a qcow2 system disk first, then install Ubuntu into it. For a physical-machine deployment, prepare clean machines in
the same way.

Install the common tools needed by the artifact, including kernel build dependencies, QEMU utilities if VMs are used, `fio`, `open-iscsi`, `targetcli-fb`, and Java. Kafka is only needed for the Kafka JBOD experiment.

For the Kafka JBOD experiment, Apache Kafka 4.2.0 is required on all Kafka nodes: `kafka-1`, `kafka-2`, `kafka-3`, and `kafka-client`. The artifact scripts assume the Kafka directory is `/root/kafka_2.13-4.2.0`; keep this path when installing Kafka, or update the Kafka script variables consistently if a different path is used. In a QEMU/KVM deployment, if the Kafka broker/client images are derived from the same prepared base image, installing Kafka in that base image avoids repeating the installation in each Kafka image.

Kafka installation references:
- Apache Kafka downloads: https://kafka.apache.org/downloads
- Apache Kafka quick start: https://kafka.apache.org/quickstart

The commands below assume that the evaluator logs into the experiment nodes as `root` and places the extracted artifact directory under the
root home directory, for example `/root/2004-BC-EH-Artifact-Evaluation`. If a different user or path is used, replace the `~/2004-BC-EH-Artifact-Evaluation` paths consistently in the commands.

<br>

### 3.2 Build and Install the BC-EH Kernel

Nodes that run the BC-EH SCSI experiments must boot the BC-EH kernel before executing the artifact scripts. The `atclinux/` directory already includes the intended `.config` file. For QEMU/KVM deployments, build and install the kernel inside the base VM image used for the scsi_debug, iSCSI initiator, and Kafka broker nodes. For physical-machine deployments, install the kernel on the corresponding experiment machines, and re-check machine-specific options such as the boot disk, network adapter, filesystem, and storage-controller drivers.

For kernel build and installation guidance, refer to the upstream Linux kernel build/install guide:
https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/admin-guide/quickly-build-trimmed-linux.rst

Run the following commands on each node that requires the BC-EH kernel, or on the corresponding base VM image:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/atclinux

# Optional: run only if the kernel tree asks for new config options.
# make olddefconfig

# Build the kernel image and modules with a stable AE-local kernel release.
make LOCALVERSION=-bceh -j"$(nproc)"

# Install the modules and kernel image.
sudo make LOCALVERSION=-bceh modules_install
sudo make LOCALVERSION=-bceh install

# Make GRUB boot the installed BC-EH kernel by default.
# Check the exact GRUB menu entry first; adjust GRUB_DEFAULT if the menu name differs.
sudo grep -n "menuentry 'Ubuntu, with Linux 6.18.0-bceh" /boot/grub/grub.cfg
sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.18.0-bceh"|' /etc/default/grub
sudo update-grub

# Reboot the node.
sudo reboot
```

After rebooting, check the running kernel and the `scsi_debug` module:

```bash
uname -r
sudo modprobe scsi_debug
lsmod | grep scsi_debug
sudo modprobe -r scsi_debug
```

The expected `uname -r` output is:

```bash
6.18.0-bceh
```

After `modprobe scsi_debug` succeeds, the test scripts under
`bc_eh_test/scsi_debug/` can be executed. Linux EH and BC-EH are selected
through the `eh_mode` interface in the same BC-EH kernel; two separate kernels
are not required.

<br>

### 3.3 Create QEMU/KVM Runtime Images

This step is only needed for QEMU/KVM deployments. Starting from the prepared base image, create one qcow2 image for the standalone `scsi_debug` and `iscsi_tcp` experiments, and four qcow2 images for the Kafka JBOD experiment:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation

qemu-img create -f qcow2 -F qcow2 -b ubuntu20046_x86_64.img iscsi.qcow2
qemu-img create -f qcow2 -F qcow2 -b ubuntu20046_x86_64.img kafka1-os.qcow2
qemu-img create -f qcow2 -F qcow2 -b ubuntu20046_x86_64.img kafka2-os.qcow2
qemu-img create -f qcow2 -F qcow2 -b ubuntu20046_x86_64.img kafka3-os.qcow2
qemu-img create -f qcow2 -F qcow2 -b ubuntu20046_x86_64.img kafka-client-os.qcow2
```

The provided `Makefile` expects these image names in the artifact root directory. If the image names or paths are changed, update the corresponding `-drive file=...` entries in `Makefile`.

After creating the images, one convenient QEMU/KVM layout is:

```bash
2004-BC-EH-Artifact-Evaluation/
├── atclinux/
├── bc_eh_test/
├── Makefile
├── README.md
├── ubuntu20046_x86_64.img     # QEMU/KVM only: prepared base image
├── iscsi.qcow2                # QEMU/KVM only: scsi_debug/iSCSI test VM   
├── kafka1-os.qcow2            # QEMU/KVM only: Kafka broker 1
├── kafka2-os.qcow2            # QEMU/KVM only: Kafka broker 2
├── kafka3-os.qcow2            # QEMU/KVM only: Kafka broker 3
└── kafka-client-os.qcow2      # QEMU/KVM only: Kafka workload client
```

Physical-machine deployments can prepare the corresponding machines directly.

<br>

### 3.4 Prepare the scsi_debug Test Node

The `scsi_debug` test node is used for the standalone `scsi_debug` functional, recovery-latency, checkpoint, and FPL experiments. The node
must have the artifact repository, the BC-EH kernel, `fio`, and a loadable `scsi_debug` kernel module.

For QEMU/KVM deployments, this node can use `iscsi.qcow2`. The provided `Makefile` starts this VM with the `make iscsi` target, exposes SSH through the QEMU user-mode management network on host port `2210`, and attaches the `tap-iscsi0` interface. Create `tap-iscsi0` with the host-side network setup in `Prepare the iSCSI Experiment Environment` before starting this target:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation
make iscsi
ssh -p 2210 root@127.0.0.1
```

For physical-machine deployments, prepare one machine with the same software environment.

Check the node before running the `scsi_debug` experiment scripts:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation

uname -r
fio --version

sudo modprobe scsi_debug
lsmod | grep scsi_debug
sudo modprobe -r scsi_debug
```

The expected kernel release is:

```bash
6.18.0-bceh
```

After these checks pass, the node is ready for the scripts under `bc_eh_test/scsi_debug/`.

<br>

### 3.5 Prepare the iSCSI Experiment Environment

The iSCSI experiment uses two roles: a host-side Linux LIO target and an initiator node running the BC-EH kernel. For QEMU/KVM deployments, the initiator node is `iscsi.qcow2`, started by the `make iscsi` target in the provided `Makefile`. In this QEMU/KVM setup, the initiator VM connects to the host-side target through the `tap-iscsi0` interface.

On the target side, install `targetcli-fb` and choose an unused private host-guest portal address. Use the same `BC_EH_ISCSI_PORTAL_IP`
value on the target side and inside the initiator node. The setup scripts create the host-side bridge/tap network and the file-backed iSCSI
target used by the experiment.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation

export BC_EH_ISCSI_PORTAL_IP=<host-private-ip>

sudo bash bc_eh_test/LLDD/iscsi_tcp/destroy_host.sh
sudo bash bc_eh_test/LLDD/iscsi_tcp/net_cleanup.sh

sudo -E bash bc_eh_test/LLDD/iscsi_tcp/net_ready.sh
sudo -E bash bc_eh_test/LLDD/iscsi_tcp/create_host.sh
```

For QEMU/KVM deployments, start the initiator VM after the target side is ready:

```bash
sudo make iscsi
ssh -p 2210 root@127.0.0.1
```

Inside the initiator node, install `open-iscsi`, boot the BC-EH kernel, keep the artifact repository available, and use the same
`BC_EH_ISCSI_PORTAL_IP` value when running the iSCSI scripts.

For physical-machine deployments, prepare one target machine and one initiator machine with the same software roles. The expected target and
initiator state is described in the `Expected iSCSI Setup State` section below.

#### 3.5.1 Expected iSCSI Setup State

The iSCSI target uses file-backed LUNs on the host; it does not require a
physical disk or a hardware storage controller.

After `net_ready.sh` and `create_host.sh` complete on the host, the host should
have:

```bash
host network:   br-iscsi up, with <host-private-ip>/24 assigned
tap device:     tap-iscsi0 attached to br-iscsi
target IQN:     iqn.2026-06.com.bc-eh:target0
initiator IQN:  iqn.2026-06.com.bc-eh:iscsi-vm
portal:         <host-private-ip>:3260
backstore type: targetcli fileio
LUN 0:          /var/lib/bc-eh-iscsi/lun0.img, 4 GiB
LUN 1:          /var/lib/bc-eh-iscsi/lun1.img, 4 GiB
```

Useful host-side checks are:

```bash
ip -4 addr show br-iscsi
ip link show tap-iscsi0
sudo targetcli /iscsi/iqn.2026-06.com.bc-eh:target0/tpg1 ls
sudo ls -lh /var/lib/bc-eh-iscsi/lun*.img
```

Inside the initiator node, use the same portal IP. The optional connectivity check
below logs in to the target and should show one `iscsi_tcp` host plus two iSCSI
LUNs:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/LLDD/iscsi_tcp

export BC_EH_ISCSI_PORTAL_IP=<host-private-ip>

sudo -E sh guest_connect.sh
iscsiadm -m session
ls -l /dev/disk/by-path | grep iscsi
```

The expected result is that `guest_connect.sh` exits successfully,
`iscsiadm -m session` shows a session to
`iqn.2026-06.com.bc-eh:target0` at `<host-private-ip>:3260`, and
`/dev/disk/by-path` contains two iSCSI LUN links:

```bash
ip-<host-private-ip>:3260-iscsi-iqn.2026-06.com.bc-eh:target0-lun-0
ip-<host-private-ip>:3260-iscsi-iqn.2026-06.com.bc-eh:target0-lun-1
```
<br>

### 3.6 Prepare the Kafka JBOD Environment

The Kafka JBOD experiment uses three broker nodes and one workload client node. For QEMU/KVM deployments, the provided `Makefile` uses
`kafka1-os.qcow2`, `kafka2-os.qcow2`, `kafka3-os.qcow2`, and `kafka-client-os.qcow2`, and starts them with the `make kafka` target.

Each Kafka broker node must boot the BC-EH kernel, keep the artifact repository available, have Java and Kafka installed at `/root/kafka_2.13-4.2.0`, and be able to load the `scsi_debug` module. The workload client node must also have Java, Kafka installed at `/root/kafka_2.13-4.2.0`, and the artifact repository available.

The default QEMU/KVM Kafka topology uses a management network for SSH and a separate cluster network for Kafka traffic. The Kafka scripts
assume the cluster interface is `enp0s3` by default, with the following addresses:

```bash
kafka-1:       10.20.0.11/24
kafka-2:       10.20.0.12/24
kafka-3:       10.20.0.13/24
kafka-client:  10.20.0.21/24
```

For QEMU/KVM deployments, start the Kafka nodes from the artifact root:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation
make kafka
```

The `Makefile` exposes SSH on the following host ports:

```bash
kafka-1:       ssh -p 2201 root@127.0.0.1
kafka-2:       ssh -p 2202 root@127.0.0.1
kafka-3:       ssh -p 2203 root@127.0.0.1
kafka-client:  ssh -p 2204 root@127.0.0.1
```

After logging into each Kafka node, check the expected runtime components:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation

ip -4 addr show enp0s3
/root/kafka_2.13-4.2.0/bin/kafka-storage.sh version
```

On each broker node, also check the BC-EH kernel and `scsi_debug` module:

```bash
uname -r
sudo modprobe scsi_debug
lsmod | grep scsi_debug
sudo modprobe -r scsi_debug
```

For physical-machine deployments, prepare three broker machines and one workload client machine with the same software roles and cluster-network addresses. The Kafka baseline setup, topic preparation, workload execution, and fault injection are described later in the `Run Kafka JBOD Experiments` section.

<br>

## 4. Run a Smoke Test

This section assumes that the runtime environments have already been prepared as described above. The shortest sanity check is to run one `scsi_debug` case on the prepared `scsi_debug` test node.

For QEMU/KVM deployments, log into the `iscsi.qcow2` node as described in `Prepare the scsi_debug Test Node`. For physical-machine deployments, run the same commands on the prepared `scsi_debug` machine.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug

uname -r
sudo sh basictopo/bc-eh/scsi_debug_P1_basictopo.sh
```

The expected kernel release is:

```bash
6.18.0-bceh
```

This single `basictopo` case is intended only as a quick sanity check. Broader test suites are listed in the experiment sections below. The foreground output mainly comes from `fio`; opening another terminal and watching `dmesg` can make the recovery progress easier to observe.

<br>

## 5. Run scsi_debug Experiments

Run the `scsi_debug` experiments on the prepared `scsi_debug` test node from the artifact directory. The experiments are exposed as 
separate entries so that each paper-mapped experiment can be run and inspected independently.

<br>

### 5.1 Functional Validation

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug
sudo sh funcVer/run_all.sh
```

These cases are functional tests for BC-EH recovery-state transitions and
reset-handler combinations. They do not correspond to a plotted result in the
paper.

<br>

### 5.2 Recovery Latency

This experiment corresponds to Figure 10 in the paper. It compares SCSI EH and
BC-EH recovery latency across Topology A (no siblings) and Topology B (with
siblings) for P1-P9.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug
sudo sh basictopo/run_all.sh
sudo sh complextopo/run_all.sh
```

Here `basictopo/` corresponds to Topology A, and `complextopo/` corresponds to
Topology B. Each directory contains both `linux-eh/` and `bc-eh/` cases for
P1-P9.

These scripts record per-case metadata under `/tmp/bc_eh_test/scsi_debug/`.
The recovery-latency values used for Figure 10 are extracted from the kernel
log.

<br>

### 5.3 Multi-Fault Sequence Cases

This experiment corresponds to Figure 11 in the paper. It evaluates the
worst-case multi-fault convoy recovery latency under 8 independent sdev-local
faults in `scsi_debug`, with both Linux EH and BC-EH cases.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug
sudo sh sequence_cases/linux-eh/scsi_debug_staggered_independent_sdev_convoy_8targets.sh
sudo sh sequence_cases/bc-eh/scsi_debug_staggered_independent_sdev_convoy_8targets.sh
```

The recovery-latency values used for Figure 11 are extracted from the kernel
log.

<br>

### 5.4 Checkpoint Traversal Overhead

This experiment corresponds to the checkpoint traversal overhead reported in
Section 4.2.3, Overhead Characterization. It measures the checkpoint traversal
cost on an extended `scsi_debug` topology and reports median/p95 latency per
checkpoint invocation and per visited node.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/checkpoint_perf
sudo sh run_matrix.sh
```

The script writes the summary and raw results to:

```bash
bc_eh_test/scsi_debug/checkpoint_perf/checkpoint_summary.md
bc_eh_test/scsi_debug/checkpoint_perf/checkpoint_raw_results.csv
```

<br>

### 5.5 FPL Hot-Path Overhead

This experiment corresponds to the steady-state FPL accounting overhead
reported in Section 4.2.3, Overhead Characterization, and plotted in Figure 12.
It runs the full matrix across Linux EH and BC-EH, 1/2/4/8/16 active sdevs,
randread/randwrite workloads, and 4 KiB to 256 KiB block sizes.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/fpl_perf_real
sudo sh run_fpl_hotpath_real_matrix.sh
```

The full FPL matrix writes raw results to:

```bash
bc_eh_test/scsi_debug/fpl_perf_real/fpl_raw_results.csv
```

For a shorter smoke run of the same matrix structure, use:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/fpl_perf_quick
sudo sh run_fpl_hotpath_matrix.sh
```

<br>

## 6. Run iSCSI Experiments

Run the iSCSI experiments on the prepared initiator node after the target side has been prepared and verified as described above.

<br>

### 6.1 Paper-Mapped iSCSI Case

The iSCSI results in Figure 13 and Table 7 come from `iscsi_tcp/P1`. Figure 13
uses the healthy-sibling `fio` throughput timeline from the P1 runs, and Table
7 reports the fault-object recovery latency (`T_eh`) extracted from the kernel
log of the same P1 runs.

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/LLDD/iscsi_tcp

export BC_EH_ISCSI_PORTAL_IP=<host-private-ip>

sudo -E sh linux-eh/iscsi_tcp_P1.sh
sudo -E sh bc-eh/iscsi_tcp_P1.sh
```

Each run prints a `RESULT` line with its output directory. The output directory
is under:

```bash
/tmp/bc_eh_test/iscsi_tcp/<linux-eh|bc-eh>/P1/<timestamp>/
```

The directory contains `metadata`, `dmesg_follow.log`, `dmesg_after.log`,
`fault_fio.stdout`, `healthy_fio.stdout`, and the `fio` bandwidth/IOPS logs
used for the healthy-sibling throughput timeline.

For Figure 13, use the healthy-sibling `fio` timeline from the P1 output
directory: `healthy_fio.stdout` plus the generated `healthy_bw*.log` and
`healthy_iops*.log` files. The `inject_epoch` field in `metadata` marks the
fault-injection point used as `t = 0`. For Table 7's iSCSI entry, use the
kernel recovery timeline from `dmesg_follow.log` or `dmesg_after.log` in the
same P1 output directory to extract the fault-object recovery latency
(`T_eh`).

<br>

## 7. Run Kafka JBOD Experiments

For QEMU/KVM deployments, start the Kafka nodes from the host:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation
make kafka
```

For physical-machine deployments, replace the QEMU/KVM SSH forwarding commands
with direct SSH access to the corresponding machines.

Then log into each broker node and prepare its local `scsi_debug`-backed data disks:

```bash
ssh -p 2201 root@127.0.0.1
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/kafka_jbod
sudo bash setup_kafka_jbod_baseline.sh
```

For QEMU/KVM deployments, repeat the same setup on `kafka-2` and `kafka-3`
using ports `2202` and `2203`. For physical-machine deployments, run the same
setup on the corresponding broker machines.

After all three broker setup scripts finish, run the basic Kafka cluster
validation on one broker node, for example `kafka-1`:

```bash
ssh -p 2201 root@127.0.0.1
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/kafka_jbod

sudo bash basic_validation/run_basic_validation.sh
```

Then select exactly one formal topic layout wrapper for the experiment round.
Run one of the following on one broker node, normally `kafka-1`:

```bash
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/kafka_jbod

# Default layout sanity check.
sudo bash formal_topic/default_layout/run_formal_topic_layout_check.sh

# Fixed layout used by the paper's 10/6 and 16/6 Kafka cases.
sudo bash formal_topic/fixed_6_16/run_fixed_6_16_layout.sh

# Fixed layout used by the paper's 12/4 Kafka case.
sudo bash formal_topic/leader_tilt_12_4/run_leader_tilt_12_4_layout.sh
```

The Kafka figure in the paper contains six panels: three Kafka fault/layout
cases, each run once with Linux EH and once with BC-EH. Treat each row below
as one experiment round: apply the listed layout on `kafka-1`, start the
pinned producer workload on `kafka-client`, then run only that row's
fault-injection entry on `kafka-1`.

| Paper panel | Formal topic layout | Fault-injection entry on `kafka-1` |
| --- | --- | --- |
| `offline_10_6_fixed`, Linux EH | `formal_topic/fixed_6_16/run_fixed_6_16_layout.sh` | `fault_injection/linux-eh/run_single_disk_offline_case.sh` |
| `offline_10_6_fixed`, BC-EH | `formal_topic/fixed_6_16/run_fixed_6_16_layout.sh` | `fault_injection/bc-eh/run_single_disk_offline_case.sh` |
| `offline_12_4_fixed`, Linux EH | `formal_topic/leader_tilt_12_4/run_leader_tilt_12_4_layout.sh` | `fault_injection/linux-eh/run_single_disk_offline_case.sh` |
| `offline_12_4_fixed`, BC-EH | `formal_topic/leader_tilt_12_4/run_leader_tilt_12_4_layout.sh` | `fault_injection/bc-eh/run_single_disk_offline_case.sh` |
| `recoverable_16_6_fixed`, Linux EH | `formal_topic/fixed_6_16/run_fixed_6_16_layout.sh` | `fault_injection/linux-eh/run_single_disk_recoverable_stall_case.sh` |
| `recoverable_16_6_fixed`, BC-EH | `formal_topic/fixed_6_16/run_fixed_6_16_layout.sh` | `fault_injection/bc-eh/run_single_disk_recoverable_stall_case.sh` |

The `default_layout` wrapper is useful for a default-layout sanity check, but
the paper's six fixed-layout Kafka panels use `fixed_6_16` and
`leader_tilt_12_4`.

For the selected round, use the client node for the producer workload:

```bash
ssh -p 2204 root@127.0.0.1
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/kafka_jbod

sudo bash workload/run_formal_pinned_partition_workload.sh
```

Then run the selected fault-injection entry from the table on `kafka-1`. For
example:

```bash
ssh -p 2201 root@127.0.0.1
cd ~/2004-BC-EH-Artifact-Evaluation/bc_eh_test/scsi_debug/kafka_jbod

# Linux EH offline round.
sudo bash fault_injection/linux-eh/run_single_disk_offline_case.sh
```

Use the Linux EH entries for Linux baseline rounds and the BC-EH entries for
BC-EH rounds. The offline case does not auto-recover the faulted disk; rerun
the broker setup before the next Kafka round. The recoverable-stall case is a
separate round and should be run only when that row is selected.

Kafka outputs are split across the client node and the fault-injection broker
node. On `kafka-client`, the producer workload writes the throughput timeline
and per-partition summaries to:

```bash
bc_eh_test/scsi_debug/kafka_jbod/workload/output/
```

Important files include:

```bash
jbod-hot.formal_pinned_partition_workload.stdout.timestamped.log
jbod-hot.formal_pinned_partition_workload.report_time.csv
jbod-hot.formal_pinned_partition_workload.worker_summary.csv
jbod-hot.formal_pinned_partition_workload.meta.txt
```

On `kafka-1`, each fault-injection run writes one timestamped output
directory under:

```bash
bc_eh_test/scsi_debug/kafka_jbod/fault_injection/output/
```

The directory name has the form:

```bash
<timestamp>.<single_disk_offline|single_disk_recoverable_stall>.<linux-eh|bc-eh>.<host|sdev>/
```

Important files include:

```bash
run.meta.txt
dmesg.txt
pre_fault/
inject_armed/ or fault_start/
post_fault_settled/ or recovered_observed/
broker_logs/
```

The Kafka panels are derived by combining the producer timeline from
`kafka-client` with the fault-injection metadata, kernel log, Kafka topic
snapshots, and broker logs collected on `kafka-1`.

The detailed Kafka JBOD guide is
`bc_eh_test/scsi_debug/kafka_jbod/README.md`.

<br>

## 8. Kernel Source Overview

BC-EH is implemented on top of Linux v6.18
(base commit: 7d0a66e4bb9081d75c82ec4957c50034cb0ea449).

The AE-relevant kernel changes are concentrated in the SCSI mid-layer, the
`scsi_debug` virtual device, and the `iscsi_tcp` software initiator path.
Hardware-specific `mpt3sas` and `megaraid_sas` changes are not considered in
this AE artifact path because they require specific SAS HBA/RAID controllers.

Compared with the Linux v6.18 base commit, the AE-relevant modified source files
are:

SCSI error-handling core and shared SCSI infrastructure:

- `drivers/scsi/Kconfig`
  Adds `CONFIG_SCSI_BC_EH_LOG`, a build-time switch for verbose BC-EH logs.
  This keeps experiment tracing available while allowing logging to be compiled
  out for low-interference performance runs.

- `drivers/scsi/hosts.c`
  Initializes BC-EH per-host lists, mode state, and workqueues for checkpoint,
  reset, and debug workers. It also flushes and destroys those workqueues during
  host teardown.

- `drivers/scsi/scsi_error.c`
  Contains the main BC-EH recovery logic, including fault admission, boundary
  closure, pending-fault handling, checkpointing, scoped reset, and scoped
  offline decisions. When `eh_mode=sdev` is selected, this is the main BC-EH
  orchestration path; it reuses existing LLDD recovery callbacks while changing
  fault-boundary inference, scheduling, and recovery scope.

- `drivers/scsi/scsi_lib.c`
  Adds forward-progress accounting on command submission/completion and routes
  failed commands into BC-EH when the host is in `sdev` mode. This provides
  runtime forward-progress evidence used by BC-EH for fault-boundary inference.

- `drivers/scsi/scsi_logging.h`
  Adds BC-EH logging macros guarded by `CONFIG_SCSI_BC_EH_LOG`. The purpose is
  to make experiment logs explicit without forcing log overhead into all runs.

- `drivers/scsi/scsi_priv.h`
  Declares BC-EH internal entry points, worker functions, and forward-progress
  constants shared across the SCSI core. These declarations connect the
  completion path, sysfs mode control, scan-time initialization, and EH workers.

- `drivers/scsi/scsi_scan.c`
  Builds the explicit `host -> channel -> target -> device` topology used by
  BC-EH and initializes per-device EH state. This lets BC-EH reason about fault
  boundaries below the host level.

- `drivers/scsi/scsi_sysfs.c`
  Adds the host `eh_mode` sysfs attribute for switching between Linux-EH
  `host` mode and BC-EH `sdev` mode. It also cancels outstanding BC-EH state
  when a SCSI device is removed.

- `include/scsi/scsi_cmnd.h`
  Adds a command submitter tag for commands issued by the new SCSI error
  handler. This allows validation commands, such as EH-issued TURs, to be
  distinguished from normal I/O.

- `include/scsi/scsi_device.h`
  Adds BC-EH state enums, per-device and per-target recovery metadata, the
  `scsi_channel` topology object, and forward-progress estimator state. These
  fields hold the persistent state needed for localized recovery.

- `include/scsi/scsi_eh.h`
  Adds the checkpoint benchmark configuration/result structures and exported
  runner prototype. This supports the synthetic checkpoint scanning benchmark
  used with `scsi_debug`.

- `include/scsi/scsi_host.h`
  Adds the BC-EH host mode, work-sequence state, per-host BC-EH queues, the
  LLDD offline-confirmation hook, and an optional forward-progress timeout
  hint. These fields provide the host-level scheduler, coordination state, and
  driver contract used by BC-EH.

`scsi_debug` fault injection and synthetic validation support:

- `drivers/scsi/scsi_debug.c`
  Extends `scsi_debug` with configurable topology, reset-failure injection,
  post-reset validation failure/timeout injection, and checkpoint benchmark
  debugfs controls. This provides a deterministic software device for the
  AE functional and synthetic experiments.

`iscsi_tcp` experiment support:

- `drivers/scsi/iscsi_tcp.c`
  Registers an `iscsi_tcp` offline-handler hook in the SCSI host template so
  the BC-EH core interface is present for this software initiator. In this AE
  path the handler is only a minimal stub; the iSCSI experiments mainly rely on
  the controlled fault-injection logic in `libiscsi.c`.

- `drivers/scsi/libiscsi.c`
  Adds iSCSI experiment controls such as `bc_iscsi_test_mode`, `bc_iscsi_fault_active`, and `bc_iscsi_hold_tur`, plus completion-drop  
  and fake-reset behavior used by the P1 iSCSI case. This makes the iSCSI fault path reproducible on the prepared iSCSI initiator node
  without relying on uncontrolled external target failures.
<br>

## 9. Artifact Scope and Limitations

This AE package focuses on the software-reproducible artifact path:

- BC-EH SCSI mid-layer changes.
- `scsi_debug` functional, recovery-latency, checkpoint, and FPL experiments.
- `iscsi_tcp` software initiator experiments.
- Kafka JBOD experiments built on `scsi_debug`-backed data disks.

The paper also evaluates hardware-dependent paths involving `mpt3sas` and
`megaraid_sas` with specific SAS HBA/RAID controllers. Those hardware-driver
paths are not part of this AE package because they require local controller
hardware that cannot be assumed for evaluators.

<br>
