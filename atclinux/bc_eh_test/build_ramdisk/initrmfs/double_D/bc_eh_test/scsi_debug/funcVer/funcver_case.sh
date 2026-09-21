#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../scsi_debug_common.sh"

: "${FUNCVER_GROUP:?FUNCVER_GROUP is required}"
: "${FUNCVER_CASE_ID:?FUNCVER_CASE_ID is required}"
: "${FUNCVER_EH_RESET_MASK:?FUNCVER_EH_RESET_MASK is required}"
: "${FUNCVER_EXPECT_PATH:?FUNCVER_EXPECT_PATH is required}"
: "${FUNCVER_ACTIVE_NODES:?FUNCVER_ACTIVE_NODES is required}"
: "${FUNCVER_DESC:?FUNCVER_DESC is required}"

readonly FUNCVER_EH_MODE="${FUNCVER_EH_MODE:-sdev}"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/funcVer/${FUNCVER_GROUP}/${FUNCVER_CASE_ID}"

bc_eh_funcver_list_contains()
{
    local needle="$1"
    local haystack="$2"

    case " ${haystack} " in
        *" ${needle} "*)
            return 0
            ;;
    esac

    return 1
}

bc_eh_funcver_collect_idle_nodes()
{
    local active_nodes="$1"
    local node
    local idle_nodes=""

    for node in $(bc_eh_named_nodes); do
        if bc_eh_funcver_list_contains "${node}" "${active_nodes}"; then
            continue
        fi
        if [ -n "${idle_nodes}" ]; then
            idle_nodes="${idle_nodes} "
        fi
        idle_nodes="${idle_nodes}${node}"
    done

    printf '%s\n' "${idle_nodes}"
}

bc_eh_funcver_first_fault_node()
{
    local list_name
    local node

    for list_name in \
        "${FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES:-}" \
        "${FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES:-}" \
        "${FUNCVER_RULE_BUS_RESET_FAIL_NODES:-}" \
        "${FUNCVER_TARGET_FAIL_NODES:-}"
    do
        for node in ${list_name}; do
            printf '%s\n' "${node}"
            return 0
        done
    done

    printf '\n'
}

bc_eh_funcver_append_node_error_rules()
{
    local node="$1"
    local extra_rules="$2"
    local merged_rules

    eval "merged_rules=\${BC_EH_NODE_${node}_ERROR_RULES}"
    if [ -n "${merged_rules}" ] && [ -n "${extra_rules}" ]; then
        merged_rules="${merged_rules}
${extra_rules}"
    else
        merged_rules="${merged_rules}${extra_rules}"
    fi

    bc_eh_set_node_error_rules "${node}" "${merged_rules}"
}

bc_eh_funcver_init_case_state()
{
    local node

    bc_eh_reset_case_state

    BC_EH_CASE_SCOPE_CN="funcVer/${FUNCVER_GROUP}"
    BC_EH_CASE_DESC_CN="${FUNCVER_DESC}"
    BC_EH_CASE_PATH_CN="${FUNCVER_EXPECT_PATH}"
    BC_EH_ACTIVE_NODES="${FUNCVER_ACTIVE_NODES}"
    BC_EH_IDLE_NODES="$(bc_eh_funcver_collect_idle_nodes "${FUNCVER_ACTIVE_NODES}")"
    BC_EH_PRIMARY_FAULT_NODE="$(bc_eh_funcver_first_fault_node)"
    BC_EH_TARGET_FAIL_NODES="${FUNCVER_TARGET_FAIL_NODES:-}"
    BC_EH_CASE_HOST_FAIL_RESET="${FUNCVER_HOST_FAIL_RESET:-0}"

    for node in ${FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES:-}; do
        bc_eh_set_node_error_rules "${node}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
    done

    for node in ${FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES:-}; do
        bc_eh_set_node_error_rules "${node}" "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
    done

    for node in ${FUNCVER_RULE_BUS_RESET_FAIL_NODES:-}; do
        bc_eh_funcver_append_node_error_rules "${node}" "${BC_EH_RULE_BUS_RESET_FAIL}"
    done
}

