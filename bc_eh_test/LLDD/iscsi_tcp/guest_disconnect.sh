#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/iscsi_tcp_common.sh"

main()
{
    bc_eh_require_root
    bc_eh_require_portal_ip
    bc_eh_require_iscsiadm

    bc_eh_iscsi_guest_cleanup_session
    printf 'disconnected iqn=%s portal=%s:%s\n' \
        "${BC_EH_ISCSI_TARGET_IQN}" "${BC_EH_ISCSI_PORTAL_IP}" "${BC_EH_ISCSI_PORTAL_PORT}"
    iscsiadm -m session 2>/dev/null || true
}

main "$@"
