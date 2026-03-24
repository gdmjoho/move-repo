#! /bin/bash
# Copyright (c) 2017 Nutanix Inc. All rights reserved.
SCRIPT_VERSION="6.1.2"
set -x
CONF_DIR="/opt/Nutanix/Move/download/conf"
PREP_CONF_FILE="${CONF_DIR}/pcf.json"
BIN_DIR="/opt/Nutanix/Move/download/bin"
CONFIGEDIT_PATH="${BIN_DIR}/configedit"
destfilepath="/etc/init.d/nutanix-move"
IFACE_MAC_ADDR="/etc/mac-nic-address-map"
BACKUP_PATH="/opt/Nutanix/backup"
RHEL_IFILE="/etc/sysconfig/network-scripts/ifcfg-"
SUSE_IFILE="/etc/sysconfig/network/ifcfg-"
RHEL_NETWORK_SCRIPTS="/etc/sysconfig/network-scripts"
RHEL_NM_KEY_FILES="/etc/NetworkManager/system-connections"
SUSE_NETWORK_SCRIPTS="/etc/sysconfig/network"
NIC_FILE="/sys/class/net"
DEBIAN_IFILE="/etc/network/interfaces"
NETPLAN="/etc/netplan/*.yaml"
NETPLAN_DIRECTORY="/etc/netplan"
DHCP_NETPLAN_FILE="/etc/netplan/nutanix.yaml"
DHCP_FILE="/etc/sourcevm-dhcpfile"
PERSISTENT_RULES_FILE="/etc/udev/rules.d/70-persistent-net.rules"
BSD_IFILE="/etc/rc.conf"
SYSCTL_CONF_FILE="/etc/sysctl.conf"
CLOUD_INIT_CONFIGS_DIR="/etc/cloud/cloud.cfg.d"
NM_KEYFILE_EXT=".nmconnection"
# Valid values are FreeBSD, RHEL, RHEL_9x, Debian, SUSE. Also used in go/src/tools/_configedit/linux-network-scripts.go
WAIT_FOR_NETWORK_MANAGER=30
OS_ID=""
OS_ID_RHEL="RHEL"
OS_ID_RHEL_9X="RHEL_9x"
OS_ID_FreeBSD="FreeBSD"
OS_ID_Debian="Debian"
OS_ID_SUSE="SUSE"
LNF_IFCFG="lnf_ifcfg"
LNF_KEYFILE="lnf_keyfile"
isCustomIP=false
freeBSD=false
uname | grep -i freebsd
errorVal=$?
if [ $errorVal = 0 ]; then
    echo "FreeBSD os detected."
    freeBSD=true
    OS_ID="${OS_ID_FreeBSD}"
fi

list_interfaces() {
    if [ "$freeBSD" = true ]; then
        ifconfig -l | tr " " "\n" | grep -v "lo"
    else
        # Skip interfaces which are virtual i.e. retain IP addresses for only physical NICs
        for nic in $(ls $NIC_FILE); do if readlink -f $NIC_FILE/$nic | grep -v 'virtual/' >/dev/null; then echo $nic; fi; done
    fi
}

# Query MAC address of given device
query_hwaddr() {
    iface="$1"
    if [ "$freeBSD" = true ]; then
        ifconfig "$iface" | grep ether | cut -d" " -f2
    else
        cat /sys/class/net/$iface/address
    fi
}

