#!/bin/bash
# run-docker-matrix.sh — prove the installer works OFFLINE on every supported
# Ubuntu LTS. For each of focal/jammy/noble:
#   1. build a systemd-enabled image (ONLINE, one-time — test scaffolding only)
#   2. start a privileged container with `--network none` (NO internet)
#   3. copy the installer tarball + harness in, run install.sh, then verify.sh
#   4. collect a per-codename report; aggregate into a matrix summary.
#
# The supra installer NEVER sees a network — any internet dependency fails.
#
# Usage: [sudo] bash run-docker-matrix.sh [--tarball PATH] [--codenames "focal jammy noble"]
# Needs: docker daemon running; access to docker.sock (docker group or sudo).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

TARBALL="/home/velu/Hitachi/supra-installer-3.6.0-linux-x64.tar.gz"
CODENAMES="focal jammy noble"
while [ $# -gt 0 ]; do case "$1" in
  --tarball) TARBALL="$2"; shift;;
  --codenames) CODENAMES="$2"; shift;;
  *) err "unknown arg: $1"; exit 2;;
esac; shift; done
[ -f "$TARBALL" ] || { err "tarball not found: $TARBALL"; exit 1; }
docker info >/dev/null 2>&1 || { err "docker daemon not reachable. Start it (sudo systemctl start docker) and ensure you're in the docker group."; exit 1; }

STAMP="$(date -u +%Y%m%d-%H%M%S)"
MATRIX="$HERE/reports/matrix-${STAMP}.md"
{ echo "# Supra Installer — Offline Multi-LTS Matrix"; echo;
  echo "- **Date:** $(date -u '+%Y-%m-%d %H:%M:%SZ')"; echo "- **Tarball:** $(basename "$TARBALL")";
  echo "- **Install network:** \`--network none\` (offline-enforced)"; echo;
  echo "| Ubuntu LTS | Install | Checks (P/F/S) | Verdict | Report |"; echo "|---|---|---|---|---|"; } > "$MATRIX"

overall=0
for CN in $CODENAMES; do
  log "==================== $CN ===================="
  IMG="supra-test-systemd:$CN"
  CNAME="supra-test-$CN-$STAMP"

  log "[$CN] build systemd image (online, scaffolding)"
  if ! docker build -q -f "$HERE/Dockerfile.systemd" --build-arg CODENAME="$CN" -t "$IMG" "$HERE" >/dev/null; then
    err "[$CN] image build failed (need internet for one-time base+systemd)"; echo "| $CN | ⚠️ build failed | - | ❌ | - |" >> "$MATRIX"; overall=1; continue
  fi

  log "[$CN] start container with NO network"
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  docker run -d --name "$CNAME" --privileged --network none \
    --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock "$IMG" >/dev/null
  sleep 6  # let systemd come up

  log "[$CN] copy installer + harness into container"
  docker cp "$TARBALL" "$CNAME:/root/installer.tar.gz"
  docker exec "$CNAME" mkdir -p /root/harness
  docker cp "$HERE/lib.sh"    "$CNAME:/root/harness/lib.sh"
  docker cp "$HERE/verify.sh" "$CNAME:/root/harness/verify.sh"

  log "[$CN] run installer (offline) + verify inside container"
  docker exec "$CNAME" bash -c '
    set -e
    # Extract under /opt (world-traversable) not /root (0700): install.sh runs
    # opensearch-plugin as the supra user, which must read the extracted tree.
    mkdir -p /opt/installer-src && tar xzf /root/installer.tar.gz -C /opt/installer-src
    chmod -R a+rX /opt/installer-src
    SRC=$(dirname $(find /opt/installer-src -name install.sh -path "*supra-installer*" | head -1))
    bash "$SRC/install.sh" >/root/install.log 2>&1
  '; INSTALL_RC=$?
  docker exec "$CNAME" bash -c 'INSTALL_LOG=/root/install.log bash /root/harness/verify.sh \
       --results /root/results --report /root/report.md --env "docker:'"$CN"' (offline)"'; VERIFY_RC=$?

  # Pull artifacts out
  RPT="$HERE/reports/docker-${CN}-${STAMP}.md"
  docker cp "$CNAME:/root/report.md" "$RPT" 2>/dev/null || echo "(no report)" > "$RPT"
  docker cp "$CNAME:/root/install.log" "$HERE/reports/docker-${CN}-${STAMP}.install.log" 2>/dev/null || true
  PFS="$(docker exec "$CNAME" bash -c '
     p=$(grep -c "^PASS|" /root/results 2>/dev/null||echo 0)
     f=$(grep -c "^FAIL|" /root/results 2>/dev/null||echo 0)
     s=$(grep -c "^SKIP|" /root/results 2>/dev/null||echo 0); echo "$p/$f/$s"' 2>/dev/null || echo "?/?/?")"

  inst="✅ exit 0"; [ "$INSTALL_RC" -ne 0 ] && inst="❌ exit $INSTALL_RC"
  verdict="✅ PASS"; { [ "$INSTALL_RC" -ne 0 ] || [ "$VERIFY_RC" -ne 0 ]; } && { verdict="❌ FAIL"; overall=1; }
  echo "| $CN | $inst | $PFS | $verdict | docker-${CN}-${STAMP}.md |" >> "$MATRIX"
  log "[$CN] $verdict (install $inst, checks $PFS)"

  docker rm -f "$CNAME" >/dev/null 2>&1 || true
done

echo; { echo; echo "**Overall:** $([ $overall -eq 0 ] && echo 'ALL PASS ✅' || echo 'FAILURES PRESENT ❌')"; } >> "$MATRIX"
log "Matrix report: $MATRIX"
cat "$MATRIX"
exit $overall
