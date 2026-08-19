# Supra SIEM — Windows Search Engine Will Not Start (Licence Fingerprint Mismatch)

**Field runbook | Version 3.6.0 | 13 August 2026**

Applies to a Windows installation of Supra SIEM 3.6.0 made with an installer
package built **before 13 August 2026 19:55** (SHA256 `0697a144…` or earlier),
where the licence is valid but the search engine never comes up.

Estimated time: **2 minutes.** No reinstall. No new licence key.

---

## 1. Symptoms

All three of these appear together, and only the first one is a real fault:

| Symptom | Where it appears |
|---|---|
| `nssm start SupraSearch` reports success, but nothing ever listens on 9200 | service never becomes usable |
| `ERR: Seems there is no OpenSearch running on localhost:9200 - Will exit` | `securityadmin` / `supra-init-security.ps1` |
| `attempt 1/60 : no response yet (cluster starting); retrying in 5s...` repeating to 60 | `supra-index-template.ps1` |

The second and third are consequences of the first. Fix the first and both clear.

The licence itself is **not** the problem. `supra-license-info.ps1` reports
`Overall status : ACTIVE` and `Signature : VALID`, and that report is accurate.

---

## 2. Cause

The licence validator plugin runs inside the search engine's Java process. On
Windows it cannot shell out to PowerShell or `wmic` to read the CPU ID,
motherboard serial and disk serial, so all three resolve to `UNKNOWN` and the
plugin hashes the constant string:

```
sha256("UNKNOWN|UNKNOWN|UNKNOWN") = 691659e84797cd7d3e22021da866ede3661a4c68538a73da2990c634b460e259
```

`get-fingerprint.ps1` — run by the operator, as an ordinary elevated script —
reads the real hardware and reports the true fingerprint. The vendor issues the
licence against that true value. The two never agree, so the plugin rejects the
licence and aborts node startup.

The Linux installer never had this problem: it writes a `machine-id` cache file
that the plugin reads in preference to computing the value itself. The Windows
installer did not write that file. **The fix is to create it.**

> **Note for the vendor:** because the plugin computed the same constant on
> every Windows host, any licence previously issued against a *Windows-reported*
> plugin fingerprint was not machine-bound at all. Reissue those against the
> fingerprint from `get-fingerprint.ps1`.

---

## 3. Before you start

- Open PowerShell **as Administrator**.
- The examples use the default install path `C:\supra`. If the site installed
  elsewhere, substitute that path throughout.
- Have this machine's fingerprint to hand. Print it with:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\get-fingerprint.ps1
```

It must match `Bound to machine` in the licence:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\supra-license-info.ps1
```

If those two do **not** match, stop — this runbook will not help, and the site
needs a licence reissued for the printed fingerprint.

---

## 4. Step 1 — Confirm the cause

```powershell
Select-String -Path C:\supra\opensearch\logs\supra*.log -Pattern "License" | Select-Object -Last 5
Get-Content C:\supra\opensearch\logs\search-stderr.log -Tail 20
```

Expected:

```
License validation failed: License fingerprint mismatch!
  Licensed for:  <the fingerprint your vendor licensed>
  This machine:  691659e84797cd7d3e22021da866ede3661a4c68538a73da2990c634b460e259
```

If instead the log says **`There is insufficient memory for the Java Runtime
Environment to continue`** or **`The paging file is too small for this operation
to complete`**, this is a different fault — go to section 9.

---

## 5. Step 2 — Stop the service

Repeated failed starts leave the service manager throttling restarts. In that
state a later `nssm start` reports success and does nothing, which is very
misleading. Always stop first.

```powershell
nssm stop SupraSearch
```

---

## 6. Step 3 — Write the fingerprint cache

Substitute the fingerprint printed in section 3.

```powershell
Set-Content -Path C:\supra\opensearch\config\supra-license\machine-id `
  -Value "PASTE-THE-64-CHARACTER-FINGERPRINT-HERE" `
  -NoNewline -Encoding ascii
```

> **`-Encoding ascii` is mandatory.** PowerShell 5.1's `utf8` option writes a
> byte-order mark, which the plugin's whitespace trim does not remove. The
> comparison would still fail and the symptom would look unchanged.

Verify the file is exactly 64 bytes:

```powershell
(Get-Item C:\supra\opensearch\config\supra-license\machine-id).Length
```

---

## 7. Step 4 — Start the search engine

```powershell
nssm start SupraSearch
Start-Sleep 60
Get-NetTCPConnection -LocalPort 9200 -State Listen
Select-String -Path C:\supra\opensearch\logs\supra*.log -Pattern "license" | Select-Object -Last 5
```

Success looks like this, and the port is listening:

```
[c.s.p.LicenseValidatorPlugin] [supra-node-1] Supra license validated successfully:
[c.s.p.LicenseValidatorPlugin] [supra-node-1]   Customer:    <customer>
[c.s.p.LicenseValidatorPlugin] [supra-node-1]   Tier:        standard
[c.s.p.LicenseValidatorPlugin] [supra-node-1]   Expires:     <date>
```

