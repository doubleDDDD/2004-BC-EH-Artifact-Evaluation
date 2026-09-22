#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 07_device_host (implements device / host)
# - Goal: Verify that with target ambiguity and only host-level escalation available, recovery enters host reset after device reset fails

export FUNCVER_GROUP=07_device_host
export FUNCVER_CASE_ID=H1_host_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0x9
export FUNCVER_EXPECT_PATH='D- -> H+'
export FUNCVER_ACTIVE_NODES='A B D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target ambiguity with only the host handler left; escalates to host reset after device reset fails'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
