# Version: 6.1.2

# Waiting for 40mins for the install ngt script to complete
$TIMEOUT=2400

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

$Code = {
    function Write-Log {
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

    $NGTServiceStatus = (Get-Service 'Nutanix Guest Tools Agent' | Select-Object -property Status).Status
    Write-Log -message "Nutanix Guest Tools Agent Status : $NGTServiceStatus"
    if ($NGTServiceStatus.ToString().Trim().Contains("Running")){
        Write-Log -message "NGT is installed"
        return 0
    }
    # use while loop to find whether Nutanix Tools is mounted or not
    $startTime = Get-Date
    $TIMEOUT_FOR_NGT_CDROM=30
    $endTime = $startTime.AddSeconds($TIMEOUT_FOR_NGT_CDROM)
    $WAIT_FOR_NGT_SERVICE=30
    $WAIT_FOR_NGT_CDROM=5

    while ($startTime -lt $endTime) {
        Write-Log -message "Looping..."
        $MountPoint = (Get-WmiObject Win32_LogicalDisk -Filter 'VolumeName="NUTANIX_TOOLS"' | Select-Object -property DeviceID).DeviceID
        if ($MountPoint -eq $null){
            Start-Sleep -Seconds $WAIT_FOR_NGT_CDROM
            $startTime = Get-Date
            Continue
        }
        $MountPoint = $MountPoint.Trim()
        break
    }

    if ($MountPoint -ne $null){
        Write-Log -message "NGT ISO is mounted at : $MountPoint"
    } else {
        Write-Log -message "NGT ISO is not mounted within the time limit"
        return 1
    }

    $InstallCmd = "$MountPoint\setup.exe /quiet ACCEPTEULA=yes /norestart"
    Write-Log -message "Command for Installing NGT : $InstallCmd"

    $Maxretries = 3
    $Retry = 0
    while ($Retry -lt $Maxretries) {
        $InstallCmdOutput = Invoke-Expression $InstallCmd -ErrorVariable badoutput
        Write-Log -message "Install NGT Command Output : $InstallCmdOutput"
        Write-Log -message "Install NGT Command Error : $badoutput"

        $startTime = Get-Date
        $endTime = $startTime.AddMinutes(10)
        while ($startTime -lt $endTime) {
            $NGTServiceStatus = (Get-Service 'Nutanix Guest Tools Agent' | Select-Object -property Status).Status
            Write-Log -message "Nutanix Guest Tools Agent Status : $NGTServiceStatus"
            $Retry = $Retry + 1

            if ($NGTServiceStatus.ToString().Trim().Contains("Running")){
                Write-Log -message "NGT is installed"
                return 0
            }
            Write-Log -message "NGT is not installed, checking for status after 30 seconds"
            Start-Sleep -s $WAIT_FOR_NGT_SERVICE
        }
    }
    return 1
}

$Job = Start-Job -ScriptBlock $Code
Wait-Job $Job -Timeout $TIMEOUT
if ($Job.State -ne "Completed") {
    Remove-Job -force $Job
    Write-Log-Global -message "Install NGT script has not completed execution within the Time limit"
    exit 1
} else {
    Write-Log-Global -message "Install NGT script has completed execution within Time Limit"
    $JobOutput = $Job | Receive-Job
    Write-Log-Global -message "Job Output = Given below:$JobOutput"
    $Result = $JobOutput | Select-Object -Last 1
    exit $Result
}
