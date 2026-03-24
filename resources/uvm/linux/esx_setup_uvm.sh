#!/bin/sh
# Version: 6.1.2
# Usage:  ./esx_setup_uvm.sh --move-address xtractMainIP --retain-ip --install-amd --reconfig-lvm --uninstall-vmware-tools --reconfig-fstab --install-ngt
# eg: ./esx_setup_uvm.sh --move-address 10.46.61.199 --retain-ip --install-amd --reconfig-lvm --uninstall-vmware-tools --reconfig-fstab --install-ngt
NXBASE_DIR="/opt/Nutanix"
mkdir -p ${NXBASE_DIR}
cd ${NXBASE_DIR}
LOG_DIR="${NXBASE_DIR}/log"
LOG_FILE="${LOG_DIR}/uvm_script.log"
mkdir -p ${LOG_DIR}
exec 3>&1 1>>${LOG_FILE} 2>&1
set -x

xtractMainIP=$xtractMainIP
retainIP=false
installAMD=false
reconfigLVM=false
uninstallVMwareTools=false
reconfigFstab=false
installNgt=false

while [ "$#" -gt 0 ]; do
    case $1 in
    -m | --move-address)
        xtractMainIP=$2
        shift
        ;;
    -r | --retain-ip) retainIP=true ;;
    -d | --install-amd) installAMD=true ;;
    -l | --reconfig-lvm) reconfigLVM=true ;;
    -u | --uninstall-vmware-tools) uninstallVMwareTools=true ;;
    -s | --reconfig-fstab) reconfigFstab=true ;;
    -n | --install-ngt) installNgt=true ;;
    esac
    shift
done

PREPARE_DIR="${NXBASE_DIR}/Move"
UNINSTALL_DIR="${NXBASE_DIR}/Uninstall"
DOWNLOAD_DIR="${PREPARE_DIR}/download"
SCRIPTS_DIR="${DOWNLOAD_DIR}/scripts"
UNINSTALL_SCRIPTS_DIR="${UNINSTALL_DIR}/scripts"
DOWNLOAD_VIRTIO_DIR="${DOWNLOAD_DIR}/virtio"
VIRTIO_SCRIPTS_DOWN_DIR="${DOWNLOAD_VIRTIO_DIR}/scripts"
PREP_STATE_FILE="${NXBASE_DIR}/prep_state"
NUTANIX_MOVE_INSTALL_SCRIPT_NAME="nutanix_move.sh"
NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH="${SCRIPTS_DIR}/${NUTANIX_MOVE_INSTALL_SCRIPT_NAME}"
RETAINIP_SCRIPT_NAME="retainIP.sh"
RETAINIP_SCRIPT_DOWN_PATH="$SCRIPTS_DIR/${RETAINIP_SCRIPT_NAME}"
INSTALL_NGT_SCRIPT_NAME="install_ngt.sh"
INSTALL_NGT_SCRIPT_DOWN_PATH="$SCRIPTS_DIR/${INSTALL_NGT_SCRIPT_NAME}"
UNINSTALL_VMWARE_TOOLS_SCRIPT_NAME="uninstallVMwareTools.sh"
UNINSTALL_VMWARE_TOOLS_SCRIPT_DOWN_PATH="$SCRIPTS_DIR/${UNINSTALL_VMWARE_TOOLS_SCRIPT_NAME}"
RECONFIG_FSTAB_SCRIPT_NAME="reconfig_fstab.sh"
RECONFIG_FSTAB_SCRIPT_DOWN_PATH="$SCRIPTS_DIR/${RECONFIG_FSTAB_SCRIPT_NAME}"
CLEANUP_SCRIPT_NAME="cleanup_installation.sh"
CLEANUP_SCRIPT_DOWN_PATH="$UNINSTALL_SCRIPTS_DIR/${CLEANUP_SCRIPT_NAME}"
VERIFICATION_SCRIPT_DOWN_PATH="$NXBASE_DIR/validate_prep_state.sh"

INSTALL_AMD="installAMD.sh"
VIRTIO_INSTALL_SCRIPT_DOWN_PATH="${VIRTIO_SCRIPTS_DOWN_DIR}/${INSTALL_AMD}"
IS_AMD_INSTALLED="isAMDInstalled.sh"
VIRTIO_VERIFY_SCRIPT_DOWN_PATH="${VIRTIO_SCRIPTS_DOWN_DIR}/${IS_AMD_INSTALLED}"
USE_BASH=1
ARGS="--sudoterm --cleanup"
NUTANIX_MOVE_ARG="setup"

