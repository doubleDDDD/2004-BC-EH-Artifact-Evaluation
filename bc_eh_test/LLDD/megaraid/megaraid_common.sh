#!/bin/sh
set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH:-}

readonly BC_EH_SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
readonly BC_EH_RUN_ROOT="${BC_EH_RUN_ROOT:-/tmp/bc_eh_test}"
readonly BC_EH_MEGA_ROOT="${BC_EH_MEGA_ROOT:-${BC_EH_RUN_ROOT}/megaraid}"
readonly BC_EH_MEGA_FIO_BIN="${BC_EH_MEGA_FIO_BIN:-$(command -v fio || true)}"
readonly BC_EH_MEGA_HOST_TIMEOUT="${BC_EH_MEGA_HOST_TIMEOUT:-15}"

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
    [ "$(id -u)" -eq 0 ] || bc_eh_die "run this script as root"
}

bc_eh_require_fio()
{
    [ -n "${BC_EH_MEGA_FIO_BIN}" ] || bc_eh_die "fio not found"
    [ -x "${BC_EH_MEGA_FIO_BIN}" ] || bc_eh_die "fio is not executable: ${BC_EH_MEGA_FIO_BIN}"
}

bc_eh_mega_param_path()
{
    printf '/sys/module/megaraid_sas/parameters/%s\n' "$1"
}

bc_eh_mega_write_param()
{
    local name="$1"
    local value="$2"
    local path

    path="$(bc_eh_mega_param_path "${name}")"
    [ -e "${path}" ] || bc_eh_die "module parameter not found: ${path}"
    printf '%s\n' "${value}" > "${path}"
}

bc_eh_mega_read_param()
{
    local name="$1"
    local path

    path="$(bc_eh_mega_param_path "${name}")"
    [ -e "${path}" ] || bc_eh_die "module parameter not found: ${path}"
    cat "${path}"
}

bc_eh_mega_mark()
{
    local message="$1"

    if [ -w /dev/kmsg ]; then
        printf 'bc_eh_megaraid %s\n' "${message}" > /dev/kmsg
    fi
}

bc_eh_mega_find_host()
{
    local host_dir
    local proc_name

    if [ -n "${BC_EH_MEGA_HOST:-}" ]; then
        [ -d "/sys/class/scsi_host/${BC_EH_MEGA_HOST}" ] || \
            bc_eh_die "configured host not found: ${BC_EH_MEGA_HOST}"
        printf '%s\n' "${BC_EH_MEGA_HOST}"
        return 0
    fi

    for host_dir in /sys/class/scsi_host/host*; do
        [ -e "${host_dir}" ] || continue
        proc_name="$(cat "${host_dir}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "megaraid_sas" ] || continue
        printf '%s\n' "$(basename "${host_dir}")"
        return 0
    done

    return 1
}

