#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/root/kafka_2.13-4.2.0/config"
CLUSTER_NET_IF="${CLUSTER_NET_IF:-enp0s3}"
QUORUM_VOTERS="1@10.20.0.11:9093,2@10.20.0.12:9093,3@10.20.0.13:9093"
KAFKA_LOG_SUBDIR="${KAFKA_LOG_SUBDIR:-kafka-logs}"

log() {
    printf '[kafka-config] %s\n' "$*"
}

warn() {
    printf '[kafka-config][warn] %s\n' "$*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must run as root." >&2
        exit 1
    fi
}

detect_local_broker_id() {
    local cluster_ip=''

    cluster_ip="$(
        ip -4 -o addr show dev "$CLUSTER_NET_IF" 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -n 1
    )"

    case "$cluster_ip" in
        10.20.0.11) echo 1 ;;
        10.20.0.12) echo 2 ;;
        10.20.0.13) echo 3 ;;
        *) return 1 ;;
    esac
}

write_config() {
    local broker_id="$1"
    local broker_ip="$2"
    local output_file="$CONFIG_DIR/kafka-$broker_id.properties"
    local log_dirs="/data/kafka-1/${KAFKA_LOG_SUBDIR},/data/kafka-2/${KAFKA_LOG_SUBDIR},/data/kafka-3/${KAFKA_LOG_SUBDIR}"

    cat > "$output_file" <<EOF
process.roles=broker,controller
node.id=$broker_id

listeners=PLAINTEXT://:9092,CONTROLLER://:9093
advertised.listeners=PLAINTEXT://$broker_ip:9092
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER

controller.quorum.voters=$QUORUM_VOTERS

log.dirs=$log_dirs
metadata.log.dir=/var/lib/kafka-metadata

default.replication.factor=3
min.insync.replicas=2
num.partitions=48
unclean.leader.election.enable=false
auto.create.topics.enable=false

offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
EOF

    chmod 644 "$output_file"
    log "Regenerated $output_file"
}

show_summary() {
    log "Generated config summary:"
    grep -E '^(node.id|advertised.listeners|controller.quorum.voters|log.dirs|metadata.log.dir)=' \
        "$CONFIG_DIR"/kafka-[123].properties
}

main() {
    local local_broker_id=''
    require_root

    mkdir -p "$CONFIG_DIR"

    write_config 1 10.20.0.11
    write_config 2 10.20.0.12
    write_config 3 10.20.0.13

    show_summary

    if local_broker_id="$(detect_local_broker_id)"; then
        log "Local broker should use: $CONFIG_DIR/kafka-$local_broker_id.properties"
    else
        warn "Could not infer local broker id from $CLUSTER_NET_IF; choose kafka-1/2/3.properties manually"
    fi
}

main "$@"
