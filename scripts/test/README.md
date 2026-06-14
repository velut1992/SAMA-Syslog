# Supra Installer — Offline Test Harness

Automated **remove → install → verify → report** for `supra-installer-3.6.0-linux-x64.tar.gz`,
proving it installs **fully offline** on every supported Ubuntu LTS (focal 20.04,
jammy 22.04, noble 24.04).

## Files
| File | Purpose |
|---|---|
| `reset.sh` | Return a host to a fresh state (removes legacy + 3.6.0 artifacts). Run as root. |
| `verify.sh` | Assert the install is correct. Install-level by default; `--runtime` adds service-start checks (needs a `license.key`). |
| `run-local.sh` | Full test on **this** host. Install runs under `unshare -n` so offline is *enforced*, not assumed. |
| `run-docker-matrix.sh` | Build systemd containers for focal/jammy/noble, install with `--network none`, verify, aggregate a matrix report. |
| `Dockerfile.systemd` | systemd-enabled Ubuntu base (built online once — scaffolding only). |
| `lib.sh` | Shared logging + report helpers. |
| `reports/` | Generated markdown reports + install logs. |

## Quick start

**This host (jammy), offline-enforced, with a fresh reset first:**
```bash
sudo bash scripts/test/run-local.sh
```
Report → `scripts/test/reports/local-jammy-<stamp>.md`.

> ⚠️ `run-local.sh` will **delete** the current install (`/opt/supra`, the `supra`
> user, units). That's the point — it tests a clean install. Use `--no-reset` to
> install over whatever's there instead.

**All three LTS versions, install fully offline (`--network none`):**
```bash
# one-time: the docker daemon must be running
sudo systemctl start docker
bash scripts/test/run-docker-matrix.sh            # or: sudo bash ... if not in docker group
```
Reports → `scripts/test/reports/docker-<codename>-<stamp>.md` and a `matrix-<stamp>.md` summary.

> The base-image build needs internet **once** (to add systemd). The Supra
> installer then runs in a container with **no network** — so a green matrix
> means the installer is genuinely internet-free on every LTS.

## What "offline" means here
- **local:** `install.sh` runs inside a private network namespace (`unshare -n`) — only loopback, no route out.
- **docker:** the container is started with `--network none` — there is no interface to the internet at all.

Either way, if the installer secretly needs `apt-get update`, a gem fetch, or any
download, the run **fails loudly** instead of passing on a connected machine.

## Runtime tier (optional, needs a license)
`install.sh` only *enables* services; starting them requires a `license.key`
(fingerprint → vendor key). To also test startup + cluster health:
1. Install, then `sudo bash .../opensearch/config/supra-license/get-fingerprint.sh`
2. Generate/obtain `license.key`, drop it in `/opt/supra/opensearch/config/supra-license/`
3. `sudo bash scripts/test/run-local.sh --no-reset --runtime`
