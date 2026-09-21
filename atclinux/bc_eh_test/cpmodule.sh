#!/bin/bash
set -eu

cp -f ../drivers/scsi/scsi_debug.ko build_ramdisk/initrmfs/double_D/modules/
cp -f ../lib/crc/crc-t10dif.ko build_ramdisk/initrmfs/double_D/modules/
# cp ../drivers/scsi/iscsi_tcp.ko build_ramdisk/initrmfs/double_D/modules/
cp -f ../drivers/scsi/mpt3sas/mpt3sas.ko build_ramdisk/initrmfs/double_D/modules/
cp -f ../drivers/scsi/megaraid/megaraid_sas.ko build_ramdisk/initrmfs/double_D/modules/