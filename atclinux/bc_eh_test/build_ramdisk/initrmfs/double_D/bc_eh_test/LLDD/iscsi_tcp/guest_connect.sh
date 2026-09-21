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
    bc_eh_iscsi_guest_login
    bc_eh_iscsi_wait_host "${BC_EH_ISCSI_HOST_TARGET_TIMEOUT}" >/dev/null || bc_eh_die "failed to find iscsi_tcp host"
    bc_eh_iscsi_wait_lun_device 0 >/dev/null
    bc_eh_iscsi_wait_lun_device 1 >/dev/null
    bc_eh_iscsi_show_state
}

main "$@"
