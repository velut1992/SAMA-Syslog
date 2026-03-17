#!/bin/bash
set -e

################################################################################
# Supra Installer Package Builder for Windows (runs on Linux)
#
# Cross-builds the Windows installer package from a Linux machine.
# Downloads Windows OpenSearch zip from CI, builds Dashboards for Windows,
# and packages everything into a deployable zip.
#
# Output: supra-installer-3.6.0-windows-x64.zip
################################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$BASE_DIR/installer-build-win"
PACKAGE_NAME="supra-installer"
VERSION="3.6.0"

# Source paths
OPENSEARCH_WIN_ZIP="$BASE_DIR/opensearch-${VERSION}-windows-x64.zip"
DASHBOARDS_SRC="$BASE_DIR/OpenSearch-Dashboards"
DASHBOARDS_WIN_ZIP_SNAPSHOT="$DASHBOARDS_SRC/target/opensearch-dashboards-${VERSION}-SNAPSHOT-windows-x64.zip"
DASHBOARDS_WIN_ZIP_RELEASE="$DASHBOARDS_SRC/target/opensearch-dashboards-${VERSION}-windows-x64.zip"
EXTRA_PLUGINS_DIR="$BASE_DIR/dashboards-plugins"
FLUENTD_CONF="$BASE_DIR/fluent/fluent.conf"
LICENSE_VALIDATOR_DIR="$BASE_DIR/opensearch-license-validator"

# NSSM download URL
NSSM_URL="https://nssm.cc/release/nssm-2.24.zip"
NSSM_ZIP="$BASE_DIR/nssm-2.24.zip"

echo "============================================"
echo "  Supra Installer Package Builder v${VERSION}"
echo "  (Windows Server x64 — cross-build)"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Download Windows OpenSearch zip from CI
# ---------------------------------------------------------------------------
echo "[1/8] Checking Supra Search Engine (Windows)..."

if [ ! -f "$OPENSEARCH_WIN_ZIP" ]; then
    echo "  Downloading Supra Search Engine for Windows..."
    OPENSEARCH_WIN_URL="https://ci.opensearch.org/ci/dbc/distribution-build-opensearch/${VERSION}/latest/windows/x64/zip/dist/opensearch/opensearch-${VERSION}-windows-x64.zip"
    if curl -fSL -o "$OPENSEARCH_WIN_ZIP" "$OPENSEARCH_WIN_URL" 2>&1; then
        echo "  Downloaded: $(du -sh "$OPENSEARCH_WIN_ZIP" | cut -f1)"
    else
        echo "ERROR: Failed to download Supra Search Engine for Windows." >&2
        echo "       URL: $OPENSEARCH_WIN_URL" >&2
        echo "       Please download manually and place at: $OPENSEARCH_WIN_ZIP" >&2
        rm -f "$OPENSEARCH_WIN_ZIP"
        exit 1
    fi
else
    echo "  Already downloaded: $(du -sh "$OPENSEARCH_WIN_ZIP" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# Step 2: Build Dashboards for Windows (cross-build from Linux)
# ---------------------------------------------------------------------------
echo ""
echo "[2/8] Building Supra Dashboards for Windows..."

if [ -f "$DASHBOARDS_WIN_ZIP_SNAPSHOT" ]; then
    DASHBOARDS_WIN_ZIP="$DASHBOARDS_WIN_ZIP_SNAPSHOT"
    echo "  Windows build already exists: $(basename "$DASHBOARDS_WIN_ZIP")"
elif [ -f "$DASHBOARDS_WIN_ZIP_RELEASE" ]; then
    DASHBOARDS_WIN_ZIP="$DASHBOARDS_WIN_ZIP_RELEASE"
    echo "  Windows build already exists: $(basename "$DASHBOARDS_WIN_ZIP")"
