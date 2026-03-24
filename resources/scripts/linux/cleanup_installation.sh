#!/usr/bin/env bash

SCRIPT_VERSION="6.1.2"

SOURCE_PROVIDER=""
SKIP_REMOVE_SCHEDULE_SERVICE_FILE=false
SKIP_CONFS_RESTORE=false
CLEAN_SCRIPTS=true
freeBSD=false
sourcefilepath="$0"

if [ $(id -u) != 0 ]; then # check if you are root
    chmod 755 $sourcefilepath
    echo "Starting the script as root"
    if [ -f "./sudoTerm" ]; then
        ./sudoTerm -s "$sourcefilepath"
        exit $?
    elif [ -f "./sudoTermFreeBSD" ]; then
        ./sudoTermFreeBSD -s "$sourcefilepath"
        exit $?
    fi
fi

while [ "$#" -gt 0 ]; do
    case $1 in
    --source-provider)
        SOURCE_PROVIDER=$2
        shift
        ;;
    --skip-remove-schedule-service-file) SKIP_REMOVE_SCHEDULE_SERVICE_FILE=true ;;
    --skip-confs-restore) SKIP_CONFS_RESTORE=true ;;
    --clean-scripts)
        CLEAN_SCRIPTS=$2
        shift
        ;;
    esac
    shift
done

# This is printed as the last message on stdout
# for marking success (for automatic cleanup in Azure)
SUCCESS_MARKER="[ OK ]"

# Directories
#NXBASE_DIR="${HOME}/Nutanix"
NXBASE_DIR="/opt/Nutanix"
mkdir -p ${NXBASE_DIR}
cd ${NXBASE_DIR}
PREPARE_DIR="${NXBASE_DIR}/Move"
UNINSTALL_DIR="${NXBASE_DIR}/Uninstall"
DOWNLOAD_DIR="${PREPARE_DIR}/download"
# Until Move-4.4.0 this was the download dir for ahv_setup_uvm.sh
DOWNLOAD_DIR_2="${NXBASE_DIR}/download"
ARTIFACT_DIR="${PREPARE_DIR}/artifact"
SCRIPTS_DIR="${DOWNLOAD_DIR}/scripts"
## Log
LOG_DIR="${NXBASE_DIR}/log"
LOG_FILE="${LOG_DIR}/uvm_cleanup_script.log"
mkdir -p ${LOG_DIR}
exec 3>&1 1>>${LOG_FILE} 2>&1
## Salt
GIT_REPO_TAG="v2018.3.3"
## Distro
OS_RELEASE_FILE="/etc/os-release"
OS_RELEASE_FILE_SECONDARY="/etc/issue"
OS_RELEASE_FILE_REDHAT="/etc/redhat-release"
DISTRO_NAME=""
DISTRO_NAME_CENTOS="CentOS"
DISTRO_NAME_REDHAT="Red Hat"
DISTRO_NAME_UBUNTU="Ubuntu"
DISTRO_NAME_SUSE="SUSE"
DISTRO_NAME_AMAZON_LINUX="AMAZON LINUX"
DISTRO_NAME_ORACLE_LINUX="ORACLE LINUX"
DISTRO_NAME_DEBIAN="Debian"
DISTRO_NAME_FREEBSD="FreeBSD"
DISTRO_NAME_ROCKY_LINUX="Rocky Linux"
### Scripts
## Scheduled Service
OLD_SERVICES="retainIP configureTempDisk reconfig-lvm uninstallVMwareTools scheduleTargetCleanup"
OLD_FILES="/etc/sourcevm-idfile-tempdisk /etc/sourceprovider_file /etc/sourcevm-idfile-uninstallVMwareTools"
SCHEDULE_SERVICE_FILENAME="nutanix-move"
SCHEDULE_SERVICE_FILE="/etc/init.d/${SCHEDULE_SERVICE_FILENAME}"
SOURCE_ID_FILE="/etc/sourcevm-idfile"
## Cloud-Init
CLOUD_INIT_CONFIG_FILE="/etc/cloud/cloud.cfg"
CLOUD_INIT_CONFIG_BAK_FILE="/etc/cloud/cloud.cfg.nxbak"
CLOUD_INIT_CONFIGS_DIR="/etc/cloud/cloud.cfg.d"
## Azure
TEMPDISK_SIZE_FILE="/etc/tempdisk_sizefile"
DHCP_FILE="/etc/sourcevm-dhcpfile"
DEBIAN_CLOUD_IMG_UDEV_FILE="/etc/udev/rules.d/75-cloud-ifupdown.rules"
DEBIAN_CLOUD_IMG_UDEV_BACKUP_FILE="/etc/udev/rules.d/75-cloud-ifupdown.rules.nxbak"
DEBIAN_NETPLAN_CONFIG_FILE="/etc/netplan/50-cloud-init.yaml"
DEBIAN_NETPLAN_CONFIG_BACKUP_FILE="/etc/netplan/50-cloud-init.yaml.nxbak"
DISABLE_CLOUD_INIT_FILE="/etc/cloud/cloud-init.disabled"
UPSTART_CLOUD_INIT_FILE="/etc/init/cloud-init.conf"
UPSTART_CLOUD_INIT_BACKUP_FILE="/etc/init/cloud-init.conf.bak"
FSTAB="/etc/fstab"
FSTAB_BAK="/etc/fstab.bak"
FSTAB_ESXI_BAK="/etc/fstab.nxbak"
#TARGET Type
AOS="AOS"
ESXI="ESXI"
HYPERV="HYPERV"
AWS="AWS"
AZURE="AZURE"

