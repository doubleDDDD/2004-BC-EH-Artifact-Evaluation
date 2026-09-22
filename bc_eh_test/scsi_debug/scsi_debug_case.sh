#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/scsi_debug_common.sh"

: "${BC_EH_CASE:?BC_EH_CASE is required}"
: "${BC_EH_MODE_VALUE:?BC_EH_MODE_VALUE is required}"
: "${BC_EH_PROFILE:?BC_EH_PROFILE is required}"
: "${BC_EH_TOPOLOGY:=complextopo}"
: "${BC_EH_RUN_GROUP:=${BC_EH_TOPOLOGY}/${BC_EH_PROFILE}}"

main()
{
    local run_dir
    local case_name
    local scsi_debug_host
    local node
    local scsi_id
    local block_name
    local target_id
    local error_rules
    local validate_rules
    local active_spec_list=""
    local primary_scsi_id=""
    local primary_block_name=""

    bc_eh_case_config "${BC_EH_CASE}"

    run_dir="${BC_EH_SCSI_DEBUG_ROOT}/${BC_EH_RUN_GROUP}/${BC_EH_CASE}"
    case_name="scsi_debug_${BC_EH_PROFILE}_${BC_EH_CASE}_${BC_EH_TOPOLOGY}"

    rm -rf "${run_dir}"
    mkdir -p "${run_dir}"

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "${BC_EH_MODE_VALUE}"

    for node in $(bc_eh_named_nodes); do
        scsi_id="$(bc_eh_wait_named_scsi_id "${node}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi device for node ${node}"
        block_name="$(bc_eh_wait_block_device "${scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block device for node ${node}"
        eval "BC_EH_NODE_${node}_SCSI_ID='${scsi_id}'"
        eval "BC_EH_NODE_${node}_BLOCK_NAME='${block_name}'"
    done

    bc_eh_configure_complextopo_queues

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
        printf 'case_name=%s\n' "${case_name}"
        printf 'case_id=%s\n' "${BC_EH_CASE}"
        printf 'profile=%s\n' "${BC_EH_PROFILE}"
        printf 'topology=%s\n' "${BC_EH_TOPOLOGY}"
        printf 'fault_scope=%s\n' "${BC_EH_CASE_SCOPE_CN}"
        printf 'fault_desc=%s\n' "${BC_EH_CASE_DESC_CN}"
        printf 'path_expr=%s\n' "${BC_EH_CASE_PATH_CN}"
        printf 'note=%s\n' "${BC_EH_CASE_NOTE_CN}"
        printf 'eh_mode=%s\n' "${BC_EH_MODE_VALUE}"
        printf 'active_nodes=%s\n' "${BC_EH_ACTIVE_NODES}"
        printf 'idle_nodes=%s\n' "${BC_EH_IDLE_NODES}"
        printf 'primary_fault_node=%s\n' "${BC_EH_PRIMARY_FAULT_NODE}"
        printf 'target_fail_nodes=%s\n' "${BC_EH_TARGET_FAIL_NODES}"
        printf 'host_fail_reset=%s\n' "${BC_EH_CASE_HOST_FAIL_RESET}"
        if bc_eh_should_tune_complextopo_queues; then
            printf 'per_disk_queue_depth=%s\n' "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
            printf 'per_disk_nr_requests=%s\n' "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
            printf 'host_can_queue=%s\n' "$(bc_eh_complextopo_host_can_queue)"
            printf 'fio_iodepth=%s\n' "$(bc_eh_fio_iodepth)"
        fi
        printf 'scsi_debug_host=%s\n' "${scsi_debug_host}"
    } > "${run_dir}/metadata"

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
        } >> "${run_dir}/metadata"
    done

    eval "primary_scsi_id=\${BC_EH_NODE_${BC_EH_PRIMARY_FAULT_NODE}_SCSI_ID}"
    eval "primary_block_name=\${BC_EH_NODE_${BC_EH_PRIMARY_FAULT_NODE}_BLOCK_NAME}"
    {
        printf 'primary_fault_scsi_id=%s\n' "${primary_scsi_id}"
        printf 'primary_fault_device=/dev/%s\n' "${primary_block_name}"
    } >> "${run_dir}/metadata"

    set --
    for node in ${BC_EH_ACTIVE_NODES}; do
        eval "block_name=\${BC_EH_NODE_${node}_BLOCK_NAME}"
        set -- "$@" "${node}=/dev/${block_name}"
        if [ -n "${active_spec_list}" ]; then
            active_spec_list="${active_spec_list} "
        fi
        active_spec_list="${active_spec_list}${node}=/dev/${block_name}"
    done

    printf 'active_devices=%s\n' "${active_spec_list}" >> "${run_dir}/metadata"
    bc_eh_log "run ${BC_EH_PROFILE}/${BC_EH_CASE}: active=${active_spec_list}"
    bc_eh_run_fio_on_named_devices "${run_dir}" "$@"
}

main "$@"