else
    echo "  Building Supra Dashboards for Windows (this may take a while)..."
    cd "$DASHBOARDS_SRC"

    # Use bundled node binary if available, otherwise try nvm
    REQUIRED_NODE=$(cat "$DASHBOARDS_SRC/.nvmrc" 2>/dev/null)
    BUNDLED_NODE="$DASHBOARDS_SRC/.node_binaries/${REQUIRED_NODE}/linux-x64/bin"
    if [ -d "$BUNDLED_NODE" ]; then
        export PATH="$BUNDLED_NODE:$PATH"
        echo "  Using bundled Node.js: $(node -v)"
    else
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
        nvm use "$REQUIRED_NODE" 2>/dev/null || true
        echo "  Using Node.js: $(node -v)"
    fi

    yarn build-platform --windows --skip-os-packages

    cd "$BASE_DIR"

    # Locate the built zip
    if [ -f "$DASHBOARDS_WIN_ZIP_SNAPSHOT" ]; then
        DASHBOARDS_WIN_ZIP="$DASHBOARDS_WIN_ZIP_SNAPSHOT"
    elif [ -f "$DASHBOARDS_WIN_ZIP_RELEASE" ]; then
        DASHBOARDS_WIN_ZIP="$DASHBOARDS_WIN_ZIP_RELEASE"
    else
        echo "ERROR: Dashboards Windows build output not found after build." >&2
        echo "       Expected at: $DASHBOARDS_WIN_ZIP_SNAPSHOT" >&2
        exit 1
    fi
    echo "  Build complete: $(du -sh "$DASHBOARDS_WIN_ZIP" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# Step 3: Download NSSM
# ---------------------------------------------------------------------------
echo ""
echo "[3/8] Checking NSSM service manager..."

if [ ! -f "$NSSM_ZIP" ]; then
    echo "  Downloading NSSM..."
    if curl -fSL -o "$NSSM_ZIP" "$NSSM_URL" 2>&1; then
        echo "  Downloaded."
    else
        echo "  WARNING: Failed to download NSSM. You may need to include it manually." >&2
        rm -f "$NSSM_ZIP"
    fi
else
    echo "  Already downloaded."
fi

# ---------------------------------------------------------------------------
# Step 4: Download Dashboards plugins (Windows)
# ---------------------------------------------------------------------------
echo ""
echo "[4/8] Checking Dashboards plugins..."

# Use same plugins as Linux (they are platform-independent zips)
DASHBOARDS_PLUGIN_BASE_URL="https://ci.opensearch.org/ci/dbc/distribution-build-opensearch-dashboards/${VERSION}/latest/linux/x64/tar/builds/opensearch-dashboards/plugins"
DASHBOARDS_PLUGIN_NAMES=(
    "securityDashboards"
    "alertingDashboards"
    "anomalyDetectionDashboards"
    "observabilityDashboards"
    "searchRelevanceDashboards"
    "queryInsightsDashboards"
    "assistantDashboards"
    "customImportMapDashboards"
)

mkdir -p "$EXTRA_PLUGINS_DIR"
for PLUGIN_NAME in "${DASHBOARDS_PLUGIN_NAMES[@]}"; do
    PLUGIN_FILE="$EXTRA_PLUGINS_DIR/${PLUGIN_NAME}-${VERSION}.zip"
    if [ ! -f "$PLUGIN_FILE" ]; then
        echo "  Downloading ${PLUGIN_NAME}..."
        PLUGIN_URL="${DASHBOARDS_PLUGIN_BASE_URL}/${PLUGIN_NAME}-${VERSION}.zip"
        if curl -fsSL -o "$PLUGIN_FILE" "$PLUGIN_URL" 2>/dev/null; then
            echo "    OK"
        else
            echo "    WARNING: Failed to download ${PLUGIN_NAME}. Skipping."
            rm -f "$PLUGIN_FILE"
        fi
    else
        echo "    ${PLUGIN_NAME} already downloaded."
    fi
done

EXTRA_PLUGINS_FOUND=$(find "$EXTRA_PLUGINS_DIR" -name "*.zip" 2>/dev/null | wc -l)
echo "  Extra plugins: ${EXTRA_PLUGINS_FOUND} found"

# ---------------------------------------------------------------------------
# Step 5: Prepare build directory
# ---------------------------------------------------------------------------
echo ""
echo "[5/8] Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME"

STAGING="$BUILD_DIR/$PACKAGE_NAME"
mkdir -p "$STAGING"/{opensearch,dashboards,dashboards-plugins,log-collector,nssm,branding,license-validator}

# ---------------------------------------------------------------------------
# Step 6: Stage all components
# ---------------------------------------------------------------------------
echo ""
echo "[6/8] Staging components..."

# -- Supra Search Engine --
echo "  Staging Supra Search Engine..."
cp "$OPENSEARCH_WIN_ZIP" "$STAGING/opensearch/"

cat > "$STAGING/opensearch/opensearch.yml" <<'OSCONF'
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
OSCONF

# -- Supra Dashboards --
echo "  Staging Supra Dashboards..."
cp "$DASHBOARDS_WIN_ZIP" "$STAGING/dashboards/"