backup_all_interfaces() {
    network_config_path="$1"
    mkdir -p $BACKUP_PATH
    if [ -f $network_config_path ]; then
        cp -R $network_config_path $BACKUP_PATH/
    elif [ -d $network_config_path ]; then
        cp -R $network_config_path/* $BACKUP_PATH/
    fi
    echo "RetainIP_debug : Time of backup $(date "+%FT%T")"
}

# Disable IPv6 for all interfaces
disable_ipv6() {
    echo "Disabling Ipv6 for all interfaces"
    if [ -f $SYSCTL_CONF_FILE ]; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >>$SYSCTL_CONF_FILE
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >>$SYSCTL_CONF_FILE

        # Setting PATH variable to include /sbin and /usr/sbin
        export PATH=$PATH:/sbin:/usr/sbin:/bin:/usr/bin

        # Apply the changes
        sysctl -p
        rc_sysctl=$?
        if [ $rc_sysctl != 0 ]; then
            echo "sysctl -p failed with return code $rc_sysctl."
        fi

        if [ -f /etc/redhat-release ]; then
            nmcli
            rc_nmcli=$?
            # Disabling the IPv6 from nmcli for centos/redhat as it precendence over sysctl
            # Note: This will not retain the IPv6 configuration as it does on other OS types.
            if [ $rc_nmcli = 0 ]; then
                for conn in $(nmcli -t -f NAME connection show); do
                # for some CentOS and RHEL versions, the ifcfg files are reset to the old
                # mac address causing the interface to not come up correctly. Set the mac-address as empty to avoid
                # issues.
                    nmcli connection modify "$conn" ipv6.addresses "" ipv6.gateway "" ipv6.method disabled ethernet.mac-address ""
                done
            fi
        fi
    else
        echo "Sysctl configuration file $SYSCTL_CONF_FILE not found. IPv6 will not be disabled."
    fi
}

# Add HWADRR to network scripts if not present already.
_add_hwaddr_in_ifcfg() {
    ifile="$1"
    network_scripts="$2"
    for iface in $(list_interfaces); do
        hwaddr=$(query_hwaddr $iface)
        ifcfg_script="${ifile}${iface}"
        if [[ -f ${ifcfg_script} ]] && ! grep -q "^HWADDR=" ${ifcfg_script}; then
            echo "HWADDR=${hwaddr}" >>${ifcfg_script}
        else
            # Iterate over all connections and check for matching NIC name
            for conn_name in $(ls "${network_scripts}" | grep "^ifcfg-" | sed 's/ifcfg-//g'); do
                ifcfg_script="${ifile}${conn_name}"
                has_device=$(cat $ifcfg_script | grep DEVICE | grep ${iface} | wc -l)
                if [[ ${has_device} -eq 0 ]]; then
                    continue
                fi
                if [[ -f ${ifcfg_script} ]] && ! grep -q "^HWADDR=" ${ifcfg_script}; then
                    echo "HWADDR=${hwaddr}" >>${ifcfg_script}
                fi
                break
            done
        fi
    done
}

# add hwaddr in nm_keyfiles if not already present
_add_hwaddr_in_nm_keyfiles() {
    nm_keyfiles_dir="$1"
    for iface in $(list_interfaces); do
        hwaddr=$(query_hwaddr $iface)
        # check filename by convention i.e. <ifname>.nmconnection
        # if not present then check interface name in all nm-keyfiles
        nm_keyfile="${nm_keyfiles_dir}/${iface}${NM_KEYFILE_EXT}"
        if [[ -f ${nm_keyfile} ]] && ! grep -q "^mac-address=" ${nm_keyfile}; then
        # check if [ethernet] section already exists and add hwaddr below it
            if grep -q "ethernet]$" ${nm_keyfile}; then
                sed -i "/ethernet\]$/a mac-address=${hwaddr}" ${nm_keyfile}
            else
                echo -e "\n[ethernet]\nmac-address=$hwaddr" >> ${nm_keyfile}
            fi
        else
            # Iterate over all connections and check for matching NIC name
            for conn_file in $(ls "${nm_keyfiles_dir}" | grep "$NM_KEYFILE_EXT$"); do
                nm_keyfile="${nm_keyfiles_dir}/${conn_file}"
                has_ifname=$(cat $nm_keyfile | grep interface-name | grep ${iface} | wc -l)
                if [[ ${has_ifname} -eq 0 ]]; then
                    continue
                fi
                if [[ -f ${nm_keyfile} ]] && ! grep -q "^mac-address=" ${nm_keyfile}; then
                # add mac-address in ethernet section if already present
                # else create ethernet section in keyfile
                    if grep -q "ethernet]$" ${nm_keyfile}; then
                        sed -i "/ethernet\]$/a mac-address=${hwaddr}" ${nm_keyfile}
                    else
                        echo -e "\n[ethernet]\nmac-address=$hwaddr" >> ${nm_keyfile}
                    fi
                fi
                break
            done
        fi
    done
}

# Add HWADRR to network scripts if not present already. This is essential for
# interface names to be retained after migration.
add_hwaddr_in_nw_scripts_and_nm_keyfiles() {
    if [ -f /etc/redhat-release ]; then
    # Add hwaddr for both ifcfg and nm_keyfiles
    # from RHEL 9 onwards, by default nm-keyfiles are used but ifcfg files
    # can still be used.
        _add_hwaddr_in_ifcfg $RHEL_IFILE $RHEL_NETWORK_SCRIPTS
        _add_hwaddr_in_nm_keyfiles $RHEL_NM_KEY_FILES
    elif [ -f /etc/SuSE-release ]; then
        _add_hwaddr_in_ifcfg $SUSE_IFILE $SUSE_NETWORK_SCRIPTS
    fi
}

correct_iface_mac_addr() {
    echo "RetainIP_debug : Entered correct_iface_mac_addr"

    for iface in $(list_interfaces); do
        # Get the Hardware address of interface.
        hwaddr=$(query_hwaddr $iface)
        # Check if it exists in $IFACE_MAC_ADDR
        oldiface=$(get_old_iface_by_hwaddr "$hwaddr" "$iface")
        echo "RetainIP_debug : correct_iface_mac_addr HW address $hwaddr"
    done
    num_interfaces=$(list_interfaces | wc -w)

    if [ ${num_interfaces} -gt 0 ]; then
        add_hwaddr_in_nw_scripts_and_nm_keyfiles
    fi
}

get_old_iface_by_hwaddr() {
    hwaddr_filter="$1"
    iface_filter="$2"
    old_iface=""
    for line in $(cat "$IFACE_MAC_ADDR"); do
        hwaddr=$(echo "$line" | cut -d"," -f 1)
        if [ "$hwaddr" = "$hwaddr_filter" ]; then
            iface=$(echo $line | cut -d"," -f 2)
            old_iface="$iface"
            break
        fi
    done

    if [ ! -z $old_iface ]; then
        if [ ! -z $iface_filter ]; then
            sed -i -e "s/$old_iface/$iface_filter/g" "$IFACE_MAC_ADDR"
        else
            sed -i -e '/'"$old_iface"'/d' "$IFACE_MAC_ADDR"
        fi
    fi
    echo "$old_iface"
}

get_old_iface_in_order() {
    line=$(head -n 1 "$IFACE_MAC_ADDR")
    old_iface=$(echo "$line" | cut -d"," -f 2)
    if [ ! -z $old_iface ]; then
        sed -i -e '/'"$old_iface"'/d' "$IFACE_MAC_ADDR"
    fi
    echo "$old_iface"
}

replace_correct_ifcfg() {
    echo "RetainIP_debug : Entered replace_correct_ifcfg with parameters $1 $2 $3 $4"
    network_script_ifile="$1"
    network_scripts_dir="$2"
    iface="$3"
    hwaddr="$4"
    # Iterate through interface configuration files
    for oldiface in $(ls "$network_scripts_dir" | grep "^ifcfg-" | sed 's/ifcfg-//g' | grep -v "^lo$"); do
        old_config="$network_script_ifile$oldiface"
        has_device=$(cat $old_config | grep DEVICE | grep $iface | wc -l)
        if [[ ${has_device} -eq 0 && "$oldiface" != "$iface" ]]; then
            continue
        fi

        # Replace HW address
        sed -i "s/^HWADDR=.*/HWADDR=\"$hwaddr\"/" $old_config

        # Add interface to udev rules
        echo "Interface name $iface mapped to MAC Address $hwaddr"
        udev_rule="SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$hwaddr\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"$iface\""
        has_udev_rule=$(cat $PERSISTENT_RULES_FILE | grep -Fx "$udev_rule" | wc -l)
        if [[ ${has_udev_rule} -eq 0 ]]; then
            echo "$udev_rule" >> $PERSISTENT_RULES_FILE
        fi
    done
    return 0
}

