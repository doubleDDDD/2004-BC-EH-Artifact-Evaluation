#!/usr/bin/env bash
set -e

PCI_BDF="${BC_EH_MPT3SAS_BDF:-0000:8b:00.0}"

sudo ip link add br-iscsi type bridge 2>/dev/null || true
sudo ip addr add 10.66.0.1/24 dev br-iscsi 2>/dev/null || true
sudo ip link set br-iscsi up

sudo ip tuntap add dev tap-iscsi0 mode tap user "${SUDO_USER:-$USER}" 2>/dev/null || true
sudo ip link set tap-iscsi0 master br-iscsi
sudo ip link set tap-iscsi0 up

sudo modprobe vfio-pci
if [ -L "/sys/bus/pci/devices/${PCI_BDF}/driver" ]; then
    printf '%s\n' "${PCI_BDF}" | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver/unbind" >/dev/null
fi
printf 'vfio-pci\n' | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver_override" >/dev/null
printf '%s\n' "${PCI_BDF}" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind >/dev/null
