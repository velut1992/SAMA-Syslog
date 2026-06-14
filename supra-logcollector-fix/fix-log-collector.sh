#!/bin/bash
set -e

################################################################################
# Supra Log Collector - Fix Script for Existing Installation
#
# Fixes the log collector on an already-installed Supra system by:
#   1. Verifying bundled .deb integrity
#   2. (deps are resolved together with fluent-package in step 4)
#   3. Cleaning any partial prior fluent-package install
#   4. Installing fluent-package (release-matched, no host-lib downgrade)
#   5. Installing fluent-plugin-opensearch from bundled gems
#   6. Updating fluent.conf to /opt/supra/log-collector/
#   7. Updating supra-log-collector systemd service
#   8. Starting and verifying the service
#
# Target: Ubuntu LTS 20.04/22.04/24.04, air-gapped (no internet required).
#         The release-matched .deb set is selected from deb/<codename>/.
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

# ---- OS check: select the release-matched .deb set ----
# fluent-package embeds a Ruby built against a specific release's library ABIs,
# so each supported LTS ships its own set under deb/<codename>/.
DEB_SET=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}:${VERSION_CODENAME:-}" in
        ubuntu:focal|ubuntu:jammy|ubuntu:noble) DEB_SET="$VERSION_CODENAME" ;;
        *)
            err "Unsupported OS: ${PRETTY_NAME:-unknown}"
            err "This patch supports Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble)."
            exit 1
            ;;
    esac
else
    err "Cannot read /etc/os-release. This patch requires Ubuntu LTS."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="$SCRIPT_DIR/deb/$DEB_SET"
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
# Step 3: (dependency libraries are installed together with fluent-package
#          in Step 5 via a local apt repo — see note there)
# =========================================================================
# We no longer force-install/downgrade the bundled libs here. On non-jammy
# releases that would replace the host's libssl3/zlib/etc. with mismatched
# versions and corrupt the system. Instead Step 5 resolves the release-matched
# deps from deb/<codename>/ against what the host already provides.
log "Step 3: Dependency libraries will be resolved with fluent-package (Step 5)."

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
# Step 5: Install fluent-package (release-matched deps, no downgrade)
# =========================================================================
log "Step 5: Installing fluent-package ($DEB_SET, offline)..."
FLUENT_DEB=$(find "$DEB_DIR" -name "fluent-package_*.deb" 2>/dev/null | head -1)
if [ -z "$FLUENT_DEB" ]; then
    err "  fluent-package .deb not found in $DEB_DIR"
    exit 1
fi

# Expose deb/<codename>/ as a throwaway local apt repo so apt resolves
# fluent-package's deps against the host (installing only what's missing) and
# never downgrades satisfactory libraries. Falls back to plain dpkg if apt or
# dpkg-scanpackages is unavailable.
SUPRA_APT_LIST="/etc/apt/sources.list.d/supra-fluent.list"
installed_via_apt=0
if command -v dpkg-scanpackages >/dev/null 2>&1; then
    ( cd "$DEB_DIR" && dpkg-scanpackages -m . > Packages 2>/dev/null && gzip -kf Packages )
    if [ -s "$DEB_DIR/Packages" ]; then
        echo "deb [trusted=yes] file:$DEB_DIR ./" > "$SUPRA_APT_LIST"
        apt-get -o Dir::Etc::sourcelist="sources.list.d/supra-fluent.list" \
                -o Dir::Etc::sourceparts="-" \
                -o APT::Get::List-Cleanup="0" update >/dev/null 2>&1 || true
        if apt-get install -y --no-download fluent-package >/tmp/supra-fluent-apt.log 2>&1; then
            installed_via_apt=1
            log "  fluent-package installed (apt resolved release-matched deps)."
        else
            warn "  apt path failed (see /tmp/supra-fluent-apt.log); falling back to dpkg."
        fi
        rm -f "$SUPRA_APT_LIST"
        apt-get update >/dev/null 2>&1 || true
    fi
fi

