# Supra Installer — Windows x64 Build Verification

- **Artifact:** `supra-installer-3.6.0-windows-x64.zip` (1,388.1 MB)
- **SHA256:** `56f5651a9688affb23c886cb9de1996983ff0506d7a7f53cce3352af95e48f92`
- **Build host:** Windows 11 Pro 22631, PowerShell 5.1
- **Date:** 2026-08-07
- **Result:** **PASS (build + collector-config runtime verification)** — 27 checks, 0 failures

> **Scope — read this first.** A **full installation was requested but could not
> be performed on the build host**, for two reasons recorded in
> "Full Installation — Not Performed" below: the session is **not elevated**
> (`install.ps1` requires Administrator), and the host has only **12.6 GB free**
> on `C:` against a peak requirement of roughly 6–7 GB, which is too tight to
> risk a half-completed install.
>
> What *was* achieved: the collector configuration is now **runtime-verified**
> against a real fluentd 1.16.7 / Ruby 3.2.0 installation that already existed on
> the host, which is the single highest-value check and the one that exposed the
> defects below. Everything else remains static verification. "Not Covered"
> lists precisely what still requires a real Windows Server.

---

## Checks

| Status | Check | Detail |
|--------|-------|--------|
| ✅ PASS | build script parses | `build-installer.ps1`, PS AST parser, 0 errors |
| ✅ PASS | generated `install.ps1` parses | extracted from zip, 0 errors |
| ✅ PASS | generated `uninstall.ps1` parses | extracted from zip, 0 errors |
| ✅ PASS | generated `install-nxlog.ps1` parses | extracted from zip, 0 errors |
| ✅ PASS | `supra-index-template.ps1` parses | 0 errors |
| ✅ PASS | `supra-license-info.ps1` parses | 0 errors |
| ✅ PASS | package entry separators | 33/33 entries use `/`, 0 use `\` (ZIP-spec conformant) |
| ✅ PASS | round-trip extraction | `Expand-Archive` reproduces the full 9-folder tree |
| ✅ PASS | checksum emitted | `.sha256` written alongside the artifact |
| ✅ PASS | search engine staged | `opensearch-3.6.0-windows-x64.zip` (830.9 MB) |
| ✅ PASS | dashboards staged | `opensearch-dashboards-3.6.0-SNAPSHOT` (270.0 MB) |
| ✅ PASS | dashboards plugins staged | 13 zips |
| ✅ PASS | NSSM staged | `nssm.exe` win64, 331 KB |
| ✅ PASS | fluent-package MSI staged | `fluent-package-5.0.9-x64.msi` (24.8 MB) |
| ✅ PASS | hardened `fluent.conf` shipped | SHA256 identical to repo `fluent/fluent.conf` |
| ✅ PASS | index template script shipped | `supra-index-template.ps1` present at package root |
| ✅ PASS | license validator rebuilt | jar contains `RestSupraLicenseAction.class`, `LicenseInfo.class` |
| ✅ PASS | license public key staged | `public.key` |
| ✅ PASS | license inspector staged | `supra-license-info.ps1` |
| ✅ PASS | fingerprint tool staged | `get-fingerprint.ps1` |
| ✅ PASS | index-management plugin staged | `opensearch-index-management-3.6.0.0-SNAPSHOT.zip` |
| ✅ PASS | NXLog endpoint kit staged | `nxlog.conf`, `install-nxlog.ps1`, `README.txt` |
| ✅ PASS | inline minimal config removed | no `logstash_prefix fluentd` anywhere in `install.ps1` |
| ✅ PASS | plugin coverage vs runtime | every `@type` in `fluent.conf` resolvable — see below |

---

## Runtime Test: Collector Configuration

Executed against `C:\opt\fluent\bin\fluentd.bat` — **fluentd 1.16.7, Ruby 3.2.0,
`fluent-plugin-opensearch` 1.1.4** — a pre-existing installation on the build
host (created 2025-04-24, unrelated to this work). Same runtime family as the
bundled fluent-package 5.0.9, so the result transfers.

| Status | Check | Detail |
|--------|-------|--------|
| ✅ PASS | `fluentd --dry-run` on repo `fluent.conf` | exit 0, `parsing config file is succeeded` |
| ✅ PASS | `fluent-plugin-opensearch` resolves | loaded at 1.1.4; all 4 `<match> @type opensearch` blocks parsed |
| ✅ PASS | `fluentd --dry-run` after buffer-path rewrite | exit 0 — Windows absolute paths accepted |

This is the check that proves the fluent-package switch is correct: the same
config on td-agent 4.5.2 could not have loaded `@type opensearch` at all.

Non-fatal warnings emitted (pre-existing, present on Linux too, no action required):

- `'protocol_type' parameter is deprecated: use transport directive` ×6
- `define <match fluent.**> ... is deprecated. Use <label @FLUENT_LOG> instead`

### Defect found by this test: POSIX buffer paths

The dry-run's resolved configuration showed all four output buffers pointing at:

```
path "/opt/supra/log-collector/buffer/ied"      (network, windows, other likewise)
```

These are POSIX paths shared with the Linux installer. On Windows they are
**drive-relative**, resolving to `C:\opt\supra\log-collector\buffer\*`:

- outside the install tree, so `-InstallPath D:\supra` still buffers onto `C:`
- outside the ACL grant the installer applies to the log-collector directory
- outside everything `uninstall.ps1` removes — with `total_limit_size 8GB` on
  four buffers, up to **32 GB** could be stranded after an uninstall

**Fixed:** `install.ps1` now rewrites these to `<InstallPath>\log-collector\buffer\*`
after deploying the config, pre-creates the four directories, and warns if any
`/opt/supra/` path survives the rewrite. Verified by re-running the dry-run
against the rewritten file (exit 0, 0 leftover POSIX paths).

---

## Functional Test: License Inspector

`supra-license-info.ps1` was executed against real license files. This is the
only component that could be exercised end-to-end without an install.

| Status | Case | Result |
|--------|------|--------|
| ✅ PASS | `keys/license.key` (Hitachi) | Permanent, no expiry, signature **VALID**, exit 0 |
| ✅ PASS | `keys/ntpc-tn-license.key` (NTPC Tamilnadu) | Permanent, no expiry, signature **VALID**, exit 0 |
| ✅ PASS | tampered payload (`Hitachi`→`EvilCorp`) | signature **INVALID**, status UNTRUSTED, exit 2 |

RSA verification works on PowerShell 5.1: the PEM SubjectPublicKeyInfo is
unwrapped by a hand-written DER reader (`.NET Framework` has no
`ImportSubjectPublicKeyInfo`) and verified via `PROV_RSA_AES`, which is required
for SHA-256.

---

## Root-Cause Finding: the collector could never have worked

The most important result of this exercise is a defect found in the **previous**
Windows build, not a new one.

`fluent.conf` routes all four pipelines through `<match> @type opensearch`. That
plugin is provided by the `fluent-plugin-opensearch` gem. Enumerating the gem
inventory of both MSIs directly from their Windows Installer file tables:

| Gem | td-agent 4.5.2 (previous) | fluent-package 5.0.9 (now) |
|---|---|---|
| Ruby | **2.7.0** | **3.2.0** |
| `fluent-plugin-opensearch` | **ABSENT** | 1.1.4 |
| `opensearch-ruby` | **ABSENT** | 2.1.0 |
| `opensearch-transport` | **ABSENT** | 2.1.0 |
| `opensearch-api` | 2.2.0 | 2.2.0 |
| `fluent-plugin-elasticsearch` | 5.3.0 | 5.4.4 |
| `faraday` / `faraday-excon` / `faraday-net_http` | ABSENT | 2.7.12 / 2.1.0 / 3.0.2 |
| `excon` / `aws-sigv4` / `aws-partitions` / `aws-eventstream` | ABSENT | 0.104.0 / 1.6.0 / 1.785.0 / 1.2.0 |

td-agent 4.5.2 ships the **Elasticsearch** plugin, not the OpenSearch one. With
that runtime, `@type opensearch` fails to resolve, fluentd aborts at startup,
and `SupraLogCollector` dies immediately — **no log line could ever be indexed**.
The build script's comment asserting td-agent "ships fluent-plugin-opensearch
pre-installed" was simply incorrect.

Shipping the Linux gem closure as a fallback was evaluated and **rejected**:
`faraday-excon-2.4.0` and `faraday-net_http-3.4.2` declare
`required_ruby_version >= 3.0.0`, so they cannot be installed onto td-agent's
Ruby 2.7 at all.

**Resolution:** the Windows build now deploys `fluent-package 5.0.9` — the same
runtime the Linux installer uses. It is self-contained (Ruby 3.2 + the full
OpenSearch plugin chain), so no gem closure needs shipping, matching the Linux
installer's "provided by fluent-package; using its stack as-is" branch.

### Plugin coverage against the new runtime

| `@type` in fluent.conf | Uses | Provided by |
|---|---|---|
| `syslog` | 6 | fluentd core |
| `record_transformer` | 6 | fluentd core |
| `opensearch` | 4 | **fluent-plugin-opensearch 1.1.4** |
| `file` (buffer) | 4 | fluentd core |
| `json` (parse) | 2 | fluentd core |
| `udp`, `tcp`, `forward` | 1 each | fluentd core |

Every type resolves. `opensearch` is the only third-party plugin, and its full
dependency chain is present in the MSI.

---

## Other Defects Fixed in This Build

| Severity | Defect | Fix |
|---|---|---|
| High | `install.ps1` overwrote the packaged hardened `fluent.conf` with a hand-written minimal config (single `syslog/514` source, all logs into one `fluentd-*` index). Every per-source port, parser and index route was silently lost. | Deploys the packaged config verbatim; hash-verified |
| High | No index template on Windows. `supra-index-template.sh` is Linux-only, so field types were guessed and `400 - Rejected by OpenSearch` was inevitable. | Ported to `supra-index-template.ps1`, shipped and wired into post-install |
| High | License validator zip predated `RestSupraLicenseAction.java` / `LicenseInfo.java` by ~4.5 months, so `GET /_supra/license` was missing. | Rebuilt; build now auto-rebuilds when any `.java` is newer than the zip |
| High | POSIX buffer paths (`/opt/supra/...`) resolved drive-relative on Windows, placing up to 32 GB of buffer outside the install tree, outside the ACL grant and outside uninstall. Found by the runtime dry-run. | Rewritten to `<InstallPath>\log-collector\buffer\*`; directories pre-created; warns if any survive |
| Medium | `install-nxlog.ps1` rewrote `define SUPRA_SERVER_IP` lines that do not exist in `nxlog.conf` (which hardcodes `Host 172.20.98.8`), and defaulted to port 5140 instead of 1514. Endpoints would have shipped pointing at a stale build-time IP. | Rewrites the real `Host`/`Port` directives, defaults to 1514, aborts if substitution fails |
| Medium | Firewall opened UDP only; config binds UDP **and** TCP on 514/1514/2514, and 5140 was not opened at all. | 11 rules covering every listener |
| Medium | Uninstaller's firewall rule names never matched the installer's, orphaning rules on every uninstall. | Names aligned; legacy names also cleaned |
| Medium | Failed `fluentd --dry-run` was only a warning, so a broken config shipped a service that dies at boot. | Now fatal, matching Linux |
| Low | `Compress-Archive` buffers in memory; unusable at 1.4 GB. | Streaming store-only writer with spec-conformant `/` separators |
| Low | MSI's own `fluentdwinsvc` service would contend for the syslog ports. | Stopped and disabled during install |

---

## Full Installation — Not Performed

A complete install-and-revert was requested. It was **not run**, and no attempt
was made, for two independent blockers on the build host:

| Blocker | Detail |
|---|---|
| **Not elevated** | The session is not Administrator. `install.ps1` declares `#Requires -RunAsAdministrator` and needs elevation for `New-LocalUser`, `secedit` (Log-on-as-a-service), `msiexec`, NSSM service registration, `New-NetFirewallRule` and the machine `PATH`. Elevation needs interactive UAC consent, which is unavailable here. |
| **Disk headroom** | `C:` has **12.6 GB free**. Peak demand is roughly **6–7 GB**: extracted installer (1.4 GB) + OpenSearch (~1.6 GB) + Dashboards and 13 plugins (~1.7 GB) + transient `%TEMP%` staging (~1.6 GB, also on `C:`). Survivable but tight; exhausting the volume mid-install would leave services half-registered on the operator's workstation. |

