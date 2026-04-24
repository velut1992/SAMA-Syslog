################################################################################
# Supra Installer Package Builder (Windows Server x64)
#
# Builds a self-contained installer zip that can be deployed on a Windows Server
# x64 machine. The package includes:
#   - Supra Search Engine (full distribution with all plugins)
#   - Supra Dashboards (full distribution with all plugins)
#   - Extra Dashboards plugins (SIEM, Index Management, Notifications, Reporting)
#   - Supra Log Collector configuration
#   - NSSM (Non-Sucking Service Manager) for Windows Services
#   - Install / Uninstall PowerShell scripts
################################################################################

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$BuildDir = Join-Path $BaseDir "installer-build-win"
$PackageName = "supra-installer"
$Version = "3.6.0"

# Source paths
$OpenSearchZip = Join-Path $BaseDir "opensearch-${Version}-windows-x64.zip"
$DashboardsZipSnapshot = Join-Path $BaseDir "OpenSearch-Dashboards\target\opensearch-dashboards-${Version}-SNAPSHOT-windows-x64.zip"
$DashboardsZipRelease  = Join-Path $BaseDir "OpenSearch-Dashboards\target\opensearch-dashboards-${Version}-windows-x64.zip"
if (Test-Path $DashboardsZipSnapshot) {
    $DashboardsZip = $DashboardsZipSnapshot
} else {
    $DashboardsZip = $DashboardsZipRelease
}
$ExtraPluginsDir = Join-Path $BaseDir "dashboards-plugins"
$FluentdConf = Join-Path $BaseDir "fluent\fluent.conf"
$LicenseValidatorDir = Join-Path $BaseDir "opensearch-license-validator"
$IndexManagementDir = Join-Path $BaseDir "index-management"
$DashboardsReportingSrc = Join-Path $BaseDir "dashboards-reporting"
$DashboardsSrc = Join-Path $BaseDir "OpenSearch-Dashboards"

# NSSM download URL
$NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$NssmZip = Join-Path $BaseDir "nssm-2.24.zip"

# Fluentd (td-agent) offline bundle.
# The MSI is fetched at BUILD time (needs internet on the build host) and then staged
# inside the installer zip so the TARGET machine can install it without internet.
# td-agent 4.5.2 ships fluent-plugin-opensearch + opensearch-ruby pre-installed, so no
# separate gem download is required.
$TdAgentMsiUrl  = "https://s3.amazonaws.com/packages.treasuredata.com/4/windows/td-agent-4.5.2-x64.msi"
$TdAgentMsiName = "td-agent-4.5.2-x64.msi"
$TdAgentMsi     = Join-Path $BaseDir $TdAgentMsiName

# NXLog endpoint agent kit (bundled inside the installer zip for deployment to Windows endpoints)
# Place a NXLog CE MSI manually at $NxlogDir\nxlog-ce-*.msi; the endpoint config is already in the repo.
$NxlogDir  = Join-Path $BaseDir "nxlog"
$NxlogConf = Join-Path $NxlogDir "nxlog.conf"

Write-Host "============================================"
Write-Host "  Supra Installer Package Builder v${Version}"
Write-Host "  (Windows Server x64)"
Write-Host "============================================"
Write-Host ""

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
Write-Host "[1/8] Checking prerequisites..."

if (-not (Test-Path $OpenSearchZip)) {
    $OpenSearchUrl = "https://ci.opensearch.org/ci/dbc/distribution-build-opensearch/${Version}/latest/windows/x64/zip/dist/opensearch/opensearch-${Version}-windows-x64.zip"
    Write-Host "  Search engine zip not found. Downloading..."
    Write-Host "    URL: $OpenSearchUrl"
    try {
        Invoke-WebRequest -Uri $OpenSearchUrl -OutFile $OpenSearchZip -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $OpenSearchZip).Length / 1MB, 1)
        Write-Host "    Downloaded: ${sizeMB} MB"
    } catch {
        Write-Host "ERROR: Failed to download Supra Search Engine." -ForegroundColor Red
        Write-Host "       URL: $OpenSearchUrl" -ForegroundColor Red
        Write-Host "       Please download manually and place at: $OpenSearchZip" -ForegroundColor Red
        Remove-Item -Path $OpenSearchZip -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    $sizeMB = [math]::Round((Get-Item $OpenSearchZip).Length / 1MB, 1)
    Write-Host "  Search engine zip:   OK (${sizeMB} MB)"
}

if (-not (Test-Path $DashboardsZip)) {
    Write-Host "  Dashboards zip not found. Attempting to build automatically..." -ForegroundColor Yellow
    if (-not (Test-Path $DashboardsSrc)) {
        Write-Host "ERROR: OpenSearch-Dashboards source not found at $DashboardsSrc" -ForegroundColor Red
        Write-Host "       Clone it first or place a pre-built zip at:" -ForegroundColor Red
        Write-Host "         $DashboardsZipRelease" -ForegroundColor Red
        exit 1
    }
    $yarnCmd = Get-Command yarn -ErrorAction SilentlyContinue
    if (-not $yarnCmd) {
        Write-Host "ERROR: yarn is not installed or not in PATH." -ForegroundColor Red
        Write-Host "       Install it with: npm install -g yarn" -ForegroundColor Red
        Write-Host "       Or build manually:" -ForegroundColor Red
        Write-Host "         cd $DashboardsSrc" -ForegroundColor Red
        Write-Host "         yarn build-platform --windows --skip-os-packages" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Bootstrapping Dashboards (yarn osd bootstrap)..."
    Push-Location $DashboardsSrc
    try {
        & yarn osd bootstrap
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: yarn osd bootstrap failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            exit 1
        }
        Write-Host "  Building Supra Dashboards (this may take a while)..."
        & yarn build-platform --windows --skip-os-packages
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Dashboards build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            exit 1
        }
    } finally {
        Pop-Location
    }
    # Re-check for the built zip (could be SNAPSHOT or release)
    if (Test-Path $DashboardsZipSnapshot) {
        $DashboardsZip = $DashboardsZipSnapshot
    } elseif (Test-Path $DashboardsZipRelease) {
        $DashboardsZip = $DashboardsZipRelease
    } else {
        Write-Host "ERROR: Build completed but zip not found at expected location." -ForegroundColor Red
        Write-Host "       Expected: $DashboardsZipSnapshot" -ForegroundColor Red
        Write-Host "       Or:       $DashboardsZipRelease" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Dashboards build complete."
}
Write-Host "  Dashboards zip:      OK"

if (-not (Test-Path $FluentdConf)) {
    Write-Host "ERROR: Log Collector config not found at $FluentdConf" -ForegroundColor Red
    exit 1
}
Write-Host "  Log Collector config: OK"

# Download NSSM if not present
if (-not (Test-Path $NssmZip)) {
    Write-Host "  Downloading NSSM service manager..."
    try {
        Invoke-WebRequest -Uri $NssmUrl -OutFile $NssmZip -UseBasicParsing
        Write-Host "    NSSM downloaded."
    } catch {
        Write-Host "  WARNING: Failed to download NSSM. You may need to include it manually." -ForegroundColor Yellow
    }
}