# Global variable to track which download tool to use
DOWNLOAD_TOOL=""

write_log() {
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
        echo "${msg}" 1>&3
    fi

    return 0
}

# Colors
ESC=$(printf '\033')
RED="${ESC}[0;31m"
GREEN="${ESC}[0;32m"
YELLOW="${ESC}[1;33m"
BLUE="${ESC}[0;34m"
CYAN="${ESC}[0;36m"
NC="${ESC}[0m" # No Color

# Prep State Management Functions
initialize_prep_state() {
    write_log "Initializing preparation state file: $PREP_STATE_FILE"
    # Create prep state file with all steps marked as "NotStarted"
    cat > "$PREP_STATE_FILE" << EOF
# VM Preparation State File
# Script Version: 6.0.1
# Format: STEP_NAME=STATUS
# Status values: NotStarted, Skipped, InProgress, Done, Failed, Interrupted
# Generated on: $(date)
# Script Arguments: retainIP=$retainIP installAMD=$installAMD reconfigLVM=$reconfigLVM uninstallVMwareTools=$uninstallVMwareTools reconfigFstab=$reconfigFstab installNgt=$installNgt

CHECK_DOWNLOAD_TOOL_AVAILABILITY=NotStarted
CHECK_CLEANUP_PREREQUISITE=NotStarted
PREPARE_DIRECTORIES=NotStarted
DOWNLOAD_ARTIFACTS=NotStarted
EOF

    # Add conditional steps based on arguments
    if [ ${installAMD} = true ]; then
        echo "INSTALL_VIRTIO_DRIVERS=NotStarted" >> "$PREP_STATE_FILE"
    else
        echo "INSTALL_VIRTIO_DRIVERS=Skipped" >> "$PREP_STATE_FILE"
    fi
    if [ ${reconfigFstab} = true ]; then
        echo "RECONFIGURE_FSTAB=NotStarted" >> "$PREP_STATE_FILE"
    else
        echo "RECONFIGURE_FSTAB=Skipped" >> "$PREP_STATE_FILE"
    fi
    echo "SCHEDULE_MOVE_SERVICE=NotStarted" >> "$PREP_STATE_FILE"
    echo "" >> "$PREP_STATE_FILE"
    echo "OVERALL_STATE=InProgress" >> "$PREP_STATE_FILE"

    write_log "Preparation state file initialized successfully"
}

update_prep_state() {
    local step_name="$1"
    local status="$2"

    # Update the status in the prep state file
    if [ -f "$PREP_STATE_FILE" ]; then
        # Use sed to update the specific line
        sed -i "s/^${step_name}=.*/${step_name}=${status}/" "$PREP_STATE_FILE"
        write_log "Updated prep state: $step_name = $status" true
    else
        write_log "Prep state file not found: $PREP_STATE_FILE" false "WARN"
    fi
}

update_overall_state() {
    local status="$1"
    update_prep_state "OVERALL_STATE" "$status"
    write_log "Updated overall state: $status" true
}

