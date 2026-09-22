#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：04_host（仅实现 host reset handler）
# - 目标：验证即使只是单设备故障，也会因无低层 handler 直接收敛到 host reset

export FUNCVER_GROUP=04_host
export FUNCVER_CASE_ID=H1_host_terminal_success
export FUNCVER_EH_RESET_MASK=0x8
export FUNCVER_EXPECT_PATH='H+'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='单设备故障且无更低层 reset 手段，直接以 host reset 终止'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
