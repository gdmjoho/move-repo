# Version: 6.1.2
# Description: This script will disable IPv6 on all the NICs on target VM
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
    $DISABLE_IPV6_CONFIG_LOG = Join-Path $TempDir -ChildPath "disable-ipv6-log.txt"
    $RESULT_FILE = Join-Path $TempDir -ChildPath "Disable_IPv6.out"
    $OSInfo = Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, ServicePackMajorVersion, OSArchitecture, CSName, WindowsDirectory
    # Get-NetAdapterBinding is not supported for Windows 2008, Windows 2008 R2 and Windows 7
    $OSStrings = @("2008", "2008 R2", "Windows 7")
    $DisableFromRegistry = $null -ne ($OSStrings | ? { $OSInfo.Caption -match $_ })

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

    # ErrorActionPreference Continue required to make redirect wmi tool output to file work without error
    $backupErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($DisableFromRegistry -eq $true) {
        infoLog "Disabling IPv6 on all NICs from registry for $OSInfo.Caption" $DISABLE_IPV6_CONFIG_LOG
        # This change will not appear in Network Adapter Settings as we are diabling from registry
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\"
        New-ItemProperty -Path $regPath -Name DisabledComponents -Type DWord -Value 255
        if ($? -eq $false) {
            updateResultFile "Failed to disable IPv6 on all NICs" $RESULT_FILE
            exit 1
        }
    }
    else {
        infoLog "Disabling IPv6 on all NICs using Disable-NetAdapterBinding for $OSInfo.Caption" $DISABLE_IPV6_CONFIG_LOG
        Disable-NetAdapterBinding -Name "*" -ComponentID ms_tcpip6
        if ($? -eq $false) {
            updateResultFile "Failed to disable IPv6 on all NICs" $RESULT_FILE
            exit 1
        }
    }
    updateResultFile "Success: Disabled IPv6 on all NICs" $RESULT_FILE
    $ErrorActionPreference = $backupErrorActionPreference
}

$Job = Start-Job -ScriptBlock $Code -ArgumentList $args
Wait-Job $Job -Timeout $TIMEOUT
if ($Job.State -ne "Completed") {
    $JobOutput = $Job | Receive-Job
    Remove-Job -force $Job
    Write-Log-Global -message "Disable IPv6 script has not completed within time limit"
    Write-Log-Global -message "Partial Job Output = '$JobOutput'"
    exit 1
} else {
    Write-Log-Global -message "Disable IPv6 script has completed execution within time Limit"
    $JobOutput = $Job | Receive-Job
    Write-Log-Global -message "Job Output = Given below:$JobOutput"
    $Result = $JobOutput | Select-Object -Last 1
    exit $Result
}
exit 0