show_prep_state() {
    if [ -f "$PREP_STATE_FILE" ]; then
        write_log "Final preparation state:" false
        local step_number=0

        # Read the prep state file and display each step with proper formatting
        while IFS= read -r line; do
            # Skip empty lines and comment lines (POSIX-safe)
            case "$line" in
                "" | \#*)
                    continue
                    ;;
            esac

            # Only consider lines containing '=' as key=value entries
            case "$line" in
                *=*) ;;
                *) continue ;;
            esac

            # Split the line at the first '=' into step_name and status
            step_name="${line%%=*}"
            status="${line#*=}"

            # Trim possible leading/trailing whitespace from step_name and status
            # POSIX shells don't have a builtin trim, so use parameter expansion
            # remove leading spaces
            case "$step_name" in
                " "*) step_name="${step_name# }" ;;
            esac
            # remove trailing spaces
            case "$step_name" in
                *" ") step_name="${step_name% }" ;;
            esac

            case "$status" in
                " "*) status="${status# }" ;;
            esac
            case "$status" in
                *" ") status="${status% }" ;;
            esac

            # Skip skipped steps from numbering
            if [ "$status" = "Skipped" ]; then
                continue
            fi

            step_number=$((step_number + 1))

            # Convert step names to readable format
            case "$step_name" in
                "CHECK_CLEANUP_PREREQUISITE") readable_name="Checking cleanup prerequisite" ;;
                "PREPARE_DIRECTORIES") readable_name="Preparing directories" ;;
                "CHECK_DOWNLOAD_TOOL_AVAILABILITY") readable_name="Checking download tool availability" ;;
                "DOWNLOAD_ARTIFACTS") readable_name="Downloading required artifacts" ;;
                "INSTALL_VIRTIO_DRIVERS") readable_name="Installing VirtIO drivers" ;;
                "RECONFIGURE_FSTAB") readable_name="Reconfiguring fstab" ;;
                "SCHEDULE_MOVE_SERVICE") readable_name="Scheduling move service" ;;
                "OVERALL_STATE") readable_name="Overall State" ;;
                *) readable_name="$step_name" ;;
            esac

            # Set color based on status
            case "$status" in
                "Done")
                    color="${GREEN}"
                    status_text="Done"
                    ;;
                "Failed"*|"Interrupted"*)
                    color="${RED}"
                    status_text="$status"
                    ;;
                "InProgress")
                    color="${YELLOW}"
                    status_text="In Progress"
                    ;;
                "Success")
                    color="${GREEN}"
                    status_text="Success"
                    ;;
                *)
                    color="${NC}"
                    status_text="$status"
                    ;;
            esac

            if [ "$step_name" = "OVERALL_STATE" ]; then
                printf "\n%s: %s%s%s\n" "$readable_name" "$color" "$status_text" "$NC" 1>&3
            else
                # Display in the same format as during execution
                printf "%s[STEP-%d/%d]%s %s: %s%s%s\n" "$GREEN" "$step_number" "$TOTAL_STEPS" "$NC" "$readable_name" "$color" "$status_text" "$NC" 1>&3
            fi
        done < "$PREP_STATE_FILE"
    else
        write_log "Prep state file not found: $PREP_STATE_FILE" false "WARN"
    fi
}

# Function to mark interrupted steps as "Interrupted"
cleanup_prep_state_on_exit() {
    if [ -f "$PREP_STATE_FILE" ]; then
        # Mark any "InProgress" steps as "Interrupted" on script exit
        sed -i 's/=InProgress.*/=Interrupted/' "$PREP_STATE_FILE"
        write_log "Marked interrupted steps as 'Interrupted' in prep state file" true

    fi
}

# Set trap to cleanup prep state on script exit
trap cleanup_prep_state_on_exit EXIT

# Step numbering variables
CURRENT_STEP=0
TOTAL_STEPS=0

# Function to calculate total steps based on script arguments
calculate_total_steps() {
    TOTAL_STEPS=5  # Base steps: cleanup check, directories, curl check, download, schedule move

    if [ ${installAMD} = true ]; then
        TOTAL_STEPS=$((TOTAL_STEPS + 1))
    fi

    if [ ${reconfigFstab} = true ]; then
        TOTAL_STEPS=$((TOTAL_STEPS + 1))
    fi
}

step_start() {
    local step="$1"
    local step_key="$2"  # Optional prep state key
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf "%s[STEP-%d/%d]%s %s: %s...Starting%s\n" "$YELLOW" "$CURRENT_STEP" "$TOTAL_STEPS" "$NC" "$step" "$YELLOW" "$NC" 1>&3
    write_log "[STEP-${CURRENT_STEP}/${TOTAL_STEPS}] Starting: $step" true

    # Update prep state if step_key is provided
    if [ -n "$step_key" ]; then
        update_prep_state "$step_key" "InProgress"
    fi
}

step_done() {
    local step="$1"
    local step_key="$2"  # Optional prep state key
    printf "%s[OK-%d/%d]%s %s: %sCompleted%s\n\n" "$GREEN" "$CURRENT_STEP" "$TOTAL_STEPS" "$NC" "$step" "$GREEN" "$NC" 1>&3
    write_log "[OK-${CURRENT_STEP}/${TOTAL_STEPS}]${NC} $step: Completed${NC}\n" true

    # Update prep state if step_key is provided
    if [ -n "$step_key" ]; then
        update_prep_state "$step_key" "Done"
    fi
}

