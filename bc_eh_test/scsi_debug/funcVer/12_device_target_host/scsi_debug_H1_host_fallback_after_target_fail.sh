#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：12_device_target_host（实现 device / target / host）
# - 目标：验证无 bus handler 时，target reset 失败后会升级到 host reset

export FUNCVER_GROUP=12_device_target_host
export FUNCVER_CASE_ID=H1_host_fallback_after_target_fail
export FUNCVER_EH_RESET_MASK=0xb
export FUNCVER_EXPECT_PATH='T- -> H+'
export FUNCVER_ACTIVE_NODES='A B C D'
export FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES='A B C'
export FUNCVER_TARGET_FAIL_NODES='A C'
export FUNCVER_DESC='无 bus handler 时，device+target+host 组合应经 target reset 失败后升级到 host reset'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/../funcver_case.sh" "$@"
