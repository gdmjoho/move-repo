#! /bin/bash
# Copyright (c) 2017 Nutanix Inc. All rights reserved.
SCRIPT_VERSION="6.1.2"

date

REDHAT_CHECK_PKG="rpm -q"
REDHAT_UNINSTALL_PKG="yum -y remove"
DEBIAN_CHECK_PKG="dpkg -s"
DEBIAN_UNINSTALL_PKG="apt-get -y remove"
SUSE_CHECK_PKG="rpm -q"
SUSE_UNINSTALL_PKG="zypper -n remove"
FREEBSD_CHECK_PKG="pkg info"
FREEBSD_UNINSTALL_PKG="pkg delete -y"

freeBSD=false
uname | grep -i freebsd
errorVal=$?
if [ $errorVal = 0 ]; then
    echo "FreeBSD os detected."
    freeBSD=true
    export PATH="$PATH:/usr/local/bin"
fi

uninstall_open_vm_tools() {
    chk_pkg_cmd=$1
    uninstall_pkg_cmd=$2

    if $chk_pkg_cmd open-vm-tools; then
        $uninstall_pkg_cmd open-vm-tools
        if [ $? -eq 0 ]; then
            echo "UninstallVMwareTools_debug : Successfully uninstalled open-vm-tools"
        else
            echo "UninstallVMwareTools_debug : Failed to uninstall open-vm-tools"
        fi
    fi
}

echo -e "\n*** Running Uninstall VMware Tools script on target VM ***\n"

# Uninstall VMware tools
if command -v vmware-toolbox-cmd; then
    echo "UninstallVMwareTools_debug : VMware tools installation found. Uninstalling VMware tools..."
    if command -v vmware-uninstall-tools.pl; then
        vmware-uninstall-tools.pl
        if [ $? -eq 0 ]; then
            echo "UninstallVMwareTools_debug : Successfully uninstalled VMware Tools"
        else
            echo "UninstallVMwareTools_debug : Failed to uninstall VMware Tools"
        fi
    fi

    # Uninstall open-vm-tools
    if [ "$freeBSD" = true ]; then
        uninstall_open_vm_tools "$FREEBSD_CHECK_PKG" "$FREEBSD_UNINSTALL_PKG"
    elif [ -f /etc/redhat-release ]; then
        uninstall_open_vm_tools "$REDHAT_CHECK_PKG" "$REDHAT_UNINSTALL_PKG"
    elif [ -f /etc/debian_version ]; then
        uninstall_open_vm_tools "$DEBIAN_CHECK_PKG" "$DEBIAN_UNINSTALL_PKG"
    elif [ -f /etc/SuSE-release ]; then
        uninstall_open_vm_tools "$SUSE_CHECK_PKG" "$SUSE_UNINSTALL_PKG"
    fi
else
    echo "UninstallVMwareTools_debug : VMware tools not installed."
fi

exit 0