step_fail() {
    local step="$1"
    local step_key="$2"  # Optional prep state key
    printf "%s[ERROR-%d/%d]%s %s: %sFailed%s\n" "$RED" "$CURRENT_STEP" "$TOTAL_STEPS" "$NC" "$step" "$RED" "$NC" 1>&3
    write_log "[ERROR-${CURRENT_STEP}/${TOTAL_STEPS}] $step: Failed\n" true

    # Update prep state if step_key is provided
    if [ -n "$step_key" ]; then
        update_prep_state "$step_key" "Failed"
    fi

    # Update overall state to Failed when any step fails
    update_overall_state "Failed"
    exit 1
}

# Sub-step functions with different colors
substep_start() {
    local substep="$1"
    printf "%s  [SUB]%s %s: %s...Starting%s\n" "$CYAN" "$NC" "$substep" "$CYAN" "$NC" 1>&3
    write_log "[SUB] $substep: Starting" true
}

substep_done() {
    local substep="$1"
    printf "%s  [SUB-OK]%s %s: %sCompleted%s\n" "$BLUE" "$NC" "$substep" "$BLUE" "$NC" 1>&3
    write_log "[SUB-OK] $substep: Completed" true
}

substep_fail() {
    local substep="$1"
    printf "%s  [SUB-ERROR]%s %s: %sFailed%s\n" "$RED" "$NC" "$substep" "$RED" "$NC" 1>&3
    write_log "[SUB-ERROR] $substep: Failed" true
}


uname | grep -i freebsd
errorVal=$?
if [ $errorVal = 0 ]; then
    write_log "FreeBSD os detected."
    INSTALL_AMD="installAMD_freebsd.sh"
    IS_AMD_INSTALLED="isAMDInstalled.sh"
    NUTANIX_MOVE_ARG="onestart"
    USE_BASH=0
fi
## Function to setup required directories in the User VM.
do_prerequisite_dirs() {
    write_log "Creating required directories to download and copy required artifacts."

    substep_start "Creating log directory"
    mkdir -p ${LOG_DIR}
    substep_done "Creating log directory"

    substep_start "Creating uninstall scripts directory"
    mkdir -p ${UNINSTALL_SCRIPTS_DIR}
    substep_done "Creating uninstall scripts directory"

    substep_start "Creating main scripts directory"
    mkdir -p ${SCRIPTS_DIR}
    substep_done "Creating main scripts directory"

    substep_start "Creating VirtIO scripts directory"
    mkdir -p ${VIRTIO_SCRIPTS_DOWN_DIR}
    substep_done "Creating VirtIO scripts directory"

    return 0
}

## Function to run cleanup script if it exists (for repeated executions)
# What happens in case of first time preperation
## When the script is run for the first time, it will try to download the cleanup script and run it.
# What happens in case of subsequent preperation
## On subsequent runs also it will be downloaded and run.
# What happen in case the customer ran the cleanup scripts and then this script
## if the customer has already run the cleanup script, it will run again and exit cleanly since the cleanup script is idempotent.
# What happens when the folder is not accessible
## if the folder is not accessible, the script will fail to download the cleanup script and exit with an error.
run_cleanup_if_exists() {
    write_log "Checking if cleanup script exists from previous installation."

    # First, try to download the cleanup script
    substep_start "Downloading cleanup script for prerequisite check"
    # create the output directory if not already present
    mkdir -p "$UNINSTALL_SCRIPTS_DIR"
    smart_download "https://${xtractMainIP}/resources/scripts/linux/$CLEANUP_SCRIPT_NAME" "$CLEANUP_SCRIPT_DOWN_PATH"
    local download_result=$?
    if [ $download_result -ne 0 ]; then
        write_log "Failed to download cleanup script. exit code: $download_result" false "ERROR"
        substep_fail "Downloading cleanup script for prerequisite check"
        return $download_result
    fi
    substep_done "Downloading cleanup script for prerequisite check"

    # Always execute the freshly downloaded cleanup script (idempotent) then remove it
    substep_start "Executing cleanup script"
    chmod +x "$CLEANUP_SCRIPT_DOWN_PATH" 2>/dev/null || true
    if [ ${USE_BASH:-0} -eq 1 ]; then
        bash "$CLEANUP_SCRIPT_DOWN_PATH"
    else
        sh "$CLEANUP_SCRIPT_DOWN_PATH"
    fi
    local cleanup_result=$?
    if [ $cleanup_result -eq 0 ]; then
        write_log "Cleanup script executed successfully." false "INFO"
        substep_done "Executing cleanup script"
    else
        write_log "Cleanup script reported errors (exit $cleanup_result). Proceeding but review logs." false "WARN"
        substep_done "Executing cleanup script (with warnings)"
    fi

    substep_start "Removing cleanup script"
    rm -f "$CLEANUP_SCRIPT_DOWN_PATH" 2>/dev/null || true
    substep_done "Removing cleanup script"
    return 0
}