cat > "$STAGING/dashboards/opensearch_dashboards.yml" <<'OSDCONF'
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
OSDCONF

# -- Extra plugins --
if [ "$EXTRA_PLUGINS_FOUND" -gt 0 ]; then
    echo "  Staging extra dashboards plugins..."
    cp "$EXTRA_PLUGINS_DIR"/*.zip "$STAGING/dashboards-plugins/"
fi

# -- Branding --
BRANDING_SRC="$DASHBOARDS_SRC/src/core/server/core_app/assets/default_branding"
if [ -d "$BRANDING_SRC" ]; then
    echo "  Staging branding assets..."
    cp "$BRANDING_SRC/scpl.png" "$STAGING/branding/" 2>/dev/null || true
    cp "$BRANDING_SRC/favicon.png" "$STAGING/branding/" 2>/dev/null || true
fi

# -- Supra Log Collector config --
echo "  Staging Supra Log Collector config..."
cp "$FLUENTD_CONF" "$STAGING/log-collector/"

# -- License validator --
if [ -d "$LICENSE_VALIDATOR_DIR" ]; then
    echo "  Staging license validator..."
    cp -r "$LICENSE_VALIDATOR_DIR/license-generator" "$STAGING/license-validator/" 2>/dev/null || true
    cp -r "$LICENSE_VALIDATOR_DIR/license-validator" "$STAGING/license-validator/" 2>/dev/null || true
fi

# -- NSSM --
if [ -f "$NSSM_ZIP" ]; then
    echo "  Extracting NSSM..."
    NSSM_TMP="$BUILD_DIR/nssm-tmp"
    mkdir -p "$NSSM_TMP"
    unzip -q -o "$NSSM_ZIP" -d "$NSSM_TMP"
    NSSM_EXE=$(find "$NSSM_TMP" -path "*/win64/nssm.exe" | head -1)
    if [ -n "$NSSM_EXE" ]; then
        cp "$NSSM_EXE" "$STAGING/nssm/nssm.exe"
        echo "  NSSM (64-bit) staged."
    else
        echo "  WARNING: nssm.exe (win64) not found in archive."
    fi
    rm -rf "$NSSM_TMP"
else
    echo "  WARNING: NSSM not available. Services will need manual setup."
fi

# ---------------------------------------------------------------------------
# Step 7: Create install.ps1 and uninstall.ps1
# ---------------------------------------------------------------------------
echo ""
echo "[7/8] Creating install and uninstall scripts..."

cat > "$STAGING/install.ps1" <<'INSTALL_PS1'
################################################################################
# Supra Stack Installer (Windows Server)
#
# Installs Supra Search Engine, Supra Dashboards, and Supra Log Collector
# as Windows Services. Must be run as Administrator.
#
# Usage:
#   .\install.ps1                          # Installs to C:\supra
#   .\install.ps1 -InstallPath "D:\supra"  # Installs to D:\supra
################################################################################

param(
    [string]$InstallPath = "C:\supra"
)

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$InstallDir = $InstallPath
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

# ---- Locate NSSM ----
$NssmExe = Join-Path $ScriptDir "nssm\nssm.exe"
if (-not (Test-Path $NssmExe)) {
    Err "NSSM not found at $NssmExe. Cannot register Windows services."
    Err "Download NSSM from https://nssm.cc and place nssm.exe in the nssm\ folder."
    exit 1
}
Log "NSSM found: $NssmExe"

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
        $iuContent = $iuContent -replace '(admin:[\s\S]*?hash:\s*")[^"]*(")', '${1}$2a$12$VcCDgh2NDk07JGN0rjGbM.Ad41qVR/YFJcgHp0UGns5JDymv..TOG${2}'
        $iuContent | Set-Content $internalUsers -Encoding UTF8
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
    $jvmContent | Set-Content $jvmOptions -Encoding UTF8
    Log "  JVM heap set to ${heapMB}m"
}

