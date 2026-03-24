#! /bin/bash
# Copyright (c) 2017 Nutanix Inc. All rights reserved.
SCRIPT_VERSION="6.1.2"

date
TEMPDISK_SIZE_FILE="/etc/tempdisk_sizefile"
FSTAB="/etc/fstab"
FSTAB_BACK="/etc/fstab.bak"
AZURE_AGENT="/etc/waagent.conf"
MOUNT_POINT_VAR="ResourceDisk.MountPoint="
CP_CMD="/bin/cp -rf"

get_partitions() {
    awk -v disk="$1" '$4 ~ disk && $4 != disk {print $4}' /proc/partitions
}

echo -e "\n*** Mounting temporary disk on target VM ***\n"

# Keep a backup of /etc/fstab
echo "Backing up ${FSTAB} to ${FSTAB_BACK}"
${CP_CMD} ${FSTAB} ${FSTAB_BACK}

# Clear the immutable flag and make it writable
chattr -i ${FSTAB}
chmod +rw ${FSTAB}
error="-1"
if [ -f "$TEMPDISK_SIZE_FILE" ]; then
    temp_disk_size=$(cat "$TEMPDISK_SIZE_FILE")
    disks=$(awk -v temp_disk_size="$temp_disk_size" '$3 == temp_disk_size {print $4}' /proc/partitions)
    num_disks=$(echo $disks | wc -w)
    echo "Number of disks with size ${temp_disk_size} found: ${num_disks}"
    if [[ ${num_disks} -eq 0 ]]; then
        echo "Temporary Disk not found"
    fi

    for disk in ${disks}; do
        num_partitions=$(get_partitions $disk | wc -w)
        if [[ ${num_partitions} -ne "0" ]]; then
            continue
        fi
        parted /dev/$disk --script mklabel msdos mkpart primary ext4 0% 100%
        rc=$?
        if [ $rc != 0 ]; then
            echo "Could not partition the disk"
            error = $rc
            break
        fi
        sleep 1
        partition=$(get_partitions $disk)
        num_partitions=$(echo $partition | wc -w)
        if [[ ${num_partitions} -ne 1 ]]; then
            echo "Partition not created"
            error=1
            break
        fi
        partition=/dev/$partition
        #Format partition
        mkfs.ext4 -F $partition
        rc=$?
        if [ $rc != 0 ]; then
            echo "Formatting of partition ${partition} failed."
            error = $rc
            break
        fi
        partprobe /dev/$disk
        rc=$?
        if [ $rc != 0 ]; then
            echo "Partition Table could not be reloaded"
            error = $rc
            break
        fi
        mount_point=$(cat $AZURE_AGENT | grep "$MOUNT_POINT_VAR" | sed -n "/$MOUNT_POINT_VAR/s/$MOUNT_POINT_VAR//p")
        if [ -z "$mount_point" ]; then
            mount_point="/mnt"
        fi
        mount $partition $mount_point
        rc=$?
        if [ $rc != 0 ]; then
            echo "Mount ${partition} failed."
            error = $rc
            break
        fi
        uuid=$(blkid $partition | sed -n 's/.*\sUUID=\"\([^\"]*\)\".*/\1/p')
        if [ -n "${uuid}" ]; then
            echo "Fixing ${FSTAB}"
            # Use * as the delimiter
            flag=$(cat ${FSTAB} | grep /dev/disk/cloud/azure_resource-part1 | wc -l)
            if [[ ${flag} -gt "0" ]]; then
                sed "s*/dev/disk/cloud/azure_resource-part1*UUID=${uuid}*g" -i ${FSTAB}
                sed "s*x-systemd.requires=cloud-init.service,**g" -i ${FSTAB}
            else
                echo "UUID=${uuid} ${mount_point} ext4 defaults 0 0" >>${FSTAB}
            fi
        fi
        # Perform a dry-run for mount
        echo "Performing a dry-run of mount with ${FSTAB}."
        mount -fav

        rc=$?
        if [ $rc -ne 0 ]; then
            echo "Dry-run of mount failed. Restoring ${FSTAB} from ${FSTAB_BACK}."
            ${CP_CMD} ${FSTAB_BACK} ${FSTAB}
            error = $rc
        fi
        error=0
        break
    done
else
    error=0
fi

echo "ConfigureTempDisk_debug : Removing $TEMPDISK_SIZE_FILE"

# Remove the size file
rm -f ${TEMPDISK_SIZE_FILE}

if [ $error -eq "-1" ]; then
    echo "Could not find temporary disk"
fi
if [ $error -ne "0" ]; then
    echo "Some error with configuring temporary disk"
fi

echo "Stopping waagent"
# Stop the service from running in future
if [ -f /etc/redhat-release ]; then
    systemctl disable waagent
elif [ -f /etc/debian_version ]; then
    systemctl disable walinuxagent
    if [ -f /etc/init/walinuxagent.conf ]; then
        mv /etc/init/walinuxagent.conf /etc/init/walinuxagent.conf.bak
    fi
elif [ -f /etc/SuSE-release ]; then
    systemctl disable waagent
fi

exit $error
