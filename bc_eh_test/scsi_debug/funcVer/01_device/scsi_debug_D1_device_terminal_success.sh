#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 01_device (only implements the device reset handler)
# - Goal: Verify that a single-LUN fault converges directly to device reset when only the device handler exists

export FUNCVER_GROUP=01_device
export FUNCVER_CASE_ID=D1_device_terminal_success
export FUNCVER_EH_RESET_MASK=0x1
export FUNCVER_EXPECT_PATH='D+'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='single-LUN fault with only the device handler; device reset completes directly'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
