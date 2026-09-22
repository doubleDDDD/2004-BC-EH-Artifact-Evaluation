# http://nickdesaulniers.github.io/blog/2018/10/24/booting-a-custom-linux-kernel-in-qemu-and-debugging-it-with-gdb/
# https://wiki.archlinux.org/index.php/QEMU_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)

# path
DIR_CUR = $(shell pwd)
KERNEL_ROOT = $(DIR_CUR)/../
BZIMAGE = $(KERNEL_ROOT)/arch/x86/boot/bzImage
OVMF = $(KERNEL_ROOT)/edk2/Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd
BIOS = $(DIR_CUR)/bios.bin
# mkinitramfs -o auto_ramdisk.img
AUTO_RAMDISK = $(DIR_CUR)/auto_ramdisk.img
# manual initrmfs
# find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../manual_ramdisk.img
MANUAL_RAMDISK_DIR = $(DIR_CUR)/build_ramdisk/
GEN_MANUAL_RAMDISK_DIR = $(MANUAL_RAMDISK_DIR)/initrmfs/
GEN_MANUAL_RAMDISK_SHELL = $(GEN_MANUAL_RAMDISK_DIR)/gen.sh
MANUAL_RAMDISK = $(MANUAL_RAMDISK_DIR)/manual_ramdisk.img

# start qemu
QEMU = qemu-system-x86_64

# qemu parameter
# -kernel bzImage use 'bzImage' as kernel image
PARAMETER := -kernel $(BZIMAGE) 
# PARAMETER += -hda $(HDIMG)
# nographic disable graphical output and redirect serial I/Os to console
PARAMETER += -nographic 
# -initrd file    use 'file' as initial ram disk
# PARAMETER += -initrd $(AUTO_RAMDISK)
PARAMETER += -initrd $(MANUAL_RAMDISK)
# -append cmdline use 'cmdline' as kernel command line
PARAMETER += -append "console=ttyS0 nokaslr memmap=2M\$$1G"  # kernel cmdline, What the kernel actually needs is memmap=2M$1G. Since this is a shell script, it involves various escape sequences.
# i meet a problem, Could not access KVM kernel module: No such file or directory
# maybe i need to enter bios to enable virtualization
PARAMETER += --enable-kvm
# -m configure guest
PARAMETER += -m 8G

PARAMETER += -smp 128,threads=2,cores=32,sockets=2

# BIOS compiled from EDK2
PARAMETER += -bios $(BIOS)

PARAMETER +=

# QEMU passes the host's PCIe HBA to the VM inside QEMU via VFIO.
HBA_HOST := 0000:8a:00.0
MPT3SAS_HOST := 0000:8b:00.0
HBA_PARAMETER_1 += -cpu host
HBA_PARAMETER_1 += -machine q35,accel=kvm,kernel-irqchip=split
HBA_PARAMETER_1 += -device intel-iommu,intremap=on,caching-mode=on # The key point is the intremap parameter; all other parameters serve to enable this parameter.
# To use multiple MSI interrupt vectors in QEMU, you need to use Intel IOMMU's interrupt
# remapping. The key is to enable intremap in the IOMMU. In addition to enabling IOMMU on
# the host machine, there are two other places that need to be configured: the QEMU startup
# parameters need to set intremap=on, and the kernel image of the virtual machine also needs to
# have IOMMU enabled during compilation.
# Device Drivers->IOMMU Hardware Support->Support for Interrupt Remapping
HBA_PARAMETER_2 := -device vfio-pci,host=$(HBA_HOST)


BASE_PARAMETER := -name ubuntu-base \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=./ubuntu20046_x86_64.img,format=qcow2,if=virtio \
	-netdev user,id=mgmt-base,hostfwd=tcp:127.0.0.1:2222-:22 \
	-device virtio-net-pci,netdev=mgmt-base,mac=52:54:00:10:00:01 \
	-display none \
	-daemonize