# Functions
## Function to log messages to log file and console
write_log() {
    # args
    local lineno=$1
    local msg=$2
    # Second arg if present is a boolean for mentioning avoidConsole
    local avoidConsole=${3:-false}
    local severity=${4:-INFO}
    #echo $msg, $lineno, $avoidConsole, $severity

    local final_msg="$(date +"%d-%m-%YT%H:%M:%S") ${severity} ${lineno} ${msg}"
    if [ "$avoidConsole" = true ]; then
        echo ${final_msg}

    else
        # Splitting since console msg and log msg needs to be different(no timestamp)
        #echo ${final_msg} | tee /dev/fd/3
        echo ${final_msg}
        echo ${msg} 1>&3
    fi

    return 0
}

check_freebsd() {
    uname | grep -i freebsd
    errorVal=$?
    if [ $errorVal = 0 ]; then
        write_log "FreeBSD os detected."
        freeBSD=true
    fi
    return 0
}

## Function to remove all the directories except "log" created as part of the preparation script.
clean_directories() {
    write_log $LINENO "Removing User VM preparation directories."
    if [ "$CLEAN_SCRIPTS" = true ]; then
        rm -rf ${PREPARE_DIR}
    fi
    rm -rf ${UNINSTALL_DIR}
    rm -f ${SOURCE_ID_FILE}
    rm -rf ${DOWNLOAD_DIR_2}

    return $?
}

## Function to clean the packages installed in CentOS/RHEL.
clean_pkgs_centos() {
    write_log $LINENO "Cleaning installed packages."
    # We didn't installed the jq via yum so no need to clean this up via yum
    #yum -y remove jq

    return 0
}

## Function to clean the packages installed in Ubuntu.
clean_pkgs_ubuntu() {
    write_log $LINENO "Cleaning installed packages."
    # dpkg -s jq
    # is_not_installed=$?
    # if [ $is_not_installed -eq 0 ]; then
    #     apt-get -y remove jq
    # else
    #     return 0
    # fi
    return 0
}