main()
{
    local scsi_debug_host
    local node
    local scsi_id
    local block_name
    local target_id
    local error_rules
    local validate_rules
    local active_spec_list=""

    bc_eh_funcver_init_case_state

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"

    export SDEBUG_EH_RESET_MASK="${FUNCVER_EH_RESET_MASK}"

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "${FUNCVER_EH_MODE}"

    for node in $(bc_eh_named_nodes); do
        scsi_id="$(bc_eh_wait_named_scsi_id "${node}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi device for node ${node}"
        block_name="$(bc_eh_wait_block_device "${scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block device for node ${node}"
        eval "BC_EH_NODE_${node}_SCSI_ID='${scsi_id}'"
        eval "BC_EH_NODE_${node}_BLOCK_NAME='${block_name}'"
    done

    for node in ${BC_EH_TARGET_FAIL_NODES}; do
        eval "scsi_id=\${BC_EH_NODE_${node}_SCSI_ID}"
        target_id="$(bc_eh_target_id_from_scsi_id "${scsi_id}")"
        bc_eh_set_target_fail_reset "${target_id}" 1
    done

    if [ "${BC_EH_CASE_HOST_FAIL_RESET}" -eq 1 ]; then
        bc_eh_set_host_fail_reset "${scsi_debug_host}" 1
    fi

    for node in $(bc_eh_named_nodes); do
        eval "scsi_id=\${BC_EH_NODE_${node}_SCSI_ID}"
        eval "validate_rules=\${BC_EH_NODE_${node}_VALIDATE_RULES}"
        eval "error_rules=\${BC_EH_NODE_${node}_ERROR_RULES}"

        bc_eh_apply_validate_after_reset "${scsi_id}" "${validate_rules}"
        bc_eh_apply_error_rules "${scsi_id}" "${error_rules}"
    done

    {
        printf 'case_id=%s\n' "${FUNCVER_CASE_ID}"
        printf 'group=%s\n' "${FUNCVER_GROUP}"
        printf 'desc=%s\n' "${FUNCVER_DESC}"
        printf 'expect_path=%s\n' "${FUNCVER_EXPECT_PATH}"
        printf 'eh_reset_mask=%s\n' "${FUNCVER_EH_RESET_MASK}"
        printf 'eh_mode=%s\n' "${FUNCVER_EH_MODE}"
        printf 'active_nodes=%s\n' "${BC_EH_ACTIVE_NODES}"
        printf 'idle_nodes=%s\n' "${BC_EH_IDLE_NODES}"
        printf 'fault_timeout_abort_nodes=%s\n' "${FUNCVER_RULE_IO_TIMEOUT_ABORT_NODES:-}"
        printf 'fault_lunreset_fail_nodes=%s\n' "${FUNCVER_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL_NODES:-}"
        printf 'fault_bus_reset_fail_nodes=%s\n' "${FUNCVER_RULE_BUS_RESET_FAIL_NODES:-}"
        printf 'target_fail_nodes=%s\n' "${BC_EH_TARGET_FAIL_NODES}"
        printf 'host_fail_reset=%s\n' "${BC_EH_CASE_HOST_FAIL_RESET}"
        printf 'host=%s\n' "${scsi_debug_host}"
    } > "${RUN_DIR}/metadata"

    for node in $(bc_eh_named_nodes); do
        eval "scsi_id=\${BC_EH_NODE_${node}_SCSI_ID}"
        eval "block_name=\${BC_EH_NODE_${node}_BLOCK_NAME}"
        eval "validate_rules=\${BC_EH_NODE_${node}_VALIDATE_RULES}"
        eval "error_rules=\${BC_EH_NODE_${node}_ERROR_RULES}"
        {
            printf 'node_%s_scsi_id=%s\n' "${node}" "${scsi_id}"
            printf 'node_%s_device=/dev/%s\n' "${node}" "${block_name}"
            printf 'node_%s_validate_begin\n' "${node}"
            printf '%s\n' "${validate_rules}"
            printf 'node_%s_validate_end\n' "${node}"
            printf 'node_%s_error_begin\n' "${node}"
            printf '%s\n' "${error_rules}"
            printf 'node_%s_error_end\n' "${node}"
        } >> "${RUN_DIR}/metadata"
    done

    set --
    for node in ${BC_EH_ACTIVE_NODES}; do
        eval "block_name=\${BC_EH_NODE_${node}_BLOCK_NAME}"
        set -- "$@" "${node}=/dev/${block_name}"
        if [ -n "${active_spec_list}" ]; then
            active_spec_list="${active_spec_list} "
        fi
        active_spec_list="${active_spec_list}${node}=/dev/${block_name}"
    done

    printf 'active_devices=%s\n' "${active_spec_list}" >> "${RUN_DIR}/metadata"
    bc_eh_log "run ${FUNCVER_GROUP}/${FUNCVER_CASE_ID}: active=${active_spec_list}"
    bc_eh_run_fio_on_named_devices "${RUN_DIR}" "$@"
}

main "$@"
