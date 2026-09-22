#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：08_target_bus（实现 target / bus）
# - 目标：验证 channel 不健康时，会跳过 target reset 直接进入 bus reset

export FUNCVER_GROUP=08_target_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x6
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='channel 级歧义下，target+bus 组合应跳过 target reset 直接进入 bus reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
