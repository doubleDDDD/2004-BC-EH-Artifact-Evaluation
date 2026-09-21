#!/bin/sh
set -eu

# 用法：
#   1) 直接运行，使用默认参数：
#      sh run_fpl_hotpath_case.sh
#   2) 指定单个测试组合：
#      BC_EH_FPL_EH_MODE=host \
#      BC_EH_FPL_ACTIVE_DISKS=4 \
#      BC_EH_FPL_WORKLOAD=randread_64k \
#      BC_EH_FPL_REPEAT_INDEX=1 \
#      sh run_fpl_hotpath_case.sh
#   3) 更多例子：
#      BC_EH_FPL_EH_MODE=host \
#      BC_EH_FPL_ACTIVE_DISKS=1 \
#      BC_EH_FPL_WORKLOAD=randwrite_16k \
#      BC_EH_FPL_REPEAT_INDEX=1 \
#      sh run_fpl_hotpath_case.sh
#
#      BC_EH_FPL_EH_MODE=sdev \
#      BC_EH_FPL_ACTIVE_DISKS=16 \
#      BC_EH_FPL_WORKLOAD=randread_256k \
#      BC_EH_FPL_REPEAT_INDEX=2 \
#      sh run_fpl_hotpath_case.sh
#
#      BC_EH_FPL_EH_MODE=sdev \
#      BC_EH_FPL_ACTIVE_DISKS=2 \
#      BC_EH_FPL_WORKLOAD=randwrite_4k \
#      BC_EH_FPL_RUNTIME_SECS=120 \
#      BC_EH_FPL_WARMUP_SECS=10 \
#      BC_EH_FPL_REPEAT_INDEX=1 \
#      sh run_fpl_hotpath_case.sh
#   4) 可选覆盖项：
#      BC_EH_FPL_RUNTIME_SECS=60
#      BC_EH_FPL_WARMUP_SECS=10
#      BC_EH_FPL_PER_DISK_DEPTH=64
#      BC_EH_FPL_DEV_SIZE_MB=128
#
# 参数说明：
#   BC_EH_FPL_EH_MODE:      host | sdev
#   BC_EH_FPL_ACTIVE_DISKS: 1 | 2 | 4 | 8 | 16
#   BC_EH_FPL_WORKLOAD:     randread_4k | randread_16k | randread_64k | randread_256k |
#                           randwrite_4k | randwrite_16k | randwrite_64k | randwrite_256k
#   BC_EH_FPL_REPEAT_INDEX: 正整数，仅用于区分重复轮次输出目录
#
# 当前脚本固定：
#   - 拓扑：1 host / 1 channel / 16 targets / 1 lun
#   - 容量：128 MiB / disk
#   - 每盘深度：queue_depth = nr_requests = fio iodepth = 64
#   - host 深度：scsi_debug can_queue = host_max_queue = max_queue = 64 x N
#   - scsi_debug 延迟：delay = 0（热路径开销上界口径）
#   - 输出：fio 结果直接打印到终端；summary 模式仅输出单行 FPL_RESULT
#   - 延迟口径统一使用 clat：输出 clat mean 与 clat p99，单位为 us

export BC_EH_TOPOLOGY=complextopo
export BC_EH_COMPLEX_NUM_CHANNELS=1
export BC_EH_COMPLEX_NUM_TARGETS=16
export BC_EH_COMPLEX_MAX_LUNS=1

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../scsi_debug_common.sh"

readonly BC_EH_FPL_EH_MODE="${BC_EH_FPL_EH_MODE:-host}"
readonly BC_EH_FPL_ACTIVE_DISKS="${BC_EH_FPL_ACTIVE_DISKS:-1}"
readonly BC_EH_FPL_WORKLOAD="${BC_EH_FPL_WORKLOAD:-randread_4k}"
readonly BC_EH_FPL_RUNTIME_SECS="${BC_EH_FPL_RUNTIME_SECS:-60}"
readonly BC_EH_FPL_WARMUP_SECS="${BC_EH_FPL_WARMUP_SECS:-10}"
readonly BC_EH_FPL_REPEAT_INDEX="${BC_EH_FPL_REPEAT_INDEX:-1}"
readonly BC_EH_FPL_PER_DISK_DEPTH="${BC_EH_FPL_PER_DISK_DEPTH:-64}"
readonly BC_EH_FPL_HOST_CAN_QUEUE_LIMIT=1024
readonly BC_EH_FPL_DEV_SIZE_MB="${BC_EH_FPL_DEV_SIZE_MB:-128}"
readonly BC_EH_FPL_OUTPUT_MODE="${BC_EH_FPL_OUTPUT_MODE:-terminal}"
export SDEBUG_DELAY="${SDEBUG_DELAY:-0}"

