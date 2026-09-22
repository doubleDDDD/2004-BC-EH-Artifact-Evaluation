#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 10_bus_host (implements bus / host)
# - Goal: Verify that when the host remains healthy, the recovery chain stops at bus reset instead of escalating to host

export FUNCVER_GROUP=10_bus_host
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0xc
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='when the channel is unhealthy but the host remains healthy, the bus+host combination should stop at bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
