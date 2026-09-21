#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：11_device_target_bus（实现 device / target / bus）
# - 目标：验证 channel 歧义时，device handler 不应误触发，恢复链应终止于 bus reset

export FUNCVER_GROUP=11_device_target_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x7
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='device+target+bus 组合在 channel 级歧义时应终止于 bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
