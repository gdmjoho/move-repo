# Version: 6.1.2

param (
    [Parameter(Mandatory = $false, Position = 1)]
    [string]$xtractIP = 'localhost',
    [string]$retainIP = $false,
    [bool]$setSanPolicy = $false,
    [bool]$installNgt = $false,
    [string]$minPSVersion = '',
    [bool]$installVirtio = $false,
    [bool]$uninstallVMwareTools = $false,
    [string]$virtIOVersion = '',
    [switch]$noWMIC = $false,
    [switch]$debugLog = $false  # Additional debug logs
)
#### constants
$Global:ScriptVersion = "6.1.2"

###### Tracking the steps
$Global:HasLastStepSucceeded = $false
$Global:CurrentStep = 0
$Global:LastStep = 5
$Global:CleanupExecuted = $false

###### Step numbering variables (separate from legacy CurrentStep/LastStep)
$Global:CurrentStepNumber = 0
$Global:TotalSteps = 0

###### Web client to download artifact
$Global:WebClient = New-Object System.Net.WebClient

#### Select protocol to download artifact. http for xtract cloud and https for xtract vm
$Global:Protocol = "https"
$Global:BaseUrl = "${Global:Protocol}://$xtractIP"

#### Wait time for virtio installation
$Global:VirtioInstallationTimeOutPeriod = [timespan]::FromSeconds(120)

#### Constants to check if virtio drivers already installed
$Global:IsVirtIOInstalledAndDriversPresent = $false
$Global:VirtIODriverInfNames = @('netkvm.inf', 'vioscsi.inf', 'balloon.inf')
$Global:PreviousVirtIOInstallation = $null

$SysDrive = "C:"
$result = Get-ChildItem Env:SYSTEMDRIVE
$Global:HasLastStepSucceeded = $?
if ($Global:HasLastStepSucceeded)
{
    $SysDrive = $result.value
}
$NXBaseDir = Join-Path $SysDrive -ChildPath "Nutanix"
$TempDir = Join-Path $NXBaseDir -ChildPath "Temp"
$MainDirPath = Join-Path $NXBaseDir -ChildPath 'Move'
$MainUninstallDirPath = Join-Path $NXBaseDir -ChildPath "Uninstall"
$ConfPath = Join-Path $MainDirPath -ChildPath "config.xml"
$PrepStateFile = Join-Path $NXBaseDir -ChildPath "prep_state.txt"
$DownloadDirPath = Join-Path $MainDirPath -ChildPath 'download'

# Scripts path
$ScriptsDirPath = Join-Path $DownloadDirPath -ChildPath 'scripts'
$UninstallScriptsPath = Join-Path $MainUninstallDirPath -ChildPath "scripts"
$destinationDirPath = Join-Path $MainDirPath -ChildPath 'artifact'

# Log file
$LogDirPath = Join-Path $NXBaseDir -ChildPath "log"
$TestLogPath = Join-Path $LogDirPath -ChildPath "uvm_script-$xtractIP.log"
$RetainIPResultPath = Join-Path $TempDir -ChildPath "RetainIPResult.out"
$NutanixMoveResultPath = Join-Path $TempDir -ChildPath "NutanixMoveResult.out"

# Directory having file to check whether VirtIO drivers were already installed before migration had started
$VirtIODriverUtility = Join-Path $NXBaseDir -ChildPath "VirtIODriverUtility"

## Log
#### Create Log directory
$cmd = "New-Item -ItemType ""directory"" -Path ""$LogDirPath"" -ErrorAction SilentlyContinue"
$out = New-Item -ItemType "directory" -Path $LogDirPath -ErrorAction SilentlyContinue 2>&1 | Out-String
#### Log function
function Write-Log
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$message,

        [Parameter()]
        [switch]$avoidStdout = $false,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Info', 'Warn', 'Eror')]
        [string]$severity = 'Info'
    )

    $time = (Get-Date -F o)
    $lineNum = $MyInvocation.ScriptLineNumber
    # Log directly in Powershell with color coding based on severity
    if (-not$avoidStdout)
    {
        switch ($severity) {
            'Eror' { Write-Host $message -ForegroundColor Red }
            'Warn' { Write-Host $message -ForegroundColor Yellow }
            default { Write-Host $message }
        }
    }
    $logRecord = "$time | $severity | $lineNum | $message"

    $logRecord | Out-File -Append $TestLogPath
}

#### Step and Sub-step functions for enhanced visibility
function Step-Start {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepMessage,
        [Parameter(Mandatory=$false)]
        [string]$StepKey
    )

    # Only increment and show step numbering for main prep steps (those with step keys)
    if ($StepKey) {
        $Global:CurrentStepNumber++
        Write-Host "[STEP-$Global:CurrentStepNumber/$Global:TotalSteps]" -ForegroundColor Yellow -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " ...Starting" -ForegroundColor Yellow
        Write-Log "[STEP-$Global:CurrentStepNumber/$Global:TotalSteps] ${StepMessage}: ...Starting" -avoidStdout:$true
        Update-PrepState -StepName $StepKey -Status "InProgress"
    } else {
        Write-Host "[STEP]" -ForegroundColor Yellow -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " ...Starting" -ForegroundColor Yellow
        Write-Log "[STEP] ${StepMessage}: ...Starting" -avoidStdout:$true
    }
}

function Step-Done {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepMessage,
        [Parameter(Mandatory=$false)]
        [string]$StepKey
    )

    # Only show step numbering for main prep steps (those with step keys)
    if ($StepKey) {
        Write-Host "[OK-$Global:CurrentStepNumber/$Global:TotalSteps]" -ForegroundColor Green -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " Completed`n" -ForegroundColor Green
        Write-Host ""  # Add blank line after main steps
        Write-Log "[OK-$Global:CurrentStepNumber/$Global:TotalSteps] ${StepMessage}: Completed`n" -avoidStdout:$true
        Update-PrepState -StepName $StepKey -Status "Done"
    } else {
        Write-Host "[OK]" -ForegroundColor Green -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " Completed`n" -ForegroundColor Green
        Write-Log "[OK] ${StepMessage}: Completed`n" -avoidStdout:$true
    }
}

function Step-Fail {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepMessage,
        [Parameter(Mandatory=$false)]
        [string]$StepKey
    )

    # Only show step numbering for main prep steps (those with step keys)
    if ($StepKey) {
        Write-Host "[ERROR-$Global:CurrentStepNumber/$Global:TotalSteps]" -ForegroundColor Red -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " Failed`n" -ForegroundColor Red
        Write-Log "[ERROR-$Global:CurrentStepNumber/$Global:TotalSteps] ${StepMessage}: Failed`n" -avoidStdout:$true
        Update-PrepState -StepName $StepKey -Status "Failed"
    } else {
        Write-Host "[ERROR]" -ForegroundColor Red -NoNewline
        Write-Host " ${StepMessage}:" -NoNewline
        Write-Host " Failed`n" -ForegroundColor Red
        Write-Log "[ERROR] ${StepMessage}: Failed`n" -avoidStdout:$true
    }

    # Update overall state to Failed when any step fails
    Update-OverallState -Status "Failed"
    exit 1
}

# Helper to evaluate sub-step exit codes and escalate to step failure
function Assert-LastCommandSuccess {
    param(
        [int]$ExitCode,
        [string]$ParentStepMessage,
        [string]$ParentStepKey,
        [string]$SubStepMessage
    )
    if ($ExitCode -ne 0) {
        Step-Fail $ParentStepMessage -StepKey $ParentStepKey
    }
}