replace_correct_nm_keyfile() {
    # Iterate through interface config files
    echo "RetainIP_debug : Entered replace_correct_nm_keyfile with parameters $1 $2 $3"
    nm_keyfiles_dir="$1"
    iface="$2"
    hwaddr="$3"
    for conn_file in $(ls "$nm_keyfiles_dir" | grep "$NM_KEYFILE_EXT$"); do
        old_nm_keyfile="$nm_keyfiles_dir/$conn_file"
        has_ifname=$(cat $old_nm_keyfile | grep interface-name | grep $iface | wc -l)
        if [[ ${has_ifname} -eq 0 && "${conn_file}%$NM_KEYFILE_EXT" != "$iface" ]]; then
            continue
        fi

        # Replace hwaddr in key file
        sed -i "s/^mac-address=.*/mac-address=\"$hwaddr\"/" $old_nm_keyfile

        # Add interface to udev rules
        echo "Interface name $iface mapped to MAC Address $hwaddr"
        udev_rule="SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$hwaddr\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"$iface\""
        has_udev_rule=$(cat $PERSISTENT_RULES_FILE | grep -Fx "$udev_rule" | wc -l)
        if [[ ${has_udev_rule} -eq 0 ]]; then
            echo "$udev_rule" >> $PERSISTENT_RULES_FILE
        fi
    done
    return 0
}

