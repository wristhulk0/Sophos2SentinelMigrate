# Sophos → SentinelOne Migration — Handoff Notes

## What This Does
Remotely uninstalls Sophos via SophosZap and installs SentinelOne on student lab machines
in the `04hslab318s` series, over PSRemoting (already enabled on student machines).

## Target Machines
- Series: `04hslab318s001` through `04hslab318s024`
- Skip: 002, 004
- Domain suffix: `mystisd.stisd.net`
- Full example: `04hslab318s007.mystisd.stisd.net`

## Key Files
| File | Purpose |
|------|---------|
| `Invoke-SophosToS1.ps1` | Main script — run this |
| `.env` | Credentials (ZAP_USER / ZAP_PASS for symantec.backupexec) |
| `logs\` | Per-machine log files written after each run |

## How to Run
```powershell
# Single machine
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-SophosToS1.ps1 -ComputerName 04hslab318s007.mystisd.stisd.net

# Full lab (001-024, skipping 002 and 004)
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-SophosToS1.ps1 -Lab318
```
Runs as `STISD\mark.moran` (current logged-in session). No interactive prompts if `.env` is populated.

## What the Script Does Per Machine
1. Establishes PSSession (no credential needed — uses mark.moran's session)
2. Copies SophosZap and S1 installer from share to local `%TEMP%`, pushes to remote `C:\Temp` via session (avoids Kerberos double-hop)
3. Reads S1 token from share on the tech machine (single hop)
4. Writes `C:\Temp\run_zap.bat` on remote machine
5. Runs SophosZap as **SYSTEM** via `schtasks.exe` (SYSTEM needed for `SeDebugPrivilege` — domain accounts fail even as local admin)
6. Reads `C:\Temp\sophoszap_out.txt` for SophosZap output
7. Checks registry uninstall keys AND services for any remaining Sophos — **both must be clean** before S1 installs
8. Installs SentinelOne silently: `SentinelOneInstaller_x64.exe -t <token> -q`
9. Cleans up temp files

## Share Paths (as seen from tech machine)
```
SophosZap:    \\10.4.14.101\HP\sophosinstall\sophoszap.exe
S1 installer: \\10.4.14.101\district_software\District_software\Network Stuff - Cesar\SentinelONE\Windows 64-bit\SentinelOneInstaller_windows_64bit_v25_1_4_434.exe
S1 token:     \\10.4.14.101\district_software\District_software\Network Stuff - Cesar\SentinelONE\Windows 64-bit\token.txt
```

## Current Machine Status
| Machine | Status | Notes |
|---------|--------|-------|
| 001 | Sophos already removed | S1 not installed — needs S1 only |
| 003 | MESSY — both Sophos + S1 installed | First botched test. Needs manual fix: uninstall S1, run ZAP, reinstall S1 |
| 006 | Clean — S1 installed | Test success |
| 007 | Deep Frozen test machine | SophosZap says "Reboot and re-execute" on first pass — needs 2 runs on unfrozen machines |

## Critical Finding: SophosZap Needs Two Passes
SophosZap output on a live Sophos install:
```
Reboot and re-execute.
```
This means **SophosZap requires a reboot between runs** to fully remove Sophos.
The script currently does NOT handle this — it will correctly block S1 install on first pass,
but does not automatically reboot and re-run.

**TODO: Add reboot + re-run logic**, OR document that operators need to run the script twice
per machine with a reboot in between. Options:
- Script initiates reboot (`Restart-Computer -ComputerName $computer -Force`), waits for machine
  to come back (`Test-Connection` loop), reconnects session, re-runs ZAP, then installs S1
- Or: run script once (removes most of Sophos + reboots), reboot happens, run script again

## Known Issues / Lessons Learned
- **Em-dash characters** break PowerShell 5.1 parsing (reads files as Windows-1252, em-dash byte `\x94` = closing quote). Always use ASCII in `.ps1` files.
- **`Register-ScheduledTask` (PowerShell cmdlet)** rejects valid domain credentials in PSSession context via WMI/CIM. Use `schtasks.exe` instead.
- **`Start-Process -Credential`** fails in non-interactive PSSession. Use scheduled task.
- **`schtasks /tr` quoting**: complex args like `--confirm` get parsed by schtasks. Fix: write a `.bat` wrapper and point `/tr` at that.
- **SophosZap as domain account**: fails with `SeDebugPrivilege` error even when account is local admin. Must run as **SYSTEM**.
- **Service check alone is not enough**: Sophos services can be stopped while software is still installed (appwiz.cpl). Must check registry uninstall keys.
- **One-time scheduled tasks auto-delete** after running past their scheduled time — query returns "file not found". Not an error. Service/registry check is the real gate.
- **S1 silent install flags**: `-t <token> -q`

## .env Format
```
ZAP_USER=STISD\symantec.backupexec
ZAP_PASS=<password>
```
Note: ZAP credentials are currently still in the script but no longer used for running SophosZap
(switched to SYSTEM). They can be removed from `.env` unless needed for something else.
Actually — they ARE still loaded but `$zapCred` is no longer passed to the migration script.
Clean this up next session.
