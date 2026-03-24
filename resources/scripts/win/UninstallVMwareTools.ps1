# Version: 6.1.2
param (
    [switch]$noWMIC = $false
)
$VMTOOLS="VMware Tools"
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

    $logRecord = "$time | $severity | $lineNum | $message"

    $logRecord
}

# Global Variable to store the return value
$Code = {
    param($VMTOOLS, $TIMEOUT, $noWMIC, $arg)
    #### Log function
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

    function Delete-Registary-Key {
        [CmdletBinding()]
        param(
            [Parameter()]
            [ValidateNotNullOrEmpty()]
            [string]$keyPath,

            [Parameter(Mandatory = $false)]
            [string]$valueName
        )

        if ($PSBoundParameters.ContainsKey('valueName')) {
            Write-Log -message "Deleting registry value: $valueName from key: $keyPath"
            reg delete "$keyPath" /v "$valueName" /f
        } else {
            Write-Log -message "Deleting entire registry key: $keyPath"
            reg delete "$keyPath" /f
        }

        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log -message "Registry key deleted successfully."
        } else {
            Write-Log -message "Failed to delete the registry key with exit code : $exitCode"
        }
    }
    Write-Log -message "Uninstalling VMware Tools"
    ### Main Function
    if ($arg -like "target") {
        if ($noWMIC) {
            Write-Log -message "Running Command : ' Get-CimInstance -Class Win32_Product | Where-Object { $_.Name -eq $VMTOOLS } | Select-Object -ExpandProperty Name | findstr $VMTOOLS | Out-Null'"
            Get-CimInstance -Class Win32_Product | Where-Object { $_.Name -eq $VMTOOLS } | Select-Object -ExpandProperty Name | findstr $VMTOOLS | Out-Null
        } else {
            Write-Log -message "Running Command : 'wmic product where `"name='$VMTOOLS'`" get name | findstr Name | Out-Null'"
            wmic product where "name='$VMTOOLS'" get name | findstr Name | Out-Null
        }
        if (-not $?) {
            Write-Log -message "Failed to run command with exit code: $ExitCode"
            Write-Log -message "VMware Tools not installed."
            return $ExitCode
        }

        Write-Log -message "VMware tools installation found. Uninstalling VMware tools."
        Write-Log -message "Running Command : 'Get-WmiObject -Class Win32_Product -Filter `"Name = '$VMTOOLS'`" | Select-Object -Property IdentifyingNumber, Version'"
        $obj = Get-WmiObject -Class Win32_Product -Filter "Name = '$VMTOOLS'" | Select-Object -Property IdentifyingNumber, Version
        $guid = $obj.IdentifyingNumber
        $vmToolsVersion = $obj.Version
        Write-Log -message "VMware Tools GUID is : $guid"
        Write-Log -message "VMware Tools Version is : $vmToolsVersion"

        # Powershell executes msiexec asynchronously. Piping the command makes powershell wait for the command to complete.
        Write-Log -message "Running command: 'msiexec /quiet /norestart /uninstall $guid | Out-Default'"
        msiexec /quiet /norestart /uninstall $guid | Out-Default
        $ExitCode = $LASTEXITCODE
        # Value 3010 refers to error code ERROR_SUCCESS_REBOOT_REQUIRED(https://docs.microsoft.com/en-us/windows/win32/msi/error-codes)
        $UninstallVMwareToolsFailure = $true
        if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
            $UninstallVMwareToolsFailure = $false
            Write-Log -message "Uninstall operation successful"
            Write-Log -message "Uninstallation successful. Proceeding to clean up VMware entries from the registry. Some errors may occur during the cleanup process, but they can be safely ignored."
        } else {
            $UninstallVMwareToolsFailure = $true
            Write-Log -message "VMware tools uninstaller failed with Exit Code $ExitCode. Uninstalling VMware Tools from Registry ..."
        }

        # https://kb.vmware.com/s/article/1001354
        Write-Log -message "Running command: 'Get-ChildItem -Path HKLM:\SOFTWARE\Classes\Installer\Products | Get-ItemProperty | Where-Object {$_.ProductName -eq $VMTOOLS } | Select-Object -ExpandProperty PSChildName'"
        $vmciId = Get-ChildItem -Path HKLM:\SOFTWARE\Classes\Installer\Products | Get-ItemProperty | Where-Object {$_.ProductName -eq $VMTOOLS } | Select-Object -ExpandProperty PSChildName
        Write-Log -message "VMCI Driver GUID is : $guid"

        if ($vmciId -eq $null) {
            if ($UninstallVMwareToolsFailure) {
                Write-Log -message "Failed to run command"
            }
            Write-Log -message "Unable to determine VMCI Driver GUID"
        } elseif ($vmciId -is [Object[]]) {
            Write-Log -message "Getting multiple VMCI Driver GUIDs"
        } else {
            Delete-Registary-Key -keyPath "HKEY_CLASSES_ROOT\Installer\Features\$vmciId"
            Delete-Registary-Key -keyPath "HKEY_CLASSES_ROOT\Installer\Products\$vmciId"
            Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Classes\Installer\Features\$vmciId"
            Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Classes\Installer\Products\$vmciId"
            Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$vmciId"
        }

        Write-Log -message "Deleting VMware Tools Services"
        $vmwareServices = @("VGAuthService", "vmvss", "VM3DService", "VMTools")
        Foreach ($s in $vmwareServices) {
            Write-Log -message "Running command: 'Stop-Service -Name $s -Force'"
            Stop-Service -Name $s -Force
            if (-not $? -and $UninstallVMwareToolsFailure) {
                Write-Log -message "Failed to run command"
            }
            Write-Log -message "Running command: 'sc.exe delete $s'"
            sc.exe delete $s
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
                Write-Log -message "Failed to run the command with exit code: $exitCode"
            }
        }

        Write-Log -message "Deleting registry keys"
        Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
        Delete-Registary-Key -keyPath "HKLM\SOFTWARE\VMware, Inc."
        Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -valueName "VMware User Process"
        Delete-Registary-Key -keyPath "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -valueName "VMware VM3DService Process"

        # stopping vm3dservice process from the task manager

        # get the vm3dprocess id
        Write-Log -message "Running command: Get-Process | Where-Object { $_.Name -like `"*vm3dservice*`" } | Select-Object -ExpandProperty Id"
        $vm3dProcessID = Get-Process | Where-Object { $_.Name -like "*vm3dservice*" } | Select-Object -ExpandProperty Id
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
        }
        #stop the process
        Write-Log -message "Running command: Stop-Process -Id $vm3dProcessID -Force"
        Stop-Process -Id $vm3dProcessID -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
        }

        # take the ownership of the file responsible for above task(vm3dservice)
        Write-Log -message "Running command: Takeown /F `"C:\Windows\System32\vm3dservice.exe`""
        Takeown /F "C:\Windows\System32\vm3dservice.exe"
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        #grant full permission on the file to the admin
        Write-Log -message "Running command: icacls `"C:\Windows\System32\vm3dservice.exe`" /grant administrators:F"
        icacls "C:\Windows\System32\vm3dservice.exe" /grant administrators:F
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        #remove the file responsible for the above process
        Write-Log -message "Running command: Remove-Item -Path `"C:\Windows\System32\vm3dservice.exe`" -Force"
        Remove-Item -Path "C:\Windows\System32\vm3dservice.exe" -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
        }

        #removing the driver files(directory) for vm3dservice

        #take the ownership for the driver files(directory) recursively
        Write-Log -message "Running command: takeown /F `"C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7`" /R /D Y"
        takeown /F "C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7" /R /D Y
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # grant full permission on the files(directory to the admin
        Write-Log -message "Running command: icacls `"C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7`" /grant administrators:F /T"
        icacls "C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7" /grant administrators:F /T
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        #remove the driver files(directory)
        Write-Log -message "Running command: Remove-Item -Path `"C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7`" -Recurse -Force"
        Remove-Item -Path "C:\Windows\System32\DriverStore\FileRepository\vm3d.inf_amd64_eb377e04601865d7" -Recurse -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
        }

        Write-Log -message "Deleting VMware Tools folder"
        # take the ownership of the VMware Tools folder recursively
        Write-Log -message "Running command: Takeown /F `"C:\Program Files\VMware\VMware Tools\`" /R /D Y"
        Takeown /F "C:\Program Files\VMware\VMware Tools\" /R /D Y
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # grant full permission on the VMware Tools folder to the admin
        Write-Log -message "Running command: icacls `"C:\Program Files\VMware\VMware Tools\`" /grant administrators:F /T"
        icacls "C:\Program Files\VMware\VMware Tools\" /grant administrators:F /T
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # remove the VMware Tools folder
        Write-Log -message "Running command: Remove-Item -Path `"C:\Program Files\VMware\VMware Tools\`" -Recurse -Force"
        Remove-Item -Path "C:\Program Files\VMware\VMware Tools\" -Recurse -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
            Write-Log -message "Failed to delete VMware Tools folder. Please delete the folder manually."
        }

        Write-Log -message "Deleting VMware folder"
        # take the ownership of the VMware folder recursively
        Write-Log -message "Running command: Takeown /F `"C:\Program Files\VMware\`" /R /D Y"
        Takeown /F "C:\Program Files\VMware\" /R /D Y
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # grant full permission on the VMware folder to the admin
        Write-Log -message "Running command: icacls `"C:\Program Files\VMware\`" /grant administrators:F /T"
        icacls "C:\Program Files\VMware\" /grant administrators:F /T
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # remove the VMware folder
        Write-Log -message "Running command: Remove-Item -Path `"C:\Program Files\VMware\`" -Recurse -Force"
        Remove-Item -Path "C:\Program Files\VMware\" -Recurse -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
            Write-Log -message "Failed to delete Program Files\VMware folder. Please delete the folder manually."
        }

        Write-Log -message "Deleting Common Files\VMware folder"
        # take the ownership of the Common Files VMware folder recursively
        Write-Log -message "Running command: Takeown /F `"C:\Program Files\Common Files\VMware\`" /R /D Y"
        Takeown /F "C:\Program Files\Common Files\VMware\" /R /D Y
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # grant full permission on the Common Files VMware folder to the admin
        Write-Log -message "Running command: icacls `"C:\Program Files\Common Files\VMware\`" /grant administrators:F /T"
        icacls "C:\Program Files\Common Files\VMware\" /grant administrators:F /T
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # remove the Common Files VMware folder
        Write-Log -message "Running command: Remove-Item -Path `"C:\Program Files\Common Files\VMware\`" -Recurse -Force"
        Remove-Item -Path "C:\Program Files\Common Files\VMware\" -Recurse -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
            Write-Log -message "Failed to delete Common Files\VMware folder. Please delete the folder manually."
        }

        Write-Log -message "Deleting ProgramData\VMware folder"
        # take the ownership of the ProgramData VMware folder recursively
        Write-Log -message "Running command: Takeown /F `"C:\ProgramData\VMware\`" /R /D Y"
        Takeown /F "C:\ProgramData\VMware\" /R /D Y
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # grant full permission on the ProgramData VMware folder to the admin
        Write-Log -message "Running command: icacls `"C:\ProgramData\VMware\`" /grant administrators:F /T"
        icacls "C:\ProgramData\VMware\" /grant administrators:F /T
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command with ExitCode: $exitCode"
        }

        # remove the ProgramData VMware folder
        Write-Log -message "Running command: Remove-Item -Path `"C:\ProgramData\VMware\`" -Recurse -Force"
        Remove-Item -Path "C:\ProgramData\VMware\" -Recurse -Force
        if (-not $? -and $UninstallVMwareToolsFailure) {
            Write-Log -message "Failed to run command"
            Write-Log -message "Failed to delete Program Data\VMware folder. Please delete the folder manually."
        }
        if ($noWMIC) {
            Write-Log -message "Get-CimInstance -ClassName Win32_Product | Where-Object { $_.Name -like "*$VMTOOLS*" } | findstr $VMTOOLS | Out-Null'"
            Get-CimInstance -ClassName Win32_Product | Where-Object { $_.Name -like "*$VMTOOLS*" } | findstr $VMTOOLS | Out-Null
        } else {
            Write-Log -message "Running command: 'wmic product where `"name='$VMTOOLS'`" get name | findstr Name | Out-Null'"
            wmic product where "name='$VMTOOLS'" get name | findstr Name | Out-Null
        }
        if (-not $?) {
            Write-Log -message "VMware Tools uninstalled successfully."
        } else {
            Write-Log -message "Failed to run command with ExitCode: $ExitCode"
            Write-Log -message "Failed to uninstall VMware Tools. Please follow https://kb.vmware.com/s/article/1001354 to uninstall VMware Tools manually."
        }

        return 0
    }
}

$Job = Start-Job -ScriptBlock $Code -ArgumentList $VMTOOLS, $TIMEOUT, $noWMIC, $args[0]
Wait-Job $Job -Timeout $TIMEOUT
if ($Job.State -ne "Completed") {
    $JobOutput = $Job | Receive-Job
    Remove-Job -force $Job
    Write-Log-Global -message "Uninstall VMware Tools script has not completed execution within the Time limit"
    Write-Log-Global -message "Partial Job Output = '$JobOutput'"
    exit 1
} else {
    Write-Log-Global -message "Uninstall VMware Tools script has completed execution within Time Limit"
    $JobOutput = $Job | Receive-Job
    Write-Log-Global -message "Job Output = Given below:$JobOutput"
    $Result = $JobOutput | Select-Object -Last 1
    exit $Result
}
