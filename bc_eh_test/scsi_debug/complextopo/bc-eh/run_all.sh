#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
found=0

for script in "${SCRIPT_DIR}"/*.sh; do
    [ -e "${script}" ] || break
    case "$(basename "${script}")" in
        run_all.sh|scsi_debug_case.sh|scsi_debug_common.sh)
            continue
            ;;
    esac
    found=1
    printf '[RUN] %s\n' "${script}"
    sh "${script}" "$@"
done

for child in "${SCRIPT_DIR}"/*; do
    [ -d "${child}" ] || continue
    [ -f "${child}/run_all.sh" ] || continue
    found=1
    printf '[RUN] %s\n' "${child}/run_all.sh"
    sh "${child}/run_all.sh" "$@"
done

if [ "${found}" -eq 0 ]; then
    printf '[SKIP] no test cases under %s\n' "${SCRIPT_DIR}"
fi
