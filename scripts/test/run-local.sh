#!/bin/bash
# run-local.sh — full installer test on THIS host (current Ubuntu LTS).
#   reset (optional) -> offline-enforced install -> verify -> markdown report.
#
# "Offline" is ENFORCED: install.sh runs inside an isolated network namespace
# (unshare -n) with no connectivity, so any accidental internet dependency fails
# loudly instead of silently succeeding on a connected box.
#
# Usage: sudo bash run-local.sh [--tarball PATH] [--no-reset] [--runtime]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
[ "$EUID" -ne 0 ] && { err "run as root: sudo bash $0"; exit 1; }

TARBALL="/home/velu/Hitachi/supra-installer-3.6.0-linux-x64.tar.gz"
LICENSE_ASSETS="/home/velu/Hitachi/opensearch-license-validator"
DO_RESET=1; RUNTIME=""
while [ $# -gt 0 ]; do case "$1" in
  --tarball) TARBALL="$2"; shift;;
  --license-assets) LICENSE_ASSETS="$2"; shift;;
  --no-reset) DO_RESET=0;;
  --runtime) RUNTIME="--runtime";;
  *) err "unknown arg: $1"; exit 2;;
esac; shift; done
[ -f "$TARBALL" ] || { err "tarball not found: $TARBALL"; exit 1; }

CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"; INSTALL_LOG="$WORK/install.log"
REPORT="$HERE/reports/local-${CODENAME}-${STAMP}.md"
export INSTALL_LOG RESULTS_FILE="$WORK/results"
export REPORT_TITLE="Supra Installer Test — local ($CODENAME, offline-enforced)"

log "Host: $(. /etc/os-release; echo "$PRETTY_NAME")  |  tarball: $TARBALL"

if [ "$DO_RESET" = 1 ]; then
  log "Phase 1/3 — reset to fresh state"
  bash "$HERE/reset.sh" || warn "reset reported issues (continuing)"
else
  log "Phase 1/3 — reset SKIPPED (--no-reset)"
fi

log "Phase 2/3 — extract + install (network-isolated)"
# install.sh installs the OpenSearch plugins as the 'supra' user
# (sudo -u supra opensearch-plugin install file://...), so the extracted tree
# MUST be traversable+readable by that user. mktemp -d is 0700 root — open it up.
chmod 755 "$WORK"
tar xzf "$TARBALL" -C "$WORK"
SRC="$(dirname "$(find "$WORK" -name install.sh -path '*supra-installer*' | head -1)")"
[ -d "$SRC" ] || { err "install.sh not found in tarball"; exit 1; }
chmod -R a+rX "$SRC"

# Enforce offline: run install in a private net namespace (only loopback, down).
if command -v unshare >/dev/null 2>&1; then
  OFFLINE=(unshare -n)
  log "  offline enforcement: unshare -n (no network during install)"
else
  OFFLINE=(); warn "  unshare unavailable — install runs WITHOUT offline enforcement"
fi
set +e
"${OFFLINE[@]}" bash "$SRC/install.sh" >"$INSTALL_LOG" 2>&1
RC=$?
set -e 2>/dev/null || true
if [ $RC -eq 0 ]; then log "  installer exit 0"; else err "  installer exit $RC (see $INSTALL_LOG)"; fi

if [ -n "$RUNTIME" ] && [ $RC -eq 0 ]; then
  log "Phase 2b — provision license (auto) for runtime tier"
  bash "$HERE/provision-license.sh" --assets "$LICENSE_ASSETS" || warn "license provisioning failed — runtime checks will be skipped"
fi

log "Phase 3/3 — verify + report"
set +e
bash "$HERE/verify.sh" $RUNTIME --results "$RESULTS_FILE" --report "$REPORT" --env "local:$CODENAME (offline)"
VRC=$?
set -e 2>/dev/null || true

# Fold installer exit code into the report verdict
if [ $RC -ne 0 ]; then
  echo "FAIL|installer exit code|install.sh returned $RC" >> "$RESULTS_FILE"
  write_report "$REPORT" "local:$CODENAME (offline)" "$INSTALL_LOG" >/dev/null
fi

echo; read -r P F S T <<<"$(counts)"
log "DONE — local:$CODENAME → PASS=$P FAIL=$F SKIP=$S"
log "Report: $REPORT"
rm -rf "$WORK"
[ "$F" -eq 0 ] && [ $RC -eq 0 ]
