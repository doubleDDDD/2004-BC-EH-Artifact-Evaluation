#!/bin/sh
set -eu

# - Paper case: P2
# - Topology: basictopo (1host_1ch_1tgt_1lun, only A=<host_no>:0:0:0)
# - Fault node: A, Recovery chain: D- -> T+

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P2
export BC_EH_TOPOLOGY=basictopo

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../../scsi_debug_case.sh" "$@"
