#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：06_device_bus（实现 device / bus）
# - 目标：验证 target 歧义且缺少 target handler 时，device reset 失败后会升级到 bus reset

export FUNCVER_GROUP=06_device_bus
export FUNCVER_CASE_ID=B1_bus_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0x5
export FUNCVER_EXPECT_PATH='D- -> B+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target 歧义且无 target handler，device reset 失败后升级到 bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
