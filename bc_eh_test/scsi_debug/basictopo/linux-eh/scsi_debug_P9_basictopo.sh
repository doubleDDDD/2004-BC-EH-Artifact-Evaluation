#!/bin/sh
set -eu

# Fault scenario:
# - Paper extension case: P9, basictopo projection of a single-channel shared fault
# - Topology: basictopo (1host_1ch_1tgt_1lun, only A=<host_no>:0:0:0)
# - Fault-injection style follows complextopo/linux-eh  P9 style:
#   A gets persistent IO timeout / abort, and target reset for the only target is set to fail,
#   make native linux-eh follow the fixed escalation chain to bus reset
# - Note:
#   basictopo has no healthy cross-channel control, so this script keeps only the main P9 fault-injection style,
#   it is not used to prove the complete channel-vs-host boundary-convergence semantics
# - Fault node: A
# - Expected recovery chain: D- -> T- -> B+

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
