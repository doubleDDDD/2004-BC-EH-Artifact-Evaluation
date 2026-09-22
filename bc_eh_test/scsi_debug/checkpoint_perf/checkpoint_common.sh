# Shared helpers for the scsi_debug checkpoint convergence benchmark.

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../scsi_debug_common.sh"

bc_cp_die()
{
    bc_eh_die "checkpoint_perf: $*"
}

bc_cp_log()
{
    bc_eh_log "checkpoint_perf: $*"
}

bc_cp_ensure_debugfs()
{
    mkdir -p /sys/kernel/debug

    if awk '$2 == "/sys/kernel/debug" && $3 == "debugfs" { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
    then
        return 0
    fi

    if mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; then
        return 0
    fi

    if awk '$2 == "/sys/kernel/debug" && $3 == "debugfs" { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
    then
        return 0
    fi

    bc_cp_die "failed to mount debugfs"
}

bc_cp_cleanup_scsi_debug()
{
    bc_eh_cleanup_scsi_debug_env
}

bc_cp_wait_scsi_debug_host()
{
    bc_eh_wait_scsi_debug_host "$@"
}

bc_cp_count_scsi_devices()
{
    local host_no="$1"
    local host_idx="${host_no#host}"
    local dev_dir
    local count=0

    for dev_dir in /sys/class/scsi_device/"${host_idx}":*:*:*; do
        [ -e "${dev_dir}" ] || continue
        count=$((count + 1))
    done

    printf '%s\n' "${count}"
}

bc_cp_wait_for_scsi_devices()
{
    local host_no="$1"
    local expected="$2"
    local timeout_secs="$3"
    local deadline
    local now
    local count

    deadline=$(( $(date +%s) + timeout_secs ))

    while :; do
        now="$(date +%s)"
        [ "${now}" -le "${deadline}" ] || break
        count="$(bc_cp_count_scsi_devices "${host_no}")"
        if [ "${count}" -eq "${expected}" ]; then
            printf '%s\n' "${count}"
            return 0
        fi
        sleep 1
    done

    return 1
}

bc_cp_checkpoint_dir()
{
    local host_no="$1"
    printf '/sys/kernel/debug/scsi_debug/%s/checkpoint_bench\n' "${host_no}"
}

bc_cp_read_result_field()
{
    local result_file="$1"
    local key="$2"

    sed -n "s/^${key}=//p" "${result_file}" | head -n 1
}

bc_cp_field_from_line()
{
    local line="$1"
    local key="$2"

    printf '%s\n' "${line}" | sed -n "s/.* ${key}=\\([^ ]*\\).*/\\1/p"
}

bc_cp_stat_series()
{
    local series_file="$1"

    awk '
        NF {
            x[count] = $1 + 0.0;
            sum += x[count];
            count += 1;
        }
        END {
            if (count == 0) {
                printf "0|0";
                exit;
            }

            for (i = 0; i < count - 1; i++) {
                for (j = i + 1; j < count; j++) {
                    if (x[i] > x[j]) {
                        tmp = x[i];
                        x[i] = x[j];
                        x[j] = tmp;
                    }
                }
            }

            if (count % 2 == 1) {
                median = x[(count - 1) / 2];
            } else {
                median = (x[count / 2 - 1] + x[count / 2]) / 2.0;
            }

            idx = int((95 * count + 99) / 100);
            if (idx < 1)
                idx = 1;
            if (idx > count)
                idx = count;

            printf "%.0f|%.0f", median, x[idx - 1];
        }
    ' "${series_file}"
}
