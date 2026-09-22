#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：14_target_bus_host（实现 target / bus / host）
# - 目标：验证整 host 都不健康时，会直接收敛到 host reset

export FUNCVER_GROUP=14_target_bus_host
export FUNCVER_CASE_ID=H1_host_terminal_success
export FUNCVER_EH_RESET_MASK=0xe
export FUNCVER_EXPECT_PATH='H+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C D'
export FUNCVER_DESC='全 host 不健康时，target+bus+host 组合应直接收敛到 host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
