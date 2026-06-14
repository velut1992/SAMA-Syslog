#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "Stopping services..."
systemctl stop supra-dashboards.service 2>/dev/null || true
systemctl stop supra-log-collector.service 2>/dev/null || true
systemctl stop supra-index-template.service 2>/dev/null || true
systemctl stop supra-search.service 2>/dev/null || true
systemctl stop fluentd.service 2>/dev/null || true

echo "Disabling services..."
systemctl disable supra-search.service 2>/dev/null || true
systemctl disable supra-dashboards.service 2>/dev/null || true
systemctl disable supra-log-collector.service 2>/dev/null || true
systemctl disable supra-index-template.service 2>/dev/null || true

echo "Removing service files..."
rm -f /etc/systemd/system/supra-search.service
rm -f /etc/systemd/system/supra-dashboards.service
rm -f /etc/systemd/system/supra-log-collector.service
rm -f /etc/systemd/system/supra-index-template.service
systemctl daemon-reload

echo "Removing fluent-package..."
if dpkg-query -W -f='${Status}\n' fluent-package 2>/dev/null | grep -q installed; then
    dpkg --purge --force-all fluent-package 2>&1 | tail -3 || true
fi

echo "Removing rsyslog forward to collector..."
if [ -f /etc/rsyslog.d/60-supra-forward.conf ]; then
    if [ -f /etc/rsyslog.d/60-supra-forward.conf.supra-bak ]; then
        mv -f /etc/rsyslog.d/60-supra-forward.conf.supra-bak /etc/rsyslog.d/60-supra-forward.conf
    else
        rm -f /etc/rsyslog.d/60-supra-forward.conf
    fi
    systemctl restart rsyslog 2>/dev/null || true
fi

echo "Removing installation directory..."
rm -rf /opt/supra

echo "Removing sysctl config..."
rm -f /etc/sysctl.d/99-supra.conf
sysctl --system > /dev/null 2>&1

echo ""
echo "Supra stack uninstalled."
echo "Note: The 'supra' user was not removed. To remove: sudo userdel -r supra"
echo "Note: jammy dependency libs (libssl3, libffi8, etc.) installed by the"
echo "      bundled .debs were left in place — they are standard Ubuntu libs."