BC_EH_FPL_RW=""
BC_EH_FPL_BS=""

bc_eh_fpl_usage()
{
    cat <<'EOF'
Usage:
  BC_EH_FPL_EH_MODE=host|sdev \
  BC_EH_FPL_ACTIVE_DISKS=1|2|4|8|16 \
  BC_EH_FPL_WORKLOAD=randread_4k|randread_16k|randread_64k|randread_256k|randwrite_4k|randwrite_16k|randwrite_64k|randwrite_256k \
  BC_EH_FPL_REPEAT_INDEX=<n> \
  sh run_fpl_hotpath_case.sh
EOF
}

bc_eh_fpl_set_workload()
{
    case "${BC_EH_FPL_WORKLOAD}" in
        randread_*)
            BC_EH_FPL_RW="randread"
            BC_EH_FPL_BS="${BC_EH_FPL_WORKLOAD#randread_}"
            ;;
        randwrite_*)
            BC_EH_FPL_RW="randwrite"
            BC_EH_FPL_BS="${BC_EH_FPL_WORKLOAD#randwrite_}"
            ;;
        *)
            bc_eh_fpl_usage >&2
            bc_eh_die "unsupported workload: ${BC_EH_FPL_WORKLOAD}"
            ;;
    esac

    case "${BC_EH_FPL_BS}" in
        4k|16k|64k|256k)
            ;;
        *)
            bc_eh_fpl_usage >&2
            bc_eh_die "unsupported block size in workload: ${BC_EH_FPL_WORKLOAD}"
            ;;
    esac
}

bc_eh_fpl_validate_inputs()
{
    case "${BC_EH_FPL_EH_MODE}" in
        host|sdev)
            ;;
        *)
            bc_eh_fpl_usage >&2
            bc_eh_die "unsupported eh mode: ${BC_EH_FPL_EH_MODE}"
            ;;
    esac

    case "${BC_EH_FPL_ACTIVE_DISKS}" in
        1|2|4|8|16)
            ;;
        *)
            bc_eh_fpl_usage >&2
            bc_eh_die "unsupported active disk count: ${BC_EH_FPL_ACTIVE_DISKS}"
            ;;
    esac

    [ "${BC_EH_FPL_RUNTIME_SECS}" -gt 0 ] || bc_eh_die "BC_EH_FPL_RUNTIME_SECS must be > 0"
    [ "${BC_EH_FPL_WARMUP_SECS}" -ge 0 ] || bc_eh_die "BC_EH_FPL_WARMUP_SECS must be >= 0"
    [ "${BC_EH_FPL_REPEAT_INDEX}" -gt 0 ] || bc_eh_die "BC_EH_FPL_REPEAT_INDEX must be > 0"
    [ "${BC_EH_FPL_PER_DISK_DEPTH}" -gt 0 ] || bc_eh_die "BC_EH_FPL_PER_DISK_DEPTH must be > 0"

    case "${BC_EH_FPL_OUTPUT_MODE}" in
        terminal|summary)
            ;;
        *)
            bc_eh_die "unsupported BC_EH_FPL_OUTPUT_MODE: ${BC_EH_FPL_OUTPUT_MODE}"
            ;;
    esac
}

bc_eh_fpl_cleanup_env()
{
    bc_eh_require_root

    if command -v pkill >/dev/null 2>&1; then
        pkill -9 -x fio >/dev/null 2>&1 || true
    fi

    rmmod scsi_debug >/dev/null 2>&1 || true
    rmmod crc_t10dif >/dev/null 2>&1 || true
    rmmod sg >/dev/null 2>&1 || true
    rmmod sr_mod >/dev/null 2>&1 || true
    rmmod sd_mod >/dev/null 2>&1 || true
}

