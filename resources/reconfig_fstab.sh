#! /bin/sh
# Copyright (c) 2023 Nutanix Inc. All rights reserved.

set -x
sourcefilepath="$0"
echo "Running $sourcefilepath"

CP_CMD="/bin/cp -rf"
MV_CMD="/bin/mv -f"
FSTAB="/etc/fstab"
FSTAB_BAK="/etc/fstab.nxbak"

if [ $(id -u) != 0 ]; then # check if you are root
    chmod 755 $sourcefilepath
    echo Starting the script as root
    ./sudoTerm -s "$sourcefilepath"
    exit $?
fi

## Function to fix the /etc/fstab entries with UUIDs instead of names
fix_fstab() {
    if [ ! -f ${FSTAB} ]; then
        write_log "Fstab file not found" false
        return 0
    fi

    # Keep a backup of /etc/fstab
    echo "Backing up ${FSTAB} to ${FSTAB_BAK}"
    ${CP_CMD} ${FSTAB} ${FSTAB_BAK}

    # Clear the immutable flag and make it writable
    chattr -i ${FSTAB}
    chmod +rw ${FSTAB}

    # Get all the disk IDs
    disks=$(blkid -o device)
    mounted_disks=$(findmnt -o source --fstab)
    ceph_type=0

    # Remove comment lines from $FSTAB
    fstab_tmp="$FSTAB.nxtmp"
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$FSTAB" > "$fstab_tmp"
    ${MV_CMD} $fstab_tmp $FSTAB

    # Check if ceph file system is present
    for mounted_disk in ${mounted_disks}; do
        type=$(blkid ${mounted_disk} | sed -n 's/.*\sTYPE=\"\([^\"]*\)\".*/\1/p')
        label=$(blkid ${mounted_disk} | sed -n 's/.*\sLABEL=\"\([^\"]*\)\".*/\1/p')
        if [ ${type} = "ceph" ] || [ ${label} = "ceph" ]; then
            ceph_type=1
        fi
    done

    echo "Fixing the entries for disks in ${FSTAB}."

    for disk in ${disks}; do
        # Replace all fstab entries with disk names
        # mountpoint stores the mountpoints of the disk (can be more than one ex: /boot)
        mountpoint=$(findmnt ${disk} -o target)
        if [ $? -ne 0 ]; then
            echo "Skipping Fixing for the entry"
        else
            # entry store first value for entry in fstab (ex: /dev/disk/sda1)
            entry=$(grep -E "(^|\s)${mountpoint}($|\s)" ${FSTAB} | sed -e 's/\s.*$//')
            if [ ${entry} != ${disk} ]; then
                echo "Fixing ${FSTAB} for Entry: ${entry} with Disk Name: ${disk}"
                sed "s*${entry}*${disk}*g" -i ${FSTAB}
            fi
        fi

        # Replace all the disk name entries with UUIDs
        uuid=$(blkid ${disk} | sed -n 's/.*\sUUID=\"\([^\"]*\)\".*/\1/p')
        if [ -n "${uuid}" ]; then
            echo "Fixing ${FSTAB} for Disk: ${disk} with UUID: ${uuid}"
            # To obtain the line number corresponding to an exact disk name match,
            # this information will be utilized in the subsequent use of 'sed' to
            # prevent alterations to other entries that match the same pattern.
            # Furthermore, if there are multiple entries for the same disk, all of
            # these entries will be replaced.
            grep -wn "${disk}" ${FSTAB} | cut -f1 -d: | while read -r line
            do
                # Use * as the delimiter
                sed "${line}s*${disk}*UUID=${uuid}*g" -i ${FSTAB}
            done
        fi
    done

    # Logging the fstab changes to the user
    echo "Changes to ${FSTAB}"
    out="$(diff -u ${FSTAB_BAK} ${FSTAB})"
    echo "${out}"

    if [ ${ceph_type} = 1 ]; then
        echo "Skiping dry-run because dry-run option not available."
    else
        # Perform a dry-run for mount
        echo "Performing a dry-run of mount with ${FSTAB}."
        mount -fav

        if [ $? -ne 0 ]; then
            # If the dry-run fails, restore the fstab
            echo "Dry-run of mount failed. Restoring ${FSTAB} from ${FSTAB_BAK}." false "ERROR"
            ${CP_CMD} ${FSTAB_BAK} ${FSTAB}
            return 1
        fi
    fi

    echo "#" > "${fstab_tmp}"
    echo "# This backup file is created by Nutanix Move." >> "${fstab_tmp}"
    echo "# Original file is $FSTAB_BAK" >> "${fstab_tmp}"
    echo "#" >> "${fstab_tmp}"
    cat "$FSTAB" >> "$fstab_tmp"
    ${MV_CMD} $fstab_tmp $FSTAB

    return 0
}

main(){
	fix_fstab
	return $?
}

main
exit $?
