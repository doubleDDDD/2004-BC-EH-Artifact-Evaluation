#!/bin/sh
set -eu

# Fault scenario:
# - Paper case: P8, single-device permanent fault
# - Topology: complextopo (full 2ch_2tgt_2lun, 8 disks total)
# - Named node mapping: A=<host_no>:0:0:0, B=<host_no>:0:0:1, C=<host_no>:0:1:0, D=<host_no>:1:0:0, E=<host_no>:1:1:0
# - Additional idle nodes: F=<host_no>:0:1:1, G=<host_no>:1:0:1, H=<host_no>:1:1:1
# - active nodes: A, B
# - idle nodes: C, D, E, F, G, H
# - Inject faults only into B (channel0/target0/lun1); A is the healthy active sibling under the same target
# - Run one fio workload on each active block device: default runtime is 30 for fault-injected disks and 120 for healthy control disks: /dev/<A_block>, /dev/<B_block>
# - The cleanup phase first unloads scsi_debug and crc_t10dif, then reloads crc_t10dif and scsi_debug with modprobe
# - Default actual command (host<host_no> / <A_block> / <B_block> are resolved at runtime when not overridden by environment variables):
#   modprobe crc_t10dif
#   modprobe scsi_debug add_host=1 num_channels=2 num_tgts=2 max_luns=2 dev_size_mb=128 sector_size=512 dsense=1 delay=1
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
#   fio --filename=/dev/<A_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=120 --group_reporting --name=randread_4k_A
#   fio --filename=/dev/<B_block> --ioengine=libaio --direct=1 --iodepth=64 --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=30 --group_reporting --name=randread_4k_B
# - B has persistent IO timeout on read/write commands 0x28 / 0x2a
# - B abort fails
# - device reset succeeds, then TUR validation times out
# - target reset succeeds, then TUR validation times out
# - bus reset succeeds, then TUR validation times out
# - host reset succeeds, then TUR validation times out
# - final recovery fails
# - Recovery chain: D+ / V~ -> T+ / V~ -> B+ / V~ -> H+ / V~

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P8

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
