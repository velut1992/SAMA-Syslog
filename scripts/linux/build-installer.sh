#!/bin/bash
set -e

################################################################################
# Supra Installer Package Builder (Linux x64)
#
# Builds a self-contained installer tarball that can be deployed on another
# Linux x64 machine. The package includes:
#   - Supra Search Engine (full distribution with all plugins)
#   - Supra Dashboards (full distribution with all plugins)
#   - Extra Dashboards plugins (SIEM, Index Management, Notifications)
#   - Supra Log Collector configuration
#   - Systemd service files
#   - Install script
################################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$BASE_DIR/installer-build"
PACKAGE_NAME="supra-installer"
VERSION="3.6.0"

# Source paths
OPENSEARCH_TARBALL="$BASE_DIR/opensearch-${VERSION}-linux-x64.tar.gz"
if [ -f "$BASE_DIR/OpenSearch-Dashboards/target/opensearch-dashboards-${VERSION}-SNAPSHOT-linux-x64.tar.gz" ]; then
  DASHBOARDS_TARBALL="$BASE_DIR/OpenSearch-Dashboards/target/opensearch-dashboards-${VERSION}-SNAPSHOT-linux-x64.tar.gz"
else
  DASHBOARDS_TARBALL="$BASE_DIR/OpenSearch-Dashboards/target/opensearch-dashboards-${VERSION}-linux-x64.tar.gz"
fi
EXTRA_PLUGINS_DIR="$BASE_DIR/dashboards-plugins"
FLUENTD_CONF="$BASE_DIR/fluent/fluent.conf"
LICENSE_VALIDATOR_DIR="$BASE_DIR/opensearch-license-validator"
DASHBOARDS_SRC="$BASE_DIR/OpenSearch-Dashboards"

echo "============================================"
echo "  Supra Installer Package Builder v${VERSION}"
echo "  (Linux x64)"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
echo "[1/7] Checking prerequisites..."

if [ ! -f "$OPENSEARCH_TARBALL" ]; then
    echo "ERROR: Supra Search Engine distribution tarball not found at $OPENSEARCH_TARBALL"
    echo "       Download from: https://ci.opensearch.org/ci/dbc/distribution-build-opensearch/${VERSION}/latest/linux/x64/tar/dist/opensearch/opensearch-${VERSION}-linux-x64.tar.gz"
    exit 1
fi

if [ ! -f "$DASHBOARDS_TARBALL" ]; then
    echo "ERROR: Supra Dashboards build tarball not found at $DASHBOARDS_TARBALL"
    echo "       Build it first:"
    echo "         cd $BASE_DIR/OpenSearch-Dashboards"
    echo "         yarn build-platform --linux --skip-os-packages"
    exit 1
fi

if [ ! -f "$FLUENTD_CONF" ]; then
    echo "ERROR: Log Collector config not found at $FLUENTD_CONF"
    exit 1
fi

echo "  Search engine tarball: OK"
echo "  Dashboards tarball:    OK"
echo "  Log Collector config:  OK"

# Download missing Dashboards plugins
DASHBOARDS_PLUGIN_BASE_URL="https://ci.opensearch.org/ci/dbc/distribution-build-opensearch-dashboards/${VERSION}/latest/linux/x64/tar/builds/opensearch-dashboards/plugins"
DASHBOARDS_PLUGIN_ARTIFACTS=(
    "securityDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/securityDashboards-${VERSION}.zip"
    "alertingDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/alertingDashboards-${VERSION}.zip"
    "anomalyDetectionDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/anomalyDetectionDashboards-${VERSION}.zip"
    "observabilityDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/observabilityDashboards-${VERSION}.zip"
    "searchRelevanceDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/searchRelevanceDashboards-${VERSION}.zip"
    "queryInsightsDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/queryInsightsDashboards-${VERSION}.zip"
    "assistantDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/assistantDashboards-${VERSION}.zip"
    "customImportMapDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/customImportMapDashboards-${VERSION}.zip"
)