function SubStep-Start {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubStepMessage
    )
    Write-Host "  [SUB]" -ForegroundColor Cyan -NoNewline
    Write-Host " ${SubStepMessage}:" -NoNewline
    Write-Host " ...Starting" -ForegroundColor Cyan
    Write-Log "[SUB] ${SubStepMessage}: Starting" -avoidStdout:$true
}

function SubStep-Done {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubStepMessage
    )
    Write-Host "  [SUB-OK]" -ForegroundColor DarkCyan -NoNewline
    Write-Host " ${SubStepMessage}:" -NoNewline
    Write-Host " Completed" -ForegroundColor DarkCyan
    Write-Log "[SUB-OK] ${SubStepMessage}: Completed" -avoidStdout:$true
}

function SubStep-Fail {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubStepMessage
    )
    Write-Host "  [SUB-ERROR]" -ForegroundColor Red -NoNewline
    Write-Host " ${SubStepMessage}:" -NoNewline
    Write-Host " Failed" -ForegroundColor Red
    Write-Log "[SUB-ERROR] ${SubStepMessage}: Failed" -avoidStdout:$true
}

#### Function to calculate total steps based on script arguments
function Calculate-TotalSteps {
    $Global:TotalSteps = 4  # Base steps: cleanup check, directories, download, schedule move

    if ($installVirtio) {
        $Global:TotalSteps++  # INSTALL_VIRTIO_CERTIFICATES (always runs if installVirtio is true)
        # INSTALL_VIRTIO_DRIVERS step only runs if VirtIO is not already installed
        if (-Not $Global:IsVirtIOInstalledAndDriversPresent) {
            $Global:TotalSteps++
        }
    }

    if ($setSanPolicy) {
        $Global:TotalSteps++
    }

    Write-Log "Calculated total steps: $Global:TotalSteps" -avoidStdout:$true
}

#### Prep State Management Functions
function Initialize-PrepState {
    Write-Log "Initializing preparation state file: $PrepStateFile"

    # Create prep state file with all steps marked as "NotStarted" (matching Linux version)
    $prepStateContent = @"
# VM Preparation State File
# Script Version: $Global:ScriptVersion
# Format: STEP_NAME=STATUS
# Status values: NotStarted, Skipped, InProgress, Done, Failed, Interrupted
# Generated on: $(Get-Date)
# Script Arguments: retainIP=$retainIP installVirtio=$installVirtio setSanPolicy=$setSanPolicy uninstallVMwareTools=$uninstallVMwareTools installNgt=$installNgt

CHECK_CLEANUP_PREREQUISITE=NotStarted
PREPARE_DIRECTORIES=NotStarted
DOWNLOAD_ARTIFACTS=NotStarted
"@

    # Add conditional steps based on arguments
    if ($installVirtio) {
        $prepStateContent += "`nINSTALL_VIRTIO_CERTIFICATES=NotStarted"
        $prepStateContent += "`nINSTALL_VIRTIO_DRIVERS=NotStarted"
    } else {
        $prepStateContent += "`nINSTALL_VIRTIO_CERTIFICATES=Skipped"
        $prepStateContent += "`nINSTALL_VIRTIO_DRIVERS=Skipped"
    }

    if ($setSanPolicy) {
        $prepStateContent += "`nSET_SAN_POLICY=NotStarted"
    } else {
        $prepStateContent += "`nSET_SAN_POLICY=Skipped"
    }

    if ($uninstallVMwareTools) {
        $prepStateContent += "`nUNINSTALL_VMWARE_TOOLS=NotStarted"
    } else {
        $prepStateContent += "`nUNINSTALL_VMWARE_TOOLS=Skipped"
    }

    if ($installNgt) {
        $prepStateContent += "`nINSTALL_NGT=NotStarted"
    } else {
        $prepStateContent += "`nINSTALL_NGT=Skipped"
    }

    $prepStateContent += "`nSCHEDULE_MOVE_SERVICE=NotStarted"
    $prepStateContent += "`n`nOVERALL_STATE=InProgress"

    # Ensure directory exists and write the file
    $prepStateDir = Split-Path $PrepStateFile -Parent
    if (!(Test-Path $prepStateDir)) {
        New-Item -Path $prepStateDir -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $PrepStateFile -Value $prepStateContent -Encoding UTF8
    Write-Log "Preparation state file initialized successfully"
}

function Update-PrepState {
    param(
        [Parameter(Mandatory=$true)]
        [string]$StepName,
        [Parameter(Mandatory=$true)]
        [string]$Status
    )


    if (Test-Path $PrepStateFile) {
        # Read the file content
        $content = Get-Content $PrepStateFile

        # Update the specific line
        for ($i = 0; $i -lt $content.Length; $i++) {
            if ($content[$i] -match "^$StepName=") {
                $content[$i] = "$StepName=$Status"
                break
            }
        }

        # Write back to file
        Set-Content -Path $PrepStateFile -Value $content -Encoding UTF8
        Write-Log "Updated prep state: $StepName = $Status" -avoidStdout:$true
    } else {
        Write-Log "Prep state file not found: $PrepStateFile" -severity Warn
    }
}

function Update-OverallState {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Success', 'Failed', 'InProgress', 'Interrupted')]
        [string]$Status
    )

    Update-PrepState -StepName "OVERALL_STATE" -Status $Status
    Write-Log "Updated overall state: $Status" -avoidStdout:$true
}

function Show-PrepState {
    if (Test-Path $PrepStateFile) {
        Write-Log "Final preparation state:" -avoidStdout:$false
        $stepNumber = 0

        # First pass: count only steps that were actually executed (not Skipped or NotStarted)
        $totalSteps = 0
        Get-Content $PrepStateFile | ForEach-Object {
            $line = $_.Trim()
            # Skip comment lines and empty lines
            if ($line.StartsWith('#') -or [string]::IsNullOrWhiteSpace($line)) {
                return
            }
            if ($line -match '^([^=]+)=(.+)$') {
                $stepName = $matches[1]
                $status = $matches[2]
                # Only count steps that were actually executed and are not the overall state
                if ($stepName -ne "OVERALL_STATE" -and $status -ne "Skipped" -and $status -ne "NotStarted") {
                    $totalSteps++
                }
            }
        }

        # Second pass: display each step with proper formatting
        Get-Content $PrepStateFile | ForEach-Object {
            $line = $_.Trim()

            # Skip comment lines and empty lines
            if ($line.StartsWith('#') -or [string]::IsNullOrWhiteSpace($line)) {
                return
            }

            # Split step name and status
            if ($line -match '^([^=]+)=(.+)$') {
                $stepName = $matches[1]
                $status = $matches[2]

                # Skip steps that were not executed (Skipped or NotStarted)
                if ($status -eq "Skipped" -or $status -eq "NotStarted") {
                    return
                }

                # Don't number the overall state
                if ($stepName -ne "OVERALL_STATE") {
                    $stepNumber++
                }

                # Convert step names to readable format
                $readableName = switch ($stepName) {
                    "CHECK_CLEANUP_PREREQUISITE" { "Checking cleanup prerequisite" }
                    "PREPARE_DIRECTORIES" { "Preparing directories" }
                    "DOWNLOAD_ARTIFACTS" { "Downloading required artifacts" }
                    "INSTALL_VIRTIO_CERTIFICATES" { "Installing VirtIO certificates" }
                    "INSTALL_VIRTIO_DRIVERS" { "Installing VirtIO drivers" }
                    "SET_SAN_POLICY" { "Setting SAN policy" }
                    "UNINSTALL_VMWARE_TOOLS" { "Uninstalling VMware Tools" }
                    "INSTALL_NGT" { "Installing NGT" }
                    "SCHEDULE_MOVE_SERVICE" { "Scheduling move service" }
                    "OVERALL_STATE" { "Overall State" }
                    default { $stepName }
                }

                # Set color based on status
                $color = switch -Wildcard ($status) {
                    "Done" { "Green" }
                    "Failed*" { "Red" }
                    "Interrupted*" { "Red" }
                    "InProgress" { "Yellow" }
                    "Success" { "Green" }
                    default { "White" }
                }

                $statusText = switch -Wildcard ($status) {
                    "Done" { "Done" }
                    "Failed*" { $status }
                    "Interrupted*" { $status }
                    "InProgress" { "In Progress" }
                    "Success" { "Success" }
                    default { $status }
                }

                if ($stepName -eq "OVERALL_STATE") {
                    Write-Host ""
                    Write-Host "${readableName}: " -NoNewline
                    Write-Host "$statusText" -ForegroundColor $color
                } else {
                    # Display in the same format as during execution using actual total steps
                    Write-Host "[STEP-$stepNumber/$totalSteps]" -ForegroundColor Green -NoNewline
                    Write-Host " ${readableName}: " -NoNewline
                    Write-Host "$statusText" -ForegroundColor $color
                }
            }
        }
    } else {
        Write-Log "Prep state file not found: $PrepStateFile" -severity Warn
    }
}

