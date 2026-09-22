#!/bin/sh
set -eu

# Runs the scsi_debug AE suite.
#
# Included suites:
# - funcVer: functional reset-handler capability checks
# - basictopo: Topology A recovery-latency cases for Figure 10
# - complextopo: Topology B recovery-latency cases for Figure 10
# - sequence_cases: multi-fault sequence cases for Figure 11
# - checkpoint_perf: checkpoint traversal microbenchmark for Section 4.2.3
# - fpl_perf_quick: short FPL hot-path matrix with reduced runtime
#
# Not included:
# - fpl_perf_real
# - kafka_jbod

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
found=0

for script in "${SCRIPT_DIR}"/*.sh; do
    [ -e "${script}" ] || break
    case "$(basename "${script}")" in
        run_all.sh|run_scsi_debug_ae_suite.sh|scsi_debug_case.sh|scsi_debug_common.sh)
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

if [ -f "${SCRIPT_DIR}/checkpoint_perf/run_matrix.sh" ]; then
    found=1
    printf '[RUN] %s\n' "${SCRIPT_DIR}/checkpoint_perf/run_matrix.sh"
    sh "${SCRIPT_DIR}/checkpoint_perf/run_matrix.sh" "$@"
fi

if [ -f "${SCRIPT_DIR}/fpl_perf_quick/run_fpl_hotpath_matrix.sh" ]; then
    found=1
    printf '[RUN] %s\n' "${SCRIPT_DIR}/fpl_perf_quick/run_fpl_hotpath_matrix.sh"
    sh "${SCRIPT_DIR}/fpl_perf_quick/run_fpl_hotpath_matrix.sh" "$@"
fi

if [ "${found}" -eq 0 ]; then
    printf '[SKIP] no test cases under %s\n' "${SCRIPT_DIR}"
fi
