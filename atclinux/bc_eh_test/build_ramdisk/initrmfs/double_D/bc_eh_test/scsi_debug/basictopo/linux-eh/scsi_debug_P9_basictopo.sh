#!/bin/sh
set -eu

# 故障场景：
# - 论文扩展用例：P9，单一 channel 内共享故障的 basictopo 投影版
# - 拓扑：basictopo（1host_1ch_1tgt_1lun，仅 A=<host_no>:0:0:0）
# - 注错方式沿用 complextopo/linux-eh 的 P9 风格：
#   A 持续 IO timeout / abort，且唯一 target 的 target reset 被设置为 fail，
#   使传统 linux-eh 沿固定升级链推进到 bus reset
# - 说明：
#   basictopo 不存在健康异 channel 对照，因此该脚本只保留 P9 的主故障注错风格，
#   不用于证明 channel-vs-host 的完整边界闭合语义
# - 故障节点：A
# - 预期恢复链：D- -> T- -> B+

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="P9"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/basictopo/linux-eh/${CASE_ID}"

export BC_EH_TOPOLOGY=basictopo

main()
{
    local scsi_debug_host
    local A_scsi_id
    local A_block
    local target0_id

    bc_eh_reset_case_state
    bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"

    export SDEBUG_EH_RESET_MASK=0xf

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "host"

    A_scsi_id="$(bc_eh_wait_named_scsi_id A "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node A"
    A_block="$(bc_eh_wait_block_device "${A_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for A"

    target0_id="$(bc_eh_target_id_from_scsi_id "${A_scsi_id}")"
    bc_eh_set_target_fail_reset "${target0_id}" 1
    bc_eh_apply_error_rules "${A_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"

    {
        printf 'case_id=%s\n' "${CASE_ID}"
        printf 'profile=linux-eh\n'
        printf 'topology=basictopo\n'
        printf 'eh_mode=host\n'
        printf 'eh_reset_mask=0xf\n'
        printf 'expect_path=D- -> T- -> B+\n'
        printf 'fault_nodes=A\n'
        printf 'active_nodes=A\n'
        printf 'target_fail_ids=%s\n' "${target0_id}"
        printf 'projection_note=basictopo projection of P9 fault-injection style; no healthy peer channel exists\n'
        printf 'host=%s\n' "${scsi_debug_host}"
        printf 'A=%s /dev/%s\n' "${A_scsi_id}" "${A_block}"
    } > "${RUN_DIR}/metadata"

    bc_eh_log "run ${CASE_ID}(linux-eh/basictopo projection): fault=A"
    bc_eh_run_fio_on_named_devices "${RUN_DIR}" "A=/dev/${A_block}"
}

main "$@"
