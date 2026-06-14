#!/bin/bash
# provision-license.sh — generate a VALID license.key and install it so the
# runtime tier can start the licensed services. Mirrors the real activation flow:
#   1. MFP = the installed get-fingerprint.sh, run as ROOT (reads real DMI) — the
#      authoritative value the plugin reads from the root-written machine-id cache.
#   2. sign a license payload for that MFP with the RSA private key that pairs
#      with the installer's deployed public.key (LicenseGenerator --create-license).
#   3. drop license.key into the supra-license dir.
#
# Assets needed (--assets DIR): LicenseGenerator.java + keys/private.key.
# Usage: provision-license.sh --assets DIR [--license-dir DIR]
#                             [--customer NAME] [--expiry YYYY-MM-DD]
set -u
LICENSE_DIR="/opt/supra/opensearch/config/supra-license"
ASSETS=""; CUSTOMER="Supra QA Harness"; EXPIRY="2035-12-31"
while [ $# -gt 0 ]; do case "$1" in
  --assets) ASSETS="$2"; shift;;
  --license-dir) LICENSE_DIR="$2"; shift;;
  --customer) CUSTOMER="$2"; shift;;
  --expiry) EXPIRY="$2"; shift;;
  *) echo "ERROR: unknown arg $1" >&2; exit 2;;
esac; shift; done
[ -n "$ASSETS" ] || { echo "ERROR: --assets DIR required" >&2; exit 2; }

GEN_SRC="$(find "$ASSETS" -name LicenseGenerator.java | head -1)"
PRIV="$(find "$ASSETS" -path '*keys*' -name private.key | head -1)"; [ -n "$PRIV" ] || PRIV="$(find "$ASSETS" -name private.key | head -1)"
[ -f "$GEN_SRC" ] || { echo "ERROR: LicenseGenerator.java not found under $ASSETS" >&2; exit 2; }
[ -f "$PRIV" ]    || { echo "ERROR: private.key not found under $ASSETS" >&2; exit 2; }

if [ -x /opt/supra/opensearch/jdk/bin/javac ]; then JAVAC=/opt/supra/opensearch/jdk/bin/javac; JAVA=/opt/supra/opensearch/jdk/bin/java
elif command -v javac >/dev/null 2>&1; then JAVAC="$(command -v javac)"; JAVA="$(command -v java)"
else echo "ERROR: no JDK (javac) available" >&2; exit 3; fi

# 1. fingerprint — exactly as a real operator obtains it: get-fingerprint.sh as root.
FP_SH="$LICENSE_DIR/get-fingerprint.sh"
[ -f "$FP_SH" ] || { echo "ERROR: $FP_SH not present (install incomplete?)" >&2; exit 4; }
MFP="$(bash "$FP_SH" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -1)"
[ -n "$MFP" ] || { echo "ERROR: could not compute fingerprint via get-fingerprint.sh" >&2; exit 4; }
echo "  fingerprint (get-fingerprint.sh as root): $MFP"

# 2. sign
TMP="$(mktemp -d)"; chmod 755 "$TMP"; trap 'rm -rf "$TMP"' EXIT
cp "$GEN_SRC" "$TMP/" && ( cd "$TMP" && "$JAVAC" LicenseGenerator.java ) || { echo "ERROR: compile failed" >&2; exit 5; }
( cd "$TMP" && "$JAVA" LicenseGenerator --create-license \
    --fingerprint "$MFP" --customer "$CUSTOMER" --expiry "$EXPIRY" \
    --private-key "$PRIV" --tier enterprise --max-nodes 3 \
    --output "$TMP/license.key" ) || { echo "ERROR: license generation failed" >&2; exit 5; }

# 3. install
cp "$TMP/license.key" "$LICENSE_DIR/license.key"
chown supra:supra "$LICENSE_DIR/license.key" 2>/dev/null || true
chmod 600 "$LICENSE_DIR/license.key"
echo "  license.key installed -> $LICENSE_DIR/license.key (expiry $EXPIRY)"