#CURL/WGET check and selection
check_curl_or_wget() {
    substep_start "Testing download tool capabilities"

    # Check if curl is available
    curl_path=$(command -v curl 2>/dev/null)
    curl_available=$?

    if [ $curl_available -eq 0 ]; then
        write_log "Found curl at: $curl_path" true "DEBUG"

        # Test curl capability
        write_log "Testing curl download capability..." true "DEBUG"

        # Create test directory
        test_dir="/opt/Nutanix/test_download"
        mkdir -p "$test_dir" 2>/dev/null
        test_file="$test_dir/curl_test.tmp"

        # Test actual download capability
        curl -ks  \
             "https://${xtractMainIP}/resources/$INSTALL_AMD" \
             --output "$test_file" 2>/dev/null

        curl_result=$?

        # Clean up test file
        rm -f "$test_file" 2>/dev/null
        rmdir "$test_dir" 2>/dev/null

        if [ $curl_result -eq 0 ]; then
            write_log "Curl test successful - using curl" false "INFO"
            DOWNLOAD_TOOL="curl"
            substep_done "Testing download tool capabilities - using: $DOWNLOAD_TOOL"
            return 0
        else
            write_log "Curl test failed (exit code: $curl_result) - checking wget alternative" false "WARN"
            # Fall through to wget check
        fi
    else
        write_log "curl command not found - checking wget alternative" false "WARN"
        # Fall through to wget check
    fi

    # Check wget (either curl not found OR curl test failed)
    wget_path=$(command -v wget 2>/dev/null)
    wget_available=$?

    if [ $wget_available -ne 0 ]; then
        write_log "wget command not found. No suitable download tool available." false "ERROR"
        substep_fail "Testing download tool capabilities"
        return 1
    fi

    write_log "Found wget at: $wget_path" true "DEBUG"

    # Test wget capability
    write_log "Testing wget download capability..." true "DEBUG"

    # Create test directory
    test_dir="/opt/Nutanix/test_download"
    mkdir -p "$test_dir" 2>/dev/null
    test_file="$test_dir/wget_test.tmp"

    # Test actual download capability
    wget --no-check-certificate --quiet  \
         "https://${xtractMainIP}/resources/$INSTALL_AMD" \
         -O "$test_file" 2>/dev/null

    wget_result=$?

    # Clean up test file
    rm -f "$test_file" 2>/dev/null
    rmdir "$test_dir" 2>/dev/null

    if [ $wget_result -eq 0 ]; then
        write_log "Wget test successful - using wget" false "INFO"
        DOWNLOAD_TOOL="wget"
        substep_done "Testing download tool capabilities - using: $DOWNLOAD_TOOL"
        return 0
    else
        write_log "Wget test failed (exit code: $wget_result). No working download tool available." false "ERROR"
        substep_fail "Testing download tool capabilities"
        return 1
    fi
}

# Smart download function that uses curl or wget based on detection
smart_download() {
    local url="$1"
    local output_path="$2"

    if [ "$DOWNLOAD_TOOL" = "wget" ]; then
        # Use wget with equivalent options
        wget --no-check-certificate --quiet "$url" -O "$output_path"
        return $?
    else
        # Use curl with original options
        curl -ks "$url" --output "$output_path"
        return $?
    fi
}

