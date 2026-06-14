# Supra Installer 3.6.0 — Offline Test Findings

**Date:** 2026-06-10  ·  **Host:** Ubuntu 22.04.5 LTS (jammy), amd64
**Artifact:** `supra-installer-3.6.0-linux-x64.tar.gz`
**Method:** automated harness in `scripts/test/` — reset → offline-enforced install → auto-license → start services → verify.

---

## Summary

| Tier | Result |
|---|---|
| **Install (offline, `unshare -n`)** | ✅ **PASS** — 25/25 checks |
| **Runtime (services started + licensed)** | ⚠️ functional after a license workaround; **2 real bugs found** |

The installer lays down a correct, fully-offline install on jammy. Two
**product** bugs (not harness artifacts, not LTS-specific) block a clean
out-of-the-box runtime and must be fixed for "works on any Ubuntu LTS without
issues":

1. **🔴 Critical — license fingerprint mismatch (licensing is unusable).** ✅ **FIXED** (2026-06-10).
2. **🟠 High — index-template one-shot fails on fresh boot (ordering/race).** ✅ **FIXED** (2026-06-10).

---

## 🔴 Bug 1 — License fingerprint mismatch (activation can never succeed)

**Symptom.** OpenSearch refuses to start after activating a license generated
from the documented `get-fingerprint.sh` output:

```
java.lang.RuntimeException: License fingerprint mismatch!
  Licensed for:  ac2908aa…4ad7c   (get-fingerprint.sh, run as root)
  This machine:  691659e8…60e259   (plugin, running as 'supra')
```

**Root cause.** `/sys/class/dmi/id/product_uuid` and `board_serial` are mode
`0400` (root-only). The two fingerprint paths disagree:

| Context | product_uuid | board_serial | disk | Fingerprint |
|---|---|---|---|---|
| `get-fingerprint.sh` (run as **root** via sudo) | real `4862defa-…` | real `PPQMR068…` | real | `ac2908aa…` |
| Plugin `MachineFingerprint` (runs as **`supra`**) | *Permission denied* → `UNKNOWN` | *Permission denied* → `UNKNOWN` | `UNKNOWN` | `sha256("UNKNOWN\|UNKNOWN\|UNKNOWN")` = `691659e8…` |

Proven: `printf 'UNKNOWN|UNKNOWN|UNKNOWN' | sha256sum` → `691659e8…60e259`,
exactly the value the plugin reports on this machine.

**Impact.**
- The documented activation flow (`sudo get-fingerprint.sh` → vendor → `license.key`) **fails on every Linux host**.
- Because the plugin gets `UNKNOWN|UNKNOWN|UNKNOWN` on *every* machine, the
  fingerprint is identical everywhere → the license is **not machine-bound** at
  all; one `license.key` validates on any Linux box. The hardware lock is void.
- Affects **all Ubuntu LTS** identically.

**Recommended fix (one of):**
- **Best:** at install time (root), capture the hardware IDs and write them to a
  `supra`-readable cache, e.g. `…/supra-license/machine-id` (`0640 root:supra`).
  Make **both** `MachineFingerprint.generate()` and `get-fingerprint.sh` read
  that cache. Consistent *and* still machine-bound.
- Or grant the `supra` service read access to the DMI values (e.g. a systemd
  `ExecStartPre` as root that stages them), then have the plugin read the stage.
- Whatever the choice, `get-fingerprint.sh` and the plugin must compute the
  **same** value as the **same effective identity**.

**✅ Fix applied (2026-06-10).** The plugin now reads a **root-written cache**
instead of computing the fingerprint as the (unprivileged) OpenSearch user:
- `MachineFingerprint.generate(Path cacheDir)` reads `supra-license/machine-id`
  if present (falls back to live hardware otherwise). `LicenseValidatorPlugin`
  passes the license dir.
- `supra-search.service` gains a root `ExecStartPre=+…` that runs
  `get-fingerprint.sh` with `MACHINE_ID_FILE=…/machine-id` **before** OpenSearch
  starts — so the cache holds the real DMI fingerprint (mode `0600`, owned by the
  run-as user). `get-fingerprint.sh` writes the cache when `MACHINE_ID_FILE` is set.
- Result: `get-fingerprint.sh` (root) and the plugin agree on the **real**
  hardware fingerprint → activation works **and** the license is machine-bound.

