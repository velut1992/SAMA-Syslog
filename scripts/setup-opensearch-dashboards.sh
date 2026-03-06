#!/bin/bash
set -e

BASE_DIR="/home/velu/Hitachi"
DASHBOARDS_DIR="$BASE_DIR/OpenSearch-Dashboards"

echo "=== OpenSearch Dashboards Setup (Build from Source) ==="
echo "Repository: https://github.com/opensearch-project/OpenSearch-Dashboards"

# Step 1: Setup Node.js via nvm
echo "Setting up Node.js..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

cd "$DASHBOARDS_DIR"
REQUIRED_NODE=$(cat .nvmrc)
echo "Required Node.js version: $REQUIRED_NODE"

nvm install "$REQUIRED_NODE"
nvm use "$REQUIRED_NODE"

# Step 2: Install yarn via corepack
echo "Installing yarn via corepack..."
npm i -g corepack
corepack install

# Step 3: Bootstrap OpenSearch Dashboards
echo "Bootstrapping OpenSearch Dashboards (this may take a while)..."
yarn osd bootstrap

# Step 4: Create systemd service file (user must install with sudo)
NODE_PATH=$(which node)
cat > "$BASE_DIR/config/systemd/opensearch-dashboards.service" <<EOF
[Unit]
Description=OpenSearch Dashboards (built from source)
After=network.target opensearch.service

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$DASHBOARDS_DIR
ExecStart=$NODE_PATH scripts/opensearch_dashboards --dev
Restart=on-failure
Environment=NODE_OPTIONS=--max-old-space-size=4096

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "OpenSearch Dashboards bootstrapped at: $DASHBOARDS_DIR"
echo ""
echo "To start in dev mode:"
echo "  cd $DASHBOARDS_DIR"
echo "  yarn start"
echo ""
echo "To install systemd service (requires sudo):"
echo "  sudo cp $BASE_DIR/config/systemd/opensearch-dashboards.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now opensearch-dashboards"
echo ""
echo "Access at: http://localhost:5601"