# Function to run cleanup script if it exists (for repeated executions)

#Questions to consider:

# What happens in case of first time preperation
## When the script is run for the first time, it will try to download the cleanup script and run it.
# What happens in case of subsequent preperation
## On subsequent runs also it will be downloaded and run.
# What happen in case the customer ran the cleanup scripts and then this script
## if the customer has already run the cleanup script, it will run again and exit cleanly since the cleanup script is idempotent.
# What happens when the folder is not accessible
## if the folder is not accessible, the script will fail to download the cleanup script and exit with an error.
function Invoke-CleanupIfExists {
    Write-Log "Running cleanup prerequisite (always download & execute)." -avoidStdout:$true

    $CleanupScriptPath = Join-Path $UninstallScriptsPath -ChildPath "cleanup_installation.ps1"
    # make the directory if not exists.
    if (!(Test-Path -Path $UninstallScriptsPath)) {
        New-Item -Path $UninstallScriptsPath -ItemType Directory -Force | Out-Null
    }
    $webCleanupScriptPath = "$Global:BaseUrl/resources/scripts/win/cleanup_installation.ps1"

    SubStep-Start "Downloading cleanup script"
    try {
        $Global:WebClient.DownloadFile($webCleanupScriptPath, $CleanupScriptPath)
        SubStep-Done "Downloading cleanup script"
    } catch {
        Write-Log "Failed to download cleanup script. Exception: $($_.Exception.Message)" -severity Eror -avoidStdout:$false
        SubStep-Fail "Downloading cleanup script"
        Write-Log "Cannot proceed without cleanup script. Exiting." -severity Eror -avoidStdout:$false
        return 1
    }

    SubStep-Start "Executing cleanup script"
    $cleanupResult = & PowerShell.exe -ExecutionPolicy Bypass -File $CleanupScriptPath 2>&1 | Out-String
    $cleanupExitCode = $LASTEXITCODE
    if ($cleanupExitCode -eq 0) {
        Write-Log "Cleanup script executed successfully." -avoidStdout:$true
        SubStep-Done "Executing cleanup script"
    } else {
        Write-Log "Cleanup script execution returned exit code: $cleanupExitCode" -severity Warn -avoidStdout:$false
        Write-Log "Cleanup output: $cleanupResult" -severity Warn -avoidStdout:$true
        SubStep-Fail "Executing cleanup script"
        return 1
    }

    SubStep-Start "Removing cleanup script"
    Remove-Item $CleanupScriptPath -Force -ErrorAction SilentlyContinue
    SubStep-Done "Removing cleanup script"
    return $cleanupExitCode
}

function Cleanup-PrepStateOnExit {
    # Prevent multiple executions
    if ($Global:CleanupExecuted) {
        return
    }
    $Global:CleanupExecuted = $true

    try {
        if (Test-Path $PrepStateFile) {
            Write-Log "Cleaning up prep state file on script exit/interruption" -avoidStdout:$true

            # Read the file content
            $content = Get-Content $PrepStateFile
            $modified = $false

            # Mark any "InProgress" steps as "Interrupted" on script exit (matching Linux version)
            for ($i = 0; $i -lt $content.Length; $i++) {
                if ($content[$i] -match "=InProgress") {
                    $content[$i] = $content[$i] -replace "=InProgress.*", "=Interrupted"
                    $modified = $true
                    Write-Log "Marked step as interrupted: $($content[$i])" -avoidStdout:$true
                }
            }

            # Write back to file only if modifications were made
            if ($modified) {
                Set-Content -Path $PrepStateFile -Value $content -Encoding UTF8
                Write-Log "Marked interrupted steps as 'Interrupted' in prep state file" -avoidStdout:$true

                # Only update overall state to Interrupted if we actually had interrupted steps
                Update-OverallState -Status "Interrupted"
            }
        }
    } catch {
        Write-Log "Error during cleanup: $($_.Exception.Message)" -avoidStdout:$true
    }
}

# Set up Ctrl+C interrupt handler for PowerShell
try {
    # Handle Ctrl+C interruption
    [Console]::TreatControlCAsInput = $false

    # Use a direct approach - set up Ctrl+C signal handling
    $ctrlCHandler = {
        param($sender, $e)
        $e.Cancel = $true
        Write-Host "`nScript interrupted by user. Cleaning up..." -ForegroundColor Yellow
        Cleanup-PrepStateOnExit
        [Environment]::Exit(1)
    }

    [Console]::CancelKeyPress += $ctrlCHandler

} catch {
    Write-Log "Warning: Could not set up Ctrl+C interrupt handling: $($_.Exception.Message)" -severity Warn -avoidStdout:$true
}

Write-Log "Setting up the User VM with Xtract: $xtractIP using script: $Global:ScriptVersion with arguments: retainIP:$retainIP, installVirtio:$installVirtio, setSanPolicy:$setSanPolicy, uninstallVMwareTools:$uninstallVMwareTools, minPSVersion:$minPSVersion, installNgt:$installNgt"
Write-Log -message "Executing command: $cmd" -avoidStdout:$true
Write-Log -message "Output: $out" -avoidStdout:$true

#### Check PowerShell Version
function Check-PowerShell-Version {
    SubStep-Start "Validating PowerShell version requirements"
    $PSVersion = $PSVersionTable.PSVersion
    $major = If ($PSVersion.Major -lt 0) {0} Else {$PSVersion.Major}
    $minor = If ($PSVersion.Minor -lt 0) {0} Else {$PSVersion.Minor}
    $build = If ($PSVersion.Build -lt 0) {0} Else {$PSVersion.Build}
    $CurPSVersion = New-Object -TypeName System.Version -ArgumentList $major,$minor,$build
    $MinPSVersion = New-Object -TypeName System.Version -ArgumentList $MinPSVersion
    if ($CurPSVersion -lt $MinPSVersion) {
        Write-Log -message "Current PowerShell version $CurPSVersion is not supported. Minimum required version is $MinPSVersion. Exiting" -severity Eror -avoidStdout:$false
        SubStep-Fail "Validating PowerShell version requirements"
        return 1
    }
    Write-Log -message "PowerShell version $CurPSVersion is supported"
    SubStep-Done "Validating PowerShell version requirements"
    return 0
}
#### Check Powershell version if minimum version provided
if (-Not ([string]::IsNullOrEmpty($minPSVersion) -or ($minPSVersion -eq '{{MIN_PS_VERSION}}'))) {
    Step-Start "Checking PowerShell version"
    $resultCode = Check-PowerShell-Version
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Checking PowerShell version" -ParentStepKey "CHECK_POWERSHELL_VERSION" -SubStepMessage "Validating PowerShell version requirements"
    Step-Done "Checking PowerShell version"
}