bc_eh_fpl_load_scsi_debug()
{
    local host_can_queue="$1"
    local num_channels
    local num_tgts
    local max_luns
    local eh_reset_mask_arg=""

    set -- $(bc_eh_topology_geometry)
    num_channels="$1"
    num_tgts="$2"
    max_luns="$3"

    [ -d "${BC_EH_MODULE_DIR}" ] || bc_eh_die "module dir not found: ${BC_EH_MODULE_DIR}"
    [ -f "${BC_EH_CRC_T10DIF_KO}" ] || bc_eh_die "crc-t10dif module not found: ${BC_EH_CRC_T10DIF_KO}"
    [ -f "${BC_EH_SCSI_DEBUG_KO}" ] || bc_eh_die "scsi_debug module not found: ${BC_EH_SCSI_DEBUG_KO}"

    bc_eh_log "insmod ${BC_EH_CRC_T10DIF_KO}"
    insmod "${BC_EH_CRC_T10DIF_KO}" || bc_eh_die "failed to insmod ${BC_EH_CRC_T10DIF_KO}"

    if [ -n "${SDEBUG_EH_RESET_MASK:-}" ]; then
        eh_reset_mask_arg="eh_reset_mask=${SDEBUG_EH_RESET_MASK}"
    fi

    bc_eh_log "insmod ${BC_EH_SCSI_DEBUG_KO}: num_channels=${num_channels} num_tgts=${num_tgts} max_luns=${max_luns} host_max_queue=${host_can_queue} max_queue=${host_can_queue}${eh_reset_mask_arg:+ ${eh_reset_mask_arg}}"
    insmod "${BC_EH_SCSI_DEBUG_KO}" \
        add_host=1 \
        num_channels="${num_channels}" \
        num_tgts="${num_tgts}" \
        max_luns="${max_luns}" \
        host_max_queue="${host_can_queue}" \
        max_queue="${host_can_queue}" \
        dev_size_mb="${BC_EH_FPL_DEV_SIZE_MB}" \
        sector_size="${SDEBUG_SECTOR_SIZE:-512}" \
        dsense="${SDEBUG_DSENSE:-1}" \
        delay="${SDEBUG_DELAY}" \
        ${eh_reset_mask_arg} \
        || bc_eh_die "failed to insmod ${BC_EH_SCSI_DEBUG_KO}"

    if command -v mdev >/dev/null 2>&1; then
        bc_eh_log "run mdev -s"
        mdev -s || bc_eh_die "mdev -s failed"
    fi

    sleep "${SDEBUG_SETTLE_SECS:-1}"
}

bc_eh_fpl_set_queue_depth()
{
    local scsi_id="$1"
    local depth="$2"
    local qd_file="/sys/class/scsi_device/${scsi_id}/device/queue_depth"

    [ -e "${qd_file}" ] || bc_eh_die "queue_depth file not found: ${qd_file}"
    bc_eh_log "set queue_depth: echo ${depth} > ${qd_file}"
    printf '%s\n' "${depth}" > "${qd_file}"
}

bc_eh_fpl_set_nr_requests()
{
    local block_name="$1"
    local nr="$2"
    local nr_file="/sys/block/${block_name}/queue/nr_requests"

    [ -e "${nr_file}" ] || bc_eh_die "nr_requests file not found: ${nr_file}"
    bc_eh_log "set nr_requests: echo ${nr} > ${nr_file}"
    printf '%s\n' "${nr}" > "${nr_file}"
}

bc_eh_fpl_list_scsi_ids()
{
    local scsi_debug_host="$1"
    local host_no="${scsi_debug_host#host}"
    local dev_dir
    local scsi_id

    for dev_dir in "/sys/class/scsi_device/${host_no}:0:"*":0"; do
        [ -e "${dev_dir}" ] || continue
        scsi_id="$(basename "${dev_dir}")"
        printf '%s\n' "${scsi_id}"
    done | sort -t: -k3,3n -k4,4n
}

bc_eh_fpl_count_scsi_ids()
{
    local count=0
    local item

    for item in $1; do
        count=$((count + 1))
    done

    printf '%s\n' "${count}"
}

