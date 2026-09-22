#!/usr/bin/env bash
set -euo pipefail

TARGET_IQN="iqn.2026-06.com.bc-eh:target0"
INITIATOR_IQN="iqn.2026-06.com.bc-eh:iscsi-vm"
TARGET_IP="${BC_EH_ISCSI_PORTAL_IP:?set BC_EH_ISCSI_PORTAL_IP}"
TARGET_PORT="3260"

BACKEND_ROOT="/var/lib/bc-eh-iscsi"
LUN0_SIZE="4G"
LUN1_SIZE="4G"
FILE_LUN0="${BACKEND_ROOT}/lun0.img"
FILE_LUN1="${BACKEND_ROOT}/lun1.img"
STORE0="bc_eh_lun0"
STORE1="bc_eh_lun1"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "run as root" >&2
        exit 1
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

targetcli_has() {
    targetcli ls | grep -Fq "$1"
}

tpg_lun_has() {
    targetcli /iscsi/"${TARGET_IQN}"/tpg1/luns ls | grep -Fq "$1"
}

require_host_ip() {
    if ! ip -4 addr | grep -Fq "${TARGET_IP}/24"; then
        echo "expected host-side iSCSI IP ${TARGET_IP}/24 to exist before running this script" >&2
        echo "prepare br-iscsi/tap first, then rerun create_host.sh" >&2
        exit 1
    fi
}

ensure_fileio_store() {
    local name="$1"
    local path="$2"
    local size="$3"

    mkdir -p "${BACKEND_ROOT}"
    if [[ ! -f "${path}" ]]; then
        truncate -s "${size}" "${path}"
    fi

    if ! targetcli_has "o- ${name} "; then
        targetcli /backstores/fileio create "${name}" "${path}" "${size}"
    fi
}

ensure_target() {
    if ! targetcli_has "o- ${TARGET_IQN} "; then
        targetcli /iscsi create "${TARGET_IQN}"
    fi

    targetcli /iscsi/"${TARGET_IQN}"/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=0 cache_dynamic_acls=0

    if targetcli_has "o- 0.0.0.0:${TARGET_PORT}"; then
        targetcli /iscsi/"${TARGET_IQN}"/tpg1/portals delete 0.0.0.0 "${TARGET_PORT}" || true
    fi
    if ! targetcli_has "o- ${TARGET_IP}:${TARGET_PORT}"; then
        targetcli /iscsi/"${TARGET_IQN}"/tpg1/portals create "${TARGET_IP}" "${TARGET_PORT}"
    fi

    if ! targetcli_has "o- ${INITIATOR_IQN} "; then
        targetcli /iscsi/"${TARGET_IQN}"/tpg1/acls create "${INITIATOR_IQN}"
    fi

    if ! tpg_lun_has "${STORE0}"; then
        targetcli /iscsi/"${TARGET_IQN}"/tpg1/luns create /backstores/fileio/"${STORE0}"
    fi
    if ! tpg_lun_has "${STORE1}"; then
        targetcli /iscsi/"${TARGET_IQN}"/tpg1/luns create /backstores/fileio/"${STORE1}"
    fi

    targetcli saveconfig
}

require_root
require_cmd ip
require_cmd targetcli
require_cmd ss
require_host_ip

ensure_fileio_store "${STORE0}" "${FILE_LUN0}" "${LUN0_SIZE}"
ensure_fileio_store "${STORE1}" "${FILE_LUN1}" "${LUN1_SIZE}"
ensure_target

echo "host iSCSI setup done"
echo "target: ${TARGET_IQN}"
echo "portal: ${TARGET_IP}:${TARGET_PORT}"
ss -lnt | grep ":${TARGET_PORT}\b" || true
