#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 11_device_target_bus (implements device / target / bus)
# - Goal: Verify that under channel ambiguity, the device handler should not be triggered by mistake and the recovery chain should terminate at bus reset

export FUNCVER_GROUP=11_device_target_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x7
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='under channel-level ambiguity, the device+target+bus combination should terminate at bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
