#!/bin/bash
set -e

################################################################################
# Supra Stack Installer (fully offline, Ubuntu LTS)
#
# Installs:
#   * Supra Search Engine (OpenSearch + license validator + index management)
#   * Supra Dashboards (OpenSearch Dashboards + extra plugins)
#   * Supra Log Collector (fluent-package 5.0.9 + fluent-plugin-opensearch)
#   * supra-index-template one-shot (auto-applies template on first search start)
#
# Strictly offline: no internet/apt/gem access required. All artifacts ship in
# the installer tarball. Supported targets are the major Ubuntu LTS releases:
# 20.04 (focal), 22.04 (jammy) and 24.04 (noble). fluent-package embeds a Ruby
# built against a specific release's library ABIs, so a release-matched .deb set
# ships under log-collector/deb/<codename>/ and is selected at runtime. We never
# force-downgrade host libraries — apt resolves the bundled set against what the
# host already provides.
#
# Must be run as root (or with sudo).
################################################################################

INSTALL_DIR="/opt/supra"
SUPRA_USER="supra"
SUPRA_GROUP="supra"

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

# ---- OS check: supported Ubuntu LTS releases ----
# Each supported release ships its own release-matched fluent-package + dep-lib
# set under log-collector/deb/<codename>/. We pick the matching set here so the
# bundled .debs always agree with the host's library ABIs (e.g. noble's libssl3
# is libssl3t64 — the jammy deb would be uninstallable there).
if [ ! -r /etc/os-release ]; then
    err "Cannot read /etc/os-release. This installer requires Ubuntu LTS."
    exit 1
fi
. /etc/os-release
case "${ID:-}:${VERSION_CODENAME:-}" in
    ubuntu:focal|ubuntu:jammy|ubuntu:noble)
        DEB_SET="$VERSION_CODENAME"
        ;;
    *)
        err "Unsupported OS: ${PRETTY_NAME:-unknown}"
        err "This installer supports the major Ubuntu LTS releases:"
        err "  Ubuntu 20.04 (focal), 22.04 (jammy), 24.04 (noble)."
        err "Install on a supported release and re-run."
        exit 1
        ;;
esac

# Block 32-bit hosts up front — every .deb in this bundle is amd64.
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "x86_64" ]; then
    err "Unsupported architecture: $ARCH. This installer ships amd64 binaries."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "============================================"
echo "  Supra Stack Installer"
echo "  ${PRETTY_NAME:-Ubuntu LTS}  -  fully offline"
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

# Secure PEM certificate file permissions (OpenSearch Security requires 0600)
for pem_file in esnode.pem esnode-key.pem kirk.pem kirk-key.pem root-ca.pem; do
    if [ -f "$INSTALL_DIR/opensearch/config/$pem_file" ]; then
        chmod 600 "$INSTALL_DIR/opensearch/config/$pem_file"
    fi
done
log "  PEM certificate permissions secured."

log "  Supra Search Engine installed to $INSTALL_DIR/opensearch"

# ---- Install Supra License Validator Plugin ----
log "Installing Supra License Validator plugin..."
PLUGIN_ZIP=$(find "$SCRIPT_DIR/license-validator" -name "supra-license-validator-*.zip" 2>/dev/null | head -1)
if [ -n "$PLUGIN_ZIP" ]; then
    sudo -u "$SUPRA_USER" "$INSTALL_DIR/opensearch/bin/opensearch-plugin" install --batch "file://$PLUGIN_ZIP"
    log "  License validator plugin installed."
else
    warn "  License validator plugin zip not found. Skipping."
fi

# Create license config directory with secure permissions
mkdir -p "$INSTALL_DIR/opensearch/config/supra-license"
if [ -f "$SCRIPT_DIR/license-validator/public.key" ]; then
    cp "$SCRIPT_DIR/license-validator/public.key" "$INSTALL_DIR/opensearch/config/supra-license/"
    chmod 600 "$INSTALL_DIR/opensearch/config/supra-license/public.key"
    log "  Public key installed."
