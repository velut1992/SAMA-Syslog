#!/bin/bash
set -e
################################################################################
# Supra Log Collector — port-514 / rsyslog conflict patch  (self-contained)
#
# Fixes everything seen in the field report (Consd Terminal Details.txt) WITHOUT
# reinstalling anything — fluent-package is already installed on the box:
#
#   1. supra-log-collector worker crash-loops with
#         Errno::EADDRINUSE error="Address already in use - bind(2) for 0.0.0.0:514"
#      because the host's rsyslog already owns :514 (imudp/imtcp). This box is a
#      dedicated Supra collector, so fluentd must own :514. We disable ONLY
#      rsyslog's *network* reception; local logging (/dev/log, journald) is kept.
#
#   2. Errno::EACCES reading fluent.conf (a `sudo nano` edit reset its ownership
#      so the `supra` service user could no longer read it). We restore a clean
#      config owned supra:supra and world-readable (0644).
#
#   3. Leftover experimental rsyslog drop-ins from manual troubleshooting
#      (30-fluentd-forwarding.conf / 60-fluentd.conf) are set aside.
#
# Safe, idempotent, reversible. Copy this one file to the target machine and:
#   sudo bash supra-514-patch.sh
################################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Run as root:  sudo bash supra-514-patch.sh"
    exit 1
fi

INSTALL_DIR="/opt/supra"
CONF="$INSTALL_DIR/log-collector/fluent.conf"
FLUENTD_BIN="/opt/fluent/bin/fluentd"
SUPRA_USER="supra"
SUPRA_GROUP="supra"

echo ""
echo "============================================"
echo "  Supra Log Collector — :514 conflict patch"
echo "============================================"
echo ""

if [ ! -x "$FLUENTD_BIN" ]; then
    err "fluent-package is not installed ($FLUENTD_BIN missing)."
    err "Run the full installer first, then apply this patch."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Free port 514 from rsyslog (disable network reception only; reversible)
