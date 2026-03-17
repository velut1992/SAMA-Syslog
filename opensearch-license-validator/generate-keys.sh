#!/bin/bash
set -e

# Generate RSA-2048 keypair for Supra license signing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/keys"

mkdir -p "$KEYS_DIR"

echo "Generating RSA-2048 keypair..."

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEYS_DIR/private.key" 2>/dev/null
openssl rsa -pubout -in "$KEYS_DIR/private.key" -out "$KEYS_DIR/public.key" 2>/dev/null

echo "Keys generated:"
echo "  Private key: $KEYS_DIR/private.key"
echo "  Public key:  $KEYS_DIR/public.key"
echo ""
echo "IMPORTANT: Keep private.key secure. Only distribute public.key with installers."