mkdir -p "$EXTRA_PLUGINS_DIR"
echo "  Checking Dashboards plugins..."
for entry in "${DASHBOARDS_PLUGIN_ARTIFACTS[@]}"; do
    PLUGIN_NAME="${entry%%|*}"
    PLUGIN_URL="${entry##*|}"
    PLUGIN_FILE="$EXTRA_PLUGINS_DIR/${PLUGIN_NAME}-${VERSION}.zip"
    if [ ! -f "$PLUGIN_FILE" ]; then
        echo "  Downloading ${PLUGIN_NAME}..."
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

EXTRA_PLUGINS_FOUND=0
if [ -d "$EXTRA_PLUGINS_DIR" ]; then
    EXTRA_PLUGINS_FOUND=$(find "$EXTRA_PLUGINS_DIR" -name "*.zip" | wc -l)
fi
echo "  Extra plugins:         ${EXTRA_PLUGINS_FOUND} found"

# ---------------------------------------------------------------------------
# Prepare build directory
# ---------------------------------------------------------------------------
echo ""
echo "[2/7] Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$PACKAGE_NAME"

STAGING="$BUILD_DIR/$PACKAGE_NAME"
mkdir -p "$STAGING"/{opensearch,dashboards,dashboards-plugins,log-collector,systemd,branding,license-validator}

# ---------------------------------------------------------------------------
# Package Supra Search Engine
# ---------------------------------------------------------------------------
echo ""
echo "[3/7] Packaging Supra Search Engine..."
cp "$OPENSEARCH_TARBALL" "$STAGING/opensearch/"

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

echo "  Tarball and config staged."

# ---------------------------------------------------------------------------
# Package Supra Dashboards (full distribution)
# ---------------------------------------------------------------------------
echo ""
echo "[4/7] Packaging Supra Dashboards..."
cp "$DASHBOARDS_TARBALL" "$STAGING/dashboards/"

echo "  Dashboards tarball packaged."

