#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '[kafka-formal-topic-runner] %s\n' "$*"
}

main() {
    log "Applying fixed_6_16 formal-topic layout"
    bash "${SCRIPT_DIR}/apply_fixed_6_16_layout.sh"

    log "Checking fixed_6_16 formal-topic layout"
    bash "${SCRIPT_DIR}/check_fixed_6_16_layout.sh"

    log "fixed_6_16 workflow finished"
}

main "$@"
