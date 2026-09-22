#!/bin/sh
set -eu

export BC_EH_TOPOLOGY=complextopo
export BC_EH_COMPLEX_NUM_CHANNELS=1
export BC_EH_COMPLEX_NUM_TARGETS=8
export BC_EH_COMPLEX_MAX_LUNS=2
export BC_EH_COMPLEX_QUEUE_TUNING=1
export BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH=64
export BC_EH_COMPLEX_PER_DISK_NR_REQUESTS=64

# Fault scenario:
# - Topic: sequence convoy / linux-eh
# - Topology is identical to the bc-eh version: 1 channel, 8 targets, 2 LUNs per target
# - lun0 of each target is healthy and active; lun1 is the faulty disk
# - 8 faulty LUNs enter sequentially by target order after warmup
# - initial I/O on each faulty LUN first times out and abort fails, triggering EH
# - subsequent device / target / bus / host resets all succeed
# - but EH TUR keeps timing out after each reset level until linux-eh escalates to host and finally offlines the device
# - Goal: Run the same convoy case with linux-eh as the control
# - Injection method:
#   after fio warmup, continuously write error rules to lun1 of 8 targets,
#   create the worst-case convoy where adjacent errors enter consecutively but remain scope-independent

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../../scsi_debug_common.sh"

readonly CASE_ID="staggered_independent_sdev_convoy_8targets"
readonly RUN_DIR="${BC_EH_SCSI_DEBUG_ROOT}/sequence_cases/linux-eh/${CASE_ID}"
readonly EXPECTED_TARGET_COUNT="${BC_EH_COMPLEX_NUM_TARGETS}"
readonly TOTAL_RUNTIME_SECS="${BC_EH_SEQ_CONVOY_FIO_RUNTIME_SECS:-240}"
readonly INITIAL_INJECT_DELAY_SECS="${BC_EH_SEQ_CONVOY_INITIAL_INJECT_DELAY_SECS:-3}"
readonly FIO_IODEPTH=64
FAULT_VALIDATE_RULES=$(cat <<'EOF'
device timeout 1
target timeout 1
bus timeout 1
host timeout 1
EOF
)

INJECTOR_PID=""
TARGET_LIST=""

count_targets()
{
    local count=0
    local target

    for target in $1; do
        count=$((count + 1))
    done

    printf '%s\n' "${count}"
}

discover_target_list()
{
    local host_no="$1"
    local channel="$2"
    local lun="$3"
    local expected_count="$4"
    local timeout_secs="$5"
    local target_list=""
    local count=0
    local dev_dir
    local scsi_id
    local rest
    local target

    while [ "${timeout_secs}" -gt 0 ]; do
        target_list="$(
            for dev_dir in /sys/class/scsi_device/"${host_no}:${channel}":*:"${lun}"; do
                [ -e "${dev_dir}" ] || continue
                scsi_id="$(basename "${dev_dir}")"
                rest="${scsi_id#*:}"
                rest="${rest#*:}"
                target="${rest%%:*}"
                printf '%s\n' "${target}"
            done | sort -n
        )"

        count="$(count_targets "${target_list}")"
        if [ "${count}" -eq "${expected_count}" ]; then
            printf '%s\n' "${target_list}"
            return 0
        fi

        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    bc_eh_die "failed to discover ${expected_count} targets on channel ${channel}; found: ${target_list:-<none>}"
}

run_fio_on_convoy_devices()
{
    local run_dir="$1"
    local fio_bin
    local fio_dir
    local fio_name
    local target
    local label
    local device
    local pid
    local pids=""
    local status=0

    fio_bin="$(bc_eh_resolve_fio_bin)" || bc_eh_die "fio binary not found"
    fio_dir="$(dirname "${fio_bin}")"
    fio_name="$(basename "${fio_bin}")"

    for target in ${TARGET_LIST}; do
        eval "device=/dev/\${HEALTHY_BLOCK_${target}}"
        label="T${target}H"
        bc_eh_log "run fio(${label}): cd ${fio_dir} && ./${fio_name} --filename=${device} --ioengine=libaio --direct=1 --iodepth=${FIO_IODEPTH} --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=${TOTAL_RUNTIME_SECS} --group_reporting --name=randread_4k_${label}"
        (
            cd "${fio_dir}" &&
            "./${fio_name}" \
                "--filename=${device}" \
                "--ioengine=libaio" \
                "--direct=1" \
                "--iodepth=${FIO_IODEPTH}" \
                "--rw=randread" \
                "--bs=4k" \
                "--numjobs=1" \
                "--thread" \
                "--size=100%" \
                "--time_based" \
                "--runtime=${TOTAL_RUNTIME_SECS}" \
                "--group_reporting" \
                "--name=randread_4k_${label}"
        ) &
        pid=$!
        pids="${pids} ${pid}"

        eval "device=/dev/\${FAULT_BLOCK_${target}}"
        label="T${target}F"
        bc_eh_log "run fio(${label}): cd ${fio_dir} && ./${fio_name} --filename=${device} --ioengine=libaio --direct=1 --iodepth=${FIO_IODEPTH} --rw=randread --bs=4k --numjobs=1 --thread --size=100% --time_based --runtime=${TOTAL_RUNTIME_SECS} --group_reporting --name=randread_4k_${label}"
        (
            cd "${fio_dir}" &&
            "./${fio_name}" \
                "--filename=${device}" \
                "--ioengine=libaio" \
                "--direct=1" \
                "--iodepth=${FIO_IODEPTH}" \
                "--rw=randread" \
                "--bs=4k" \
                "--numjobs=1" \
                "--thread" \
                "--size=100%" \
                "--time_based" \
                "--runtime=${TOTAL_RUNTIME_SECS}" \
                "--group_reporting" \
                "--name=randread_4k_${label}"
        ) &
        pid=$!
        pids="${pids} ${pid}"
    done

    for pid in ${pids}; do
        wait "${pid}" || status=1
    done

    [ "${status}" -eq 0 ] || bc_eh_die "fio failed"
    bc_eh_log "fio done"
}

