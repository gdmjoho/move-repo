#! /bin/sh
# Copyright (c) 2017 Nutanix Inc. All rights reserved.
# Sample manual execution: /tmp/nutanix_move/vmware300/nutanix_move.sh --retain-ip /tmp/nutanix_move/vmware300/retainIP.sh --reconfig-lvm --uninstall-vmware-tools /tmp/nutanix_move/vmware300/uninstallVMwareTools.sh --prep-conf-file-path /tmp/nutanix_move/vmware300/pcf_ee015026-8842-47f5-99a9-0d857061d770_f8437e97-4013-5783-b311-e56dcd8ceac1.json --configedit-path /tmp/nutanix_move/vmware300/configedit --cleanup /tmp/nutanix_move/vmware300/cleanup_installation.sh --sudoterm
SCRIPT_VERSION="6.1.2"

### BEGIN INIT INFO
# Provides:          nutanix_move
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start daemon at boot time
# Description:       Enable service provided by daemon.
### END INIT INFO

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
tmpDir="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$tmpDir/xtract-guest.log"
TEMP_TARGET_SCRIPT_COMPLETED_STATUS_FILE="$tmpDir/target-script-completed.txt"
exec 3>&1 1>>${LOG_FILE} 2>&1

set -x
sourcefilepath="$0"
echo "Running $sourcefilepath"

NUTANIX_MOVE_ARG="$1"
xtractMainIP=$xtractMainIP
sudoterm=false
retainIP=false
skipretainIP=false
retainIPscript=""
reconfigLVM=false
configureTempDisk=false
configureTempDiskscript=""
uninstallVMwareTools=false
installNgt=false
uninstallVMwareToolsscript=""
cleanup=false
cleanupscript=""
freeBSD=false
isCustomIP=false
prepConfFilePath=""
configeditPath=""

while [ "$#" -gt 0 ]; do
    case $1 in
    -m | --move-address)
        xtractMainIP=$2
        shift
        ;;
    -s | --sudoterm)
        sudoterm=true
        ;;
    -r | --retain-ip)
        retainIP=true
        case $2 in
        "-"*) ;;
        *)
            retainIPscript=$2
            shift
            ;;
        esac
        ;;
    -i | --skip-retain-ip)
        skipretainIP=true
        case $2 in
        "-"*) ;;
        *)
            retainIPscript=$2
            shift
            ;;
        esac
        ;;
    -l | --reconfig-lvm) reconfigLVM=true ;;
    -t | --configure-temp-disk)
        configureTempDisk=true
        case $2 in
        "-"*) ;;
        *)
            configureTempDiskscript=$2
            shift
            ;;
        esac
        ;;
    -u | --uninstall-vmware-tools)
        uninstallVMwareTools=true
        case $2 in
        "-"*) ;;
        *)
            uninstallVMwareToolsscript=$2
            shift
            ;;
        esac
        ;;
    -c | --cleanup)
        cleanup=true
        case $2 in
        "-"*) ;;
        *)
            cleanupscript=$2
            shift
            ;;
        esac
        ;;
    -f | --prep-conf-file-path)
        isCustomIP=true
        case $2 in
        "-"*) ;;
        *)
            prepConfFilePath=$2
            shift
            ;;
        esac
        ;;
    -e | --configedit-path)
        case $2 in
        "-"*) ;;
        *)
            configeditPath=$2
            shift
            ;;
        esac
        ;;
    -n | --install-ngt)
        installNgt=true
        case $2 in
        "-"*) ;;
        *)
            installNgtScriptPath=$2
            shift
            ;;
        esac
        ;;
    esac
    shift
done