create_debian_dhcp_config() {
    if [ -f "$DHCP_FILE" ]; then
        mkdir -p $BACKUP_PATH
        num_netplan_config=$(ls $NETPLAN | wc -w)
        mkdir -p $CLOUD_INIT_CONFIGS_DIR
        echo "network: {config: disabled}" >$CLOUD_INIT_CONFIGS_DIR/99-disable-network-config.cfg
        if [ ${num_netplan_config} -gt 0 ]; then
            version=""
            renderer=""
            for yaml_file in $NETPLAN; do
                if [ -z $version ]; then
                    version=$(sed -n '/version:/p' $yaml_file | sed "s/^[[:space:]]*//")
                fi
                if [ -z $renderer ]; then
                    renderer=$(sed -n '/renderer:/p' $yaml_file | sed "s/^[[:space:]]*//")
                fi
                mv $yaml_file $BACKUP_PATH
            done
            echo "Creating new netplan config $DHCP_NETPLAN_FILE"
            echo "network:" >$DHCP_NETPLAN_FILE
            if [ ! -z "$version" ]; then
                echo "  $version" >>$DHCP_NETPLAN_FILE
            else
                echo "  version: 2" >>$DHCP_NETPLAN_FILE
            fi
            if [ ! -z $renderer ]; then
                echo "  $renderer" >>$DHCP_NETPLAN_FILE
            fi
            echo "  ethernets:" >>$DHCP_NETPLAN_FILE
        else
            mv $DEBIAN_IFILE $BACKUP_PATH
            echo "Rewriting $DEBIAN_IFILE"
            echo "auto lo" >$DEBIAN_IFILE
            echo "iface lo inet loopback" >>$DEBIAN_IFILE
        fi
    fi

}

add_interface_to_debian_dhcp_config() {
    iface="$1"
    if [ -f "$DHCP_FILE" ]; then
        if [ -f $DHCP_NETPLAN_FILE ]; then
            echo "Added Interface name $iface to new netplan config"
            echo "    $iface:" >>$DHCP_NETPLAN_FILE
            echo "      dhcp4: true" >>$DHCP_NETPLAN_FILE
        else
            echo "Added Interface name $iface to new interfaces config"
            echo "auto $iface" >>$DEBIAN_IFILE
            echo "iface $iface inet dhcp" >>$DEBIAN_IFILE
        fi
    fi

}
# Correct interface name in /etc/network/interfaces file
correct_debian_interfaces() {
    unassigned_ifaces=""

    num_netplan_config=$(ls $NETPLAN | wc -w)
    create_debian_dhcp_config
    for iface in $(list_interfaces); do
        hwaddr=$(query_hwaddr $iface)
        oldiface=$(get_old_iface_by_hwaddr "$hwaddr")
        if [ -z "$oldiface" ]; then
            if [ ! -z "$unassigned_ifaces" ]; then
                unassigned_ifaces=$(echo "$unassigned_ifaces $iface")
            else
                unassigned_ifaces="$iface"
            fi
        else
            echo "Interface name $oldiface mapped to MAC Address $hwaddr"
            echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$hwaddr\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"$oldiface\"" >>$PERSISTENT_RULES_FILE
            add_interface_to_debian_dhcp_config $oldiface
        fi
    done

    for uniface in $(echo "$unassigned_ifaces"); do
        hwaddr=$(query_hwaddr $uniface)
        oldiface=$(get_old_iface_in_order)
        if [ ! -z "$oldiface" ]; then
            echo "Interface name $oldiface mapped to MAC Address $hwaddr"
            echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$hwaddr\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"$oldiface\"" >>$PERSISTENT_RULES_FILE
            add_interface_to_debian_dhcp_config $oldiface
        fi
    done
    if [ -d "/etc/systemd" ]; then
        # ENG-417738: Race condition between systemd-networkd and udevd causes issue in getting IP. Add network start delay
        mkdir -p /etc/systemd/system/systemd-networkd.service.d
        echo -e "[Service]\nExecStartPre=/bin/sleep 5" >/etc/systemd/system/systemd-networkd.service.d/after-udev.conf
    fi
    if [[ ${num_netplan_config} -gt 0 ]]; then
        # 'dhcp-identifier: mac' ties the network connection to mac address
        # which might be problematic since MACs are not necessarily retained on target
        for yaml_file in $NETPLAN; do
            sed -i '/dhcp-identifier: mac/d' $yaml_file
        done
        netplan apply
    fi

    if [ -f "$DHCP_FILE" ]; then
        # disable ipv6 on all interfaces if DHCP option is selected
        disable_ipv6
    fi
}
setdhcp_ifcfg() {
    echo "RetainIP_debug : Entered setdhcp_ifcfg with $1 $2"
    network_script_ifile="$1"
    network_scripts_dir="$2"
    mkdir -p $BACKUP_PATH
    for iface in $(ls "$network_scripts_dir" | grep "^ifcfg-" | sed 's/ifcfg-//g' | grep -v "^lo$"); do
        config="$network_script_ifile$iface"
        cp $config $BACKUP_PATH/bak.ifcfg-$iface
        if [ -f "$DHCP_FILE" ]; then
            sed -i 's/^BOOTPROTO.*/BOOTPROTO=dhcp/g' "$config"
            sed -i '/^IPADDR/d;/^PREFIX/d;/^NETMASK/d;/^DNS/d;/^GATEWAY/d' "$config"
        fi
    done

    # In certain CentOS versions, we noticed that after migrating to the target,
    # executing any nmcli command to modify the interface the resets the ifcfg files
    # to the previous source configurations. To prevent this, we are also configuring
    # IPv4 DHCP settings using nmcli.
    if [ -f "$DHCP_FILE" ]; then
        nmcli
        rc_nmcli=$?
        if [ $rc_nmcli = 0 ]; then
            for conn in $(nmcli -t -f NAME connection show); do
                # for some CentOS and RHEL versions, the ifcfg files are reset to the old
                # mac address causing the interface to not come up correctly. Set the mac-address as empty
                # to avoid issues.
                nmcli connection modify "$conn" ipv4.addresses "" ipv4.gateway "" ipv4.method auto ethernet.mac-address ""
            done
        fi
    fi
}