## Function to download artifacts
download_artifacts() {
    write_log "Preparing Source VM. Downloading required artifacts."

    if [ ${installAMD} = true ]; then
        substep_start "Downloading VirtIO installation script"
        smart_download "https://${xtractMainIP}/resources/$INSTALL_AMD" "$VIRTIO_INSTALL_SCRIPT_DOWN_PATH"
        errorVal=$?
        if [ $errorVal != 0 ]; then
            rm -f $VIRTIO_INSTALL_SCRIPT_DOWN_PATH
            write_log "Failed to download $INSTALL_AMD script." false "EROR"
            substep_fail "Downloading VirtIO installation script"
            return $errorVal
        fi
        substep_done "Downloading VirtIO installation script"

        substep_start "Downloading VirtIO verification script"
        smart_download "https://${xtractMainIP}/resources/$IS_AMD_INSTALLED" "$VIRTIO_VERIFY_SCRIPT_DOWN_PATH"
        errorVal=$?
        if [ $errorVal != 0 ]; then
            rm -f $VIRTIO_VERIFY_SCRIPT_DOWN_PATH
            write_log "Failed to download $IS_AMD_INSTALLED script." false "EROR"
            substep_fail "Downloading VirtIO verification script"
            return $errorVal
        fi
        substep_done "Downloading VirtIO verification script"
    fi

    substep_start "Downloading IP retention script"
    smart_download "https://${xtractMainIP}/resources/scripts/linux/$RETAINIP_SCRIPT_NAME" "$RETAINIP_SCRIPT_DOWN_PATH"
    errorVal=$?
    if [ $errorVal != 0 ]; then
        rm -f $RETAINIP_SCRIPT_DOWN_PATH
        write_log "Failed to download $RETAINIP_SCRIPT_NAME script." false "EROR"
        substep_fail "Downloading IP retention script"
        return $errorVal
    fi
    substep_done "Downloading IP retention script"

    if [ "$uninstallVMwareTools" = true ]; then
        substep_start "Downloading VMware Tools uninstall script"
        smart_download "https://${xtractMainIP}/resources/scripts/linux/$UNINSTALL_VMWARE_TOOLS_SCRIPT_NAME" "$UNINSTALL_VMWARE_TOOLS_SCRIPT_DOWN_PATH"
        errorVal=$?
        if [ $errorVal != 0 ]; then
            rm -f $UNINSTALL_VMWARE_TOOLS_SCRIPT_DOWN_PATH
            write_log "Failed to download $UNINSTALL_VMWARE_TOOLS_SCRIPT_NAME script." false "EROR"
            substep_fail "Downloading VMware Tools uninstall script"
            return $errorVal
        fi
        substep_done "Downloading VMware Tools uninstall script"
    fi

    if [ "$reconfigFstab" = true ]; then
        substep_start "Downloading fstab reconfiguration script"
        smart_download "https://${xtractMainIP}/resources/$RECONFIG_FSTAB_SCRIPT_NAME" "$RECONFIG_FSTAB_SCRIPT_DOWN_PATH"
        errorVal=$?
        if [ $errorVal != 0 ]; then
            rm -f "$RECONFIG_FSTAB_SCRIPT_DOWN_PATH"
            write_log "Failed to download $RECONFIG_FSTAB_SCRIPT_NAME script." false "EROR"
            substep_fail "Downloading fstab reconfiguration script"
            return $errorVal
        fi
        substep_done "Downloading fstab reconfiguration script"
    fi

    if [ ${installNgt} = true ]; then
        substep_start "Downloading NGT installation script"
        smart_download "https://${xtractMainIP}/resources/scripts/linux/$INSTALL_NGT_SCRIPT_NAME" "$INSTALL_NGT_SCRIPT_DOWN_PATH"
        errorVal=$?
        if [ $errorVal != 0 ]; then
            rm -f $INSTALL_NGT_SCRIPT_DOWN_PATH
            write_log "Failed to download $INSTALL_NGT_SCRIPT_NAME script." false "ERROR"
            substep_fail "Downloading NGT installation script"
            return $errorVal
        fi
        substep_done "Downloading NGT installation script"
    fi

    substep_start "Downloading cleanup script"
    smart_download "https://${xtractMainIP}/resources/scripts/linux/$CLEANUP_SCRIPT_NAME" "$CLEANUP_SCRIPT_DOWN_PATH"
    errorVal=$?
    if [ $errorVal != 0 ]; then
        rm -f $CLEANUP_SCRIPT_DOWN_PATH
        write_log "Failed to download $CLEANUP_SCRIPT_NAME script." false "EROR"
        substep_fail "Downloading cleanup script"
        return $errorVal
    fi
    substep_done "Downloading cleanup script"

    substep_start "Downloading validation script"
    smart_download "https://${xtractMainIP}/resources/uvm/linux/validate_prep_state.sh" "$VERIFICATION_SCRIPT_DOWN_PATH"
    errorVal=$?
    if [ $errorVal != 0 ]; then
        rm -f validate_prep_state.sh
        write_log "Failed to download validate_prep_state.sh script." false "EROR"
        substep_fail "Downloading validation script"
        return $errorVal
    fi
    # make this file executable because by default curl doesn't maintain the file metadata.
    chmod +x $VERIFICATION_SCRIPT_DOWN_PATH 2>/dev/null || true
    substep_done "Downloading validation script"

    return 0
}

