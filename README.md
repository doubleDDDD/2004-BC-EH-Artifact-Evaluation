# 2004-BC-EH-Artifact-Evaluation

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
  Adds iSCSI experiment controls such as `bc_iscsi_test_mode`,
  `bc_iscsi_fault_active`, and `bc_iscsi_hold_tur`, plus completion-drop and
  fake-reset behavior for P1/P5-style cases. This makes the iSCSI fault path
  reproducible inside the Ubuntu guest without relying on uncontrolled external
  target failures.



裸金属免责，要考虑自己的必要启动设备

# TODO list
1. 明确镜像版本，是否需要重新统一内核版本
2. 把 5 个镜像彻底准备利索，脚本的位置要调整好
3. 思考镜像内部的git，是否要清理
4. 镜像内部搞不好要删东西哦，但也不一定，也不是必须移除

ssh -p 2201 zc@127.0.0.1   # kafka-1
ssh -p 2202 zc@127.0.0.1   # kafka-2
ssh -p 2203 zc@127.0.0.1   # kafka-3
ssh -p 2204 zc@127.0.0.1   # kafka-client
ssh -p 2210 zc@127.0.0.1   # iscsi-vm



```bash
doubled@super:~/workspace/githublinux/linux$ git log
commit 907b8a9cda01436bdd35e0d8461bbbc1f718a713 (HEAD -> b618, origin/b618)
Author: doubled <18374822143@163.com>
Date:   Tue Jun 9 00:24:55 2026 +0800

    update

    Signed-off-by: doubled <18374822143@163.com>
```

### 第一件事我得先统一一下镜像
make iscsi
ssh -p 2210 zc@127.0.0.1
```bash
commit ec4a05fd3880745be9dfd13782827bd491ddf292 (HEAD -> b618, origin/b618)
Author: doubled <18374822143@163.com>
Date:   Mon Jun 8 22:45:32 2026 +0800

    update

    Signed-off-by: doubled <18374822143@163.com>

Linux kafka-client 6.18.0-00087-gec4a05fd3880 #657 SMP PREEMPT_DYNAMIC Mon Jun  8 22:52:14 CST 2026 x86_64 x86_64 x86_64 GNU/Linux
```
make kafka1
ssh -p 2201 zc@127.0.0.1
```bash
commit a8263b8d30fe5b888976ac371c20fd9d1f5856ba (HEAD -> b618, origin/b618)
Author: Dongdong Hao <doubled@leap-io-kernel.com>
Date:   Wed May 20 19:31:54 2026 +0800

    update

5.4.0-216-generic  6.18.0-00066-gbb7b31dc685a  6.18.0-00067-ga8263b8d30fe

Linux kafka-1 6.18.0-00067-ga8263b8d30fe #643 SMP PREEMPT_DYNAMIC Wed May 20 19:34:37 CST 2026 x86_64 x86_64 x86_64 GNU/Linux
```

make kafka2
ssh -p 2202 zc@127.0.0.1
```bash
commit a8263b8d30fe5b888976ac371c20fd9d1f5856ba (HEAD -> b618, origin/b618)
Author: Dongdong Hao <doubled@leap-io-kernel.com>
Date:   Wed May 20 19:31:54 2026 +0800

    update

Linux kafka-2 6.18.0-00067-ga8263b8d30fe #643 SMP PREEMPT_DYNAMIC Wed May 20 19:34:38 CST 2026 x86_64 x86_64 x86_64 GNU/Linux
```

make kafka3
ssh -p 2203 zc@127.0.0.1
```bash
commit a8263b8d30fe5b888976ac371c20fd9d1f5856ba (HEAD -> b618, origin/b618)
Author: Dongdong Hao <doubled@leap-io-kernel.com>
Date:   Wed May 20 19:31:54 2026 +0800

    update

Linux kafka-3 6.18.0-00067-ga8263b8d30fe #643 SMP PREEMPT_DYNAMIC Wed May 20 19:34:40 CST 2026 x86_64 x86_64 x86_64 GNU/Linux
```

