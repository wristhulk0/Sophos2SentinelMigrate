#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Uninstalls Sophos via SophosZap and installs SentinelOne on student machines.

.DESCRIPTION
    1. Adds STISD\symantec.backupexec to the local Administrators group
    2. Copies SophosZap locally, then runs it under STISD\symantec.backupexec credentials
    3. Removes STISD\symantec.backupexec from local Administrators (cleanup)
    4. Launches the SentinelOne 64-bit installer with the token open in Notepad for reference

.NOTES
    Run this script as a local or domain admin on each student machine.
    Student machines are on mystisd.stisd.net domain.
#>

$LogFile = "C:\Temp\sophos_migration_log.txt"
$SophosZapSrc  = "\\10.4.14.101\HP\sophos\sophoszap.exe"
$SophosZapDest = "C:\Temp\sophoszap.exe"
$S1Base        = "Y:\District_software\Network Stuff - Cesar\SentinelONE\Windows 64-bit"
$S1Exe         = "$S1Base\SentinelOneInstaller_windows_64bit_v25_1_4_434.exe"
$S1TokenSrc    = "$S1Base\token.txt"
$S1TokenLocal  = "C:\Temp\s1_token.txt"
$BackupExecAcct = "STISD\symantec.backupexec"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp][$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

# Ensure C:\Temp exists
if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" | Out-Null
}

Write-Log "=== Sophos Removal / SentinelOne Installation ==="
Write-Log "Computer: $env:COMPUTERNAME"

# ------------------------------------------------------------------------------
# Step 1: Authenticate to the network share
# ------------------------------------------------------------------------------
Write-Log "Connecting to network share..."
$shareResult = net use \\10.4.14.101\IPC$ /user: 2>&1
# If already connected this is a no-op; errors are non-fatal
Write-Log "Share connection result: $shareResult"

# ------------------------------------------------------------------------------
# Step 2: Add STISD\symantec.backupexec to local Administrators
# ------------------------------------------------------------------------------
Write-Log "Adding $BackupExecAcct to local Administrators..."
$addOutput = net localgroup Administrators $BackupExecAcct /add 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Log "$BackupExecAcct added to local Administrators."
} elseif ($addOutput -match "already a member") {
    Write-Log "$BackupExecAcct is already a member of local Administrators."
} else {
    Write-Log "Unexpected result adding $BackupExecAcct`: $addOutput" "WARN"
}

# ------------------------------------------------------------------------------
# Step 3: Copy SophosZap locally so it's accessible when running as another user
# ------------------------------------------------------------------------------
Write-Log "Copying SophosZap to $SophosZapDest..."
try {
    Copy-Item -Path $SophosZapSrc -Destination $SophosZapDest -Force
    Write-Log "SophosZap copied."
} catch {
    Write-Log "Failed to copy SophosZap: $_" "ERROR"
    Write-Host ""
    Write-Host "ERROR: Could not copy SophosZap from $SophosZapSrc" -ForegroundColor Red
    Write-Host "Verify the share is reachable and you have access." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# ------------------------------------------------------------------------------
# Step 4: Prompt for symantec.backupexec credentials, then run SophosZap
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "Enter the password for $BackupExecAcct when prompted." -ForegroundColor Cyan
Write-Host "SophosZap requires Backup Operator / local admin privileges to run." -ForegroundColor Cyan
Write-Host ""

$zapCred = Get-Credential -Message "Credentials to run SophosZap (must be $BackupExecAcct)" -UserName $BackupExecAcct

Write-Log "Running SophosZap --confirm as $BackupExecAcct..."
try {
    $proc = Start-Process -FilePath $SophosZapDest `
        -ArgumentList "--confirm" `
        -Credential $zapCred `
        -Wait `
        -PassThru

    if ($proc.ExitCode -eq 0) {
        Write-Log "SophosZap completed successfully (exit code 0)."
    } else {
        Write-Log "SophosZap finished with exit code $($proc.ExitCode)." "WARN"
    }
} catch {
    Write-Log "SophosZap failed to launch: $_" "ERROR"
    Write-Host "SophosZap failed. See log for details." -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# Step 5: Remove STISD\symantec.backupexec from local Administrators (cleanup)
# ------------------------------------------------------------------------------
Write-Log "Removing $BackupExecAcct from local Administrators..."
$removeOutput = net localgroup Administrators $BackupExecAcct /delete 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Log "$BackupExecAcct removed from local Administrators."
} else {
    Write-Log "Remove result: $removeOutput" "WARN"
}

# Clean up local SophosZap copy
Remove-Item -Path $SophosZapDest -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# Step 6: Install SentinelOne (64-bit)
# ------------------------------------------------------------------------------
Write-Log "Preparing SentinelOne installation..."
try {
    Copy-Item -Path $S1TokenSrc -Destination $S1TokenLocal -Force
    Start-Process "notepad.exe" -ArgumentList $S1TokenLocal
    Write-Log "Token file opened in Notepad for reference."
} catch {
    Write-Log "Could not open token file: $_" "WARN"
    Write-Host "WARNING: Could not open token file from $S1TokenSrc" -ForegroundColor Yellow
    Write-Host "You will need to enter the SentinelOne token manually." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Launching SentinelOne installer. Use the token shown in Notepad." -ForegroundColor Cyan
Write-Host ""

try {
    Start-Process -FilePath $S1Exe
    Write-Log "SentinelOne installer launched: $S1Exe"
} catch {
    Write-Log "SentinelOne installer launch FAILED: $_" "ERROR"
    Write-Host "ERROR: Could not launch SentinelOne installer." -ForegroundColor Red
    Write-Host "Path: $S1Exe" -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
Write-Log "=== Script complete. Review full log at $LogFile ==="
Write-Host ""
Write-Host "All steps complete. Complete the SentinelOne GUI installation manually." -ForegroundColor Green
Read-Host "Press Enter to exit"
