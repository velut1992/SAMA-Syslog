#!/bin/bash
set -e

################################################################################
# Supra Installer Package Builder (Linux x64)
#
# Builds a self-contained installer tarball that can be deployed on another
# Linux x64 machine. The package includes:
#   - Supra Search Engine (full distribution with all plugins)
#   - Supra Dashboards (full distribution with all plugins)
#   - Extra Dashboards plugins (SIEM, Index Management, Notifications, Reporting)
#   - Supra Log Collector (fluent-package + OpenSearch plugin gems)
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
INDEX_MANAGEMENT_DIR="$BASE_DIR/index-management"
INDEX_TEMPLATE_SCRIPT="$BASE_DIR/supra-index-template.sh"
DASHBOARDS_SRC="$BASE_DIR/OpenSearch-Dashboards"
# Canonical, version-controlled installer scripts (copied into the bundle below
# instead of being inlined here — keeps them diffable and prevents the drift
# that previously left the shipped install.sh ahead of this builder).
INSTALLER_SRC="$SCRIPT_DIR/installer-src"

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
    OPENSEARCH_URL="https://ci.opensearch.org/ci/dbc/distribution-build-opensearch/${VERSION}/latest/linux/x64/tar/dist/opensearch/opensearch-${VERSION}-linux-x64.tar.gz"
    echo "  Search engine tarball not found. Downloading..."
    echo "    URL: $OPENSEARCH_URL"
    if curl -fSL -o "$OPENSEARCH_TARBALL" "$OPENSEARCH_URL" 2>&1; then
        echo "    Downloaded: $(du -sh "$OPENSEARCH_TARBALL" | cut -f1)"
    else
        echo "ERROR: Failed to download Supra Search Engine." >&2
        echo "       URL: $OPENSEARCH_URL" >&2
        echo "       Please download manually and place at: $OPENSEARCH_TARBALL" >&2
        rm -f "$OPENSEARCH_TARBALL"
        exit 1
    fi
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

for f in install.sh uninstall.sh; do
    if [ ! -f "$INSTALLER_SRC/$f" ]; then
        echo "ERROR: Installer source $INSTALLER_SRC/$f not found." >&2
        exit 1
    fi
done

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
    "indexManagementDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/indexManagementDashboards-${VERSION}.zip"
    "notificationsDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/notificationsDashboards-${VERSION}.zip"
    "securityAnalyticsDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/securityAnalyticsDashboards-${VERSION}.zip"
    "reportsDashboards|${DASHBOARDS_PLUGIN_BASE_URL}/reportsDashboards-${VERSION}.zip"
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
mkdir -p "$STAGING"/{opensearch,dashboards,dashboards-plugins,log-collector,systemd,branding,license-validator,index-management,index-template}

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
# Package Supra Log Collector (fluent-package + OpenSearch plugin gems)
# ---------------------------------------------------------------------------
echo ""
echo "[5/7] Packaging Supra Log Collector..."
cp "$FLUENTD_CONF" "$STAGING/log-collector/"
echo "  Log Collector config staged."

