#!/bin/sh
set -eu

# - 论文用例：P7
# - 拓扑：basictopo（1host_1ch_1tgt_1lun，仅 A=<host_no>:0:0:0）
# - 故障节点：A，恢复链：D- -> T- -> B- -> H+ / V-

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P7
export BC_EH_TOPOLOGY=basictopo

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
