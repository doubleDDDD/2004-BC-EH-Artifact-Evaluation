#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FAULT_EH_MODE=host

exec bash "${SCRIPT_DIR}/../single_disk_offline_case_impl.sh" "$@"
