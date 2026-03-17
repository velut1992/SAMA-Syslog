#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Full Stack Setup: Supra Search Engine"
echo "  + Supra Log Collector"
echo "  + Supra Dashboards (from source)"
echo "============================================"
echo ""

echo "[1/3] Setting up Supra Search Engine..."
bash "$SCRIPT_DIR/setup-opensearch.sh"
echo ""

echo "[2/3] Setting up Supra Log Collector..."
bash "$SCRIPT_DIR/setup-log-collector.sh"
echo ""

echo "[3/3] Setting up Supra Dashboards..."
bash "$SCRIPT_DIR/setup-dashboards.sh"
echo ""

echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "Services:"
echo "  Supra Search Engine:   https://localhost:9200"
echo "  Supra Dashboards:      http://localhost:5601"
echo "  Supra Log Collector:   localhost:5140 (syslog), localhost:24224 (forward)"
echo ""
echo "Start all services:"
echo "  sudo systemctl start supra-search"
echo "  sudo systemctl start supra-log-collector"
echo "  sudo systemctl start supra-dashboards"