# Provide release-matched fluent-package + dependency-lib sets for every
# supported Ubuntu LTS as log-collector/deb/<codename>/. install.sh selects the
# matching set at runtime. We prefer reusing a known-good local set (these are
# version-controlled and already validated); fetching fresh is only needed for
# codenames that aren't present locally, and cross-release fetching requires
# Docker. $DEB_SETS_SRC can be overridden; it defaults to the fix package's set.
DEB_SETS_SRC="${DEB_SETS_SRC:-$BASE_DIR/supra-logcollector-fix/deb}"
DEB_SETS_SCRIPT="$BASE_DIR/scripts/build-deb-sets.sh"
echo "  Assembling release-matched Log Collector .deb sets (focal/jammy/noble)..."
for cn in focal jammy noble; do
    dest="$STAGING/log-collector/deb/$cn"
    mkdir -p "$dest"
    if ls "$DEB_SETS_SRC/$cn"/fluent-package_*.deb >/dev/null 2>&1; then
        cp "$DEB_SETS_SRC/$cn"/*.deb "$dest/"
        echo "    $cn: reused local set ($(ls "$dest"/*.deb | wc -l) debs)."
    elif [ -x "$DEB_SETS_SCRIPT" ]; then
        echo "    $cn: not present locally — fetching..."
        bash "$DEB_SETS_SCRIPT" "$STAGING/log-collector/deb" "$cn" || true
    fi
    if ! ls "$dest"/fluent-package_*.deb >/dev/null 2>&1; then
        echo "ERROR: fluent-package .deb missing for $cn." >&2
        echo "       Provide it under $DEB_SETS_SRC/$cn/ or re-run with Docker available." >&2
        exit 1
    fi
done

# Stage the OpenSearch plugin gems for offline installation.
#
# install.sh uses this set only as a FALLBACK: (a) a complete-closure install if
# a given fluent-package build somehow lacks fluent-plugin-opensearch, and (b) a
# self-healing backfill if the fluentd dry-run trips over a missing transitive
# gem (e.g. jmespath behind aws-sdk-core). install.sh no longer uninstalls
# anything — fluent-package's bundled stack is used as-is — so this set must be
# the COMPLETE dependency closure (fluent-plugin-opensearch + opensearch-ruby +
# aws-* + faraday* + jmespath + ...), which the curated fix-package gems are.
# Prefer those version-controlled gems; only download as a last resort when
# they're absent (a bare `gem install` also drags in a 34-gem fluentd stack).
GEMS_DIR="$STAGING/log-collector/gems"
mkdir -p "$GEMS_DIR"
CURATED_GEMS="$BASE_DIR/supra-logcollector-fix/gems"
if ls "$CURATED_GEMS"/*.gem >/dev/null 2>&1; then
    cp "$CURATED_GEMS"/*.gem "$GEMS_DIR/"
    GEMS_COUNT=$(find "$GEMS_DIR" -name "*.gem" 2>/dev/null | wc -l)
    echo "  Reused curated opensearch gem stack ($GEMS_COUNT gems) from fix package."
else
    echo "  Curated gem set not found; downloading fluent-plugin-opensearch..."
    TMPGEM=$(mktemp -d)
    if gem install fluent-plugin-opensearch --no-document --install-dir "$TMPGEM" 2>/dev/null; then
        cp "$TMPGEM"/cache/*.gem "$GEMS_DIR/" 2>/dev/null
        GEMS_COUNT=$(find "$GEMS_DIR" -name "*.gem" 2>/dev/null | wc -l)
        echo "  $GEMS_COUNT plugin gem files cached for offline install."
    else
        echo "  WARNING: Failed to download plugin gems."
        echo "           Target machines will need internet to install fluent-plugin-opensearch."
    fi
    rm -rf "$TMPGEM"
fi

# ---------------------------------------------------------------------------
# Package license validator (auto-build with Maven if zip is missing)
# ---------------------------------------------------------------------------
if [ -d "$LICENSE_VALIDATOR_DIR" ]; then
    echo "  Packaging license validator..."
    PLUGIN_ZIP=$(find "$LICENSE_VALIDATOR_DIR/license-validator/target/releases" -name "supra-license-validator-*.zip" 2>/dev/null | head -1)
    if [ -z "$PLUGIN_ZIP" ]; then
        echo "    Plugin zip not found — building with Maven..."
        if ! command -v mvn &>/dev/null; then
            echo "    ERROR: Maven (mvn) is not installed or not in PATH."
            echo "           Install it with: sudo apt install maven  (or equivalent)"
            echo "           Skipping license validator plugin."
        else
            # Use bundled OpenSearch JDK if JAVA_HOME is not set
            if [ -z "$JAVA_HOME" ]; then
                BUNDLED_JDK="$BASE_DIR/opensearch-${VERSION}-linux-x64/jdk"
                if [ -d "$BUNDLED_JDK" ]; then
                    export JAVA_HOME="$BUNDLED_JDK"
                    echo "    Using bundled OpenSearch JDK: $BUNDLED_JDK"
                fi
            fi
            POM_FILE="$LICENSE_VALIDATOR_DIR/license-validator/pom.xml"
            echo "    Running: mvn clean package -f $POM_FILE"
            if mvn clean package -f "$POM_FILE" -q; then
                echo "    Maven build succeeded."
            else
                echo "    ERROR: Maven build failed. Ensure Java 17+ and Maven are installed."
            fi
            PLUGIN_ZIP=$(find "$LICENSE_VALIDATOR_DIR/license-validator/target/releases" -name "supra-license-validator-*.zip" 2>/dev/null | head -1)
        fi
    fi
    if [ -n "$PLUGIN_ZIP" ]; then
        cp "$PLUGIN_ZIP" "$STAGING/license-validator/"
        echo "    Plugin zip staged: $(basename "$PLUGIN_ZIP")"
    else
        echo "    WARNING: License validator plugin zip not available. Skipping."
    fi
    if [ -f "$LICENSE_VALIDATOR_DIR/keys/public.key" ]; then
        cp "$LICENSE_VALIDATOR_DIR/keys/public.key" "$STAGING/license-validator/"
        echo "    Public key staged."
    fi
    if [ -f "$LICENSE_VALIDATOR_DIR/get-fingerprint.sh" ]; then
        cp "$LICENSE_VALIDATOR_DIR/get-fingerprint.sh" "$STAGING/license-validator/"
        echo "    Fingerprint script staged."
    fi
fi

# ---------------------------------------------------------------------------
# Package Index Management backend plugin (auto-build with Gradle if zip is missing)
# ---------------------------------------------------------------------------
if [ -d "$INDEX_MANAGEMENT_DIR" ]; then
    echo "  Packaging Index Management plugin..."
    IM_PLUGIN_ZIP=$(find "$INDEX_MANAGEMENT_DIR/build/distributions" -name "opensearch-index-management-*.zip" 2>/dev/null | head -1)
    if [ -z "$IM_PLUGIN_ZIP" ]; then
        echo "    Plugin zip not found — building with Gradle..."
        GRADLEW_CMD="$INDEX_MANAGEMENT_DIR/gradlew"
        if [ ! -f "$GRADLEW_CMD" ]; then
            echo "    ERROR: gradlew not found in $INDEX_MANAGEMENT_DIR"
            echo "           Skipping Index Management plugin."
        else
            # Use bundled OpenSearch JDK if JAVA_HOME is not set
            if [ -z "$JAVA_HOME" ]; then
                BUNDLED_JDK="$BASE_DIR/opensearch-${VERSION}-linux-x64/jdk"
                if [ -d "$BUNDLED_JDK" ]; then
                    export JAVA_HOME="$BUNDLED_JDK"
                    echo "    Using bundled OpenSearch JDK: $BUNDLED_JDK"
                fi
            fi
            echo "    Running: gradlew assemble (this may take a while)..."
            cd "$INDEX_MANAGEMENT_DIR"
            chmod +x "$GRADLEW_CMD"
            if "$GRADLEW_CMD" assemble -x test -q; then
                echo "    Gradle build succeeded."
            else
                echo "    ERROR: Gradle build failed. Ensure Java 17+ is installed."
            fi
            cd "$SCRIPT_DIR"
            IM_PLUGIN_ZIP=$(find "$INDEX_MANAGEMENT_DIR/build/distributions" -name "opensearch-index-management-*.zip" 2>/dev/null | head -1)
        fi
    fi
    if [ -n "$IM_PLUGIN_ZIP" ]; then
        cp "$IM_PLUGIN_ZIP" "$STAGING/index-management/"
        echo "    Plugin zip staged: $(basename "$IM_PLUGIN_ZIP")"
    else
        echo "    WARNING: Index Management plugin zip not available. Skipping."
    fi
fi

# ---------------------------------------------------------------------------
# Package index template one-shot script
# ---------------------------------------------------------------------------
# install.sh copies this to /opt/supra/index-template/ and enables
# supra-index-template.service, which applies it once supra-search is healthy.
# Without it staged here, install.sh's `cp` would fail under `set -e`.
if [ -f "$INDEX_TEMPLATE_SCRIPT" ]; then
    cp "$INDEX_TEMPLATE_SCRIPT" "$STAGING/index-template/supra-index-template.sh"
    echo "  Index template script staged."
else
    echo "ERROR: Index template script not found at $INDEX_TEMPLATE_SCRIPT" >&2
    exit 1
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
# Write the hardware fingerprint to a supra-readable cache BEFORE OpenSearch
# starts. The '+' runs this as root (User= is ignored) so it can read the
# root-only DMI files; the license-validator plugin (running as supra) then
# reads config/supra-license/machine-id, keeping it consistent with
# get-fingerprint.sh and machine-bound. See MachineFingerprint.generate(Path).
ExecStartPre=+/bin/bash -c 'MACHINE_ID_FILE=/opt/supra/opensearch/config/supra-license/machine-id bash /opt/supra/opensearch/config/supra-license/get-fingerprint.sh >/dev/null 2>&1 || true'
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/opt/fluent/bin/fluentd -c /opt/supra/log-collector/fluent.conf
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# One-shot: waits for the search engine HTTP API to come up, then applies the
# supra-* index template. RemainAfterExit keeps it from re-running every boot;
# the PUT is idempotent, so a manual `systemctl start supra-index-template`
# after licensing is always safe.
cat > "$STAGING/systemd/supra-index-template.service" <<'EOF'
[Unit]
Description=Supra Index Template (one-shot)
After=network.target supra-search.service
Requires=supra-search.service

[Service]
Type=oneshot
User=supra
Group=supra
RemainAfterExit=true
ExecStartPre=/bin/bash -c 'for i in $(seq 1 120); do (exec 3<>/dev/tcp/localhost/9200) 2>/dev/null && exit 0; sleep 5; done; echo "timed out waiting for supra-search on :9200" >&2; exit 1'
ExecStart=/opt/supra/index-template/supra-index-template.sh

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Create the install script
# ---------------------------------------------------------------------------
cp "$INSTALLER_SRC/install.sh" "$STAGING/install.sh"

chmod +x "$STAGING/install.sh"

# ---------------------------------------------------------------------------
# Create uninstall script
# ---------------------------------------------------------------------------
cp "$INSTALLER_SRC/uninstall.sh" "$STAGING/uninstall.sh"

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
