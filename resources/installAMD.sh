#!/bin/bash
# Copyright (c) 2017 Nutanix Inc. All rights reserved.

set -x
sourcefilepath="$0"
echo "Running $sourcefilepath"

if [ $(id -u) != 0 ]; then # check if you are root
    chmod 755 $sourcefilepath
    echo Starting the script as root
    ./sudoTerm -s "$sourcefilepath"
    exit $?
fi

date
redhat_drivers="virtio_scsi virtio_net virtio_blk virtio_pci virtio"
uek_drivers="virtio_scsi virtio_net virtio_blk virtio_pci virtio"
uek_drivers_5x="virtio_scsi virtio_net virtio_blk virtio_pci"
redhat_drivers_8x_9x="virtio_scsi virtio_net virtio_blk"
debian_drivers="virtio_scsi"
suse_drivers="virtio_scsi virtio_net virtio_blk virtio_pci virtio"
custom_drivers="$1"
nutanix_initramfs_backup="/opt/Nutanix/initramfs_backup"
error_start="[Error]"
error_end="[/Error]"

# Find all the installed kernel versions. We can get the list from
# /lib/modules
list_available_kernels() {
    # Return a version sorted list
    ls /lib/modules | sort -V
}

print_error_message() {
    echo "$error_start $1 $error_end"
    echo "$error_start $1 $error_end" 1>&3
}

