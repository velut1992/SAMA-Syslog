#!/bin/bash
set -euo pipefail

# Supra License Inspector (Linux)
# Decodes a Supra license file into human-readable form so operators can see at a
# glance whether a license is Permanent or Temporary, its validity window, tier,
# licensed device/node counts and which machine it is bound to.
#
# The license file is NOT encrypted -- it is base64(JSON payload).base64(RSA
# signature). The signature only makes it tamper-proof; the details are plainly
# readable, so this tool needs no private key. If openssl and the matching
# public.key are available it will additionally verify the signature so you know
# the file is authentic and unmodified.
#
# Usage:
#   ./supra-license-info.sh [path/to/license.key] [path/to/public.key]
#
# Defaults (typical install layout):
#   license.key -> ./license.key, then config/supra-license/license.key
#   public.key  -> alongside the license file

LICENSE_FILE="${1:-}"
PUBLIC_KEY="${2:-}"

# --- locate the license file ---------------------------------------------------
if [ -z "$LICENSE_FILE" ]; then
    for c in "./license.key" "config/supra-license/license.key" \
             "/etc/supra-search/config/supra-license/license.key"; do
        if [ -f "$c" ]; then LICENSE_FILE="$c"; break; fi
    done
fi

if [ -z "$LICENSE_FILE" ] || [ ! -f "$LICENSE_FILE" ]; then
    echo "ERROR: license file not found." >&2
    echo "Usage: $0 [path/to/license.key] [path/to/public.key]" >&2
    exit 1
fi

# default public key location: next to the license file
if [ -z "$PUBLIC_KEY" ]; then
    cand="$(dirname "$LICENSE_FILE")/public.key"
    [ -f "$cand" ] && PUBLIC_KEY="$cand"
fi

# --- split and decode ----------------------------------------------------------
CONTENT="$(tr -d '[:space:]' < "$LICENSE_FILE")"
PAYLOAD_B64="${CONTENT%%.*}"
SIG_B64="${CONTENT#*.}"

if [ "$PAYLOAD_B64" = "$CONTENT" ] || [ -z "$PAYLOAD_B64" ] || [ -z "$SIG_B64" ]; then
    echo "ERROR: invalid license format (expected <payload>.<signature>)." >&2
    exit 1
fi

PAYLOAD="$(printf '%s' "$PAYLOAD_B64" | base64 -d 2>/dev/null || true)"
if [ -z "$PAYLOAD" ]; then
    echo "ERROR: could not decode license payload." >&2
    exit 1
fi

# --- extract a flat-JSON field (string or number) ------------------------------
jget() {
    local key="$1" v
    # string value: "key":"value" -- '|| true' so a missing field is not fatal
    # under 'set -euo pipefail' (grep exits 1 on no match).
    v="$(printf '%s' "$PAYLOAD" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/" || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    # numeric value: "key":123
    v="$(printf '%s' "$PAYLOAD" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" \
        | head -1 | sed -E "s/.*:[[:space:]]*([0-9]+)/\1/" || true)"
    printf '%s' "$v"
    return 0
}

CUSTOMER="$(jget customer)"
FINGERPRINT="$(jget fingerprint)"
ISSUED="$(jget issuedAt)"
EXPIRES="$(jget expiresAt)"
TYPE="$(jget type)"          # may be empty on older licenses
TIER="$(jget tier)"
MAXNODES="$(jget maxNodes)"
MAXDEVICES="$(jget maxDevices)"  # may be empty on older licenses

# --- derive permanent vs temporary + remaining validity ------------------------
EXP_YEAR="${EXPIRES%%-*}"
LICENSE_KIND=""
VALIDITY=""
STATUS="ACTIVE"

if [ -n "$TYPE" ]; then
    # explicit signed type wins, if present
    case "$TYPE" in
        permanent|perpetual) LICENSE_KIND="Permanent (perpetual)";;
        *)                   LICENSE_KIND="Temporary";;
    esac
fi

if [ -n "$EXP_YEAR" ] && [ "$EXP_YEAR" -ge 9999 ] 2>/dev/null; then
    [ -z "$LICENSE_KIND" ] && LICENSE_KIND="Permanent (perpetual)"
    VALIDITY="No expiry"
else
    [ -z "$LICENSE_KIND" ] && LICENSE_KIND="Temporary"
    # days remaining (best-effort; requires GNU date)
    if now_s="$(date +%s 2>/dev/null)" && exp_s="$(date -d "$EXPIRES" +%s 2>/dev/null)"; then
        days=$(( (exp_s - now_s) / 86400 ))
        if [ "$days" -lt 0 ]; then
            STATUS="EXPIRED"
            VALIDITY="Expired ${days#-} day(s) ago"
        else
            VALIDITY="$days day(s) remaining"
        fi
    else
        VALIDITY="Expires $EXPIRES"
    fi
fi

# --- optional signature verification ------------------------------------------
SIG_RESULT="not checked (public.key or openssl unavailable)"
if [ -n "$PUBLIC_KEY" ] && [ -f "$PUBLIC_KEY" ] && command -v openssl >/dev/null 2>&1; then
    tmp_pl="$(mktemp)"; tmp_sig="$(mktemp)"
    trap 'rm -f "$tmp_pl" "$tmp_sig"' EXIT
    printf '%s' "$PAYLOAD" > "$tmp_pl"
    if printf '%s' "$SIG_B64" | base64 -d > "$tmp_sig" 2>/dev/null \
        && openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$tmp_sig" "$tmp_pl" >/dev/null 2>&1; then
        SIG_RESULT="VALID (signature authentic, not tampered)"
    else
        SIG_RESULT="INVALID (signature does NOT match -- file may be tampered or wrong public key)"
        STATUS="UNTRUSTED"
    fi
fi

# --- report -------------------------------------------------------------------
echo "=============================================="
echo "          Supra License Information"
echo "=============================================="
echo "  Customer        : ${CUSTOMER:-<unknown>}"
echo "  License type    : ${LICENSE_KIND}"
echo "  Validity        : ${VALIDITY}"
echo "  Issued on       : ${ISSUED:-<unknown>}"
echo "  Expires on      : ${EXPIRES:-<unknown>}"
echo "  Tier            : ${TIER:-<unknown>}"
echo "  Max nodes       : ${MAXNODES:-<unknown>}"
echo "  Max devices     : ${MAXDEVICES:-not specified}"
echo "  Bound to machine: ${FINGERPRINT:-<unknown>}"
echo "  Signature       : ${SIG_RESULT}"
echo "  Overall status  : ${STATUS}"
echo "=============================================="
echo
echo "Note: this machine's own fingerprint can be printed with get-fingerprint.sh."
echo "It must match 'Bound to machine' above for the license to be accepted."

# exit non-zero if the license is not usable, so it can be scripted
case "$STATUS" in
    ACTIVE) exit 0;;
    *)      exit 2;;
esac