#### Create Main directory
$cmd = "New-Item -ItemType ""directory"" -Path ""$MainDirPath"" -ErrorAction SilentlyContinue"
$out = New-Item -ItemType "directory" -Path $MainDirPath -ErrorAction SilentlyContinue 2>&1 | Out-String
Write-Log -message "Executing command: $cmd" -avoidStdout:$true
Write-Log -message "Output: $out" -avoidStdout:$true

# CreateFileToStateWhetherVirtIOWasAlreadyInstalled is a helper function to create a file representing whether the virtIO drivers was being already installed on the source vm
function CreateFileToStateWhetherVirtIOWasAlreadyInstalled {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$value
    )
    # get the biosID to be appended along with the value(true/false) so that the on target vm the cleanup_installation script don't uninstall the virtIO
    $keepVirtIO = $value
    $biosUUID = (Get-WmiObject -Class Win32_ComputerSystemProduct).UUID
    $item1 = "keepVirtIO:$keepVirtIO"
    $item2 = "biosUUID:$biosUUID"

    # Create the directory if it doesn't exist
    if (-not (Test-Path -Path $VirtIODriverUtility)) {
        New-Item -ItemType Directory -Path $VirtIODriverUtility | Out-Null
    }
    Write-Log -message "Writing file ifVirtIOWereInstalled with KeepVirtIO:$keepVirtIO\nbiosUUID:$biosUUID"
    $item1, $item2 | Set-Content -Path $VirtIODriverUtility/ifVirtIOWereInstalled
}

function Execute-ifneeded-WithLog
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$cmd,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Float]$step,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$stepMessage,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [int]$sleepSec = 0
    )

    if ($step -lt $Global:CurrentStep)
    {
        Write-Log "Skipped executing the command: -- $cmd --. CurrentStep: $Global:CurrentStep ; step: $step" -avoidStdout:$true
    }
    else
    {
        Write-Log "Executing the command: -- $cmd --. CurrentStep: $Global:CurrentStep ; step: $step"
        $out = & $cmd 2>&1 | Out-String
        $Global:HasLastStepSucceeded = $?
        Write-Log -message "Output: $out" -avoidStdout:$true
        Start-Sleep -s $sleepSec
        $prefix = "Completed successfully the step <"
        $suffix = ">"
        if (-Not$Global:HasLastStepSucceeded)
        {
            $severity = "Eror"
            $prefix = "Failed to complete the step <"
        }
        $modifiedMessage = "$prefix$message$suffix"
    }
    Write-Log -message $modifiedMessage
}

#### Config access functions
$Global:Config = @{ }
$Global:Config.ScriptVersion = $Global:ScriptVersion
$Global:Config.CurrentStep = $Global:CurrentStep
$Global:Config.XtractIP = $xtractIP

function Get-Config
{
    $Global:Config = Import-Clixml $ConfPath
    $configstr = ($Global:Config.Keys | foreach { "$_ $( $Global:Config[$_] )" }) -join " | "
    Write-Log -message "Global:Config -> $configstr"
}

function Set-Config
{
    $Global:Config | Export-CliXml $ConfPath
}

