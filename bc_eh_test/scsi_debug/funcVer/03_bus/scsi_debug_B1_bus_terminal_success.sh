#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：03_bus（仅实现 bus reset handler）
# - 目标：验证 channel 级故障在只有 bus handler 时直接收敛到 bus reset

export FUNCVER_GROUP=03_bus
export FUNCVER_CASE_ID=B1_bus_terminal_success
export FUNCVER_EH_RESET_MASK=0x4
export FUNCVER_EXPECT_PATH='B+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_DESC='同一 channel 的多 target 故障，只有 bus handler，直接以 bus reset 终止'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
