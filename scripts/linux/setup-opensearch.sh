#!/bin/bash
set -e

BASE_DIR="$(dirname "$(dirname "$(cd "$(dirname "$0")" && pwd)")")"
OPENSEARCH_DIR="$BASE_DIR/OpenSearch"

echo "=== Supra Search Engine Setup (Build from Source) ==="

# Step 1: Verify prerequisites
echo "Checking prerequisites..."
if ! java -version 2>&1 | grep -q "17\|21\|24"; then
    echo "ERROR: JDK 17+ is required. Install with: sudo apt install openjdk-17-jdk"
    exit 1
fi

export SDKMAN_DIR="$HOME/.sdkman"
if [ -f "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
    source "$SDKMAN_DIR/bin/sdkman-init.sh"
    export JAVA_HOME=$(sdk home java 21.0.6-tem)
fi
echo "Using JAVA_HOME=$JAVA_HOME"

# Step 2: Build
echo "Building Supra Search Engine (this may take a while)..."
cd "$OPENSEARCH_DIR"
./gradlew :distribution:archives:linux-tar:assemble -Dbuild.snapshot=false

# Step 3: Locate the distribution tarball
DIST_TAR=$(find "$OPENSEARCH_DIR/distribution/archives/linux-tar/build/distributions" -name "opensearch-*.tar.gz" | head -1)
if [ -z "$DIST_TAR" ]; then
    echo "ERROR: Build output not found. Check build logs."
    exit 1
fi
echo "Built distribution: $DIST_TAR"

# Step 4: Extract to install location
INSTALL_DIR="$BASE_DIR/opensearch-dist"
echo "Extracting to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$DIST_TAR" -C "$INSTALL_DIR" --strip-components=1

# Step 5: Create systemd service file
mkdir -p "$BASE_DIR/config/systemd"
cat > "$BASE_DIR/config/systemd/supra-search.service" <<EOF
[Unit]
Description=Supra Search Engine
After=network.target

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
ExecStart=$INSTALL_DIR/bin/opensearch
Restart=on-failure
LimitNOFILE=65535
LimitMEMLOCK=infinity
Environment=JAVA_HOME=$JAVA_HOME
Environment=OPENSEARCH_HOME=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "Supra Search Engine built and installed to: $INSTALL_DIR"
echo ""
echo "To start:"
echo "  $INSTALL_DIR/bin/opensearch"
echo ""
echo "To install systemd service (requires sudo):"
echo "  sudo cp $BASE_DIR/config/systemd/supra-search.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now supra-search"
echo ""
echo "Verify with:"
echo "  curl -k -u admin:admin https://localhost:9200"
