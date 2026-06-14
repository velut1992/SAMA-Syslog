#!/bin/bash
set -e

# Supra Machine Fingerprint Generator (Linux)
# Produces the same fingerprint as MachineFingerprint.java

get_value() {
    local file="$1"
    local cmd="$2"

    if [ -n "$file" ] && [ -f "$file" ]; then
        cat "$file" 2>/dev/null | tr -d '[:space:]'
    elif [ -n "$cmd" ]; then
        eval "$cmd" 2>/dev/null | head -1 | tr -d '[:space:]'
    else
        echo "UNKNOWN"
    fi
}

CPU_ID=$(get_value "/sys/class/dmi/id/product_uuid" "")
BOARD_SERIAL=$(get_value "/sys/class/dmi/id/board_serial" "")
DISK_SERIAL=$(get_value "" "lsblk -ndo SERIAL 2>/dev/null | head -1")

[ -z "$CPU_ID" ] && CPU_ID="UNKNOWN"
[ -z "$BOARD_SERIAL" ] && BOARD_SERIAL="UNKNOWN"
[ -z "$DISK_SERIAL" ] && DISK_SERIAL="UNKNOWN"

RAW="${CPU_ID}|${BOARD_SERIAL}|${DISK_SERIAL}"
FINGERPRINT=$(echo -n "$RAW" | sha256sum | awk '{print $1}')

# Optionally cache the fingerprint for the license-validator plugin. OpenSearch
# runs as a non-root user that cannot read the root-only DMI files, so it relies
# on this root-written cache (see MachineFingerprint.generate(Path)). The
# supra-search.service ExecStartPre invokes this script with MACHINE_ID_FILE set.
if [ -n "${MACHINE_ID_FILE:-}" ]; then
    if printf '%s\n' "$FINGERPRINT" > "$MACHINE_ID_FILE" 2>/dev/null; then
        # Match the license dir's owner (the OpenSearch run-as user) so the
        # plugin can read it, and keep 0600 to satisfy OpenSearch Security's
        # config-file permission check. (Runs as root via the service ExecStartPre.)
        chown --reference="$(dirname "$MACHINE_ID_FILE")" "$MACHINE_ID_FILE" 2>/dev/null || true
        chmod 600 "$MACHINE_ID_FILE" 2>/dev/null || true
    fi
fi

echo "Machine Fingerprint (MFP): $FINGERPRINT"