bc_eh_fpl_discover_devices()
{
    local scsi_debug_host="$1"
    local need_count="$2"
    local timeout_secs="${SDEBUG_WAIT_SECS:-15}"
    local scsi_list=""
    local count=0
    local slot=0
    local scsi_id
    local block_name

    while [ "${timeout_secs}" -gt 0 ]; do
        scsi_list="$(bc_eh_fpl_list_scsi_ids "${scsi_debug_host}")"
        count="$(bc_eh_fpl_count_scsi_ids "${scsi_list}")"
        if [ "${count}" -ge "${need_count}" ]; then
            break
        fi
        sleep 1
        timeout_secs=$((timeout_secs - 1))
    done

    if [ "${count}" -lt "${need_count}" ]; then
        bc_eh_die "only found ${count}/${need_count} scsi_debug devices on ${scsi_debug_host}; found: ${scsi_list:-<none>}"
    fi

    for scsi_id in ${scsi_list}; do
        [ "${slot}" -lt "${need_count}" ] || break
        block_name="$(bc_eh_wait_block_device "${scsi_id}" "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find block device for sdev ${scsi_id}"
        eval "BC_EH_FPL_SCSI_ID_${slot}='${scsi_id}'"
        eval "BC_EH_FPL_BLOCK_NAME_${slot}='${block_name}'"
        slot=$((slot + 1))
    done
}

bc_eh_fpl_active_targets()
{
    local count=0
    local output=""

    while [ "${count}" -lt "${BC_EH_FPL_ACTIVE_DISKS}" ]; do
        if [ -n "${output}" ]; then
            output="${output} "
        fi
        output="${output}${count}"
        count=$((count + 1))
    done

    printf '%s\n' "${output}"
}

bc_eh_fpl_print_config()
{
    local scsi_debug_host="$1"
    local active_targets="$2"
    local per_disk_depth="$3"
    local host_can_queue="$4"
    local target
    local scsi_id
    local block_name

    bc_eh_log "config: eh_mode=${BC_EH_FPL_EH_MODE} active_disks=${BC_EH_FPL_ACTIVE_DISKS} workload=${BC_EH_FPL_WORKLOAD} rw=${BC_EH_FPL_RW} bs=${BC_EH_FPL_BS} runtime=${BC_EH_FPL_RUNTIME_SECS}s warmup=${BC_EH_FPL_WARMUP_SECS}s repeat=${BC_EH_FPL_REPEAT_INDEX} sdebug_delay=${SDEBUG_DELAY}"
    bc_eh_log "config: scsi_debug_host=${scsi_debug_host} host_can_queue=${host_can_queue} max_queue=${host_can_queue} dev_size_mb=${BC_EH_FPL_DEV_SIZE_MB} per_disk_queue_depth=${per_disk_depth} per_disk_nr_requests=${per_disk_depth} per_disk_fio_iodepth=${per_disk_depth}"

    for target in ${active_targets}; do
        eval "scsi_id=\${BC_EH_FPL_SCSI_ID_${target}}"
        eval "block_name=\${BC_EH_FPL_BLOCK_NAME_${target}}"
        bc_eh_log "device: slot=${target} scsi_id=${scsi_id} block=/dev/${block_name}"
    done
}

