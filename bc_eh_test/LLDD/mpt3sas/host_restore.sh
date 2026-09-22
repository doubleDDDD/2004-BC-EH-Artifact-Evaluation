#!/usr/bin/env bash
set -e

PCI_BDF="${BC_EH_MPT3SAS_BDF:-0000:8b:00.0}"

if [ -L "/sys/bus/pci/devices/${PCI_BDF}/driver" ]; then
    CUR_DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/${PCI_BDF}/driver")")"
    if [ "${CUR_DRIVER}" = "vfio-pci" ]; then
        printf '%s\n' "${PCI_BDF}" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind >/dev/null
    fi
fi

sudo modprobe -r mpt3sas 2>/dev/null || true
sudo modprobe mpt3sas

printf 'mpt3sas\n' | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver_override" >/dev/null
printf '%s\n' "${PCI_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null
printf '\n' | sudo tee "/sys/bus/pci/devices/${PCI_BDF}/driver_override" >/dev/null
