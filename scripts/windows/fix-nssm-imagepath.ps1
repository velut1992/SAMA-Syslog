################################################################################
# Supra Services - Fix NSSM ImagePath (Option A, in-place repair)
#
# When install.ps1 registers services via NSSM, the Windows Service ImagePath
# is stored with the EXACT path of the nssm.exe that was invoked. If the
# extracted installer folder is later deleted, SCM cannot find nssm.exe and
# services fail to start with "Error 2: The system cannot find the file
# specified."
#
# This script repoints each service's ImagePath to the permanent nssm.exe
# that install.ps1 copied to <InstallPath>\nssm\nssm.exe, without removing
# or re-registering the services (so all per-service config is preserved).
#
# Must be run as Administrator.
#
# Usage:
#   .\fix-nssm-imagepath.ps1                          # default InstallPath: E:\SupraSyslog
#   .\fix-nssm-imagepath.ps1 -InstallPath "C:\supra"  # custom path
#   .\fix-nssm-imagepath.ps1 -StartServices           # also start services in dependency order
################################################################################

#Requires -RunAsAdministrator

param(
    [string]$InstallPath   = "E:\SupraSyslog",
    [switch]$StartServices
)

$ErrorActionPreference = "Stop"

function Log($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$Services = @("SupraSearch", "SupraDashboards", "SupraLogCollector")

Write-Host ""
Write-Host "============================================"
Write-Host "  Fix NSSM ImagePath (Option A)"
Write-Host "============================================"
Write-Host ""
Write-Host "Install directory: $InstallPath"
Write-Host ""

# ---------------------------------------------------------------------------
#  Step 1: Verify the permanent nssm.exe is present
# ---------------------------------------------------------------------------
$NssmExe = Join-Path $InstallPath "nssm\nssm.exe"

Log "Step 1: Verifying permanent NSSM location..."
if (-not (Test-Path $NssmExe)) {
    Err "NSSM not found at: $NssmExe"
    Err ""
    Err "install.ps1 is supposed to copy nssm.exe here during install, but it is missing."
    Err "Copy nssm.exe to '$NssmExe' and re-run this script."
    Err ""
    Err "You can extract nssm.exe from your freshly built installer zip:"
    Err "  Expand-Archive supra-installer-3.6.0-windows-x64.zip -DestinationPath C:\tmp\supra-extract"
    Err "  Copy-Item C:\tmp\supra-extract\supra-installer\nssm\nssm.exe '$NssmExe'"
    exit 1
}
Log "  Found: $NssmExe"

# ---------------------------------------------------------------------------
#  Step 2: Show current ImagePath values (backup to console)
# ---------------------------------------------------------------------------
Log "Step 2: Current ImagePath values (backup - copy these somewhere if you want a rollback record)..."

$oldValues = @{}
foreach ($svc in $Services) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if (-not (Test-Path $regPath)) {
        Warn "  $svc : service not registered (skipping)"
        continue
    }
    $old = (Get-ItemProperty -Path $regPath -Name ImagePath -ErrorAction Stop).ImagePath
    $oldValues[$svc] = $old
    Write-Host "  $svc"
    Write-Host "      OLD: $old"
}

if ($oldValues.Count -eq 0) {
    Err "No Supra services found in registry. Nothing to fix."
    exit 1
}

# ---------------------------------------------------------------------------
#  Step 3: Stop services before changing ImagePath
# ---------------------------------------------------------------------------
Log "Step 3: Stopping services (dependents first)..."
foreach ($svc in @("SupraLogCollector", "SupraDashboards", "SupraSearch")) {
    if (-not $oldValues.ContainsKey($svc)) { continue }
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne "Stopped") {
        Write-Host "  Stopping $svc..." -NoNewline
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Host " stopped."
        } catch {
            Write-Host " (already stopped or stop failed: $($_.Exception.Message))"
        }
    } else {
        Write-Host "  $svc already stopped."
    }
}

# ---------------------------------------------------------------------------
#  Step 4: Write the new ImagePath for each service
# ---------------------------------------------------------------------------
Log "Step 4: Writing corrected ImagePath values..."
foreach ($svc in $Services) {
    if (-not $oldValues.ContainsKey($svc)) { continue }
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    $newImagePath = "`"$NssmExe`" $svc"
    Set-ItemProperty -Path $regPath -Name ImagePath -Value $newImagePath
    Log "  $svc"
    Write-Host "      NEW: $newImagePath"
}

# ---------------------------------------------------------------------------
#  Step 5: Verify
# ---------------------------------------------------------------------------
Log "Step 5: Verifying registry update..."
foreach ($svc in $Services) {
    if (-not $oldValues.ContainsKey($svc)) { continue }
    $current = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name ImagePath).ImagePath
    if ($current -like "*$NssmExe*") {
        Log "  $svc : OK"
    } else {
        Err "  $svc : MISMATCH - expected path to contain '$NssmExe', got '$current'"
    }
}

# ---------------------------------------------------------------------------
#  Step 6: Optionally start services in dependency order
# ---------------------------------------------------------------------------
if ($StartServices) {
    Log "Step 6: Starting services in dependency order..."

    if ($oldValues.ContainsKey("SupraSearch")) {
        Write-Host "  Starting SupraSearch..."
        try {
            Start-Service SupraSearch -ErrorAction Stop
            Log "  SupraSearch started. Waiting 30s for cluster init..."
            Start-Sleep -Seconds 30
        } catch {
            Err "  Failed to start SupraSearch: $($_.Exception.Message)"
            Err "  Check: $InstallPath\opensearch\logs\search-stderr.log"
            exit 1
        }
    }

    foreach ($svc in @("SupraDashboards", "SupraLogCollector")) {
        if (-not $oldValues.ContainsKey($svc)) { continue }
        Write-Host "  Starting $svc..."
        try {
            Start-Service $svc -ErrorAction Stop
            Log "  $svc started."
        } catch {
            Warn "  Failed to start $svc : $($_.Exception.Message)"
        }
    }
} else {
    Log "Step 6: Skipping service start (pass -StartServices to auto-start)."
}

# ---------------------------------------------------------------------------
#  Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ImagePath Repair Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
if (-not $StartServices) {
    Write-Host "Start services manually (in order):" -ForegroundColor Yellow
    Write-Host "  Start-Service SupraSearch"
    Write-Host "  Start-Sleep 30"
    Write-Host "  Start-Service SupraDashboards"
    Write-Host "  Start-Service SupraLogCollector"
    Write-Host ""
}
Write-Host "Check status:"
Write-Host "  Get-Service SupraSearch, SupraDashboards, SupraLogCollector"
Write-Host ""
