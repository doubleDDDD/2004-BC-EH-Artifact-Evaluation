#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 13_device_bus_host (implements device / bus / host)
# - Goal: Verify that target ambiguity first triggers device reset, then escalates to host reset because the host is unhealthy

export FUNCVER_GROUP=13_device_bus_host
export FUNCVER_CASE_ID=H1_host_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0xd
export FUNCVER_EXPECT_PATH='D- -> H+'
export FUNCVER_ACTIVE_NODES='A B D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target ambiguity first triggers device reset; then the host is unhealthy, so the device+bus+host combination should escalate to host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
