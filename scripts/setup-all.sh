#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================"
echo "  Full Stack Setup: OpenSearch + Fluentd"
echo "  + OpenSearch Dashboards (from source)"
echo "============================================"
echo ""

echo "[1/3] Setting up OpenSearch..."
bash "$SCRIPT_DIR/setup-opensearch.sh"
echo ""

echo "[2/3] Setting up Fluentd..."
bash "$SCRIPT_DIR/setup-fluentd.sh"
echo ""

echo "[3/3] Setting up OpenSearch Dashboards..."
bash "$SCRIPT_DIR/setup-opensearch-dashboards.sh"
echo ""

echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "Services:"
echo "  OpenSearch:            https://localhost:9200"
echo "  OpenSearch Dashboards: http://localhost:5601"
echo "  Fluentd syslog input:  localhost:5140"
echo "  Fluentd forward input: localhost:24224"
echo ""
echo "Start all services:"
echo "  sudo systemctl start opensearch"
echo "  sudo systemctl start fluentd"
echo "  sudo systemctl start opensearch-dashboards"