On a reference run the node bound port 9200 **49 seconds** after start. Allow up
to 2 minutes on slower hardware before concluding it has failed.

---

## 8. Step 5 — Security, index template, remaining services

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-init-security.ps1
```

### If that fails with `PKIX path building failed`

This is antivirus (Norton and similar) intercepting TLS on the loopback
interface and re-signing the node's certificate, so Java cannot build a trust
path to `root-ca.pem`. **In most cases it does not matter.** The node
initialises its own security index at first start. Check:

```powershell
curl.exe -sS -k -u admin:admin "https://localhost:9200/_cat/indices/.opendistro_security?v"
```

If the index exists with roughly 9 documents, security is initialised. Ignore
the error and continue. If it does not exist, exclude port 9200 from the
antivirus TLS/web shield and re-run `supra-init-security.ps1`.

### Then

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-index-template.ps1
nssm start SupraDashboards
nssm start SupraLogCollector
```

The index template must be applied **before** logs start flowing. Without it
field types are guessed, and the collector begins failing with
`400 - Rejected by OpenSearch` at the first type conflict.

---

## 9. If the log showed a memory or paging-file error instead

The installer sizes the Java heap at 50% of installed RAM. Windows must back the
entire heap with commit charge, so on a machine with a small page file the
process dies before the search engine loads anything:

```
Native memory allocation (mmap) failed to map 8396996608 bytes
The paging file is too small for this operation to complete (DOS error 1455)
```

Lower the heap:

```powershell
nssm stop SupraSearch
notepad C:\supra\opensearch\config\jvm.options
```

Set both values to something the machine can commit — 2 GB is ample for a pilot,
and a production server should stay at 50% of RAM but needs a page file large
enough to back it:

```
-Xms2g
-Xmx2g
```

Then:

```powershell
nssm start SupraSearch
```

---

## 10. Verification

```powershell
curl.exe -sS -k -u admin:admin "https://localhost:9200/_cluster/health?pretty"
curl.exe -sS -k -u admin:admin "https://localhost:9200/_supra/license?pretty"
curl.exe -sS -k -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v"
```

| Check | Expected |
|---|---|
| Cluster health | `"status" : "green"`, 1 node |
| Licence endpoint | `"status" : "ACTIVE"`, `"signature_verified" : true` |
| Dashboards | `http://localhost:5601` loads the login page; sign in as `admin` / `admin` |
| Indices | `supra-*` indices appear once devices start sending logs |

> **Use `curl.exe`, not `Invoke-RestMethod` or `Invoke-WebRequest`.** The node
> negotiates TLS 1.3, which PowerShell 5.1 (.NET Framework) does not support.
> Every PowerShell web call fails with *"The underlying connection was closed"*
> no matter what certificate or `SecurityProtocol` settings are applied. This is
> a limitation of the client, not a fault in the server.

An end-to-end test, if the site wants one before connecting devices — send five
syslog datagrams and confirm they are indexed:

```powershell
$udp = New-Object System.Net.Sockets.UdpClient
$msg = [Text.Encoding]::ASCII.GetBytes("<134>Aug 13 21:00:00 test-host SupraTest: end-to-end probe")
1..5 | ForEach-Object { [void]$udp.Send($msg, $msg.Length, "127.0.0.1", 514); Start-Sleep -Milliseconds 300 }
$udp.Close()
Start-Sleep 60
curl.exe -sS -k -u admin:admin "https://localhost:9200/_cat/indices/supra-ied-*?v"
```

`docs.count` should show the five documents.

---

## 11. Aftercare

The repaired machine still carries the older `get-fingerprint.ps1`, which has no
switch for writing the cache. **If its hardware changes** — motherboard, CPU or
the first disk — the cached fingerprint will no longer describe the machine.
Repeat sections 5 to 7 with the newly printed fingerprint.

Installer packages built from 13 August 2026 onward (SHA256 `b46d8ae0…` or
later) write this cache during installation, so a fresh install on a new machine
needs none of the above. Reinstalling an already-working machine is not
necessary to obtain this fix.

---

## 12. Quick reference

```powershell
# 1. confirm
Select-String -Path C:\supra\opensearch\logs\supra*.log -Pattern "License" | Select-Object -Last 5

# 2. stop
nssm stop SupraSearch

# 3. cache the fingerprint (64 chars, ascii, no newline)
Set-Content -Path C:\supra\opensearch\config\supra-license\machine-id `
  -Value "PASTE-THE-64-CHARACTER-FINGERPRINT-HERE" -NoNewline -Encoding ascii

# 4. start and confirm
nssm start SupraSearch
Start-Sleep 60
Get-NetTCPConnection -LocalPort 9200 -State Listen

# 5. finish the bring-up
powershell -ExecutionPolicy Bypass -File C:\supra\supra-init-security.ps1
powershell -ExecutionPolicy Bypass -File C:\supra\supra-index-template.ps1
nssm start SupraDashboards
nssm start SupraLogCollector
```
