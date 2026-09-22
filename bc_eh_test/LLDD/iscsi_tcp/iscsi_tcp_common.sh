#!/bin/sh
set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH:-}

readonly BC_EH_SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
readonly BC_EH_RUN_ROOT="${BC_EH_RUN_ROOT:-/tmp/bc_eh_test}"
readonly BC_EH_ISCSI_ROOT="${BC_EH_ISCSI_ROOT:-${BC_EH_RUN_ROOT}/iscsi_tcp}"
readonly BC_EH_ISCSI_INITIATOR_IQN="${BC_EH_ISCSI_INITIATOR_IQN:-iqn.2026-06.com.bc-eh:iscsi-vm}"
readonly BC_EH_ISCSI_TARGET_IQN="${BC_EH_ISCSI_TARGET_IQN:-iqn.2026-06.com.bc-eh:target0}"
readonly BC_EH_ISCSI_PORTAL_IP="${BC_EH_ISCSI_PORTAL_IP:?set BC_EH_ISCSI_PORTAL_IP}"
readonly BC_EH_ISCSI_PORTAL_PORT="${BC_EH_ISCSI_PORTAL_PORT:-3260}"
readonly BC_EH_ISCSI_BACKSTORE_LUN0="${BC_EH_ISCSI_BACKSTORE_LUN0:-bc_eh_iscsi_lun0}"
readonly BC_EH_ISCSI_BACKSTORE_LUN1="${BC_EH_ISCSI_BACKSTORE_LUN1:-bc_eh_iscsi_lun1}"
readonly BC_EH_ISCSI_HOST_TARGET_TIMEOUT="${BC_EH_ISCSI_HOST_TARGET_TIMEOUT:-15}"
readonly BC_EH_ISCSI_FIO_BIN="${BC_EH_ISCSI_FIO_BIN:-$(command -v fio || true)}"

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

bc_eh_require_portal_ip()
{
    [ -n "${BC_EH_ISCSI_PORTAL_IP}" ] || bc_eh_die "BC_EH_ISCSI_PORTAL_IP is required"
}

bc_eh_require_targetcli()
{
    command -v targetcli >/dev/null 2>&1 || bc_eh_die "targetcli not found"
}

bc_eh_require_iscsiadm()
{
    command -v iscsiadm >/dev/null 2>&1 || bc_eh_die "iscsiadm not found"
}

bc_eh_iscsi_prepare_initiator()
{
    local initiator_file="/etc/iscsi/initiatorname.iscsi"

    bc_eh_require_root

    command -v modprobe >/dev/null 2>&1 && modprobe iscsi_tcp >/dev/null 2>&1 || true
    mkdir -p /etc/iscsi
    printf 'InitiatorName=%s\n' "${BC_EH_ISCSI_INITIATOR_IQN}" > "${initiator_file}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart iscsid >/dev/null 2>&1 || true
        systemctl restart open-iscsi >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service iscsid restart >/dev/null 2>&1 || true
        service open-iscsi restart >/dev/null 2>&1 || true
    fi
}

bc_eh_require_fio()
{
    [ -n "${BC_EH_ISCSI_FIO_BIN}" ] || bc_eh_die "fio not found"
    [ -x "${BC_EH_ISCSI_FIO_BIN}" ] || bc_eh_die "fio is not executable: ${BC_EH_ISCSI_FIO_BIN}"
}

bc_eh_targetcli()
{
    targetcli "$@" >/dev/null
}

bc_eh_iscsi_lun_symlink()
{
    local lun="$1"
    printf '/dev/disk/by-path/ip-%s:%s-iscsi-%s-lun-%s\n' \
        "${BC_EH_ISCSI_PORTAL_IP}" \
        "${BC_EH_ISCSI_PORTAL_PORT}" \
        "${BC_EH_ISCSI_TARGET_IQN}" \
        "${lun}"
}

