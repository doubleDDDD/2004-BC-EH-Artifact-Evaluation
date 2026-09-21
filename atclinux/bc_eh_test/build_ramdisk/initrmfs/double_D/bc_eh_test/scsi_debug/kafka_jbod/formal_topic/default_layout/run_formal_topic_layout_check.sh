#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '[kafka-formal-topic-runner] %s\n' "$*"
}

main() {
    log "Creating or reusing the formal Kafka JBOD topic with the default layout"
    bash "${SCRIPT_DIR}/create_formal_jbod_topic.sh"

    log "Checking formal Kafka JBOD default layout"
    bash "${SCRIPT_DIR}/check_formal_jbod_layout.sh"

    log "Default formal-topic layout workflow finished"
}

main "$@"