#### Log the Current direcotry(pwd)
function Log-Current-Dir
{
    $curDir = (Get-Item -Path ".\").FullName
    Write-Log -message "The script's current directory: $curDir" -avoidStdout:$true
}
Log-Current-Dir

# Verify script sanity with the UVM
function Verify-Script-Sanity
{
    SubStep-Start "Verifying script version compatibility"
    # Scriptversion comparison, to verify if the script already ran in the UVM with a different version.
    if ($Global:Config.ScriptVersion -ne $Global:ScriptVersion)
    {
        Write-Log "Detected a mismatch in the script versions, this script's version($Global:ScriptVersion) and config's version($( $Global:Config.ScriptVersion ))" -avoidStdout:$true -severity Warn
    }
    SubStep-Done "Verifying script version compatibility"

    # Verify if the UVM prep-ed with another Xtract-Lite and if so request for cleanup before proceeding.
    try
    {
        SubStep-Start "Verifying Xtract IP consistency"
        if ($Global:Config.XtractIP -ne $xtractIP)
        {
            Write-Log "Detected that the User VM was prepared with another Xtract($( $Global:Config.XtractIP )). Please do a clean-up and then try again." -avoidStdout:$false -severity Eror
            SubStep-Fail "Verifying Xtract IP consistency"
            return 1
        }
        SubStep-Done "Verifying Xtract IP consistency"
    }
    catch
    {
        $errorMessage = $_.Exception.Message
        Write-Log "While verifying Xtract info, got error: ($errorMessage)"
        Get-Config
        Write-Log "Seems the config file format is old and couldn't verify Xtract." -avoidStdout:$true
        SubStep-Fail "Verifying Xtract IP consistency"
        return 1
    }

    SubStep-Start "Checking if installation was previously completed"
    # To verify if installation has completed.
    if ($Global:Config.CurrentStep -eq $Global:LastStep)
    {
        Write-Log "CurrentStep from config file and last step are the same, i.e. ($Global:LastStep). The previous preparation was with script version: ($( $Global:Config.ScriptVersion ))." -avoidStdout:$true
        Write-Log "The script was already used to prepare the User VM. Verifying the previous preparation."
    }
    SubStep-Done "Checking if installation was previously completed"
    return 0
}

try
{
    Get-Config

    Step-Start "Verifying script sanity"
    # Running the function before changing the global values.
    $sanityResult = Verify-Script-Sanity
    if ($sanityResult -ne 0)
    {
        Step-Fail "Verifying script sanity"
    }
    else
    {
        Step-Done "Verifying script sanity"
    }
    #removed  $Global:CurrentStep = $Global:Config.CurrentStep because we want the script to run freshly everytime and not skip any steps
    # Will update the version in config as in the script
    $Global:Config.ScriptVersion = $Global:ScriptVersion
}
catch
{
    Set-Config
    Write-Log "Couldn't find the configuration file in the system, created a new one."
}

#### Debug log for tracking command logs
if ($debugLog)
{
    Set-PSDebug -Trace 1
}
Else
{
    Set-PSDebug -Off
}

# Initialize prep state tracking
Initialize-PrepState

# Main script execution wrapped in try/finally for cleanup
try {

#### UVM system information
$Global:OSInfo = ''
###### Architecture
$osArch = gwmi win32_operatingsystem | select osarchitecture
Write-Log "OS Arch: $osArch"
$Hostname = [System.Net.Dns]::GetHostName()
Write-Log "Hostname: $Hostname"

###### OS Info collector
function Collect-OSInfo
{
    SubStep-Start "Collecting operating system information"
    Write-Log -message "Collecting OS Info." -avoidStdout:$true
    $Global:OSInfo = Get-WmiObject Win32_OperatingSystem | Select-Object Caption, Version, ServicePackMajorVersion, OSArchitecture, CSName, WindowsDirectory
    Write-Log -message "OSInfo: $Global:OSInfo" -avoidStdout:$true
    SubStep-Done "Collecting operating system information"
}
Step-Start "Collecting OS information"
Collect-OSInfo
Step-Done "Collecting OS information"

###### OS Support Verification
$Global:SupportedOSStrings = @("2008", "2008 R2", "2012", "2012 R2", "2016", "2019", "2022", "2025", "Windows 7", "Windows 8", "Windows 10", "Windows 11")
$Global:NoWMICOSStrings = @("2025", "Windows 11")
$SupportedOSMsg = "Supported Windows OSs are Microsoft Windows Server 2008, 2008 R2, 2012, 2012 R2, 2016, 2019, 2022, 2025, Windows 7, 8, 10, 11."

$Global:IsOSSupported = $false
$Global:OSVersion = [System.Version]((Get-WmiObject -class Win32_OperatingSystem).Version)
function Check-OSSupport
{
    SubStep-Start "Checking OS support compatibility"
    Write-Log -message "Checking if the OS is supported." -avoidStdout:$true
    $Global:IsOSSupported = $null -ne ($Global:SupportedOSStrings | ? { $Global:OSInfo.Caption -match $_ })
    if ($Global:IsOSSupported) {
        SubStep-Done "Checking OS support compatibility"
    } else {
        SubStep-Fail "Checking OS support compatibility"
        return 1
    }
}

Step-Start "Checking OS support"
Check-OSSupport
Step-Done "Checking OS support"

Step-Start "Checking if the OS is supported for migration"
if ($Global:IsOSSupported)
{
    Write-Log -message "User VM OS ($( $Global:OSInfo.Caption )) is supported for migration."
}
else
{
    Write-Log -message "User VM OS ($( $Global:OSInfo.Caption )) is not supported for migration. $SupportedOSMsg. Exiting."
    Step-Fail "User VM OS ($( $Global:OSInfo.Caption )) is not supported for migration."
    exit 1
}
Step-Done "Checking if the OS is supported for migration"


Write-Log -message "Checking if the OS includes WMIC" -avoidStdout:$true
$noWMIC = $null -ne ($Global:NoWMICOSStrings | ? { $Global:OSInfo.Caption -match $_ })

function CheckIfVirtIOPreInstalledAndCreateState {
    SubStep-Start "Checking for existing VirtIO installation"
    Write-Log -message "Checking if VirtIO package already installed and drivers present" -avoidStdout:$true
    $cmd = "Get-WmiObject -Class Win32_Product | Where-Object {`$_.Name -like ""*Nutanix VirtIO*""}"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $out = Get-WmiObject -Class Win32_Product | Where-Object {$_.Name -like "*Nutanix VirtIO*"} 2>&1 | Out-String
    if ([string]::IsNullOrEmpty($out))
    {
        Write-Log -message "VirtIO drivers not installed." -avoidStdout:$true
        SubStep-Done "Checking for existing VirtIO installation (not found)"

        SubStep-Start "Creating VirtIO state file (not installed)"
        CreateFileToStateWhetherVirtIOWasAlreadyInstalled -value "false"
        SubStep-Done "Creating VirtIO state file (not installed)"
        return
    }
    Write-Log -message "VirtIO drivers are already installed." -avoidStdout:$true
    SubStep-Done "Checking for existing VirtIO installation (found)"

    # create a file under the directory VirtIODriverIfPresent with content as true to reflect the state of virtIO drivers being already present on the source vm
    SubStep-Start "Creating VirtIO state file (already installed)"
    CreateFileToStateWhetherVirtIOWasAlreadyInstalled -value "true"
    SubStep-Done "Creating VirtIO state file (already installed)"
    return
}


# executing the function to create virtIO state file
Step-Start "Checking if VirtIO was already installed and creating state file"
CheckIfVirtIOPreInstalledAndCreateState
Step-Done "Checking if VirtIO was already installed and creating state file"


###### Check if VirtIO installed, cache previous installation and
###### set 'IsVirtIOInstalledAndDriversPresent' flag
function Check-VirtIOInstalled
{
    SubStep-Start "Checking VirtIO package installation status"
    Write-Log -message "Checking if VirtIO package already installed and drivers present" -avoidStdout:$true
    $cmd = "Get-WmiObject -Class Win32_Product | Where-Object {`$_.Name -like ""*Nutanix VirtIO*"" -and `$_.Version -eq ""$virtIOVersion""}"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $Global:PreviousVirtIOInstallation = Get-WmiObject -Class Win32_Product | Where-Object {$_.Name -like "*Nutanix VirtIO*" -and $_.Version -eq "$virtIOVersion"} 2>&1
    $out = $Global:PreviousVirtIOInstallation | Out-String
    Write-Log -message "Output: $out" -avoidStdout:$true
    if ([string]::IsNullOrEmpty($out))
    {
        Write-Log -message "VirtIO drivers not installed. Setting 'IsVirtIOInstalledAndDriversPresent' to false" -avoidStdout:$true
        $Global:IsVirtIOInstalledAndDriversPresent = $false
        SubStep-Done "Checking VirtIO package installation status (not installed)"
        return
    }
    SubStep-Done "Checking VirtIO package installation status (package found)"

    SubStep-Start "Verifying all VirtIO drivers are present"
    Write-Log -message "Checking if all VirtIO drivers are present" -avoidStdout:$true
    foreach ($driverName in $Global:VirtIODriverInfNames)
    {
        $cmd = "Get-WindowsDriver -Online | Where-Object {`$_.OriginalFileName -like ""*$driverName"" -and `$_.ProviderName -like ""*Nutanix*"" -and `$_.Version -eq ""$virtIOVersion""} | Out-String"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $out = Get-WindowsDriver -Online | Where-Object {$_.OriginalFileName -like "*$driverName" -and $_.ProviderName -like "*Nutanix*" -and $_.Version -eq "$virtIOVersion"} 2>&1 | Out-String
        Write-Log -message "Output: $out" -avoidStdout:$true
        if ([string]::IsNullOrEmpty($out))
        {
            Write-Log -message "VirtIO driver '$driverName' is not present. Setting 'IsVirtIOInstalledAndDriversPresent' to false" -avoidStdout:$true
            $Global:IsVirtIOInstalledAndDriversPresent = $false
            # Marking the Sub-Step done as we are exiting the function here
            SubStep-Done "Verifying all VirtIO drivers are present"
            return
        }
    }
    Write-Log -message "VirtIO drivers are already installed. Setting 'IsVirtIOInstalledAndDriversPresent' to true" -avoidStdout:$true
    $Global:IsVirtIOInstalledAndDriversPresent = $true
    $installVirtio = $false
    if ($installVirtio -and $Global:IsVirtIOInstalledAndDriversPresent)
    {
        # because of the flag installVirtio the total steps would have been incremented by 1, so decrementing it here as we will skip the installation
        $Global:TotalSteps--
    }
    SubStep-Done "Verifying all VirtIO drivers are present"
    return
}

###### Virtio configuration
if ($installVirtio)
{
    Step-Start "Checking VirtIO installation status"
    Check-VirtIOInstalled
    $webVirtioFilePath32Bit = "$Global:BaseUrl/resources/Nutanix-VirtIO-latest-stable-x86.msi"
    $webVirtioFilePath64Bit = "$Global:BaseUrl/resources/Nutanix-VirtIO-latest-stable.msi"
    $destinationVirtioDirectoryPath = Join-Path $destinationDirPath -ChildPath 'virtio'
    $virtioInstaller32Bit = Join-Path $destinationVirtioDirectoryPath -ChildPath 'Nutanix-VirtIO-latest-stable-x86.msi'
    $virtioInstaller64Bit = Join-Path $destinationVirtioDirectoryPath -ChildPath 'Nutanix-VirtIO-latest-stable.msi'
    $virtioInstallerArgs = "/quiet"
}

# Calculate total steps based on script arguments AFTER VirtIO check
Calculate-TotalSteps


# Check and run cleanup script if it exists from previous installation
Step-Start "Checking cleanup prerequisite" "CHECK_CLEANUP_PREREQUISITE"
$resultCode = Invoke-CleanupIfExists
Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Checking cleanup prerequisite" -ParentStepKey "CHECK_CLEANUP_PREREQUISITE" -SubStepMessage "Running cleanup script if exists"
Step-Done "Checking cleanup prerequisite" "CHECK_CLEANUP_PREREQUISITE"


######## SAN Policy script configuration
if ($setSanPolicy)
{
    $webSANPolicyScriptPath = "$Global:BaseUrl/resources/setSANPolicy.bat"
    $SANPolicyScriptPath = Join-Path $ScriptsDirPath -ChildPath 'setSANPolicy.bat'
}

######## Cleanup script configuration
$webCleanupScriptPath = "$Global:BaseUrl/resources/scripts/win/cleanup_installation.ps1"
$CleanupScriptPath = Join-Path $UninstallScriptsPath -ChildPath "cleanup_installation.ps1"

######## Retain IP script configuration
$webRetainIpScriptPath = "$Global:BaseUrl/resources/scripts/win/RetainIP.ps1"
$RetainIpScriptPath = Join-Path $ScriptsDirPath -ChildPath 'RetainIP.ps1'
$webWmiNetUtilFilePath = "$Global:BaseUrl/resources/wmi-net-util.exe"
$WmiNetUtilFilePath = Join-Path $DownloadDirPath -ChildPath 'wmi-net-util.exe'
$webNetUtilFilePath = "$Global:BaseUrl/resources/net-util.exe"
$NetUtilFilePath = Join-Path $DownloadDirPath -ChildPath 'net-util.exe'

######## Uninstall VMware Tools script configuration
$webUninstallVMwareToolsScriptPath = "$Global:BaseUrl/resources/scripts/win/UninstallVMwareTools.ps1"
$UninstallVMwareToolsScriptPath = Join-Path $ScriptsDirPath -ChildPath 'UninstallVMwareTools.ps1'

######## Install NGT script configuration
$webInstallNGTScriptPath = "$Global:BaseUrl/resources/scripts/win/InstallNGT.ps1"
$InstallNGTScriptPath = Join-Path $ScriptsDirPath -ChildPath 'InstallNGT.ps1'

######## Schedule nutanix move script configuration
$webNutanixMoveScriptPath = "$Global:BaseUrl/resources/scripts/win/NutanixMove.bat"
$NutanixMoveScriptPath = Join-Path $ScriptsDirPath -ChildPath "NutanixMove.bat"
$webNutanixMoveConfigurationOnStartConfigPath = "$Global:BaseUrl/resources/scripts/win/TaskNutanixMoveOnStartConfig.xml"
$NutanixMoveConfigurationOnStartConfigPath = Join-Path $ScriptsDirPath -ChildPath 'TaskNutanixMoveOnStartConfig.xml'

######## Retain disabled IP config script configuration
$webRetainDisabledIPConfigScriptPath = "$Global:BaseUrl/resources/scripts/win/RetainDisabledIPConfigurations.ps1"
$RetainDisabledIPConfigScriptPath = Join-Path $ScriptsDirPath -ChildPath 'RetainDisabledIPConfigurations.ps1'

######## manual preparation validation script configuration
$webManualPrepValidationScriptPath = "$Global:BaseUrl/resources/uvm/win/validate_prep_state.ps1"
$ManualPrepValidationScriptPath = Join-Path $NXBaseDir -ChildPath 'validate_prep_state.ps1'

######## Disable IPv6 script configuration
$webDisableIPv6ScriptPath = "$Global:BaseUrl/resources/scripts/win/DisableIPv6.ps1"
$DisableIPv6ScriptPath = Join-Path $ScriptsDirPath -ChildPath 'DisableIPv6.ps1'

#### Create Directory Function
function Create-Directory
{
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$path,

        [Parameter()]
        [string]$itemType = "directory",

        [Parameter()]
        [string]$errorActions = "SilentlyContinue",

        [Parameter()]
        [switch]$avoidStdout = $true
    )

    SubStep-Start "Creating directory: $path"
    $cmd = "New-Item -ItemType ""$itemType"" -Path $path -ErrorAction $errorActions"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$avoidStdout
    $out = New-Item -ItemType "$itemType" -Path $path -ErrorAction $errorActions 2>&1 | Out-String
    Write-Log -message "Output: $out" -avoidStdout:$avoidStdout
    SubStep-Done "Creating directory: $path"
}

Step-Start "Creating required directories" "PREPARE_DIRECTORIES"
Write-Log "Creating required directories"
#### Create required directories
Create-Directory -path $MainDirPath
Create-Directory -path $ScriptsDirPath
Create-Directory -path $UninstallScriptsPath
if ($installVirtio)
{
    Create-Directory -path $destinationVirtioDirectoryPath

    Write-Log "Selecting required files to be downloaded to User VM."
    #### Select download file based on architecture
    $arch64 = @("64")
    $arch32 = @("32")
    if ($arch64 | ? { $osArch.osarchitecture -match $_ })
    {
        ###### virtio
        Write-Log "Found 64-bit OS Architecture"
        $virtioInstaller = $virtioInstaller64Bit
        $webVirtioFilePath = $webVirtioFilePath64Bit
    }
    elseif ($arch32 | ? { $osArch.osarchitecture -match $_ })
    {
        ###### virtio
        Write-Log "Found 32-bit OS Architecture"
        $virtioInstaller = $virtioInstaller32Bit
        $webVirtioFilePath = $webVirtioFilePath32Bit
    }
}
Step-Done "Creating required directories" "PREPARE_DIRECTORIES"

#### Download File Function
function Download-Artifact {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$fromLocation,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$toLocation,

        [Parameter()]
        [string]$artifactName = "",

        [Parameter()]
        [switch]$avoidStdout = $true
    )

    if ([string]::IsNullOrEmpty($artifactName)) {
        $artifactName = Split-Path $toLocation -Leaf
    }

    SubStep-Start "Downloading $artifactName"
    $cmd = "$Global:WebClient.DownloadFile($fromLocation, $toLocation)"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$avoidStdout
    $retryCount = 5
    do {
        try {
            $Global:WebClient.DownloadFile($fromLocation, $toLocation)
        } catch [Net.WebException] {
            $excStr = $_.Exception.ToString()
            Write-Log -message "Got error while downloading. Exception: $excStr"
        }

        if(Test-Path -Path $toLocation) {
            SubStep-Done "Downloading $artifactName"
            return 0
        } else {
            Start-sleep -Seconds 5
            Write-Log "Retry download.... $fromLocation. Retries left: $retryCount." -avoidStdout:$false
        }
    } while ($retryCount--)

    SubStep-Fail "Downloading $artifactName"
    Write-Log -message "Failed to download artifact: $fromLocation" -severity Eror
    return 1
}