make kafka-client
ssh -p 2204 zc@127.0.0.1
```bash
commit a8263b8d30fe5b888976ac371c20fd9d1f5856ba (HEAD -> b618, origin/b618)
Author: Dongdong Hao <doubled@leap-io-kernel.com>
Date:   Wed May 20 19:31:54 2026 +0800

    update

Linux kafka-client 6.18.0-00067-ga8263b8d30fe #643 SMP PREEMPT_DYNAMIC Wed May 20 19:34:37 CST 2026 x86_64 x86_64 x86_64 GNU/Linux
```





```bash
                 BC-EH Artifact
                       │
          Linux source + bc_eh_test
                       │
          ┌────────────┴────────────┐
          │                         │
       QEMU/VM                  Bare Metal
          │                         │
  scsi_debug / iscsi_tcp       BC-EH kernel
  Kafka JBOD                   overhead tests
          │                         │
  EH behavior/latency          hot-path overhead
```

论文完整 evaluation 包含 mpt3sas / megaraid_sas 对应的真实 HBA/RAID 控制器和磁盘，而这些硬件环境无法提供给 AE evaluator，因此无法满足完整的 Reproduced 要求。



本代码包以 `atclinux/` 为主目录，主要包含两部分内容：

- `atclinux/`：基于 Linux 6.18.0 的内核代码目录，包含本人在块层 / SCSI / error handling 相关方向上的代码修改。
- `atclinux/bc_eh_test/`：与上述代码修改配套的测试与验证目录。

## 1. atclinux

`atclinux/` 是本次交付的主体代码目录。它不是单纯的原始内核源码，而是基于 Linux 6.18.0 继续开发后的代码树，里面保留了本次实验和开发过程中实际使用的代码修改。

这个目录主要用于：

- 保存修改后的内核代码。
- 编译内核和相关模块。
- 生成测试所需的内核产物。
- 配合 `bc_eh_test/` 完成启动、调试和验证。

目录中可直接用于验证的典型产物包括：

- `.config`
- `vmlinux`
- `System.map`
- `Module.symvers`
- `arch/x86/boot/bzImage`

如果需要继续开发、复现或检查代码修改，主要就在 `atclinux/` 下进行。

## 2. bc_eh_test

`bc_eh_test/` 是配套测试目录，用来围绕 `atclinux/` 中的代码修改做环境构建、模块装载、虚拟机启动和测试执行。

它的主要作用包括：

- 启动 QEMU 调试环境。
- 生成测试用 initramfs。
- 将编译出的内核模块拷贝进测试镜像。
- 搭建 HBA 透传、iSCSI、MegaRAID、mpt3sas、Kafka JBOD 等测试场景。
- 在最小化用户态环境中执行功能测试和性能测试。

目录内几个核心文件/子目录如下：

- `Makefile`
  - 提供统一的测试入口。
  - 可用于启动基础调试环境、HBA 透传环境、iSCSI 场景、MegaRAID 场景、mpt3sas 场景以及 Kafka JBOD 场景。
  - 也可用于生成 `manual_ramdisk.img` 和 `auto_ramdisk.img`。

- `cpmodule.sh`
  - 用于把当前编译得到的模块复制到测试 ramdisk 中。
  - 当前脚本会复制 `scsi_debug.ko`、`crc-t10dif.ko`、`mpt3sas.ko`、`megaraid_sas.ko`。

- `build_ramdisk/`
  - 手工构建 ramdisk 的目录。
  - 包含 `manual_ramdisk.img` 和 `initrmfs/` 根文件系统模板。

- `auto_ramdisk.img`
  - 自动生成的 initramfs 镜像。

### 2.1 主要测试场景说明

`bc_eh_test/Makefile` 中定义了几类主要测试场景：

