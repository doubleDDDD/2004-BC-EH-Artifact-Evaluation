#!/usr/bin/env bash
set -e

PCI_BDF="${BC_EH_MEGA_BDF:-0000:8a:00.0}"

if [ -L "/sys/bus/pci/devices/${PCI_BDF}/driver" ]; then
    CUR_DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/${PCI_BDF}/driver")")"
    if [ "${CUR_DRIVER}" = "vfio-pci" ]; then
        printf '%s\n' "${PCI_BDF}" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind >/dev/null
    fi
fi

sudo modprobe -r megaraid_sas 2>/dev/null || true
sudo modprobe megaraid_sas

printf 'megaraid_sas\n' | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver_override" >/dev/null
printf '%s\n' "${PCI_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null
printf '\n' | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver_override" >/dev/null
