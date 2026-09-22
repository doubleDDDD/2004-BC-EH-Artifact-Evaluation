#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 02_target (only implements the target reset handler)
# - Goal: Verify that dual-LUN faults under the same target converge directly to target reset

export FUNCVER_GROUP=02_target
export FUNCVER_CASE_ID=T1_target_terminal_success
export FUNCVER_EH_RESET_MASK=0x2
export FUNCVER_EXPECT_PATH='T+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B'
export FUNCVER_DESC='dual-LUN fault under the same target with only the target handler; terminates at target reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
