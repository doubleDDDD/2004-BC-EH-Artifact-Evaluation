#!/bin/sh
set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH:-}

readonly BC_EH_SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
readonly BC_EH_RUN_ROOT="${BC_EH_RUN_ROOT:-/tmp/bc_eh_test}"
readonly BC_EH_SCSI_DEBUG_ROOT="${BC_EH_RUN_ROOT}/scsi_debug"
readonly BC_EH_COMPLEX_NUM_CHANNELS="${BC_EH_COMPLEX_NUM_CHANNELS:-2}"
readonly BC_EH_COMPLEX_NUM_TARGETS="${BC_EH_COMPLEX_NUM_TARGETS:-2}"
readonly BC_EH_COMPLEX_MAX_LUNS="${BC_EH_COMPLEX_MAX_LUNS:-2}"
readonly BC_EH_COMPLEX_QUEUE_TUNING="${BC_EH_COMPLEX_QUEUE_TUNING:-1}"
readonly BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH="${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH:-64}"
readonly BC_EH_COMPLEX_PER_DISK_NR_REQUESTS="${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS:-64}"
readonly BC_EH_DEFAULT_FIO_IODEPTH="${BC_EH_DEFAULT_FIO_IODEPTH:-128}"
readonly BC_EH_FIO_FAULT_RUNTIME="${BC_EH_FIO_FAULT_RUNTIME:-30}"
readonly BC_EH_FIO_HEALTHY_RUNTIME="${BC_EH_FIO_HEALTHY_RUNTIME:-120}"

BC_EH_RULE_IO_TIMEOUT_ABORT=$(cat <<'EOF'
0 1 28
3 1 28
0 1 2a
3 1 2a
EOF
)

BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL=$(cat <<'EOF'
0 1 28
3 1 28
4 1 28
0 1 2a
3 1 2a
4 1 2a
EOF
)

BC_EH_RULE_BUS_RESET_FAIL=$(cat <<'EOF'
5 1 28
5 1 2a
EOF
)

readonly BC_EH_RULE_IO_TIMEOUT_ABORT
readonly BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL
readonly BC_EH_RULE_BUS_RESET_FAIL