if [ "$EXTRA_PLUGINS_FOUND" -gt 0 ]; then
    echo "  Packaging extra dashboards plugins..."
    cp "$EXTRA_PLUGINS_DIR"/*.zip "$STAGING/dashboards-plugins/"
    for f in "$STAGING/dashboards-plugins"/*.zip; do
        echo "    - $(basename $f)"
    done
fi

# Copy branding assets
if [ -d "$DASHBOARDS_SRC/src/core/server/core_app/assets/default_branding" ]; then
    cp "$DASHBOARDS_SRC/src/core/server/core_app/assets/default_branding/scpl.png" "$STAGING/branding/"
    cp "$DASHBOARDS_SRC/src/core/server/core_app/assets/default_branding/favicon.png" "$STAGING/branding/"
else
    echo "  WARNING: Branding assets not found in source tree. Skipping."
fi

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

echo "  Branding and config staged."

# ---------------------------------------------------------------------------
# Package Supra Log Collector config
# ---------------------------------------------------------------------------
echo ""
echo "[5/7] Packaging Supra Log Collector config..."
cp "$FLUENTD_CONF" "$STAGING/log-collector/"
echo "  Log Collector config staged."

# ---------------------------------------------------------------------------
# Package license validator
# ---------------------------------------------------------------------------
if [ -d "$LICENSE_VALIDATOR_DIR" ]; then
    echo "  Packaging license validator..."
    cp -r "$LICENSE_VALIDATOR_DIR/license-generator" "$STAGING/license-validator/"
    cp -r "$LICENSE_VALIDATOR_DIR/license-validator" "$STAGING/license-validator/"
fi

# ---------------------------------------------------------------------------
# Create systemd service files
# ---------------------------------------------------------------------------
cat > "$STAGING/systemd/supra-search.service" <<'EOF'
[Unit]
Description=Supra Search Engine
After=network.target

[Service]
Type=simple
User=supra
Group=supra
WorkingDirectory=/opt/supra/opensearch
ExecStart=/opt/supra/opensearch/bin/opensearch
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
LimitMEMLOCK=infinity
Environment=OPENSEARCH_HOME=/opt/supra/opensearch

[Install]
WantedBy=multi-user.target
EOF

cat > "$STAGING/systemd/supra-dashboards.service" <<'EOF'
[Unit]
Description=Supra Dashboards
After=network.target supra-search.service
Requires=supra-search.service

[Service]
Type=simple
User=supra
Group=supra
WorkingDirectory=/opt/supra/dashboards
ExecStart=/opt/supra/dashboards/bin/opensearch-dashboards
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > "$STAGING/systemd/supra-log-collector.service" <<'EOF'
[Unit]
Description=Supra Log Collector
After=network.target supra-search.service

[Service]
Type=simple
User=supra
Group=supra
ExecStart=/usr/local/bin/fluentd -c /opt/supra/log-collector/fluent.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Create the install script
# ---------------------------------------------------------------------------
cat > "$STAGING/install.sh" <<'INSTALL_SCRIPT'
#!/bin/bash
set -e

################################################################################
# Supra Stack Installer
#
# Installs Supra Search Engine, Supra Dashboards, and Supra Log Collector
# as systemd services. Must be run as root (or with sudo).
################################################################################

INSTALL_DIR="/opt/supra"
SUPRA_USER="supra"
SUPRA_GROUP="supra"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- Root check ----
if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root. Use: sudo bash install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "============================================"
echo "  Supra Stack Installer"
echo "============================================"
echo ""
echo "Install directory: $INSTALL_DIR"
echo ""

ADMIN_PASSWORD="admin"

# ---- Create supra user ----
log "Creating system user '$SUPRA_USER'..."
if id "$SUPRA_USER" &>/dev/null; then
    warn "User '$SUPRA_USER' already exists, skipping."
else
    useradd -r -m -d "$INSTALL_DIR" -s /bin/false "$SUPRA_USER"
fi

mkdir -p "$INSTALL_DIR"

# ---- System tuning ----
log "Applying system tuning..."
SYSCTL_CONF="/etc/sysctl.d/99-supra.conf"
if [ ! -f "$SYSCTL_CONF" ]; then
    cat > "$SYSCTL_CONF" <<SYSCTL
vm.max_map_count=262144
SYSCTL
    sysctl --system > /dev/null 2>&1
else
    warn "Sysctl config already exists, skipping."
fi

# ---- Install Supra Search Engine ----
log "Installing Supra Search Engine..."
OS_TARBALL=$(find "$SCRIPT_DIR/opensearch" -name "opensearch-*.tar.gz" | head -1)
if [ -z "$OS_TARBALL" ]; then
    err "Search engine tarball not found in $SCRIPT_DIR/opensearch/"
    exit 1
fi

rm -rf "$INSTALL_DIR/opensearch"
mkdir -p "$INSTALL_DIR/opensearch"
tar -xzf "$OS_TARBALL" -C "$INSTALL_DIR/opensearch" --strip-components=1

# Initialize security plugin demo certificates
SECURITY_PLUGIN_DIR="$INSTALL_DIR/opensearch/plugins/opensearch-security"
if [ -d "$SECURITY_PLUGIN_DIR" ]; then
    log "  Initializing security demo certificates..."
    chmod +x "$SECURITY_PLUGIN_DIR/tools/install_demo_configuration.sh"
    cd "$INSTALL_DIR/opensearch"
    export OPENSEARCH_INITIAL_ADMIN_PASSWORD="MyS3cur!tyP@ss"
    bash "$SECURITY_PLUGIN_DIR/tools/install_demo_configuration.sh" -y -i -s 2>&1 | tail -5
    unset OPENSEARCH_INITIAL_ADMIN_PASSWORD
    cd "$SCRIPT_DIR"
    log "  Security demo certificates installed."

    # Reset admin password hash to default "admin"
    INTERNAL_USERS="$INSTALL_DIR/opensearch/config/opensearch-security/internal_users.yml"
    if [ -f "$INTERNAL_USERS" ]; then
        sed -i '/^admin:/,/^[a-zA-Z]/{s|hash: ".*"|hash: "$2a$12$VcCDgh2NDk07JGN0rjGbM.Ad41qVR/YFJcgHp0UGns5JDymv..TOG"|}' "$INTERNAL_USERS"
        log "  Admin password reset to default (admin/admin)."
    fi

    cp "$SCRIPT_DIR/opensearch/opensearch.yml" "$INSTALL_DIR/opensearch/config/opensearch.yml"
else
    warn "Security plugin not found. Authentication will not be available."
    cp "$SCRIPT_DIR/opensearch/opensearch.yml" "$INSTALL_DIR/opensearch/config/opensearch.yml"
fi

# Set JVM heap (50% of RAM, max 8g)
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HEAP_MB=$(( TOTAL_MEM_KB / 1024 / 2 ))
if [ "$HEAP_MB" -gt 8192 ]; then HEAP_MB=8192; fi
if [ "$HEAP_MB" -lt 512 ]; then HEAP_MB=512; fi

JVM_OPTIONS="$INSTALL_DIR/opensearch/config/jvm.options"
if [ -f "$JVM_OPTIONS" ]; then
    sed -i "s/^-Xms.*/-Xms${HEAP_MB}m/" "$JVM_OPTIONS"
    sed -i "s/^-Xmx.*/-Xmx${HEAP_MB}m/" "$JVM_OPTIONS"
    log "  JVM heap set to ${HEAP_MB}m"