# Find all the installed kernel versions. For RHEL/CentOS/OEL, we can
# query using RPM to get the list of installed kernels.
list_available_kernels_from_rpm_info() {
    kvers=""
    for kernel in $(rpm -qa kernel); do
        kver=${kernel#"kernel-"}
        kvers="${kvers} ${kver}"
    done

    # Get the UEK Kernels for OEL
    for kernel in $(rpm -qa kernel-uek); do
        kver=${kernel#"kernel-uek-"}
        kvers="${kvers} ${kver}"
    done

    # Sort according to version.
    kvers=$(echo ${kvers} | xargs -n1 | sort -V | xargs)
    echo $kvers
}

install_for_suse() {
    mkdir -p $nutanix_initramfs_backup
    initrd_module_file="/etc/sysconfig/kernel"
    drivers=${suse_drivers}
    running_kver=$(uname -r)
    if [ ! -z "$custom_drivers" ]; then
        drivers=$custom_drivers
    fi
    if [ ! -e "$initrd_module_file" ]; then
        echo "INITRD_MODULES=\" $drivers \"" >$initrd_module_file
    else
        sed -i.bak -e "s/^INITRD_MODULES=\"/INITRD_MODULES=\"$drivers /g" $initrd_module_file
        rc=$?
        if [[ $rc != 0 ]]; then exit $rc; fi
    fi
    exit_on_error=false
    for kver in $(list_available_kernels); do
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio installation fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            exit_on_error=true
        fi
        # Take a backup of current initrd
        if [ -f /boot/initrd-${kver} ]; then
            cp -f /boot/initrd-${kver} $nutanix_initramfs_backup/initrd-${kver}.nxbak
            copy_res=$?
            if [[ $copy_res != 0 ]]; then
                exit $copy_res
            fi
        fi
        # check if mkinitrd command is present on the system
        which mkinitrd
        rc=$?
        if [[ $rc != 0 ]]; then
              # mkinitrd not found, use dracut to create initramfs
              # add virtio drivers for the kernel module to load
              touch /etc/dracut.conf.d/virtio.conf
              echo "add_drivers+=$suse_drivers" > /etc/dracut.conf.d/virtio.conf
              dracut -f
        else
              # mkinitrd is available, use it to create initramfs
              mkinitrd -k /boot/vmlinuz-${kver} -i /boot/initrd-${kver}
        fi
        rc=$?
        if [[ $rc != 0 ]]; then
            # Restore from the backup of failed initrd and exit
            mv -f $nutanix_initramfs_backup/initrd-${kver}.nxbak /boot/initrd-${kver}
            if [[ ${exit_on_error} == true ]]; then
                exit $rc
            fi
        fi
    done
}

if [ -f /etc/redhat-release ]; then
    running_kernel_drivers=""
    exit_on_error=false
    running_kver=$(uname -r)
    mkdir -p $nutanix_initramfs_backup
    # Update the initramfs image for all installed kernels
    initrd_module_file="/etc/dracut.conf.d/virtio.conf"
    rm -f $initrd_module_file
    for kver in $(list_available_kernels_from_rpm_info); do

        kernel_version_major=$(echo $kver | cut -d '.' -f1)
        is_uek=false
        if [[ "$kver" == *"uek"* ]]; then
            is_uek=true
        fi
        drivers=${redhat_drivers}
        # Check for RHEL/Centos 8, 9 and add appropriate drivers.
        if [ "${kernel_version_major}" -ge 4 ]; then drivers=${redhat_drivers_8x_9x}; fi
        # Check if uek kernel and add appropriate drivers
        if [[ ${is_uek} == true ]]; then
            drivers=${uek_drivers}
            if [ "${kernel_version_major}" -ge 5 ]; then drivers=${uek_drivers_5x}; fi
        fi
        if [ ! -z "$custom_drivers" ]; then
            drivers=$custom_drivers
        fi
        # Check if bochs-drm driver is required for RHEL and add if necessary.
        bochs_path="/lib/modules/${kver}/kernel/drivers/gpu/drm/bochs"
        if [ -d $bochs_path ]; then
            drivers="${drivers} bochs-drm"
        fi
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio installation fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            running_kernel_drivers=$drivers
            exit_on_error=true
        fi
        # Take a backup of current initramfs
        if [ -f /boot/initramfs-${kver}.img ]; then
            cp -f /boot/initramfs-${kver}.img $nutanix_initramfs_backup/initramfs-${kver}.img.nxbak
            copy_res=$?
            if [[ $copy_res != 0 ]]; then
                exit $copy_res
            fi
        fi

        dracut --add-drivers "$drivers" -f -v /boot/initramfs-${kver}.img ${kver}
        rc=$?
        if [[ $rc != 0 ]]; then
            # Restore from the backup of failed initramfs and exit
            mv -f $nutanix_initramfs_backup/initramfs-${kver}.img.nxbak /boot/initramfs-${kver}.img
            if [[ ${exit_on_error} == true ]]; then
                exit $rc
            fi
        fi
    done
    echo "add_drivers+=\" $running_kernel_drivers \"" >$initrd_module_file

elif [ -f /etc/debian_version ]; then
    mkdir -p $nutanix_initramfs_backup
    initrd_module_file="/etc/initramfs-tools/modules"
    echo "# AHV drivers added by DataMover" >>$initrd_module_file
    if [ ! -z "$custom_drivers" ]; then
        debian_drivers=$custom_drivers
    fi
    for driver in $debian_drivers; do
        echo $driver >>$initrd_module_file
    done
    exit_on_error=false
    running_kver=$(uname -r)

    for kver in $(list_available_kernels); do
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio installation fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            exit_on_error=true
        fi
        # Take a backup of current initrd img
        if [ -f /boot/initrd.img-${kver} ]; then
            cp -f /boot/initrd.img-${kver} $nutanix_initramfs_backup/initrd.img-${kver}.nxbak
            copy_res=$?
            if [[ $copy_res != 0 ]]; then
                exit $copy_res
            fi
        fi
        update-initramfs -u -k ${kver}
        rc=$?
        if [[ $rc != 0 ]]; then
            # Restore from the backup of failed initrd img and exit
            mv -f $nutanix_initramfs_backup/initrd.img-${kver}.nxbak /boot/initrd.img-${kver}
            if [[ ${exit_on_error} == true ]]; then
                exit $rc
            fi
        fi
    done
elif [ -f /etc/SuSE-release ]; then
    install_for_suse
elif [ -f /etc/os-release ]; then
    # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
    isSuSe=$(grep -ie "suse" /etc/os-release)
    if [ ${#isSuSe} -gt 0 ]; then
        install_for_suse
    fi
else
    print_error_message "Unsupported linux variant for virtio installation"
    exit 1
fi

exit 0