Files changed: `MachineFingerprint.java`, `LicenseValidatorPlugin.java`,
`get-fingerprint.sh`, `build-installer.sh` (supra-search.service generation).
Plugin zip rebuilt (`mvn package`, offline). All four baked into the canonical
sources *and* the shipped 3.6.0 tarball.

**Verified end-to-end:** new plugin installed → `get-fingerprint.sh` (root) →
`ac2908aa…` (real, not `691659e8…`) → license signed for it → service start wrote
`machine-id=ac2908aa…` → plugin logged **"Supra license validated successfully"**,
cluster healthy. `machine-id` is `0600 supra:supra`.

---

## 🟠 Bug 2 — `supra-index-template` one-shot fails on a fresh boot

**Symptom.** On first start the one-shot fails and the `supra-logs` template is
never applied:

```
Installing index template 'supra-logs' on https://localhost:9200 ...
OpenSearch Security not initialized.
WARNING: did not see acknowledged:true
supra-index-template.service: Failed with result 'exit-code' (status=1)
```

**Root cause.** `supra-index-template.sh` PUTs the template **immediately**, with
no wait/retry for cluster readiness. Right after boot, OpenSearch Security has
not finished initializing the `.opendistro_security` index, so the request is
rejected ("Security not initialized") and the one-shot exits 1.

**Proof it's purely ordering:** re-running the one-shot *after* the cluster is up
succeeds (`Result=success`) and the template appears:
`GET /_index_template` → `"name": "supra-logs"`.

**Impact.** On a normal first boot the `supra-logs` index template is **silently
missing** → fluentd-ingested `supra-*` indices get default dynamic mappings
instead of the intended settings (replicas 0, keyword/text rules, field limits),
until someone manually re-runs the script. Affects all Ubuntu LTS.

**Recommended fix.** Gate the PUT on readiness: poll
`GET /_cluster/health?wait_for_status=yellow` (authenticated) until it returns
200, with a bounded retry loop, *then* apply the template — and retry the PUT a
few times on "Security not initialized". (Equivalently, have the service wait for
search health before running.)

**✅ Fix applied (2026-06-10).** `supra-index-template.sh` now retries the
idempotent PUT until acknowledged (up to `MAX_TRIES`×`SLEEP_SECS`, default
5 min; oneshot `TimeoutStartSec=infinity` so this is safe). Each client path
(curl/wget/python3/ruby) now echoes the response body without aborting, and the
bash loop waits out "Security not initialized".
- Source fixed: `supra-index-template.sh` (canonical — `build-installer.sh:34`
  bundles it, so future builds inherit it).
- Existing tarball patched in place (member replaced + verified).
- **Verified:** deleted the template, restarted `supra-search` (forces security
  re-init), fired the one-shot in the race window → it retried through init and
  finished `Result=success`; `GET /_index_template` shows `supra-logs`.

---

## Install-level checks (offline, 25/25 PASS)

supra user · sysctl `vm.max_map_count` · opensearch (bin/JDK/opensearch.yml,
owned `supra`) · license `public.key` · dashboards (bin/config) ·
`fluent-package` + `/opt/fluent/bin/fluentd` + `fluent-plugin-opensearch` ·
`fluent.conf` · index-template script · all 4 `supra-*` units present + enabled.

Install ran under `unshare -n` (no network) and exited 0 → **confirmed fully
offline on jammy.**

## Runtime checks (after license workaround)

| Check | Result |
|---|---|
| supra-search active | ✅ |
| cluster responds :9200 / health | ✅ green→yellow (yellow normal: single node) |
| supra-dashboards active / :5601 | ✅ |
| supra-log-collector active | ✅ |
| :24224 (forward) / :514 (syslog) listening | ✅ |
| **index template applied (auto)** | ❌ **Bug 2** |
| **license activation (documented flow)** | ❌ **Bug 1** |

---

## Cross-LTS status

The two bugs are **identity/permission and ordering** issues — **not** tied to
any library ABI, so they reproduce identically on focal/jammy/noble. The
per-codename offline `.deb` install can be validated on all three via
`scripts/test/run-docker-matrix.sh` (install-level; `--network none`). **Pending.**

## Next actions
1. Fix Bug 1 (fingerprint parity) and Bug 2 (readiness gate).
2. Run the focal/jammy/noble offline matrix to confirm per-LTS package install.
3. Re-run `run-local.sh --runtime` → expect a clean full-lifecycle PASS.
