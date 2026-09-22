#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 03_bus (only implements the bus reset handler)
# - Goal: Verify that a channel-level fault converges directly to bus reset when only the bus handler exists

export FUNCVER_GROUP=03_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x4
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='multi-target fault on the same channel with only the bus handler; terminates at bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
