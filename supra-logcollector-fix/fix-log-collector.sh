#!/bin/bash
set -e

################################################################################
# Supra Log Collector - Fix Script for Existing Installation
#
# Fixes the log collector on an already-installed Supra system by:
#   1. Verifying bundled .deb integrity
#   2. Installing/restoring jammy dependency libraries
#   3. Cleaning any partial prior fluent-package install
#   4. Installing fluent-package (self-contained Fluentd with bundled Ruby)
#   5. Installing fluent-plugin-opensearch from bundled gems
#   6. Updating fluent.conf to /opt/supra/log-collector/
#   7. Updating supra-log-collector systemd service
#   8. Starting and verifying the service
#
# Target: Ubuntu 22.04 LTS (jammy), air-gapped (no internet required)
# Usage:  sudo bash fix-log-collector.sh
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---- Root check ----
if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root. Use: sudo bash fix-log-collector.sh"
    exit 1
fi

# ---- OS check ----
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${VERSION_CODENAME:-}" != "jammy" ]; then
        warn "This patch targets Ubuntu 22.04 (jammy). Detected: ${PRETTY_NAME:-unknown}"
        warn "Proceeding anyway, but installs may fail."
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="$SCRIPT_DIR/deb"
GEMS_DIR="$SCRIPT_DIR/gems"
INSTALL_DIR="/opt/supra"
SUPRA_USER="supra"
SUPRA_GROUP="supra"
FLUENT_GEM="/opt/fluent/bin/fluent-gem"
FLUENTD_BIN="/opt/fluent/bin/fluentd"

echo ""
echo "============================================"
echo "  Supra Log Collector - Fix Script"
echo "============================================"
echo ""

# =========================================================================
# Step 1: Stop existing log collector service
# =========================================================================
log "Step 1: Stopping existing services..."
systemctl stop supra-log-collector.service 2>/dev/null || true
systemctl stop fluentd.service 2>/dev/null || true
log "  Services stopped."

# =========================================================================
# Step 2: Verify .deb integrity (catch corrupted bundles up front)
# =========================================================================
log "Step 2: Verifying bundled .deb integrity..."
if [ ! -d "$DEB_DIR" ]; then
    err "  Missing deb directory: $DEB_DIR"
    exit 1
fi

