################################################################################
# Supra Services Repair Script (Windows)
#
# Unregisters and re-registers all 3 Supra services via NSSM.
# Also ensures NSSM is in the system PATH.
#
# Must be run as Administrator.
#
# Usage:
#   .\repair-services.ps1                                # Default: E:\SupraSyslog
#   .\repair-services.ps1 -InstallPath "C:\supra"        # Custom path
################################################################################

#Requires -RunAsAdministrator

param(
    [string]$InstallPath = "E:\SupraSyslog"
)

$ErrorActionPreference = "Stop"

function Log($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================"
Write-Host "  Supra Services Repair Script"
Write-Host "============================================"
Write-Host ""
Write-Host "Install directory: $InstallPath"
Write-Host ""

# ============================================================
#  Step 1: Locate NSSM
# ============================================================
Log "Step 1: Locating NSSM..."

$NssmExe = $null
$nssmPaths = @(
    (Join-Path $InstallPath "nssm\nssm.exe"),
    (Join-Path $PSScriptRoot "nssm\nssm.exe"),
    "C:\supra\nssm\nssm.exe",
    "nssm.exe"
)

foreach ($path in $nssmPaths) {
    if (Test-Path $path -ErrorAction SilentlyContinue) {
        $NssmExe = $path
        break
    }
}

if (-not $NssmExe) {
    Err "NSSM not found in any of these locations:"
    foreach ($p in $nssmPaths) { Err "  $p" }
    Err ""
    Err "Please download NSSM from https://nssm.cc and place nssm.exe in:"
    Err "  $InstallPath\nssm\nssm.exe"
    exit 1
}

Log "  NSSM found: $NssmExe"

# ============================================================
#  Step 2: Add NSSM to system PATH
# ============================================================
Log "Step 2: Ensuring NSSM is in system PATH..."

$nssmDir = Split-Path -Parent $NssmExe

# Copy NSSM to install directory if it's not already there
$nssmInstallDir = Join-Path $InstallPath "nssm"
if (-not (Test-Path $nssmInstallDir)) { New-Item -ItemType Directory -Path $nssmInstallDir -Force | Out-Null }
if ($NssmExe -ne (Join-Path $nssmInstallDir "nssm.exe")) {
    Copy-Item $NssmExe -Destination (Join-Path $nssmInstallDir "nssm.exe") -Force
    Log "  NSSM copied to $nssmInstallDir"
}
$NssmExe = Join-Path $nssmInstallDir "nssm.exe"

# Add to system PATH
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$nssmInstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$nssmInstallDir", "Machine")
    Log "  NSSM added to system PATH."
    Log "  NOTE: Open a NEW terminal after this script for 'nssm' to be recognized globally."
} else {
    Log "  NSSM already in system PATH."
}
# Update current session PATH
$env:Path = "$env:Path;$nssmInstallDir"

# ============================================================
#  Step 3: Stop and unregister all existing services
# ============================================================
Log "Step 3: Stopping and unregistering existing services..."

foreach ($svc in @("SupraLogCollector", "SupraDashboards", "SupraSearch")) {
    Write-Host "  Stopping $svc..." -NoNewline
    try { & $NssmExe stop $svc 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    Write-Host " removing..." -NoNewline
    try { & $NssmExe remove $svc confirm 2>&1 | Out-Null } catch {}
    Write-Host " done."
}

Log "  All services unregistered."

# ============================================================
#  Step 4: Validate install paths
# ============================================================
Log "Step 4: Validating installation..."

$osInstallDir = Join-Path $InstallPath "opensearch"
$osdInstallDir = Join-Path $InstallPath "dashboards"
$logCollectorDir = Join-Path $InstallPath "log-collector"

$osBat = Join-Path $osInstallDir "bin\opensearch.bat"
$osdBat = Join-Path $osdInstallDir "bin\opensearch-dashboards.bat"
$osJdk = Join-Path $osInstallDir "jdk"

$checks = @(
    @{ Name = "OpenSearch binary";    Path = $osBat }
    @{ Name = "OpenSearch JDK";       Path = $osJdk }
    @{ Name = "Dashboards binary";    Path = $osdBat }
    @{ Name = "Log Collector config"; Path = (Join-Path $logCollectorDir "fluent.conf") }
)

$allOk = $true
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Log "  $($check.Name): OK"
    } else {
        Err "  $($check.Name): NOT FOUND at $($check.Path)"
        $allOk = $false
    }
}

if (-not $allOk) {
    Err ""
    Err "Some files are missing. Fix the paths above and re-run."
    exit 1
}

# Detect fluentd
$tdAgentPath = "C:\opt\td-agent"
$fluentdExe = $null
if (Test-Path $tdAgentPath) {
    $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"
    Log "  Log Collector runtime: $fluentdExe"
} elseif (Get-Command fluentd -ErrorAction SilentlyContinue) {
    $fluentdExe = (Get-Command fluentd).Source
    Log "  Log Collector runtime: $fluentdExe"
} else {
    Warn "  Log Collector runtime (td-agent/fluentd) NOT FOUND."
    Warn "  SupraLogCollector service will NOT be registered."
    Warn "  Install td-agent first, then re-run this script."
}