KAFKA_JBOD_PARAMETER_1 := -name kafka-1 \
	-m 8G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../kafka1-os.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt1,hostfwd=tcp:127.0.0.1:2201-:22 \
	-device virtio-net-pci,netdev=mgmt1,mac=52:54:00:10:10:11 \
	-netdev socket,id=cluster1,mcast=239.192.168.1:1102 \
	-device virtio-net-pci,netdev=cluster1,mac=52:54:00:20:20:11 \
	-display none \
	-daemonize
# -nographic -serial mon:stdio

KAFKA_JBOD_PARAMETER_2 := -name kafka-2 \
	-m 8G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../kafka2-os.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt2,hostfwd=tcp:127.0.0.1:2202-:22 \
	-device virtio-net-pci,netdev=mgmt2,mac=52:54:00:10:10:12 \
	-netdev socket,id=cluster2,mcast=239.192.168.1:1102 \
	-device virtio-net-pci,netdev=cluster2,mac=52:54:00:20:20:12 \
	-display none \
	-daemonize
#-nographic -serial mon:stdio

KAFKA_JBOD_PARAMETER_3 := -name kafka-3 \
	-m 8G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../kafka3-os.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt3,hostfwd=tcp:127.0.0.1:2203-:22 \
	-device virtio-net-pci,netdev=mgmt3,mac=52:54:00:10:10:13 \
	-netdev socket,id=cluster3,mcast=239.192.168.1:1102 \
	-device virtio-net-pci,netdev=cluster3,mac=52:54:00:20:20:13 \
	-display none \
	-daemonize
# -nographic -serial mon:stdio

KAFKA_CLIENT_PARAMETER := -name kafka-client \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 2,sockets=1,cores=2,threads=1 \
	-drive file=../../kafka-client-os.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt4,hostfwd=tcp:127.0.0.1:2204-:22 \
	-device virtio-net-pci,netdev=mgmt4,mac=52:54:00:10:10:21 \
	-netdev socket,id=cluster4,mcast=239.192.168.1:1102 \
	-device virtio-net-pci,netdev=cluster4,mac=52:54:00:20:20:21 \
	-display none \
	-daemonize

# sudo ip link add br-iscsi type bridge
# sudo ip addr add 10.66.0.1/24 dev br-iscsi
# sudo ip link set br-iscsi up

# sudo ip tuntap add dev tap-iscsi0 mode tap user "$USER"
# sudo ip link set tap-iscsi0 master br-iscsi
# sudo ip link set tap-iscsi0 up

# 登录 ssh -p 2210 zc@127.0.0.1

ISCSI_VM_PARAMETER := -name iscsi-vm \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../iscsi.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
	-display none \
	-daemonize

MEGA_VM_PARAMETER := -name mega-vm \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../iscsi.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
	-device intel-iommu,intremap=on,caching-mode=on \
	-device vfio-pci,host=$(HBA_HOST) \
	-display none \
	-daemonize

MPT3SAS_VM_PARAMETER := -name mpt3sas-vm \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=../../iscsi.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
	-device intel-iommu,intremap=on,caching-mode=on \
	-device vfio-pci,host=$(MPT3SAS_HOST),rombar=0 \
	-boot order=c,strict=on \
	-display none \
	-daemonize

.PHONY:help
help:
	@echo make dr  -- start debug kernel without dev
	@echo make dhba  -- start debug pcie scsi host, hba
	@echo make kafka  -- start all kafka jbod VMs and client VM
	@echo make kafka1/2/3  -- start single kafka jbod broker VM
	@echo make kafka-client -- start kafka client VM
	@echo make kafka-stop -- stop all kafka jbod VMs and client VM
	@echo make kafka-ps -- show kafka jbod qemu processes
	@echo make mega -- start qcow2 VM with MegaRAID passthrough
	@echo make mega-stop -- stop MegaRAID passthrough VM
	@echo make mega-ps -- show MegaRAID passthrough VM
	@echo make mpt3sas -- start qcow2 VM with mpt3sas passthrough
	@echo make mpt3sas-stop -- stop mpt3sas passthrough VM
	@echo make mpt3sas-ps -- show mpt3sas passthrough VM
	@echo make mad -- gen manual ramdisk.img
	@echo make aud -- gen auto ramdisk.img

