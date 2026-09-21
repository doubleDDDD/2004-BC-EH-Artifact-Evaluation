#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
    "${SCRIPT_DIR}/00_reset_kafka_runtime_env.sh"
    "${SCRIPT_DIR}/99_cleanup_kafka_jbod.sh"
}

main "$@"