setdhcp_nm_keyfiles() {
    echo "RetainIP_debug : Entered setdhcp_nm_keyfiles with $1"
    nm_keyfiles_dir="$1"
    mkdir -p $BACKUP_PATH
    for conn_file in $(ls $nm_keyfiles_dir | grep "$NM_KEYFILE_EXT$"); do
        nm_keyfile="$nm_keyfiles_dir/$conn_file"
        cp $nm_keyfile $BACKUP_PATH/$conn_file.bak
        if [ -f "$DHCP_FILE" ]; then
        # delete static ip configuration from nm_keyfile config
            sed -i '/^\[ipv4\]$/,/^$/{/address/d;}'  ${nm_keyfile}
            sed -i '/^\[ipv4\]$/,/^$/{/dns/d;}'  ${nm_keyfile}
            sed -i '/^\[ipv4\]$/,/^$/{/gateway/d;}'  ${nm_keyfile}
            # set ipv4 address method from manual to auto
            sed -i '/^\[ipv4\]$/,/^$/{s/method=manual/method=auto/g;}'  ${nm_keyfile}
        fi
    done
}

is_custom_ips_flow() {
  if [ -f "${PREP_CONF_FILE}" ]; then
    isCustomIP=true
  fi
}

_call_configedit_all_ifcfg_files(){
  network_script_ifile_pathprefix="$1"
  network_scripts_dir="$2"
  ce_log_level="$3"

  for conn_name in $(ls "$network_scripts_dir" | grep "^ifcfg-" | sed 's/ifcfg-//g' | grep -v "^lo$"); do
    cfg_file="${network_script_ifile_pathprefix}${conn_name}"
    echo "CustomIP_debug : configedit on ifcfg ${cfg_file}"
    ${CONFIGEDIT_PATH} -type ${LNF_IFCFG} -in "${cfg_file}" -setFromMeta "${PREP_CONF_FILE}" -debug "${ce_log_level}" "OS_ID=${OS_ID}"
    ret=$?
    echo "CustomIP_debug : Completed configedit on ${cfg_file}, with return code:[${ret}]"
  done
}

_call_configedit_all_nm_files(){
  nm_keyfiles_dir="$1"
  ce_log_level="$2"

  for conn_file in $(ls "${nm_keyfiles_dir}" | grep "$NM_KEYFILE_EXT$"); do
    nm_keyfile="${nm_keyfiles_dir}/${conn_file}"
    has_ifname=$(cat $nm_keyfile | grep "interface-name" | wc -l)
    if [[ ${has_ifname} -eq 0 ]]; then
        continue
    fi
    echo "CustomIP_debug : configedit on keyfile ${nm_keyfile}"
    ${CONFIGEDIT_PATH} -type ${LNF_KEYFILE} -in "${nm_keyfile}" -setFromMeta "${PREP_CONF_FILE}" -debug "${ce_log_level}" "OS_ID=${OS_ID}"
    ret=$?
    echo "CustomIP_debug : Completed configedit on ${nm_keyfile}, with return code:[${ret}]"
  done
}

_call_configedit_print_version(){
   ${CONFIGEDIT_PATH} -version
}

