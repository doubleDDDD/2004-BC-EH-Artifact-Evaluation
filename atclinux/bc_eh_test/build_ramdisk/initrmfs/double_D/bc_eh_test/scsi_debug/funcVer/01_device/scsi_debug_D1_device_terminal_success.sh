#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：01_device（仅实现 device reset handler）
# - 目标：验证单 LUN 故障在只有 device handler 时直接收敛到 device reset

export FUNCVER_GROUP=01_device
export FUNCVER_CASE_ID=D1_device_terminal_success
export FUNCVER_EH_RESET_MASK=0x1
export FUNCVER_EXPECT_PATH='D+'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='单 LUN 故障，只有 device handler，可直接完成 device reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