#Install the virtio
install_virtio_drivers() {

    substep_start "Checking if VirtIO drivers are already installed"
    if [ ${USE_BASH:-0} -eq 1 ]; then
        bash ${VIRTIO_VERIFY_SCRIPT_DOWN_PATH}
    else
        sh ${VIRTIO_VERIFY_SCRIPT_DOWN_PATH}
    fi
    errorVal=$?
    if [ ${errorVal} != 0 ]; then
        substep_done "Checking if VirtIO drivers are already installed (not installed)"
        write_log "Virtio drivers are not installed proceeding with their installation."

        substep_start "Installing VirtIO drivers"
        if [ ${USE_BASH:-0} -eq 1 ]; then
            bash ${VIRTIO_INSTALL_SCRIPT_DOWN_PATH}
        else
            sh ${VIRTIO_INSTALL_SCRIPT_DOWN_PATH}
        fi

        errorVal=$?

        if [ ${errorVal} != 0 ]; then
            write_log "Failed to install VirtIO drivers. This would impact migrated VM's network connectivity in AHV cluster. Please make sure to run the preparation script in root shell." false "EROR"
            substep_fail "Installing VirtIO drivers"
            update_prep_state "INSTALL_VIRTIO_DRIVERS" "Failed - Installation Error"
            return ${errorVal}
        fi
        substep_done "Installing VirtIO drivers"
    else
        substep_done "Checking if VirtIO drivers are already installed (already installed)"
        write_log "Virtio drivers are already installed."
        return 0
    fi

    substep_start "Verifying VirtIO driver installation"
    if [ ${USE_BASH:-0} -eq 1 ]; then
        bash ${VIRTIO_VERIFY_SCRIPT_DOWN_PATH} "--print-error"
    else
        sh ${VIRTIO_VERIFY_SCRIPT_DOWN_PATH} "--print-error"
    fi
    errorVal=$?
    if [ ${errorVal} -eq 0 ]; then
        write_log "Installing virtio drivers success."
        substep_done "Verifying VirtIO driver installation"
        return 0
    else
        write_log "Installing virtio failed." false "EROR"
        substep_fail "Verifying VirtIO driver installation"
        update_prep_state "INSTALL_VIRTIO_DRIVERS" "Failed - Verification Error"
        return ${errorVal}
    fi
    return 0
}

reconfig_fstab(){
	if [ ${USE_BASH:-0} -eq 1 ]; then
          bash ${RECONFIG_FSTAB_SCRIPT_DOWN_PATH}
      else
          sh ${RECONFIG_FSTAB_SCRIPT_DOWN_PATH}
      fi
      local fstab_result=$?
      if [ $fstab_result -eq 0 ]; then
          substep_done "Executing fstab reconfiguration script"
      else
          substep_fail "Executing fstab reconfiguration script"
      fi
      return $fstab_result
}

schedule_move_service() {
    substep_start "Downloading Nutanix Move installation script"
    smart_download "https://${xtractMainIP}/resources/scripts/linux/$NUTANIX_MOVE_INSTALL_SCRIPT_NAME" "$NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH"
    errorVal=$?
    if [ $errorVal != 0 ]; then
        rm -f $NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH
        write_log "Failed to download $NUTANIX_MOVE_INSTALL_SCRIPT_NAME script." false "EROR"
        substep_fail "Downloading Nutanix Move installation script"
        return $errorVal
    fi
    substep_done "Downloading Nutanix Move installation script"

    substep_start "Configuring move service arguments"
    #Retain IP
    if [ ${retainIP} = false ]; then
        ARGS="$ARGS --skip-retain-ip"
    else
        ARGS="$ARGS --retain-ip"
    fi
    #Reconfigure LVM
    if [ ${reconfigLVM} = true ]; then
        ARGS="$ARGS --reconfig-lvm"
    fi
    #Uninstall VMWare Tools
    if [ ${uninstallVMwareTools} = true ]; then
        ARGS="$ARGS --uninstall-vmware-tools"
    fi
    #Install NGT
    if [ ${installNgt} = true ]; then
        ARGS="$ARGS --install-ngt"
    fi
    substep_done "Configuring move service arguments"

    substep_start "Executing Nutanix Move setup"
    if [ ${USE_BASH:-0} -eq 1 ]; then
        bash ${NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH} $NUTANIX_MOVE_ARG --move-address "https://${xtractMainIP}/resources/scripts/linux/" $ARGS
    else
        sh ${NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH} $NUTANIX_MOVE_ARG --move-address "https://${xtractMainIP}/resources/scripts/linux/" $ARGS
    fi
    errorVal=$?
    if [ ${errorVal} != 0 ]; then
        rm -f ${NUTANIX_MOVE_INSTALL_SCRIPT_DOWN_PATH}
        write_log "Failed to setup nutanix move script. Please make sure to run the preparation script in root shell." false "EROR"
        substep_fail "Executing Nutanix Move setup"
        return ${errorVal}
    fi
    substep_done "Executing Nutanix Move setup"
    write_log "Successfully scheduled nutanix move script."
}

