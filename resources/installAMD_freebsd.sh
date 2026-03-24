#!/bin/sh
# Copyright (c) 2017 Nutanix Inc. All rights reserved.

set -x
sourcefilepath="$0"
echo "Running $sourcefilepath"

if [ $(id -u) != 0 ]; then # check if you are root
  chmod 755 $sourcefilepath
  echo Starting the script as root
  ./sudoTermFreeBSD -s "$sourcefilepath"
  exit $?
fi

date
drivers="virtio virtio_scsi virtio_balloon virtio_blk virtio_pci vtnet"
custom_drivers="$1"
if [ ! -z "$custom_drivers" ]; then
  drivers=$custom_drivers
fi
rc_conf_file="/etc/rc.conf"
echo 'kld_list="'"$drivers"'"' >>"$rc_conf_file"
for driver in $drivers; do
  kldload -n "$driver"
done
exit 0