# Set permissions
$acl = Get-Acl $osInstallDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($SupraUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path $osInstallDir -AclObject $acl -ErrorAction SilentlyContinue
Log "  Supra Search Engine installed to $osInstallDir"

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

$tdAgentPath = "C:\opt\td-agent"
$fluentdExe = $null

if (Test-Path $tdAgentPath) {
    $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"
    Log "  Log Collector runtime found at $tdAgentPath"
} elseif (Get-Command fluentd -ErrorAction SilentlyContinue) {
    $fluentdExe = (Get-Command fluentd).Source
    Log "  Log Collector runtime found at $fluentdExe"
} else {
    Warn "Log Collector runtime not found on this system."
    Warn "Download td-agent for Windows from: https://td-agent-package-browser.herokuapp.com/4/windows"
    Warn "Or install via RubyInstaller + gem install fluentd fluent-plugin-opensearch"
    Warn "Skipping Log Collector service registration. Re-run installer after installing."
}

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

# -- Supra Search Engine Service --
$osBat = Join-Path $osInstallDir "bin\opensearch.bat"
if (Test-Path $osBat) {
    & $NssmExe stop "SupraSearch" 2>$null
    & $NssmExe remove "SupraSearch" confirm 2>$null

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
    & $NssmExe stop "SupraDashboards" 2>$null
    & $NssmExe remove "SupraDashboards" confirm 2>$null

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
    & $NssmExe stop "SupraLogCollector" 2>$null
    & $NssmExe remove "SupraLogCollector" confirm 2>$null

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
    @{ Name = "Supra Search Engine";           Port = 9200;  Protocol = "TCP" }
    @{ Name = "Supra Dashboards";              Port = 5601;  Protocol = "TCP" }
    @{ Name = "Supra Log Collector Syslog";    Port = 5140;  Protocol = "UDP" }
    @{ Name = "Supra Log Collector Forward";   Port = 24224; Protocol = "TCP" }
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

# ---- Start services ----
Log "Starting services..."

Log "  Starting Supra Search Engine..."
& $NssmExe start "SupraSearch"

Write-Host -NoNewline "  Waiting for Supra Search Engine"
$ready = $false
for ($i = 1; $i -le 60; $i++) {
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $response = Invoke-WebRequest -Uri "https://localhost:9200" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 401) {
            Write-Host ""
            Log "  Supra Search Engine is ready."
            $ready = $true
            break
        }
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            Write-Host ""
            Log "  Supra Search Engine is ready."
            $ready = $true
            break
        }
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Write-Host ""
    Warn "Supra Search Engine did not start within 120s. Check: $InstallDir\opensearch\logs\"
}

# ---- Initialize security index ----
$secPluginDir = Join-Path $osInstallDir "plugins\opensearch-security"
if (Test-Path $secPluginDir) {
    Log "Initializing security index..."
    Start-Sleep -Seconds 5

    $secAdminBat = Join-Path $secPluginDir "tools\securityadmin.bat"
    $osConfDir = Join-Path $osInstallDir "config"
    $env:OPENSEARCH_JAVA_HOME = Join-Path $osInstallDir "jdk"

    if (Test-Path $secAdminBat) {
        & cmd.exe /c "`"$secAdminBat`" -cd `"$osConfDir\opensearch-security`" -icl -nhnv -cacert `"$osConfDir\root-ca.pem`" -cert `"$osConfDir\kirk.pem`" -key `"$osConfDir\kirk-key.pem`"" 2>&1 | Select-Object -Last 5

        Log "  Security index initialized."

        Start-Sleep -Seconds 2
        try {
            $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin"))
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $resp = Invoke-WebRequest -Uri "https://localhost:9200" -Headers @{ Authorization = "Basic $cred" } -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -eq 200) {
                Log "  Admin login verified successfully."
            } else {
                Warn "  Admin login returned HTTP $($resp.StatusCode)."
            }
        } catch {
            Warn "  Admin login verification failed. Service may still be starting."
        }
    } else {
        Warn "  Security admin tool not found. Security index not initialized."
    }
}

Log "  Starting Supra Log Collector..."
& $NssmExe start "SupraLogCollector" 2>$null

Log "  Starting Supra Dashboards..."
& $NssmExe start "SupraDashboards"

