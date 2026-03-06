#!/bin/bash
set -e

PLUGIN_DIR="/home/velu/Hitachi/opensearch-license-validator/license-validator"

echo "=== Building OpenSearch License Validator Plugin ==="

# Step 1: Build with Maven
cd "$PLUGIN_DIR"
mvn clean install

# Step 2: Create plugin zip
echo "Creating plugin zip..."
cd target
rm -rf plugin-tmp
mkdir plugin-tmp
cp license-validator-1.0.0.jar plugin-tmp/
cp ../plugin-descriptor.properties plugin-tmp/
cd plugin-tmp
zip -r ../license-validator-1.0.0.zip *

echo ""
echo "Plugin built successfully!"
echo "Plugin zip: $PLUGIN_DIR/target/license-validator-1.0.0.zip"
echo ""
echo "To install the plugin:"
echo "  sudo /usr/share/opensearch/bin/opensearch-plugin install file://$PLUGIN_DIR/target/license-validator-1.0.0.zip --verbose"
echo ""
echo "To uninstall the plugin:"
echo "  /usr/share/opensearch/bin/opensearch-plugin remove 'License Validator'"
echo ""
echo "To list installed plugins:"
echo "  /usr/share/opensearch/bin/opensearch-plugin list"
