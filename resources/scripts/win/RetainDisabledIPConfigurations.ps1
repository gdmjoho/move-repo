# Version: 6.1.2
# Description: This script is used to retain the disabled IP configuration on the source VM and apply the same on the target VM.
# On Source VM - Captures the NIC names and MAC address with IPv4 and IPv6 disabled and writes to a file
# On Target VM - Reads the file created at source and based on MAC address disables the IPv4 and IPv6 on the NIC
$TIMEOUT=300
function Write-Log-Global {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$message,

        [Parameter()]
        [switch]$avoidStdout = $false,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Info','Warn','Eror')]
        [string]$severity = 'Info'
    )

    $time = (Get-Date -F o)
    $lineNum = $MyInvocation.ScriptLineNumber

    $logRecord = "`r`n$time | $severity | $lineNum | $message"

    $logRecord
}

# Global Variable to store the return value
$Code = {
    $SysDrive = "C:"
    $NXBaseDir = Join-Path $SysDrive -ChildPath "Nutanix"
    $TempDir = Join-Path $NXBaseDir -ChildPath "Temp"
    $IPV4_DISABLED_CONFIG_DUMP = Join-Path $TempDir -ChildPath "ipv4-disabled-config-dump.json"
    $IPV6_DISABLED_CONFIG_DUMP = Join-Path $TempDir -ChildPath "ipv6-disabled-config-dump.json"
    $IPV4_TARGET_CONFIG_DUMP = Join-Path $TempDir -ChildPath "ipv4-target-config-dump.json"
    $IPV6_TARGET_CONFIG_DUMP = Join-Path $TempDir -ChildPath "ipv6-target-config-dump.json"
    $RETAIN_DISABLED_IP_CONFIG_LOG = Join-Path $TempDir -ChildPath "retain-disabled-ip-config-log.txt"
    $RESULT_FILE = Join-Path $TempDir -ChildPath "Retain_Disabled_IP_Configuration.out"
    $OSInfo = Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, ServicePackMajorVersion, OSArchitecture, CSName, WindowsDirectory
    # Get-NetAdapterBinding is not supported for Windows 2008, Windows 2008 R2 and Windows 7
    $SkipRetainDisabledIPConfigOSStrings = @("2008", "2008 R2", "Windows 7")
    $SkipRetainDisabledIPConfig = $null -ne ($SkipRetainDisabledIPConfigOSStrings | ? { $OSInfo.Caption -match $_ })

    function infoLog {
        param (
            [string]$message,
            [string]$logfile
        )
        Get-Date -Format "dd/MM/yyyy HH:mm:ss" >> $logfile
        Write-Output $message
        Write-Output $message *>> $logfile
    }

    function updateResultFile {
        param (
            [string]$message,
            [string]$logfile
        )
        Write-Output $message
        Write-Output $message > $logfile
    }

    function getComponentId {
        param (
            [string]$ipType
        )
        $componentId = ""
        if ($ipType -eq "ipv4") {
            $componentId = "ms_tcpip"
        }
        elseif ($ipType -eq "ipv6") {
            $componentId = "ms_tcpip6"
        }
        else {
            Write-Output "Invalid IP type"
            exit 1
        }
        return $componentId
    }

    function dumpDisabledIPConfig {
        param (
            [string]$ipType,
            [string]$configDumpFile
        )
        $componentId = getComponentId $ipType
        Write-Output "Capturing the NICs with $ipType disabled"
        infoLog "Capturing the NICs with $ipType disabled" $RETAIN_DISABLED_IP_CONFIG_LOG
        $disabledNics = Get-NetAdapterBinding -ComponentID $componentId | Where-Object { $_.Enabled -eq $false } | ForEach-Object {
            Get-NetAdapter -Name $_.Name | Select-Object -Property Name, MacAddress
        }
        if ($? -eq $false) {
            updateResultFile "Failed to dump the source $ipType configuration" $RESULT_FILE
            exit 1
        }
        if ($disabledNics -is [System.Collections.IEnumerable]) {
            $disabledNics | ConvertTo-Json -Compress | Out-File $configDumpFile
        }
        else {
            $disabledNics | ForEach-Object { @($_) } | ConvertTo-Json -Compress | Out-File $configDumpFile
        }
    }

    function captureTargetNicInfo {
        param (
            [string]$ipType,
            [string]$targetDumpFile
        )
        $componentId = getComponentId $ipType
        infoLog "Capturing the target $ipType NICs configuration" $RETAIN_DISABLED_IP_CONFIG_LOG
        Get-NetAdapterBinding -ComponentID $componentId | ForEach-Object {
            $adapter = Get-NetAdapter -Name $_.Name | Select-Object -Property MacAddress
            [PSCustomObject]@{
                Name       = $_.Name
                Enabled    = $_.Enabled
                MacAddress = $adapter.MacAddress
            }
        } | ConvertTo-Json | Out-File $targetDumpFile
        if ($? -eq $false) {
            updateResultFile "Failed to capture $ipType NICs info on target" $RESULT_FILE
            exit 1
        }
    }

    function restoreDisabledIpConfig {
        param (
            [string]$ipType,
            [string]$configDumpFile
        )
        $componentId = getComponentId $ipType
        infoLog "Reading the source $ipType disabled NICs configuration" $RETAIN_DISABLED_IP_CONFIG_LOG
        $jsonOutput = Get-Content -Path $configDumpFile | ConvertFrom-Json
        if ($? -eq $false) {
            updateResultFile "Failed to read the $configDumpFile" $RESULT_FILE
            exit 1
        }
        foreach ($nic in $jsonOutput) {
            $adapter = Get-NetAdapter | Where-Object { $_.MacAddress -eq $nic.MacAddress }
            if ($? -eq $false) {
                updateResultFile "Failed to get the adapter with MAC address: $macAddress" $RESULT_FILE
                exit 1
            }
            infoLog "Disabling $ipType on ($($adapter.Name)) adapter with MAC address: ($($nic.MacAddress))" $RETAIN_DISABLED_IP_CONFIG_LOG
            Disable-NetAdapterBinding -Name $adapter.Name -ComponentID $componentId
            if ($? -eq $false) {
                updateResultFile "Failed to disable $ipType on adapter with MAC address: $macAddress" $RESULT_FILE
                exit 1
            }
        }
    }

    # ErrorActionPreference Continue required to make redirect wmi tool output to file work without error
    $backupErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($SkipRetainDisabledIPConfig -eq $false) {
        if ($args[0] -like "source") {
            dumpDisabledIPConfig "ipv4" $IPV4_DISABLED_CONFIG_DUMP
            dumpDisabledIPConfig "ipv6" $IPV6_DISABLED_CONFIG_DUMP
            updateResultFile "success" $RESULT_FILE
        }
        elseif ($args[0] -like "target") {
            restoreDisabledIpConfig "ipv4" $IPV4_DISABLED_CONFIG_DUMP
            restoreDisabledIpConfig "ipv6" $IPV6_DISABLED_CONFIG_DUMP
            captureTargetNicInfo "ipv4" $IPV4_TARGET_CONFIG_DUMP
            captureTargetNicInfo "ipv6" $IPV6_TARGET_CONFIG_DUMP
        }
    }
    $ErrorActionPreference = $backupErrorActionPreference
}

$Job = Start-Job -ScriptBlock $Code -ArgumentList $args
Wait-Job $Job -Timeout $TIMEOUT
if ($Job.State -ne "Completed") {
    $JobOutput = $Job | Receive-Job
    Remove-Job -force $Job
    Write-Log-Global -message "Retain Disabled IP Configurations script has not completed within time limit"
    Write-Log-Global -message "Partial Job Output = '$JobOutput'"
    exit 1
} else {
    Write-Log-Global -message "Retain Disabled IP Configurations script has completed execution within time Limit"
    $JobOutput = $Job | Receive-Job
    Write-Log-Global -message "Job Output = Given below:$JobOutput"
    $Result = $JobOutput | Select-Object -Last 1
    exit $Result
}
exit 0