date
name="nutanix_move"
start_cmd="${name}_start"
stop_cmd=":"
destfilepath="/etc/init.d/nutanix-move"
SOURCE_ID_FILE="/etc/sourcevm-idfile"
BSD_IFILE="/etc/rc.conf"
ENABLE_MOVE="nutanix_move_enable=\"YES\""
DHCP_FILE="/etc/sourcevm-dhcpfile"
SCRIPTS_DIR="/opt/Nutanix/Move/download/scripts"
LVM_CONFIG_FILE="/etc/lvm/lvm.conf"
BACKUP_SUFFIX=".bak"
TEMPDISK_SIZE_FILE="/etc/tempdisk_sizefile"
CLEANUP_DIR="/opt/Nutanix/Uninstall/scripts"
cleanupscriptpath="$CLEANUP_DIR/cleanup_installation.sh"
LOG_DIR="/opt/Nutanix/log"
TARGET_SCRIPT_COMPLETED_STATUS_FILE=$LOG_DIR/target-script-completed.txt
BASH_CMD="bash"
SYSTEMD_PATH="/etc/systemd/system"
UNINSTALL_VMWARETOOLS_TIMEOUT=180
INSTALL_NGT_TIMEOUT=1500
CONFIGURE_TEMP_DISK_TIMEOUT=180
RETAIN_IP_TIMEOUT=200
CLEANUP_SCRIPT_TIMEOUT=100
MISC_OPS_TIMEOUT=100
TOTAL_SCRIPTS_TIMEOUT=$((INSTALL_NGT_TIMEOUT+CONFIGURE_TEMP_DISK_TIMEOUT+RETAIN_IP_TIMEOUT+CLEANUP_SCRIPT_TIMEOUT+MISC_OPS_TIMEOUT))
# If you are changing the value here please also change the field TimeoutSec it in write_service_file
NUTANIX_MOVE_SCRIPT_TIMEOUT=2500
CONF_DIR="/opt/Nutanix/Move/download/conf"
PREP_CONF_FILE="${CONF_DIR}/pcf.json"
BIN_DIR="/opt/Nutanix/Move/download/bin"
CONFIGEDIT_PATH="${BIN_DIR}/configedit"

rm $TARGET_SCRIPT_COMPLETED_STATUS_FILE
rm $TEMP_TARGET_SCRIPT_COMPLETED_STATUS_FILE

## Function to log messages to log file and console
write_log() {
    set +x
    # args
    local msg="$1"
    # Second arg if present is a boolean for mentioning avoidConsole
    local avoidConsole=${2:-false}
    local severity=${3:-INFO}
    #echo $msg, $lineno, $avoidConsole, $severity

    local final_msg="$(date +"%d-%m-%YT%H:%M:%S") ${severity} ${msg}"
    if [ "$avoidConsole" = true ]; then
        echo ${final_msg}

    else
        # Splitting since console msg and log msg needs to be different(no timestamp)
        #echo ${final_msg} | tee /dev/fd/3
        echo ${final_msg}
        echo ${msg} 1>&3
    fi
    set -x
    return 0
}

if [ $NUTANIX_MOVE_SCRIPT_TIMEOUT -lt $TOTAL_SCRIPTS_TIMEOUT ]; then
    write_log "The timeout for all the scripts combined is greater than the timeout for the nutanix-move script"
    exit 1
fi

