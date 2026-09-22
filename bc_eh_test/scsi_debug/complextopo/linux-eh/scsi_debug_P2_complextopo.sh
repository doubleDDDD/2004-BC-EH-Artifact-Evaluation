#!/bin/sh
set -eu

# Fault scenario:
# - Paper case: P2, target-scope transient fault
# - Topology: complextopo (full 2ch_2tgt_2lun, 8 disks total)
# - Named node mapping: A=<host_no>:0:0:0, B=<host_no>:0:0:1, C=<host_no>:0:1:0, D=<host_no>:1:0:0, E=<host_no>:1:1:0
# - Additional idle nodes: F=<host_no>:0:1:1, G=<host_no>:1:0:1, H=<host_no>:1:1:1
# - active nodes: A, B, C
# - idle nodes: D, E, F, G, H
# - Inject faults into A and B; C is the healthy active sibling under the same channel
# - Run one fio workload on each active block device: default runtime is 30 for fault-injected disks and 120 for healthy control disks: /dev/<A_block>, /dev/<B_block>, /dev/<C_block>
# - The cleanup phase first unloads scsi_debug and crc_t10dif, then reloads crc_t10dif and scsi_debug with modprobe
# - Default actual command (host<host_no> / <A_block> / <B_block> / <C_block> are resolved at runtime when not overridden by environment variables):
#   modprobe crc_t10dif
#   modprobe scsi_debug add_host=1 num_channels=2 num_tgts=2 max_luns=2 dev_size_mb=128 sector_size=512 dsense=1 delay=1
#   echo 'host' > /sys/class/scsi_host/host<host_no>/eh_mode
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '4 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '4 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:0/error
#   echo '0 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '4 1 28' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '0 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '3 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   echo '4 1 2a' > /sys/kernel/debug/scsi_debug/<host_no>:0:0:1/error
#   fio --filename=/dev/<A_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_A
#   fio --filename=/dev/<B_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_B
#   fio --filename=/dev/<C_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=120 --group_reporting --name=randread_4k_C
# - A/B has persistent IO timeout on read/write commands 0x28 / 0x2a
# - A/B abort fails
# - A/B  device reset fails
# - then target reset succeeds and I/O recovers
# - Recovery chain: D- -> T+

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P2

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