customize_ips_if_needed(){
  is_custom_ips_flow
  if [ ${isCustomIP} = false ]; then
    return
  fi

  echo "CustomIP_debug : Customizing IP"
  # config edit log levels
  ce_verbose_log=5
  ce_basic_log=2
  #
  network_script_ifile_pathprefix="$1"
  network_scripts_dir="$2"
  nm_keyfiles_dir="$3"

  _call_configedit_print_version

  if [ "${OS_ID}" = "${OS_ID_RHEL}" ]; then
    _call_configedit_all_ifcfg_files "${network_script_ifile_pathprefix}" "${network_scripts_dir}" "${ce_verbose_log}"
    _call_configedit_all_nm_files "${nm_keyfiles_dir}" "${ce_verbose_log}"
  elif [ "${OS_ID}" = "${OS_ID_RHEL_9X}" ]; then
    _call_configedit_all_nm_files "${nm_keyfiles_dir}" "${ce_verbose_log}"
    _call_configedit_all_ifcfg_files "${network_script_ifile_pathprefix}" "${network_scripts_dir}" "${ce_verbose_log}"
  fi

  echo "CustomIP_debug : Customizing IP completed"
}

correct_ifcfg_and_nm_keyfiles() {
    unassigned_ifaces=""
    echo "RetainIP_debug : Entered correct_ifcfg_and_nm_keyfiles with $1 $2 $3"
    network_script_ifile="$1"
    network_scripts_dir="$2"
    nm_keyfiles_dir="$3"
    setdhcp_ifcfg $network_script_ifile $network_scripts_dir
    if [[ ! -z "$nm_keyfiles_dir" ]]; then
        setdhcp_nm_keyfiles $nm_keyfiles_dir
    fi
    for iface in $(list_interfaces); do
        # Get the Hardware address of interface.
        hwaddr=$(query_hwaddr $iface)
        # Check if it exists in $IFACE_MAC_ADDR
        oldiface=$(get_old_iface_by_hwaddr "$hwaddr")
        echo "RetainIP_debug : correct_ifcfg_and_nm_keyfiles HW address $hwaddr"
        # Does not exist - new NIC - add to unassigned interface
        if [ -z "$oldiface" ]; then
            if [ ! -z "$unassigned_ifaces" ]; then
                unassigned_ifaces=$(echo "$unassigned_ifaces $iface")
            else
                unassigned_ifaces="$iface"
            fi
        # Mac exists in $IFACE_MAC_ADDR
        else
            # Only if new and old interface names are not the same,
            # we replace the configuration.
            echo "RetainIP_debug: Case 1: correct_ifcfg_and_nm_keyfiles old $oldiface new $iface"
            if [ "$oldiface" != "$iface" ]; then
                # Case 1: Hardware match, name mismatch
                # check for nm_keyfiles only if directory for nm_keyfiles is
                # provided
                if [[ ! -z "$nm_keyfiles_dir" ]]; then
                    replace_correct_nm_keyfile "$nm_keyfiles_dir" "$oldiface" "$hwaddr"
                fi
                replace_correct_ifcfg "$network_script_ifile" "$network_scripts_dir" "$oldiface" "$hwaddr"
            else
                # Case 2: Hardware and name match
                echo "Case 2: Interface name $oldiface mapped to MAC Address $hwaddr"
                udev_rule="SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$hwaddr\", ATTR{dev_id}==\"0x0\", ATTR{type}==\"1\", NAME=\"$oldiface\""
                has_udev_rule=$(cat $PERSISTENT_RULES_FILE | grep -Fx "$udev_rule" | wc -l)
                if [[ ${has_udev_rule} -eq 0 ]]; then
                    echo "$udev_rule" >> $PERSISTENT_RULES_FILE
                fi
            fi
        fi
    done

    for uniface in $(echo "$unassigned_ifaces"); do
        hwaddr=$(query_hwaddr $uniface)
        oldiface=$(get_old_iface_in_order)
        if [ ! -z "$oldiface" ]; then
            # Case 3: Hardware mismatch
            echo "RetainIP debug: Case 3: correct_ifcfg_and_nm_keyfiles old $oldiface new $uniface"
            # check for both nm-keyfile and ifcfg file
            if [[ ! -z "$nm_keyfiles_dir" ]]; then
                replace_correct_nm_keyfile "$nm_keyfiles_dir" "$oldiface" "$hwaddr"
            fi
            replace_correct_ifcfg "$network_script_ifile" "$network_scripts_dir" "$oldiface" "$hwaddr"
        fi
    done

    customize_ips_if_needed "${network_script_ifile}" "${network_scripts_dir}" "${nm_keyfiles_dir}"

    if [ -f "$DHCP_FILE" ]; then
        # disable ipv6 on all interfaces if DHCP option is selected
        disable_ipv6
    fi
}
replace_iface_freebsd() {
    old_interface_name="$1"
    new_interface_name="$2"
    freebsd_config="$3"
    if [ -f "$DHCP_FILE" ]; then
        sed -i -e '/'"ifconfig_$old_interface_name"'/d' "$freebsd_config"
        sed -i -e '/'"defaultrouter"'/d' "$freebsd_config"
        echo "ifconfig_$new_interface_name=\"DHCP\"" >>$freebsd_config
    else
        sed -i -e 's/'"$old_interface_name"'/'"$new_interface_name"'/g' "$freebsd_config"
    fi
}
correct_freebsd_ifcfg() {
    unassigned_ifaces=""
    config="$BSD_IFILE"
    # backup old config
    cp $config $config.bak
    for iface in $(list_interfaces); do
        hwaddr=$(query_hwaddr $iface)
        oldiface=$(get_old_iface_by_hwaddr "$hwaddr")
        if [ -z "$oldiface" ]; then
            if [ ! -z $unassigned_ifaces ]; then
                unassigned_ifaces=$(echo "$unassigned_ifaces $iface")
            else
                unassigned_ifaces="$iface"
            fi
        else
            replace_iface_freebsd $oldiface $iface $config
        fi
    done

    for uniface in $(echo "$unassigned_ifaces"); do
        oldiface=$(get_old_iface_in_order)
        if [ ! -z "$oldiface" ]; then
            replace_iface_freebsd $oldiface $uniface $config
        fi
    done

    if [ -f "$DHCP_FILE" ]; then
        # disable ipv6 on all interfaces if DHCP option is selected
        disable_ipv6
    fi
}

