#!/usr/bin/env bash
set -euo pipefail

sudo ip link set tap-iscsi0 down 2>/dev/null || true
sudo ip link delete tap-iscsi0 2>/dev/null || true
sudo ip link set br-iscsi down 2>/dev/null || true
sudo ip link delete br-iscsi 2>/dev/null || true