# Download td-agent MSI if not present (target machine will install this offline)
if (-not (Test-Path $TdAgentMsi)) {
    Write-Host "  Downloading td-agent (Fluentd) MSI..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $TdAgentMsiUrl -OutFile $TdAgentMsi -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $TdAgentMsi).Length / 1MB, 1)
        Write-Host "    td-agent MSI downloaded (${sizeMB} MB)."
    } catch {
        Write-Host "ERROR: Failed to download td-agent MSI." -ForegroundColor Red
        Write-Host "       URL: $TdAgentMsiUrl" -ForegroundColor Red
        Write-Host "       Please download manually and place at: $TdAgentMsi" -ForegroundColor Red
        Remove-Item -Path $TdAgentMsi -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    $sizeMB = [math]::Round((Get-Item $TdAgentMsi).Length / 1MB, 1)
    Write-Host "  td-agent MSI:         OK (${sizeMB} MB)"
}

# Note: td-agent 4.5.2 ships with fluent-plugin-opensearch (and opensearch-ruby)
# pre-installed. No gem fetch is needed — the MSI is self-contained.

# Check for an optional NXLog CE MSI (for Windows endpoints that forward logs to this server).
# Direct download links from nxlog.co are not stable, so we don't auto-download — the user
# places the MSI at nxlog\nxlog-ce-*.msi manually.
$NxlogMsi = $null
if (Test-Path $NxlogDir) {
    $NxlogMsi = Get-ChildItem -Path $NxlogDir -Filter "nxlog-ce-*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($NxlogMsi) {
    $sizeMB = [math]::Round($NxlogMsi.Length / 1MB, 1)
    Write-Host "  NXLog CE MSI:         OK (${sizeMB} MB) - $($NxlogMsi.Name)"
} else {
    Write-Host "  NXLog CE MSI:         not found (endpoint kit will ship without MSI)" -ForegroundColor Yellow
    Write-Host "                        Download from https://nxlog.co/products/nxlog-community-edition/download" -ForegroundColor Yellow
    Write-Host "                        Place at: $NxlogDir\nxlog-ce-<version>.msi" -ForegroundColor Yellow
}

# Download missing Dashboards plugins
$DashboardsPluginBaseUrl = "https://ci.opensearch.org/ci/dbc/distribution-build-opensearch-dashboards/${Version}/latest/windows/x64/zip/builds/opensearch-dashboards/plugins"
$DashboardsPluginArtifacts = @(
    @{ Name = "securityDashboards";          Url = "${DashboardsPluginBaseUrl}/securityDashboards-${Version}.zip" }
    @{ Name = "alertingDashboards";          Url = "${DashboardsPluginBaseUrl}/alertingDashboards-${Version}.zip" }
    @{ Name = "anomalyDetectionDashboards";  Url = "${DashboardsPluginBaseUrl}/anomalyDetectionDashboards-${Version}.zip" }
    @{ Name = "observabilityDashboards";     Url = "${DashboardsPluginBaseUrl}/observabilityDashboards-${Version}.zip" }
    @{ Name = "searchRelevanceDashboards";   Url = "${DashboardsPluginBaseUrl}/searchRelevanceDashboards-${Version}.zip" }
    @{ Name = "queryInsightsDashboards";     Url = "${DashboardsPluginBaseUrl}/queryInsightsDashboards-${Version}.zip" }
    @{ Name = "assistantDashboards";         Url = "${DashboardsPluginBaseUrl}/assistantDashboards-${Version}.zip" }
    @{ Name = "customImportMapDashboards";   Url = "${DashboardsPluginBaseUrl}/customImportMapDashboards-${Version}.zip" }
    @{ Name = "indexManagementDashboards";   Url = "${DashboardsPluginBaseUrl}/indexManagementDashboards-${Version}.zip" }
    @{ Name = "notificationsDashboards";     Url = "${DashboardsPluginBaseUrl}/notificationsDashboards-${Version}.zip" }
    @{ Name = "securityAnalyticsDashboards"; Url = "${DashboardsPluginBaseUrl}/securityAnalyticsDashboards-${Version}.zip" }
    @{ Name = "reportsDashboards";           Url = "${DashboardsPluginBaseUrl}/reportsDashboards-${Version}.zip" }
    @{ Name = "mlCommonsDashboards";         Url = "${DashboardsPluginBaseUrl}/mlCommonsDashboards-${Version}.zip" }
)

if (-not (Test-Path $ExtraPluginsDir)) { New-Item -ItemType Directory -Path $ExtraPluginsDir -Force | Out-Null }

