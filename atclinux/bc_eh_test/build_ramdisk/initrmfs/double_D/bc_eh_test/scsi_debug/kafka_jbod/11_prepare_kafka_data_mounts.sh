#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/kafka_jbod_common.sh"

FORCE_REFORMAT="${FORCE_REFORMAT:-0}"
DATA_OWNER="${DATA_OWNER:-root}"
DATA_GROUP="${DATA_GROUP:-root}"
FS_TYPE="${FS_TYPE:-ext4}"
MOUNT_OPTIONS="${MOUNT_OPTIONS:-noatime}"
METADATA_DIR="${METADATA_DIR:-/var/lib/kafka-metadata}"
KAFKA_LOG_SUBDIR="${KAFKA_LOG_SUBDIR:-kafka-logs}"

format_device_if_needed() {
    local target="$1"
    local dev_path="$2"
    local mount_dir="$3"
    local fs_type=''

    fs_type="$(kafka_jbod_filesystem_type "${dev_path}")"

    if [ "${FORCE_REFORMAT}" = "1" ] || [ -z "${fs_type}" ]; then
        kafka_jbod_log "mkfs.${FS_TYPE} -F ${dev_path} for ${mount_dir}"
        "mkfs.${FS_TYPE}" -F "${dev_path}" || kafka_jbod_die "failed to format ${dev_path}"
        return 0
    fi

    kafka_jbod_log "Reusing existing filesystem ${fs_type} on ${dev_path} for ${mount_dir}"
}

mount_device_to_dir() {
    local dev_path="$1"
    local mount_dir="$2"
    local source=''

    mkdir -p "${mount_dir}"

    if mountpoint -q "${mount_dir}"; then
        source="$(findmnt -n -o SOURCE --target "${mount_dir}" 2>/dev/null || true)"
        if [ "${source}" = "${dev_path}" ]; then
            kafka_jbod_log "${mount_dir} already mounted from ${dev_path}"
            return 0
        fi
        kafka_jbod_log "umount ${mount_dir} from unexpected source ${source:-<unknown>}"
        umount "${mount_dir}" || kafka_jbod_die "failed to umount ${mount_dir}"
    fi

    kafka_jbod_log "mount -o ${MOUNT_OPTIONS} ${dev_path} ${mount_dir}"
    mount -o "${MOUNT_OPTIONS}" "${dev_path}" "${mount_dir}" || \
        kafka_jbod_die "failed to mount ${dev_path} at ${mount_dir}"
}

main() {
    local target
    local dev_path
    local mount_dir
    local kafka_log_dir

    kafka_jbod_require_root

    kafka_jbod_wait_for_expected_devices "${SDEBUG_WAIT_SECS}" >/dev/null
    kafka_jbod_udev_settle

    for target in 0 1 2; do
        dev_path="$(kafka_jbod_dev_for_target "${target}")"
        mount_dir="$(kafka_jbod_mount_dir_for_target "${target}")"
        format_device_if_needed "${target}" "${dev_path}" "${mount_dir}"
        mount_device_to_dir "${dev_path}" "${mount_dir}"
        chown "${DATA_OWNER}:${DATA_GROUP}" "${mount_dir}" || \
            kafka_jbod_die "failed to chown ${mount_dir} to ${DATA_OWNER}:${DATA_GROUP}"
        kafka_log_dir="${mount_dir}/${KAFKA_LOG_SUBDIR}"
        mkdir -p "${kafka_log_dir}"
        chown "${DATA_OWNER}:${DATA_GROUP}" "${kafka_log_dir}" || \
            kafka_jbod_die "failed to chown ${kafka_log_dir} to ${DATA_OWNER}:${DATA_GROUP}"
    done

    mkdir -p "${METADATA_DIR}"
    chown "${DATA_OWNER}:${DATA_GROUP}" "${METADATA_DIR}" || \
        kafka_jbod_die "failed to chown ${METADATA_DIR} to ${DATA_OWNER}:${DATA_GROUP}"

    kafka_jbod_print_mapping_summary
    kafka_jbod_print_mount_summary
}

main "$@"