bc_eh_wait_path()
{
    local path="$1"
    local timeout_secs="${2:-15}"

    while [ "${timeout_secs}" -gt 0 ]; do
        [ -e "${path}" ] && return 0
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_iscsi_guest_cleanup_session()
{
    bc_eh_require_root
    bc_eh_require_portal_ip
    bc_eh_require_iscsiadm

    iscsiadm -m node -T "${BC_EH_ISCSI_TARGET_IQN}" -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" --logout >/dev/null 2>&1 || true
    iscsiadm -m node -T "${BC_EH_ISCSI_TARGET_IQN}" -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" -o delete >/dev/null 2>&1 || true
    sleep 1
}

bc_eh_iscsi_guest_login()
{
    bc_eh_require_root
    bc_eh_require_portal_ip
    bc_eh_require_iscsiadm
    bc_eh_iscsi_prepare_initiator

    iscsiadm -m discoverydb -t sendtargets -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" -D >/dev/null 2>&1 || true
    iscsiadm -m discovery -t sendtargets -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" >/dev/null

    iscsiadm -m node -T "${BC_EH_ISCSI_TARGET_IQN}" -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" \
        --op update -n node.conn[0].timeo.noop_out_interval -v 0 >/dev/null
    iscsiadm -m node -T "${BC_EH_ISCSI_TARGET_IQN}" -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" \
        --op update -n node.conn[0].timeo.noop_out_timeout -v 0 >/dev/null

    iscsiadm -m node -T "${BC_EH_ISCSI_TARGET_IQN}" -p "${BC_EH_ISCSI_PORTAL_IP}:${BC_EH_ISCSI_PORTAL_PORT}" --login >/dev/null
    sleep 2
}

bc_eh_iscsi_session_exists()
{
    bc_eh_require_iscsiadm

    iscsiadm -m session 2>/dev/null | grep -Fq "${BC_EH_ISCSI_TARGET_IQN}"
}

bc_eh_iscsi_find_host()
{
    local host_dir
    local proc_name

    for host_dir in /sys/class/scsi_host/host*; do
        [ -e "${host_dir}" ] || continue
        proc_name="$(cat "${host_dir}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "iscsi_tcp" ] || continue
        printf '%s\n' "$(basename "${host_dir}")"
        return 0
    done

    return 1
}

bc_eh_iscsi_wait_host()
{
    local timeout_secs="${1:-15}"
    local host_name

    while [ "${timeout_secs}" -gt 0 ]; do
        host_name="$(bc_eh_iscsi_find_host || true)"
        if [ -n "${host_name}" ]; then
            printf '%s\n' "${host_name}"
            return 0
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    return 1
}

bc_eh_iscsi_set_eh_mode()
{
    local host_name="$1"
    local mode="$2"
    local path="/sys/class/scsi_host/${host_name}/eh_mode"

    [ -e "${path}" ] || bc_eh_die "eh_mode sysfs not found: ${path}"
    printf '%s\n' "${mode}" > "${path}"
}

bc_eh_iscsi_wait_lun_device()
{
    local lun="$1"
    local path

    path="$(bc_eh_iscsi_lun_symlink "${lun}")"
    bc_eh_wait_path "${path}" "${BC_EH_ISCSI_HOST_TARGET_TIMEOUT}" || bc_eh_die "LUN path not found: ${path}"
    readlink -f "${path}"
}

bc_eh_iscsi_block_name_from_dev()
{
    local dev_path="$1"

    basename "${dev_path}"
}

bc_eh_iscsi_scsi_id_from_dev()
{
    local dev_path="$1"
    local block_name
    local link_target

    block_name="$(bc_eh_iscsi_block_name_from_dev "${dev_path}")"
    link_target="$(readlink -f "/sys/block/${block_name}/device")" || \
        bc_eh_die "failed to resolve scsi device for ${dev_path}"
    basename "${link_target}"
}

bc_eh_iscsi_set_queue_depth()
{
    local dev_path="$1"
    local depth="$2"
    local scsi_id
    local qd_file

    scsi_id="$(bc_eh_iscsi_scsi_id_from_dev "${dev_path}")"
    qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"
    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    printf '%s\n' "${depth}" > "${qd_file}"
}

bc_eh_iscsi_get_queue_depth()
{
    local dev_path="$1"
    local scsi_id
    local qd_file

    scsi_id="$(bc_eh_iscsi_scsi_id_from_dev "${dev_path}")"
    qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"
    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    cat "${qd_file}"
}

bc_eh_iscsi_set_nr_requests()
{
    local dev_path="$1"
    local nr="$2"
    local block_name
    local nr_file

    block_name="$(bc_eh_iscsi_block_name_from_dev "${dev_path}")"
    nr_file="/sys/block/${block_name}/queue/nr_requests"
    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    printf '%s\n' "${nr}" > "${nr_file}"
}

bc_eh_iscsi_get_nr_requests()
{
    local dev_path="$1"
    local block_name
    local nr_file

    block_name="$(bc_eh_iscsi_block_name_from_dev "${dev_path}")"
    nr_file="/sys/block/${block_name}/queue/nr_requests"
    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    cat "${nr_file}"
}

bc_eh_iscsi_show_state()
{
    bc_eh_require_iscsiadm

    printf 'initiator=%s\n' "${BC_EH_ISCSI_INITIATOR_IQN}"
    printf 'portal=%s:%s\n' "${BC_EH_ISCSI_PORTAL_IP}" "${BC_EH_ISCSI_PORTAL_PORT}"
    printf 'iqn=%s\n' "${BC_EH_ISCSI_TARGET_IQN}"
    iscsiadm -m session -P 3 2>/dev/null || true
    command -v lsscsi >/dev/null 2>&1 && lsscsi || true
    lsblk -S 2>/dev/null || true
    ls -l /dev/disk/by-path 2>/dev/null | grep iscsi || true
}

