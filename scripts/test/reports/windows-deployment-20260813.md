# Supra Installer — Windows x64 Deployment Test (machine-id fix)

- **Artifact:** `supra-installer-3.6.0-windows-x64.zip`, rebuilt 2026-08-13 19:55
  (SHA256 `6727b239d188dfecccc38ec174fc52d95933ac27d62313217f1cf73d9f79b536`)
- **Test host:** Windows 11 Pro 22631 (workstation, **not** Windows Server), 15.6 GB RAM,
  Norton 360 active
- **Install path:** `D:\supra-test` (never `D:\supra` — that is `D:\Supra`, the
  operator's working tree; see 20260807 report §6)
- **Date:** 2026-08-13, 19:55 – 21:17 IST
- **Installer result:** **PASS** — exit 0, 34m 6s, zero errors, one warning (now fixed)
- **Service bring-up:** **PASS** — everything the 20260807 run left unverified now verified
- **Revert:** **PASS** — clean, and the pre-existing Fluentd survived

## 1. What this run was for

The 20260807 report, §4, recorded a High defect that was never fixed:
`get-fingerprint.ps1` and the validating plugin disagreed about this machine's
fingerprint, so a licence issued against the reported MFP was rejected and the
node refused to start. A customer hit exactly that on their test PC.

Root cause confirmed here: the plugin cannot shell out to PowerShell/wmic from
inside the OpenSearch JVM, so `MachineFingerprint` resolved CPU, board and disk
all to `UNKNOWN` and hashed the constant

```
sha256("UNKNOWN|UNKNOWN|UNKNOWN") = 691659e84797cd7d3e22021da866ede3661a4c68538a73da2990c634b460e259
```

— byte-for-byte the value §4 captured from the plugin. Linux never saw this
because `supra-search.service` writes a `machine-id` cache from a root
`ExecStartPre` and `MachineFingerprint.generate(Path)` prefers it. The Windows
installer wrote no such cache.

**Fix under test:** `install.ps1` now writes `config\supra-license\machine-id`
from the real hardware values while running elevated, and `get-fingerprint.ps1`
gained `-MachineIdFile` (matching `MACHINE_ID_FILE` in the `.sh`).

**Licence used:** issued against `d480b59a4fa8ff88cd9672c53cbeca62bf0e91775f0b094e64659fbdcbb27671`,
this machine's *real* MFP — the value the broken path could never produce. A
pass therefore cannot be a false positive from a licence bound to the UNKNOWN hash.

## 2. Installation — PASS (exit 0, 34m 6s)

| Status | Step | Detail |
|--------|------|--------|
| ✅ PASS | Service account, NSSM, PATH | as before |
| ✅ PASS | Search engine, demo certs, admin hash | as before |
| ✅ PASS | **`machine-id` cache written** | `Machine fingerprint cached: d480b59a…`, 64 bytes, no BOM |
| ✅ PASS | Licence validator, public key, fingerprint tool, inspector | all installed |
| ✅ PASS | Index Management custom build | installed |
| ✅ PASS | Dashboards | **13/13** plugins |
| ✅ PASS | Fluentd runtime | existing `C:\opt\fluent` detected and reused (no marker written — correct) |
| ✅ PASS | `fluent.conf` deploy, buffer rewrite, dry-run | all as designed |
| ✅ PASS | Firewall | **11/11** rules |
| ⚠️ WARN | **NSSM `AppEvents` hook rejected** | see §5 — fixed after this run |

## 3. Service bring-up — PASS

| Status | Check | Detail |
|--------|-------|--------|
| ✅ PASS | **Licence accepted against the real MFP** | `LicenseValidatorPlugin: Supra license validated successfully` — the defect is gone |
| ✅ PASS | `SupraSearch` starts | 9200 listening 49 s after start |
| ✅ PASS | Cluster health | `green`, 7/7 shards, single node |
| ✅ PASS | **`GET /_supra/license`** | ACTIVE, `signature_verified: true`, `bound_to_machine: d480b59a…` (was BLOCKED on 20260807) |
| ✅ PASS | **`_cat/plugins`** | 19 components incl. `supra-license-validator 1.0.0` (was BLOCKED) |
| ✅ PASS | **Index template** | `{"acknowledged":true}`, exit 0 (was BLOCKED) |
| ✅ PASS | **Dashboards UI** | `GET /api/status` → 200 authenticated, 401 anonymous (was BLOCKED) |
| ✅ PASS | **End-to-end log flow** | 5 syslog datagrams → udp/514 → `supra-ied-2026.08.13`, 5 docs, fields parsed (was BLOCKED) |
| ⛔ BLOCKED | `securityadmin` | PKIX, Norton again — but **not needed**, see §6 |

## 4. Defect found: JVM heap sized without checking commit limit

Severity: **Medium — blocks startup on any host whose page file is small.**

`install.ps1` sets the heap to 50% of RAM (here 8008m). Windows must back the
whole heap with commit charge, and the JVM died before OpenSearch loaded:

```
Native memory allocation (mmap) failed to map 8396996608 bytes
The paging file is too small for this operation to complete (DOS error 1455)
```

NSSM then throttled the service to `SERVICE_PAUSED`, which reads as "started
successfully" from `nssm start` and gives no hint of the real cause. Commit
limit was 34 GB with only 6.2 GB free virtual.

Dropping to `-Xmx2g` made the node start immediately. **Not fixed.** The heap
calculation should also cap against available commit
(`Win32_OperatingSystem.FreeVirtualMemory`), and a startup failure should
surface `hs_err_pid*.log` / `search-stderr.log` rather than a paused service.

## 5. Defect found and fixed: NSSM 2.24 has no `AppEvents`

The pre-start `machine-id` refresh (the Windows counterpart of the Linux
`ExecStartPre`) was registered with `nssm set SupraSearch AppEvents Start/Pre`.
NSSM 2.24 — the version bundled in this installer — rejects the parameter
outright; hooks arrived in 2.25. It failed non-fatally, exactly as designed, but
the hook never existed.

**Fixed after this run:** the call is removed and the limitation documented. The
cache is written once, at install time, from real hardware values.
**Consequence:** after a hardware change, or on a disk cloned to another host,
the cache still describes the original machine and the licence keeps validating
until refreshed:

```powershell
powershell -ExecutionPolicy Bypass -File <install>\opensearch\config\supra-license\get-fingerprint.ps1 `
           -MachineIdFile <install>\opensearch\config\supra-license\machine-id
```

Note this is still strictly better than before: the plugin previously computed
the same constant on *every* Windows host, so Windows licences were not
machine-bound at all.

## 6. `securityadmin` fails under Norton — and is not required

Same PKIX failure as 20260807 §3: Norton Web/Mail Shield re-signs the loopback
TLS certificate on 9200, so Java cannot build a path to `root-ca.pem`.
`supra-init-security.ps1` retried 5 times and exited 1.

**New finding: it does not matter.** `plugins.security.allow_default_init_securityindex: true`
is set in `opensearch.yml`, so the node initialised `.opendistro_security`
itself (9 docs), and every authenticated call afterwards worked. The stack was
fully functional despite the `[ERROR]` banner.

`supra-init-security.ps1` should therefore check whether the security index is
already initialised before declaring failure — an operator who sees this
concludes the install is broken when it is not. **Not fixed.**

## 7. Revert — PASS

`uninstall.ps1 -InstallPath D:\supra-test`, elevated, exit 0.

| Item | Baseline | After revert | Status |
|---|---|---|---|
| `Supra*` services | 0 | 0 | ✅ |
| `Supra*` firewall rules | 0 | 0 | ✅ |
| NSSM on machine PATH | absent | absent | ✅ |
| `OPENSEARCH_JAVA_HOME` | unset | unset | ✅ |
| **`C:\opt\fluent` (pre-existing)** | present | **present** | ✅ |
| **Fluent Package v5.0.6 in Add/Remove** | present | **present** | ✅ |
| `D:\supra-test` | absent | absent (removed) | ✅ |
| `D:\Supra` (operator data) | present | **present** | ✅ |
| `SupraService` account | absent | present → removed by hand | ⚠️ by design |
| `fluentdwinsvc` | Stopped / **Manual** | Stopped / **Disabled** | ⚠️ fixed, see below |

The 20260807 §5 data-loss defect is **confirmed fixed**: with a pre-existing
Fluentd and no `.supra-installed` marker, the uninstaller logged *"Leaving the
existing runtime and its Add/Remove Programs entry untouched"* and both survived.
This run also closed the remaining half of that defect — the marker previously
gated only the folder delete, not the MSI uninstall, so the operator's runtime
would still have been removed from Add/Remove Programs.

**Fixed after this run:** `install.ps1` records `fluentdwinsvc`'s startup type
before disabling it, and `uninstall.ps1` restores it before deleting the install
directory. Restored by hand here.

## 8. Coverage

**Verified on real hardware:** the machine-id fix with a licence bound to the
real MFP; installer end-to-end; node startup and plugin loading; cluster health;
`/_supra/license`; `_cat/plugins`; index template; Dashboards UI; **end-to-end
log flow into `supra-*` indices**; uninstall, including non-destruction of a
pre-existing Fluentd.

**Still unverified:** `securityadmin` on a host without TLS-inspecting antivirus;
Windows **Server** behaviour (this was a workstation); the fluent-package **MSI
install path** (the existing runtime was reused again, so that branch still has
never run); NXLog endpoint kit; multi-node licensing; and the three fixes made
*after* this run (§5, §7, and the heap-example doc text) — those are in
`build-installer.ps1` and the rebuilt zip, but were not themselves re-tested by
a full install.
