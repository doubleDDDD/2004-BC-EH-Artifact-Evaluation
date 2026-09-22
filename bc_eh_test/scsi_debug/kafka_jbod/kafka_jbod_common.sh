#!/usr/bin/env bash
set -euo pipefail

PATH=/sbin:/bin:/usr/sbin:/usr/bin:${PATH:-}

readonly KAFKA_JBOD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KAFKA_JBOD_PARENT_DIR="$(cd "${KAFKA_JBOD_SCRIPT_DIR}/.." && pwd)"

export BC_EH_TOPOLOGY="${BC_EH_TOPOLOGY:-complextopo}"
export BC_EH_COMPLEX_NUM_CHANNELS="${BC_EH_COMPLEX_NUM_CHANNELS:-1}"
export BC_EH_COMPLEX_NUM_TARGETS="${BC_EH_COMPLEX_NUM_TARGETS:-3}"
export BC_EH_COMPLEX_MAX_LUNS="${BC_EH_COMPLEX_MAX_LUNS:-1}"
export BC_EH_COMPLEX_QUEUE_TUNING="${BC_EH_COMPLEX_QUEUE_TUNING:-1}"
export BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH="${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH:-64}"
export BC_EH_COMPLEX_PER_DISK_NR_REQUESTS="${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS:-64}"
export SDEBUG_DEV_SIZE_MB="${SDEBUG_DEV_SIZE_MB:-4096}"
export SDEBUG_SECTOR_SIZE="${SDEBUG_SECTOR_SIZE:-512}"
export SDEBUG_DSENSE="${SDEBUG_DSENSE:-1}"
export SDEBUG_DELAY="${SDEBUG_DELAY:-1}"
export SDEBUG_WAIT_SECS="${SDEBUG_WAIT_SECS:-15}"
export SDEBUG_SETTLE_SECS="${SDEBUG_SETTLE_SECS:-1}"

# shellcheck source=/dev/null
. "${KAFKA_JBOD_PARENT_DIR}/scsi_debug_common.sh"

readonly KAFKA_JBOD_NUM_CHANNELS=1
readonly KAFKA_JBOD_NUM_TARGETS=3
readonly KAFKA_JBOD_MAX_LUNS=1

kafka_jbod_log() {
    printf '[kafka-jbod] %s\n' "$*"
}

kafka_jbod_warn() {
    printf '[kafka-jbod][warn] %s\n' "$*" >&2
}

kafka_jbod_die() {
    printf '[kafka-jbod][error] %s\n' "$*" >&2
    exit 1
}

kafka_jbod_require_root() {
    bc_eh_require_root
}

# Kafka JBOD runs on a full Ubuntu install, so scsi_debug comes from the
# system module tree via modprobe.
kafka_jbod_load_scsi_debug() {
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
    modprobe crc_t10dif || bc_eh_die "failed to modprobe crc_t10dif"

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
            dev_size_mb="${SDEBUG_DEV_SIZE_MB:-4096}" \
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
            dev_size_mb="${SDEBUG_DEV_SIZE_MB:-4096}" \
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
    kafka_jbod_udev_settle
}

kafka_jbod_mount_dir_for_target() {
    local target="$1"
    printf '/data/kafka-%s\n' "$((target + 1))"
}

kafka_jbod_expected_device_count() {
    printf '%s\n' "$((KAFKA_JBOD_NUM_CHANNELS * KAFKA_JBOD_NUM_TARGETS * KAFKA_JBOD_MAX_LUNS))"
}

kafka_jbod_scsi_debug_hosts() {
    local host_name
    local proc_name

    for host_name in /sys/class/scsi_host/host*; do
        [ -e "${host_name}" ] || continue
        host_name="$(basename "${host_name}")"
        proc_name="$(cat "/sys/class/scsi_host/${host_name}/proc_name" 2>/dev/null || true)"
        [ "${proc_name}" = "scsi_debug" ] || continue
        printf '%s\n' "${host_name}"
    done
}

kafka_jbod_scsi_debug_host_count() {
    local count=0
    local host_name

    while read -r host_name; do
        [ -n "${host_name}" ] || continue
        count=$((count + 1))
    done <<EOF
$(kafka_jbod_scsi_debug_hosts || true)
EOF

    printf '%s\n' "${count}"
}

