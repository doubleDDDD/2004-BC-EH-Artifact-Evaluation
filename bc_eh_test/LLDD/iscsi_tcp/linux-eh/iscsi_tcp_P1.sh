#!/bin/sh
set -eu

export BC_EH_PROFILE=linux-eh
export BC_EH_MODE_VALUE=host
export BC_EH_CASE=P1

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec sh "${SCRIPT_DIR}/../run_iscsi_case.sh" "$@"