fi

chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/opensearch"
log "  Supra Search Engine installed to $INSTALL_DIR/opensearch"

# ---- Install Supra Dashboards ----
log "Installing Supra Dashboards..."
OSD_TARBALL=$(find "$SCRIPT_DIR/dashboards" -name "opensearch-dashboards-*.tar.gz" | head -1)
if [ -z "$OSD_TARBALL" ]; then
    err "Dashboards tarball not found in $SCRIPT_DIR/dashboards/"
    exit 1
fi

rm -rf "$INSTALL_DIR/dashboards"
mkdir -p "$INSTALL_DIR/dashboards"
tar -xzf "$OSD_TARBALL" -C "$INSTALL_DIR/dashboards" --strip-components=1

# Install extra dashboards plugins
if [ -d "$SCRIPT_DIR/dashboards-plugins" ]; then
    for plugin_zip in "$SCRIPT_DIR/dashboards-plugins"/*.zip; do
        if [ -f "$plugin_zip" ]; then
            plugin_name=$(basename "$plugin_zip" .zip | sed 's/-[0-9].*//')
            log "  Installing dashboards plugin: $plugin_name..."
            unzip -q -o "$plugin_zip" -d /tmp/osd-plugin-tmp 2>/dev/null
            if [ -d "/tmp/osd-plugin-tmp/opensearch-dashboards" ]; then
                cp -r /tmp/osd-plugin-tmp/opensearch-dashboards/* "$INSTALL_DIR/dashboards/plugins/"
                log "  Plugin $plugin_name installed."
            else
                warn "  Plugin $plugin_name has unexpected zip structure, skipping."
            fi
            rm -rf /tmp/osd-plugin-tmp
        fi
    done
fi

cp "$SCRIPT_DIR/dashboards/opensearch_dashboards.yml" "$INSTALL_DIR/dashboards/config/opensearch_dashboards.yml"

# Add security config if security plugin is present
if [ -d "$INSTALL_DIR/dashboards/plugins/securityDashboards" ]; then
    log "  Security plugin detected — adding security config..."
    cat >> "$INSTALL_DIR/dashboards/config/opensearch_dashboards.yml" <<'SECCONF'

opensearch_security.multitenancy.enabled: true
opensearch_security.multitenancy.tenants.preferred: ["Private", "Global"]
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
opensearch_security.cookie.secure: false
SECCONF
fi

# Copy branding assets
BRANDING_DIR="$INSTALL_DIR/dashboards/src/core/server/core_app/assets/default_branding"
mkdir -p "$BRANDING_DIR"
if [ -f "$SCRIPT_DIR/branding/scpl.png" ]; then
    cp "$SCRIPT_DIR/branding/scpl.png" "$BRANDING_DIR/"
    cp "$SCRIPT_DIR/branding/favicon.png" "$BRANDING_DIR/"
fi

chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/dashboards"
log "  Supra Dashboards installed to $INSTALL_DIR/dashboards"

# ---- Install Supra Log Collector ----
log "Installing Supra Log Collector..."
if ! command -v fluentd &>/dev/null; then
    warn "Log Collector runtime not found. Installing via gem..."
    if ! command -v gem &>/dev/null; then
        err "Ruby gem not found. Install Ruby first: sudo apt install ruby-full"
        err "Then install: sudo gem install fluentd fluent-plugin-opensearch"
        warn "Skipping Log Collector installation. You can install it later and re-run."
    else
        gem install fluentd --no-document
        gem install fluent-plugin-opensearch --no-document
        log "  Log Collector runtime installed via gem."
    fi
else
    log "  Log Collector runtime already installed."
fi

mkdir -p "$INSTALL_DIR/log-collector"

cat > "$INSTALL_DIR/log-collector/fluent.conf" <<FLUENTDCONF
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
  password ${ADMIN_PASSWORD}
  logstash_format true
  logstash_prefix fluentd
  flush_interval 10s
</match>
FLUENTDCONF

chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/log-collector"
log "  Supra Log Collector config installed to $INSTALL_DIR/log-collector/"

# ---- Install systemd services ----
log "Installing systemd services..."
cp "$SCRIPT_DIR/systemd/supra-search.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/supra-dashboards.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/supra-log-collector.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable supra-search.service
systemctl enable supra-dashboards.service
systemctl enable supra-log-collector.service
log "  Systemd services installed and enabled."

# ---- Start services ----
log "Starting services..."

log "  Starting Supra Search Engine..."
systemctl start supra-search.service
echo -n "  Waiting for Supra Search Engine"
for i in $(seq 1 60); do
    if curl -sk -o /dev/null https://localhost:9200 2>/dev/null; then
        echo ""
        log "  Supra Search Engine is ready."
        break
    fi
    echo -n "."
    sleep 2
done

if ! curl -sk -o /dev/null https://localhost:9200 2>/dev/null; then
    echo ""
    warn "Supra Search Engine did not start within 120s. Check: journalctl -u supra-search"
fi

# ---- Initialize security index ----
if [ -d "$INSTALL_DIR/opensearch/plugins/opensearch-security" ]; then
    log "Initializing security index..."
    SECURITY_PLUGIN_DIR="$INSTALL_DIR/opensearch/plugins/opensearch-security"
    chmod +x "$SECURITY_PLUGIN_DIR/tools/securityadmin.sh"
    OPENSEARCH_CONF_DIR="$INSTALL_DIR/opensearch/config"
    export OPENSEARCH_JAVA_HOME="$INSTALL_DIR/opensearch/jdk"

    sleep 5

    sudo -u "$SUPRA_USER" OPENSEARCH_JAVA_HOME="$INSTALL_DIR/opensearch/jdk" bash "$SECURITY_PLUGIN_DIR/tools/securityadmin.sh" \
        -cd "$OPENSEARCH_CONF_DIR/opensearch-security/" \
        -icl -nhnv \
        -cacert "$OPENSEARCH_CONF_DIR/root-ca.pem" \
        -cert "$OPENSEARCH_CONF_DIR/kirk.pem" \
        -key "$OPENSEARCH_CONF_DIR/kirk-key.pem" \
        2>&1 | tail -5
    SECADMIN_EXIT=$?

    if [ $SECADMIN_EXIT -ne 0 ]; then
        warn "Security admin tool exited with code $SECADMIN_EXIT. Retrying..."
        sleep 5
        sudo -u "$SUPRA_USER" OPENSEARCH_JAVA_HOME="$INSTALL_DIR/opensearch/jdk" bash "$SECURITY_PLUGIN_DIR/tools/securityadmin.sh" \
            -cd "$OPENSEARCH_CONF_DIR/opensearch-security/" \
            -icl -nhnv \
            -cacert "$OPENSEARCH_CONF_DIR/root-ca.pem" \
            -cert "$OPENSEARCH_CONF_DIR/kirk.pem" \
            -key "$OPENSEARCH_CONF_DIR/kirk-key.pem" \
            2>&1 | tail -5
    fi
    log "  Security index initialized."

    sleep 2
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "admin:admin" https://localhost:9200 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        log "  Admin login verified successfully."
    else
        warn "  Admin login returned HTTP $HTTP_CODE. Service may still be starting up."
    fi
fi

log "  Starting Supra Log Collector..."
systemctl start supra-log-collector.service

log "  Starting Supra Dashboards..."
systemctl start supra-dashboards.service

# ---- Summary ----
echo ""
echo "============================================"
echo "  Installation Complete!"
echo "============================================"
echo ""
echo "Services:"
echo "  Supra Search Engine:   https://localhost:9200"
echo "  Supra Dashboards:      http://localhost:5601"
echo "  Supra Log Collector:   localhost:5140 (syslog), localhost:24224 (forward)"
echo ""
echo "Credentials:"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Verify:"
echo "  curl -sk -u admin:<password> https://localhost:9200"
echo ""
echo "Manage services:"
echo "  sudo systemctl {start|stop|restart|status} supra-search"
echo "  sudo systemctl {start|stop|restart|status} supra-dashboards"
echo "  sudo systemctl {start|stop|restart|status} supra-log-collector"
echo ""
echo "Logs:"
echo "  journalctl -u supra-search -f"
echo "  journalctl -u supra-dashboards -f"
echo "  journalctl -u supra-log-collector -f"
echo ""
echo "Install directory: $INSTALL_DIR"
echo ""
INSTALL_SCRIPT

chmod +x "$STAGING/install.sh"

# ---------------------------------------------------------------------------
# Create uninstall script
# ---------------------------------------------------------------------------
cat > "$STAGING/uninstall.sh" <<'UNINSTALL_SCRIPT'
#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "Stopping services..."
systemctl stop supra-dashboards.service 2>/dev/null || true
systemctl stop supra-log-collector.service 2>/dev/null || true
systemctl stop supra-search.service 2>/dev/null || true

echo "Disabling services..."
systemctl disable supra-search.service 2>/dev/null || true
systemctl disable supra-dashboards.service 2>/dev/null || true
systemctl disable supra-log-collector.service 2>/dev/null || true

echo "Removing service files..."
rm -f /etc/systemd/system/supra-search.service
rm -f /etc/systemd/system/supra-dashboards.service
rm -f /etc/systemd/system/supra-log-collector.service
systemctl daemon-reload

echo "Removing installation directory..."
rm -rf /opt/supra

echo "Removing sysctl config..."
rm -f /etc/sysctl.d/99-supra.conf
sysctl --system > /dev/null 2>&1

echo ""
echo "Supra stack uninstalled."
echo "Note: The 'supra' user was not removed. To remove: sudo userdel -r supra"
UNINSTALL_SCRIPT

chmod +x "$STAGING/uninstall.sh"

# ---------------------------------------------------------------------------
# Create the final tarball
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] Creating installer package..."
cd "$BUILD_DIR"
tar -czf "$BASE_DIR/${PACKAGE_NAME}-${VERSION}-linux-x64.tar.gz" "$PACKAGE_NAME"

FINAL_SIZE=$(du -sh "$BASE_DIR/${PACKAGE_NAME}-${VERSION}-linux-x64.tar.gz" | cut -f1)

echo ""
echo "============================================"
echo "  Installer Package Ready!"
echo "============================================"
echo ""
echo "  Package: $BASE_DIR/${PACKAGE_NAME}-${VERSION}-linux-x64.tar.gz"
echo "  Size:    $FINAL_SIZE"
echo ""
echo "  To install on another machine:"
echo "    1. Copy the tarball to the target machine"
echo "    2. Extract: tar -xzf ${PACKAGE_NAME}-${VERSION}-linux-x64.tar.gz"
echo "    3. Install: sudo bash ${PACKAGE_NAME}/install.sh"
echo ""
echo "  To uninstall:"
echo "    sudo bash /opt/supra/uninstall.sh"
echo "    (or from extracted dir: sudo bash ${PACKAGE_NAME}/uninstall.sh)"
echo ""

# Cleanup build dir
rm -rf "$BUILD_DIR"
