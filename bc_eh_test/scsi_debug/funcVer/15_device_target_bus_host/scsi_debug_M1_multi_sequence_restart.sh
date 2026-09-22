#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 15_device_target_bus_host (all four reset handlers implemented: device / target / bus / host)
# - Special case: M1, stable multi-sequence restart
# - Goal: reliably verify that the first sequence has entered reset phase and no longer accepts pending faults,
#   later faults must wait for the previous sequence to finish, then restart a second sequence from pending faults"
# - Key synchronization method:
#   1. first let A/B/C drive the first sequence to bus reset
#   2. watch for this kernel log message `scsi_eh_schannel_reset: schannel(<host_no>:0) RESET!`
#   3. inject the delayed fault into D only after seeing this log
# - Expected log keywords:
#   1. enqueue pending fault ... action=wait_next_sequence
#   2. scsi_eh_finish_work_sequence: sdev(...) restart EH from pending fault
# - Note:
#   this case focuses on reliably creating multiple sequences, not on fixing the final reset level of the second sequence

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="M1_multi_sequence_restart"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/funcVer/15_device_target_bus_host/${CASE_ID}"
readonly RESET_WAIT_SECS="${BC_EH_MULTI_SEQ_RESET_WAIT_SECS:-30}"
readonly KMSG_POLL_INTERVAL_SECS="${BC_EH_MULTI_SEQ_POLL_INTERVAL_SECS:-1}"

KMSG_PID=""
INJECTOR_PID=""

bc_eh_wait_for_reset_phase_log()
{
    local log_file="$1"
    local pattern="$2"
    local timeout_secs="$3"

    while [ "${timeout_secs}" -gt 0 ]; do
        if grep -Fq "${pattern}" "${log_file}"; then
            return 0
        fi
        sleep "${KMSG_POLL_INTERVAL_SECS}"
        timeout_secs=$((timeout_secs - KMSG_POLL_INTERVAL_SECS))
    done

    return 1
}

cleanup()
{
    if [ -n "${INJECTOR_PID}" ]; then
        kill "${INJECTOR_PID}" >/dev/null 2>&1 || true
        wait "${INJECTOR_PID}" >/dev/null 2>&1 || true
    fi
    if [ -n "${KMSG_PID}" ]; then
        kill "${KMSG_PID}" >/dev/null 2>&1 || true
        wait "${KMSG_PID}" >/dev/null 2>&1 || true
    fi
}

main()
{
    local scsi_debug_host
    local host_no
    local kmsg_log
    local A_scsi_id B_scsi_id C_scsi_id D_scsi_id
    local A_block B_block C_block D_block
    local reset_log_pattern

    trap cleanup EXIT INT TERM

    bc_eh_reset_case_state
    bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT}"

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"
    kmsg_log="${RUN_DIR}/kmsg.log"

    export SDEBUG_EH_RESET_MASK=0xf

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "sdev"
    host_no="${scsi_debug_host#host}"

    A_scsi_id="$(bc_eh_wait_named_scsi_id A "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node A"
    B_scsi_id="$(bc_eh_wait_named_scsi_id B "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node B"
    C_scsi_id="$(bc_eh_wait_named_scsi_id C "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node C"
    D_scsi_id="$(bc_eh_wait_named_scsi_id D "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find node D"

    A_block="$(bc_eh_wait_block_device "${A_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for A"
    B_block="$(bc_eh_wait_block_device "${B_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for B"
    C_block="$(bc_eh_wait_block_device "${C_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for C"
    D_block="$(bc_eh_wait_block_device "${D_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block for D"

    # intentionally hold one device during the TUR tail of the first bus reset to widen the reset-phase window,
    # make the later fault on D reliably land in the `accepting_pending=0` stage.
    bc_eh_apply_validate_after_reset "${A_scsi_id}" "bus timeout 1"
    bc_eh_apply_error_rules "${A_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_apply_error_rules "${B_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    bc_eh_apply_error_rules "${C_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"

    reset_log_pattern="scsi_eh_schannel_reset: schannel(${host_no}:0) RESET!"

    {
        printf 'case_id=%s\n' "${CASE_ID}"
        printf 'group=15_device_target_bus_host\n'
        printf 'eh_reset_mask=0xf\n'
        printf 'eh_mode=sdev\n'
        printf 'reset_wait_secs=%s\n' "${RESET_WAIT_SECS}"
        printf 'kmsg_poll_interval_secs=%s\n' "${KMSG_POLL_INTERVAL_SECS}"
        printf 'first_sequence_fault_nodes=A,B,C\n'
        printf 'late_fault_node=D\n'
        printf 'reset_phase_sync_log=%s\n' "${reset_log_pattern}"
        printf 'host=%s\n' "${scsi_debug_host}"
        printf 'A=%s /dev/%s\n' "${A_scsi_id}" "${A_block}"
        printf 'B=%s /dev/%s\n' "${B_scsi_id}" "${B_block}"
        printf 'C=%s /dev/%s\n' "${C_scsi_id}" "${C_block}"
        printf 'D=%s /dev/%s\n' "${D_scsi_id}" "${D_block}"
    } > "${RUN_DIR}/metadata"

    # clear the old ring buffer and keep only kernel logs from this test, making reset-phase synchronization stable.
    dmesg -c >/dev/null 2>&1 || true
    dmesg -w > "${kmsg_log}" &
    KMSG_PID=$!

    (
        bc_eh_wait_for_reset_phase_log "${kmsg_log}" "${reset_log_pattern}" "${RESET_WAIT_SECS}" || \
            bc_eh_die "timed out waiting for reset phase log: ${reset_log_pattern}"
        bc_eh_log "reset phase observed, inject late fault into D to force next sequence restart"
        bc_eh_apply_error_rules "${D_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    ) &
    INJECTOR_PID=$!

    bc_eh_log "run ${CASE_ID}: A=/dev/${A_block} B=/dev/${B_block} C=/dev/${C_block} D=/dev/${D_block}"
    bc_eh_run_fio_on_named_devices "${RUN_DIR}" \
        "A=/dev/${A_block}" \
        "B=/dev/${B_block}" \
        "C=/dev/${C_block}" \
        "D=/dev/${D_block}"

    wait "${INJECTOR_PID}"
    INJECTOR_PID=""
}

main "$@"