bc_eh_log()
{
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

bc_eh_die()
{
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
    exit 1
}

bc_eh_require_root()
{
    if [ "$(id -u)" -ne 0 ]; then
        bc_eh_die "run this script as root"
    fi
}

bc_eh_resolve_fio_bin()
{
    local candidate

    if [ -n "${FIO_BIN:-}" ] && [ -x "${FIO_BIN}" ]; then
        printf '%s\n' "${FIO_BIN}"
        return 0
    fi

    candidate="$(command -v fio 2>/dev/null || true)"
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    for candidate in "${BC_EH_SCRIPT_DIR}/../fio" /bin/fio /usr/bin/fio; do
        if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

bc_eh_cleanup_scsi_debug_env()
{
    bc_eh_require_root

    mkdir -p "${BC_EH_SCSI_DEBUG_ROOT}"

    if command -v pkill >/dev/null 2>&1; then
        pkill -9 -x fio >/dev/null 2>&1 || true
    fi

    modprobe -r scsi_debug >/dev/null 2>&1 || true
    modprobe -r crc_t10dif >/dev/null 2>&1 || true
}

bc_eh_load_scsi_debug()
{
    local num_channels
    local num_tgts
    local max_luns
    local host_can_queue=""
    local eh_reset_mask_arg=""

    set -- $(bc_eh_topology_geometry)
    num_channels="$1"
    num_tgts="$2"
    max_luns="$3"

    bc_eh_log "modprobe crc_t10dif"
    modprobe crc_t10dif >/dev/null 2>&1 || true

    if [ -n "${SDEBUG_EH_RESET_MASK:-}" ]; then
        eh_reset_mask_arg="eh_reset_mask=${SDEBUG_EH_RESET_MASK}"
    fi

    if bc_eh_should_tune_complextopo_queues; then
        host_can_queue="$(bc_eh_complextopo_host_can_queue)"
    fi

    if [ -n "${host_can_queue}" ]; then
        bc_eh_log "modprobe scsi_debug: num_channels=${num_channels} num_tgts=${num_tgts} max_luns=${max_luns} host_max_queue=${host_can_queue} max_queue=${host_can_queue}${eh_reset_mask_arg:+ ${eh_reset_mask_arg}}"
        modprobe scsi_debug \
            add_host=1 \
            num_channels="${num_channels}" \
            num_tgts="${num_tgts}" \
            max_luns="${max_luns}" \
            host_max_queue="${host_can_queue}" \
            max_queue="${host_can_queue}" \
            dev_size_mb="${SDEBUG_DEV_SIZE_MB:-128}" \
            sector_size="${SDEBUG_SECTOR_SIZE:-512}" \
            dsense="${SDEBUG_DSENSE:-1}" \
            delay="${SDEBUG_DELAY:-1}" \
            ${eh_reset_mask_arg} \
            || bc_eh_die "failed to modprobe scsi_debug"
    else
        bc_eh_log "modprobe scsi_debug: num_channels=${num_channels} num_tgts=${num_tgts} max_luns=${max_luns}${eh_reset_mask_arg:+ ${eh_reset_mask_arg}}"
        modprobe scsi_debug \
            add_host=1 \
            num_channels="${num_channels}" \
            num_tgts="${num_tgts}" \
            max_luns="${max_luns}" \
            dev_size_mb="${SDEBUG_DEV_SIZE_MB:-128}" \
            sector_size="${SDEBUG_SECTOR_SIZE:-512}" \
            dsense="${SDEBUG_DSENSE:-1}" \
            delay="${SDEBUG_DELAY:-1}" \
            ${eh_reset_mask_arg} \
            || bc_eh_die "failed to modprobe scsi_debug"
    fi

    if command -v mdev >/dev/null 2>&1; then
        bc_eh_log "run mdev -s"
        mdev -s || bc_eh_die "mdev -s failed"
    fi

    sleep "${SDEBUG_SETTLE_SECS:-1}"
}

bc_eh_topology_geometry()
{
    case "${BC_EH_TOPOLOGY:-complextopo}" in
        basictopo)
            printf '1 1 1\n'
            ;;
        complextopo)
            printf '%s %s %s\n' \
                "${BC_EH_COMPLEX_NUM_CHANNELS}" \
                "${BC_EH_COMPLEX_NUM_TARGETS}" \
                "${BC_EH_COMPLEX_MAX_LUNS}"
            ;;
        *)
            bc_eh_die "unsupported topology: ${BC_EH_TOPOLOGY}"
            ;;
    esac
}

bc_eh_topology_disk_count()
{
    local num_channels
    local num_tgts
    local max_luns

    set -- $(bc_eh_topology_geometry)
    num_channels="$1"
    num_tgts="$2"
    max_luns="$3"

    printf '%s\n' "$((num_channels * num_tgts * max_luns))"
}

bc_eh_should_tune_complextopo_queues()
{
    [ "${BC_EH_TOPOLOGY:-complextopo}" = "complextopo" ] || return 1
    [ "${BC_EH_COMPLEX_QUEUE_TUNING}" != "0" ] || return 1
    return 0
}

bc_eh_complextopo_host_can_queue()
{
    local disk_count

    disk_count="$(bc_eh_topology_disk_count)"
    printf '%s\n' "$((BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH * disk_count))"
}

bc_eh_fio_iodepth()
{
    if bc_eh_should_tune_complextopo_queues; then
        printf '%s\n' "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
        return 0
    fi

    printf '%s\n' "${BC_EH_DEFAULT_FIO_IODEPTH}"
}

bc_eh_find_scsi_debug_host()
{
    local host_name
    local proc_name

    for host_name in /sys/class/scsi_host/host*; do
        [ -e "${host_name}" ] || continue
        host_name="$(basename "${host_name}")"
        proc_name="$(cat "/sys/class/scsi_host/${host_name}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "scsi_debug" ] || continue
        printf '%s\n' "${host_name}"
        return 0
    done

    return 1
}

