#!/bin/sh
set -eu

# 故障场景：
# - 论文用例：P3，Host / controller 侧瞬时故障
# - 拓扑：complextopo（完整 2ch_2tgt_2lun，共 8 盘）
# - 命名节点映射：A=<host_no>:0:0:0，B=<host_no>:0:0:1，C=<host_no>:0:1:0，D=<host_no>:1:0:0，E=<host_no>:1:1:0
# - 补足 idle 节点：F=<host_no>:0:1:1，G=<host_no>:1:0:1，H=<host_no>:1:1:1
# - active 节点：A、B、C、D
# - idle 节点：E、F、G、H
# - 实际对 A、B、C、D 注入故障，A 为主触发盘
# - 对 active 块设备各运行一组 fio：故障注入盘默认 runtime=30，健康对照盘默认 runtime=120：/dev/<A_block>、/dev/<B_block>、/dev/<C_block>、/dev/<D_block>
# - 清场阶段会先卸载 scsi_debug 与 crc_t10dif，再通过 modprobe 加载 crc_t10dif 与 scsi_debug
# - 默认实际命令（host<host_no> / <A_block> / <B_block> / <C_block> / <D_block> 为运行时解析值，环境变量未覆盖时）：
#   modprobe crc_t10dif
#   modprobe scsi_debug add_host=1 num_channels=2 num_tgts=2 max_luns=2 dev_size_mb=128 sector_size=512 dsense=1 delay=1
#   echo 'host' > /sys/class/scsi_host/host<host_no>/eh_mode
#   echo '1' > /sys/kernel/debug/scsi_debug/target<host_no>:0:0/fail_reset
#   echo '1' > /sys/kernel/debug/scsi_debug/target<host_no>:0:1/fail_reset
#   echo '1' > /sys/kernel/debug/scsi_debug/target<host_no>:1:0/fail_reset
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '4 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '4 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '5 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '5 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:1:0/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:1:0/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:1:0/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:1:0/error
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:1:0:0/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:1:0:0/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:1:0:0/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:1:0:0/error
#   fio --filename=/dev/<A_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_A
#   fio --filename=/dev/<B_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_B
#   fio --filename=/dev/<C_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_C
#   fio --filename=/dev/<D_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_D
# - A/B/C/D 上读写命令 0x28 / 0x2a 持续 IO timeout
# - A 上 device reset 失败、target reset 失败、bus reset 失败
# - target<host_no>:0:0、target<host_no>:0:1、target<host_no>:1:0 的 target reset 均失败
# - host reset 成功，随后 I/O 恢复
# - 恢复链：D- -> T- -> B- -> H+

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P3

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