error_check() {
    #Args
    local error_code=$1
    local exit_message="$2"
    local step_key="$3"  # Optional prep state key
    if [ ${error_code} -ne 0 ]; then
        step_fail "$exit_message" "$step_key"
        exit ${error_code}
    fi
}

main() {

    write_log "Starting esx_setup_uvm.sh script with retainIP=$retainIP installAMD=$installAMD reconfigLVM=$reconfigLVM uninstallVMwareTools=$uninstallVMwareTools reconfigFstab=$reconfigFstab installNgt=$installNgt"

    # Calculate total steps based on script arguments
    calculate_total_steps

    # Initialize prep state tracking
    initialize_prep_state

    #Download tool check
    step_start "Checking download tool availability" "CHECK_DOWNLOAD_TOOL_AVAILABILITY"
    check_curl_or_wget
    local func_execution_status=$?
    error_check ${func_execution_status} "No suitable download tool found" "CHECK_DOWNLOAD_TOOL_AVAILABILITY"
    step_done "Checking download tool availability" "CHECK_DOWNLOAD_TOOL_AVAILABILITY"

    # Check and run cleanup script first (download, execute, delete)
    step_start "Checking cleanup prerequisite" "CHECK_CLEANUP_PREREQUISITE"
    run_cleanup_if_exists
    local func_execution_status=$?
    error_check ${func_execution_status} "Could not complete cleanup prerequisite check." "CHECK_CLEANUP_PREREQUISITE"
    step_done "Checking cleanup prerequisite" "CHECK_CLEANUP_PREREQUISITE"

    step_start "Preparing directories" "PREPARE_DIRECTORIES"
    do_prerequisite_dirs
    func_execution_status=$?
    error_check ${func_execution_status} "Could not prepare required directories." "PREPARE_DIRECTORIES"
    step_done "Preparing directories" "PREPARE_DIRECTORIES"


    step_start "Downloading required artifacts from the IP $xtractMainIP" "DOWNLOAD_ARTIFACTS"
    download_artifacts
    func_execution_status=$?
    error_check ${func_execution_status} "Could not download the required artifacts." "DOWNLOAD_ARTIFACTS"
    step_done "Downloading required artifacts" "DOWNLOAD_ARTIFACTS"

    # Virtio Installation
    if [ ${installAMD} = true ]; then
        step_start "Installing VirtIO drivers" "INSTALL_VIRTIO_DRIVERS"
        install_virtio_drivers
        func_execution_status=$?
        error_check ${func_execution_status} "Virtio Installation Failed" "INSTALL_VIRTIO_DRIVERS"
        step_done "Installing VirtIO drivers" "INSTALL_VIRTIO_DRIVERS"
    fi

    # Reconfigure fstab
    if [ ${reconfigFstab} = true ]; then
        step_start "Reconfiguring fstab" "RECONFIGURE_FSTAB"
        reconfig_fstab
        func_execution_status=$?
        error_check ${func_execution_status} "Reconfiguring fstab Failed" "RECONFIGURE_FSTAB"
        step_done "Reconfiguring fstab" "RECONFIGURE_FSTAB"
    fi

    step_start "Scheduling move service" "SCHEDULE_MOVE_SERVICE"
    schedule_move_service
    func_execution_status=$?
    error_check ${func_execution_status} "Scheduling move service failed" "SCHEDULE_MOVE_SERVICE"
    step_done "Scheduling move service" "SCHEDULE_MOVE_SERVICE"

    # Update overall state to Success when all steps complete successfully
    update_overall_state "Success"

    # Show final prep state
    printf "\n%s=== FINAL PREPARATION STATE ===%s\n" "$GREEN" "$NC" 1>&3
    show_prep_state

}
main
