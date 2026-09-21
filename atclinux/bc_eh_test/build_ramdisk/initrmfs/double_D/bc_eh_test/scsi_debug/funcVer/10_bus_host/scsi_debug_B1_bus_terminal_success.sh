#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：10_bus_host（实现 bus / host）
# - 目标：验证 host 仍健康时，恢复链应停在 bus reset 而不是继续升级到 host

export FUNCVER_GROUP=10_bus_host
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0xc
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='channel 不健康但 host 仍健康时，bus+host 组合应停在 bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