# ---- Summary ----
Write-Host ""
Write-Host "============================================"
Write-Host "  Installation Complete!"
Write-Host "============================================"
Write-Host ""
Write-Host "Services (Windows Services):"
Write-Host "  SupraSearch          - Supra Search Engine  (https://localhost:9200)"
Write-Host "  SupraDashboards      - Supra Dashboards     (http://localhost:5601)"
Write-Host "  SupraLogCollector    - Supra Log Collector"
Write-Host ""
Write-Host "Credentials:"
Write-Host "  Username: admin"
Write-Host "  Password: admin"
Write-Host ""
Write-Host "Verify:"
Write-Host "  Invoke-WebRequest -Uri https://localhost:9200 -SkipCertificateCheck -Credential (Get-Credential)"
Write-Host ""
Write-Host "Manage services:"
Write-Host "  Start-Service SupraSearch"
Write-Host "  Stop-Service SupraSearch"
Write-Host "  Restart-Service SupraSearch"
Write-Host "  Get-Service Supra*"
Write-Host ""
Write-Host "  Or via NSSM:"
Write-Host "  nssm start|stop|restart SupraSearch"
Write-Host "  nssm start|stop|restart SupraDashboards"
Write-Host "  nssm start|stop|restart SupraLogCollector"
Write-Host ""
Write-Host "Logs:"
Write-Host "  $InstallDir\opensearch\logs\"
Write-Host "  $InstallDir\dashboards\logs\"
Write-Host "  $InstallDir\log-collector\log-collector-stdout.log"
Write-Host ""
Write-Host "Install directory: $InstallDir"
Write-Host ""
INSTALL_PS1

cat > "$STAGING/uninstall.ps1" <<'UNINSTALL_PS1'
################################################################################
# Supra Stack Uninstaller (Windows Server)
# Must be run as Administrator.
#
# Usage:
#   .\uninstall.ps1                          # Uninstalls from C:\supra
#   .\uninstall.ps1 -InstallPath "D:\supra"  # Uninstalls from D:\supra
################################################################################

param(
    [string]$InstallPath = "C:\supra"
)

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$InstallDir = $InstallPath

Write-Host "Stopping and removing services..."
foreach ($svc in @("SupraDashboards", "SupraLogCollector", "SupraSearch")) {
    $nssmPath = Join-Path $PSScriptRoot "nssm\nssm.exe"
    if (-not (Test-Path $nssmPath)) {
        $nssmPath = "nssm.exe"
    }

    try { & $nssmPath stop $svc 2>$null } catch {}
    try { & $nssmPath remove $svc confirm 2>$null } catch {}
    Write-Host "  $svc removed."
}

Write-Host "Removing firewall rules..."
foreach ($ruleName in @("Supra Search Engine", "Supra Dashboards", "Supra Log Collector Syslog", "Supra Log Collector Forward")) {
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
}

Write-Host "Removing installation directory ($InstallDir)..."
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host ""
Write-Host "Supra stack uninstalled."
Write-Host "Note: The 'SupraService' user was not removed. To remove:"
Write-Host "  Remove-LocalUser -Name SupraService"
UNINSTALL_PS1

echo "  install.ps1 and uninstall.ps1 created."

# ---------------------------------------------------------------------------
# Step 8: Create the final zip package
# ---------------------------------------------------------------------------
echo ""
echo "[8/8] Creating installer package..."
cd "$BUILD_DIR"

OUTPUT_ZIP="$BASE_DIR/${PACKAGE_NAME}-${VERSION}-windows-x64.zip"
rm -f "$OUTPUT_ZIP"

# Use zip command (available on most Linux systems)
if command -v zip &>/dev/null; then
    zip -r -q "$OUTPUT_ZIP" "$PACKAGE_NAME"
else
    # Fallback to tar + zip via Python
    python3 -c "
import zipfile, os, sys
base = '$PACKAGE_NAME'
with zipfile.ZipFile('$OUTPUT_ZIP', 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(base):
        for f in files:
            fp = os.path.join(root, f)
            zf.write(fp)
print('Created zip via Python')
"
fi

FINAL_SIZE=$(du -sh "$OUTPUT_ZIP" | cut -f1)

echo ""
echo "============================================"
echo "  Installer Package Ready!"
echo "============================================"
echo ""
echo "  Package: $OUTPUT_ZIP"
echo "  Size:    $FINAL_SIZE"
echo ""
echo "  To install on a Windows Server:"
echo "    1. Copy the zip to the target machine"
echo "    2. Extract: Expand-Archive -Path ${PACKAGE_NAME}-${VERSION}-windows-x64.zip -DestinationPath ."
echo "    3. Install (as Administrator):"
echo "       .\\${PACKAGE_NAME}\\install.ps1"
echo "       .\\${PACKAGE_NAME}\\install.ps1 -InstallPath \"D:\\supra\""
echo ""
echo "  To uninstall:"
echo "    .\\${PACKAGE_NAME}\\uninstall.ps1"
echo ""

# Cleanup build dir
rm -rf "$BUILD_DIR"