kafka_jbod_count_scsi_devices_on_host() {
    local host_name="$1"
    local host_no="${host_name#host}"
    local dev_dir
    local count=0

    for dev_dir in /sys/class/scsi_device/"${host_no}":0:*:0; do
        [ -e "${dev_dir}" ] || continue
        count=$((count + 1))
    done

    printf '%s\n' "${count}"
}

kafka_jbod_wait_for_expected_devices() {
    local timeout_secs="${1:-$SDEBUG_WAIT_SECS}"
    local expected_count
    local host_name=''
    local count=0
    local host_count=0

    expected_count="$(kafka_jbod_expected_device_count)"

    while [ "${timeout_secs}" -gt 0 ]; do
        host_count="$(kafka_jbod_scsi_debug_host_count)"
        if [ "${host_count}" -eq 1 ]; then
            host_name="$(bc_eh_wait_scsi_debug_host 1 || true)"
            if [ -n "${host_name}" ]; then
                count="$(kafka_jbod_count_scsi_devices_on_host "${host_name}")"
                if [ "${count}" -eq "${expected_count}" ]; then
                    printf '%s\n' "${host_name}"
                    return 0
                fi
            fi
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    kafka_jbod_die "expected exactly 1 scsi_debug host and ${expected_count} devices, got hosts=${host_count} devices=${count}"
}

kafka_jbod_scsi_id_for_target() {
    local target="$1"
    local scsi_id=''

    scsi_id="$(bc_eh_wait_scsi_id 0 "${target}" 0 "${SDEBUG_WAIT_SECS}")" || \
        kafka_jbod_die "failed to find scsi id for target ${target}"
    printf '%s\n' "${scsi_id}"
}

kafka_jbod_block_for_scsi_id() {
    local scsi_id="$1"
    local block_name=''

    block_name="$(bc_eh_wait_block_device "${scsi_id}" "${SDEBUG_WAIT_SECS}")" || \
        kafka_jbod_die "failed to find block device for ${scsi_id}"
    printf '%s\n' "${block_name}"
}

kafka_jbod_dev_for_target() {
    local target="$1"
    local scsi_id
    local block_name

    scsi_id="$(kafka_jbod_scsi_id_for_target "${target}")"
    block_name="$(kafka_jbod_block_for_scsi_id "${scsi_id}")"
    printf '/dev/%s\n' "${block_name}"
}

kafka_jbod_mapping_lines() {
    local target
    local scsi_id
    local block_name
    local mount_dir

    for target in 0 1 2; do
        scsi_id="$(kafka_jbod_scsi_id_for_target "${target}")"
        block_name="$(kafka_jbod_block_for_scsi_id "${scsi_id}")"
        mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"
        printf 'target-%s scsi_id=%s dev=/dev/%s mount=%s\n' \
            "${target}" "${scsi_id}" "${block_name}" "${mount_dir}"
    done
}

kafka_jbod_set_queue_tuning() {
    local target
    local scsi_id
    local block_name

    for target in 0 1 2; do
        scsi_id="$(kafka_jbod_scsi_id_for_target "${target}")"
        block_name="$(kafka_jbod_block_for_scsi_id "${scsi_id}")"
        bc_eh_set_queue_depth "${scsi_id}" "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
        bc_eh_set_nr_requests "${block_name}" "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
    done
}

kafka_jbod_udev_settle() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle || true
    fi
}

kafka_jbod_umount_data_dirs() {
    local target
    local mount_dir

    for target in 0 1 2; do
        mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"
        if mountpoint -q "${mount_dir}"; then
            kafka_jbod_log "umount ${mount_dir}"
            umount "${mount_dir}" || kafka_jbod_die "failed to umount ${mount_dir}"
        fi
    done
}

kafka_jbod_filesystem_type() {
    local dev_path="$1"
    blkid -o value -s TYPE "${dev_path}" 2>/dev/null || true
}

kafka_jbod_mount_source_for_target() {
    local target="$1"
    local mount_dir

    mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"
    findmnt -n -o SOURCE --target "${mount_dir}" 2>/dev/null || true
}

kafka_jbod_print_mapping_summary() {
    kafka_jbod_log "device mapping summary:"
    kafka_jbod_mapping_lines
}

kafka_jbod_print_mount_summary() {
    local target
    local mount_dir

    kafka_jbod_log "mount summary:"
    for target in 0 1 2; do
        mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"
        findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS --target "${mount_dir}" || true
    done
}