- `HBA` 透传场景
  - 通过 VFIO 将宿主机上的 PCIe HBA 设备直接透传给 QEMU 虚拟机。
  - 主要用于验证真实 HBA 硬件条件下的驱动行为、中断/IOMMU 配置以及 error handling 路径。
  - 对应入口主要是 `make dhba`。

- `iSCSI` 场景
  - 启动带独立系统盘的测试虚拟机，并通过单独的测试网络连接 iSCSI 环境。
  - 主要用于验证 `iscsi_tcp` 相关场景下的发现、连接、异常注入和恢复行为。
  - 对应入口主要是 `make iscsi`。

- `MegaRAID` 场景
  - 在测试虚拟机中透传 MegaRAID 控制器，验证 MegaRAID 驱动及其 error handling 行为。
  - 主要用于 `megaraid` 相关测试脚本的复现和对比。
  - 对应入口主要是 `make mega`。
  - 除虚拟机系统镜像外，该场景还依赖宿主机存在可透传的对应控制器，以及 VFIO、IOMMU、KVM 等宿主机透传条件。

- `mpt3sas` 场景
  - 在测试虚拟机中透传 mpt3sas 控制器，验证 mpt3sas 驱动及其 error handling 行为。
  - 主要用于 `mpt3sas` 相关测试脚本的复现和对比。
  - 对应入口主要是 `make mpt3sas`。
  - 除虚拟机系统镜像外，该场景还依赖宿主机存在可透传的对应控制器，以及 VFIO、IOMMU、KVM 等宿主机透传条件。

- `Kafka JBOD` 场景
  - 同时启动 3 个 Kafka broker 虚拟机和 1 个 client 虚拟机，构造多盘、多节点的 JBOD 使用环境。
  - 主要用于验证论文和实验中与多盘持续 I/O、故障注入、恢复过程和业务前向进展相关的场景。
  - 对应入口主要是 `make kafka`、`make kafka1`、`make kafka2`、`make kafka3`、`make kafka-client`。

需要单独说明的是，上述部分场景依赖额外的虚拟机镜像文件，但这些镜像文件没有随当前代码包一并上传。

当前 `Makefile` 中直接引用、但未包含在本次交付中的镜像主要包括：

- `iscsi.qcow2`
- `kafka1-os.qcow2`
- `kafka2-os.qcow2`
- `kafka3-os.qcow2`
- `kafka-client-os.qcow2`

也就是说，代码包中保留了这些测试场景的启动脚本和配置方式，但实际运行这些场景时，仍需要使用者自行准备对应的虚拟机镜像文件。

## 3. bc_eh_test 中的测试内容

`bc_eh_test/build_ramdisk/initrmfs/` 中内置了可直接在虚拟机内运行的测试脚本和工具，核心测试内容主要分为两类。

### 3.1 LLDD 驱动测试

`LLDD/` 目录下包含：

- `iscsi_tcp/`
- `megaraid/`
- `mpt3sas/`

这部分脚本主要用于对比 `bc-eh` 与 `linux-eh` 两条路径在不同驱动场景下的行为和结果。

### 3.2 scsi_debug 场景测试

`scsi_debug/` 目录下包含：

- `basictopo/`
- `complextopo/`
- `funcVer/`
- `sequence_cases/`
- `checkpoint_perf/`
- `fpl_perf/`
- `fpl_perf_quick/`
- `fpl_perf_real/`
- `kafka_jbod/`

这部分脚本主要用于基于 `scsi_debug` 构造虚拟 SCSI 设备，验证功能、错误处理路径以及性能表现。

其中，`basictopo/`、`complextopo/`、`funcVer/`、`sequence_cases/` 以及部分 `scsi_debug` 性能测试，可以直接通过 `make dr` 启动的基础调试虚拟机执行。这类测试主要依赖当前内核、ramdisk 和 `scsi_debug` 模块本身，不依赖前面 `iSCSI`、`MegaRAID`、`mpt3sas`、`Kafka JBOD` 场景所需的额外虚拟机镜像。

