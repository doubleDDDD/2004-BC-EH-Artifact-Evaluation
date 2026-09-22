#!/bin/sh
set -eu

# Fault scenario:
# - Paper case: P9, single-channel shared fault
# - Topology: complextopo (full 2ch_2tgt_2lun, 8 disks total)
# - Named node mapping: A=<host_no>:0:0:0, B=<host_no>:0:0:1, C=<host_no>:0:1:0, D=<host_no>:1:0:0, E=<host_no>:1:1:0
# - Additional idle nodes: F=<host_no>:0:1:1, G=<host_no>:1:0:1, H=<host_no>:1:1:1
# - active nodes: A, B, C, D
# - idle nodes: E, F, G, H
# - Inject faults into A/B/C; all three are on faulty channel-0
# - D is on healthy channel-1 and keeps issuing healthy I/O to show host-level forward progress
# - To make native linux-eh follow the fixed escalation chain to bus reset,
#   also mark target reset as failed for both targets under channel-0
# - Goal:
#   verify that the same single-channel shared fault reaches bus/channel-level recovery under native linux-eh
# - Expected recovery chain: D- -> T- -> B+

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="P9"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/complextopo/linux-eh/${CASE_ID}"

main()
{
    local scsi_debug_host
    local A_scsi_id B_scsi_id C_scsi_id D_scsi_id
    local A_block B_block C_block D_block
    local target0_id target1_id

    bc_eh_reset_case_state
    bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
    bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
    bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"

    export SDEBUG_EH_RESET_MASK=0xf

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "host"

    A_scsi_id="$(bc_eh_wait_named_scsi_id A "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node A"
    B_scsi_id="$(bc_eh_wait_named_scsi_id B "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node B"
    C_scsi_id="$(bc_eh_wait_named_scsi_id C "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node C"
    D_scsi_id="$(bc_eh_wait_named_scsi_id D "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node D"

    A_block="$(bc_eh_wait_block_device "${A_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for A"
    B_block="$(bc_eh_wait_block_device "${B_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for B"
    C_block="$(bc_eh_wait_block_device "${C_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for C"
    D_block="$(bc_eh_wait_block_device "${D_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for D"

    eval "BC_EH_NODE_A_SCSI_ID='${A_scsi_id}'"
    eval "BC_EH_NODE_A_BLOCK_NAME='${A_block}'"
    eval "BC_EH_NODE_B_SCSI_ID='${B_scsi_id}'"
    eval "BC_EH_NODE_B_BLOCK_NAME='${B_block}'"
    eval "BC_EH_NODE_C_SCSI_ID='${C_scsi_id}'"
    eval "BC_EH_NODE_C_BLOCK_NAME='${C_block}'"
    eval "BC_EH_NODE_D_SCSI_ID='${D_scsi_id}'"
    eval "BC_EH_NODE_D_BLOCK_NAME='${D_block}'"

    bc_eh_configure_complextopo_queues

    target0_id="$(bc_eh_target_id_from_scsi_id "${A_scsi_id}")"
    target1_id="$(bc_eh_target_id_from_scsi_id "${C_scsi_id}")"
    bc_eh_set_target_fail_reset "${target0_id}" 1
    bc_eh_set_target_fail_reset "${target1_id}" 1

    bc_eh_apply_error_rules "${A_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
    bc_eh_apply_error_rules "${B_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
    bc_eh_apply_error_rules "${C_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"

    {
        printf 'case_id=%s\n' "${CASE_ID}"
        printf 'profile=linux-eh\n'
        printf 'topology=complextopo\n'
        printf 'eh_mode=host\n'
        printf 'eh_reset_mask=0xf\n'
        printf 'expect_path=D- -> T- -> B+\n'
        printf 'fault_nodes=A,B,C\n'
        printf 'healthy_running_node=D\n'
        printf 'idle_nodes=E,F,G,H\n'
        printf 'fault_channel=0\n'
        printf 'healthy_channel=1\n'
        printf 'target_fail_ids=%s,%s\n' "${target0_id}" "${target1_id}"
        if bc_eh_should_tune_complextopo_queues; then
            printf 'per_disk_queue_depth=%s\n' "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
            printf 'per_disk_nr_requests=%s\n' "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
            printf 'host_can_queue=%s\n' "$(bc_eh_complextopo_host_can_queue)"
            printf 'fio_iodepth=%s\n' "$(bc_eh_fio_iodepth)"
        fi
        printf 'host=%s\n' "${scsi_debug_host}"
        printf 'A=%s /dev/%s\n' "${A_scsi_id}" "${A_block}"
        printf 'B=%s /dev/%s\n' "${B_scsi_id}" "${B_block}"
        printf 'C=%s /dev/%s\n' "${C_scsi_id}" "${C_block}"
        printf 'D=%s /dev/%s\n' "${D_scsi_id}" "${D_block}"
    } > "${RUN_DIR}/metadata"

    bc_eh_log "run ${CASE_ID}(linux-eh): fault=A,B,C on channel-0; healthy=D on channel-1"
    bc_eh_run_fio_on_named_devices "${RUN_DIR}" \
        "A=/dev/${A_block}" \
        "B=/dev/${B_block}" \
        "C=/dev/${C_block}" \
        "D=/dev/${D_block}"
}

main "$@"