is_rhel_9x(){
  grep -qi "release 9" /etc/redhat-release
  return $?
}

connect_network_interfaces() {
    if [ "$freeBSD" = true ]; then
        ifconfig -a
        for iface in $(list_interfaces); do
            ifconfig "$iface" up
        done
    elif [ -f /etc/redhat-release ]; then
        nmcli
        rc_nmcli=$?
        if [ $rc_nmcli = 0 ]; then
            nmcli device status
            for iface in $(list_interfaces); do
                nmcli device connect "$iface"
            done
        elif [ $rc_nmcli = 127 ]; then
            ifconfig -a
            for iface in $(list_interfaces); do
                ifup "$iface"
            done
        else
            return 1
        fi
    elif [ -f /etc/debian_version ]; then
        nmcli
        rc_nmcli=$?
        ifup --help
        rc_ifup=$?
        if [ $rc_nmcli = 0 ]; then
            nmcli device status
            for iface in $(list_interfaces); do
                nmcli device connect "$iface"
            done
        elif [[  $rc_nmcli = 127 && $rc_ifup = 0 ]]; then
            ifconfig -a
            for iface in $(list_interfaces); do
                ifup "$iface"
            done
        else
            for iface in $(list_interfaces); do
                ip link set "$iface" up
            done
        fi
    elif [ -f /etc/SuSE-release ]; then
        nmcli
        rc_nmcli=$?
        if [ $rc_nmcli = 0 ]; then
            nmcli device status
            for iface in $(list_interfaces); do
                nmcli device connect "$iface"
            done
        elif [ $rc_nmcli = 127 ]; then
            for iface in $(list_interfaces); do
                ifup "$iface"
            done
        else
            return 1
        fi
    elif [ -f /etc/os-release ]; then
        isSuSe=$(grep -ie "suse" /etc/os-release)
        if [ ${#isSuSe} -gt 0 ]; then
            nmcli
            rc_nmcli=$?
            if [ $rc_nmcli = 0 ]; then
                nmcli device status
                for iface in $(list_interfaces); do
                    nmcli device connect "$iface"
                done
            elif [ $rc_nmcli = 127 ]; then
                for iface in $(list_interfaces); do
                    ifup "$iface"
                done
            else
                return 1
            fi
        fi
    fi
    return $?
}

do_source() {
    echo -e "\n*** Running IP retention script on source VM ***\n"

    # This is to make sure in case source vm is powered on then correct Interface file is maintained in address map
    if [ -f "$destfilepath" ]; then
        if [ "$freeBSD" = false ]; then
            echo "RetainIP_debug : $destfilepath exists, so going to correct interfaces!"
            correct_iface_mac_addr
        fi
        echo "RetainIP_debug : $destfilepath already exist, exiting from script!"
        exit 0
    fi

    echo "RetainIP_debug : $destfilepath does not exist. Running retainIP script on source."

    echo "RetainIP_debug : Adding Hardware address to network scripts"
    num_interfaces=$(list_interfaces | wc -w)
    # Add HWADDR to ifcfg scripts and nm-keyfiles
    if [ ${num_interfaces} -gt 0 ]; then
        add_hwaddr_in_nw_scripts_and_nm_keyfiles
    fi

    # Remove if $IFACE_MAC_ADDR exists
    rm -f $IFACE_MAC_ADDR

    rm -f ${DHCP_FILE}

    echo "RetainIP_debug : Dumping Hardware address and interface name to $IFACE_MAC_ADDR"
    # This dumps hardware address with nic information
    for iface in $(list_interfaces); do
        hwaddr=$(query_hwaddr $iface)
        echo "$hwaddr","$iface" >>"$IFACE_MAC_ADDR"
    done

    echo "RetainIP_debug : Backing up interface configuration"
    # Back up all interface configuration files
    if [ "$freeBSD" = true ]; then
        OS_ID="${OS_ID_FreeBSD}"
        backup_all_interfaces $BSD_IFILE
    elif [ -f /etc/redhat-release ]; then
      is_rhel_9x
      if [ "$?" -eq 0 ]; then
        OS_ID="${OS_ID_RHEL_9X}"
      else
        OS_ID="${OS_ID_RHEL}"
      fi
    # Backup both ifcfg and network manager keyfiles for RHEL
    # From RHEL 9, key files are used by default but ifcfg files can still
    # be used.
        backup_all_interfaces $RHEL_NETWORK_SCRIPTS
        backup_all_interfaces $RHEL_NM_KEY_FILES
    elif [ -f /etc/debian_version ]; then
        OS_ID="${OS_ID_Debian}"
        backup_all_interfaces $NETPLAN_DIRECTORY
        backup_all_interfaces $DEBIAN_IFILE
    elif [ -f /etc/SuSE-release ]; then
        OS_ID="${OS_ID_SUSE}"
        backup_all_interfaces $SUSE_NETWORK_SCRIPTS
    fi

    # More changes might be required to support older linux versions using
    # persistent udev rules to retain names. Currently we remove this file
    # prior to migration.
    # Make the 70-persistent-net.rules file inactive (udev works only with .rules extension)
    #Execute this only one time
    if [ -f /etc/udev/rules.d/70-persistent-net.rules -a ! -f /etc/udev/rules.d/70-persistent-net.rules.nxbak ]; then
        cp -f /etc/udev/rules.d/70-persistent-net.rules /etc/udev/rules.d/70-persistent-net.rules.nxbak
    fi

}

do_target() {
    echo -e "\n*** Running IP retention script on target VM ***\n"

    rm -f ${PERSISTENT_RULES_FILE}

    # Handle IPs set using ifcfg/interfaces file
    if [ "$freeBSD" = true ]; then
        OS_ID="${OS_ID_FreeBSD}"
        correct_freebsd_ifcfg
        rc=$?
    elif [ -f /etc/redhat-release ]; then
        # for RHEL 9, both ifcfg and nm-keyfiles need to be checked
        is_rhel_9x
        if [ "$?" -eq 0 ]; then
            OS_ID="${OS_ID_RHEL_9X}"
            correct_ifcfg_and_nm_keyfiles $RHEL_IFILE $RHEL_NETWORK_SCRIPTS $RHEL_NM_KEY_FILES
            rc=$?
        else
            OS_ID="${OS_ID_RHEL}"
            correct_ifcfg_and_nm_keyfiles $RHEL_IFILE $RHEL_NETWORK_SCRIPTS
            rc=$?
        fi
    elif [ -f /etc/debian_version ]; then
        OS_ID="${OS_ID_Debian}"
        correct_debian_interfaces
        rc=$?
    elif [ -f /etc/SuSE-release ]; then
        OS_ID="${OS_ID_SUSE}"
        correct_ifcfg_and_nm_keyfiles $SUSE_IFILE $SUSE_NETWORK_SCRIPTS
        rc=$?
    fi
    retry=0
    maxretry=3
    while [ $retry -lt $maxretry ]
    do
        connect_network_interfaces
        if [ $? = 0 ]; then
            break
        else
            retry=$((retry+1))
            sleep $WAIT_FOR_NETWORK_MANAGER
        fi
    done
    return $rc
}

if [ "$1" = "source" ]; then
    do_source
elif [ "$1" = "target" ]; then
    do_target
fi