## Function to clean the packages installed in a supported Linux. Need to be
## safe here deleting only safe ones
clean_pkgs() {
    local last_status=0
    if [ "$DISTRO_NAME" = "$DISTRO_NAME_CENTOS" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_REDHAT" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_SUSE" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_AMAZON_LINUX" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_ORACLE_LINUX" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_ROCKY_LINUX" ]; then
        clean_pkgs_centos
        local last_status=$?
    elif [ "$DISTRO_NAME" = "$DISTRO_NAME_UBUNTU" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_DEBIAN" ]; then
        clean_pkgs_ubuntu
        local last_status=$?
    fi

    return ${last_status}
}

clean_old_files() {
    write_log $LINENO "Cleaning old files and services created from previous Move versions if any"
    service_path=""
    if [ "$freeBSD" = true ]; then
        service_path="/etc/rc.d"
    else
        service_path="/etc/init.d"
    fi
    for service in $OLD_SERVICES; do
        if [ -f $service_path/$service ]; then
            if [ "$freeBSD" == true ]; then
                sed -i -e "/^${service}_enable=\"YES\"$/d" /etc/rc.conf
            elif [ -f /etc/redhat-release ]; then
                chkconfig --del ${service}
            elif [ -f /etc/debian_version ]; then
                update-rc.d -f ${service} remove
            elif [ -f /etc/SuSE-release ]; then
                chkconfig --del ${service}
            elif [ -f /etc/os-release ]; then
                # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
                isSuSe=$(grep -ie "suse" /etc/os-release)
                if [ ${#isSuSe} -gt 0 ]; then
                    if [ -d "/etc/systemd" ]; then
                        systemctl disable ${service}
                    else
                        chkconfig --del ${service}
                    fi
                fi
            fi
            rm -f $service_path/$service
        fi
    done
    for file in $OLD_FILES; do
        rm -f $file
    done
    return 0
}
# Function to remove the service file.
clean_schedule_servicefile() {
    write_log $LINENO "Removing ${SCHEDULE_SERVICE_FILENAME} service file."

    rm -f ${DHCP_FILE}

    # Stop the service form running in future
    if [ "$freeBSD" = true ]; then
        sed -i -e '/^nutanix_move_enable="YES"$/d' /etc/rc.conf
        rm -f /etc/rc.d/nutanix-move
        return $?
    elif [ -f /etc/redhat-release ]; then
        # remove service file from systemd in case chkconfig not present
        output=$(chkconfig --list)
        if [ $? = 0 ] && [[ "$output" == *"${SCHEDULE_SERVICE_FILENAME}"* ]]; then
            chkconfig --del ${SCHEDULE_SERVICE_FILENAME}
        else
            systemctl disable ${SCHEDULE_SERVICE_FILENAME}.service
        fi
    elif [ -f /etc/debian_version ]; then
        output=$(initctl list)
        if [ $? = 0 ] && [[ "$output" == *"${SCHEDULE_SERVICE_FILENAME}"* ]]; then
            update-rc.d -f ${SCHEDULE_SERVICE_FILENAME} remove
        else
            systemctl disable ${SCHEDULE_SERVICE_FILENAME}.service
        fi
    elif [ -f /etc/SuSE-release ]; then
        output=$(chkconfig --list)
        if [ $? = 0 ] && [[ "$output" == *"${SCHEDULE_SERVICE_FILENAME}"* ]]; then
            chkconfig --del ${SCHEDULE_SERVICE_FILENAME}
        else
            systemctl disable ${SCHEDULE_SERVICE_FILENAME}.service
        fi
    elif [ -f /etc/os-release ]; then
        # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
        isSuSe=$(grep -ie "suse" /etc/os-release)
        if [ ${#isSuSe} -gt 0 ]; then
            output=$(chkconfig --list)
            if [ $? = 0 ] && [[ "$output" == *"${SCHEDULE_SERVICE_FILENAME}"* ]]; then
                chkconfig --del ${SCHEDULE_SERVICE_FILENAME}
            else
                systemctl disable ${SCHEDULE_SERVICE_FILENAME}.service
            fi
        fi
    fi
    rm -f ${SCHEDULE_SERVICE_FILE}
    if [ -f /etc/systemd/system/${SCHEDULE_SERVICE_FILENAME}.service ]; then
        systemctl disable ${SCHEDULE_SERVICE_FILENAME}.service
        rm -f /etc/systemd/system/${SCHEDULE_SERVICE_FILENAME}.service
    fi
    return $?

}

## Function to clean CentOS/RHEL distro
clean_linux() {
    write_log $LINENO "Detected that the UVM is a supported Linux distro, proceeding." true
    local last_status=0

    clean_pkgs
    local last_status=$?
    write_log $LINENO "clean_pkgs returned with code: ($last_status)" true

    clean_directories
    local last_status=$?
    write_log $LINENO "clean_directories returned with code: ($last_status)" true

    clean_old_files
    local last_status=$?
    write_log $LINENO "clean_old_files returned with code: ($last_status)" true

    if [ "$SKIP_REMOVE_SCHEDULE_SERVICE_FILE" = false ]; then
        clean_schedule_servicefile
        local last_status=$?
        write_log $LINENO "clean_schedule_servicefile returned with code: ($last_status)" true
    else
        write_log $LINENO "Skipped clean_schedule_servicefile." true
    fi

    return ${last_status}
}

## Function to clean the User VM.
clean_uvm() {
    write_log $LINENO "Starting User VM clean-up."
    if [ "$DISTRO_NAME" = "$DISTRO_NAME_CENTOS" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_REDHAT" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_UBUNTU" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_SUSE" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_AMAZON_LINUX" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_ORACLE_LINUX" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_DEBIAN" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_FREEBSD" ] || [ "$DISTRO_NAME" = "$DISTRO_NAME_ROCKY_LINUX" ]; then
        clean_linux
        local last_status=$?
        return ${last_status}
    fi

    write_log $LINENO "Couldn't detect any supported distro in User VM, exiting the clean-up."
    return 1
}

## Function to revert backed up cloud-init config in the User VM.
_revert_cloud_init() {
    write_log $LINENO "Reverting cloud init config in the User VM during the clean-up." true
    if [ $(type -t cp) == "alias" ]; then
        unalias cp
    fi
    if [ -f ${CLOUD_INIT_CONFIG_BAK_FILE} ]; then
        cp -f ${CLOUD_INIT_CONFIG_BAK_FILE} ${CLOUD_INIT_CONFIG_FILE}
    fi
    # Reverting changes in the conf directory
    for filename in ${CLOUD_INIT_CONFIGS_DIR}/*.nxbak; do
        if [ -e $filename ]; then
            org_filname="${filename%.*}"
            cp -f ${filename} ${org_filname}
            if [ "$?" -eq 0 ]; then
                rm -f ${filename}
            fi
        fi
    done

    return $?
}

# Function to revert the changes in grub config
_revert_grub() {
    write_log $LINENO "Reverting grub config in the User VM during the clean-up." true
    if [ -f /boot/grub/grub.cfg.nxbak ]; then
        cp -f /boot/grub/grub.cfg.nxbak /boot/grub/grub.cfg
    fi
    if [ -f /etc/default/grub.nxbak ]; then
        cp -f /etc/default/grub.nxbak /etc/default/grub
    fi
    rm -f /boot/grub/grub.cfg.nxbak
    rm -f /etc/default/grub.nxbak

    return $?
}

## Function to revert backed up configs in the User VM.
revert_config() {
    if [ "$SKIP_CONFS_RESTORE" = false ]; then
        write_log $LINENO "Reverting configs in the User VM during the clean-up."
        _revert_grub
        local last_status=$?
        write_log $LINENO "_revert_grub returned with code: ($last_status)" true
        _revert_cloud_init
        local last_status=$?
        write_log $LINENO "_revert_cloud_init returned with code: ($last_status)" true
        return ${last_status}
    else
        write_log $LINENO "Skipped revert_config as flag was not set." true
    fi

    return 0
}

## Function to revert Azure related config changes.
revert_azure_config() {
    if [ "$SOURCE_PROVIDER" = "$AZURE" ]; then
        write_log $LINENO "Reverting azure configs in the User VM during the clean-up."
        # Remove temporary disk size file
        rm -f ${TEMPDISK_SIZE_FILE}
        # Restore the udev rules for the cloud image
        if [ -f ${DEBIAN_CLOUD_IMG_UDEV_BACKUP_FILE} ]; then
            mv -f ${DEBIAN_CLOUD_IMG_UDEV_BACKUP_FILE} ${DEBIAN_CLOUD_IMG_UDEV_FILE}
        fi
        # Restore the netplan configuration
        if [ -f ${DEBIAN_NETPLAN_CONFIG_BACKUP_FILE} ]; then
            mv -f ${DEBIAN_NETPLAN_CONFIG_BACKUP_FILE} ${DEBIAN_NETPLAN_CONFIG_FILE}
        fi
        # Re-enable cloud-init
        if [ -f ${DISABLE_CLOUD_INIT_FILE} ]; then
            rm -f ${DISABLE_CLOUD_INIT_FILE}
        fi
        # Restore the cloud-init configuration
        if [ -f ${UPSTART_CLOUD_INIT_BACKUP_FILE} ]; then
            mv -f ${UPSTART_CLOUD_INIT_BACKUP_FILE} ${UPSTART_CLOUD_INIT_FILE}
        fi
        # Restore the fstab backup file
        if [ -f ${FSTAB_BAK} ]; then
            mv -f ${FSTAB_BAK} ${FSTAB}
        fi
    fi

    return 0
}

## Function to setup required directories in the User VM.
do_prerequisite_dirs() {
    write_log $LINENO "Creating required directories to clean-up the User VM."
    mkdir -p ${LOG_DIR}
    mkdir -p ${UNINSTALL_DIR}
    mkdir -p ${SCRIPTS_DIR}

    return 0
}

## Function to determine the Distro to complete the UVM clean-up and install
## prerequisite pkgs for the operation.
determine_distro_with_pkgs() {
    DISTRO_NAME=""
    uname | grep -i freebsd
    errorVal=$?
    if [ $errorVal = 0 ]; then
        DISTRO_NAME="$DISTRO_NAME_FREEBSD"
        do_prerequisite_dirs
        freeBSD=true
        return 0
    fi
    if [ -f ${OS_RELEASE_FILE} ]; then
        OS_RELEASE_FILE_SECONDARY="$OS_RELEASE_FILE_SECONDARY"
    else
        OS_RELEASE_FILE="$OS_RELEASE_FILE_SECONDARY"
    fi
    if [ -f ${OS_RELEASE_FILE} ]; then
        # CentOS
        grep "CentOS" ${OS_RELEASE_FILE}
        local last_status=$?
        if [ ${last_status} -eq 0 ]; then
            DISTRO_NAME="$DISTRO_NAME_CENTOS"
            do_prerequisite_dirs
            return 0
        else
            # Ubuntu
            grep -i "ubuntu" ${OS_RELEASE_FILE}
            local last_status=$?
            if [ ${last_status} -eq 0 ]; then
                DISTRO_NAME="$DISTRO_NAME_UBUNTU"
                do_prerequisite_dirs
                return 0
            else
                # RHEL
                grep "Red Hat" ${OS_RELEASE_FILE}
                local last_status=$?
                if [ ${last_status} -eq 0 ] || [ -f ${OS_RELEASE_FILE_REDHAT} ]; then
                    DISTRO_NAME="$DISTRO_NAME_REDHAT"
                    do_prerequisite_dirs
                    return 0
                else
                    #SUSE Linux
                    grep -ie "SLES\|suse" ${OS_RELEASE_FILE}
                    local last_status=$?
                    if [ ${last_status} -eq 0 ]; then
                        DISTRO_NAME="$DISTRO_NAME_SUSE"
                        do_prerequisite_dirs
                        return 0
                    else
                        #Amazon Linux
                        grep "Amazon Linux" ${OS_RELEASE_FILE}
                        local last_status=$?
                        if [ ${last_status} -eq 0 ]; then
                            DISTRO_NAME="$DISTRO_NAME_AMAZON_LINUX"
                            do_prerequisite_dirs
                            return 0
                        else
                            #Oracle Linux
                            grep "Oracle" ${OS_RELEASE_FILE}
                            local last_status=$?
                            if [ ${last_status} -eq 0 ]; then
                                DISTRO_NAME="$DISTRO_NAME_ORACLE_LINUX"
                                do_prerequisite_dirs
                                return 0
                            else
                                #Debian
                                grep "Debian" ${OS_RELEASE_FILE}
                                local last_status=$?
                                if [ ${last_status} -eq 0 ]; then
                                    DISTRO_NAME="$DISTRO_NAME_DEBIAN"
                                    do_prerequisite_dirs
                                    return 0
                                else
                                    # Rocky Linux
                                    grep "Rocky Linux" ${OS_RELEASE_FILE}
                                    local last_status=$?
                                    if [ ${last_status} -eq 0 ]; then
                                        DISTRO_NAME="$DISTRO_NAME_ROCKY_LINUX"
                                        do_prerequisite_dirs
                                        return 0
                                    fi
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
    return 1
}

## Function to print the success marker for automatic cleanup
print_success_marker() {
    # print to stdout
    echo "${SUCCESS_MARKER}" 1>&3
}

revert_fstab() {
    if [ "$SOURCE_PROVIDER" = "$ESXI" ]; then
        # Restore the fstab backup file
        if [ -f ${FSTAB_ESXI_BAK} ]; then
            mv -f ${FSTAB_ESXI_BAK} ${FSTAB}
        fi
    fi
    return 0
}

# Script Main Block
main() {
    write_log $LINENO "--------------------------------------------------------" true
    write_log $LINENO "Cleaning the User VM using script: $SCRIPT_VERSION"

    # check if OS is freebsd
    check_freebsd

    # Need to be first, as the below steps have dependency based on the distro
    determine_distro_with_pkgs
    if [ "$?" -ne 0 ]; then
        write_log $LINENO "Couldn't detect a supported distro in the User VM." "false" "EROR"
        exit 1
    fi
    write_log $LINENO "Distro: ${DISTRO_NAME}"

    clean_uvm
    if [ "$?" -ne 0 ]; then
        write_log $LINENO "Couldn't finish User VM clean-up." "false" "EROR"
        exit 1
    fi

    revert_config
    if [ "$?" -ne 0 ]; then
        write_log $LINENO "Couldn't revert config files in User VM." "false" "EROR"
        exit 1
    fi

    revert_azure_config
    if [ "$?" -ne 0 ]; then
        write_log $LINENO "Couldn't revert azure config files in User VM." "false" "EROR"
        exit 1
    fi

    revert_fstab
    if [ "$?" -ne 0 ]; then
        write_log $LINENO "Couldn't revert fstab in User VM." "false" "EROR"
        exit 1
    fi

    write_log $LINENO "Clean-up of User VM completed successfully."
    write_log $LINENO "========================================================" true
    print_success_marker
}

# Printing the commands which are executed while running the script.
set -x

# Script Execution
main