# ---------------------------------------------------------------------------
log "Step 1: Ensuring port 514 is free for the collector (rsyslog check)..."
free_syslog_ports() {
    command -v rsyslogd >/dev/null 2>&1 || { log "  rsyslog not installed; :514 is free."; return 0; }

    local files=() f
    [ -f /etc/rsyslog.conf ] && files+=("/etc/rsyslog.conf")
    for f in /etc/rsyslog.d/*.conf; do [ -f "$f" ] && files+=("$f"); done
    [ "${#files[@]}" -gt 0 ] || return 0

    # These tokens only appear on input/module lines, never on forwarding
    # actions (@host / @@host) — so rsyslog forwarding rules are left intact.
    local net_re='^[[:space:]]*(module\(load="im(udp|tcp)"\)|input\(type="im(udp|tcp)"|\$ModLoad[[:space:]]+im(udp|tcp)|\$UDPServerRun|\$InputTCPServerRun)'
    if ! grep -Eq "$net_re" "${files[@]}" 2>/dev/null; then
        log "  rsyslog is not receiving network syslog; :514 already free."
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

# ---------------------------------------------------------------------------
# 2. Set aside the manual troubleshooting drop-ins (if present)
# ---------------------------------------------------------------------------
log "Step 2: Setting aside leftover experimental rsyslog drop-ins..."
moved=0
for leftover in /etc/rsyslog.d/30-fluentd-forwarding.conf /etc/rsyslog.d/60-fluentd.conf; do
    if [ -f "$leftover" ]; then
        mv -f "$leftover" "${leftover}.supra-disabled"
        log "  Disabled $leftover (renamed to .supra-disabled)."
        moved=1
    fi
done
if [ "$moved" -eq 1 ]; then
    systemctl restart rsyslog 2>/dev/null || true
else
    log "  None found; nothing to set aside."
fi

# ---------------------------------------------------------------------------
# 3. Restore a clean, correct fluent.conf (fixes the EACCES from manual edits)
# ---------------------------------------------------------------------------
log "Step 3: Restoring a clean fluent.conf..."
mkdir -p "$INSTALL_DIR/log-collector"
if [ -f "$CONF" ]; then
    cp -a "$CONF" "${CONF}.supra-bak.$(date +%s 2>/dev/null || echo prev)" 2>/dev/null || true
fi
cat > "$CONF" <<'FLUENTCONF'
## Supra Log Collector Configuration (Fluentd)
##
## Collects logs from: IEDs, Switches, Routers, Firewalls,
##                     Windows Workstations/Servers, Linux Servers
##
## Ports:
##    514/UDP+TCP  - IED syslog (timestamps in UTC)
##   1514/UDP      - Windows NXLog agents (JSON format, IST)
##   2514/UDP+TCP  - Network devices: switches, routers, firewalls (timestamps in IST)
##  24224/TCP      - Fluentd forward input (from Fluentd agents)
##
## Port Assignment Guide:
##   IEDs (ABB REC670, REL670, etc.)     → configure syslog to port 514
##   Siemens Ruggedcom switches           → configure syslog to port 2514
##   Routers / Firewalls                  → configure syslog to port 2514
##   Windows servers (NXLog)              → configure NXLog to port 1514
##   Linux servers (rsyslog)              → configure rsyslog to port 514

# ============================================================
#  SYSTEM
# ============================================================
<system>
  log_level info
</system>

# ============================================================
#  INPUT: IEDs (Port 514) — timestamps in UTC
# ============================================================
<source>
  @type syslog
  port 514
  bind 0.0.0.0
  tag ied
  protocol_type udp
  @log_level info
  <parse>
    message_format auto
    timezone +00:00
  </parse>
</source>

<source>
  @type syslog
  port 514
  bind 0.0.0.0
  tag ied
  protocol_type tcp
  @log_level info
  <parse>
    message_format auto
    timezone +00:00
  </parse>
</source>

# ============================================================
#  INPUT: Windows NXLog Agents (Port 1514) — JSON format, IST
# ============================================================
<source>
  @type udp
  port 1514
  bind 0.0.0.0
  tag windows
  @log_level info
  <parse>
    @type json
    time_key EventTime
    time_format %Y-%m-%d %H:%M:%S
    timezone +05:30
    keep_time_key true
  </parse>
</source>

# ============================================================
#  INPUT: Network Devices (Port 2514) — timestamps in IST
#  Siemens Ruggedcom switches, routers, firewalls
# ============================================================
<source>
  @type syslog
  port 2514
  bind 0.0.0.0
  tag network
  protocol_type udp
  @log_level info
  <parse>
    message_format auto
    timezone +05:30
  </parse>
</source>

<source>
  @type syslog
  port 2514
  bind 0.0.0.0
  tag network
  protocol_type tcp
  @log_level info
  <parse>
    message_format auto
    timezone +05:30
  </parse>
</source>

# ============================================================
#  INPUT: Fluentd Forward (Port 24224)
# ============================================================
<source>
  @type forward
  port 24224
  bind 0.0.0.0
  @log_level info
</source>

# ============================================================
#  ENRICHMENT
# ============================================================

# Tag IED logs with source type
<filter ied.**>
  @type record_transformer
  <record>
    log_collector "supra"
    source_type "ied"
  </record>
</filter>

# Tag Windows logs with source type
<filter windows>
  @type record_transformer
  <record>
    log_collector "supra"
    source_type "windows"
  </record>
</filter>

# Tag network device logs with source type
<filter network.**>
  @type record_transformer
  <record>
    log_collector "supra"
    source_type "network"
  </record>
</filter>

# ============================================================
#  OUTPUT — All logs to OpenSearch
# ============================================================
<match **>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix supra-logs
  include_tag_key true
  tag_key fluentd_tag
  flush_interval 5s
  @log_level info
  <buffer>
    @type memory
    flush_mode interval
    flush_interval 5s
    retry_max_interval 30s
    retry_forever true
    chunk_limit_size 4MB
    queue_limit_length 64
  </buffer>
</match>
FLUENTCONF

# Make sure the service user can always read it.
if ! getent group "$SUPRA_GROUP" >/dev/null; then groupadd --system "$SUPRA_GROUP"; fi
if ! id -u "$SUPRA_USER" >/dev/null 2>&1; then
    useradd --system --gid "$SUPRA_GROUP" --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SUPRA_USER"
fi
chown -R "$SUPRA_USER:$SUPRA_GROUP" "$INSTALL_DIR/log-collector"
chmod 0644 "$CONF"
log "  Clean fluent.conf restored (owner supra:supra, mode 0644)."

# ---------------------------------------------------------------------------
# 4. Ensure the systemd unit is correct (can bind :514 as the supra user)
# ---------------------------------------------------------------------------
log "Step 4: Ensuring supra-log-collector.service is correct..."
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
systemctl stop fluentd.service 2>/dev/null || true
systemctl disable fluentd.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable supra-log-collector.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. Verify config, then start and confirm it owns :514
# ---------------------------------------------------------------------------
log "Step 5: Verifying config (dry-run)..."
if ! "$FLUENTD_BIN" --dry-run -c "$CONF" >/tmp/fluentd-dryrun.log 2>&1; then
    err "  fluentd dry-run failed:"
    cat /tmp/fluentd-dryrun.log
    exit 1
fi
log "  Config OK."

log "  Restarting supra-log-collector..."
systemctl restart supra-log-collector
sleep 4

if systemctl is-active --quiet supra-log-collector; then
    log "  supra-log-collector is RUNNING."
else
    err "  supra-log-collector failed to start. Recent journal:"
    journalctl -u supra-log-collector --no-pager -n 30
    exit 1
fi

echo ""
echo "Listeners now on the syslog ports:"
ss -tulpn 2>/dev/null | grep -E ':514|:1514|:2514|:24224' || true

echo ""
echo "============================================"
echo "  Patch complete — collector owns :514"
echo "============================================"
echo ""
echo "  Verify:   sudo ss -tulpn | grep ':514'   # should show fluentd/ruby"
echo "  Logs:     journalctl -u supra-log-collector -f"
echo ""
echo "  To revert rsyslog changes (if ever needed):"
echo "    sudo cp /etc/rsyslog.conf.supra-bak /etc/rsyslog.conf && sudo systemctl restart rsyslog"
echo ""
