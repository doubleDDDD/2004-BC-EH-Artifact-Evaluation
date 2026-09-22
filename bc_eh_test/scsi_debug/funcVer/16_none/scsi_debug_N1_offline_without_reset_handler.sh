#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 16_none (implements no reset handler)
# - Goal: Verify that the fault sdev is offlined directly instead of entering any reset path

export FUNCVER_GROUP=16_none
export FUNCVER_CASE_ID=N1_offline_without_reset_handler
export FUNCVER_EH_RESET_MASK=0x0
export FUNCVER_EXPECT_PATH='offline'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='when no reset handler exists, the fault sdev should be offlined directly'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