#### Download files from Xtract appliance
$stepNum = 1
if ($stepNum -le $Global:CurrentStep) {
    Write-Log "Skipped download of various artifacts as the step was already executed." -avoidStdout:$true
    Write-Log "StepNum: $stepNum CurrentStep: $Global:CurrentStep." -avoidStdout:$true
} else {
    Step-Start "Downloading required artifacts" "DOWNLOAD_ARTIFACTS"
    Write-Log "Starting to download various artifacts."

    ###### download scripts
    if ($setSanPolicy) {
        ######## download SAN Policy script
        $cmd = "Download-Artifact -fromLocation $webSANPolicyScriptPath -toLocation $SANPolicyScriptPath"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webSANPolicyScriptPath -toLocation $SANPolicyScriptPath -artifactName "SAN Policy script"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - SAN Policy Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading SAN Policy script"
    }

    ######## download cleanup script
    $cmd = "Download-Artifact -fromLocation $webCleanupScriptPath -toLocation $CleanupScriptPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $resultCode = Download-Artifact -fromLocation $webCleanupScriptPath -toLocation $CleanupScriptPath -artifactName "cleanup script"
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Cleanup Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading cleanup script"

    ######## download nutanix move script
    $cmd = "Download-Artifact -fromLocation $webNutanixMoveScriptPath -toLocation $NutanixMoveScriptPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $resultCode = Download-Artifact -fromLocation $webNutanixMoveScriptPath -toLocation $NutanixMoveScriptPath -artifactName "Nutanix Move script"
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Nutanix Move Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Nutanix Move script"

    ######## download nutanix move on start config
    $cmd = "Download-Artifact -fromLocation $webNutanixMoveConfigurationOnStartConfigPath -toLocation $NutanixMoveConfigurationOnStartConfigPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $resultCode = Download-Artifact -fromLocation $webNutanixMoveConfigurationOnStartConfigPath -toLocation $NutanixMoveConfigurationOnStartConfigPath -artifactName "Nutanix Move configuration"
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Nutanix Move Configuration" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Nutanix Move configuration"

    ######## download retain ipv6 disabled config script
    $cmd = "Download-Artifact -fromLocation $webRetainDisabledIPConfigScriptPath -toLocation $RetainDisabledIPConfigScriptPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $resultCode = Download-Artifact -fromLocation $webRetainDisabledIPConfigScriptPath -toLocation $RetainDisabledIPConfigScriptPath -artifactName "retain disabled IP config script"
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Retain Disabled IP Config Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Retain Disabled IP Config script"

    ######## download manual prep validation script
    $cmd = "Download-Artifact -fromLocation $webManualPrepValidationScriptPath -toLocation $ManualPrepValidationScriptPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $resultCode = Download-Artifact -fromLocation $webManualPrepValidationScriptPath -toLocation $ManualPrepValidationScriptPath -artifactName "manual prep validation script"
    Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Manual Prep Validation Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Manual Prep Validation Script"

    if($retainIP -eq $true) {
        ######## download retainIP script
        $cmd = "Download-Artifact -fromLocation $webRetainIpScriptPath -toLocation $RetainIpScriptPath"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webRetainIpScriptPath -toLocation $RetainIpScriptPath -artifactName "retain IP script"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Retain IP Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Retain IP script"

       if ($noWMIC) {
            $cmd = "Download-Artifact -fromLocation $webNetUtilFilePath -toLocation $NetUtilFilePath"
            Write-Log -message "Executing command: $cmd" -avoidStdout:$true
            $resultCode = Download-Artifact -fromLocation $webNetUtilFilePath -toLocation $NetUtilFilePath
            Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - NetUtil" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading NetUtil"
        } else {
            $cmd = "Download-Artifact -fromLocation $webWmiNetUtilFilePath -toLocation $WmiNetUtilFilePath"
            Write-Log -message "Executing command: $cmd" -avoidStdout:$true
            $resultCode = Download-Artifact -fromLocation $webWmiNetUtilFilePath -toLocation $WmiNetUtilFilePath
            Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - WmiNetUtil" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading WmiNetUtil"
        }

    } else {
        ######## download disable ipv6 script
        $cmd = "Download-Artifact -fromLocation $webDisableIPv6ScriptPath -toLocation $DisableIPv6ScriptPath"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webDisableIPv6ScriptPath -toLocation $DisableIPv6ScriptPath -artifactName "disable IPv6 script"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Disable IPv6 Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Disable IPv6 script"
    }

    if ($installVirtio) {
        ###### download Virtio artifact
        $cmd = "Download-Artifact -fromLocation $webVirtioFilePath -toLocation $virtioInstaller"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webVirtioFilePath -toLocation $virtioInstaller -artifactName "VirtIO drivers"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - VirtIO Drivers" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading VirtIO drivers"
        Write-Log "Downloaded Virtio artifact."
    }

    if($uninstallVMwareTools -eq $true) {
        ######## download uninstallVMwareTools script
        $cmd = "Download-Artifact -fromLocation $webUninstallVMwareToolsScriptPath -toLocation $UninstallVMwareToolsScriptPath"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webUninstallVMwareToolsScriptPath -toLocation $UninstallVMwareToolsScriptPath -artifactName "uninstall VMware Tools script"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Uninstall VMware Tools Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Uninstall VMware Tools script"
    }

    if($installNgt -eq $true) {
        ######## download install ngt script
        $cmd = "Download-Artifact -fromLocation $webInstallNGTScriptPath -toLocation $InstallNGTScriptPath"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $resultCode = Download-Artifact -fromLocation $webInstallNGTScriptPath -toLocation $InstallNGTScriptPath -artifactName "install NGT script"
        Assert-LastCommandSuccess -ExitCode $resultCode -ParentStepMessage "Downloading required artifacts - Install NGT Script" -ParentStepKey "DOWNLOAD_ARTIFACTS" -SubStepMessage "Downloading Install NGT script"
    }

    $Global:Config.CurrentStep = $stepNum
    Set-Config
    Step-Done "Downloading required artifacts" "DOWNLOAD_ARTIFACTS"
}

