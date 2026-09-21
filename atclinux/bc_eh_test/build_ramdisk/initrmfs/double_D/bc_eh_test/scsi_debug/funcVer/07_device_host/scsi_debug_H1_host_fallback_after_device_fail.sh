#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：07_device_host（实现 device / host）
# - 目标：验证 target 歧义且只有 host 可升级时，device reset 失败后会进入 host reset

export FUNCVER_GROUP=07_device_host
export FUNCVER_CASE_ID=H1_host_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0x9
export FUNCVER_EXPECT_PATH='D- -> H+'
export FUNCVER_ACTIVE_NODES='A B D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target 歧义且仅剩 host handler，device reset 失败后升级到 host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
