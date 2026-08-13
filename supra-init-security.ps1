################################################################################
# Supra security initialization (Windows) - run ONCE after SupraSearch starts.
#
# Wraps the OpenSearch Security plugin's securityadmin.bat, which cannot be run
# straight from a normal shell for two reasons this script removes:
#
#   1. securityadmin.bat resolves the JVM ONLY from OPENSEARCH_JAVA_HOME or
#      JAVA_HOME and aborts with "Unable to find java runtime" if neither is
#      set. The bundled JDK ships inside the install tree but is not on PATH and
#      is not exported to interactive shells - only to the NSSM service - so the
#      manual step failed on every fresh install. This script points at the
#      bundled JDK itself.
#   2. The securityadmin call needs six absolute paths that all depend on where
#      the stack was installed. Pasting them by hand from the guide (which shows
#      the C:\supra default) breaks on any other -InstallPath. This script
#      derives every path from its own location instead.
#
# It also waits for the node to accept connections first: securityadmin exits
# non-zero if it runs before OpenSearch has opened :9200.
#
# Usage (from the install directory):
#   powershell -ExecutionPolicy Bypass -File supra-init-security.ps1
#   powershell -ExecutionPolicy Bypass -File supra-init-security.ps1 -OsHome D:\Syslog_Windows\opensearch
#
# Exit codes: 0 = security index initialized, 1 = failed (reason printed)
################################################################################

[CmdletBinding()]
param(
    # Empty means "derive from this script's location" - see below. It cannot be
    # defaulted here: under [CmdletBinding()] the automatic $PSScriptRoot is not
    # yet populated while parameter defaults are evaluated, so a default built
    # from it silently collapses to C:\supra and breaks every other -InstallPath.
    [string]$OsHome = "",
    [string]$OsHost = "localhost",
    [int]$OsPort   = 9200,
    [int]$MaxTries  = 60,     # 60 x 5s = up to 5 minutes waiting for the node
    [int]$SleepSecs = 5
)

$ErrorActionPreference = "Stop"

# Default to the opensearch folder next to this script, i.e. the layout
# install.ps1 creates: <InstallDir>\supra-init-security.ps1 + <InstallDir>\opensearch\
if (-not $OsHome) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not $scriptDir) { $scriptDir = "C:\supra" }
    $OsHome = Join-Path $scriptDir "opensearch"
}

function Log($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================"
Write-Host "  Supra Security Initialization"
Write-Host "============================================"
Write-Host ""

# ---- Resolve and validate the install tree ----------------------------------
if (-not (Test-Path $OsHome)) {
    Err "Search engine home not found: $OsHome"
    Err "Pass the correct path, e.g. -OsHome D:\Syslog_Windows\opensearch"
    exit 1
}
$OsHome = (Resolve-Path $OsHome).Path

$securityAdmin = Join-Path $OsHome "plugins\opensearch-security\tools\securityadmin.bat"
$securityConf  = Join-Path $OsHome "config\opensearch-security\"
$caCert        = Join-Path $OsHome "config\root-ca.pem"
$adminCert     = Join-Path $OsHome "config\kirk.pem"
$adminKey      = Join-Path $OsHome "config\kirk-key.pem"

$missing = @()
foreach ($p in @($securityAdmin, $securityConf, $caCert, $adminCert, $adminKey)) {
    if (-not (Test-Path $p)) { $missing += $p }
}
if ($missing.Count -gt 0) {
    Err "The security plugin files are incomplete under $OsHome :"
    foreach ($m in $missing) { Err "  missing: $m" }
    Err "Re-run install.ps1 - the search engine was not fully installed."
    exit 1
}
Log "Search engine home: $OsHome"

# ---- Resolve the JVM --------------------------------------------------------
# This is the fix for "Unable to find java runtime / OPENSEARCH_JAVA_HOME or
# JAVA_HOME must be defined". Prefer an operator-provided JDK, otherwise use the
# one bundled in the install tree.
$javaHome = $null
foreach ($candidate in @($env:OPENSEARCH_JAVA_HOME, $env:JAVA_HOME, (Join-Path $OsHome "jdk"))) {
    if ($candidate -and (Test-Path (Join-Path $candidate "bin\java.exe"))) {
        $javaHome = $candidate
        break
    }
}
if (-not $javaHome) {
    Err "No Java runtime found."
    Err "Looked at OPENSEARCH_JAVA_HOME, JAVA_HOME and the bundled $OsHome\jdk."
    Err "The bundled JDK is missing - re-run install.ps1."
    exit 1
}
# securityadmin.bat reads this from the environment of the process we launch.
$env:OPENSEARCH_JAVA_HOME = $javaHome
Log "Java runtime:       $javaHome"

# ---- Wait for the node to accept connections --------------------------------
# securityadmin fails outright if the transport is not listening yet, and
# "nssm start SupraSearch" returns long before OpenSearch has finished booting.
Log "Waiting for the search engine on ${OsHost}:${OsPort} ..."
$up = $false
for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($OsHost, $OsPort)
        $up = $client.Connected
    } catch {
        $up = $false
    } finally {
        $client.Close()
    }
    if ($up) {
        Log "  Search engine is listening (attempt $attempt)."
        break
    }
    Write-Host "  attempt $attempt/$MaxTries : not listening yet; retrying in ${SleepSecs}s..."
    Start-Sleep -Seconds $SleepSecs
}
if (-not $up) {
    Err "The search engine never opened ${OsHost}:${OsPort}."
    Err "Check that the service is running:  nssm status SupraSearch"
    Err "and the startup log:                $OsHome\logs\search-stderr.log"
    exit 1
}

# ---- Apply the security configuration ---------------------------------------
# -icl  ignore cluster name  -nhnv  no hostname verification (demo certs are
# issued to a fixed CN, not to this machine's hostname).
Log "Applying the security configuration..."
$saArgs = @(
    "-cd",     $securityConf,
    "-icl",
    "-nhnv",
    "-cacert", $caCert,
    "-cert",   $adminCert,
    "-key",    $adminKey
)

# securityadmin.bat sends its own errors to nul, so a failed run prints almost
# nothing. Retry a few times: the node can be listening while the security
# plugin is still coming up, which fails with a transient connection error.
$ok = $false
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $output = & $securityAdmin @saArgs 2>&1 | Out-String
    Write-Host $output
    if ($LASTEXITCODE -eq 0 -and $output -match "(?i)Done with success") {
        $ok = $true
        break
    }
    if ($attempt -lt 5) {
        Warn "  attempt $attempt/5 did not succeed; retrying in ${SleepSecs}s..."
        Start-Sleep -Seconds $SleepSecs
    }
}

Write-Host ""
if ($ok) {
    Log "Security initialized. The admin account is now active."
    Write-Host ""
    Write-Host "Next: apply the index template, then start the remaining services:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File $(Join-Path (Split-Path -Parent $OsHome) 'supra-index-template.ps1')"
    Write-Host "  nssm start SupraDashboards"
    Write-Host "  nssm start SupraLogCollector"
    exit 0
} else {
    Err "securityadmin did not report success after 5 attempts."
    Err "Check the search engine log: $OsHome\logs\search-stderr.log"
    exit 1
}
