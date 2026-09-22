#!/bin/sh
set -eu

# Quick single-case entry:
# - defaults to one repeat
# - defaults to runtime=5s
# - defaults to no warmup
# - the remaining logic reuses the Ubuntu/modprobe version in fpl_perf_real/run_fpl_hotpath_case.sh
#
# Examples:
#   BC_EH_FPL_EH_MODE=host \
#   BC_EH_FPL_ACTIVE_DISKS=4 \
#   BC_EH_FPL_WORKLOAD=randread_64k \
#   sh run_fpl_hotpath_case.sh

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly UPSTREAM_CASE_SH="${SCRIPT_DIR}/../fpl_perf_real/run_fpl_hotpath_case.sh"

[ -x "${UPSTREAM_CASE_SH}" ] || [ -f "${UPSTREAM_CASE_SH}" ] || {
    printf 'missing upstream script: %s\n' "${UPSTREAM_CASE_SH}" >&2
    exit 1
}

export BC_EH_FPL_RUNTIME_SECS="${BC_EH_FPL_RUNTIME_SECS:-5}"
export BC_EH_FPL_WARMUP_SECS="${BC_EH_FPL_WARMUP_SECS:-0}"

exec sh "${UPSTREAM_CASE_SH}" "$@"
