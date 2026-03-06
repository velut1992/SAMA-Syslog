#!/bin/bash
set -e

BASE_DIR="/home/velu/Hitachi"
FLUENTD_BIN="/home/velu/.local/share/gem/ruby/3.0.0/bin/fluentd"

echo "=== Fluentd Setup (gem install) ==="

# Step 1: Install Fluentd and plugins via gem (user-level)
echo "Installing Fluentd..."
gem install fluentd --user-install
gem install fluent-plugin-opensearch fluent-plugin-syslog --user-install

# Step 2: Verify installation
echo "Verifying Fluentd..."
$FLUENTD_BIN --version

# Step 3: Generate systemd service file
cat > "$BASE_DIR/config/systemd/fluentd.service" <<EOF
[Unit]
Description=Fluentd log collector
After=network.target

[Service]
Type=simple
ExecStart=$FLUENTD_BIN -c $BASE_DIR/fluent/fluent.conf
Restart=always
User=$(whoami)
Group=$(id -gn)
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "Fluentd installed successfully!"
echo "Binary: $FLUENTD_BIN"
echo "Config: $BASE_DIR/fluent/fluent.conf"
echo ""
echo "To start manually:"
echo "  $FLUENTD_BIN -c $BASE_DIR/fluent/fluent.conf"
echo ""
echo "To install systemd service (requires sudo):"
echo "  sudo cp $BASE_DIR/config/systemd/fluentd.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now fluentd"
