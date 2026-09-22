#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '[kafka-formal-topic-runner] %s\n' "$*"
}

main() {
    log "Applying leader_tilt_12_4 formal-topic layout"
    bash "${SCRIPT_DIR}/apply_leader_tilt_12_4_layout.sh"

    log "Checking leader_tilt_12_4 formal-topic layout"
    bash "${SCRIPT_DIR}/check_leader_tilt_12_4_layout.sh"

    log "leader_tilt_12_4 workflow finished"
}

main "$@"