bc_eh_wait_scsi_debug_host()
{
    local timeout_secs="${1:-15}"
    local host_name

    while [ "${timeout_secs}" -gt 0 ]; do
        host_name="$(bc_eh_find_scsi_debug_host || true)"
        if [ -n "${host_name}" ]; then
            printf '%s\n' "${host_name}"
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_set_host_eh_mode()
{
    local host_name="$1"
    local mode="$2"
    local mode_file="/sys/class/scsi_host/${host_name}/eh_mode"

    case "${mode}" in
        host|sdev)
            ;;
        *)
            bc_eh_die "unsupported eh mode: ${mode}"
            ;;
    esac

    [ -e "${mode_file}" ] || bc_eh_die "eh_mode file not found: ${mode_file}"
    bc_eh_log "set eh mode: echo ${mode} > ${mode_file}"
    printf '%s\n' "${mode}" > "${mode_file}" || bc_eh_die "failed to set ${mode_file}"
}

bc_eh_find_scsi_id()
{
    local channel="$1"
    local target="$2"
    local lun="$3"
    local dev_dir
    local host_name
    local proc_name
    local scsi_id

    for host_name in /sys/class/scsi_host/host*; do
        [ -e "${host_name}" ] || continue
        host_name="$(basename "${host_name}")"
        proc_name="$(cat "/sys/class/scsi_host/${host_name}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "scsi_debug" ] || continue
        scsi_id="${host_name#host}:${channel}:${target}:${lun}"
        if [ -d "/sys/class/scsi_device/${scsi_id}" ]; then
            printf '%s\n' "${scsi_id}"
            return 0
        fi
    done

    for dev_dir in /sys/class/scsi_device/*:"${channel}":"${target}":"${lun}"; do
        [ -e "${dev_dir}" ] || continue
        scsi_id="$(basename "${dev_dir}")"
        host_name="host${scsi_id%%:*}"
        proc_name="$(cat "/sys/class/scsi_host/${host_name}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "scsi_debug" ] || continue
        printf '%s\n' "${scsi_id}"
        return 0
    done

    return 1
}

bc_eh_wait_scsi_id()
{
    local channel="$1"
    local target="$2"
    local lun="$3"
    local timeout_secs="${4:-15}"
    local scsi_id

    while [ "${timeout_secs}" -gt 0 ]; do
        scsi_id="$(bc_eh_find_scsi_id "${channel}" "${target}" "${lun}" || true)"
        if [ -n "${scsi_id}" ]; then
            printf '%s\n' "${scsi_id}"
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_find_block_device()
{
    local scsi_id="$1"
    local block_dir

    for block_dir in "/sys/class/scsi_device/${scsi_id}"/device/block/*; do
        [ -e "${block_dir}" ] || return 1
        basename "${block_dir}"
        return 0
    done

    return 1
}

bc_eh_wait_block_device()
{
    local scsi_id="$1"
    local timeout_secs="${2:-15}"
    local block_name

    while [ "${timeout_secs}" -gt 0 ]; do
        block_name="$(bc_eh_find_block_device "${scsi_id}" || true)"
        if [ -n "${block_name}" ]; then
            printf '%s\n' "${block_name}"
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_set_queue_depth()
{
    local scsi_id="$1"
    local depth="$2"
    local qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"

    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    bc_eh_log "set queue_depth: echo ${depth} > ${qd_file}"
    printf '%s\n' "${depth}" > "${qd_file}"
}

bc_eh_set_nr_requests()
{
    local block_name="$1"
    local nr="$2"
    local nr_file="/sys/block/${block_name}/queue/nr_requests"

    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    bc_eh_log "set nr_requests: echo ${nr} > ${nr_file}"
    printf '%s\n' "${nr}" > "${nr_file}"
}

bc_eh_configure_complextopo_queues()
{
    local node
    local scsi_id
    local block_name

    bc_eh_should_tune_complextopo_queues || return 0

    for node in $(bc_eh_named_nodes); do
        eval "scsi_id=\${BC_EH_NODE_${node}_SCSI_ID:-}"
        if [ -z "${scsi_id}" ]; then
            scsi_id="$(bc_eh_wait_named_scsi_id "${node}" "${SDEBUG_WAIT_SECS:-15}")" || \
                bc_eh_die "failed to find scsi device for node ${node}"
            eval "BC_EH_NODE_${node}_SCSI_ID='${scsi_id}'"
        fi

        eval "block_name=\${BC_EH_NODE_${node}_BLOCK_NAME:-}"
        if [ -z "${block_name}" ]; then
            block_name="$(bc_eh_wait_block_device "${scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || \
                bc_eh_die "failed to find block device for node ${node}"
            eval "BC_EH_NODE_${node}_BLOCK_NAME='${block_name}'"
        fi

        bc_eh_set_queue_depth "${scsi_id}" "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
        bc_eh_set_nr_requests "${block_name}" "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
    done
}

bc_eh_target_id_from_scsi_id()
{
    printf 'target%s\n' "${1%:*}"
}

bc_eh_set_target_fail_reset()
{
    local target_id="$1"
    local value="$2"
    local fail_file="/sys/kernel/debug/scsi_debug/${target_id}/fail_reset"

    [ -e "${fail_file}" ] || bc_eh_die "target fail_reset file not found: ${fail_file}"
    bc_eh_log "set target fail_reset: echo ${value} > ${fail_file}"
    printf '%s\n' "${value}" > "${fail_file}"
}

bc_eh_set_host_fail_reset()
{
    local host_name="$1"
    local value="$2"
    local fail_file="/sys/kernel/debug/scsi_debug/${host_name}/fail_reset"

    [ -e "${fail_file}" ] || bc_eh_die "host fail_reset file not found: ${fail_file}"
    bc_eh_log "set host fail_reset: echo ${value} > ${fail_file}"
    printf '%s\n' "${value}" > "${fail_file}"
}

bc_eh_apply_error_rules()
{
    local scsi_id="$1"
    local error_rules="$2"
    local error_file="/sys/kernel/debug/scsi_debug/${scsi_id}/error"
    local rule

    [ -n "${error_rules}" ] || return 0
    [ -e "${error_file}" ] || bc_eh_die "debugfs error file not found: ${error_file}"

    while IFS= read -r rule; do
        [ -n "${rule}" ] || continue
        bc_eh_log "inject error: ${rule} -> ${error_file}"
        printf '%s\n' "${rule}" > "${error_file}"
    done <<EOF
${error_rules}
EOF
}

bc_eh_apply_validate_after_reset()
{
    local scsi_id="$1"
    local validate_rules="$2"
    local validate_file="/sys/kernel/debug/scsi_debug/${scsi_id}/validate_after_reset"
    local rule

    [ -n "${validate_rules}" ] || return 0
    [ -e "${validate_file}" ] || bc_eh_die "validate_after_reset file not found: ${validate_file}"

    bc_eh_log "inject validate_after_reset: clear -> ${validate_file}"
    printf 'clear\n' > "${validate_file}"

    while IFS= read -r rule; do
        [ -n "${rule}" ] || continue
        bc_eh_log "inject validate_after_reset: ${rule} -> ${validate_file}"
        printf '%s\n' "${rule}" > "${validate_file}"
    done <<EOF
${validate_rules}
EOF
}

bc_eh_node_coords()
{
    case "${BC_EH_TOPOLOGY:-complextopo}" in
        basictopo)
            case "$1" in
                A) printf '0 0 0\n' ;;
                *)
                    bc_eh_die "unsupported named node for basictopo: $1"
                    ;;
            esac
            ;;
        complextopo)
            case "$1" in
                A) printf '0 0 0\n' ;;
                B) printf '0 0 1\n' ;;
                C) printf '0 1 0\n' ;;
                D) printf '1 0 0\n' ;;
                E) printf '1 1 0\n' ;;
                F) printf '0 1 1\n' ;;
                G) printf '1 0 1\n' ;;
                H) printf '1 1 1\n' ;;
                *)
                    bc_eh_die "unsupported named node: $1"
                    ;;
            esac
            ;;
        *)
            bc_eh_die "unsupported topology: ${BC_EH_TOPOLOGY}"
            ;;
    esac
}

bc_eh_named_nodes()
{
    case "${BC_EH_TOPOLOGY:-complextopo}" in
        basictopo)
            printf '%s\n' 'A'
            ;;
        complextopo)
            printf '%s\n' 'A B C D E F G H'
            ;;
        *)
            bc_eh_die "unsupported topology: ${BC_EH_TOPOLOGY}"
            ;;
    esac
}

bc_eh_wait_named_scsi_id()
{
    local node="$1"
    local timeout_secs="${2:-15}"
    local channel
    local target
    local lun

    set -- $(bc_eh_node_coords "${node}")
    channel="$1"
    target="$2"
    lun="$3"
    bc_eh_wait_scsi_id "${channel}" "${target}" "${lun}" "${timeout_secs}"
}

bc_eh_set_node_error_rules()
{
    local node="$1"
    local rules="$2"

    eval "BC_EH_NODE_${node}_ERROR_RULES=\${rules}"
}

bc_eh_set_node_validate_rules()
{
    local node="$1"
    local rules="$2"

    eval "BC_EH_NODE_${node}_VALIDATE_RULES=\${rules}"
}

bc_eh_node_is_fault_injected()
{
    local node="$1"
    local error_rules
    local validate_rules

    eval "error_rules=\${BC_EH_NODE_${node}_ERROR_RULES}"
    eval "validate_rules=\${BC_EH_NODE_${node}_VALIDATE_RULES}"

    if [ -n "${error_rules}" ] || [ -n "${validate_rules}" ]; then
        return 0
    fi

    case " ${BC_EH_TARGET_FAIL_NODES} " in
        *" ${node} "*)
            return 0
            ;;
    esac

    [ "${node}" = "${BC_EH_PRIMARY_FAULT_NODE}" ]
}

bc_eh_node_fio_runtime()
{
    local node="$1"

    if bc_eh_node_is_fault_injected "${node}"; then
        printf '%s\n' "${BC_EH_FIO_FAULT_RUNTIME}"
        return 0
    fi

    printf '%s\n' "${BC_EH_FIO_HEALTHY_RUNTIME}"
}

bc_eh_reset_case_state()
{
    local node

    BC_EH_CASE_SUPPORTED=1
    BC_EH_CASE_SCOPE_CN=""
    BC_EH_CASE_DESC_CN=""
    BC_EH_CASE_PATH_CN=""
    BC_EH_CASE_NOTE_CN=""
    BC_EH_CASE_UNSUPPORTED_REASON=""
    BC_EH_ACTIVE_NODES=""
    BC_EH_IDLE_NODES="$(bc_eh_named_nodes)"
    BC_EH_PRIMARY_FAULT_NODE=""
    BC_EH_TARGET_FAIL_NODES=""
    BC_EH_CASE_HOST_FAIL_RESET=0

    for node in $(bc_eh_named_nodes); do
        eval "BC_EH_NODE_${node}_ERROR_RULES=''"
        eval "BC_EH_NODE_${node}_VALIDATE_RULES=''"
    done
}

bc_eh_case_config_basictopo()
{
    local case_id="$1"

    case "${case_id}" in
        P1)
            BC_EH_CASE_SCOPE_CN="LUN"
            BC_EH_CASE_DESC_CN="single-device local transient stall, device reset recoverable"
            BC_EH_CASE_PATH_CN="D+"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            ;;
        P2)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="validate the target-reset recovery path in the single-target basic topology"
            BC_EH_CASE_PATH_CN="D- -> T+"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
            ;;
        P3)
            BC_EH_CASE_SCOPE_CN="Host / controller"
            BC_EH_CASE_DESC_CN="validate the host-reset recovery path in the single-device basic topology"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H+"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target/bus/host semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            ;;
        P4)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="device reset returns, post-device TUR validation fails, and target reset recovers"
            BC_EH_CASE_PATH_CN="D+ / V- -> T+"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "device fail 1"
            ;;
        P5)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="device reset returns, post-device TUR times out, and target reset recovers"
            BC_EH_CASE_PATH_CN="D+ / V~ -> T+"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "device timeout 1"
            ;;
        P6)
            BC_EH_CASE_SCOPE_CN="Unrecoverable / multi-level"
            BC_EH_CASE_DESC_CN="all reset levels fail in the single-device basic topology"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H-"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target/bus/host semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A"
            BC_EH_CASE_HOST_FAIL_RESET=1
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            ;;
        P7)
            BC_EH_CASE_SCOPE_CN="Unrecoverable after host reset"
            BC_EH_CASE_DESC_CN="host reset returns but the device still fails validation"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H+ / V-"
            BC_EH_CASE_NOTE_CN="the basic topology has only one target; target/bus/host semantics are approximated through reset levels"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            bc_eh_set_node_validate_rules A "host fail 1"
            ;;
        P8)
            BC_EH_CASE_SCOPE_CN="Permanent single-device failure"
            BC_EH_CASE_DESC_CN="single-device permanent fault, TUR keeps timing out after each reset level"
            BC_EH_CASE_PATH_CN="D+ / V~ -> T+ / V~ -> B+ / V~ -> H+ / V~"
            BC_EH_ACTIVE_NODES="A"
            BC_EH_IDLE_NODES=""
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "device timeout 1
target timeout 1
bus timeout 1
host timeout 1"
            ;;
        *)
            bc_eh_die "unsupported case: ${case_id}"
            ;;
    esac
}

bc_eh_case_config()
{
    local case_id="$1"

    bc_eh_reset_case_state

    case "${BC_EH_TOPOLOGY:-complextopo}" in
        basictopo)
            bc_eh_case_config_basictopo "${case_id}"
            return 0
            ;;
        complextopo)
            ;;
        *)
            bc_eh_die "unsupported topology: ${BC_EH_TOPOLOGY}"
            ;;
    esac

    case "${case_id}" in
        P1)
            BC_EH_CASE_SCOPE_CN="LUN"
            BC_EH_CASE_DESC_CN="single-LUN local transient stall, device reset recoverable"
            BC_EH_CASE_PATH_CN="D+"
            BC_EH_ACTIVE_NODES="A B"
            BC_EH_IDLE_NODES="C D E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            ;;
        P2)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="shared-state fault within the same target, device reset fails, target reset recovers"
            BC_EH_CASE_PATH_CN="D- -> T+"
            BC_EH_ACTIVE_NODES="A B C"
            BC_EH_IDLE_NODES="D E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}"
            ;;
        P3)
            BC_EH_CASE_SCOPE_CN="Host / controller"
            BC_EH_CASE_DESC_CN="host/controller-level transient fault, lower-level resets cannot recover, and host reset eventually succeeds"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H+"
            BC_EH_ACTIVE_NODES="A B C D"
            BC_EH_IDLE_NODES="E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A C D"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules D "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            ;;
        P4)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="device reset returns, post-device TUR validation fails, and target reset recovers"
            BC_EH_CASE_PATH_CN="D+ / V- -> T+"
            BC_EH_ACTIVE_NODES="A B C"
            BC_EH_IDLE_NODES="D E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "device fail 1"
            bc_eh_set_node_validate_rules B "device fail 1"
            ;;
        P5)
            BC_EH_CASE_SCOPE_CN="Target"
            BC_EH_CASE_DESC_CN="device reset returns, post-device TUR times out, and target reset recovers"
            BC_EH_CASE_PATH_CN="D+ / V~ -> T+"
            BC_EH_ACTIVE_NODES="A B C"
            BC_EH_IDLE_NODES="D E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "device timeout 1"
            bc_eh_set_node_validate_rules B "device timeout 1"
            ;;
        P6)
            BC_EH_CASE_SCOPE_CN="Unrecoverable / multi-level"
            BC_EH_CASE_DESC_CN="persistent host-level fault, all reset levels fail"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H-"
            BC_EH_ACTIVE_NODES="A B C D"
            BC_EH_IDLE_NODES="E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A C D"
            BC_EH_CASE_HOST_FAIL_RESET=1
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules D "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            ;;
        P7)
            BC_EH_CASE_SCOPE_CN="Unrecoverable after host reset"
            BC_EH_CASE_DESC_CN="host reset returns but the device still fails validation"
            BC_EH_CASE_PATH_CN="D- -> T- -> B- -> H+ / V-"
            BC_EH_ACTIVE_NODES="A B C D"
            BC_EH_IDLE_NODES="E F G H"
            BC_EH_PRIMARY_FAULT_NODE="A"
            BC_EH_TARGET_FAIL_NODES="A C D"
            bc_eh_set_node_error_rules A "${BC_EH_RULE_IO_TIMEOUT_ABORT_LUNRESET_FAIL}
${BC_EH_RULE_BUS_RESET_FAIL}"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules C "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_error_rules D "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules A "host fail 1"
            ;;
        P8)
            BC_EH_CASE_SCOPE_CN="Permanent single-device failure"
            BC_EH_CASE_DESC_CN="single-device permanent fault, TUR keeps timing out after each reset level"
            BC_EH_CASE_PATH_CN="D+ / V~ -> T+ / V~ -> B+ / V~ -> H+ / V~"
            BC_EH_ACTIVE_NODES="A B"
            BC_EH_IDLE_NODES="C D E F G H"
            BC_EH_PRIMARY_FAULT_NODE="B"
            bc_eh_set_node_error_rules B "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
            bc_eh_set_node_validate_rules B "device timeout 1
target timeout 1
bus timeout 1
host timeout 1"
            ;;
        *)
            bc_eh_die "unsupported case: ${case_id}"
            ;;
    esac
}

bc_eh_run_fio_on_named_devices()
{
    local run_dir="$1"
    shift

    local fio_bin
    local fio_dir
    local fio_name
    local spec
    local node
    local device
    local runtime
    local iodepth
    local pid
    local pids=""
    local status=0

    [ "$#" -gt 0 ] || bc_eh_die "no active devices provided for fio"

    fio_bin="$(bc_eh_resolve_fio_bin)" || bc_eh_die "fio binary not found"
    fio_dir="$(dirname "${fio_bin}")"
    fio_name="$(basename "${fio_bin}")"
    iodepth="$(bc_eh_fio_iodepth)"

    mkdir -p "${run_dir}"

    for spec in "$@"; do
        node="${spec%%=*}"
        device="${spec#*=}"
        runtime="$(bc_eh_node_fio_runtime "${node}")"
        bc_eh_log "run fio(${node}): cd ${fio_dir} && ./${fio_name} --filename=${device} --ioengine=libaio --direct=1 --iodepth=${iodepth} --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=${runtime} --group_reporting --name=randread_4k_${node}"
        (
            cd "${fio_dir}" &&
            "./${fio_name}" \
                "--filename=${device}" \
                "--ioengine=libaio" \
                "--direct=1" \
                "--iodepth=${iodepth}" \
                "--rw=randread" \
                "--bs=4k" \
                "--numjobs=1" \
                "--thread" \
                "--size=100%" \
                "--time_based" \
                "--runtime=${runtime}" \
                "--group_reporting" \
                "--name=randread_4k_${node}"
        ) &
        pid=$!
        pids="${pids} ${pid}"
    done

    for pid in ${pids}; do
        wait "${pid}" || status=1
    done

    [ "${status}" -eq 0 ] || bc_eh_die "fio failed"
    bc_eh_log "fio done"
}
