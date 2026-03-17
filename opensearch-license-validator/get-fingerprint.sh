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

echo "Machine Fingerprint (MFP): $FINGERPRINT"