bc_eh_mega_wait_host()
{
    local timeout_secs="${1:-15}"
    local host_name

    while [ "${timeout_secs}" -gt 0 ]; do
        host_name="$(bc_eh_mega_find_host || true)"
        if [ -n "${host_name}" ]; then
            printf '%s\n' "${host_name}"
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_mega_set_eh_mode()
{
    local host_name="$1"
    local mode="$2"
    local path="/sys/class/scsi_host/${host_name}/eh_mode"

    [ -e "${path}" ] || bc_eh_die "eh_mode sysfs not found: ${path}"
    printf '%s\n' "${mode}" > "${path}"
}

bc_eh_mega_block_name_from_dev()
{
    local dev_path="$1"
    basename "$(readlink -f "${dev_path}")"
}

bc_eh_mega_scsi_id_from_dev()
{
    local dev_path="$1"
    local block_name
    local dev_link

    block_name="$(bc_eh_mega_block_name_from_dev "${dev_path}")"
    dev_link="$(readlink -f "/sys/block/${block_name}/device")" || \
        bc_eh_die "failed to resolve scsi device for ${dev_path}"
    basename "${dev_link}"
}

bc_eh_mega_target_id_from_scsi_id()
{
    local scsi_id="$1"
    local host channel target lun

    IFS=: read -r host channel target lun <<EOF
${scsi_id}
EOF
    printf '%s\n' "$(( (channel % 2) * 128 + target ))"
}

bc_eh_mega_lun_from_scsi_id()
{
    local scsi_id="$1"
    local host channel target lun

    IFS=: read -r host channel target lun <<EOF
${scsi_id}
EOF
    printf '%s\n' "${lun}"
}

bc_eh_mega_host_from_scsi_id()
{
    local scsi_id="$1"
    local host channel target lun

    IFS=: read -r host channel target lun <<EOF
${scsi_id}
EOF
    printf 'host%s\n' "${host}"
}

bc_eh_mega_target_id_from_dev()
{
    bc_eh_mega_target_id_from_scsi_id "$(bc_eh_mega_scsi_id_from_dev "$1")"
}

bc_eh_mega_host_from_dev()
{
    bc_eh_mega_host_from_scsi_id "$(bc_eh_mega_scsi_id_from_dev "$1")"
}

bc_eh_mega_require_megaraid_dev()
{
    local dev_path="$1"
    local host_name
    local proc_name

    host_name="$(bc_eh_mega_host_from_dev "${dev_path}")"
    proc_name="$(cat "/sys/class/scsi_host/${host_name}/proc_name" 2>/dev/null || true)"
    [ "${proc_name}" = "megaraid_sas" ] || \
        bc_eh_die "device ${dev_path} is not on a megaraid_sas host"
}

bc_eh_mega_autodetect_devices()
{
    local host_name="$1"
    local tmp
    local sys_block
    local block_name
    local dev_path
    local scsi_id
    local dev_host
    local lun
    local target
    local line_count

    tmp="$(mktemp)"
    for sys_block in /sys/block/sd*; do
        [ -e "${sys_block}" ] || continue
        block_name="$(basename "${sys_block}")"
        dev_path="/dev/${block_name}"
        scsi_id="$(bc_eh_mega_scsi_id_from_dev "${dev_path}")"
        dev_host="$(bc_eh_mega_host_from_scsi_id "${scsi_id}")"
        [ "${dev_host}" = "${host_name}" ] || continue
        lun="$(bc_eh_mega_lun_from_scsi_id "${scsi_id}")"
        [ "${lun}" = "0" ] || continue
        target="$(bc_eh_mega_target_id_from_scsi_id "${scsi_id}")"
        printf '%s %s\n' "${target}" "${dev_path}" >> "${tmp}"
    done

    line_count="$(wc -l < "${tmp}" | tr -d ' ')"
    [ "${line_count}" -ge 2 ] || {
        rm -f "${tmp}"
        bc_eh_die "failed to autodetect two megaraid logical devices; set BC_EH_MEGA_FAULT_DEV and BC_EH_MEGA_HEALTHY_DEV"
    }

    sort -n "${tmp}" | awk 'NR==1 { print $2 } NR==2 { print $2 }'
    rm -f "${tmp}"
}

bc_eh_mega_resolve_devices()
{
    local host_name="$1"
    local fault_dev
    local healthy_dev

    fault_dev="${BC_EH_MEGA_FAULT_DEV:-}"
    healthy_dev="${BC_EH_MEGA_HEALTHY_DEV:-}"

    if [ -n "${fault_dev}" ] || [ -n "${healthy_dev}" ]; then
        [ -n "${fault_dev}" ] || bc_eh_die "BC_EH_MEGA_FAULT_DEV is required when BC_EH_MEGA_HEALTHY_DEV is set"
        [ -n "${healthy_dev}" ] || bc_eh_die "BC_EH_MEGA_HEALTHY_DEV is required when BC_EH_MEGA_FAULT_DEV is set"
        printf '%s\n' "$(readlink -f "${fault_dev}")"
        printf '%s\n' "$(readlink -f "${healthy_dev}")"
        return 0
    fi

    bc_eh_mega_autodetect_devices "${host_name}"
}

bc_eh_mega_set_queue_depth()
{
    local dev_path="$1"
    local depth="$2"
    local scsi_id
    local qd_file

    scsi_id="$(bc_eh_mega_scsi_id_from_dev "${dev_path}")"
    qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"
    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    printf '%s\n' "${depth}" > "${qd_file}"
}

bc_eh_mega_get_queue_depth()
{
    local dev_path="$1"
    local scsi_id
    local qd_file

    scsi_id="$(bc_eh_mega_scsi_id_from_dev "${dev_path}")"
    qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"
    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    cat "${qd_file}"
}

bc_eh_mega_set_nr_requests()
{
    local dev_path="$1"
    local nr="$2"
    local block_name
    local nr_file

    block_name="$(bc_eh_mega_block_name_from_dev "${dev_path}")"
    nr_file="/sys/block/${block_name}/queue/nr_requests"
    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    printf '%s\n' "${nr}" > "${nr_file}"
}

bc_eh_mega_get_nr_requests()
{
    local dev_path="$1"
    local block_name
    local nr_file

    block_name="$(bc_eh_mega_block_name_from_dev "${dev_path}")"
    nr_file="/sys/block/${block_name}/queue/nr_requests"
    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    cat "${nr_file}"
}

bc_eh_mega_clear_injection()
{
    bc_eh_mega_write_param bc_mega_fault_active 0
    bc_eh_mega_write_param bc_mega_fault_mode 0
    bc_eh_mega_write_param bc_mega_fault_target_id -1
}

bc_eh_mega_arm_case()
{
    local case_name="$1"
    local fault_target_id="$2"

    bc_eh_mega_clear_injection
    bc_eh_mega_write_param bc_mega_fault_target_id "${fault_target_id}"

    case "${case_name}" in
        P2)
            bc_eh_mega_write_param bc_mega_tur_fail_budget "${BC_EH_MEGA_P2_TUR_FAIL_BUDGET:--1}"
            bc_eh_mega_write_param bc_mega_fault_mode 2
            ;;
        P3)
            bc_eh_mega_write_param bc_mega_tur_fail_budget "${BC_EH_MEGA_P3_TUR_FAIL_BUDGET:--1}"
            bc_eh_mega_write_param bc_mega_fault_mode 3
            ;;
        *)
            bc_eh_die "unsupported case: ${case_name}"
            ;;
    esac

    bc_eh_mega_write_param bc_mega_fault_active 1
}

