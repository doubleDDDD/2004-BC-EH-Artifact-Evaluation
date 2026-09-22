#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：16_none（不实现任何 reset handler）
# - 目标：验证 fault sdev 会被直接 offline，而不是进入任何 reset 路径

export FUNCVER_GROUP=16_none
export FUNCVER_CASE_ID=N1_offline_without_reset_handler
export FUNCVER_EH_RESET_MASK=0x0
export FUNCVER_EXPECT_PATH='offline'
export FUNCVER_ACTIVE_NODES='A B'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A'
export FUNCVER_DESC='没有任何 reset handler 时，fault sdev 应直接 offline'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
