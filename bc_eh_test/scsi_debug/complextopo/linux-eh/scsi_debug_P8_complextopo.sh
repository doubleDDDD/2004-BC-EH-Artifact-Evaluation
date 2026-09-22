#!/bin/sh
set -eu

# 故障场景：
# - 论文用例：P8，单设备永久性故障
# - 拓扑：complextopo（完整 2ch_2tgt_2lun，共 8 盘）
# - 命名节点映射：A=<host_no>:0:0:0，B=<host_no>:0:0:1，C=<host_no>:0:1:0，D=<host_no>:1:0:0，E=<host_no>:1:1:0
# - 补足 idle 节点：F=<host_no>:0:1:1，G=<host_no>:1:0:1，H=<host_no>:1:1:1
# - active 节点：A、B
# - idle 节点：C、D、E、F、G、H
# - 实际仅对 B（channel0/target0/lun1）注入故障，A 作为同 target 下的健康 active 兄弟
# - 对 active 块设备各运行一组 fio：故障注入盘默认 runtime=30，健康对照盘默认 runtime=120：/dev/<A_block>、/dev/<B_block>
# - 清场阶段会先卸载 scsi_debug 与 crc_t10dif，再从 /double_D/modules 先加载 crc-t10dif.ko，再加载 scsi_debug.ko
# - 默认实际命令（host<host_no> / <A_block> / <B_block> 为运行时解析值，环境变量未覆盖时）：
#   insmod /double_D/modules/crc-t10dif.ko
#   insmod /double_D/modules/scsi_debug.ko add_host=1 num_channels=2 num_tgts=2 max_luns=2 dev_size_mb=128 sector_size=512 dsense=1 delay=1
#   echo 'host' > /sys/class/scsi_host/host<host_no>/eh_mode
#   echo 'clear' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/validate_after_reset
#   echo 'device timeout 1' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/validate_after_reset
#   echo 'target timeout 1' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/validate_after_reset
#   echo 'bus timeout 1' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/validate_after_reset
#   echo 'host timeout 1' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/validate_after_reset
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   cd /double_D && ./fio --filename=/dev/<A_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=120 --group_reporting --name=randread_4k_A
#   cd /double_D && ./fio --filename=/dev/<B_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_B
# - B 上读写命令 0x28 / 0x2a 持续 IO timeout
# - B 上 abort 失败
# - device reset 成功，随后的 TUR 验证超时
# - target reset 成功，随后的 TUR 验证超时
# - bus reset 成功，随后的 TUR 验证超时
# - host reset 成功，随后的 TUR 验证超时
# - 最终恢复失败
# - 恢复链：D+ / V~ -> T+ / V~ -> B+ / V~ -> H+ / V~

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P8

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