fi
if [ -f "$SCRIPT_DIR/license-validator/get-fingerprint.sh" ]; then
    cp "$SCRIPT_DIR/license-validator/get-fingerprint.sh" "$INSTALL_DIR/opensearch/config/supra-license/"
    chmod 600 "$INSTALL_DIR/opensearch/config/supra-license/get-fingerprint.sh"
    log "  Fingerprint tool installed."
fi
chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/opensearch/config/supra-license"
chmod 700 "$INSTALL_DIR/opensearch/config/supra-license"

# ---- Install Index Management Plugin ----
# The full OpenSearch distribution we ship already bundles
# opensearch-index-management at the matching version. Re-installing the zip on
# top makes opensearch-plugin abort with "plugin directory already exists" —
# harmless, but it looks like a failure. So only install the zip if the plugin
# is genuinely absent (e.g. a future switch to the -min distribution).
log "Installing Index Management plugin..."
IM_PLUGIN_DIR="$INSTALL_DIR/opensearch/plugins/opensearch-index-management"
if [ -d "$IM_PLUGIN_DIR" ]; then
    log "  Index Management already bundled in the search engine distribution; skipping."
else
    IM_PLUGIN_ZIP=$(find "$SCRIPT_DIR/index-management" -name "opensearch-index-management-*.zip" 2>/dev/null | head -1)
    if [ -n "$IM_PLUGIN_ZIP" ]; then
        if sudo -u "$SUPRA_USER" "$INSTALL_DIR/opensearch/bin/opensearch-plugin" install --batch "file://$IM_PLUGIN_ZIP"; then
            log "  Index Management plugin installed."
        else
            warn "  Index Management plugin install failed."
            warn "  Plugin zip may be built for a different OpenSearch version."
            warn "  Continuing install - place a compatible plugin zip and re-run."
        fi
    else
        warn "  Index Management plugin zip not found and not bundled. Skipping."
    fi
fi

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

opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
opensearch_security.cookie.secure: false
opensearch_security.ui.basicauth.login.title: "Log in to Supra Dashboard"
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

# ---- Install Supra Log Collector (offline: fluent-package + bundled gems) ----
# Replaces the old `gem install fluentd` path. fluent-package ships its own
# embedded Ruby at /opt/fluent so it never collides with system Ruby.
log "Installing Supra Log Collector (offline)..."

# Release-matched .deb set chosen by the OS check above ($DEB_SET).
DEB_DIR="$SCRIPT_DIR/log-collector/deb/$DEB_SET"
GEMS_DIR="$SCRIPT_DIR/log-collector/gems"
FLUENT_GEM="/opt/fluent/bin/fluent-gem"
FLUENTD_BIN="/opt/fluent/bin/fluentd"