###### Installing virtio
$stepNum = 2
if ((-Not $installVirtio) -Or $Global:IsVirtIOInstalledAndDriversPresent) {
    Write-Log "Skipped Virtio installation as the step was already executed or installVirtio flag was false." -avoidStdout:$true
    Write-Log "StepNum: $stepNum CurrentStep: $Global:CurrentStep." -avoidStdout:$true
} else {
    Step-Start "Installing VirtIO drivers" "INSTALL_VIRTIO_DRIVERS"

    ###### if 'Global:PreviousVirtIOInstallation' is populated at this step
    ###### it means previous installation is present with missing drivers
    if ($Global:PreviousVirtIOInstallation)
    {
        SubStep-Start "Uninstalling previous VirtIO installation with missing drivers"
        Write-Log "Uninstalling previous installation of VirtIO with missing drivers"
        $cmd = "`$Global:PreviousVirtIOInstallation.Uninstall()"
        Write-Log -message "Executing command: $cmd" -avoidStdout:$true
        $uninstallOutput = $Global:PreviousVirtIOInstallation.Uninstall() 2>&1
        $Global:HasLastStepSucceeded = $?
        $out = $uninstallOutput | Out-String
        Write-Log -message "Output: $out" -avoidStdout:$true
        if ((-Not $Global:HasLastStepSucceeded) -Or ($uninstallOutput.ReturnValue -ne 0))
        {
            $Local:errMsg = "Failed to uninstall previous installation of Nutanix VirtIO drivers. Please remove it manually."
            Write-Log -message "$Local:errMsg" -severity Eror -avoidStdout:$false
            SubStep-Fail "Uninstalling previous VirtIO installation with missing drivers"
            Assert-LastCommandSuccess -ExitCode 1 -ParentStepMessage "Installing VirtIO drivers" -ParentStepKey "INSTALL_VIRTIO_DRIVERS" -SubStepMessage "Uninstalling previous VirtIO installation with missing drivers"
        }
        SubStep-Done "Uninstalling previous VirtIO installation with missing drivers"
    }

    SubStep-Start "Installing VirtIO drivers package"
    Write-Log "Installing Virtio drivers"

    $cmd = "$virtioInstaller $virtioInstallerArgs"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $out = & $virtioInstaller $virtioInstallerArgs 2>&1
    $Global:HasLastStepSucceeded = $?
    Write-Log -message "Output: $out" -avoidStdout:$true

    SubStep-Start "Verifying VirtIO driver installation"
    $virtioRepSleepSec = 10
    $startRunTime = Get-Date
    $virtioInstalled = $false
    while ((Get-Date)- $startRunTime -lt $Global:VirtioInstallationTimeOutPeriod)
    {
        Start-Sleep -s $virtioRepSleepSec
        if ($noWMIC) {
            Get-CimInstance -ClassName Win32_Product | Select-Object -ExpandProperty Name | Out-String | findstr /c:"Nutanix VirtIO"
        } else {
            wmic product where "Name like 'Nutanix VirtIO'" get Name 2>&1 | Out-String | findstr /c:"Nutanix VirtIO"
        }
        $virtioInstalled = $?
        if ($virtioInstalled) {
            break
        }
    }
    $Global:HasLastStepSucceeded = ($Global:HasLastStepSucceeded) -and ($virtioInstalled)
    if ($Global:HasLastStepSucceeded) {
        SubStep-Done "Installing VirtIO drivers package"
        SubStep-Done "Verifying VirtIO driver installation"
        Write-Log "Virtio drivers installation completed successfully"
        Step-Done "Installing VirtIO drivers" "INSTALL_VIRTIO_DRIVERS"
        $Global:Config.CurrentStep = $stepNum
        Set-Config
    } else {
        SubStep-Fail "Installing VirtIO drivers package"
        $oldOSVersion = @("2008 R2", "Windows 7")
        if ($null -ne ($oldOSVersion | ? { $Global:OSInfo.Caption -match $_ }))
        {
            Write-Log "Check if OS is SHA2 compatible." -avoidStdout:$false -severity Eror
        }
        Write-Log "Failed to install VirtIO drivers. This would impact migrated VM's network connectivity in AHV cluster." -avoidStdout:$true -severity Eror
        Write-Host "Failed to install VirtIO drivers. This would impact migrated VM's network connectivity in AHV cluster." -ForegroundColor Red
        Assert-LastCommandSuccess -ExitCode 1 -ParentStepMessage "Installing VirtIO drivers" -ParentStepKey "INSTALL_VIRTIO_DRIVERS" -SubStepMessage "Installing VirtIO drivers package"
    }
}