bc_eh_iscsi_clear_injection()
{
    bc_eh_require_root

    [ -e /sys/module/libiscsi/parameters/bc_iscsi_test_mode ] || bc_eh_die "libiscsi test params not found"
    printf '0\n' > /sys/module/libiscsi/parameters/bc_iscsi_hold_tur
    printf '0\n' > /sys/module/libiscsi/parameters/bc_iscsi_fault_active
    printf '0\n' > /sys/module/libiscsi/parameters/bc_iscsi_test_mode
}

bc_eh_iscsi_arm_case()
{
    local case_name="$1"

    bc_eh_require_root
    bc_eh_iscsi_clear_injection

    case "${case_name}" in
        P1)
            printf '1\n' > /sys/module/libiscsi/parameters/bc_iscsi_test_mode
            printf '1\n' > /sys/module/libiscsi/parameters/bc_iscsi_fault_active
            ;;
        P5)
            printf '5\n' > /sys/module/libiscsi/parameters/bc_iscsi_test_mode
            printf '1\n' > /sys/module/libiscsi/parameters/bc_iscsi_fault_active
            ;;
        *)
            bc_eh_die "unsupported case: ${case_name}"
            ;;
    esac
}

bc_eh_iscsi_mark()
{
    local message="$1"
    if [ -w /dev/kmsg ]; then
        printf 'bc_eh_iscsi %s\n' "${message}" > /dev/kmsg
    fi
}

bc_eh_iscsi_fio_job()
{
    local name="$1"
    local filename="$2"
    local runtime="$3"
    local iodepth="$4"
    local log_prefix="$5"
    local log_avg_msec="${6:-1000}"
    local stable_mode="${7:-0}"
    local randseed="${8:-}"
    local cpu_id="${9:-}"

    if [ "${stable_mode}" = "1" ]; then
        if [ -n "${cpu_id}" ] && command -v taskset >/dev/null 2>&1; then
            taskset -c "${cpu_id}" \
                "${BC_EH_ISCSI_FIO_BIN}" \
                --name="${name}" \
                --filename="${filename}" \
                --ioengine=libaio \
                --direct=1 \
                --rw=randread \
                --bs=4k \
                --time_based=1 \
                --runtime="${runtime}" \
                --iodepth="${iodepth}" \
                --numjobs=1 \
                --thread=1 \
                --gtod_reduce=1 \
                --randrepeat=1 \
                --randseed="${randseed}" \
                --norandommap=1 \
                --group_reporting=1 \
                --log_avg_msec="${log_avg_msec}" \
                --write_bw_log="${log_prefix}" \
                --write_iops_log="${log_prefix}" \
                --output-format=normal
        else
            "${BC_EH_ISCSI_FIO_BIN}" \
                --name="${name}" \
                --filename="${filename}" \
                --ioengine=libaio \
                --direct=1 \
                --rw=randread \
                --bs=4k \
                --time_based=1 \
                --runtime="${runtime}" \
                --iodepth="${iodepth}" \
                --numjobs=1 \
                --thread=1 \
                --gtod_reduce=1 \
                --randrepeat=1 \
                --randseed="${randseed}" \
                --norandommap=1 \
                --group_reporting=1 \
                --log_avg_msec="${log_avg_msec}" \
                --write_bw_log="${log_prefix}" \
                --write_iops_log="${log_prefix}" \
                --output-format=normal
        fi
        return
    fi

    if [ -n "${cpu_id}" ] && command -v taskset >/dev/null 2>&1; then
        taskset -c "${cpu_id}" \
            "${BC_EH_ISCSI_FIO_BIN}" \
            --name="${name}" \
            --filename="${filename}" \
            --ioengine=libaio \
            --direct=1 \
            --rw=randread \
            --bs=4k \
            --time_based=1 \
            --runtime="${runtime}" \
            --iodepth="${iodepth}" \
            --group_reporting=1 \
            --log_avg_msec="${log_avg_msec}" \
            --write_bw_log="${log_prefix}" \
            --write_iops_log="${log_prefix}" \
            --output-format=normal
        return
    fi

    "${BC_EH_ISCSI_FIO_BIN}" \
        --name="${name}" \
        --filename="${filename}" \
        --ioengine=libaio \
        --direct=1 \
        --rw=randread \
        --bs=4k \
        --time_based=1 \
        --runtime="${runtime}" \
        --iodepth="${iodepth}" \
        --group_reporting=1 \
        --log_avg_msec="${log_avg_msec}" \
        --write_bw_log="${log_prefix}" \
        --write_iops_log="${log_prefix}" \
        --output-format=normal
}
