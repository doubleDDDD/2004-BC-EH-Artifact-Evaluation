#!/bin/sh
set -eu

# 故障场景：
# - 功能验证分组：15_device_target_bus_host（device / target / bus / host 四级 reset handler 全实现）
# - 独特用例：W1，checkpoint wait / re-enter
# - 目标：验证“首个 fault 已经启动 sequence，随后同 host 的另一个 fault episode 延迟到达”时：
#   1. 新 fault 先进入 pending fault 队列
#   2. 在更大 reset scope 上被吸收
#   3. checkpoint 因 busy != failed 返回 NEED_WAIT_IO_DONE
#   4. 之后再次进入 checkpoint，继续推进恢复
# - scsi_debug 模块参数：eh_reset_mask=0xf
# - 拓扑：complextopo（完整 2ch_2tgt_2lun，共 8 盘）
# - 命名节点映射：A=<host_no>:0:0:0，B=<host_no>:0:0:1，C=<host_no>:0:1:0，D=<host_no>:1:0:0
# - active 节点：A、B、C、D
# - idle 节点：E、F、G、H
# - 故障域设计：
#   A/B/C 从起始时刻故障，用于把 sequence 迅速推到 bus / host 方向
#   D 起始保持健康并持续 I/O，延迟注入故障，用于制造 pending fault + wait/re-enter
# - 预期日志关键字：
#   1. enqueue pending fault
#   2. absorb pending fault
#   3. update_eh_field_to_host ... need wait(1) 或 update_eh_field_to_channel ... need wait(1)
#   4. 后续再次进入同层 checkpoint，need wait(0) 后继续 reset
# - 说明：
#   该用例关注的是“结构性路径是否出现”，不是固定要求最终停在某一级 reset

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="W1_checkpoint_wait_reenter"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/funcVer/15_device_target_bus_host/${CASE_ID}"
readonly DELAYED_INJECT_SECS="${BC_EH_DELAYED_INJECT_SECS:-5}"

main()
{
    local scsi_debug_host
    local injector_pid
    local A_scsi_id B_scsi_id C_scsi_id D_scsi_id
    local A_block B_block C_block D_block
    local A_rules

    bc_eh_reset_case_state
    A_rules="${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
    bc_eh_set_node_error_rules A "${A_rules}"
    bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT}"

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"

    export SDEBUG_EH_RESET_MASK=0xf

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "sdev"

    A_scsi_id="$(bc_eh_wait_named_scsi_id A "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node A"
    B_scsi_id="$(bc_eh_wait_named_scsi_id B "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node B"
    C_scsi_id="$(bc_eh_wait_named_scsi_id C "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node C"
    D_scsi_id="$(bc_eh_wait_named_scsi_id D "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node D"

    A_block="$(bc_eh_wait_block_device "${A_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for A"
    B_block="$(bc_eh_wait_block_device "${B_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for B"
    C_block="$(bc_eh_wait_block_device "${C_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for C"
    D_block="$(bc_eh_wait_block_device "${D_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for D"

    bc_eh_apply_error_rules "${A_scsi_id}" "${A_rules}"
    bc_eh_apply_error_rules "${B_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_apply_error_rules "${C_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"

    {
        printf 'case_id=%s\n' "${CASE_ID}"
        printf 'group=15_device_target_bus_host\n'
        printf 'eh_reset_mask=0xf\n'
        printf 'eh_mode=sdev\n'
        printf 'delayed_inject_secs=%s\n' "${DELAYED_INJECT_SECS}"
        printf 'seed_fault_nodes=A,B,C\n'
        printf 'late_fault_node=D\n'
        printf 'host=%s\n' "${scsi_debug_host}"
        printf 'A=%s /dev/%s\n' "${A_scsi_id}" "${A_block}"
        printf 'B=%s /dev/%s\n' "${B_scsi_id}" "${B_block}"
        printf 'C=%s /dev/%s\n' "${C_scsi_id}" "${C_block}"
        printf 'D=%s /dev/%s\n' "${D_scsi_id}" "${D_block}"
    } > "${RUN_DIR}/metadata"

    (
        sleep "${DELAYED_INJECT_SECS}"
        bc_eh_log "delayed inject fault into D after ${DELAYED_INJECT_SECS}s"
        bc_eh_apply_error_rules "${D_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    ) &
    injector_pid=$!

    bc_eh_log "run ${CASE_ID}: A=/dev/${A_block} B=/dev/${B_block} C=/dev/${C_block} D=/dev/${D_block}"
    bc_eh_run_fio_on_named_devices "${RUN_DIR}" \
        "A=/dev/${A_block}" \
        "B=/dev/${B_block}" \
        "C=/dev/${C_block}" \
        "D=/dev/${D_block}"

    wait "${injector_pid}"
}

main "$@"