.PHONY:dr
dr:
	$(QEMU) $(PARAMETER) $(HBA_PARAMETER_1)

.PHONY:dhba
dhba:
	$(QEMU) $(PARAMETER) $(HBA_PARAMETER_1) $(HBA_PARAMETER_2)

.PHONY:kafka
kafka: kafka1 kafka2 kafka3 kafka-client
	@echo "Kafka JBOD VMs started: 2201/2202/2203, client: 2204"

.PHONY:kafka-ps
kafka-ps:
	@ps -ef | grep '[q]emu-system-x86_64 .* -name kafka' || echo "No Kafka QEMU VMs running"

.PHONY:kafka-stop
kafka-stop:
	pkill -f '^qemu-system-x86_64 .* -name kafka-1( |$$)' || true
	pkill -f '^qemu-system-x86_64 .* -name kafka-2( |$$)' || true
	pkill -f '^qemu-system-x86_64 .* -name kafka-3( |$$)' || true
	pkill -f '^qemu-system-x86_64 .* -name kafka-client( |$$)' || true

.PHONY:kafka1
kafka1:
	$(QEMU) $(KAFKA_JBOD_PARAMETER_1)

.PHONY:kafka2
kafka2:
	$(QEMU) $(KAFKA_JBOD_PARAMETER_2)

.PHONY:kafka3
kafka3:
	$(QEMU) $(KAFKA_JBOD_PARAMETER_3)
  .PHONY:kafka-client

.PHONY:kafka-client
kafka-client:
	$(QEMU) $(KAFKA_CLIENT_PARAMETER)

.PHONY: iscsi
iscsi:
	$(QEMU) $(ISCSI_VM_PARAMETER)

.PHONY: iscsi-stop
iscsi-stop:
	pkill -f '^qemu-system-x86_64 .* -name iscsi-vm( |$$)' || true

.PHONY: iscsi-ps
iscsi-ps:
	@ps -ef | grep '[q]emu-system-x86_64 .* -name iscsi-vm' || echo "No iSCSI QEMU VM running"

.PHONY: mega
mega:
	$(QEMU) $(MEGA_VM_PARAMETER)

.PHONY: mega-stop
mega-stop:
	pkill -f '^qemu-system-x86_64 .* -name mega-vm( |$$)' || true

.PHONY: mega-ps
mega-ps:
	@ps -ef | grep '[q]emu-system-x86_64 .* -name mega-vm' || echo "No MegaRAID passthrough QEMU VM running"

.PHONY: mpt3sas
mpt3sas:
	$(QEMU) $(MPT3SAS_VM_PARAMETER)

.PHONY: mpt3sas-stop
mpt3sas-stop:
	pkill -f '^qemu-system-x86_64 .* -name mpt3sas-vm( |$$)' || true

.PHONY: mpt3sas-ps
mpt3sas-ps:
	@ps -ef | grep '[q]emu-system-x86_64 .* -name mpt3sas-vm' || echo "No mpt3sas passthrough QEMU VM running"

GEN_AUTO_RAMDISK = $(shell mkinitramfs -o auto_ramdisk.img)
.PHONY:aud
aud:
	@echo $(GEN_AUTO_RAMDISK)

.PHONY:mad
mad: 
	@cd $(GEN_MANUAL_RAMDISK_DIR) && bash $(GEN_MANUAL_RAMDISK_SHELL)

.PHONY:test
test:
	@echo do check

.PHONY:clean
clean:
	@echo clean done
