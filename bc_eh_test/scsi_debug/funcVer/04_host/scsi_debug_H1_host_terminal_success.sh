#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 04_host (only implements the host reset handler)
# - Goal: Verify that even a single-device fault converges directly to host reset when lower-level handlers are absent

export FUNCVER_GROUP=04_host
export FUNCVER_CASE_ID=H1_host_terminal_success
export FUNCVER_EH_RESET_MASK=0x8
export FUNCVER_EXPECT_PATH='H+'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='single-device fault with no lower-level reset method; terminates at host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