cleanup()
{
    if [ -n "${INJECTOR_PID}" ]; then
        kill "${INJECTOR_PID}" >/dev/null 2>&1 || true
        wait "${INJECTOR_PID}" >/dev/null 2>&1 || true
    fi
}

main()
{
    local scsi_debug_host
    local target
    local target_count
    local healthy_scsi_id
    local fault_scsi_id
    local healthy_block
    local fault_block
    local inject_scsi_id

    trap cleanup EXIT INT TERM

    bc_eh_reset_case_state

    rm -rf "${RUN_DIR}"
    mkdir -p "${RUN_DIR}"

    export SDEBUG_EH_RESET_MASK=0xf

    bc_eh_cleanup_scsi_debug_env
    bc_eh_load_scsi_debug
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "host"
    TARGET_LIST="$(discover_target_list "${scsi_debug_host#host}" 0 0 "${EXPECTED_TARGET_COUNT}" "${SDEBUG_WAIT_SECS:-15}")"
    target_count="$(count_targets "${TARGET_LIST}")"
    [ "${target_count}" -eq "${EXPECTED_TARGET_COUNT}" ] || \
        bc_eh_die "unexpected target count: expected ${EXPECTED_TARGET_COUNT}, got ${target_count}"
    bc_eh_log "discovered target ids on channel-0: ${TARGET_LIST}"

    for target in ${TARGET_LIST}; do
        healthy_scsi_id="$(bc_eh_wait_scsi_id 0 "${target}" 0 "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find healthy lun for target ${target}"
        fault_scsi_id="$(bc_eh_wait_scsi_id 0 "${target}" 1 "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find fault lun for target ${target}"
        healthy_block="$(bc_eh_wait_block_device "${healthy_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find healthy block for target ${target}"
        fault_block="$(bc_eh_wait_block_device "${fault_scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find fault block for target ${target}"

        eval "HEALTHY_SCSI_ID_${target}='${healthy_scsi_id}'"
        eval "FAULT_SCSI_ID_${target}='${fault_scsi_id}'"
        eval "HEALTHY_BLOCK_${target}='${healthy_block}'"
        eval "FAULT_BLOCK_${target}='${fault_block}'"

        bc_eh_set_queue_depth "${healthy_scsi_id}" "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
        bc_eh_set_nr_requests "${healthy_block}" "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
        bc_eh_set_queue_depth "${fault_scsi_id}" "${BC_EH_COMPLEX_PER_DISK_QUEUE_DEPTH}"
        bc_eh_set_nr_requests "${fault_block}" "${BC_EH_COMPLEX_PER_DISK_NR_REQUESTS}"
        bc_eh_apply_validate_after_reset "${fault_scsi_id}" "${FAULT_VALIDATE_RULES}"
    done

    {
        printf 'case_id=%s\n' "${CASE_ID}"
        printf 'group=sequence_cases/linux-eh\n'
        printf 'eh_reset_mask=0xf\n'
        printf 'eh_mode=host\n'
        printf 'topology=%sch_%stgt_%slun\n' \
            "${BC_EH_COMPLEX_NUM_CHANNELS}" \
            "${BC_EH_COMPLEX_NUM_TARGETS}" \
            "${BC_EH_COMPLEX_MAX_LUNS}"
        printf 'healthy_lun=0\n'
        printf 'fault_lun=1\n'
        printf 'fault_inject_order=%s\n' "${TARGET_LIST}"
        printf 'fault_inject_mode=contiguous_burst_after_warmup\n'
        printf 'single_sequence_tail=device/target/bus/host timeout 1\n'
        printf 'fio_runtime_secs=%s\n' "${TOTAL_RUNTIME_SECS}"
        printf 'initial_inject_delay_secs=%s\n' "${INITIAL_INJECT_DELAY_SECS}"
        printf 'inject_spacing_secs=0\n'
        printf 'host=%s\n' "${scsi_debug_host}"
        for target in ${TARGET_LIST}; do
            eval "healthy_scsi_id=\${HEALTHY_SCSI_ID_${target}}"
            eval "fault_scsi_id=\${FAULT_SCSI_ID_${target}}"
            eval "healthy_block=\${HEALTHY_BLOCK_${target}}"
            eval "fault_block=\${FAULT_BLOCK_${target}}"
            printf 'target_%s_healthy=%s /dev/%s\n' "${target}" "${healthy_scsi_id}" "${healthy_block}"
            printf 'target_%s_fault=%s /dev/%s\n' "${target}" "${fault_scsi_id}" "${fault_block}"
        done
    } > "${RUN_DIR}/metadata"

    (
        sleep "${INITIAL_INJECT_DELAY_SECS}"
        for target in ${TARGET_LIST}; do
            eval "inject_scsi_id=\${FAULT_SCSI_ID_${target}}"
            bc_eh_log "inject contiguous burst fault into target-${target} lun-1"
            bc_eh_apply_error_rules "${inject_scsi_id}" "${BC_EH_RULE_IO_TIMEOUT_ABORT}"
        done
    ) &
    INJECTOR_PID=$!

    bc_eh_log "run ${CASE_ID}: ${EXPECTED_TARGET_COUNT} healthy lun0 + ${EXPECTED_TARGET_COUNT} fault lun1 under one channel"
    run_fio_on_convoy_devices "${RUN_DIR}"

    wait "${INJECTOR_PID}"
    INJECTOR_PID=""
}

main "$@"
