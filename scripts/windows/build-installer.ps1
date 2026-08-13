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
$IndexTemplateScript = Join-Path $BaseDir "supra-index-template.ps1"
$InitSecurityScript = Join-Path $BaseDir "supra-init-security.ps1"
$DashboardsReportingSrc = Join-Path $BaseDir "dashboards-reporting"
$DashboardsSrc = Join-Path $BaseDir "OpenSearch-Dashboards"

# NSSM download URL
$NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$NssmZip = Join-Path $BaseDir "nssm-2.24.zip"

# Fluentd (fluent-package) offline bundle.
# The MSI is fetched at BUILD time (needs internet on the build host) and then staged
# inside the installer zip so the TARGET machine can install it without internet.
#
# fluent-package 5.0.9 is the SAME runtime the Linux installer deploys, and it is
# what makes the OpenSearch output work at all:
#   * Ruby 3.2 - the older td-agent 4.5.2 shipped Ruby 2.7, on which the
#     faraday 2.x / opensearch-ruby stack cannot even be installed.
#   * fluent-plugin-opensearch 1.1.4 + opensearch-ruby/-transport/-api built in,
#     so no gem closure has to be shipped or installed offline.
# td-agent 4.5.2 shipped fluent-plugin-ELASTICsearch only, so every
# "<match> @type opensearch" block in fluent.conf failed to load and the
# collector died at first start without ever indexing a document.
$FluentPkgMsiUrl  = "https://s3.amazonaws.com/packages.treasuredata.com/lts/5/windows/fluent-package-5.0.9-x64.msi"
$FluentPkgMsiName = "fluent-package-5.0.9-x64.msi"
$FluentPkgMsi     = Join-Path $BaseDir $FluentPkgMsiName

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

if (-not (Test-Path $IndexTemplateScript)) {
    Write-Host "ERROR: Index template script not found at $IndexTemplateScript" -ForegroundColor Red
    Write-Host "       Without it, supra-* indices get guessed mappings and Fluentd hits" -ForegroundColor Red
    Write-Host "       '400 - Rejected by OpenSearch' on type conflicts." -ForegroundColor Red
    exit 1
}
Write-Host "  Index template script: OK"

if (-not (Test-Path $InitSecurityScript)) {
    Write-Host "ERROR: Security init script not found at $InitSecurityScript" -ForegroundColor Red
    Write-Host "       Without it, securityadmin.bat has to be run by hand and fails with" -ForegroundColor Red
    Write-Host "       'Unable to find java runtime' because no JAVA_HOME is set." -ForegroundColor Red
    exit 1
}
Write-Host "  Security init script:  OK"

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

# Download fluent-package MSI if not present (target machine will install this offline)
if (-not (Test-Path $FluentPkgMsi)) {
    Write-Host "  Downloading fluent-package (Fluentd) MSI..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $FluentPkgMsiUrl -OutFile $FluentPkgMsi -UseBasicParsing
        $sizeMB = [math]::Round((Get-Item $FluentPkgMsi).Length / 1MB, 1)
        Write-Host "    fluent-package MSI downloaded (${sizeMB} MB)."
    } catch {
        Write-Host "ERROR: Failed to download fluent-package MSI." -ForegroundColor Red
        Write-Host "       URL: $FluentPkgMsiUrl" -ForegroundColor Red
        Write-Host "       Please download manually and place at: $FluentPkgMsi" -ForegroundColor Red
        Remove-Item -Path $FluentPkgMsi -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    $sizeMB = [math]::Round((Get-Item $FluentPkgMsi).Length / 1MB, 1)
    Write-Host "  fluent-package MSI:   OK (${sizeMB} MB)"
}

