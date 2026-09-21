#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：02_target（仅实现 target reset handler）
# - 目标：验证同一 target 的双 LUN 故障会直接收敛到 target reset

export FUNCVER_GROUP=02_target
export FUNCVER_CASE_ID=T1_target_terminal_success
export FUNCVER_EH_RESET_MASK=0x2
export FUNCVER_EXPECT_PATH='T+'
export FUNCVER_ACTIVE_NODES='A B C'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B'
export FUNCVER_DESC='同一 target 双 LUN 故障，只有 target handler，直接以 target reset 终止'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
