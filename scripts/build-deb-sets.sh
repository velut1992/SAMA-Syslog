#!/bin/bash
set -euo pipefail

################################################################################
# build-deb-sets.sh — fetch release-matched Log Collector .deb sets
#
# Produces, for each supported Ubuntu LTS:
#
#   <dest>/<codename>/fluent-package_<ver>_amd64.deb   (from packages.treasuredata.com)
#   <dest>/<codename>/<dependency libs>.deb            (release-native versions)
#
# These dirs are what install.sh / fix-log-collector.sh select at runtime via
# log-collector/deb/<codename>/.
#
# THIS IS A BUILD-TIME SCRIPT and is the ONLY part of the pipeline that needs
# internet access. The installer bundle it produces stays fully air-gapped.
#
# Dependency libs are release-specific (e.g. focal links libssl1.1, jammy
# libssl3, noble libssl3t64), so they are resolved from each release's own
# fluent-package .deb Depends and downloaded from a matching environment:
#   * Preferred: a per-release Docker container (clean, exact versions).
#   * Fallback:  the host's apt, but ONLY for the host's own codename.
#
# Usage:
#   scripts/build-deb-sets.sh [DEST_DIR] [CODENAME...]
#     DEST_DIR   default: <repo>/supra-installer/log-collector/deb
#     CODENAME   default: focal jammy noble
#
# Env overrides:
#   FLUENT_VERSION   fluent-package version (default 5.0.9-1)
#   TD_BASE_URL      treasuredata repo base (default packages.treasuredata.com/lts/5/ubuntu)
################################################################################

FLUENT_VERSION="${FLUENT_VERSION:-5.0.9-1}"
TD_BASE_URL="${TD_BASE_URL:-https://packages.treasuredata.com/lts/5/ubuntu}"

DEST_DIR="${1:-}"
if [ -z "$DEST_DIR" ]; then
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    DEST_DIR="$REPO_ROOT/supra-installer/log-collector/deb"
fi
shift || true
CODENAMES=("$@")
[ "${#CODENAMES[@]}" -eq 0 ] && CODENAMES=(focal jammy noble)

# Base libraries that are part of every Ubuntu install — we never bundle/ship
# these (shipping libc6 etc. is exactly what risks corrupting a host).
SKIP_DEPS_RE='^(libc6|libgcc-s1|libcrypt1|adduser|gcc-.*-base)$'

log()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    HAVE_DOCKER=1
fi
# Download the release's fluent-package .deb from treasuredata into $1.
fetch_fluent_package() {
    local codename="$1" out="$2" url
    url="$TD_BASE_URL/$codename/pool/contrib/f/fluent-package/fluent-package_${FLUENT_VERSION}_amd64.deb"
    log "  fluent-package: $url"
    if ! curl -fSL --retry 3 -o "$out/fluent-package_${FLUENT_VERSION}_amd64.deb" "$url"; then
        err "  Could not download fluent-package for $codename from $url"
        err "  Check FLUENT_VERSION / TD_BASE_URL, or the repo layout for this release."
        return 1
    fi
}

# Parse the dependency package names we should bundle out of a .deb's Depends.
deb_dep_names() {
    dpkg-deb -f "$1" Depends \
        | tr ',' '\n' \
        | sed -E 's/\(.*\)//; s/\|.*//; s/[[:space:]]//g' \
        | grep -vE "$SKIP_DEPS_RE" \
        | grep -v '^$' || true
}

# Download the named dep .debs for $codename into $out using a Docker container.
fetch_deps_docker() {
    local codename="$1" out="$2"; shift 2
    local names="$*"
    log "  Resolving dependency libs in ubuntu:$codename container..."
    docker run --rm -v "$out":/out "ubuntu:$codename" bash -c "
        set -e
        apt-get update -qq
        cd /out
        for p in $names; do
            apt-get download \"\$p\" || echo \"  (skip \$p — not downloadable)\" >&2
        done
        chmod a+rw /out/*.deb 2>/dev/null || true
    "
}

# Fallback (no Docker): resolve dep libs straight from the Ubuntu archive by
# parsing each suite's Packages index. Works for any codename from any host.
ARCHIVE_MIRROR="${ARCHIVE_MIRROR:-http://archive.ubuntu.com/ubuntu}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}"

fetch_deps_pool() {
    local codename="$1" out="$2"; shift 2
    local names="$*"
    local tmp; tmp="$(mktemp -d)"
    declare -A FN_MIRROR FN_PATH
    log "  Resolving dependency libs from Ubuntu archive ($codename)..."
    # Later suites (updates/security) override the release pocket.
    local suites=("$codename:$ARCHIVE_MIRROR" \
                  "$codename-updates:$ARCHIVE_MIRROR" \
                  "$codename-security:$SECURITY_MIRROR")
    for entry in "${suites[@]}"; do
        local suite="${entry%%:*}" mirror="${entry#*:}"
        for comp in main universe; do
            local idx="$mirror/dists/$suite/$comp/binary-amd64/Packages.gz"
            curl -fsSL "$idx" 2>/dev/null | gunzip 2>/dev/null \
              | awk 'BEGIN{RS="";FS="\n"}{p="";f="";for(i=1;i<=NF;i++){if($i~/^Package: /)p=substr($i,10);else if($i~/^Filename: /)f=substr($i,11)}if(p&&f)print p"\t"f}' \
              > "$tmp/pairs" || continue
            while IFS=$'\t' read -r p f; do
                FN_MIRROR["$p"]="$mirror"; FN_PATH["$p"]="$f"
            done < "$tmp/pairs"
        done
    done
    for p in $names; do
        if [ -n "${FN_PATH[$p]:-}" ]; then
            curl -fsSL -o "$out/$(basename "${FN_PATH[$p]}")" \
                 "${FN_MIRROR[$p]}/${FN_PATH[$p]}" \
              && log "    + $(basename "${FN_PATH[$p]}")" \
              || warn "    ! download failed: $p"
        else
            warn "    ! not found in $codename main/universe: $p"
        fi
    done
    rm -rf "$tmp"
}

for codename in "${CODENAMES[@]}"; do
    out="$DEST_DIR/$codename"
    log "=== $codename -> $out ==="
    mkdir -p "$out"
    rm -f "$out"/*.deb "$out"/Packages*

    fetch_fluent_package "$codename" "$out" || { err "skip $codename"; continue; }

    fp_deb="$(ls "$out"/fluent-package_*.deb 2>/dev/null | head -1)"
    dep_names="$(deb_dep_names "$fp_deb" | tr '\n' ' ')"
    log "  Dependency libs to bundle: ${dep_names:-<none>}"

    if [ "$HAVE_DOCKER" -eq 1 ]; then
        fetch_deps_docker "$codename" "$out" $dep_names
    else
        fetch_deps_pool "$codename" "$out" $dep_names
    fi

    log "  $codename set: $(ls "$out"/*.deb 2>/dev/null | wc -l) .deb file(s)"
done

log "Done. Review $DEST_DIR/<codename>/ before repackaging the installer tarball."
