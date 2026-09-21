#!/bin/sh
set -eu

# FPL hot-path case: bc_eh / 2 active sdev / randread / 64k
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BC_EH_FPL_EH_MODE=sdev \
BC_EH_FPL_ACTIVE_DISKS=2 \
BC_EH_FPL_WORKLOAD=randread_64k \
exec sh "${SCRIPT_DIR}/run_fpl_hotpath_case.sh" "$@"