bc_eh_fpl_run_fio()
{
    local phase="$1"
    local runtime_secs="$2"
    local iodepth="$3"
    local active_targets="$4"
    local fio_bin
    local fio_json
    local summary_direction
    local target
    local block_name

    fio_bin="$(bc_eh_resolve_fio_bin)" || bc_eh_die "fio binary not found"

    set -- \
        "--ioengine=libaio" \
        "--direct=1" \
        "--iodepth=${iodepth}" \
        "--rw=${BC_EH_FPL_RW}" \
        "--bs=${BC_EH_FPL_BS}" \
        "--numjobs=1" \
        "--thread=1" \
        "--size=100%" \
        "--time_based=1" \
        "--runtime=${runtime_secs}" \
        "--group_reporting=1"

    for target in ${active_targets}; do
        eval "block_name=\${BC_EH_FPL_BLOCK_NAME_${target}}"
        set -- "$@" "--name=target_${target}" "--filename=/dev/${block_name}"
    done

    if [ "${BC_EH_FPL_OUTPUT_MODE}" = "summary" ]; then
        fio_json="$("${fio_bin}" --output-format=json "$@" 2>/dev/null)" || bc_eh_die "fio ${phase} failed"
        if [ "${phase}" = "measure" ]; then
            if [ "${BC_EH_FPL_RW}" = "randwrite" ]; then
                summary_direction="write"
            else
                summary_direction="read"
            fi
            printf '%s\n' "${fio_json}" | awk -v direction="${summary_direction}" '
                function emit_result() {
                    if (!printed && iops != "" && avg_clat_ns != "" && p99_clat_ns != "") {
                        printf "FPL_RESULT iops=%.2f avg_clat_us=%.3f p99_clat_us=%.3f\n", \
                            iops + 0.0, (avg_clat_ns + 0.0) / 1000.0, (p99_clat_ns + 0.0) / 1000.0
                        printed = 1
                    }
                }
                function field_value(line, value) {
                    value = line
                    sub(/^[^:]*:[[:space:]]*/, "", value)
                    gsub(/[ ,]/, "", value)
                    return value
                }
                /"jobname"[[:space:]]*:/ && !job_seen {
                    job_seen = 1
                }
                /"groupid"[[:space:]]*:[[:space:]]*4294967295/ && job_seen {
                    exit
                }
                job_seen && $0 ~ ("\"" direction "\"[[:space:]]*:[[:space:]]*[{]") {
                    in_dir = 1
                    next
                }
                job_seen && in_dir && /"iops"[[:space:]]*:/ && iops == "" {
                    iops = field_value($0)
                    emit_result()
                    next
                }
                job_seen && in_dir && /"clat_ns"[[:space:]]*:[[:space:]]*[{]/ {
                    in_clat = 1
                    next
                }
                job_seen && in_clat && /"mean"[[:space:]]*:/ && avg_clat_ns == "" {
                    avg_clat_ns = field_value($0)
                    emit_result()
                    next
                }
                job_seen && in_clat && /"percentile"[[:space:]]*:[[:space:]]*[{]/ {
                    in_pct = 1
                    next
                }
                job_seen && in_pct && /"99\.000000"[[:space:]]*:/ && p99_clat_ns == "" {
                    p99_clat_ns = field_value($0)
                    emit_result()
                    next
                }
                END {
                    if (!printed || iops == "" || avg_clat_ns == "" || p99_clat_ns == "") {
                        exit 1
                    }
                }
            ' || bc_eh_die "failed to summarize fio ${phase} output"
        fi
        return 0
    fi

    printf '\n[%s] === fio %s start ===\n' "$(date '+%F %T')" "${phase}"
    "${fio_bin}" \
        "$@" || bc_eh_die "fio ${phase} failed"
    printf '[%s] === fio %s end ===\n\n' "$(date '+%F %T')" "${phase}"
}

main()
{
    local per_disk_depth
    local host_can_queue
    local active_targets
    local scsi_debug_host
    local target
    local scsi_id
    local block_name

    bc_eh_fpl_set_workload
    bc_eh_fpl_validate_inputs

    per_disk_depth="${BC_EH_FPL_PER_DISK_DEPTH}"
    host_can_queue=$((per_disk_depth * BC_EH_FPL_ACTIVE_DISKS))
    [ "${host_can_queue}" -le "${BC_EH_FPL_HOST_CAN_QUEUE_LIMIT}" ] || \
        bc_eh_die "host_can_queue=${host_can_queue} exceeds scsi_debug limit ${BC_EH_FPL_HOST_CAN_QUEUE_LIMIT}"
    active_targets="$(bc_eh_fpl_active_targets)"

    bc_eh_fpl_cleanup_env
    bc_eh_fpl_load_scsi_debug "${host_can_queue}"
    scsi_debug_host="$(bc_eh_wait_scsi_debug_host "${SDEBUG_WAIT_SECS:-15}")" || bc_eh_die "failed to find scsi_debug host"
    bc_eh_set_host_eh_mode "${scsi_debug_host}" "${BC_EH_FPL_EH_MODE}"
    bc_eh_fpl_discover_devices "${scsi_debug_host}" "${BC_EH_FPL_ACTIVE_DISKS}"

    for target in ${active_targets}; do
        eval "scsi_id=\${BC_EH_FPL_SCSI_ID_${target}}"
        eval "block_name=\${BC_EH_FPL_BLOCK_NAME_${target}}"
        bc_eh_fpl_set_queue_depth "${scsi_id}" "${per_disk_depth}"
        bc_eh_fpl_set_nr_requests "${block_name}" "${per_disk_depth}"
    done

    bc_eh_fpl_print_config "${scsi_debug_host}" "${active_targets}" "${per_disk_depth}" "${host_can_queue}"

    if [ "${BC_EH_FPL_WARMUP_SECS}" -gt 0 ]; then
        bc_eh_fpl_run_fio "warmup" "${BC_EH_FPL_WARMUP_SECS}" "${per_disk_depth}" "${active_targets}"
    fi
    bc_eh_fpl_run_fio "measure" "${BC_EH_FPL_RUNTIME_SECS}" "${per_disk_depth}" "${active_targets}"
}

main "$@"
