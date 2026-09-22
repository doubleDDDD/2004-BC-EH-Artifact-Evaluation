#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 05_device_target (implements device / target)
# - Goal: Verify that when the target is unhealthy, device reset is skipped and target reset is entered directly

export FUNCVER_GROUP=05_device_target
export FUNCVER_CASE_ID=T1_target_terminal_success
export FUNCVER_EH_RESET_MASK=0x3
export FUNCVER_EXPECT_PATH='T+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B'
export FUNCVER_DESC='when the same target is unhealthy, the device+target combination should choose target reset directly'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
