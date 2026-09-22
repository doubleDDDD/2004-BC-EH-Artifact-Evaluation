#!/bin/sh
set -eu

# Fault scenario:
# - Functional validation group: 15_device_target_bus_host (all four reset handlers implemented: device / target / bus / host)
# - Special case: S1, scope-matched absorb before reset
# - Goal: Verify that after the host has entered EH_QUIESCE but before reset work starts, a late fault first enters the pending queue,
#   and is absorbed at host scope in `scsi_eh_queue_reset_work()`
# - Key synchronization method:
#   1. A/B/C fail from the beginning and push the sequence toward host scope
#   2. watch for `update_eh_field_to_host START`
#   3. inject the fault into D only after the host has entered EH_QUIESCE
# - Expected log keywords:
#   1. enqueue pending fault ... action=may_be_absorbed_by_current_sequence
#   2. absorb scope-matched pending faults before reset, level=EH_SHOST

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="S1_scope_matched_absorb_before_reset"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/funcVer/15_device_target_bus_host/${CASE_ID}"
readonly WAIT_SECS="${BC_EH_SCOPE_ABSORB_WAIT_SECS:-30}"
readonly POLL_INTERVAL_SECS="${BC_EH_SCOPE_ABSORB_POLL_INTERVAL_SECS:-1}"

KMSG_PID=""
INJECTOR_PID=""

wait_for_log()
{
    local log_file="$1"
    local pattern="$2"
    local timeout_secs="$3"

    while [ "${timeout_secs}" -gt 0 ]; do
        if grep -Fq "${pattern}" "${log_file}"; then
            return 0
        fi
        sleep "${POLL_INTERVAL_SECS}"
        timeout_secs=$((timeout_secs - POLL_INTERVAL_SECS))
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
    local kmsg_log
    local A_scsi_id B_scsi_id C_scsi_id D_scsi_id
    local A_block B_block C_block D_block
    local A_rules

    trap cleanup EXIT INT TERM

    bc_eh_reset_case_state
    A_rules="${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
    bc_eh_set_node_error_rules A "${A_rules}"
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
        printf 'wait_secs=%s\n' "${WAIT_SECS}"
        printf 'seed_fault_nodes=A,B,C\n'
        printf 'late_fault_node=D\n'
        printf 'expect_log_1=enqueue pending fault ... may_be_absorbed_by_current_sequence\n'
        printf 'expect_log_2=absorb scope-matched pending faults before reset, level=EH_SHOST\n'
        printf 'host=%s\n' "${scsi_debug_host}"
        printf 'A=%s /dev/%s\n' "${A_scsi_id}" "${A_block}"
        printf 'B=%s /dev/%s\n' "${B_scsi_id}" "${B_block}"
        printf 'C=%s /dev/%s\n' "${C_scsi_id}" "${C_block}"
        printf 'D=%s /dev/%s\n' "${D_scsi_id}" "${D_block}"
    } > "${RUN_DIR}/metadata"

    dmesg -c >/dev/null 2>&1 || true
    dmesg -w > "${kmsg_log}" &
    KMSG_PID=$!

    (
        wait_for_log "${kmsg_log}" "update_eh_field_to_host START" "${WAIT_SECS}" || \
            bc_eh_die "timed out waiting for update_eh_field_to_host START"
        bc_eh_log "host entered EH_QUIESCE, inject late fault into D for scope-matched absorb"
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