$stepNum = 3
#https://docs.microsoft.com/en-us/powershell/module/storage/set-storagesetting
try {
    $out = Get-StorageSetting 2>&1 | Out-String
    Write-Log -message "Current Storage Settings: $out" -avoidStdout:$true
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Log -message "Get-StorageSetting command failed with message: ($errorMessage)" -avoidStdout:$true
}

if ($stepNum -le $Global:CurrentStep -Or -Not $setSanPolicy ) {
    Write-Log "Skipped applying SAN Policy as the step was already executed or setSanPolicy flag was false." -avoidStdout:$true
    Write-Log "StepNum: $stepNum CurrentStep: $Global:CurrentStep." -avoidStdout:$true
} else {
    Step-Start "Applying SAN Policy" "SET_SAN_POLICY"

    SubStep-Start "Executing SAN Policy configuration script"
    $cmd = "$SANPolicyScriptPath"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $out = & $SANPolicyScriptPath 2>&1 | Out-String
    $Global:HasLastStepSucceeded = $?
    Write-Log -message "Output: $out" -avoidStdout:$true
    if ($Global:HasLastStepSucceeded) {
        SubStep-Done "Executing SAN Policy configuration script"
        Write-Log "Applied SAN Policy."
        Step-Done "Applying SAN Policy" "SET_SAN_POLICY"
        $Global:Config.CurrentStep = $stepNum
        Set-Config
    } else {
        SubStep-Fail "Executing SAN Policy configuration script"
        Write-Log "Failed to apply SAN Policy."
        Assert-LastCommandSuccess -ExitCode 1 -ParentStepMessage "Applying SAN Policy" -ParentStepKey "SET_SAN_POLICY" -SubStepMessage "Executing SAN Policy configuration script"
    }
}

$stepNum = 4
if (Test-Path $RetainIPResultPath) {
    Remove-item $RetainIPResultPath
}
if (Test-Path $NutanixMoveResultPath) {
    Remove-item $NutanixMoveResultPath
}
Write-Log -message "Scheduling Nutanix Move task for retainIP, uninstallVMwareTools, installNgt and cleanup on target User VM after first boot" -avoidStdout:$true
if ($stepNum -le $Global:CurrentStep) {
    Write-Log "Skipped scheduling target User VM Nutanix Move task as the step was already executed." -avoidStdout:$true
    Write-Log "StepNum: $stepNum CurrentStep: $Global:CurrentStep." -avoidStdout:$true
} else {
    Step-Start "Scheduling Nutanix Move task" "SCHEDULE_MOVE_SERVICE"

    SubStep-Start "Configuring Nutanix Move task arguments"
    $cmd = "cmd.exe /c ""$NutanixMoveScriptPath --xml $NutanixMoveConfigurationOnStartConfigPath --cleanup $CleanupScriptPath --retain-disabled-ip-config $RetainDisabledIPConfigScriptPath "
    if ($retainIP -eq $true) {
        if ($noWMIC) {
            $cmd = $cmd + " --retain-ip $RetainIpScriptPath $NetUtilFilePath"
        } else {
            $cmd = $cmd + " --retain-ip $RetainIpScriptPath $WmiNetUtilFilePath"
        }
    } else {
        # For DHCP option, disable IPv6 for all nics
        $cmd = $cmd + " --disable-ipv6 $DisableIPv6ScriptPath"
    }
    if ($uninstallVMwareTools -eq $true) {
        $cmd = $cmd + " --uninstall-vmware-tools $UninstallVMwareToolsScriptPath"
    }
    if ($installNgt -eq $true) {
        $cmd = $cmd + " --install-ngt $InstallNGTScriptPath"
    }
    if ($noWMIC) {
        $cmd = $cmd + " --no-wmic"
    }
    $cmd = $cmd + """"
    SubStep-Done "Configuring Nutanix Move task arguments"

    SubStep-Start "Executing Nutanix Move task scheduling"
    Write-Log -message "Executing command: $cmd" -avoidStdout:$true
    $out = Invoke-Expression $cmd 2>&1 | Out-String
    $Global:HasLastStepSucceeded = ($LASTEXITCODE -eq 0)
    Write-Log -message "ExitCode: $Global:HasLastStepSucceeded" -avoidStdout:$true
    Write-Log -message "Output: $out" -avoidStdout:$true
    if ($Global:HasLastStepSucceeded) {
        SubStep-Done "Executing Nutanix Move task scheduling"
        Write-Log "Scheduled target User VM Nutanix Move task."
        Step-Done "Scheduling Nutanix Move task" "SCHEDULE_MOVE_SERVICE"
        $Global:Config.CurrentStep = $stepNum
        Set-Config

        # Update overall state to Success when all steps complete successfully
        Update-OverallState -Status "Success"

        # Show final prep state
        Write-Host "`n=== FINAL PREPARATION STATE ===" -ForegroundColor Green
        Show-PrepState
    } else {
        SubStep-Fail "Executing Nutanix Move task scheduling"
        Write-Log "Failure in scheduling target User VM Nutanix Move task."
        Assert-LastCommandSuccess -ExitCode 1 -ParentStepMessage "Scheduling Nutanix Move task" -ParentStepKey "SCHEDULE_MOVE_SERVICE" -SubStepMessage "Executing Nutanix Move task scheduling"
    }
}

} finally {
    # Ensure cleanup happens on any exit/interruption
    Cleanup-PrepStateOnExit
}
