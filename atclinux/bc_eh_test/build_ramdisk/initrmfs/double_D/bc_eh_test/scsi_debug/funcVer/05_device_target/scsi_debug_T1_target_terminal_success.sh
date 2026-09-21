#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：05_device_target（实现 device / target）
# - 目标：验证 target 已不健康时会跳过 device reset，直接进入 target reset

export FUNCVER_GROUP=05_device_target
export FUNCVER_CASE_ID=T1_target_terminal_success
export FUNCVER_EH_RESET_MASK=0x3
export FUNCVER_EXPECT_PATH='T+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B'
export FUNCVER_DESC='同一 target 不健康时，device+target 组合应直接选择 target reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
