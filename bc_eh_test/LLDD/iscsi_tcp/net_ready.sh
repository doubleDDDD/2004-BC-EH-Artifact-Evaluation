#!/usr/bin/env bash
set -euo pipefail

: "${BC_EH_ISCSI_PORTAL_IP:?set BC_EH_ISCSI_PORTAL_IP}"

sudo ip link add br-iscsi type bridge
sudo ip addr add "${BC_EH_ISCSI_PORTAL_IP}/24" dev br-iscsi
sudo ip link set br-iscsi up

sudo ip tuntap add dev tap-iscsi0 mode tap user "$USER"
sudo ip link set tap-iscsi0 master br-iscsi
sudo ip link set tap-iscsi0 up
