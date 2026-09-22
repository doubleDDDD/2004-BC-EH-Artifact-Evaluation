# start qemu
QEMU = qemu-system-x86_64

KAFKA_JBOD_PARAMETER_1 := -name kafka-1 \
	-m 8G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=./kafka1-os.qcow2,format=qcow2,if=virtio \
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
	-drive file=./kafka2-os.qcow2,format=qcow2,if=virtio \
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
	-drive file=./kafka3-os.qcow2,format=qcow2,if=virtio \
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
	-drive file=./kafka-client-os.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt4,hostfwd=tcp:127.0.0.1:2204-:22 \
	-device virtio-net-pci,netdev=mgmt4,mac=52:54:00:10:10:21 \
	-netdev socket,id=cluster4,mcast=239.192.168.1:1102 \
	-device virtio-net-pci,netdev=cluster4,mac=52:54:00:20:20:21 \
	-display none \
	-daemonize

ISCSI_VM_PARAMETER := -name iscsi-vm \
	-m 4G \
	-cpu host \
	-machine q35,accel=kvm,kernel-irqchip=split \
	-enable-kvm \
	-smp 4,sockets=1,cores=4,threads=1 \
	-drive file=./iscsi.qcow2,format=qcow2,if=virtio \
	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
	-display none \
	-daemonize

# The following passthrough VM configurations require specific local HBA/RAID hardware,
# so they are kept commented out by default.

# MEGA_VM_PARAMETER := -name mega-vm \
# 	-m 4G \
# 	-cpu host \
# 	-machine q35,accel=kvm,kernel-irqchip=split \
# 	-enable-kvm \
# 	-smp 4,sockets=1,cores=4,threads=1 \
# 	-drive file=../../iscsi.qcow2,format=qcow2,if=virtio \
# 	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
# 	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
# 	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
# 	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
# 	-device intel-iommu,intremap=on,caching-mode=on \
# 	-device vfio-pci,host=$(HBA_HOST) \
# 	-display none \
# 	-daemonize

# MPT3SAS_VM_PARAMETER := -name mpt3sas-vm \
# 	-m 4G \
# 	-cpu host \
# 	-machine q35,accel=kvm,kernel-irqchip=split \
# 	-enable-kvm \
# 	-smp 4,sockets=1,cores=4,threads=1 \
# 	-drive file=../../iscsi.qcow2,format=qcow2,if=virtio \
# 	-netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:2210-:22 \
# 	-device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:30:01 \
# 	-netdev tap,id=iscsi0,ifname=tap-iscsi0,script=no,downscript=no \
# 	-device virtio-net-pci,netdev=iscsi0,mac=52:54:00:20:30:01 \
# 	-device intel-iommu,intremap=on,caching-mode=on \
# 	-device vfio-pci,host=$(MPT3SAS_HOST),rombar=0 \
# 	-boot order=c,strict=on \
# 	-display none \
# 	-daemonize

.PHONY:help
help:
	@echo make iscsi  -- start iSCSI/scsi_debug Ubuntu VM
	@echo make kafka  -- start all kafka jbod VMs and client VM
	@echo make kafka1/2/3  -- start single kafka jbod broker VM
	@echo make kafka-client -- start kafka client VM

.PHONY:kafka
kafka: kafka1 kafka2 kafka3 kafka-client
	@echo "Kafka JBOD VMs started: 2201/2202/2203, client: 2204"

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
kafka-client:
	$(QEMU) $(KAFKA_CLIENT_PARAMETER)

.PHONY: iscsi
iscsi:
	$(QEMU) $(ISCSI_VM_PARAMETER)