if [ ! -d "$DEB_DIR" ] || ! ls "$DEB_DIR"/*.deb >/dev/null 2>&1; then
    err "  log-collector/deb/$DEB_SET is missing or empty. This bundle does not"
    err "  include a .deb set for Ubuntu $DEB_SET. Bundle is incomplete."
    exit 1
fi
# Note: log-collector/gems is now only a *fallback*. fluent-package already
# bundles a working fluent-plugin-opensearch stack, so an empty/absent gems dir
# is not fatal — see the plugin-verification step below.

# Verify every .deb is readable before we touch dpkg — a half-copied bundle
# would otherwise leave the system in a partially-configured state.
log "  Verifying bundled .deb integrity..."
bad=0
for d in "$DEB_DIR"/*.deb; do
    if ! dpkg-deb --contents "$d" >/dev/null 2>&1; then
        err "    Corrupt or truncated: $(basename "$d")"
        bad=1
    fi
done
if [ $bad -ne 0 ]; then
    err "  One or more .deb files are corrupted. Re-copy the installer bundle."
    exit 1
fi

# Purge any prior half-installed fluent-package so the fresh dpkg starts clean.
if dpkg-query -W -f='${Status}\n' fluent-package 2>/dev/null | grep -qE 'installed|unpacked|half'; then
    log "  Removing prior fluent-package state..."
    systemctl stop fluentd.service 2>/dev/null || true
    dpkg --purge --force-all fluent-package 2>&1 | tail -3 || true
fi

FLUENT_DEB=$(find "$DEB_DIR" -name "fluent-package_*.deb" | head -1)
if [ -z "$FLUENT_DEB" ]; then
    err "  fluent-package .deb not found in $DEB_DIR"
    exit 1
fi

# Install fluent-package together with its bundled, release-matched dependency
# libs WITHOUT downgrading anything the host already provides at a satisfactory
# version. We expose $DEB_DIR as a throwaway local apt repo and let apt resolve:
# on a normal host the deps are already present (apt installs only fluent-pkg);
# on a minimal host the bundled same-release libs satisfy them cleanly. This
# replaces the old `dpkg -i --force-downgrade`, which corrupted non-jammy hosts.
log "  Installing fluent-package (offline, release-matched deps)..."
SUPRA_APT_LIST="/etc/apt/sources.list.d/supra-fluent.list"
installed_via_apt=0
if command -v dpkg-scanpackages >/dev/null 2>&1; then
    ( cd "$DEB_DIR" && dpkg-scanpackages -m . > Packages 2>/dev/null && gzip -kf Packages )
    if [ -s "$DEB_DIR/Packages" ]; then
        echo "deb [trusted=yes] file:$DEB_DIR ./" > "$SUPRA_APT_LIST"
        # Update only our local list so we stay fully offline (no network repos).
        apt-get -o Dir::Etc::sourcelist="sources.list.d/supra-fluent.list" \
                -o Dir::Etc::sourceparts="-" \
                -o APT::Get::List-Cleanup="0" update >/dev/null 2>&1 || true
        if apt-get install -y --no-download fluent-package >/tmp/supra-fluent-apt.log 2>&1; then
            installed_via_apt=1
        else
            warn "  apt install path failed; see /tmp/supra-fluent-apt.log. Falling back to dpkg."
        fi
        rm -f "$SUPRA_APT_LIST"
        # Refresh apt's view so the throwaway repo leaves no trace.
        apt-get update >/dev/null 2>&1 || true
    fi
fi

# Fallback: install fluent-package together with its bundled deps in a SINGLE
# dpkg transaction. dpkg then orders configuration by dependency (e.g. it
# configures libtinfo6 before libncurses6, which depends on it). Installing the
# libs one-at-a-time — as we used to — leaves an intermediate dep unpacked but
# unconfigured, and fluent-package then refuses to configure with
# "libncurses6 is not configured yet". `dpkg --configure -a` settles anything
# left pending. The .deb set is release-matched, so this does not downgrade
# host libraries to foreign-release versions.
if [ "$installed_via_apt" -ne 1 ]; then
    log "  Installing via dpkg (single transaction; host already provides base libraries)..."
    if ! dpkg -i "$DEB_DIR"/*.deb >/tmp/supra-fluent-dpkg.log 2>&1; then
        warn "  dpkg reported issues; running 'dpkg --configure -a' to finish ordering..."
        dpkg --configure -a >>/tmp/supra-fluent-dpkg.log 2>&1 || true
        dpkg -i "$FLUENT_DEB" 2>&1 | tail -10 || true
    fi
fi

if [ ! -x "$FLUENTD_BIN" ] || [ ! -x "$FLUENT_GEM" ]; then
    err "  fluent-package install reported success but $FLUENTD_BIN is missing."
    exit 1
fi
"$FLUENTD_BIN" --version || true

# fluent-package 5.0.9 already ships a complete, internally-consistent stack:
# fluentd 1.16.x + fluent-plugin-opensearch + aws-sdk-core + jmespath + faraday
# + opensearch-ruby + fluent-plugin-s3, all mutually compatible. We use that
# stack EXACTLY as fluent-package ships it.
#
# We must NOT touch its gems. A previous version of this installer ran an
# "uninstall every version present in log-collector/gems/" cleanup loop to
# strip a supposed second, newer plugin set. But log-collector/gems/ also
# carries shared dependency gems (jmespath, base64, multi_json, aws-*, faraday*)
# at the SAME versions fluent-package bundles — so the loop uninstalled
# fluent-package's own jmespath-1.6.2. aws-sdk-core (required at dry-run time by
# both fluent-plugin-s3 and fluent-plugin-opensearch) then could not activate:
#   Could not find 'jmespath' (~> 1, >= 1.6.1) ... (Gem::MissingSpecError)
#   cannot load such file -- aws-sdk-core (LoadError)
# which aborted the dry-run and left the service uncreated. So: no uninstalls.
#
# The bundled gems remain ONLY as a fallback for the unlikely case a given
# fluent-package build ships without fluent-plugin-opensearch, or has an
# incomplete dependency closure (handled by the self-healing dry-run below).
log "  Verifying fluent-plugin-opensearch (bundled with fluent-package)..."
if "$FLUENT_GEM" list -i fluent-plugin-opensearch >/dev/null 2>&1; then
    log "  fluent-plugin-opensearch provided by fluent-package; using its stack as-is."
elif [ -d "$GEMS_DIR" ] && ls "$GEMS_DIR"/*.gem >/dev/null 2>&1; then
    warn "  fluent-plugin-opensearch not present in fluent-package; installing bundled gem closure..."
    # log-collector/gems/ is the COMPLETE dependency closure, so installing it
    # with --ignore-dependencies (offline, no remote fetch) leaves a consistent
    # set with every transitive dep — including jmespath — present.
    "$FLUENT_GEM" install --no-document --local --ignore-dependencies "$GEMS_DIR"/*.gem
else
    err "  fluent-plugin-opensearch is unavailable and no fallback gems were bundled."
    exit 1
fi

# fluent-package ships its own fluentd.service. Disable it so it can't race
# our supra-log-collector.service for ports 514 / 24224.
systemctl stop fluentd.service 2>/dev/null || true
systemctl disable fluentd.service 2>/dev/null || true

mkdir -p "$INSTALL_DIR/log-collector"
if [ -f "$SCRIPT_DIR/log-collector/fluent.conf" ]; then
    cp "$SCRIPT_DIR/log-collector/fluent.conf" "$INSTALL_DIR/log-collector/fluent.conf"
    log "  Packaged fluent.conf deployed."
else
    err "  Packaged fluent.conf missing — bundle is incomplete."
    exit 1
fi

# Dry-run the config so the install fails loud here, not after first boot.
# fluentd loads EVERY bundled plugin during a dry-run (s3, opensearch, ...), so
# a single missing transitive gem (e.g. jmespath behind aws-sdk-core) fails it.
# If that happens and we shipped the gem closure, install it to backfill the
# missing dep, then retry once before giving up.
log "  Verifying fluentd config..."
if ! "$FLUENTD_BIN" --dry-run -c "$INSTALL_DIR/log-collector/fluent.conf" >/tmp/fluentd-dryrun.log 2>&1; then
    if grep -qiE "MissingSpec|cannot load such file|Could not find|LoadError" /tmp/fluentd-dryrun.log \
       && [ -d "$GEMS_DIR" ] && ls "$GEMS_DIR"/*.gem >/dev/null 2>&1; then
        warn "  Dry-run hit a missing gem; backfilling from bundled gem closure and retrying..."
        "$FLUENT_GEM" install --no-document --local --ignore-dependencies "$GEMS_DIR"/*.gem \
            >/tmp/supra-gem-repair.log 2>&1 || true
    fi
    if ! "$FLUENTD_BIN" --dry-run -c "$INSTALL_DIR/log-collector/fluent.conf" >/tmp/fluentd-dryrun.log 2>&1; then
        err "  fluentd config dry-run failed:"
        cat /tmp/fluentd-dryrun.log
        exit 1
    fi
fi
log "  fluentd config verified."

# Free the syslog ports for the collector. fluent.conf binds 514/udp+tcp (IED
# syslog). On many hosts rsyslog already listens on :514 (imudp/imtcp), so the
# fluentd worker would die at first start with:
#   Errno::EADDRINUSE error="Address already in use - bind(2) for 0.0.0.0:514"
# This box is a dedicated Supra log collector, so fluentd must own :514. We
# disable ONLY rsyslog's *network* reception (imudp/imtcp + their listeners);
# local logging via /dev/log and journald is untouched. Reversible: each edited
# file is backed up to <file>.supra-bak and our changes are marked SUPRA-DISABLED.
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

# Ship THIS host's own logs into the SIEM. fluent.conf binds a dedicated Linux
# syslog source on :5140 (kept off :514 so the IED pipe-parser never touches
# generic Linux syslog), tagged "linux" -> supra-logs (source_type=linux).
# We forward over TCP with a disk-assisted queue so logs survive a collector
# restart and are never dropped. Reversible: the drop-in is a single file and
# any pre-existing copy is saved to <file>.supra-bak.
forward_local_syslog() {
    command -v rsyslogd >/dev/null 2>&1 || {
        warn "  rsyslog not installed; this host's local logs will NOT be forwarded to the collector."
        return 0
    }
    local dropin="/etc/rsyslog.d/60-supra-forward.conf"
    [ -f "$dropin" ] && [ ! -f "${dropin}.supra-bak" ] && cp -a "$dropin" "${dropin}.supra-bak"
    cat > "$dropin" <<'RSYSLOG_EOF'
# Supra SIEM — forward all local syslog to the Supra log collector (fluentd) on TCP 5140.
# TCP + disk-assisted queue so logs survive a collector restart and aren't dropped.
*.* action(type="omfwd"
           target="127.0.0.1" port="5140" protocol="tcp"
           action.resumeRetryCount="-1"
           queue.type="linkedList"
           queue.size="50000"
           queue.saveOnShutdown="on")
RSYSLOG_EOF
    if systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null; then
        log "  Local syslog now forwarded to the Supra collector on tcp/5140 (source_type=linux)."
    else
        warn "  Wrote $dropin but could not restart rsyslog; run 'sudo systemctl restart rsyslog'."
    fi
}
forward_local_syslog

chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/log-collector"
# World-readable so the supra service user can always read it (a later root edit
# that resets ownership won't lock the service out with Errno::EACCES).
chmod 0644 "$INSTALL_DIR/log-collector/fluent.conf"
log "  Supra Log Collector installed (fluent-package $(dpkg-query -W -f='${Version}' fluent-package))"

# ---- Install index template script ----
# Applied automatically by supra-index-template.service once supra-search
# becomes healthy (the unit waits on :9200 before PUT-ing the template).
log "Installing index template script..."
mkdir -p "$INSTALL_DIR/index-template"
cp "$SCRIPT_DIR/index-template/supra-index-template.sh" "$INSTALL_DIR/index-template/"
chmod +x "$INSTALL_DIR/index-template/supra-index-template.sh"
chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/index-template"

# ---- Install systemd services ----
log "Installing systemd services..."
cp "$SCRIPT_DIR/systemd/supra-search.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/supra-dashboards.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/supra-log-collector.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/supra-index-template.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable supra-search.service
systemctl enable supra-dashboards.service
systemctl enable supra-log-collector.service
systemctl enable supra-index-template.service
log "  Systemd services installed and enabled."

echo ""
echo "============================================"
echo "  Installation Complete!"
echo "============================================"
echo ""
echo "IMPORTANT: License activation required before starting services."
echo ""
echo "Step 1: Get this machine's fingerprint:"
echo "  sudo bash $INSTALL_DIR/opensearch/config/supra-license/get-fingerprint.sh"
echo ""
echo "Step 2: Send the fingerprint (MFP) to your Supra vendor to receive a license.key file."
echo ""
echo "Step 3: Place the license file:"
echo "  sudo cp license.key $INSTALL_DIR/opensearch/config/supra-license/"
echo "  sudo chown $SUPRA_USER:$SUPRA_GROUP $INSTALL_DIR/opensearch/config/supra-license/license.key"
echo "  sudo chmod 600 $INSTALL_DIR/opensearch/config/supra-license/license.key"
echo ""
echo "Step 4: Start services:"
echo "  sudo systemctl start supra-search"
echo "  # supra-index-template runs automatically once supra-search is healthy."
echo "  sudo systemctl start supra-dashboards"
echo "  sudo systemctl start supra-log-collector"
echo ""
echo "Services:"
echo "  Supra Search Engine:   https://localhost:9200"
echo "  Supra Dashboards:      http://localhost:5601"
echo "  Supra Log Collector:   UDP/514 (syslog), TCP/24224 (forward)"
echo ""
echo "Credentials:"
echo "  Username: admin"
echo "  Password: admin"
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
echo "  journalctl -u supra-index-template"
echo ""
echo "Install directory: $INSTALL_DIR"
echo ""
