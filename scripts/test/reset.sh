#!/bin/bash
# reset.sh — return a host to a "fresh system" state so the Supra installer can
# be tested as if on a clean Ubuntu LTS. Removes BOTH legacy artifacts
# (opensearch*/fluentd units, gem-based fluentd, fluentd-apt-source) AND any
# 3.6.0-style artifacts (supra-* units, /opt/supra, supra user, sysctl drop-in).
# Idempotent; safe to re-run. Run as root.
set -u
[ "$EUID" -ne 0 ] && { echo "ERROR: run as root (sudo bash $0)"; exit 1; }
say(){ echo -e "\n=== $* ==="; }

ALL_UNITS="opensearch opensearch-dashboards opensearch-performance-analyzer \
supra-search supra-dashboards supra-log-collector supra-index-template fluentd"

say "1/8 Stop + disable all known units"
for u in $ALL_UNITS; do
  systemctl stop "$u.service"    2>/dev/null && echo "  stopped  $u" || true
  systemctl disable "$u.service" 2>/dev/null && echo "  disabled $u" || true
done

say "2/8 Kill leftover orphan processes"
pkill -u supra 2>/dev/null && echo "  killed supra-user procs" || true
pkill -f '/opt/supra' 2>/dev/null || true
pkill -f 'bin/fluentd' 2>/dev/null || true
sleep 2
pkill -9 -u supra 2>/dev/null || true
pkill -9 -f '/opt/supra' 2>/dev/null || true

say "3/8 Remove systemd unit files (+ drop-ins) + reload"
for u in $ALL_UNITS; do rm -f "/etc/systemd/system/$u.service"; rm -rf "/etc/systemd/system/$u.service.d"; done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

say "4/8 Remove install directory /opt/supra"
rm -rf /opt/supra && echo "  removed /opt/supra"

say "5/8 Remove fluent-package (/opt/fluent) and any gem-based fluentd"
if dpkg-query -W -f='${Status}\n' fluent-package 2>/dev/null | grep -q installed; then
  dpkg --purge --force-all fluent-package 2>&1 | tail -2 && echo "  purged fluent-package" || true
fi
rm -rf /opt/fluent 2>/dev/null || true
if command -v gem >/dev/null 2>&1; then
  for g in $(gem list 2>/dev/null | grep -iE '^fluent' | awk '{print $1}'); do
    gem uninstall -aIx "$g" 2>/dev/null && echo "  gem removed $g" || true
  done
fi
rm -f /usr/local/bin/fluentd /usr/local/bin/fluent-* 2>/dev/null || true

say "6/8 Purge apt sources (legacy fluentd-apt-source + 3.6.0 supra-fluent)"
if dpkg-query -W -f='${Status}\n' fluentd-apt-source 2>/dev/null | grep -q installed; then
  dpkg --purge --force-all fluentd-apt-source 2>&1 | tail -2 && echo "  purged fluentd-apt-source" || true
fi
rm -f /etc/apt/sources.list.d/fluentd.sources \
      /etc/apt/sources.list.d/supra-fluent.list \
      /usr/share/keyrings/fluentd-archive-keyring.gpg 2>/dev/null || true

say "7/8 Remove sysctl drop-in + supra user/group"
rm -f /etc/sysctl.d/99-supra.conf && sysctl --system >/dev/null 2>&1 && echo "  removed 99-supra.conf"
id supra >/dev/null 2>&1 && { userdel supra 2>/dev/null && echo "  deleted user supra" || echo "  WARN userdel failed"; }
getent group supra >/dev/null 2>&1 && groupdel supra 2>/dev/null && echo "  deleted group supra" || true

say "8/8 Restore any rsyslog *.supra-bak backups"
shopt -s nullglob
for b in /etc/rsyslog.conf.supra-bak /etc/rsyslog.d/*.conf.supra-bak; do
  mv -f "$b" "${b%.supra-bak}" && echo "  restored ${b%.supra-bak}"
done
systemctl restart rsyslog 2>/dev/null || true

echo -e "\n--- Fresh-state verification ---"
echo "units:";   ls /etc/systemd/system/ | grep -iE 'supra|opensearch|fluent' || echo "  none"
echo "/opt/supra:"; [ -e /opt/supra ] && echo "  STILL EXISTS" || echo "  gone"
echo "/opt/fluent:"; [ -e /opt/fluent ] && echo "  STILL EXISTS" || echo "  gone"
echo "fluentd on PATH:"; command -v fluentd 2>/dev/null || echo "  gone"
echo "supra user:"; id supra 2>/dev/null || echo "  gone"
echo "ports:"; (ss -tulnp 2>/dev/null | grep -E ':9200|:5601|:24224|:514\b') || echo "  none"
echo -e "\nDONE — host reset for a fresh offline install test."