if [ "$installed_via_apt" -ne 1 ]; then
    log "  Installing fluent-package + bundled $DEB_SET deps (dpkg, single transaction)"
    # Install everything in ONE dpkg call so dpkg orders configuration by
    # dependency (e.g. libtinfo6 before libncurses6). Installing the libs
    # one-at-a-time leaves an intermediate dep unconfigured and fluent-package
    # then refuses with "libncurses6 is not configured yet".
    if ! dpkg -i "$DEB_DIR"/*.deb >/tmp/supra-fluent-dpkg.log 2>&1; then
        warn "  dpkg reported issues; running 'dpkg --configure -a' to finish ordering..."
        dpkg --configure -a >>/tmp/supra-fluent-dpkg.log 2>&1 || true
        dpkg -i "$FLUENT_DEB" >>/tmp/supra-fluent-dpkg.log 2>&1 || true
    fi
    if [ ! -x "$FLUENTD_BIN" ]; then
        err "  fluent-package install failed. See /tmp/supra-fluent-dpkg.log"
        exit 1
    fi
    log "  fluent-package installed."
fi

if [ ! -f "$FLUENT_GEM" ] || [ ! -f "$FLUENTD_BIN" ]; then
    err "  fluent-package install reported success but $FLUENTD_BIN is missing."
    exit 1
fi
"$FLUENTD_BIN" --version || true

# =========================================================================
# Step 6: Use fluent-package's complete, consistent plugin/gem stack as-is
# =========================================================================
# fluent-package 5.0.9 ships a complete, internally-consistent stack: fluentd
# 1.16.x + fluent-plugin-opensearch + aws-sdk-core + jmespath + faraday +
# opensearch-ruby + fluent-plugin-s3, all mutually compatible.
#
# We must NOT uninstall any of its gems. A previous version of this script ran
# an "uninstall every version present in gems/" loop to strip a supposed
# second, newer plugin set. But gems/ also carries shared dependency gems
# (jmespath, base64, multi_json, aws-*, faraday*) at the SAME versions
# fluent-package bundles — so the loop uninstalled fluent-package's own
# jmespath-1.6.2. aws-sdk-core (required at dry-run time by both
# fluent-plugin-s3 and fluent-plugin-opensearch) then could not activate:
#   Could not find 'jmespath' (~> 1, >= 1.6.1) ... (Gem::MissingSpecError)
#   cannot load such file -- aws-sdk-core (LoadError)
# which aborted the dry-run. So: no uninstalls — keep fluent-package pristine.
log "Step 6: Verifying fluent-plugin-opensearch (bundled with fluent-package)..."
if "$FLUENT_GEM" list -i fluent-plugin-opensearch >/dev/null 2>&1; then
    log "  fluent-plugin-opensearch provided by fluent-package; using its stack as-is."
elif [ -d "$GEMS_DIR" ] && ls "$GEMS_DIR"/*.gem >/dev/null 2>&1; then
    warn "  fluent-plugin-opensearch absent from fluent-package; installing bundled gem closure..."
    # gems/ is the COMPLETE dependency closure, so --ignore-dependencies (offline,
    # no remote fetch) leaves every transitive dep — including jmespath — present.
    "$FLUENT_GEM" install --no-document --local --ignore-dependencies "$GEMS_DIR"/*.gem
else
    err "  fluent-plugin-opensearch is unavailable and no fallback gems were bundled."
    exit 1
fi

# fluentd loads EVERY bundled plugin during a dry-run (s3, opensearch, ...), so
# a single missing transitive gem (e.g. jmespath behind aws-sdk-core) fails it.
# If that happens and we shipped the gem closure, backfill it and retry once.
log "  Verifying fluentd config (dry-run)..."
if ! "$FLUENTD_BIN" --dry-run -c "$SCRIPT_DIR/fluent.conf" >/tmp/fluentd-dryrun.log 2>&1; then
    if grep -qiE "MissingSpec|cannot load such file|Could not find|LoadError" /tmp/fluentd-dryrun.log \
       && [ -d "$GEMS_DIR" ] && ls "$GEMS_DIR"/*.gem >/dev/null 2>&1; then
        warn "  Dry-run hit a missing gem; backfilling from bundled gem closure and retrying..."
        "$FLUENT_GEM" install --no-document --local --ignore-dependencies "$GEMS_DIR"/*.gem \
            >/tmp/supra-gem-repair.log 2>&1 || true
    fi
    if ! "$FLUENTD_BIN" --dry-run -c "$SCRIPT_DIR/fluent.conf" >/tmp/fluentd-dryrun.log 2>&1; then
        err "  fluentd dry-run failed. Output:"
        cat /tmp/fluentd-dryrun.log
        exit 1
    fi
fi
log "  fluentd config dry-run OK."

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
# World-readable so the supra service user can always read it (a later root edit
# that resets ownership won't lock the service out with Errno::EACCES).
chmod 0644 "$INSTALL_DIR/log-collector/fluent.conf"
log "  Config deployed to $INSTALL_DIR/log-collector/fluent.conf"

# =========================================================================
# Step 8: Free the syslog ports (rsyslog vs. the collector on :514)
# =========================================================================
# fluent.conf binds 514/udp+tcp (IED syslog). On many hosts rsyslog already
# listens on :514 (imudp/imtcp), so the fluentd worker dies at start with:
#   Errno::EADDRINUSE error="Address already in use - bind(2) for 0.0.0.0:514"
# This box is a dedicated Supra log collector, so fluentd must own :514. We
# disable ONLY rsyslog's *network* reception (imudp/imtcp + their listeners);
# local logging via /dev/log and journald is untouched. Reversible: each edited
# file is backed up to <file>.supra-bak and our changes are marked SUPRA-DISABLED.
log "Step 8: Ensuring port 514 is free for the collector (rsyslog check)..."
free_syslog_ports() {
    command -v rsyslogd >/dev/null 2>&1 || { log "  rsyslog not installed; :514 is free for the collector."; return 0; }

    local files=() f
    [ -f /etc/rsyslog.conf ] && files+=("/etc/rsyslog.conf")
    for f in /etc/rsyslog.d/*.conf; do [ -f "$f" ] && files+=("$f"); done
    [ "${#files[@]}" -gt 0 ] || return 0

    # These tokens only ever appear on input/module lines, never on forwarding
    # actions (@host / @@host) — so rsyslog forwarding rules are left intact.
    local net_re='^[[:space:]]*(module\(load="im(udp|tcp)"\)|input\(type="im(udp|tcp)"|\$ModLoad[[:space:]]+im(udp|tcp)|\$UDPServerRun|\$InputTCPServerRun)'
    if ! grep -Eq "$net_re" "${files[@]}" 2>/dev/null; then
        log "  rsyslog is not receiving network syslog; :514 is free for the collector."
        return 0
    fi

    log "  rsyslog is listening for network syslog (imudp/imtcp) — it owns :514."
    log "  Disabling rsyslog network reception so the collector can bind 514/1514/2514..."
    for f in "${files[@]}"; do
        grep -Eq "$net_re" "$f" 2>/dev/null || continue
        [ -f "${f}.supra-bak" ] || cp -a "$f" "${f}.supra-bak"
        sed -i -E \
            -e 's/^([[:space:]]*)(module\(load="im(udp|tcp)"\).*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(input\(type="im(udp|tcp)".*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(\$ModLoad[[:space:]]+im(udp|tcp).*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(\$UDPServerRun.*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(\$InputTCPServerRun.*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(\$UDPServerAddress.*)$/\1#SUPRA-DISABLED \2/' \
            -e 's/^([[:space:]]*)(\$InputTCPServerAddress.*)$/\1#SUPRA-DISABLED \2/' \
            "$f"
    done
    if systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null; then
        log "  rsyslog network reception on :514 disabled (local logging preserved)."
    else
        warn "  Could not restart rsyslog automatically; run 'sudo systemctl restart rsyslog'."
    fi
}
free_syslog_ports

# =========================================================================
# Step 9: Update systemd service
# =========================================================================
log "Step 9: Updating supra-log-collector systemd service..."

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
# Step 10: Start and verify
# =========================================================================
log "Step 10: Starting supra-log-collector..."
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
