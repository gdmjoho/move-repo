#!/bin/bash
# Copyright (c) 2017 Nutanix Inc. All rights reserved.

set -x
sourcefilepath="$0"
echo "Running $sourcefilepath"
# If true, will print error for automatic preparation display
print_error=false
# Ref: ENG-142424, ignores_error flag only for OEL. Passed only in verification
# after initramfs is created.
ignore_error=false
custom_drivers=""
while [ "$#" -gt 0 ]; do
    case $1 in
    -p | --print-error)
        print_error=true
        ;;
    -i | --ignore-error)
        ignore_error=true
        ;;
    -c | --custom-drivers)
        custom_drivers=$2
        shift
        ;;
    esac
    shift
done

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
# For RHEL, virtio and virtio_pci are not found in image.
redhat_drivers_8x_9x="virtio_scsi virtio_net virtio_blk"
debian_drivers="virtio_scsi"
suse_drivers="virtio_scsi virtio_net virtio_blk"
# Paths taken from https://github.com/dracutdevs/dracut/blob/master/lsinitrd.sh
skipcpio_searchpaths="/usr/lib/dracut/skipcpio/skipcpio /usr/lib/dracut/skipcpio"
skipcpio_path=""
error_start="[Error]"
error_end="[/Error]"
# Find all the installed kernel versions. We can get the list from
# /lib/modules
list_available_kernels() {
    # Return a version sorted list
    ls /lib/modules | sort -V
}

print_driver_installation_failed_error_message() {
    print_error_message "Drivers Installation Failed. Driver(s) $1could not be installed for kernel $2"
}
print_error_message() {
    if [ $print_error = true ]; then
        echo "$error_start $1 $error_end"
        echo "$error_start $1 $error_end" 1>&3
    fi
}
# Find all the installed kernel versions. For RHEL/CentOS, we can
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

# Function to check if driver is available using lsinitrd utility
check_driver_lsinitrd() {
    initrd_path="$1"
    driver="$2"

    if [[ -f ${initrd_path} ]]; then
        lsinitrd ${initrd_path} | grep -v "^Arguments" | grep "${driver}\."
    fi

    rc=$?
    return $rc
}

# Function to check if driver is available using skipcpio utility
check_driver_skipcpio() {
    initrd_path="$1"
    driver="$2"
    skipcpio_path="$3"

    if [[ -f ${initrd_path} ]]; then
        if [ -z ${skipcpio_path} ]; then
            # HACK Ref: ENG-142424, absence of skipcpio disables us in verifying.
            # Currently this false negative detected only in Oracle Linux.
            if [ -f /etc/oracle-release ] && [ ${ignore_error} = true ]; then
                echo "Proceeding without verification of virtio drivers."
            else
                return 1
            fi
        else
            ${skipcpio_path} ${initrd_path} | zcat | cpio -ivt | grep -i "${driver}\."
        fi
    fi

    rc=$?
    return $rc
}

# Function to check if driver is available using lsinitramfs utility
check_driver_lsinitramfs() {
    initramfs_path="$1"
    driver="$2"

    if [[ -f ${initramfs_path} ]]; then
        lsinitramfs ${initramfs_path} | grep "${driver}\."
    fi

    rc=$?
    return $rc
}

check_debian_driver() {
    drivers="$1"
    exit_on_error="$2"
    missing_drivers=""
    for driver in $drivers; do
        initrd_path="/boot/initrd.img-${kver}"
        check_driver_lsinitramfs ${initrd_path} ${driver}
        rc=$?
        if [[ ${exit_on_error} == true ]]; then
            if [[ $rc != 0 ]]; then
                missing_drivers+="$driver "
            fi
        fi
    done
    if [ ! -z "$missing_drivers" ]; then
        print_driver_installation_failed_error_message "${missing_drivers}" "${kver}"
        exit 1
    fi
}

