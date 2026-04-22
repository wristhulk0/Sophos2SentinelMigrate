<#
.SYNOPSIS
    Remotely removes Sophos (via SophosZap) and installs SentinelOne on student machines.

.DESCRIPTION
    Runs entirely over existing PSRemoting sessions using your current logged-in identity
    (stisd\mark.moran). Only the symantec.backupexec password is required.

    Flow per machine:
      1. Push SophosZap from \\10.4.14.101 to remote C:\Temp (via session, no double-hop)
      2. Push SentinelOne installer to remote C:\Temp (same approach)
      3. Add STISD\symantec.backupexec to local Administrators
      4. Run SophosZap --confirm as STISD\symantec.backupexec
      5. Verify no Sophos services remain running
      6. Remove STISD\symantec.backupexec from local Administrators
      7. Install SentinelOne silently ONLY if Sophos was cleanly removed
      8. Clean up

.PARAMETER ComputerName
    One or more student machine hostnames or FQDNs.

.PARAMETER Lab318
    Auto-generates the full 04hslab318s series (001-024, skipping 002 and 004).
    Machines are processed one at a time in order.

.EXAMPLE
    # Test on machine 003 first
    .\Invoke-SophosToS1.ps1 -ComputerName 04hslab318s003.mystisd.stisd.net

.EXAMPLE
    # Full lab run after testing
    .\Invoke-SophosToS1.ps1 -Lab318
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string[]]$ComputerName,

    [Parameter(Mandatory, ParameterSetName = 'Lab318')]
    [switch]$Lab318
)

$Domain = "mystisd.stisd.net"

if ($Lab318) {
    $ComputerName = 1..24 |
        Where-Object { $_ -notin 2, 4 } |
        ForEach-Object { "04hslab318s{0:D3}.$Domain" -f $_ }

    Write-Host "Lab318 series - $($ComputerName.Count) machines:" -ForegroundColor Cyan
    $ComputerName | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

# --- Paths on the tech machine (mark.moran has access) ---
$SophosZapSharePath = "\\10.4.14.101\HP\sophosinstall\sophoszap.exe"
$S1InstallerShare   = "\\10.4.14.101\district_software\District_software\Network Stuff - Cesar\SentinelONE\Windows 64-bit\SentinelOneInstaller_windows_64bit_v25_1_4_434.exe"
$S1TokenShare       = "\\10.4.14.101\district_software\District_software\Network Stuff - Cesar\SentinelONE\Windows 64-bit\token.txt"

# --- Load .env if present ---
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+?)\s*=\s*(.*)\s*$') {
            [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
        }
    }
    Write-Host "Loaded credentials from .env" -ForegroundColor DarkGray
}

# --- Only credential needed: symantec.backupexec (to run SophosZap) ---
Write-Host ""
Write-Host "=== Sophos -> SentinelOne Remote Migration ===" -ForegroundColor Cyan
Write-Host "Running as: $env:USERDOMAIN\$env:USERNAME"
Write-Host "Targets:    $($ComputerName -join ', ')"
Write-Host ""

$zapUser = [Environment]::GetEnvironmentVariable("ZAP_USER")
$zapPass = [Environment]::GetEnvironmentVariable("ZAP_PASS")

