#!/bin/bash
set -e

GENERATOR_DIR="/home/velu/Hitachi/opensearch-license-validator/license-generator"

echo "=== Generating OpenSearch License Key ==="

cd "$GENERATOR_DIR"

# Compile
echo "Compiling LicenseGenerator..."
javac LicenseGenerator.java

# Run and capture output
echo "Generating license key..."
java LicenseGenerator

echo ""
echo "Copy the 'Encrypted License Key' value above and save it to:"
echo "  /etc/opensearch/license.key"
echo ""
echo "Example:"
echo "  echo '<ENCRYPTED_KEY>' | sudo tee /etc/opensearch/license.key"