write_service_file() {
    destfilename=${destfilepath##*/}
    cat <<EOF >$SYSTEMD_PATH/$destfilename.service
[Service]
Type=forking
ExecStart=/bin/bash $destfilepath
TimeoutSec=2500

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 $SYSTEMD_PATH/$destfilename.service
}
uname | grep -i freebsd
errorVal=$?
if [ $errorVal = 0 ]; then
    write_log "FreeBSD os detected."
    set +x
    freeBSD=true
    BASH_CMD="sh"
    . /etc/rc.subr
    rcvar=$(set_rcvar)
    destfilepath="/etc/rc.d/nutanix-move"
    load_rc_config $name
    set -x
fi

if [ $sudoterm = true -a $(id -u) != 0 ]; then # check if you are root
    chmod 755 $sourcefilepath
    write_log "Starting the script as root"
    if [ "$freeBSD" = true ]; then
        ./sudoTermFreeBSD -s "$sourcefilepath"
    else
        ./sudoTerm -s "$sourcefilepath"
    fi
    exit $?
fi

wget_with_retry() {
    for i in $(seq 1 $RETRIES); do
        wget -P "${1}" "${2}"
        errorVal=$?
        if [ ${errorVal} -eq 0 ]; then
            return 0
        fi
    done
    return 1
}

is_custom_ips_flow() {
  if [ -f "${PREP_CONF_FILE}" ]; then
    isCustomIP=true
  fi
}

cleanup_start_of_nutanix_move_service_on_restart() {
    destfilename=${destfilepath##*/}

    # Stop the service form running in future
    if [ "$freeBSD" = true ]; then
        sed -i -e '/^nutanix_move_enable="YES"$/d' /etc/rc.conf
    elif [ -f /etc/redhat-release ]; then
        rc=0
        # disable using chkconfig if systemctl not present
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            chkconfig --del $destfilename
            rc=$?
        else
            systemctl disable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then exit $rc; fi
    elif [ -f /etc/debian_version ]; then
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            update-rc.d -f $destfilename remove
            rc=$?
        else
            systemctl disable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then exit $rc; fi
    elif [ -f /etc/SuSE-release ]; then
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            chkconfig --del $destfilename
            rc=$?
        else
            systemctl disable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then exit $rc; fi
    elif [ -f /etc/os-release ]; then
        # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
        isSuSe=$(grep -ie "suse" /etc/os-release)
        if [ ${#isSuSe} -gt 0 ]; then
            rc=0
            systemctlpath=`whereis systemctl`
            if [ -z ${systemctlpath#"systemctl:"} ]; then
                chkconfig --del $destfilename
                rc=$?
            else
                systemctl disable $destfilename.service
                rc=$?
            fi
            if [ $rc != 0 ]; then exit $rc; fi
        fi
    fi
}

do_source() {
    write_log "Starting nutanix_move script with xtractMainIP $xtractMainIP retainIP $retainIP skipRetainIP $skipretainIP reconfigLVM $reconfigLVM configureTempDisk $configureTempDisk uninstallVMwareTools $uninstallVMwareTools cleanup $cleanup"

    exit_status=0
    destfilename=${destfilepath##*/}
    mkdir -p "$SCRIPTS_DIR" "$CONF_DIR" "$BIN_DIR"
    if [ "$retainIP" = true -o "$skipretainIP" = true -o -f $SCRIPTS_DIR/retainIP.sh ]; then
        if [ ! -f $SCRIPTS_DIR/retainIP.sh ]; then
            if [ ! -z $retainIPscript ]; then
                mv $retainIPscript $SCRIPTS_DIR
                if [ "$?" -ne 0 ]; then
                    write_log "RetainIP script path provided is not correct. Copying from $tmpDir/nutanix_move/retainIP.sh"
                    mv $tmpDir/nutanix_move/retainIP.sh $SCRIPTS_DIR
                    if [ "$?" -ne 0 ]; then
                        write_log "RetainIP script are not in current $tmpDir/nutanix_move/retainIP.sh"
                        exit_status=1
                    fi
                fi
            else
                wget_with_retry $SCRIPTS_DIR $xtractMainIP/retainIP.sh
                if [ "$?" -ne 0 ]; then
                    write_log "Could not download retainIP script."
                    exit_status=1
                fi
            fi
        fi
        $BASH_CMD $SCRIPTS_DIR/retainIP.sh "source"
        if [ "$?" -ne 0 ]; then
            write_log "Retain IP Failed"
            exit_status=1
        fi
    fi

    if [ "$skipretainIP" = true ]; then
        echo "true" >$DHCP_FILE
    fi

    if [ "$reconfigLVM" = true ]; then
        write_log "\n*** Running reconfigLVM on source VM ***\n"
        #No-op if lvmetad not runing
        grep 'use_lvmetad.*=.*1' $LVM_CONFIG_FILE
        rc=$?
        if [ $rc != 0 ]; then
            write_log "lvmetad not running. Returning success."
        else
            # backup and modify original lvm.conf
            sed -i$BACKUP_SUFFIX 's/use_lvmetad.*=.*1/use_lvmetad = 0/' $LVM_CONFIG_FILE
        fi
    fi

    if [ "$configureTempDisk" = true ]; then
        write_log "\n*** Running configureTempDisk on source VM ***\n"
        if [ ! -L /dev/disk/azure/resource -a ! -L /dev/disk/cloud/azure_resource ]; then
            write_log "ConfigureTempDisk_debug : Temporary Disk does not exist!"
        else
            disk=""
            if [ -L /dev/disk/azure/resource ]; then
                disk=$(readlink -f /dev/disk/azure/resource)
            else
                disk=$(readlink -f /dev/disk/cloud/azure_resource)
            fi
            temp_disk_size=$(awk -v disk="$disk" '"/dev/"$4 == disk {print $3}' /proc/partitions)
            echo $temp_disk_size >$TEMPDISK_SIZE_FILE
            write_log "ConfigureTempDisk_debug : Temporary disk of size $temp_disk_size KB detected"
            if [ ! -f $SCRIPTS_DIR/configureTempDisk.sh ]; then
                if [ ! -z $configureTempDiskscript ]; then
                    mv $configureTempDiskscript $SCRIPTS_DIR
                    if [ "$?" -ne 0 ]; then
                        write_log "configureTempDisk script path provided is not correct. Copying from $tmpDir/nutanix_move/configureTempDisk.sh"
                        mv $tmpDir/nutanix_move/configureTempDisk.sh $SCRIPTS_DIR
                        if [ "$?" -ne 0 ]; then
                            write_log "configureTempDisk script are not in $tmpDir/nutanix_move/configureTempDisk.sh"
                            exit_status=1
                        fi
                    fi
                else
                    wget_with_retry $SCRIPTS_DIR $xtractMainIP/configureTempDisk.sh
                    if [ "$?" -ne 0 ]; then
                        write_log "Could not download configureTempDisk script."
                        exit_status=1
                    fi
                fi
            fi
        fi
    fi

    if [ ! -f $SCRIPTS_DIR/uninstallVMwareTools.sh -a "$uninstallVMwareTools" = true ]; then
        write_log "\n*** Downloading uninstallVMwareTools script on source VM ***\n"
        if [ ! -z $uninstallVMwareToolsscript ]; then
            mv $uninstallVMwareToolsscript $SCRIPTS_DIR
            if [ "$?" -ne 0 ]; then
                write_log "UninstallVMWareTools script path provided is not correct. Copying from $tmpDir/nutanix_move/uninstallVMwareTools.sh"
                mv $tmpDir/nutanix_move/uninstallVMwareTools.sh $SCRIPTS_DIR
                if [ "$?" -ne 0 ]; then
                    write_log "UninstallVMWareTools script are not in $tmpDir/nutanix_move/uninstallVMwareTools.sh"
                    exit_status=1
                fi
            fi
        else
            wget_with_retry $SCRIPTS_DIR $xtractMainIP/uninstallVMwareTools.sh
            if [ "$?" -ne 0 ]; then
                write_log "Could not download uninstallVMwareTools script."
                exit_status=1
            fi
        fi
    fi

    if [ ! -f $SCRIPTS_DIR/install_ngt.sh -a "$installNgt" = true ]; then
        write_log "\n*** Downloading Install NGT script on source VM ***\n"
        if [ ! -z $installNgtScriptPath ]; then
            mv $installNgtScriptPath $SCRIPTS_DIR
            if [ "$?" -ne 0 ]; then
                write_log "Install NGT script path provided is not correct. Copying from $tmpDir/nutanix_move/install_ngt.sh"
                mv $tmpDir/nutanix_move/install_ngt.sh $SCRIPTS_DIR
                if [ "$?" -ne 0 ]; then
                    write_log "Install NGT script is not in $tmpDir/nutanix_move/install_ngt.sh"
                    exit_status=1
                fi
            fi
        else
            wget_with_retry $SCRIPTS_DIR $xtractMainIP/install_ngt.sh
            if [ "$?" -ne 0 ]; then
                write_log "Could not download Install NGT script."
                exit_status=1
            fi
        fi
    fi

    is_custom_ips_flow
    if [ ${isCustomIP} = true ]; then
        write_log "\n*** Keeping prep conf file properly in source VM ***\n"
        if [ ! -z $prepConfFilePath ]; then
            prepConfFileName=${prepConfFilePath##*/}
            /bin/mv -f $prepConfFilePath $CONF_DIR/ && /bin/cp -f "$CONF_DIR/$prepConfFileName" "${PREP_CONF_FILE}"
            if [ "$?" -ne 0 ]; then
                write_log "Prep conf file path provided is not correct. Copying from $tmpDir/nutanix_move/"
                /bin/mv -f $tmpDir/nutanix_move/$prepConfFileName $CONF_DIR/ && /bin/cp -f "$CONF_DIR/$prepConfFileName" "${PREP_CONF_FILE}"
                if [ "$?" -ne 0 ]; then
                    write_log "Prep conf file is not available in path $tmpDir/nutanix_move/$prepConfFileName"
                    exit_status=1
                fi
            fi
            # TODO: else with wget_with_retry can be added once other providers also support custom IP.
        fi

        write_log "\n*** Keeping configedit properly in source VM ***\n"
        if [ ! -z $configeditPath ]; then
            configeditName=${configeditPath##*/}
            /bin/mv -f $configeditPath "${CONFIGEDIT_PATH}"
            if [ "$?" -ne 0 ]; then
                write_log "configedit path provided is not correct. Copying from $tmpDir/nutanix_move/"
                /bin/mv -f $tmpDir/nutanix_move/$configeditName "${CONFIGEDIT_PATH}"
                if [ "$?" -ne 0 ]; then
                    write_log "configedit is not available in path $tmpDir/nutanix_move/$configeditPath"
                    exit_status=1
                fi
            fi
            # TODO: else with wget_with_retry can be added once other providers also support custom IP.
            chmod a+x "${CONFIGEDIT_PATH}"
        fi
    fi

    if [ ! -f "$cleanupscriptpath" -a "$cleanup" = true ]; then
        mkdir -p $CLEANUP_DIR
        write_log "\n*** Downloading cleanup_installation script on source VM ***\n"
        if [ ! -z $cleanupscript ]; then
            mv $cleanupscript $CLEANUP_DIR
            if [ "$?" -ne 0 ]; then
                write_log "Cleanup script path provided is not correct. Copying from $tmpDir/nutanix_move/cleanup_installation.sh"
                mv $tmpDir/nutanix_move/cleanup_installation.sh $SCRIPTS_DIR
                if [ "$?" -ne 0 ]; then
                    write_log "Cleanup script are not in $tmpDir/nutanix_move/cleanup_installation.sh"
                    exit_status=1
                fi
            fi
        else
            wget_with_retry $CLEANUP_DIR $xtractMainIP/cleanup_installation.sh
            if [ "$?" -ne 0 ]; then
                write_log "Could not download cleanup script."
                exit_status=1
            fi
        fi
    fi

    if [ -f $destfilepath ]; then
        exit $exit_status
    fi
    # check if /etc/init.d directory exists
    # In rhel 9, it is not present by default
    if [ ! -d $( dirname $destfilepath ) ]; then
        mkdir -p $( dirname $destfilepath )
    fi
    # Copy the script to /etc/init.d
    cp $sourcefilepath $destfilepath
    rc=$?
    if [ $rc != 0 ]; then exit $rc; fi
    chmod 755 $destfilepath
    rc=$?
    if [ $rc != 0 ]; then exit $rc; fi

    # Run the script on startup
    if [ "$freeBSD" = true ]; then
        echo $ENABLE_MOVE >>$BSD_IFILE
        # The hostuuid is saved here and used later to distinguish source from
        # target
        kenv smbios.system.uuid >$SOURCE_ID_FILE
        mkdir -p $LOG_DIR
        cp $tmpDir/xtract-guest.log $LOG_DIR/xtract-source.log
        exit $exit_status
    fi
    if [ -f /etc/redhat-release ]; then
        # if chkconfig is not present then use systemd to schedule service
        # file execution
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            chkconfig --add $destfilename
            rc=$?
        else
            write_service_file
            systemctl daemon-reload
            systemctl enable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then
            rm -f $destfilepath
            exit $rc
        fi
    elif [ -f /etc/debian_version ]; then
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            update-rc.d $destfilename defaults
            rc=$?
        else
            write_service_file
            systemctl daemon-reload
            systemctl enable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then
            rm -f $destfilepath
            exit $rc
        fi
    elif [ -f /etc/SuSE-release ]; then
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            chkconfig --add $destfilename
            rc=$?
        else
            write_service_file
            systemctl daemon-reload
            systemctl enable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then
            rm -f $destfilepath
            exit $rc
        fi
    elif [ -f /etc/almalinux-release ]; then
        rc=0
        systemctlpath=`whereis systemctl`
        if [ -z ${systemctlpath#"systemctl:"} ]; then
            chkconfig --add $destfilename
            rc=$?
        else
            write_service_file
            systemctl daemon-reload
            systemctl enable $destfilename.service
            rc=$?
        fi
        if [ $rc != 0 ]; then
            rm -f $destfilepath
            exit $rc
        fi
    elif [ -f /etc/os-release ]; then
        # This case is for versions of SuSe(like SuSe15 where /etc/SuSE-release file does not exist
        isSuSe=$(grep -ie "suse" /etc/os-release)
        if [ ${#isSuSe} -gt 0 ]; then
            rc=0
            systemctlpath=`whereis systemctl`
            if [ -z ${systemctlpath#"systemctl:"} ]; then
                chkconfig --add $destfilename
                rc=$?
            else
                write_service_file
                systemctl daemon-reload
                systemctl enable $destfilename.service
                rc=$?
                # This is the case where enabling of the
                # service failed with systemctl(insserv command not present),
                # we can try enable it using chkconfig
                # But the disabling of the service can only
                # be done using systemctl
                if [ $rc != 0 ]; then
                    chkconfig --add $destfilename
                    rc=$?
                fi
            fi
            if [ $rc != 0 ]; then
                rm -f $destfilepath
                exit $rc
            fi
        fi
    fi
    write_log "NutanixMove_debug : Copying UUID to $SOURCE_ID_FILE"
    cat /sys/class/dmi/id/product_uuid >$SOURCE_ID_FILE
    mkdir -p $LOG_DIR
    cp $tmpDir/xtract-guest.log $LOG_DIR/xtract-source.log
    exit $exit_status
}

do_target() {
    cleanup_start_of_nutanix_move_service_on_restart
    destfilename=${destfilepath##*/}
    clean_scripts=true

    if [ "$freeBSD" = true ]; then
        PATH="/usr/local/bin:/usr/local/sbin:/root/bin:$PATH"
        export PATH
    fi
    # Check if timeout command is present
    which timeout
    is_timeout=$?

    if [ -f "$LVM_CONFIG_FILE$BACKUP_SUFFIX" ]; then
        # Copy original lvm.conf back
        write_log "Restoring lvm configuration and starting lvm2-lvmetad"
        mv $LVM_CONFIG_FILE$BACKUP_SUFFIX $LVM_CONFIG_FILE
        # Start lvmetad
        systemctl start lvm2-lvmetad
    fi

    if [ -f "$SCRIPTS_DIR/configureTempDisk.sh" ]; then
        write_log "*** Running configureTempDisk script on target VM ***"
        if [ $is_timeout = 0 ]; then
            write_log "Running the command using timeout"
            timeout -s SIGKILL $CONFIGURE_TEMP_DISK_TIMEOUT $BASH_CMD $SCRIPTS_DIR/configureTempDisk.sh
        else
            write_log "Running the command without timeout"
            $BASH_CMD $SCRIPTS_DIR/configureTempDisk.sh
        fi
        if [ "$?" -ne 0 ]; then
            clean_scripts=false
            write_log "Could not configure Temporary Disk on target"
        else
            write_log "Configure Temp Disk script completed successfully"
        fi
    fi

    if [ -f "$SCRIPTS_DIR/uninstallVMwareTools.sh" ]; then
        # Run Uninstall Vmware Tools script
        write_log "*** Running uninstallVMwareTools script on target VM ***"
        if [ $is_timeout = 0 ]; then
            write_log "Running the command using timeout"
            timeout -s SIGKILL $UNINSTALL_VMWARETOOLS_TIMEOUT $BASH_CMD $SCRIPTS_DIR/uninstallVMwareTools.sh
        else
            write_log "Running the command without timeout"
            $BASH_CMD $SCRIPTS_DIR/uninstallVMwareTools.sh
        fi
        if [ "$?" -ne 0 ]; then
            clean_scripts=false
            write_log "Could not uninstall VMWare Tools"
        else
            write_log "Uninstall VMware Tools script completed successfully"
        fi
    fi

    if [ -f "$SCRIPTS_DIR/retainIP.sh" ]; then
        write_log "*** Running retainIP script on target VM ***"
        if [ $is_timeout = 0 ]; then
            write_log "Running the command using timeout"
            timeout -s SIGKILL $RETAIN_IP_TIMEOUT $BASH_CMD $SCRIPTS_DIR/retainIP.sh "target"
        else
            write_log "Running the command without timeout"
            $BASH_CMD $SCRIPTS_DIR/retainIP.sh "target"
        fi
        if [ "$?" -ne 0 ]; then
            clean_scripts=false
            write_log "IP restoration Failed"
        else
            write_log "Retain IP script completed successfully"
        fi
    fi

    if [ -f "$SCRIPTS_DIR/install_ngt.sh" ]; then
        # Run Install NGT script
        write_log "*** Running install_ngt script on target VM ***"
        if [ $is_timeout = 0 ]; then
            write_log "Running the command using timeout"
            timeout -s SIGKILL $INSTALL_NGT_TIMEOUT $BASH_CMD $SCRIPTS_DIR/install_ngt.sh
        else
            write_log "Running the command without timeout"
            $BASH_CMD $SCRIPTS_DIR/install_ngt.sh
        fi
        if [ "$?" -ne 0 ]; then
            clean_scripts=false
            write_log "NGT service has not yet started, please check if the service starts after reboot"
        else
            write_log "Install NGT script completed successfully"
        fi
    fi

    if [ -f "$cleanupscriptpath" ]; then
        # Run the cleanup script.
        write_log "*** Running cleanup_installation script on target VM ***"
        if [ $is_timeout = 0 ]; then
            write_log "Running the command using timeout"
            timeout -s SIGKILL $CLEANUP_SCRIPT_TIMEOUT $BASH_CMD $cleanupscriptpath --skip-remove-schedule-service-file --skip-confs-restore --clean-scripts $clean_scripts
        else
            write_log "Running the command without timeout"
            $BASH_CMD $cleanupscriptpath --skip-remove-schedule-service-file --skip-confs-restore --clean-scripts $clean_scripts
        fi
        if [ "$?" -ne 0 ]; then
            write_log "Target cleanup failed"
        else
            write_log "Target cleanup completed successfully"
        fi
    fi

    rm -f $destfilepath
    rm -f $SYSTEMD_PATH/$destfilename.service

    mkdir -p $LOG_DIR
    write_log "RetainIP_debug : Rebooting VM"
    cp $tmpDir/xtract-guest.log $LOG_DIR/xtract-target.log
    date +'%s' > $TEMP_TARGET_SCRIPT_COMPLETED_STATUS_FILE
    cp $TEMP_TARGET_SCRIPT_COMPLETED_STATUS_FILE $TARGET_SCRIPT_COMPLETED_STATUS_FILE
    reboot
}

do_start() {
    # product_uuid is unique for each VM and is assigned by the system
    # bios/board. SOURCE_ID_FILE contains the product_uuid from the sourcevm
    # when it was prepared. Here, if we find that the product_uuid is same as
    # what is stored in SOURCE_ID_FILE then we are executing on the sourcevm
    # else we are on target.

    if [ -f "$SOURCE_ID_FILE" ]; then
        srcUuid=$(cat "$SOURCE_ID_FILE")
        vmUuid=""
        if [ "$freeBSD" = true ]; then
            vmUuid=$(kenv smbios.system.uuid)
        else
            vmUuid=$(cat /sys/class/dmi/id/product_uuid)
        fi
        write_log "NutanixMove : do_start with $vmUuid $srcUuid"
        if [ "$srcUuid" = "$vmUuid" ]; then
            do_source
        else
            do_target
        fi
        return 0
    else
        do_source
    fi
}

# Carry out specific functions when asked to by the system
nutanix_move_start() {
    echo "Starting script nutanix_move"
    do_start
}

# Carry out specific functions when asked to by the system
if [ "$freeBSD" = true ]; then
    run_rc_command "$NUTANIX_MOVE_ARG"
else
    case "$NUTANIX_MOVE_ARG" in
    start)
        write_log "Starting script nutanix_move"
        do_start
        ;;
    stop)
        write_log "Stopping script nutanix_move"
        # No-op
        ;;
    *)
        write_log "Starting script nutanix_move"
        do_start
        ;;
    esac
fi
exit 0
