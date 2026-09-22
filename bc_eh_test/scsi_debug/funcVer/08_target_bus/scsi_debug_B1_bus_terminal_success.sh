#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 08_target_bus (implements target / bus)
# - Goal: Verify that when the channel is unhealthy, target reset is skipped and bus reset is entered directly

export FUNCVER_GROUP=08_target_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x6
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='under channel-level ambiguity, the target+bus combination should skip target reset and enter bus reset directly'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