bc_eh_mega_fio_job()
{
    local name="$1"
    local filename="$2"
    local runtime="$3"
    local iodepth="$4"
    local log_prefix="$5"
    local rw="${6:-randread}"
    local bs="${7:-4k}"
    local log_avg_msec="${8:-1000}"
    local cpu_id="${9:-}"
    local randseed="${10:-}"

    if [ -n "${cpu_id}" ] && command -v taskset >/dev/null 2>&1; then
        taskset -c "${cpu_id}" \
            "${BC_EH_MEGA_FIO_BIN}" \
            --name="${name}" \
            --filename="${filename}" \
            --ioengine=libaio \
            --direct=1 \
            --rw="${rw}" \
            --bs="${bs}" \
            --time_based=1 \
            --runtime="${runtime}" \
            --iodepth="${iodepth}" \
            --group_reporting=1 \
            --log_avg_msec="${log_avg_msec}" \
            --write_bw_log="${log_prefix}" \
            --write_iops_log="${log_prefix}" \
            --randrepeat=1 \
            --randseed="${randseed}" \
            --norandommap=1 \
            --output-format=normal
        return
    fi

    "${BC_EH_MEGA_FIO_BIN}" \
        --name="${name}" \
        --filename="${filename}" \
        --ioengine=libaio \
        --direct=1 \
        --rw="${rw}" \
        --bs="${bs}" \
        --time_based=1 \
        --runtime="${runtime}" \
        --iodepth="${iodepth}" \
        --group_reporting=1 \
        --log_avg_msec="${log_avg_msec}" \
        --write_bw_log="${log_prefix}" \
        --write_iops_log="${log_prefix}" \
        --randrepeat=1 \
        --randseed="${randseed}" \
        --norandommap=1 \
        --output-format=normal
}