Write-Host "  Checking Dashboards plugins..."
foreach ($plugin in $DashboardsPluginArtifacts) {
    $pluginFile = Join-Path $ExtraPluginsDir "$($plugin.Name)-${Version}.zip"
    if (-not (Test-Path $pluginFile)) {
        Write-Host "  Downloading $($plugin.Name)..."
        try {
            Invoke-WebRequest -Uri $plugin.Url -OutFile $pluginFile -UseBasicParsing
            Write-Host "    OK"
        } catch {
            Write-Host "    WARNING: Failed to download $($plugin.Name). Skipping." -ForegroundColor Yellow
            Remove-Item -Path $pluginFile -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "    $($plugin.Name) already downloaded."
    }
}

$ExtraPluginsFound = (Get-ChildItem -Path $ExtraPluginsDir -Filter "*.zip" -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "  Extra plugins:        ${ExtraPluginsFound} found"

# ---------------------------------------------------------------------------
# Prepare build directory
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/8] Preparing build directory..."
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
$Staging = Join-Path $BuildDir $PackageName
New-Item -ItemType Directory -Path $Staging -Force | Out-Null
foreach ($sub in @("opensearch", "dashboards", "dashboards-plugins", "log-collector", "nssm", "branding", "license-validator", "index-management", "nxlog-agent")) {
    New-Item -ItemType Directory -Path (Join-Path $Staging $sub) -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Package Supra Search Engine
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/8] Packaging Supra Search Engine..."
Copy-Item $OpenSearchZip -Destination (Join-Path $Staging "opensearch\")

$opensearchYml = @"
cluster.name: supra
node.name: supra-node-1
discovery.type: single-node
network.host: 0.0.0.0
http.port: 9200

# Security plugin configuration
plugins.security.disabled: false
plugins.security.ssl.transport.pemcert_filepath: esnode.pem
plugins.security.ssl.transport.pemkey_filepath: esnode-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false
plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: esnode.pem
plugins.security.ssl.http.pemkey_filepath: esnode-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: root-ca.pem
plugins.security.allow_unsafe_democertificates: true
plugins.security.allow_default_init_securityindex: true
plugins.security.authcz.admin_dn:
  - CN=kirk,OU=client,O=client,L=test,C=de
plugins.security.audit.type: internal_opensearch
plugins.security.enable_snapshot_restore_privilege: true
plugins.security.check_snapshot_restore_write_privileges: true
plugins.security.restapi.roles_enabled: ["all_access", "security_rest_api_access"]
plugins.security.system_indices.enabled: true
plugins.security.system_indices.indices: [".plugins-ml-agent", ".plugins-ml-config", ".plugins-ml-connector", ".plugins-ml-controller", ".plugins-ml-model-group", ".plugins-ml-model", ".plugins-ml-task", ".plugins-ml-conversation-meta", ".plugins-ml-conversation-interactions", ".plugins-ml-memory-meta", ".plugins-ml-memory-message", ".opendistro-job-scheduler-lock", ".opensearch-notifications-config", ".opensearch-notifications-profiles", ".opensearch-observability", ".ql-datasources", ".opendistro-asynchronous-search-response", ".replication-metadata-store", ".opensearch-knn-models", ".geospatial-ip2geo-data", ".opendistro-reports-definitions", ".opendistro-reports-instances", ".opensearch-sap-log-types-config", ".opensearch-sap-pre-packaged-rules-config"]
"@
$opensearchYml | Out-File -FilePath (Join-Path $Staging "opensearch\opensearch.yml") -Encoding UTF8
Write-Host "  Zip and config staged."

# ---------------------------------------------------------------------------
# Package Supra Dashboards
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/8] Packaging Supra Dashboards..."
Copy-Item $DashboardsZip -Destination (Join-Path $Staging "dashboards\")

if ($ExtraPluginsFound -gt 0) {
    Write-Host "  Packaging extra dashboards plugins..."
    Get-ChildItem -Path $ExtraPluginsDir -Filter "*.zip" | ForEach-Object {
        Copy-Item $_.FullName -Destination (Join-Path $Staging "dashboards-plugins\")
        Write-Host "    - $($_.Name)"
    }
}

# Copy branding assets
$brandingSource = Join-Path $DashboardsSrc "src\core\server\core_app\assets\default_branding"
if (Test-Path $brandingSource) {
    Copy-Item (Join-Path $brandingSource "scpl.png")    -Destination (Join-Path $Staging "branding\") -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $brandingSource "favicon.png") -Destination (Join-Path $Staging "branding\") -ErrorAction SilentlyContinue
}

$dashboardsYml = @"
server.port: 5601
server.host: "0.0.0.0"
opensearch.hosts: ["https://localhost:9200"]
opensearch.ssl.verificationMode: none
opensearch.username: "kibanaserver"
opensearch.password: "kibanaserver"
opensearch.requestHeadersAllowlist: ["securitytenant", "Authorization"]

opensearchDashboards.branding:
  logo:
    defaultUrl: "/ui/default_branding/scpl.png"
    darkModeUrl: "/ui/default_branding/scpl.png"
  mark:
    defaultUrl: "/ui/default_branding/favicon.png"
  loadingLogo:
    defaultUrl: "/ui/default_branding/favicon.png"
    darkModeUrl: "/ui/default_branding/favicon.png"
  faviconUrl: "/ui/default_branding/favicon.png"
  applicationTitle: "Supra"
"@
$dashboardsYml | Out-File -FilePath (Join-Path $Staging "dashboards\opensearch_dashboards.yml") -Encoding UTF8
Write-Host "  Branding and config staged."

# ---------------------------------------------------------------------------
# Package Supra Log Collector config + Fluentd (td-agent) offline bundle
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Packaging Supra Log Collector (Fluentd) offline bundle..."
Copy-Item $FluentdConf -Destination (Join-Path $Staging "log-collector\")
Write-Host "  fluent.conf staged."

# Stage td-agent MSI (includes fluent-plugin-opensearch pre-installed)
Copy-Item $TdAgentMsi -Destination (Join-Path $Staging "log-collector\")
Write-Host "  td-agent MSI staged: $TdAgentMsiName"

# ---------------------------------------------------------------------------
# Package NXLog endpoint agent kit (for Windows endpoints forwarding to this server)
# ---------------------------------------------------------------------------
Write-Host "  Packaging NXLog endpoint agent kit..."
$nxlogStaging = Join-Path $Staging "nxlog-agent"
if (Test-Path $NxlogConf) {
    Copy-Item $NxlogConf -Destination $nxlogStaging
    Write-Host "    nxlog.conf staged."
} else {
    Write-Host "    WARNING: $NxlogConf not found. Endpoint kit will ship without config." -ForegroundColor Yellow
}
if ($NxlogMsi) {
    Copy-Item $NxlogMsi.FullName -Destination $nxlogStaging
    Write-Host "    NXLog CE MSI staged: $($NxlogMsi.Name)"
}

# Endpoint-side install script (runs ON each Windows workstation, not on the server)
$nxlogEndpointScript = @'
################################################################################
# Supra NXLog Endpoint Installer (run on each Windows endpoint)
#
# Installs NXLog CE offline from the bundled MSI and drops the Supra-specific
# nxlog.conf. Must be run as Administrator.
#
# Usage:
#   .\install-nxlog.ps1 -SupraServerIP 192.168.1.100
################################################################################

#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory=$true)]
    [string]$SupraServerIP,

    [int]$SupraPort = 5140
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================"
Write-Host "  Supra NXLog Endpoint Installer"
Write-Host "============================================"
Write-Host ""
Write-Host "  Supra server IP: $SupraServerIP"
Write-Host "  Supra port     : $SupraPort"
Write-Host ""

# ---- Install NXLog CE from bundled MSI ----
$nxlogInstallDir = "C:\Program Files\nxlog"
if (-not (Test-Path $nxlogInstallDir)) {
    $nxlogMsi = Get-ChildItem -Path $ScriptDir -Filter "nxlog-ce-*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nxlogMsi) {
        Err "NXLog CE MSI not found in $ScriptDir."
        Err "Place nxlog-ce-<version>.msi next to this script and re-run."
        exit 1
    }
    Log "Installing NXLog CE from $($nxlogMsi.Name)..."
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($nxlogMsi.FullName)`" /quiet /norestart" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Err "NXLog MSI install failed (exit $($proc.ExitCode))."
        exit 1
    }
    Log "  NXLog CE installed to $nxlogInstallDir"
} else {
    Log "NXLog already installed at $nxlogInstallDir"
}

# ---- Drop config with substituted server IP ----
$nxlogConfSrc  = Join-Path $ScriptDir "nxlog.conf"
$nxlogConfDest = Join-Path $nxlogInstallDir "conf\nxlog.conf"
if (-not (Test-Path $nxlogConfSrc)) {
    Err "nxlog.conf not found at $nxlogConfSrc"
    exit 1
}
$conf = Get-Content $nxlogConfSrc -Raw
$conf = $conf -replace '(?m)^define\s+SUPRA_SERVER_IP\s+.*$', "define SUPRA_SERVER_IP   $SupraServerIP"
$conf = $conf -replace '(?m)^define\s+SUPRA_PORT\s+.*$',      "define SUPRA_PORT        $SupraPort"
[System.IO.File]::WriteAllText($nxlogConfDest, $conf, [System.Text.UTF8Encoding]::new($false))
Log "  nxlog.conf written to $nxlogConfDest (SUPRA_SERVER_IP=$SupraServerIP)"

# ---- Restart service ----
Log "Restarting nxlog service..."
try {
    Stop-Service nxlog -ErrorAction SilentlyContinue
    Start-Service nxlog
    Log "  nxlog service running."
} catch {
    Warn "  Could not restart nxlog service automatically: $_"
    Warn "  Run: Restart-Service nxlog"
}

Write-Host ""
Write-Host "Done. This endpoint will forward Windows event logs to ${SupraServerIP}:${SupraPort} (UDP)."
'@
$nxlogEndpointScript | Out-File -FilePath (Join-Path $nxlogStaging "install-nxlog.ps1") -Encoding UTF8

$nxlogReadme = @'
Supra NXLog Endpoint Agent Kit
===============================

This folder is a self-contained kit for Windows endpoints that need to forward
event logs to the Supra SIEM server. It does NOT need to run on the Supra server
itself — deploy it to each workstation or server you want to collect logs from.

Contents:
  - nxlog-ce-*.msi    NXLog Community Edition installer (offline)
  - nxlog.conf        Supra-specific NXLog configuration (collects Security,
                      System, Application, and PowerShell event logs)
  - install-nxlog.ps1 Endpoint installer (offline)

Deployment (on each endpoint, as Administrator):
  1. Copy this folder to the endpoint (e.g. C:\supra-nxlog-agent)
  2. Open PowerShell as Administrator
  3. Run:
       .\install-nxlog.ps1 -SupraServerIP <your-supra-server-ip>
     Optional:
       .\install-nxlog.ps1 -SupraServerIP 10.0.0.5 -SupraPort 5140

Verifying:
  Get-Service nxlog
  Get-Content 'C:\Program Files\nxlog\data\nxlog.log' -Tail 50

Uninstall:
  Run the same MSI with /x, e.g.:
    msiexec /x nxlog-ce-3.2.2329.msi /quiet
'@
$nxlogReadme | Out-File -FilePath (Join-Path $nxlogStaging "README.txt") -Encoding UTF8
Write-Host "    Endpoint install script + README staged."

# ---------------------------------------------------------------------------
# Package license validator (auto-build with Maven if zip is missing)
# ---------------------------------------------------------------------------
if (Test-Path $LicenseValidatorDir) {
    Write-Host "  Packaging license validator..."
    $pluginZip = Get-ChildItem -Path (Join-Path $LicenseValidatorDir "license-validator\target\releases") -Filter "supra-license-validator-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pluginZip) {
        Write-Host "    Plugin zip not found - building with Maven..."
        # Locate mvn
        $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
        if (-not $mvnCmd) {
            Write-Host "    ERROR: Maven (mvn) is not installed or not in PATH." -ForegroundColor Red
            Write-Host "           Install it with: winget install Apache.Maven" -ForegroundColor Red
            Write-Host "           Skipping license validator plugin." -ForegroundColor Yellow
        } else {
            # Use bundled OpenSearch JDK if JAVA_HOME is not set
            if (-not $env:JAVA_HOME) {
                $bundledJdk = Join-Path $BaseDir "opensearch-${Version}-windows-x64\jdk"
                if (Test-Path $bundledJdk) {
                    $env:JAVA_HOME = $bundledJdk
                    Write-Host "    Using bundled OpenSearch JDK: $bundledJdk"
                }
            }
            $pomFile = Join-Path $LicenseValidatorDir "license-validator\pom.xml"
            Write-Host "    Running: mvn clean package -f $pomFile"
            & mvn clean package -f $pomFile -q
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Maven build succeeded."
            } else {
                Write-Host "    ERROR: Maven build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
                Write-Host "           Ensure Java 17+ and Maven are installed." -ForegroundColor Red
            }
            $pluginZip = Get-ChildItem -Path (Join-Path $LicenseValidatorDir "license-validator\target\releases") -Filter "supra-license-validator-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if ($pluginZip) {
        Copy-Item $pluginZip.FullName -Destination (Join-Path $Staging "license-validator\")
        Write-Host "    Plugin zip staged: $($pluginZip.Name)"
    } else {
        Write-Host "    WARNING: License validator plugin zip not available. Skipping." -ForegroundColor Yellow
    }
    $pubKey = Join-Path $LicenseValidatorDir "keys\public.key"
    if (Test-Path $pubKey) {
        Copy-Item $pubKey -Destination (Join-Path $Staging "license-validator\")
        Write-Host "    Public key staged."
    }
    $fpScript = Join-Path $LicenseValidatorDir "get-fingerprint.ps1"
    if (Test-Path $fpScript) {
        Copy-Item $fpScript -Destination (Join-Path $Staging "license-validator\")
        Write-Host "    Fingerprint script staged."
    }
}

# ---------------------------------------------------------------------------
# Package Index Management backend plugin (auto-build with Gradle if zip is missing)
# ---------------------------------------------------------------------------
if (Test-Path $IndexManagementDir) {
    Write-Host "  Packaging Index Management plugin..."
    $imPluginZip = Get-ChildItem -Path (Join-Path $IndexManagementDir "build\distributions") -Filter "opensearch-index-management-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $imPluginZip) {
        Write-Host "    Plugin zip not found - building with Gradle..."
        $gradlewCmd = Join-Path $IndexManagementDir "gradlew.bat"
        if (-not (Test-Path $gradlewCmd)) {
            Write-Host "    ERROR: gradlew.bat not found in $IndexManagementDir" -ForegroundColor Red
            Write-Host "           Skipping Index Management plugin." -ForegroundColor Yellow
        } else {
            # Use bundled OpenSearch JDK if JAVA_HOME is not set
            if (-not $env:JAVA_HOME) {
                $bundledJdk = Join-Path $BaseDir "opensearch-${Version}-windows-x64\jdk"
                if (Test-Path $bundledJdk) {
                    $env:JAVA_HOME = $bundledJdk
                    Write-Host "    Using bundled OpenSearch JDK: $bundledJdk"
                }
            }
            Write-Host "    Running: gradlew assemble (this may take a while)..."
            Push-Location $IndexManagementDir
            try {
                & $gradlewCmd assemble -x test -q
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Gradle build succeeded."
                } else {
                    Write-Host "    ERROR: Gradle build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
                    Write-Host "           Ensure Java 17+ is installed." -ForegroundColor Red
                }
            } finally {
                Pop-Location
            }
            $imPluginZip = Get-ChildItem -Path (Join-Path $IndexManagementDir "build\distributions") -Filter "opensearch-index-management-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if ($imPluginZip) {
        Copy-Item $imPluginZip.FullName -Destination (Join-Path $Staging "index-management\")
        Write-Host "    Plugin zip staged: $($imPluginZip.Name)"
    } else {
        Write-Host "    WARNING: Index Management plugin zip not available. Skipping." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Package NSSM
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/8] Packaging NSSM service manager..."
if (Test-Path $NssmZip) {
    $nssmExtract = Join-Path $BuildDir "nssm-extract"
    Expand-Archive -Path $NssmZip -DestinationPath $nssmExtract -Force
    $nssmExe = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" | Where-Object { $_.Directory.Name -eq "win64" } | Select-Object -First 1
    if ($nssmExe) {
        Copy-Item $nssmExe.FullName -Destination (Join-Path $Staging "nssm\nssm.exe")
        Write-Host "  NSSM (64-bit) staged."
    } else {
        Write-Host "  WARNING: Could not find nssm.exe (win64) in archive." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARNING: NSSM zip not found. Services will need manual setup." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Create the install script
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/8] Creating install and uninstall scripts..."

$installScript = @'
################################################################################
# Supra Stack Installer (Windows Server)
#
# Installs Supra Search Engine, Supra Dashboards, and Supra Log Collector
# as Windows Services. Must be run as Administrator.
################################################################################

#Requires -RunAsAdministrator

# ---- CONFIGURABLE: Change this to install on a different drive/path ----
param(
    [string]$InstallPath = "C:\supra"
)

$ErrorActionPreference = "Stop"

# ---- Ensure scripts can run on this machine ----
$currentPolicy = Get-ExecutionPolicy -Scope LocalMachine
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "AllSigned") {
    Write-Host "[INFO]  Setting ExecutionPolicy to RemoteSigned for LocalMachine..." -ForegroundColor Green
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
}

$InstallDir = $InstallPath
# ------------------------------------------------------------------------

# ---- Track installation time ----
$InstallStartTime = Get-Date
Write-Host "  Started : $($InstallStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan

$SupraUser  = "SupraService"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Log($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "============================================"
Write-Host "  Supra Stack Installer (Windows Server)"
Write-Host "============================================"
Write-Host ""
Write-Host "Install directory: $InstallDir"
Write-Host ""

$AdminPassword = "admin"

# ---- Create local service account ----
Log "Creating local service account '$SupraUser'..."
$userExists = Get-LocalUser -Name $SupraUser -ErrorAction SilentlyContinue
if ($userExists) {
    Warn "User '$SupraUser' already exists, skipping."
} else {
    $securePass = ConvertTo-SecureString "Supra@Service123!" -AsPlainText -Force
    New-LocalUser -Name $SupraUser -Password $securePass -PasswordNeverExpires -Description "Supra service account" | Out-Null
    Log "  Service account created."
}

# Grant Log on as a service right
$tempCfg = [System.IO.Path]::GetTempFileName()
secedit /export /cfg $tempCfg | Out-Null
$content = Get-Content $tempCfg
$serviceLogonRight = $content | Where-Object { $_ -match "SeServiceLogonRight" }
if ($serviceLogonRight -and $serviceLogonRight -notmatch $SupraUser) {
    $content = $content -replace "(SeServiceLogonRight.*)", "`$1,$SupraUser"
    $content | Set-Content $tempCfg
    secedit /configure /db ([System.IO.Path]::GetTempFileName()) /cfg $tempCfg /areas USER_RIGHTS | Out-Null
    Log "  Granted 'Log on as a service' right."
}
Remove-Item $tempCfg -ErrorAction SilentlyContinue

# ---- Create install directory ----
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

# ---- Locate NSSM and copy to install directory ----
$NssmExe = Join-Path $ScriptDir "nssm\nssm.exe"
if (-not (Test-Path $NssmExe)) {
    Err "NSSM not found at $NssmExe. Cannot register Windows services."
    Err "Download NSSM from https://nssm.cc and place nssm.exe in the nssm\ folder."
    exit 1
}
Log "NSSM found: $NssmExe"

# Copy NSSM to install directory and add to system PATH
$nssmInstallDir = Join-Path $InstallDir "nssm"
if (-not (Test-Path $nssmInstallDir)) { New-Item -ItemType Directory -Path $nssmInstallDir -Force | Out-Null }
Copy-Item $NssmExe -Destination (Join-Path $nssmInstallDir "nssm.exe") -Force
Log "  NSSM copied to $nssmInstallDir"

# Add NSSM to system PATH if not already present
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$nssmInstallDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$nssmInstallDir", "Machine")
    $env:Path = "$env:Path;$nssmInstallDir"
    Log "  NSSM added to system PATH."
} else {
    Log "  NSSM already in system PATH."
}

# ---- Install Supra Search Engine ----
Log "Installing Supra Search Engine..."
$osZip = Get-ChildItem -Path (Join-Path $ScriptDir "opensearch") -Filter "opensearch-*.zip" | Select-Object -First 1
if (-not $osZip) {
    Err "Search engine zip not found in $ScriptDir\opensearch\"
    exit 1
}

$osInstallDir = Join-Path $InstallDir "opensearch"
if (Test-Path $osInstallDir) { Remove-Item -Recurse -Force $osInstallDir }
New-Item -ItemType Directory -Path $osInstallDir -Force | Out-Null

Log "  Extracting Supra Search Engine (this may take a moment)..."
$osTempDir = Join-Path $env:TEMP "opensearch-extract"
if (Test-Path $osTempDir) { Remove-Item -Recurse -Force $osTempDir }
Expand-Archive -Path $osZip.FullName -DestinationPath $osTempDir -Force

$osTopDir = Get-ChildItem -Path $osTempDir -Directory | Select-Object -First 1
if ($osTopDir) {
    Get-ChildItem -Path $osTopDir.FullName | Move-Item -Destination $osInstallDir -Force
} else {
    Get-ChildItem -Path $osTempDir | Move-Item -Destination $osInstallDir -Force
}
Remove-Item -Recurse -Force $osTempDir

# Initialize security plugin demo certificates
$securityPluginDir = Join-Path $osInstallDir "plugins\opensearch-security"
if (Test-Path $securityPluginDir) {
    Log "  Initializing security demo certificates..."
    $demoBat = Join-Path $securityPluginDir "tools\install_demo_configuration.bat"
    if (Test-Path $demoBat) {
        $env:OPENSEARCH_INITIAL_ADMIN_PASSWORD = "MyS3cur!tyP@ss"
        Push-Location $osInstallDir
        & cmd.exe /c "`"$demoBat`" -y -i -s" 2>&1 | Select-Object -Last 5
        Pop-Location
        Remove-Item Env:\OPENSEARCH_INITIAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue
        Log "  Security demo certificates installed."
    } else {
        $demoSh = Join-Path $securityPluginDir "tools\install_demo_configuration.sh"
        if ((Test-Path $demoSh) -and (Get-Command bash -ErrorAction SilentlyContinue)) {
            $env:OPENSEARCH_INITIAL_ADMIN_PASSWORD = "MyS3cur!tyP@ss"
            Push-Location $osInstallDir
            & bash $demoSh -y -i -s 2>&1 | Select-Object -Last 5
            Pop-Location
            Remove-Item Env:\OPENSEARCH_INITIAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue
            Log "  Security demo certificates installed (via bash)."
        } else {
            Warn "  Demo configuration script not found. Certificates may need manual setup."
        }
    }

    # Reset admin password hash to default "admin"
    $internalUsers = Join-Path $osInstallDir "config\opensearch-security\internal_users.yml"
    if (Test-Path $internalUsers) {
        $iuContent = Get-Content $internalUsers -Raw
        $adminHash = '$2a$12$VcCDgh2NDk07JGN0rjGbM.Ad41qVR/YFJcgHp0UGns5JDymv..TOG'
        $iuContent = [regex]::Replace(
            $iuContent,
            '(?s)(^admin:\s*\n(?:[ \t]+[^\n]*\n)*?[ \t]+hash:\s*")[^"]*(")',
            { param($m) $m.Groups[1].Value + $adminHash + $m.Groups[2].Value },
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        )
        [System.IO.File]::WriteAllText($internalUsers, $iuContent, [System.Text.UTF8Encoding]::new($false))
        Log "  Admin password reset to default (admin/admin)."
    }
}

# Apply custom config
Copy-Item (Join-Path $ScriptDir "opensearch\opensearch.yml") -Destination (Join-Path $osInstallDir "config\opensearch.yml") -Force

# Set JVM heap (50% of RAM, max 8GB)
$totalMemMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$heapMB = [math]::Min([math]::Max([math]::Round($totalMemMB / 2), 512), 8192)

$jvmOptions = Join-Path $osInstallDir "config\jvm.options"
if (Test-Path $jvmOptions) {
    $jvmContent = Get-Content $jvmOptions
    $jvmContent = $jvmContent -replace '^-Xms.*', "-Xms${heapMB}m"
    $jvmContent = $jvmContent -replace '^-Xmx.*', "-Xmx${heapMB}m"
    [System.IO.File]::WriteAllLines($jvmOptions, $jvmContent, [System.Text.UTF8Encoding]::new($false))
    Log "  JVM heap set to ${heapMB}m"
}

# Set permissions
$acl = Get-Acl $osInstallDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($SupraUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $osInstallDir -AclObject $acl -ErrorAction SilentlyContinue
Log "  Supra Search Engine installed to $osInstallDir"

# ---- Install Supra License Validator Plugin ----
Log "Installing Supra License Validator plugin..."
$licPluginZip = Get-ChildItem -Path (Join-Path $ScriptDir "license-validator") -Filter "supra-license-validator-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($licPluginZip) {
    # Encode spaces as %20 so Java URI.create() does not throw IllegalArgumentException
    $pluginUri = "file:///" + ($licPluginZip.FullName -replace '[\\]', '/' -replace ' ', '%20')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $pluginResult = & (Join-Path $osInstallDir "bin\opensearch-plugin.bat") install --batch $pluginUri 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "  License validator plugin installed."
        } else {
            Warn "  License validator plugin install failed (exit $LASTEXITCODE):"
            $pluginResult | ForEach-Object { Warn "    $_" }
            Warn "  Plugin zip may be built for a different OpenSearch version."
            Warn "  Continuing install - place a compatible plugin zip and re-run."
        }
    } catch {
        Warn "  License validator plugin install threw an exception: $_"
        Warn "  Continuing install - place a compatible plugin zip and re-run."
    } finally {
        $ErrorActionPreference = $prev
    }
} else {
    Warn "  License validator plugin zip not found. Skipping."
}

# Create license config directory
$licenseConfigDir = Join-Path $osInstallDir "config\supra-license"
if (-not (Test-Path $licenseConfigDir)) { New-Item -ItemType Directory -Path $licenseConfigDir -Force | Out-Null }
$pubKeySrc = Join-Path $ScriptDir "license-validator\public.key"
if (Test-Path $pubKeySrc) {
    Copy-Item $pubKeySrc -Destination $licenseConfigDir
    Log "  Public key installed."
}
$fpScriptSrc = Join-Path $ScriptDir "license-validator\get-fingerprint.ps1"
if (Test-Path $fpScriptSrc) {
    Copy-Item $fpScriptSrc -Destination $licenseConfigDir
    Log "  Fingerprint tool installed."
}

# ---- Install Index Management Plugin (custom build replaces the bundled one) ----
Log "Installing Index Management plugin..."
$imPluginZip = Get-ChildItem -Path (Join-Path $ScriptDir "index-management") -Filter "opensearch-index-management-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($imPluginZip) {
    $pluginBat = Join-Path $osInstallDir "bin\opensearch-plugin.bat"
    # The full OpenSearch distribution already ships opensearch-index-management.
    # Remove it first so the custom build can install cleanly.
    if (Test-Path (Join-Path $osInstallDir "plugins\opensearch-index-management")) {
        Log "  Removing bundled opensearch-index-management before installing custom build..."
        $prevE = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $pluginBat remove --purge opensearch-index-management 2>&1 | Out-Null
        } catch {
            Warn "  Remove of bundled index-management threw: $_"
        } finally {
            $ErrorActionPreference = $prevE
        }
    }

    $pluginUri = "file:///" + ($imPluginZip.FullName -replace '[\\]', '/' -replace ' ', '%20')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $pluginResult = & $pluginBat install --batch $pluginUri 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "  Index Management plugin installed (custom build)."
        } else {
            Warn "  Index Management plugin install failed (exit $LASTEXITCODE):"
            $pluginResult | ForEach-Object { Warn "    $_" }
            Warn "  Plugin zip may be built for a different OpenSearch version."
            Warn "  Continuing install - place a compatible plugin zip and re-run."
        }
    } catch {
        Warn "  Index Management plugin install threw an exception: $_"
        Warn "  Continuing install - place a compatible plugin zip and re-run."
    } finally {
        $ErrorActionPreference = $prev
    }
} else {
    Log "  No custom Index Management zip staged - keeping the bundled plugin."
}

# ---- Install Supra Dashboards ----
Log "Installing Supra Dashboards..."
$osdZip = Get-ChildItem -Path (Join-Path $ScriptDir "dashboards") -Filter "opensearch-dashboards-*.zip" | Select-Object -First 1
if (-not $osdZip) {
    Err "Dashboards zip not found in $ScriptDir\dashboards\"
    exit 1
}

$osdInstallDir = Join-Path $InstallDir "dashboards"
if (Test-Path $osdInstallDir) { Remove-Item -Recurse -Force $osdInstallDir }
New-Item -ItemType Directory -Path $osdInstallDir -Force | Out-Null

Log "  Extracting Supra Dashboards..."
$osdTempDir = Join-Path $env:TEMP "dashboards-extract"
if (Test-Path $osdTempDir) { Remove-Item -Recurse -Force $osdTempDir }
Expand-Archive -Path $osdZip.FullName -DestinationPath $osdTempDir -Force

$osdTopDir = Get-ChildItem -Path $osdTempDir -Directory | Select-Object -First 1
if ($osdTopDir) {
    Get-ChildItem -Path $osdTopDir.FullName | Move-Item -Destination $osdInstallDir -Force
} else {
    Get-ChildItem -Path $osdTempDir | Move-Item -Destination $osdInstallDir -Force
}
Remove-Item -Recurse -Force $osdTempDir

# Install extra dashboards plugins
$pluginsSource = Join-Path $ScriptDir "dashboards-plugins"
if (Test-Path $pluginsSource) {
    Get-ChildItem -Path $pluginsSource -Filter "*.zip" | ForEach-Object {
        $pluginName = $_.BaseName -replace '-[\d].*', ''
        Log "  Installing dashboards plugin: $pluginName..."
        $pluginTmp = Join-Path $env:TEMP "osd-plugin-tmp"
        if (Test-Path $pluginTmp) { Remove-Item -Recurse -Force $pluginTmp }
        Expand-Archive -Path $_.FullName -DestinationPath $pluginTmp -Force
        $osdSubDir = Join-Path $pluginTmp "opensearch-dashboards"
        if (Test-Path $osdSubDir) {
            Get-ChildItem -Path $osdSubDir | Copy-Item -Recurse -Destination (Join-Path $osdInstallDir "plugins\") -Force
            Log "    Plugin $pluginName installed."
        } else {
            Warn "    Plugin $pluginName has unexpected zip structure, skipping."
        }
        Remove-Item -Recurse -Force $pluginTmp -ErrorAction SilentlyContinue
    }
}

# Apply config
Copy-Item (Join-Path $ScriptDir "dashboards\opensearch_dashboards.yml") -Destination (Join-Path $osdInstallDir "config\opensearch_dashboards.yml") -Force

# Add security config if security plugin is present
if (Test-Path (Join-Path $osdInstallDir "plugins\securityDashboards")) {
    Log "  Security plugin detected - adding security config..."
    $secConf = @"

opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
opensearch_security.cookie.secure: false
opensearch_security.ui.basicauth.login.title: "Log in to Supra Dashboard"
"@
    Add-Content -Path (Join-Path $osdInstallDir "config\opensearch_dashboards.yml") -Value $secConf
}

# Copy branding assets
$brandingDest = Join-Path $osdInstallDir "src\core\server\core_app\assets\default_branding"
if (-not (Test-Path $brandingDest)) { New-Item -ItemType Directory -Path $brandingDest -Force | Out-Null }
$brandingSrc = Join-Path $ScriptDir "branding"
if (Test-Path (Join-Path $brandingSrc "scpl.png")) {
    Copy-Item (Join-Path $brandingSrc "scpl.png")    -Destination $brandingDest -Force
    Copy-Item (Join-Path $brandingSrc "favicon.png") -Destination $brandingDest -Force
}

$acl = Get-Acl $osdInstallDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($SupraUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $osdInstallDir -AclObject $acl -ErrorAction SilentlyContinue
Log "  Supra Dashboards installed to $osdInstallDir"

# ---- Install Supra Log Collector (Fluentd / td-agent) ----
# Fully offline: uses the bundled td-agent MSI. td-agent 4.5.2 already ships
# fluent-plugin-opensearch + opensearch-ruby, so no gem install is needed on
# the target machine.
Log "Installing Supra Log Collector..."
$logCollectorDir = Join-Path $InstallDir "log-collector"
if (-not (Test-Path $logCollectorDir)) { New-Item -ItemType Directory -Path $logCollectorDir -Force | Out-Null }

$tdAgentPath = "C:\opt\td-agent"
$fluentdExe  = $null
$fluentdCandidate = Join-Path $tdAgentPath "bin\fluentd.bat"

if (Test-Path $fluentdCandidate) {
    $fluentdExe = $fluentdCandidate
    Log "  Log Collector runtime already present at $tdAgentPath"
} else {
    # Folder may exist as empty leftover from a previous uninstall — clean it up
    # so msiexec can do a fresh install.
    if (Test-Path $tdAgentPath) {
        Log "  Stale td-agent folder found (no fluentd.bat). Removing before reinstall..."
        Remove-Item -Recurse -Force $tdAgentPath -ErrorAction SilentlyContinue
    }
    $bundledMsi = Get-ChildItem -Path (Join-Path $ScriptDir "log-collector") -Filter "td-agent-*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bundledMsi) {
        Err "  Bundled td-agent MSI not found in $ScriptDir\log-collector\."
        Err "  The installer package is incomplete. Re-build with build-installer.ps1."
        exit 1
    }
    Log "  Installing td-agent from bundled MSI: $($bundledMsi.Name)"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($bundledMsi.FullName)`" /quiet /norestart" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Err "  td-agent MSI install failed (exit $($proc.ExitCode))."
        exit 1
    }
    $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"
    Log "  td-agent installed to $tdAgentPath (fluent-plugin-opensearch already included)."
}

# Write log collector config
$logCollectorConf = @"
## Supra Log Collector configuration

# Syslog input
<source>
  @type syslog
  port 514
  tag system
</source>

# Forward input (for other log collection agents)
<source>
  @type forward
  port 24224
</source>

# Supra Search Engine output
<match **>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password $AdminPassword
  logstash_format true
  logstash_prefix fluentd
  flush_interval 10s
</match>
"@
$logCollectorConf | Out-File -FilePath (Join-Path $logCollectorDir "fluent.conf") -Encoding UTF8

$acl = Get-Acl $logCollectorDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($SupraUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $logCollectorDir -AclObject $acl -ErrorAction SilentlyContinue
Log "  Supra Log Collector installed to $logCollectorDir"

# ---- Register Windows Services via NSSM ----
Log "Registering Windows services via NSSM..."

# Pre-create log folders so NSSM AppStdout/AppStderr can write from first start
New-Item -ItemType Directory -Path (Join-Path $osInstallDir  "logs") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $osdInstallDir "logs") -Force | Out-Null
New-Item -ItemType Directory -Path $logCollectorDir -Force | Out-Null

# -- Supra Search Engine Service --
$osBat = Join-Path $osInstallDir "bin\opensearch.bat"
if (Test-Path $osBat) {
    try { & $NssmExe stop "SupraSearch" 2>&1 | Out-Null } catch {}
    try { & $NssmExe remove "SupraSearch" confirm 2>&1 | Out-Null } catch {}

    & $NssmExe install "SupraSearch" $osBat
    & $NssmExe set "SupraSearch" DisplayName "Supra Search Engine"
    & $NssmExe set "SupraSearch" Description "Supra Search Engine service"
    & $NssmExe set "SupraSearch" AppDirectory $osInstallDir
    & $NssmExe set "SupraSearch" Start SERVICE_AUTO_START
    & $NssmExe set "SupraSearch" AppRestartDelay 10000
    & $NssmExe set "SupraSearch" AppStdout (Join-Path $osInstallDir "logs\search-stdout.log")
    & $NssmExe set "SupraSearch" AppStderr (Join-Path $osInstallDir "logs\search-stderr.log")
    & $NssmExe set "SupraSearch" AppEnvironmentExtra "OPENSEARCH_HOME=$osInstallDir" "OPENSEARCH_JAVA_HOME=$(Join-Path $osInstallDir 'jdk')"
    Log "  SupraSearch service registered."
} else {
    Warn "  Search engine binary not found. Service not registered."
}

# -- Supra Dashboards Service --
$osdBat = Join-Path $osdInstallDir "bin\opensearch-dashboards.bat"
if (Test-Path $osdBat) {
    try { & $NssmExe stop "SupraDashboards" 2>&1 | Out-Null } catch {}
    try { & $NssmExe remove "SupraDashboards" confirm 2>&1 | Out-Null } catch {}

    & $NssmExe install "SupraDashboards" $osdBat
    & $NssmExe set "SupraDashboards" DisplayName "Supra Dashboards"
    & $NssmExe set "SupraDashboards" Description "Supra Dashboards web UI"
    & $NssmExe set "SupraDashboards" AppDirectory $osdInstallDir
    & $NssmExe set "SupraDashboards" Start SERVICE_AUTO_START
    & $NssmExe set "SupraDashboards" AppRestartDelay 10000
    & $NssmExe set "SupraDashboards" AppStdout (Join-Path $osdInstallDir "logs\dashboards-stdout.log")
    & $NssmExe set "SupraDashboards" AppStderr (Join-Path $osdInstallDir "logs\dashboards-stderr.log")
    & $NssmExe set "SupraDashboards" DependOnService "SupraSearch"
    Log "  SupraDashboards service registered."
} else {
    Warn "  Dashboards binary not found. Service not registered."
}

# -- Supra Log Collector Service --
if ($fluentdExe) {
    try { & $NssmExe stop "SupraLogCollector" 2>&1 | Out-Null } catch {}
    try { & $NssmExe remove "SupraLogCollector" confirm 2>&1 | Out-Null } catch {}

    & $NssmExe install "SupraLogCollector" $fluentdExe "-c" (Join-Path $logCollectorDir "fluent.conf")
    & $NssmExe set "SupraLogCollector" DisplayName "Supra Log Collector"
    & $NssmExe set "SupraLogCollector" Description "Supra log collection agent"
    & $NssmExe set "SupraLogCollector" Start SERVICE_AUTO_START
    & $NssmExe set "SupraLogCollector" AppRestartDelay 5000
    & $NssmExe set "SupraLogCollector" AppStdout (Join-Path $logCollectorDir "log-collector-stdout.log")
    & $NssmExe set "SupraLogCollector" AppStderr (Join-Path $logCollectorDir "log-collector-stderr.log")
    & $NssmExe set "SupraLogCollector" DependOnService "SupraSearch"
    Log "  SupraLogCollector service registered."
} else {
    Warn "  Log Collector runtime not found. Service not registered."
}

# ---- Configure Windows Firewall ----
Log "Configuring Windows Firewall rules..."
$firewallRules = @(
    @{ Name = "Supra Search Engine";       Port = 9200;  Protocol = "TCP" }
    @{ Name = "Supra Dashboards";          Port = 5601;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector IED Syslog";     Port = 514;   Protocol = "UDP" }
    @{ Name = "Supra Log Collector Windows JSON";   Port = 1514;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Network Syslog"; Port = 2514;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Forward";        Port = 24224; Protocol = "TCP" }
)

foreach ($rule in $firewallRules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.Port | Out-Null
        Log "  Firewall rule added: $($rule.Name) ($($rule.Protocol)/$($rule.Port))"
    } else {
        Warn "  Firewall rule '$($rule.Name)' already exists."
    }
}

# ---- Licensing ----
Write-Host ""
Write-Host "============================================"
Write-Host "  Installation Complete!"
Write-Host "============================================"
Write-Host ""
Write-Host "IMPORTANT: License activation required before starting services." -ForegroundColor Yellow
Write-Host ""
Write-Host "Step 1: Get this machine's fingerprint:"
Write-Host "  powershell -File $osInstallDir\config\supra-license\get-fingerprint.ps1"
Write-Host ""
Write-Host "Step 2: Send the fingerprint (MFP) to your Supra vendor to receive a license.key file."
Write-Host ""
Write-Host "Step 3: Place the license file:"
Write-Host "  Copy-Item license.key -Destination $osInstallDir\config\supra-license\"
Write-Host ""
Write-Host "Step 4: Start services and initialize security (open a NEW terminal so PATH is updated):"
Write-Host "  nssm start SupraSearch"
Write-Host "  # Wait ~30 seconds for Search Engine to be ready, then initialize security:"
Write-Host "  & '$osInstallDir\plugins\opensearch-security\tools\securityadmin.bat' -cd '$osInstallDir\config\opensearch-security\' -icl -nhnv -cacert '$osInstallDir\config\root-ca.pem' -cert '$osInstallDir\config\kirk.pem' -key '$osInstallDir\config\kirk-key.pem'"
Write-Host "  nssm start SupraDashboards"
Write-Host "  nssm start SupraLogCollector"
Write-Host ""
Write-Host "NOTE: NSSM has been added to system PATH at $InstallDir\nssm" -ForegroundColor Cyan
Write-Host "      Open a new terminal/PowerShell window for 'nssm' to be recognized." -ForegroundColor Cyan
Write-Host ""
Write-Host "Services (Windows Services):"
Write-Host "  SupraSearch          - Supra Search Engine  (https://localhost:9200)"
Write-Host "  SupraDashboards      - Supra Dashboards     (http://localhost:5601)"
Write-Host "  SupraLogCollector    - Supra Log Collector  (IEDs UDP/514, Windows UDP/1514, Network UDP/2514, Forward TCP/24224)"
Write-Host ""
Write-Host "Credentials:"
Write-Host "  Username: admin"
Write-Host "  Password: admin"
Write-Host ""
Write-Host "Manage services:"
Write-Host "  nssm start|stop|restart SupraSearch"
Write-Host "  nssm start|stop|restart SupraDashboards"
Write-Host "  nssm start|stop|restart SupraLogCollector"
Write-Host ""
Write-Host "Logs:"
Write-Host "  $InstallDir\opensearch\logs\"
Write-Host "  $InstallDir\dashboards\logs\"
Write-Host "  $InstallDir\log-collector\"
Write-Host ""
Write-Host "NXLog endpoint kit:"
Write-Host "  $ScriptDir\nxlog-agent\  (copy this folder to each Windows endpoint)"
Write-Host "  On each endpoint (as Administrator):"
Write-Host "    .\install-nxlog.ps1 -SupraServerIP <this-server-ip>"
Write-Host ""
Write-Host "Install directory: $InstallDir"
Write-Host ""
$InstallEndTime = Get-Date
$Duration = $InstallEndTime - $InstallStartTime
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Timing Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Started  : $($InstallStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "  Finished : $($InstallEndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "  Duration : $($Duration.Hours)h $($Duration.Minutes)m $($Duration.Seconds)s" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
'@

$installScript | Out-File -FilePath (Join-Path $Staging "install.ps1") -Encoding UTF8

# ---------------------------------------------------------------------------
# Create uninstall script
# ---------------------------------------------------------------------------
$uninstallScript = @'
################################################################################
# Supra Stack Uninstaller (Windows Server)
# Must be run as Administrator.
################################################################################

#Requires -RunAsAdministrator

# ---- CONFIGURABLE: Must match the install path used during installation ----
param(
    [string]$InstallPath = "C:\supra"
)

$ErrorActionPreference = "Stop"

$InstallDir = $InstallPath
# ----------------------------------------------------------------------------

Write-Host "Stopping services..."
foreach ($svc in @("SupraDashboards", "SupraLogCollector", "SupraSearch")) {
    $nssmPath = Join-Path $PSScriptRoot "nssm\nssm.exe"
    if (-not (Test-Path $nssmPath)) {
        $nssmPath = "nssm.exe"
    }

    try { & $nssmPath stop $svc 2>&1 | Out-Null } catch {}
    try { & $nssmPath remove $svc confirm 2>&1 | Out-Null } catch {}
    Write-Host "  $svc removed."
}

Write-Host "Removing firewall rules..."
foreach ($ruleName in @("Supra Search Engine", "Supra Dashboards", "Supra Log Collector Syslog", "Supra Log Collector Forward")) {
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
}

Write-Host "Removing NSSM from system PATH..."
$nssmInstallDir = Join-Path $InstallDir "nssm"
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -like "*$nssmInstallDir*") {
    $newPath = ($currentPath.Split(';') | Where-Object { $_ -ne $nssmInstallDir }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    Write-Host "  NSSM removed from system PATH."
}

Write-Host "Uninstalling td-agent (Fluentd runtime)..."
$tdKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$tdEntry = Get-ItemProperty $tdKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "Td-agent*" } | Select-Object -First 1
if ($tdEntry -and $tdEntry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
    try {
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($tdEntry.PSChildName) /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "  td-agent uninstalled."
        } else {
            Write-Host "  td-agent uninstall returned exit $($proc.ExitCode)."
        }
    } catch {
        Write-Host "  td-agent uninstall threw: $_"
    }
} else {
    Write-Host "  td-agent not found in installed programs, skipping."
}

# Remove any leftover td-agent folder (MSI uninstall leaves empty dirs/logs behind,
# which confuses the installer's presence check on the next install).
if (Test-Path "C:\opt\td-agent") {
    try {
        Remove-Item -Recurse -Force "C:\opt\td-agent" -ErrorAction Stop
        Write-Host "  Leftover td-agent folder removed."
    } catch {
        Write-Host "  Could not remove C:\opt\td-agent (likely held open by a service). Delete it manually after a reboot."
    }
}

Write-Host "Removing installation directory contents..."
if (Test-Path $InstallDir) {
    Get-ChildItem -Path $InstallDir -Force | Remove-Item -Recurse -Force
    Write-Host "  Contents of '$InstallDir' removed (folder kept)."
} else {
    Write-Host "  Directory '$InstallDir' not found, skipping."
}

Write-Host ""
Write-Host "Supra stack uninstalled."
Write-Host "Note: The 'SupraService' user was not removed. To remove:"
Write-Host "  Remove-LocalUser -Name SupraService"
Write-Host "Note: NXLog agents on remote endpoints are NOT touched by this uninstaller."
Write-Host "      Uninstall each endpoint manually with: msiexec /x nxlog-ce-<version>.msi /quiet"
'@

$uninstallScript | Out-File -FilePath (Join-Path $Staging "uninstall.ps1") -Encoding UTF8

Write-Host "  install.ps1 and uninstall.ps1 created."

# ---------------------------------------------------------------------------
# Create the final zip package
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[8/8] Creating installer package..."

$outputZip = Join-Path $BaseDir "${PackageName}-${Version}-windows-x64.zip"
if (Test-Path $outputZip) { Remove-Item $outputZip }

Compress-Archive -Path $Staging -DestinationPath $outputZip -Force

$finalSize = (Get-Item $outputZip).Length / 1MB
$finalSizeStr = "{0:N1} MB" -f $finalSize

Write-Host ""
Write-Host "============================================"
Write-Host "  Installer Package Ready!"
Write-Host "============================================"
Write-Host ""
Write-Host "  Package: $outputZip"
Write-Host "  Size:    $finalSizeStr"
Write-Host ""
Write-Host "  To install on a Windows Server:"
Write-Host "    1. Copy the zip to the target machine"
Write-Host "    2. Extract: Expand-Archive -Path ${PackageName}-${Version}-windows-x64.zip -DestinationPath ."
Write-Host "    3. Install (as Administrator): .\${PackageName}\install.ps1"
Write-Host ""
Write-Host "  To uninstall:"
Write-Host "    .\${PackageName}\uninstall.ps1"
Write-Host ""

# Cleanup build dir
Remove-Item -Recurse -Force $BuildDir