check_drivers_for_suse() {
    exit_on_error=false
    running_kver=$(uname -r)
    for kver in $(list_available_kernels); do
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio check fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            exit_on_error=true
        fi
        drivers=${suse_drivers}
        # Check if virtio and virtio-pci drivers are present.
        virtio_path="/lib/modules/${kver}/kernel/drivers/virtio"
        if [ $(ls $virtio_path | grep virtio.ko | wc -w) -gt 0 ]; then
            drivers+=" virtio"
        fi
        if [ $(ls $virtio_path | grep virtio_pci.ko | wc -w) -gt 0 ]; then
            drivers+=" virtio_pci"
        fi
        if [ ! -z "$custom_drivers" ]; then
            drivers=$custom_drivers
        fi
        missing_drivers=""
        for driver in $drivers; do
            initrd_path="/boot/initrd-${kver}"
            check_driver_lsinitrd ${initrd_path} ${driver}
            rc=$?
            if [[ ${exit_on_error} == true ]]; then
                if [[ $rc != 0 ]]; then
                    missing_drivers+="$driver "
                fi
            fi
        done
        if [ ! -z "$missing_drivers" ]; then
            print_driver_installation_failed_error_message "${missing_drivers}" "${kver}"
            exit 1
        fi
    done
}

if [ -f /etc/redhat-release ]; then
    for path in $skipcpio_searchpaths; do
        if [ -f ${path} ]; then
            skipcpio_path=${path}
            echo "Found skipcpio in path: " $skipcpio_path
        fi
    done

    exit_on_error=false
    running_kver=$(uname -r)

    for kver in $(list_available_kernels_from_rpm_info); do
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio check fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            exit_on_error=true
        fi
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
        missing_drivers=""
        for driver in ${drivers}; do
            initrd_path="/boot/initramfs-${kver}.img"
            check_driver_lsinitrd ${initrd_path} ${driver}
            rc=$?
            if [[ $rc != 0 ]]; then
                check_driver_skipcpio ${initrd_path} ${driver} ${skipcpio_path}
                rc=$?
                if [[ ${exit_on_error} == true ]]; then
                    if [[ $rc != 0 ]]; then
                        missing_drivers+="$driver "
                    fi
                fi
            fi
        done
        if [ ! -z "$missing_drivers" ]; then
            print_driver_installation_failed_error_message "${missing_drivers}" "${kver}"
            exit 1
        fi
    done
elif [ -f /etc/debian_version ]; then
    exit_on_error=false
    running_kver=$(uname -r)
    for kver in $(list_available_kernels); do
        # Operation must fail for current kernel version and all kernel
        # versions higher than current version (if virtio check fails).
        # NOTE: The kernel version list must be sorted for this to work
        if [[ ${kver} == ${running_kver} ]]; then
            exit_on_error=true
        fi
        drivers=$debian_drivers
        if [ ! -z "$custom_drivers" ]; then
            drivers=$custom_drivers
        else
            kernel_version_major=$(echo $kver | cut -d '.' -f1)
            if [ "${kernel_version_major}" -ge 6 ]; then
                grep -i 'CONFIG_SCSI_VIRTIO=m' /boot/config-$kver
                if [ $? = 0 ]; then
                    check_debian_driver $drivers $exit_on_error
                    continue
                fi
                grep -i 'CONFIG_SCSI_VIRTIO=y' /boot/config-$kver
                if [[ $? != 0 ]]; then
                    print_driver_installation_failed_error_message "virtio_scsi" "${kver}"
                    if [[ ${exit_on_error} == true ]]; then
                        exit 1
                    fi
                fi
                continue
            fi
        fi
        check_debian_driver $drivers $exit_on_error
    done
elif [ -f /etc/SuSE-release ]; then
    check_drivers_for_suse
elif [ -f /etc/os-release ]; then
    # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
    isSuSe=$(grep -ie "suse" /etc/os-release)
    if [ ${#isSuSe} -gt 0 ]; then
        check_drivers_for_suse
    fi
else
    print_error_message "Unsupported linux variant for virtio installation"
    exit 1
fi

exit 0
