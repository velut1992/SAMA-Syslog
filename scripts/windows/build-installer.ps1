################################################################################
# Supra Installer Package Builder (Windows Server x64)
#
# Builds a self-contained installer zip that can be deployed on a Windows Server
# x64 machine. The package includes:
#   - Supra Search Engine (full distribution with all plugins)
#   - Supra Dashboards (full distribution with all plugins)
#   - Extra Dashboards plugins (SIEM, Index Management, Notifications)
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
$DashboardsSrc = Join-Path $BaseDir "OpenSearch-Dashboards"

# NSSM download URL
$NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$NssmZip = Join-Path $BaseDir "nssm-2.24.zip"

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
foreach ($sub in @("opensearch", "dashboards", "dashboards-plugins", "log-collector", "nssm", "branding", "license-validator")) {
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
# Package Supra Log Collector config
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/8] Packaging Supra Log Collector config..."
Copy-Item $FluentdConf -Destination (Join-Path $Staging "log-collector\")
Write-Host "  Log Collector config staged."

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
        $iuContent = $iuContent -replace '(hash:\s*")[^"]*(")', '${"1"}$2a$12$VcCDgh2NDk07JGN0rjGbM.Ad41qVR/YFJcgHp0UGns5JDymv..TOG${"2"}'
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

opensearch_security.multitenancy.enabled: true
opensearch_security.multitenancy.tenants.preferred: ["Private", "Global"]
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
opensearch_security.cookie.secure: false
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

# ---- Install Supra Log Collector ----
Log "Installing Supra Log Collector..."
$logCollectorDir = Join-Path $InstallDir "log-collector"
if (-not (Test-Path $logCollectorDir)) { New-Item -ItemType Directory -Path $logCollectorDir -Force | Out-Null }

# Check if td-agent (log collector runtime for Windows) is installed
$tdAgentPath = "C:\opt\td-agent"
$fluentdExe = $null

if (Test-Path $tdAgentPath) {
    $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"
    Log "  Log Collector runtime found at $tdAgentPath"
} elseif (Get-Command fluentd -ErrorAction SilentlyContinue) {
    $fluentdExe = (Get-Command fluentd).Source
    Log "  Log Collector runtime found at $fluentdExe"
} else {
    Log "  Log Collector runtime not found. Attempting automatic download and install..."
    $tdAgentMsiUrl = "https://s3.amazonaws.com/packages.treasuredata.com/4/windows/td-agent-4.5.2-x64.msi"
    $tdAgentMsi = Join-Path $env:TEMP "td-agent-4.5.2-x64.msi"

    try {
        if (-not (Test-Path $tdAgentMsi)) {
            Log "  Downloading td-agent installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $tdAgentMsiUrl -OutFile $tdAgentMsi -UseBasicParsing
            Log "  td-agent downloaded."
        }

        Log "  Installing td-agent (this may take a minute)..."
        $msiArgs = "/i `"$tdAgentMsi`" /quiet /norestart"
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Log "  td-agent installed successfully to $tdAgentPath"
            $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"

            # Install the opensearch output plugin for fluentd
            $tdAgentGem = Join-Path $tdAgentPath "bin\fluent-gem.bat"
            if (Test-Path $tdAgentGem) {
                Log "  Installing fluent-plugin-opensearch gem..."
                & $tdAgentGem install fluent-plugin-opensearch --no-document 2>&1 | Out-Null
                Log "  fluent-plugin-opensearch installed."
            }
        } else {
            Warn "  td-agent MSI installer returned exit code $($proc.ExitCode)."
            Warn "  Please install td-agent manually from: https://td-agent-package-browser.herokuapp.com/4/windows"
        }
    } catch {
        Warn "  Failed to download/install td-agent: $_"
        Warn "  Please install td-agent manually from: https://td-agent-package-browser.herokuapp.com/4/windows"
        Warn "  After installing, re-run this installer to register the Log Collector service."
    }
}

# Write log collector config
$logCollectorConf = @"
## Supra Log Collector configuration

# Syslog input
<source>
  @type syslog
  port 5140
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
Log "  Supra Log Collector config installed to $logCollectorDir"

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
    @{ Name = "Supra Log Collector Syslog";  Port = 5140; Protocol = "UDP" }
    @{ Name = "Supra Log Collector Forward"; Port = 24224; Protocol = "TCP" }
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
Write-Host "Step 4: Start services (open a NEW terminal so PATH is updated):"
Write-Host "  nssm start SupraSearch"
Write-Host "  # Wait for Search Engine to be ready, then:"
Write-Host "  nssm start SupraDashboards"
Write-Host "  nssm start SupraLogCollector"
Write-Host ""
Write-Host "NOTE: NSSM has been added to system PATH at $InstallDir\nssm" -ForegroundColor Cyan
Write-Host "      Open a new terminal/PowerShell window for 'nssm' to be recognized." -ForegroundColor Cyan
Write-Host ""
Write-Host "Services (Windows Services):"
Write-Host "  SupraSearch          - Supra Search Engine  (https://localhost:9200)"
Write-Host "  SupraDashboards      - Supra Dashboards     (http://localhost:5601)"
Write-Host "  SupraLogCollector    - Supra Log Collector  (Syslog UDP/5140, Forward TCP/24224)"
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