`kafka_jbod/` 虽然位于 `scsi_debug/` 目录下，但它对应的是基于 Kafka 多虚拟机环境的扩展实验场景，不属于 `make dr` 直接可跑通的基础调试路径，仍依赖前文说明的 Kafka 业务镜像和相应 guest 环境。

需要特别说明的是，`scsi_debug` 相关材料中同时存在“实验路径编号”和“论文路径编号”两套命名，它们不是完全同一套编号。

- 实验脚本和实验设计材料沿用较早的路径划分方式。
- 论文和图表为了按故障作用域与恢复链重新组织叙述，对路径编号做了重新映射。
- 因此，阅读实验脚本、`scsi_debug.md`、测试记录和论文图表时，不能仅按相同的 `P` 编号直接对应，需要按下面的映射关系理解。

对应关系如下：

- 论文 `P1` = 实验旧路径 `P1`
- 论文 `P2` = 实验旧路径 `P8`
- 论文 `P3` / `P4` / `P5` = 实验旧路径 `P2` / `P4` / `P5`
- 论文 `P6` = 实验旧路径 `P9`
- 论文 `P7` / `P8` / `P9` = 实验旧路径 `P3` / `P6` / `P7`

也就是说，论文中的路径编号是最终写作口径，实验中的旧路径编号是实际测试设计和部分材料中保留下来的历史命名；两者描述的是同一组测试场景，但编号体系不同。

## 4. 最快运行流程

如果只是希望尽快把 `scsi_debug` 相关测试跑起来，可以按下面的顺序执行：

1. 先进入 `atclinux/` 编译 Linux 内核和相关模块。

```bash
cd /path/to/atclinux
make -j$(nproc)
```

2. 编译完成后进入 `bc_eh_test/`，把模块复制到 ramdisk，并重新生成手工 ramdisk 镜像。

```bash
cd /path/to/atclinux/bc_eh_test
./cpmodule.sh
make mad
```

3. 在宿主机上使用 `sudo make dr` 启动基础调试虚拟机。

```bash
sudo make dr
```

4. 进入虚拟机后，进入 `/double_D/bc_eh_test/scsi_debug/`，执行基础回归入口脚本 `run_all.sh`。

```bash
cd /double_D/bc_eh_test/scsi_debug
bash run_all.sh
```

这条流程对应的是最快的 `scsi_debug` 基础验证路径：不依赖额外的 `qcow2` 业务镜像，直接基于当前内核、手工 ramdisk 和 `make dr` 启动的调试虚拟机完成基础回归测试。需要注意，这里的 `run_all.sh` 并不覆盖 `scsi_debug/` 目录下所有扩展场景，像 `kafka_jbod/` 这类依赖额外环境的目录仍需单独按其场景要求执行。

## 5. 两部分之间的关系

这份代码包的使用关系很直接：

1. 在 `atclinux/` 中完成代码修改、编译内核和编译模块。
2. 通过 `bc_eh_test/cpmodule.sh` 把测试模块复制到 ramdisk。
3. 通过 `bc_eh_test/Makefile` 生成镜像并启动对应测试场景。
4. 在虚拟机内执行 `bc_eh_test` 内置脚本，对 `atclinux/` 中的代码修改进行验证。

## 6. 总结

如果对外说明，这份代码包可以概括为：

`atclinux/` 提供包含实际代码修改的 Linux 6.18.0 内核代码树，`bc_eh_test/` 提供与这些修改相配套的测试、启动和验证环境，两者配合用于完成开发、复现和测试。

## 7. 声明

`bc_eh_test/` 中 `LLDD/` 和 `scsi_debug/` 相关测试内容，均由本人提出测试需求、场景要求和使用目标，并最终由 AI 生成。

本次交付材料中已隐去 `git` 提交信息。

当前说明文档由 AI 生成。

并由本人复查过。