# Pre-create log directories
New-Item -ItemType Directory -Path (Join-Path $osInstallDir "logs") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $osdInstallDir "logs") -Force | Out-Null
New-Item -ItemType Directory -Path $logCollectorDir -Force | Out-Null

# ============================================================
#  Step 5: Register SupraSearch service
# ============================================================
Log "Step 5: Registering SupraSearch service..."

& $NssmExe install "SupraSearch" $osBat
& $NssmExe set "SupraSearch" DisplayName "Supra Search Engine"
& $NssmExe set "SupraSearch" Description "Supra Search Engine service"
& $NssmExe set "SupraSearch" AppDirectory $osInstallDir
& $NssmExe set "SupraSearch" Start SERVICE_AUTO_START
& $NssmExe set "SupraSearch" AppRestartDelay 10000
& $NssmExe set "SupraSearch" AppStdout (Join-Path $osInstallDir "logs\search-stdout.log")
& $NssmExe set "SupraSearch" AppStderr (Join-Path $osInstallDir "logs\search-stderr.log")
& $NssmExe set "SupraSearch" AppEnvironmentExtra "OPENSEARCH_HOME=$osInstallDir" "OPENSEARCH_JAVA_HOME=$osJdk"
Log "  SupraSearch registered."

# ============================================================
#  Step 6: Register SupraDashboards service
# ============================================================
Log "Step 6: Registering SupraDashboards service..."

& $NssmExe install "SupraDashboards" $osdBat
& $NssmExe set "SupraDashboards" DisplayName "Supra Dashboards"
& $NssmExe set "SupraDashboards" Description "Supra Dashboards web UI"
& $NssmExe set "SupraDashboards" AppDirectory $osdInstallDir
& $NssmExe set "SupraDashboards" Start SERVICE_AUTO_START
& $NssmExe set "SupraDashboards" AppRestartDelay 10000
& $NssmExe set "SupraDashboards" AppStdout (Join-Path $osdInstallDir "logs\dashboards-stdout.log")
& $NssmExe set "SupraDashboards" AppStderr (Join-Path $osdInstallDir "logs\dashboards-stderr.log")
& $NssmExe set "SupraDashboards" DependOnService "SupraSearch"
Log "  SupraDashboards registered."

# ============================================================
#  Step 7: Register SupraLogCollector service
# ============================================================
if ($fluentdExe) {
    Log "Step 7: Registering SupraLogCollector service..."

    & $NssmExe install "SupraLogCollector" $fluentdExe "-c" (Join-Path $logCollectorDir "fluent.conf")
    & $NssmExe set "SupraLogCollector" DisplayName "Supra Log Collector"
    & $NssmExe set "SupraLogCollector" Description "Supra log collection agent (Fluentd)"
    & $NssmExe set "SupraLogCollector" Start SERVICE_AUTO_START
    & $NssmExe set "SupraLogCollector" AppRestartDelay 5000
    & $NssmExe set "SupraLogCollector" AppStdout (Join-Path $logCollectorDir "log-collector-stdout.log")
    & $NssmExe set "SupraLogCollector" AppStderr (Join-Path $logCollectorDir "log-collector-stderr.log")
    & $NssmExe set "SupraLogCollector" DependOnService "SupraSearch"
    Log "  SupraLogCollector registered."
} else {
    Warn "Step 7: Skipping SupraLogCollector (fluentd not found)."
}

# ============================================================
#  Step 8: Verify registration
# ============================================================
Log "Step 8: Verifying service registration..."

foreach ($svc in @("SupraSearch", "SupraDashboards", "SupraLogCollector")) {
    $status = & $NssmExe status $svc 2>&1
    if ($status -match "SERVICE_STOPPED|SERVICE_RUNNING|SERVICE_PAUSED") {
        Log "  $svc : $status"
    } else {
        Warn "  $svc : $status"
    }
}

# ============================================================
#  Done
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Services Repair Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Start services:" -ForegroundColor Yellow
Write-Host "  nssm start SupraSearch"
Write-Host "  # Wait ~30 seconds for Search Engine to be ready, then:"
Write-Host "  nssm start SupraDashboards"
if ($fluentdExe) {
    Write-Host "  nssm start SupraLogCollector"
}
Write-Host ""
Write-Host "Or start all at once:"
Write-Host "  nssm start SupraSearch; Start-Sleep 30; nssm start SupraDashboards; nssm start SupraLogCollector"
Write-Host ""
Write-Host "Check status:"
Write-Host "  nssm status SupraSearch"
Write-Host "  nssm status SupraDashboards"
Write-Host "  nssm status SupraLogCollector"
Write-Host ""
Write-Host "Services:"
Write-Host "  SupraSearch          - https://localhost:9200"
Write-Host "  SupraDashboards      - http://localhost:5601"
Write-Host "  SupraLogCollector    - UDP/5140 (syslog), TCP/24224 (forward)"
Write-Host ""
Write-Host "NOTE: Open a NEW terminal for 'nssm' command to work globally." -ForegroundColor Cyan
Write-Host ""