bad=0
for d in "$DEB_DIR"/*.deb; do
    [ -f "$d" ] || continue
    if ! dpkg-deb --contents "$d" >/dev/null 2>&1; then
        err "  Corrupt or truncated: $(basename "$d")"
        bad=1
    fi
done
if [ $bad -ne 0 ]; then
    err "  One or more .deb files are corrupted. Re-copy the supra-logcollector-fix"
    err "  directory from the source and try again."
    exit 1
fi
log "  All bundled .debs OK."

# =========================================================================
# Step 3: Install / restore jammy dependency libraries
# =========================================================================
# These are the jammy versions of every library fluent-package depends on.
# Installing them as a single dpkg transaction lets dpkg sort ordering.
# --force-downgrade is set in case a previous (broken) run installed older
# focal-era libs and we need to put the system back on jammy versions.
log "Step 3: Installing/restoring dependency libraries (jammy)..."

DEP_DEBS=()
for d in "$DEB_DIR"/lib*.deb "$DEB_DIR"/zlib*.deb; do
    [ -f "$d" ] && DEP_DEBS+=("$d")
done

if [ "${#DEP_DEBS[@]}" -eq 0 ]; then
    err "  No dependency .debs found in $DEB_DIR"
    exit 1
fi

if dpkg -i --force-downgrade "${DEP_DEBS[@]}" 2>&1 | tail -20; then
    log "  Dependency libraries installed."
else
    warn "  dpkg reported issues installing dependencies (see above)."
fi

# =========================================================================
# Step 4: Remove any prior partial fluent-package install
# =========================================================================
# A previous broken run could have left fluent-package in an unpacked-but-
# unconfigured state. Force-purge so the fresh install starts clean.
log "Step 4: Cleaning any prior fluent-package state..."
if dpkg-query -W -f='${Status}\n' fluent-package 2>/dev/null | grep -qE 'installed|unpacked|half'; then
    systemctl stop fluentd.service 2>/dev/null || true
    dpkg --purge --force-all fluent-package 2>&1 | tail -5 || true
    log "  Prior fluent-package state cleared."
else
    log "  No prior fluent-package install detected."
fi

# =========================================================================
# Step 5: Install fluent-package
# =========================================================================
log "Step 5: Installing fluent-package..."
FLUENT_DEB=$(find "$DEB_DIR" -name "fluent-package_*.deb" 2>/dev/null | head -1)
if [ -z "$FLUENT_DEB" ]; then
    err "  fluent-package .deb not found in $DEB_DIR"
    exit 1
fi

log "  Installing from: $(basename "$FLUENT_DEB")"
if dpkg -i "$FLUENT_DEB"; then
    log "  fluent-package installed."
else
    err "  fluent-package install failed."
    err "  Check that all dependency libs in Step 3 installed correctly."
    exit 1
fi

if [ ! -f "$FLUENT_GEM" ] || [ ! -f "$FLUENTD_BIN" ]; then
    err "  fluent-package install reported success but $FLUENTD_BIN is missing."
    exit 1
fi
"$FLUENTD_BIN" --version || true

# =========================================================================
# Step 6: Install fluent-plugin-opensearch from bundled gems
# =========================================================================
# The bundle ships only pure-Ruby gems (no C extensions) — every gem that
# needs a native compile (bigdecimal, msgpack, cool.io, http_parser.rb,
# json, strptime, yajl-ruby) is already inside fluent-package's bundled
# Ruby, so we don't reinstall them here. --ignore-dependencies prevents
# rubygems from trying to fetch anything from the network.
log "Step 6: Installing fluent-plugin-opensearch from bundled gems..."
if [ ! -d "$GEMS_DIR" ] || ! ls "$GEMS_DIR"/*.gem >/dev/null 2>&1; then
    err "  No .gem files found in $GEMS_DIR"
    exit 1
fi

"$FLUENT_GEM" install --no-document --local --ignore-dependencies "$GEMS_DIR"/*.gem
log "  Plugin gems installed."

log "  Verifying fluent-plugin-opensearch is loadable..."
if "$FLUENTD_BIN" --dry-run -c "$SCRIPT_DIR/fluent.conf" >/tmp/fluentd-dryrun.log 2>&1; then
    log "  fluentd config dry-run OK."
else
    err "  fluentd dry-run failed. Output:"
    cat /tmp/fluentd-dryrun.log
    exit 1
fi

log "  Installed plugins of interest:"
"$FLUENT_GEM" list 2>/dev/null | grep -E "fluentd|fluent-plugin-opensearch|opensearch-ruby" || true

# =========================================================================
# Step 7: Deploy fluent.conf
# =========================================================================
log "Step 7: Deploying fluent.conf..."
mkdir -p "$INSTALL_DIR/log-collector"

if [ -f "$SCRIPT_DIR/fluent.conf" ]; then
    cp "$SCRIPT_DIR/fluent.conf" "$INSTALL_DIR/log-collector/fluent.conf"
    log "  Using fluent.conf from fix package."
elif [ -f "$INSTALL_DIR/log-collector/fluent.conf" ]; then
    log "  Existing fluent.conf found; keeping it."
else
    err "  No fluent.conf provided and none exists at $INSTALL_DIR/log-collector/"
    exit 1
fi

# Create supra user/group if absent so chown doesn't fail
if ! getent group "$SUPRA_GROUP" >/dev/null; then
    groupadd --system "$SUPRA_GROUP"
fi
if ! id -u "$SUPRA_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SUPRA_GROUP" --home-dir "$INSTALL_DIR" \
            --shell /usr/sbin/nologin "$SUPRA_USER"
fi
chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/log-collector"
log "  Config deployed to $INSTALL_DIR/log-collector/fluent.conf"

# =========================================================================
# Step 8: Update systemd service
# =========================================================================
log "Step 8: Updating supra-log-collector systemd service..."

cat > /etc/systemd/system/supra-log-collector.service <<'EOF'
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

# Disable the default fluentd service that ships with fluent-package
systemctl stop fluentd.service 2>/dev/null || true
systemctl disable fluentd.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable supra-log-collector.service
log "  Systemd service updated and enabled."

# =========================================================================
# Step 9: Start and verify
# =========================================================================
log "Step 9: Starting supra-log-collector..."
systemctl restart supra-log-collector

sleep 3

if systemctl is-active --quiet supra-log-collector; then
    log "  supra-log-collector is RUNNING"
else
    err "  supra-log-collector failed to start. Recent journal:"
    journalctl -u supra-log-collector --no-pager -n 30
    exit 1
fi

echo ""
echo "============================================"
echo "  Fix Complete!"
echo "============================================"
echo ""
echo "  Service:  supra-log-collector"
echo "  Binary:   /opt/fluent/bin/fluentd"
echo "  Config:   $INSTALL_DIR/log-collector/fluent.conf"
echo "  Ports:    UDP/514 (syslog), TCP/24224 (forward)"
echo ""
echo "  Manage:"
echo "    sudo systemctl {start|stop|restart|status} supra-log-collector"
echo ""
echo "  Logs:"
echo "    journalctl -u supra-log-collector -f"
echo ""
