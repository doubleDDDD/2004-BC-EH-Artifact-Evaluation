#!/bin/sh
set -eu

# FPL hot-path case: bc_eh / 8 active sdev / randwrite / 256k
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BC_EH_FPL_EH_MODE=sdev \
BC_EH_FPL_ACTIVE_DISKS=8 \
BC_EH_FPL_WORKLOAD=randwrite_256k \
exec sh "${SCRIPT_DIR}/run_fpl_hotpath_case.sh" "$@"