A third constraint would apply even with the first two resolved: the license
validator binds to a hardware fingerprint, and neither bundled licence
(`Hitachi`, `NTPC Tamilnadu`) is issued for this host, so `SupraSearch` would
refuse to start. A host-specific test licence can be minted with
`license-generator/LicenseGenerator.java` and the repo private key — the same
approach `scripts/test/provision-license.sh` uses on Linux.

**Recommendation:** run the install on a disposable Windows Server 2019/2022 VM
or container, not on a workstation, so the revert is a snapshot rollback rather
than a dependency on `uninstall.ps1` being perfect.

---

## Not Covered — Required Before Sign-Off

These need a real Windows Server and **have not been verified**:

1. **`install.ps1` end-to-end** — service account creation, ACLs, `secedit`
   "Log on as a service" grant, NSSM registration, PATH mutation.
2. **Security initialization** — `securityadmin.bat`, and whether the demo
   certificate flow completes on Windows Server.
4. **Index template application** — `supra-index-template.ps1` against a live
   node, including its retry-until-Security-ready loop.
5. **End-to-end log flow** — a syslog datagram arriving on 514/1514/2514/5140
   and appearing in the matching `supra-*` index.
6. **License enforcement** — the plugin rejecting startup on a fingerprint
   mismatch, and `GET /_supra/license` responding on a running node.
7. **NXLog endpoint** — MSI install and JSON delivery over TCP/1514. *Note: the
   endpoint kit currently ships **without** an NXLog MSI; none was present at
   `nxlog\nxlog-ce-*.msi` at build time.*
8. **`uninstall.ps1`** — service removal, MSI uninstall, firewall/PATH cleanup.
9. **Windows Server specifically.** The build host is Windows 11 Pro; Server
   2019/2022 behaviour for `secedit`, `New-LocalUser` and NSSM is unverified.

---

## Known Gaps in the Artifact

- **NXLog CE MSI missing.** Endpoint kit ships config + installer script only.
  Place `nxlog\nxlog-ce-<version>.msi` and rebuild to include it.
- **Index Management plugin provenance.** Packaged from the existing
  `build/distributions` zip, built from submodule commit `7f268af3` — not the
  `4c5c9380` the repo pins. Rebuild if that distinction matters.
- **No PDF guide.** `wkhtmltopdf` is not installed on the build host; `.md`,
  `.html` and `.docx` are produced. Same situation as the Linux guide.