# fluent-package 5.0.9 bundles fluent-plugin-opensearch, opensearch-ruby,
# opensearch-transport and the faraday/aws-sigv4 chain they depend on, so the
# MSI is self-contained and no gem closure has to be staged.

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
# Package Supra Log Collector config + Fluentd (fluent-package) offline bundle
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Packaging Supra Log Collector (Fluentd) offline bundle..."
Copy-Item $FluentdConf -Destination (Join-Path $Staging "log-collector\")
Write-Host "  fluent.conf staged."

Copy-Item $IndexTemplateScript -Destination $Staging
Write-Host "  supra-index-template.ps1 staged."

Copy-Item $InitSecurityScript -Destination $Staging
Write-Host "  supra-init-security.ps1 staged."

# Stage fluent-package MSI (includes fluent-plugin-opensearch pre-installed)
Copy-Item $FluentPkgMsi -Destination (Join-Path $Staging "log-collector\")
Write-Host "  fluent-package MSI staged: $FluentPkgMsiName"

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

    # nxlog.conf forwards JSON over om_tcp, which the collector reads on its
    # Windows source (tcp/1514). 5140 is the Linux rsyslog source - not this.
    [int]$SupraPort = 1514
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
# nxlog.conf sets the destination with literal `Host` / `Port` directives inside
# its om_tcp output block (there are no define placeholders), so rewrite those
# directly and keep the original indentation.
$conf = $conf -replace '(?m)^(\s*Host\s+).*$', "`${1}$SupraServerIP"
$conf = $conf -replace '(?m)^(\s*Port\s+).*$', "`${1}$SupraPort"

# Fail loudly rather than shipping a config still pointing at the build-time host.
if ($conf -notmatch "(?m)^\s*Host\s+$([regex]::Escape($SupraServerIP))\s*$") {
    Err "Could not set the destination Host in nxlog.conf."
    Err "Edit $nxlogConfDest manually and set Host to $SupraServerIP."
    exit 1
}
[System.IO.File]::WriteAllText($nxlogConfDest, $conf, [System.Text.UTF8Encoding]::new($false))
Log "  nxlog.conf written to $nxlogConfDest (Host=$SupraServerIP, Port=$SupraPort)"

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
Write-Host "Done. This endpoint will forward Windows event logs as JSON to ${SupraServerIP}:${SupraPort} (TCP)."
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
  3. Run (-ExecutionPolicy Bypass is needed on a stock server, which refuses
     to run unsigned scripts):
       powershell -ExecutionPolicy Bypass -File .\install-nxlog.ps1 -SupraServerIP <your-supra-server-ip>
     Optional (only if the collector was moved off its default port):
       powershell -ExecutionPolicy Bypass -File .\install-nxlog.ps1 -SupraServerIP 10.0.0.5 -SupraPort 1514

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

    # Rebuild when any .java source is newer than the packaged zip. Without this
    # check a stale zip is shipped silently and features added to the plugin
    # (e.g. the /_supra/license REST endpoint) never reach the target machine.
    if ($pluginZip) {
        $srcDir = Join-Path $LicenseValidatorDir "license-validator\src"
        $newestSrc = Get-ChildItem -Path $srcDir -Recurse -Filter "*.java" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newestSrc -and $newestSrc.LastWriteTime -gt $pluginZip.LastWriteTime) {
            Write-Host "    Plugin zip is older than $($newestSrc.Name) - rebuilding." -ForegroundColor Yellow
            $pluginZip = $null
        }
    }

    if (-not $pluginZip) {
        Write-Host "    Building license validator plugin with Maven..."
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
    # License inspector (Windows counterpart of supra-license-info.sh)
    $infoScript = Join-Path $LicenseValidatorDir "supra-license-info.ps1"
    if (Test-Path $infoScript) {
        Copy-Item $infoScript -Destination (Join-Path $Staging "license-validator\")
        Write-Host "    License inspector staged."
    } else {
        Write-Host "    WARNING: supra-license-info.ps1 not found. Operators will have no license inspector." -ForegroundColor Yellow
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

# ---- Ensure scripts can run on this machine ----
# Test the EFFECTIVE policy, not the LocalMachine scope. A stock server leaves
# LocalMachine "Undefined" while the effective policy is still Restricted, so
# checking the scope alone matched nothing, set nothing, and every later
# "powershell -File ...ps1" died with "running scripts is disabled on this
# system". Set LocalMachine first and fall back to CurrentUser, because a
# CurrentUser value overrides LocalMachine and would otherwise keep winning.
$restrictive = @("Restricted", "AllSigned", "Undefined")
if ((Get-ExecutionPolicy) -in $restrictive) {
    foreach ($scope in @("LocalMachine", "CurrentUser")) {
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope $scope -Force -ErrorAction Stop
            Log "  ExecutionPolicy set to RemoteSigned for $scope."
        } catch {
            Warn "  Could not set ExecutionPolicy for ${scope}: $($_.Exception.Message)"
        }
        if ((Get-ExecutionPolicy) -notin $restrictive) { break }
    }
}
if ((Get-ExecutionPolicy) -in $restrictive) {
    # Group Policy (MachinePolicy/UserPolicy scope) cannot be overridden here.
    # Not fatal: every command this installer prints uses -ExecutionPolicy
    # Bypass, which a policy-locked machine still honours for a single process.
    Warn "  ExecutionPolicy is still $(Get-ExecutionPolicy) - most likely enforced by Group Policy."
    Warn "  Run the Supra scripts with:  powershell -ExecutionPolicy Bypass -File <script>"
}

# Strip the Mark-of-the-Web from everything in the bundle. Files extracted from
# a zip that was downloaded or copied off a network share are tagged as coming
# from the internet, and RemoteSigned refuses to run unsigned scripts so tagged.
Get-ChildItem -Path $ScriptDir -Recurse -Include *.ps1, *.psm1, *.bat, *.cmd -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "============================================"
Write-Host "  Supra Stack Installer (Windows Server)"
Write-Host "============================================"
Write-Host ""
Write-Host "Install directory: $InstallDir"
Write-Host ""

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

# Use the permanent copy for service registration so services keep working
# after the extracted installer folder is deleted (SCM stores the exact
# nssm.exe path as the service ImagePath).
$NssmExe = Join-Path $nssmInstallDir "nssm.exe"

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
$infoScriptSrc = Join-Path $ScriptDir "license-validator\supra-license-info.ps1"
if (Test-Path $infoScriptSrc) {
    Copy-Item $infoScriptSrc -Destination $licenseConfigDir
    Log "  License inspector installed."
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

# ---- Install Supra Log Collector (Fluentd / fluent-package) ----
# Fully offline: uses the bundled fluent-package MSI. fluent-package 5.0.9 runs
# on Ruby 3.2 and ships fluent-plugin-opensearch + opensearch-ruby, so no gem
# install is needed on the target machine. This is the same runtime the Linux
# installer deploys.
Log "Installing Supra Log Collector..."
$logCollectorDir = Join-Path $InstallDir "log-collector"
if (-not (Test-Path $logCollectorDir)) { New-Item -ItemType Directory -Path $logCollectorDir -Force | Out-Null }

$fluentPath  = "C:\opt\fluent"
$fluentdExe  = $null
$fluentdCandidate = Join-Path $fluentPath "bin\fluentd.bat"

if (Test-Path $fluentdCandidate) {
    $fluentdExe = $fluentdCandidate
    Log "  Log Collector runtime already present at $fluentPath"
} else {
    # Folder may exist as empty leftover from a previous uninstall — clean it up
    # so msiexec can do a fresh install.
    if (Test-Path $fluentPath) {
        Log "  Stale fluent folder found (no fluentd.bat). Removing before reinstall..."
        Remove-Item -Recurse -Force $fluentPath -ErrorAction SilentlyContinue
    }
    $bundledMsi = Get-ChildItem -Path (Join-Path $ScriptDir "log-collector") -Filter "fluent-package-*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bundledMsi) {
        Err "  Bundled fluent-package MSI not found in $ScriptDir\log-collector\."
        Err "  The installer package is incomplete. Re-build with build-installer.ps1."
        exit 1
    }
    Log "  Installing fluent-package from bundled MSI: $($bundledMsi.Name)"
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$($bundledMsi.FullName)`" /quiet /norestart" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Err "  fluent-package MSI install failed (exit $($proc.ExitCode))."
        exit 1
    }
    $fluentdExe = Join-Path $fluentPath "bin\fluentd.bat"
    # Marker so uninstall.ps1 knows this runtime is ours and may be removed.
    # Without it, an uninstall would delete a Fluentd the operator installed
    # themselves before Supra was ever on the machine.
    "Installed by Supra installer $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" |
        Out-File -FilePath (Join-Path $fluentPath ".supra-installed") -Encoding ascii
    Log "  fluent-package installed to $fluentPath (fluent-plugin-opensearch included)."
}

# The MSI registers its own 'fluentdwinsvc' service, which would race
# SupraLogCollector for ports 514 / 1514 / 2514 / 5140 / 24224. Disable it, the
# same way the Linux installer disables the packaged fluentd.service.
$stockSvc = Get-Service -Name 'fluentdwinsvc' -ErrorAction SilentlyContinue
if ($stockSvc) {
    Stop-Service -Name 'fluentdwinsvc' -Force -ErrorAction SilentlyContinue
    Set-Service  -Name 'fluentdwinsvc' -StartupType Disabled -ErrorAction SilentlyContinue
    Log "  Stock 'fluentdwinsvc' service stopped and disabled (it would fight for the syslog ports)."
}

if (-not (Test-Path $fluentdExe)) {
    Err "  fluentd launcher not found at $fluentdExe after install."
    Err "  The fluent-package install did not complete correctly."
    exit 1
}

# ---- Deploy the packaged log collector config ----
# The hardened, IED-aware fluent.conf ships inside the installer (built from
# fluent\fluent.conf in the repo). It defines dedicated ports per source type:
#   514  udp+tcp  IED syslog        -> supra-ied-*
#   1514 udp+tcp  Windows JSON      -> supra-windows-*
#   2514 udp+tcp  Network syslog    -> supra-network-*
#   5140 udp+tcp  Linux rsyslog     -> supra-logs-*
#   24224 tcp     Fluentd forward
# Do NOT hand-write a config here - it would silently drop the parsing and
# routing rules the collectors depend on.
$packagedConf = Join-Path $ScriptDir "log-collector\fluent.conf"
if (-not (Test-Path $packagedConf)) {
    Err "  Packaged fluent.conf missing from $packagedConf - bundle is incomplete."
    Err "  Re-build the installer with build-installer.ps1."
    exit 1
}
$fluentConfPath = Join-Path $logCollectorDir "fluent.conf"
Copy-Item $packagedConf -Destination $fluentConfPath -Force
Log "  Packaged fluent.conf deployed."

# ---- Translate the Linux buffer paths to this install ----
# The shared fluent.conf declares POSIX buffer paths (/opt/supra/log-collector/
# buffer/*). On Windows those are DRIVE-RELATIVE: they resolve to C:\opt\supra\...
# regardless of -InstallPath. That puts up to 32 GB of buffer (4 x total_limit_size
# 8GB) outside the install tree, outside the ACL grant below, and outside anything
# uninstall.ps1 removes. Rewrite them to sit under the real install directory.
$bufferRoot = (Join-Path $logCollectorDir "buffer")
$bufferRootFwd = $bufferRoot -replace '\\', '/'
$confText = [System.IO.File]::ReadAllText($fluentConfPath, [System.Text.UTF8Encoding]::new($false))
$confText = [regex]::Replace(
    $confText,
    '(?m)^(\s*path\s+)/opt/supra/log-collector/buffer/',
    { param($m) $m.Groups[1].Value + $bufferRootFwd + '/' }
)
[System.IO.File]::WriteAllText($fluentConfPath, $confText, [System.Text.UTF8Encoding]::new($false))

$remainingPosix = ([regex]::Matches($confText, '(?m)^\s*path\s+/opt/supra/')).Count
if ($remainingPosix -gt 0) {
    Warn "  $remainingPosix buffer path(s) still point at /opt/supra - check fluent.conf."
} else {
    Log "  Buffer paths rewritten to $bufferRoot"
}

foreach ($b in @("ied", "network", "windows", "other")) {
    $bp = Join-Path $bufferRoot $b
    if (-not (Test-Path $bp)) { New-Item -ItemType Directory -Path $bp -Force | Out-Null }
}
Log "  Buffer directories created."

# ---- Validate the config before registering the service ----
# A config error here would otherwise surface as a service that starts and
# immediately dies, with the reason buried in the stderr log.
$dryRunLog = Join-Path $env:TEMP "fluentd-dryrun.log"
$prevEA = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & $fluentdExe --dry-run -c $fluentConfPath *> $dryRunLog
    $dryRunOk = ($LASTEXITCODE -eq 0)
} catch {
    $dryRunOk = $false
    "$_" | Out-File -FilePath $dryRunLog -Append
} finally {
    $ErrorActionPreference = $prevEA
}
if ($dryRunOk) {
    Log "  fluent.conf verified (dry-run passed)."
} else {
    # Fail loud here rather than shipping a service that starts and immediately
    # dies with the reason buried in a stderr log. This mirrors the Linux
    # installer, which also treats a failed dry-run as fatal.
    Err "  fluentd config dry-run FAILED:"
    Get-Content $dryRunLog -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object { Err "    $_" }
    Err ""
    Err "  Full log: $dryRunLog"
    Err "  The collector would not start. Aborting so this is fixed now, not after first boot."
    exit 1
}

$acl = Get-Acl $logCollectorDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($SupraUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $logCollectorDir -AclObject $acl -ErrorAction SilentlyContinue
Log "  Supra Log Collector installed to $logCollectorDir"

# ---- Stage the index template installer ----
# Must be run once after SupraSearch is up. Without it, OpenSearch guesses field
# types and Fluentd starts failing with "400 - Rejected by OpenSearch" as soon as
# a field arrives as a number in one event and a string in another.
$templateSrc = Join-Path $ScriptDir "supra-index-template.ps1"
if (Test-Path $templateSrc) {
    Copy-Item $templateSrc -Destination $InstallDir -Force
    Log "  Index template installer staged at $InstallDir\supra-index-template.ps1"
} else {
    Warn "  supra-index-template.ps1 not found in the bundle - index mappings will be guessed."
}

# ---- Stage the security initializer ----
# Wraps securityadmin.bat with the bundled JDK and this install's real paths.
$initSecSrc = Join-Path $ScriptDir "supra-init-security.ps1"
if (Test-Path $initSecSrc) {
    Copy-Item $initSecSrc -Destination $InstallDir -Force
    Log "  Security initializer staged at $InstallDir\supra-init-security.ps1"
} else {
    Warn "  supra-init-security.ps1 not found in the bundle - security must be initialized by hand."
}

# ---- Publish the bundled JDK to interactive shells ----
# The NSSM services get OPENSEARCH_JAVA_HOME via AppEnvironmentExtra, but the
# operator tools do not: securityadmin.bat resolves java ONLY from
# OPENSEARCH_JAVA_HOME or JAVA_HOME and aborts with "Unable to find java
# runtime" when neither is set. Persist it at machine scope (visible to new
# terminals, like the NSSM PATH entry) and set it for this process too.
$bundledJdk = Join-Path $osInstallDir "jdk"
if (Test-Path (Join-Path $bundledJdk "bin\java.exe")) {
    [Environment]::SetEnvironmentVariable("OPENSEARCH_JAVA_HOME", $bundledJdk, "Machine")
    $env:OPENSEARCH_JAVA_HOME = $bundledJdk
    Log "  OPENSEARCH_JAVA_HOME set to $bundledJdk (machine scope)."
} else {
    Warn "  Bundled JDK not found at $bundledJdk - securityadmin will need JAVA_HOME set manually."
}

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
# These mirror every listener in the packaged fluent.conf. Each syslog/JSON
# source binds BOTH udp and tcp, so both need opening - NXLog uses om_tcp on
# 1514, and rsyslog forwarding on 5140 may be either.
$firewallRules = @(
    @{ Name = "Supra Search Engine";       Port = 9200;  Protocol = "TCP" }
    @{ Name = "Supra Dashboards";          Port = 5601;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector IED Syslog UDP";     Port = 514;   Protocol = "UDP" }
    @{ Name = "Supra Log Collector IED Syslog TCP";     Port = 514;   Protocol = "TCP" }
    @{ Name = "Supra Log Collector Windows JSON UDP";   Port = 1514;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Windows JSON TCP";   Port = 1514;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector Network Syslog UDP"; Port = 2514;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Network Syslog TCP"; Port = 2514;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector Linux Syslog UDP";   Port = 5140;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Linux Syslog TCP";   Port = 5140;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector Forward";            Port = 24224; Protocol = "TCP" }
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
Write-Host "NOTE: every command below is shown with the paths for THIS install" -ForegroundColor Cyan
Write-Host "      ($InstallDir) and with -ExecutionPolicy Bypass, which runs the" -ForegroundColor Cyan
Write-Host "      script even where policy blocks scripts. Copy them from here," -ForegroundColor Cyan
Write-Host "      not from the guide, which shows the C:\supra defaults." -ForegroundColor Cyan
Write-Host ""
Write-Host "Step 1: Get this machine's fingerprint:"
Write-Host "  powershell -ExecutionPolicy Bypass -File $osInstallDir\config\supra-license\get-fingerprint.ps1"
Write-Host ""
Write-Host "Step 2: Send the fingerprint (MFP) to your Supra vendor to receive a license.key file."
Write-Host ""
Write-Host "Step 3: Place the license file:"
Write-Host "  Copy-Item license.key -Destination $osInstallDir\config\supra-license\"
Write-Host ""
Write-Host "Step 4: Verify the license before starting (checks type, expiry and signature):"
Write-Host "  powershell -ExecutionPolicy Bypass -File $osInstallDir\config\supra-license\supra-license-info.ps1"
Write-Host "  Exit code 0 = ACTIVE, 2 = EXPIRED or UNTRUSTED."
Write-Host ""
Write-Host "Step 5: Start the search engine (open a NEW terminal so PATH is updated):"
Write-Host "  nssm start SupraSearch"
Write-Host ""
Write-Host "Step 6: Initialize security. This waits for the node, then runs"
Write-Host "        securityadmin with the bundled JDK - do NOT call securityadmin.bat"
Write-Host "        directly, it aborts with 'Unable to find java runtime':"
Write-Host "  powershell -ExecutionPolicy Bypass -File $InstallDir\supra-init-security.ps1"
Write-Host ""
Write-Host "Step 7: Apply the Supra index template (REQUIRED - run once, after the"
Write-Host "        security step above and BEFORE logs start flowing):"
Write-Host "  powershell -ExecutionPolicy Bypass -File $InstallDir\supra-index-template.ps1"
Write-Host "  Without it, field types are guessed and the collector will hit"
Write-Host "  '400 - Rejected by OpenSearch' on the first type conflict."
Write-Host ""
Write-Host "Step 8: Start the remaining services:"
Write-Host "  nssm start SupraDashboards"
Write-Host "  nssm start SupraLogCollector"
Write-Host ""
Write-Host "NOTE: NSSM has been added to system PATH at $InstallDir\nssm" -ForegroundColor Cyan
Write-Host "      Open a new terminal/PowerShell window for 'nssm' to be recognized." -ForegroundColor Cyan
Write-Host ""
Write-Host "Services (Windows Services):"
Write-Host "  SupraSearch          - Supra Search Engine  (https://localhost:9200)"
Write-Host "  SupraDashboards      - Supra Dashboards     (http://localhost:5601)"
Write-Host "  SupraLogCollector    - Supra Log Collector"
Write-Host "      IED syslog     udp+tcp/514   -> supra-ied-*"
Write-Host "      Windows JSON   udp+tcp/1514  -> supra-windows-*"
Write-Host "      Network syslog udp+tcp/2514  -> supra-network-*"
Write-Host "      Linux syslog   udp+tcp/5140  -> supra-logs-*"
Write-Host "      Fluentd fwd    tcp/24224"
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
Write-Host "    powershell -ExecutionPolicy Bypass -File .\install-nxlog.ps1 -SupraServerIP <this-server-ip>"
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
# Names must match install.ps1 exactly, otherwise rules are orphaned and keep
# the collector ports open after uninstall.
$ruleNames = @(
    "Supra Search Engine"
    "Supra Dashboards"
    "Supra Log Collector IED Syslog UDP"
    "Supra Log Collector IED Syslog TCP"
    "Supra Log Collector Windows JSON UDP"
    "Supra Log Collector Windows JSON TCP"
    "Supra Log Collector Network Syslog UDP"
    "Supra Log Collector Network Syslog TCP"
    "Supra Log Collector Linux Syslog UDP"
    "Supra Log Collector Linux Syslog TCP"
    "Supra Log Collector Forward"
    # Legacy names from earlier builds - removed so upgrades do not leave them behind.
    "Supra Log Collector Syslog"
    "Supra Log Collector IED Syslog"
    "Supra Log Collector Windows JSON"
    "Supra Log Collector Network Syslog"
)
foreach ($ruleName in $ruleNames) {
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
}
Write-Host "  Firewall rules removed."

Write-Host "Removing NSSM from system PATH..."
$nssmInstallDir = Join-Path $InstallDir "nssm"
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -like "*$nssmInstallDir*") {
    $newPath = ($currentPath.Split(';') | Where-Object { $_ -ne $nssmInstallDir }) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    Write-Host "  NSSM removed from system PATH."
}

# install.ps1 publishes the bundled JDK here so securityadmin.bat can find a
# runtime. Only clear it if it still points inside the tree we are removing -
# an operator may have repointed it at their own JDK.
$javaHomeVar = [Environment]::GetEnvironmentVariable("OPENSEARCH_JAVA_HOME", "Machine")
if ($javaHomeVar -and $javaHomeVar -like "$InstallDir*") {
    [Environment]::SetEnvironmentVariable("OPENSEARCH_JAVA_HOME", $null, "Machine")
    Write-Host "  OPENSEARCH_JAVA_HOME removed from system environment."
}

Write-Host "Uninstalling Fluentd runtime..."
$tdKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
# "Fluent Package v5.x" is the current runtime; "Td-agent*" is matched too so
# this uninstaller still cleans up servers built with an older installer.
$tdEntry = Get-ItemProperty $tdKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "Fluent Package*" -or $_.DisplayName -like "Td-agent*" } |
    Select-Object -First 1
if ($tdEntry -and $tdEntry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
    try {
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($tdEntry.PSChildName) /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "  $($tdEntry.DisplayName) uninstalled."
        } else {
            Write-Host "  Fluentd runtime uninstall returned exit $($proc.ExitCode)."
        }
    } catch {
        Write-Host "  Fluentd runtime uninstall threw: $_"
    }
} else {
    Write-Host "  Fluentd runtime not found in installed programs, skipping."
}

# Remove any leftover runtime folder (MSI uninstall leaves empty dirs/logs behind,
# which confuses the installer's presence check on the next install).
#
# Only ever remove a runtime WE installed. install.ps1 records that by dropping
# .supra-installed into the runtime folder; if the marker is absent the Fluentd
# install predates us (the operator already had one) and deleting it would
# destroy unrelated software.
foreach ($leftover in @("C:\opt\fluent", "C:\opt\td-agent")) {
    if (-not (Test-Path $leftover)) { continue }
    if (-not (Test-Path (Join-Path $leftover ".supra-installed"))) {
        Write-Host "  Leaving $leftover in place - it was not installed by Supra."
        continue
    }
    try {
        Remove-Item -Recurse -Force $leftover -ErrorAction Stop
        Write-Host "  Leftover folder removed: $leftover"
    } catch {
        Write-Host "  Could not remove $leftover (likely held open by a service). Delete it manually after a reboot."
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

# Compress-Archive buffers in memory and is unusably slow at this size (>1 GB).
# The payload is almost entirely pre-compressed zips and an MSI, so storing
# without recompression is both far faster and no larger.
#
# Entries are written by hand rather than with ZipFile::CreateFromDirectory
# because the .NET Framework build of that helper emits backslash separators,
# which the ZIP spec forbids. Windows tolerates it; 7-Zip and every Unix
# extractor produce one flatly-named file per entry instead of a tree.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($outputZip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $stagingRoot = Split-Path -Parent $Staging
    foreach ($file in Get-ChildItem -Path $Staging -Recurse -File) {
        $rel = $file.FullName.Substring($stagingRoot.Length).TrimStart('\')
        $entryName = $rel -replace '\\', '/'
        $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
        $entryStream = $entry.Open()
        try {
            $fileStream = [System.IO.File]::OpenRead($file.FullName)
            try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose() }
        } finally { $entryStream.Dispose() }
    }
} finally {
    $archive.Dispose()
}

$finalSize = (Get-Item $outputZip).Length / 1MB
$finalSizeStr = "{0:N1} MB" -f $finalSize

# Emit a checksum alongside the package, matching the Linux build output, so the
# transfer to the test machine can be verified.
$sha = (Get-FileHash -Path $outputZip -Algorithm SHA256).Hash.ToLower()
"$sha  $(Split-Path -Leaf $outputZip)" | Out-File -FilePath "${outputZip}.sha256" -Encoding ascii
Write-Host "  SHA256: $sha"

Write-Host ""
Write-Host "============================================"
Write-Host "  Installer Package Ready!"
Write-Host "============================================"
Write-Host ""
Write-Host "  Package: $outputZip"
Write-Host "  Size:    $finalSizeStr"
Write-Host ""
Write-Host "  To install on a Windows Server (run PowerShell as Administrator):"
Write-Host "    1. Copy the zip to the target machine"
Write-Host "    2. Unblock and extract (Unblock-File strips the internet tag that"
Write-Host "       otherwise blocks every script in the bundle):"
Write-Host "       Unblock-File -Path ${PackageName}-${Version}-windows-x64.zip"
Write-Host "       Expand-Archive -Path ${PackageName}-${Version}-windows-x64.zip -DestinationPath ."
Write-Host "    3. Install:"
Write-Host "       powershell -ExecutionPolicy Bypass -File .\${PackageName}\install.ps1"
Write-Host "       # optional, to install somewhere other than C:\supra:"
Write-Host "       powershell -ExecutionPolicy Bypass -File .\${PackageName}\install.ps1 -InstallPath D:\Supra"
Write-Host ""
Write-Host "  -ExecutionPolicy Bypass is required: a stock Windows Server refuses to"
Write-Host "  run unsigned scripts, and install.ps1 cannot lift that restriction"
Write-Host "  before it has been allowed to start."
Write-Host ""
Write-Host "  To uninstall:"
Write-Host "    powershell -ExecutionPolicy Bypass -File .\${PackageName}\uninstall.ps1"
Write-Host ""

# Cleanup build dir
Remove-Item -Recurse -Force $BuildDir
