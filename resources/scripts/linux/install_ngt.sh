#! /bin/bash
# Copyright (c) 2024 Nutanix Inc. All rights reserved.
set -x
SCRIPT_VERSION="6.1.2"

sourcefilepath="$0"
WAIT_FOR_NGT_SERVICE=45
WAIT_FOR_NGT_CDROM=5
TIMEOUT_FOR_NGT_CDROM=60
MNT_NGT_CDROM=0
INSTALL_NGT_SCRIPT=0
FOUND_PYTHON=0
WAIT_FOR_INSTALL_NGT=10

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

check_ngt_status() {
	ngtstatus=$(service ngt_guest_agent status 2>&1)
	if [ $? = 0 ] && [[ "$ngtstatus" == *"running"* ]]; then
		echo "NGT is installed successfully on the vm"
		exit 0
	fi

	ngtstatus=$(systemctl status ngt_guest_agent.service 2>&1)
	if [ $? = 0 ] && [[ "$ngtstatus" == *"active (running)"* ]]; then
		echo "NGT is installed successfully on the vm"
		exit 0
	fi
}

mount_cdrom() {
	end=$((SECONDS+TIMEOUT_FOR_NGT_CDROM))

	while [ $SECONDS -lt $end ]
	do
		output=$(lsblk -f | grep 'NUTANIX_TOOLS'|awk '{print$1}')
		if [ "$output" = "" ]; then
			output=$(blkid -L NUTANIX_TOOLS)
		fi
		echo "Nutanix Tools CD is present/inserted at : $output"
		if [ "$output" = "" ]; then
			echo "Nutanix Guest Tools CD is not yet present/inserted"
			sleep $WAIT_FOR_NGT_CDROM
		else
			echo "Mounting Nutanix Guest Tools CD to /mnt"
			mkdir -p /mnt
			if [[ "$output" == *"/dev"* ]]; then
				mount "$output" /mnt
			else
				mount /dev/"$output" /mnt
			fi
			sleep $WAIT_FOR_NGT_CDROM
			MNT_NGT_CDROM=1
			break
		fi
	done

	if [ $MNT_NGT_CDROM = 0 ]; then
		echo "Nutanix Guest Tools CD-ROM is not mounted/present, exiting the install_ngt script"
		exit 1
	fi
}

install_ngt() {
	retry=0
	maxretry=3

	while [ $retry -lt $maxretry ]
	do
		if [ -f "/mnt/installer/linux/install_ngt.sh" ]; then
			sh /mnt/installer/linux/install_ngt.sh --operation=install 2>&1
			if [ $? != 0 ]; then
				echo "script execution failed using shell"
			else
				echo "script execution completed successfully using shell"
				INSTALL_NGT_SCRIPT=1
				break
			fi
		fi
		if [ -f "/mnt/installer/linux/install_ngt.py" ]; then
			which python2
			if [ $? = 0 ]; then
				FOUND_PYTHON=1
				python2 /mnt/installer/linux/install_ngt.py --operation install 2>&1
				if [ $? != 0 ]; then
					echo "script execution failed using python2"
				else
					echo "script execution completed successfully using python2"
					INSTALL_NGT_SCRIPT=1
					break
				fi
			fi

			which python3
			if [ $? = 0 ]; then
				FOUND_PYTHON=1
				python3 /mnt/installer/linux/install_ngt.py --operation install 2>&1
				if [ $? != 0 ]; then
					echo "script execution failed using python3"
				else
					echo "script execution completed successfully using python3"
					INSTALL_NGT_SCRIPT=1
					break
				fi
			fi

			which python
			if [ $? = 0 ]; then
				FOUND_PYTHON=1
				python /mnt/installer/linux/install_ngt.py --operation install 2>&1
				if [ $? != 0 ]; then
					echo "script execution failed using python"
				else
					echo "script execution completed successfully using python"
					INSTALL_NGT_SCRIPT=1
					break
				fi
			fi

			if [ $FOUND_PYTHON = 0 ]; then
				echo "No Python package found on the VM"
			fi
		fi
		retry=$((retry+1))
		sleep $WAIT_FOR_INSTALL_NGT
	done

	if [ $INSTALL_NGT_SCRIPT = 0 ]; then
		echo "Unable to Install NGT on the VM"
		exit 1
	fi
}

main() {
	# If NGT is already running no need to proceed further
	check_ngt_status
	# Mount NGT CD-ROM
	mount_cdrom
	# Install NGT on the vm using python or shell script
	install_ngt
	# Sleep for some time to make sure that the service is up and running
	sleep $WAIT_FOR_NGT_SERVICE

	check_ngt_status

	exit 1
}
main