if ($zapUser -and $zapPass) {
    $zapCred = New-Object PSCredential($zapUser, (ConvertTo-SecureString $zapPass -AsPlainText -Force))
    Write-Host "symantec.backupexec credentials loaded from .env" -ForegroundColor DarkGray
} else {
    $zapCred = Get-Credential -Message "Enter password for STISD\symantec.backupexec (needed to run SophosZap)" `
                              -UserName "STISD\symantec.backupexec"
}

# --- Stage files locally on the tech machine (single-hop, mark.moran has access) ---
$localZapTemp = "$env:TEMP\sophoszap.exe"
$localS1Temp  = "$env:TEMP\SentinelOneInstaller_x64.exe"

Write-Host ""
Write-Host "Staging files from share..." -ForegroundColor Cyan

Write-Host "  Copying SophosZap..."
try {
    Copy-Item -Path $SophosZapSharePath -Destination $localZapTemp -Force -ErrorAction Stop
} catch {
    Write-Error "Could not copy SophosZap: $_"
    exit 1
}

Write-Host "  Copying SentinelOne installer (may take a moment)..."
try {
    Copy-Item -Path $S1InstallerShare -Destination $localS1Temp -Force -ErrorAction Stop
} catch {
    Write-Error "Could not copy SentinelOne installer: $_"
    exit 1
}

Write-Host "  Reading SentinelOne token..."
try {
    $s1Token = (Get-Content -Path $S1TokenShare -Raw -ErrorAction Stop).Trim()
} catch {
    Write-Error "Could not read S1 token: $_"
    exit 1
}

Write-Host "Files staged. Ready to process machines." -ForegroundColor Green

# --- Log folder ---
$logDir = "$PSScriptRoot\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# ============================================================
# ScriptBlock that runs on each remote machine
# ============================================================
$migrationScript = {
    param([string]$S1Token)

    $log = [System.Collections.Generic.List[string]]::new()
    function Log {
        param([string]$Msg, [string]$Level = "INFO")
        $entry = "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Msg"
        Write-Host "    $entry"
        $log.Add($entry)
    }

    Log "--- Starting on $env:COMPUTERNAME ---"

    $zapSuccess = $false

    # --------------------------------------------------------
    # 1. Run SophosZap as SYSTEM via schtasks.exe
    #    SYSTEM has SeDebugPrivilege natively, which SophosZap requires
    #    to attach to and kill Sophos processes. Running as a domain
    #    account (even local admin) does not reliably get this privilege
    #    in a non-interactive scheduled task context.
    # --------------------------------------------------------
    Log "Running SophosZap --confirm as SYSTEM (via schtasks.exe)..."
    $taskName = "SophosZapMigration"

    # Write a wrapper batch file so schtasks /tr has no quoting complexity
    $zapLog = "C:\Temp\sophoszap_out.txt"
    $zapBat = "C:\Temp\run_zap.bat"
    "@echo off`r`nC:\Temp\sophoszap.exe --confirm > C:\Temp\sophoszap_out.txt 2>&1" |
        Set-Content -Path $zapBat -Encoding ASCII

    $createOut = & schtasks /create /tn $taskName /tr $zapBat `
        /sc once /st "00:00" /ru SYSTEM /rl HIGHEST /f 2>&1
    Log "schtasks create: $createOut"

    if ($LASTEXITCODE -eq 0) {
        & schtasks /run /tn $taskName 2>&1 | Out-Null
        Log "Task started. Waiting for SophosZap to complete (up to 20 min)..."

        $deadline = (Get-Date).AddMinutes(20)
        do {
            Start-Sleep -Seconds 10
            $queryOut    = & schtasks /query /tn $taskName /fo LIST 2>&1
            $stillRunning = "$queryOut" -match "Status:\s+Running"
        } while ($stillRunning -and (Get-Date) -lt $deadline)

        & schtasks /delete /tn $taskName /f 2>&1 | Out-Null
        Remove-Item $zapBat -Force -ErrorAction SilentlyContinue

        # Read what SophosZap actually printed
        if (Test-Path $zapLog) {
            $zapOutput = Get-Content $zapLog -Raw
            Log "SophosZap output: $($zapOutput.Trim())"
            Remove-Item $zapLog -Force -ErrorAction SilentlyContinue

            if ($zapOutput -match "Complet") {
                Log "SophosZap completed successfully."
                # Note: reboot may be recommended but not required to install S1
            } else {
                Log "SophosZap output did not contain completion message. Will verify via service check." "WARN"
            }
        } else {
            Log "SophosZap output file not found - task may not have run. Will verify via service check." "WARN"
        }
    } else {
        Log "schtasks /create failed - could not register SophosZap task." "ERROR"
        & schtasks /delete /tn $taskName /f 2>&1 | Out-Null
    }

    Remove-Item "C:\Temp\sophoszap.exe" -Force -ErrorAction SilentlyContinue

    # --------------------------------------------------------
    # 4. Definitive Sophos removal check.
    #    Services being gone is not enough — check installed programs
    #    in the registry as well (appwiz.cpl source of truth).
    # --------------------------------------------------------
    Log "Verifying Sophos is fully removed..."

    $sophosServices = Get-Service -Name "Sophos*" -ErrorAction SilentlyContinue |
                      Where-Object { $_.Status -ne "Stopped" }

    $sophosInstalled = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "Sophos" }

    if ($sophosServices) {
        Log "Sophos services still RUNNING: $($sophosServices.Name -join ', '). Aborting S1 install." "ERROR"
        $sophosServices | ForEach-Object { Log "  Service: $($_.Name) - $($_.Status)" "ERROR" }
        $zapSuccess = $false
    } elseif ($sophosInstalled) {
        Log "Sophos software still present in installed programs. Aborting S1 install." "ERROR"
        $sophosInstalled | ForEach-Object { Log "  Installed: $($_.DisplayName) $($_.DisplayVersion)" "ERROR" }
        $zapSuccess = $false
    } else {
        Log "No Sophos services or installed programs detected - fully removed."
        $zapSuccess = $true
    }

    # --------------------------------------------------------
    # 5. Install SentinelOne ONLY if Sophos was cleanly removed
    # --------------------------------------------------------
    if (-not $zapSuccess) {
        Log "SKIPPING SentinelOne install - Sophos was not cleanly removed. Manual intervention required." "ERROR"
        Remove-Item "C:\Temp\SentinelOneInstaller_x64.exe" -Force -ErrorAction SilentlyContinue
    } else {
        Log "Installing SentinelOne..."
        try {
            $s1Proc = Start-Process -FilePath "C:\Temp\SentinelOneInstaller_x64.exe" `
                -ArgumentList "-t", $S1Token, "-q" `
                -Wait -PassThru -ErrorAction Stop
            Log "SentinelOne installer exited with code $($s1Proc.ExitCode)."
        } catch {
            Log "SentinelOne install failed: $_" "ERROR"
        }
        Remove-Item "C:\Temp\SentinelOneInstaller_x64.exe" -Force -ErrorAction SilentlyContinue
    }

    Log "--- Done on $env:COMPUTERNAME ---"
    return $log
}

