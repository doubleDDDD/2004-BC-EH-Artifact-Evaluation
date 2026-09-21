#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：13_device_bus_host（实现 device / bus / host）
# - 目标：验证 target 歧义先触发 device reset，随后因 host 不健康而升级到 host reset

export FUNCVER_GROUP=13_device_bus_host
export FUNCVER_CASE_ID=H1_host_fallback_after_device_fail
export FUNCVER_EH_RESET_MASK=0xd
export FUNCVER_EXPECT_PATH='D- -> H+'
export FUNCVER_ACTIVE_NODES='A B D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES='A B'
export FUNCVER_DESC='target 歧义先触发 device reset，随后 host 不健康，device+bus+host 组合应升级到 host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
