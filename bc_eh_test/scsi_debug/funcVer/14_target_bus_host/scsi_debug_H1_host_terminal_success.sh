#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 14_target_bus_host (implements target / bus / host)
# - Goal: Verify that when the whole host is unhealthy, recovery converges directly to host reset

export FUNCVER_GROUP=14_target_bus_host
export FUNCVER_CASE_ID=H1_host_terminal_success
export FUNCVER_EH_RESET_MASK=0xe
export FUNCVER_EXPECT_PATH='H+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C D'
export FUNCVER_DESC='when the whole host is unhealthy, the target+bus+host combination should converge directly to host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
