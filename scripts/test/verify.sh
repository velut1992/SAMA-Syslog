#!/bin/bash
# verify.sh — assert the Supra installer produced a correct install.
# Two tiers:
#   install-level (default): files, packages, units enabled — what install.sh guarantees.
#   runtime-level (--runtime): start services + check cluster/ports — needs a license.key.
#
# Usage: verify.sh [--runtime] [--results FILE] [--report FILE] [--env LABEL]
# Exits nonzero if any check FAILs. Designed to run on the host OR inside a container.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

RUNTIME=0; REPORT=""; ENVLABEL="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
while [ $# -gt 0 ]; do case "$1" in
  --runtime) RUNTIME=1;;
  --results) RESULTS_FILE="$2"; shift;;
  --report)  REPORT="$2"; shift;;
  --env)     ENVLABEL="$2"; shift;;
  *) err "unknown arg: $1"; exit 2;;
esac; shift; done

results_init
log "Install-level verification ($ENVLABEL)"

# ---- user / system tuning ----
check "supra user exists"            id supra
check "sysctl drop-in present"       test -f /etc/sysctl.d/99-supra.conf
check "vm.max_map_count applied"     bash -c '[ "$(sysctl -n vm.max_map_count 2>/dev/null)" -ge 262144 ]'

# ---- search engine ----
check "opensearch dir present"       test -d /opt/supra/opensearch
check "opensearch binary present"    test -x /opt/supra/opensearch/bin/opensearch
check "opensearch.yml present"       test -f /opt/supra/opensearch/config/opensearch.yml
check "bundled JDK present"          test -x /opt/supra/opensearch/jdk/bin/java
check "license public.key present"   test -f /opt/supra/opensearch/config/supra-license/public.key
check "opensearch owned by supra"    bash -c '[ "$(stat -c %U /opt/supra/opensearch)" = supra ]'

# ---- dashboards ----
check "dashboards dir present"       test -d /opt/supra/dashboards
check "dashboards binary present"    test -x /opt/supra/dashboards/bin/opensearch-dashboards
check "dashboards config present"    test -f /opt/supra/dashboards/config/opensearch_dashboards.yml

# ---- log collector (fluent-package) ----
check "fluent-package installed"     bash -c 'dpkg-query -W -f="\${Status}" fluent-package 2>/dev/null | grep -q installed'
check "fluentd binary present"       test -x /opt/fluent/bin/fluentd
check "fluent.conf present"          test -f /opt/supra/log-collector/fluent.conf
check "fluent-plugin-opensearch"     bash -c '/opt/fluent/bin/fluent-gem list -i fluent-plugin-opensearch >/dev/null 2>&1'

# ---- index template + units ----
check "index-template script"        test -f /opt/supra/index-template/supra-index-template.sh
for u in supra-search supra-dashboards supra-log-collector supra-index-template; do
  check "unit file: $u"              test -f "/etc/systemd/system/$u.service"
  check_msg "unit enabled: $u" "$(systemctl is-enabled $u 2>/dev/null)" \
                                     bash -c "systemctl is-enabled $u 2>/dev/null | grep -q enabled"
done

# ---- runtime tier (optional) ----
if [ "$RUNTIME" -eq 1 ]; then
  log "Runtime verification (services must be started + licensed)"
  if [ ! -f /opt/supra/opensearch/config/supra-license/license.key ]; then
    record SKIP "runtime checks" "no license.key present — start gate not satisfied"
  else
    # --- search engine ---
    systemctl start supra-search 2>/dev/null || true
    # Wait for the cluster to be READY: _cluster/health returns green|yellow only
    # after the security index is initialized AND shards are allocated. Polling
    # the root endpoint is not enough — it answers before the cluster settles.
    health=""; ok=0
    for _ in $(seq 1 60); do
      health="$(curl -sk 'https://localhost:9200/_cluster/health' -u admin:admin 2>/dev/null | grep -oE '\"status\":\"[a-z]+\"' | head -1)"
      case "$health" in *green*|*yellow*) ok=1; break;; esac
      sleep 2
    done
    check_msg "supra-search active" "$(systemctl is-active supra-search 2>/dev/null)" \
                                     bash -c 'systemctl is-active supra-search | grep -q active'
    [ "$ok" = 1 ] && record PASS "cluster responds on :9200" "$(curl -sk https://localhost:9200 -u admin:admin 2>/dev/null | grep -oE '\"number\" : \"[^\"]+\"' | head -1)" \
                  || record FAIL "cluster responds on :9200" "no healthy response after 120s — license rejected or boot failure"
    case "$health" in *green*|*yellow*) record PASS "cluster health" "$health";; *) record FAIL "cluster health" "${health:-unreachable}";; esac
    # index template applied by the supra-index-template one-shot. The one-shot
    # has no readiness wait, so on a fresh boot it can fire before security is
    # initialized and FAIL. We've already waited for health above; trigger it now
    # and report whether the installer's own mechanism actually applied it.
    systemctl start supra-index-template 2>/dev/null || true; sleep 5
    if curl -sk 'https://localhost:9200/_index_template' -u admin:admin 2>/dev/null | grep -qiE 'supra|logs|ied'; then
      record PASS "index template applied"
    else record FAIL "index template applied" "supra-index-template one-shot did not apply the template (ordering bug: runs before security init)"; fi

    # --- dashboards ---
    systemctl start supra-dashboards 2>/dev/null || true
    dok=0; for _ in $(seq 1 45); do
      curl -s -o /dev/null -w '%{http_code}' http://localhost:5601/api/status 2>/dev/null | grep -qE '200|302|401' && { dok=1; break; }; sleep 2; done
    check_msg "supra-dashboards active" "$(systemctl is-active supra-dashboards 2>/dev/null)" \
                                     bash -c 'systemctl is-active supra-dashboards | grep -q active'
    [ "$dok" = 1 ] && record PASS "dashboards responds on :5601" || record FAIL "dashboards responds on :5601" "no HTTP after 90s"

    # --- log collector ---
    systemctl start supra-log-collector 2>/dev/null || true; sleep 8
    check_msg "supra-log-collector active" "$(systemctl is-active supra-log-collector 2>/dev/null)" \
                                     bash -c 'systemctl is-active supra-log-collector | grep -q active'
    check ":24224 listening (forward)"  bash -c 'ss -tlnp 2>/dev/null | grep -q :24224'
    check ":514 listening (syslog)"     bash -c 'ss -ulnp 2>/dev/null | grep -q :514'
  fi
fi

read -r P F S T <<<"$(counts)"
echo
log "Summary ($ENVLABEL): PASS=$P FAIL=$F SKIP=$S TOTAL=$T"
[ -n "$REPORT" ] && write_report "$REPORT" "$ENVLABEL" "${INSTALL_LOG:-}"
[ "$F" -eq 0 ]
