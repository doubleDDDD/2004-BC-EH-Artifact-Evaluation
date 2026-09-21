#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FAULT_EH_MODE=host

exec bash "${SCRIPT_DIR}/../single_disk_recoverable_stall_case_impl.sh" "$@"
