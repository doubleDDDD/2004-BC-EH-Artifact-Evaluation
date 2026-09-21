#!/bin/sh
set -eu

# FPL hot-path case: bc_eh / 1 active sdev / randread / 4k
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BC_EH_FPL_EH_MODE=sdev \
BC_EH_FPL_ACTIVE_DISKS=1 \
BC_EH_FPL_WORKLOAD=randread_4k \
exec sh "${SCRIPT_DIR}/run_fpl_hotpath_case.sh" "$@"
