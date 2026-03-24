<#
Minimal validator for Windows prep_state file produced by esx_setup_uvm.ps1
Usage:
    # Explicit path
    powershell.exe -ExecutionPolicy Bypass -File .\validate_preparation.ps1 -Path C:\Nutanix\prep_state.txt
    # Or rely on default path C:\Nutanix\prep_state.txt
    powershell.exe -ExecutionPolicy Bypass -File .\validate_preparation.ps1
Exit Codes:
 0 = Success
 1 = File / argument error
 2 = OVERALL_STATE not Success
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$Path = 'C:\\Nutanix\\prep_state.txt'
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "prep_state file not found: $Path" -ForegroundColor Red
    Write-Host "(Provide -Path to override default if needed)" -ForegroundColor Yellow
    exit 1
}

# Read file, find last non-comment OVERALL_STATE line
try {
    $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
} catch {
    Write-Host "Failed to read file: $Path : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$overallLine = ($lines | Where-Object {$_ -match '^OVERALL_STATE='}) | Select-Object -Last 1
if (-not $overallLine) {
    Write-Host "OVERALL_STATE not found in file: $Path" -ForegroundColor Yellow
    exit 2
}

$state = $overallLine.Substring('OVERALL_STATE='.Length)

switch -Regex ($state) {
    '^Success$'       { Write-Host "OVERALL_STATE: "  -NoNewline 
    Write-Host "$state" -ForegroundColor Green; exit 0 }
    '^(Failed|Failure)$' { Write-Host "OVERALL_STATE: "  -NoNewline
    Write-Host "$state" -ForegroundColor Red; exit 2 }
    '^(Interrupted|InProgress)$' { Write-Host "OVERALL_STATE: "  -NoNewline
    Write-Host "$state" -ForegroundColor Yellow; exit 2 }
    default { Write-Host "OVERALL_STATE: $state"; exit 2 }
}