# ============================================================
# Process each machine
# ============================================================
foreach ($computer in $ComputerName) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "  Processing: $computer" -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow

    # --- Establish session (uses current logged-in identity: mark.moran) ---
    try {
        $session = New-PSSession -ComputerName $computer -ErrorAction Stop
        Write-Host "  PSSession established." -ForegroundColor Green
    } catch {
        Write-Warning "  SKIPPED - could not connect to ${computer}: $_"
        continue
    }

    # --- Ensure C:\Temp on remote ---
    Invoke-Command -Session $session -ScriptBlock {
        if (-not (Test-Path "C:\Temp")) { New-Item -ItemType Directory -Path "C:\Temp" | Out-Null }
    }

    # --- Push SophosZap ---
    Write-Host "  Pushing SophosZap..."
    try {
        Copy-Item -Path $localZapTemp -Destination "C:\Temp\sophoszap.exe" -ToSession $session -Force -ErrorAction Stop
    } catch {
        Write-Warning "  Could not push SophosZap to ${computer}: $_"
        Remove-PSSession $session
        continue
    }

    # --- Push SentinelOne installer ---
    Write-Host "  Pushing SentinelOne installer..."
    try {
        Copy-Item -Path $localS1Temp -Destination "C:\Temp\SentinelOneInstaller_x64.exe" -ToSession $session -Force -ErrorAction Stop
    } catch {
        Write-Warning "  Could not push S1 installer to ${computer}: $_"
        Remove-PSSession $session
        continue
    }

    # --- Run migration on remote machine ---
    Write-Host "  Running migration..."
    $remoteLog = Invoke-Command -Session $session -ScriptBlock $migrationScript -ArgumentList $s1Token

    # --- Save log ---
    $logFile = "$logDir\$($computer.Split('.')[0])_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $remoteLog | Out-File -FilePath $logFile -Force
    Write-Host "  Log saved: $logFile" -ForegroundColor Green

    Remove-PSSession $session
}

# --- Clean up local temp files ---
Remove-Item $localZapTemp -Force -ErrorAction SilentlyContinue
Remove-Item $localS1Temp  -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== All targets processed. Logs in: $logDir ===" -ForegroundColor Cyan
