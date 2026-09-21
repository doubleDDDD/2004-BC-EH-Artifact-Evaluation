#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BC_EH_CP_RUNNING_POS=16 exec sh "${SCRIPT_DIR}/run_checkpoint_convergence_case.sh" "$@"
