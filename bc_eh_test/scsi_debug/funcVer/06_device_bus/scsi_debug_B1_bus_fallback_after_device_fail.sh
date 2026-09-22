#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 06_device_bus (implements device / bus)
# - Goal: Verify that with target ambiguity and no target handler, recovery escalates to bus reset after device reset fails

export FUNCVER_GROUP=06_device_bus
export FUNCVER_CASE_ID=B1_bus_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0x5
export FUNCVER_EXPECT_PATH='D- -> B+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target ambiguity with no target handler; escalates to bus reset after device reset fails'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
