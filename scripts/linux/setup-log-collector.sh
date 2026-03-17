#!/bin/bash
set -e

BASE_DIR="$(dirname "$(dirname "$(cd "$(dirname "$0")" && pwd)")")"
FLUENTD_BIN="$HOME/.local/share/gem/ruby/3.0.0/bin/fluentd"

echo "=== Supra Log Collector Setup ==="

# Step 1: Install runtime and plugins via gem (user-level)
echo "Installing Supra Log Collector runtime..."
gem install fluentd --user-install
gem install fluent-plugin-opensearch fluent-plugin-syslog --user-install

# Step 2: Verify installation
echo "Verifying installation..."
$FLUENTD_BIN --version

# Step 3: Generate systemd service file
mkdir -p "$BASE_DIR/config/systemd"
cat > "$BASE_DIR/config/systemd/supra-log-collector.service" <<EOF
[Unit]
Description=Supra Log Collector
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
echo "Supra Log Collector installed successfully!"
echo "Binary: $FLUENTD_BIN"
echo "Config: $BASE_DIR/fluent/fluent.conf"
echo ""
echo "To start manually:"
echo "  $FLUENTD_BIN -c $BASE_DIR/fluent/fluent.conf"
echo ""
echo "To install systemd service (requires sudo):"
echo "  sudo cp $BASE_DIR/config/systemd/supra-log-collector.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now supra-log-collector"
