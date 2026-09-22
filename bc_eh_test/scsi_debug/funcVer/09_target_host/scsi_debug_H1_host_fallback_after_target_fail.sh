#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 09_target_host (implements target / host)
# - Goal: Verify that with channel ambiguity and no bus handler, recovery escalates to host reset after target reset fails

export FUNCVER_GROUP=09_target_host
export FUNCVER_CASE_ID=H1_host_fallback_after_target_fail
export FUNCVER_EH_RESET_MASK=0xa
export FUNCVER_EXPECT_PATH='T- -> H+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_TARGET_FAIL_NODES='A C'
export FUNCVER_DESC='channel ambiguity with no bus handler; escalates to host reset after target reset fails'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
