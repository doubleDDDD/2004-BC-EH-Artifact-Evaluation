#!/usr/bin/env bash
set -euo pipefail

TARGET_IQN="iqn.2026-06.com.bc-eh:target0"
BACKEND_ROOT="/var/lib/bc-eh-iscsi"
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

targetcli_has() {
    targetcli ls | grep -Fq "$1"
}

require_root

if targetcli_has "o- ${TARGET_IQN} "; then
    targetcli /iscsi delete "${TARGET_IQN}"
fi

if targetcli_has "o- ${STORE0} "; then
    targetcli /backstores/fileio delete "${STORE0}"
fi
if targetcli_has "o- ${STORE1} "; then
    targetcli /backstores/fileio delete "${STORE1}"
fi

rm -f "${FILE_LUN0}" "${FILE_LUN1}"
rmdir "${BACKEND_ROOT}" 2>/dev/null || true
targetcli saveconfig

echo "host iSCSI cleanup done"
