# Supra SIEM Platform - Installation and User Guide (Windows)

**Version 3.6.0** | Windows Server x64 | Rev. August 2026

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Post-Installation Verification](#5-post-installation-verification)
6. [Forwarding Logs from Devices](#6-forwarding-logs-from-devices)
7. [Log Collector Configuration](#7-log-collector-configuration)
8. [Index Management](#8-index-management)
9. [Users and Roles](#9-users-and-roles)
10. [Dashboards Setup](#10-dashboards-setup)
11. [Alerts and Notifications](#11-alerts-and-notifications)
12. [Service Management](#12-service-management)
13. [Backup and Restore](#13-backup-and-restore)
14. [Troubleshooting](#14-troubleshooting)
15. [Appendix](#15-appendix)

---

## 1. Overview

The Supra SIEM platform collects, indexes, searches and alerts on log data from
network devices, servers and IEDs. On Windows it is delivered as a single
self-contained zip that installs three Windows Services:

| Service | Display name | Purpose |
|---|---|---|
| `SupraSearch` | Supra Search Engine | Indexes and stores log data (OpenSearch) |
| `SupraDashboards` | Supra Dashboards | Web UI for search, dashboards, alerting |
| `SupraLogCollector` | Supra Log Collector | Receives syslog/JSON and ships it to the search engine (Fluentd) |

All three run under NSSM (Non-Sucking Service Manager), which is installed to
`C:\supra\nssm` and added to the system PATH.

The installer is **fully offline**. Every component — the search engine, the
dashboards, all plugins, the Fluentd runtime (fluent-package MSI) and NSSM — is
bundled inside the zip. The target server needs no internet access.

---

## 2. Architecture

```
   Network devices          Windows endpoints         Linux servers        IEDs
   (Cisco, Juniper,          (NXLog agent)             (rsyslog)        (IEC 61850)
    Palo Alto, Fortinet)
          |                        |                       |                |
   syslog | udp+tcp/2514    JSON   | tcp/1514      syslog  | udp+tcp/5140   | udp+tcp/514
          |                        |                       |                |
          +------------------------+-----------+-----------+----------------+
                                               |
                                   +-----------v-----------+
                                   |  Supra Log Collector  |   C:\supra\log-collector
                                   |      (Fluentd)        |   fluent.conf
                                   +-----------+-----------+
                                               | https/9200
                                   +-----------v-----------+
                                   |  Supra Search Engine  |   C:\supra\opensearch
                                   |     (OpenSearch)      |   + license validator plugin
                                   +-----------+-----------+
                                               | https/9200
                                   +-----------v-----------+
                                   |   Supra Dashboards    |   C:\supra\dashboards
                                   |    (Web UI :5601)     |
                                   +-----------------------+
```

Each source type lands on its own port and is routed to its own index prefix,
so a malformed IED message can never corrupt the Windows event mappings:

| Source | Port | Index prefix |
|---|---|---|
| IED devices (IEC 61850) | udp+tcp/514 | `supra-ied-*` |
| Windows endpoints (NXLog, JSON) | udp+tcp/1514 | `supra-windows-*` |
| Network devices (routers, switches, firewalls) | udp+tcp/2514 | `supra-network-*` |
| Linux servers (rsyslog) | udp+tcp/5140 | `supra-logs-*` |
| Fluentd / Fluent Bit agents | tcp/24224 | routed by tag |

---

## 3. Prerequisites

### Hardware Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16–32 GB |
| Disk | 100 GB SSD | 500 GB+ SSD |
| Network | 1 Gbps | 1 Gbps |

The installer sets the JVM heap to 50% of physical RAM, capped at 8 GB.

### Software Requirements

- Windows Server 2019 or 2022 (x64). Windows 10/11 Pro x64 works for testing.
- PowerShell 5.1 or later (ships with Windows Server 2016+).
- Administrator rights.
- **No JDK required** — the search engine ships with its own bundled JDK.
- **No internet required** on the target server.

### Pre-Install Checks

Run these on the target server before installing:

```powershell
# Confirm you are Administrator
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Confirm nothing already holds the ports the collector needs
Get-NetTCPConnection -LocalPort 9200,5601,514,1514,2514,5140,24224 -ErrorAction SilentlyContinue
Get-NetUDPEndpoint  -LocalPort 514,1514,2514,5140 -ErrorAction SilentlyContinue

# Confirm free disk space on the target drive
Get-PSDrive C | Select-Object Used,Free
```

> **Note on port 514:** unlike Linux, Windows has no privileged-port restriction
> and no rsyslog competing for `:514`. If something *is* already bound there it
> is usually a third-party syslog daemon — stop it before installing.

---

## 4. Installation

### Step 1: Transfer the Installer

Copy `supra-installer-3.6.0-windows-x64.zip` to the target server, then verify
the transfer against the published checksum:

```powershell
(Get-FileHash .\supra-installer-3.6.0-windows-x64.zip -Algorithm SHA256).Hash.ToLower()
# Compare with the contents of supra-installer-3.6.0-windows-x64.zip.sha256
```

### Step 2: Extract

```powershell
Expand-Archive -Path .\supra-installer-3.6.0-windows-x64.zip -DestinationPath C:\ -Force
```

This produces `C:\supra-installer\`.

### Step 3: Run the Installer

Open PowerShell **as Administrator**:

```powershell
cd C:\supra-installer
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

To install somewhere other than `C:\supra`:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallPath D:\supra
```

> **`-ExecutionPolicy Bypass` is required.** A stock Windows Server refuses to
> run unsigned scripts, and `install.ps1` cannot lift that restriction before it
> has been allowed to start. Without it you get:
> `File ...install.ps1 cannot be loaded because running scripts is disabled on
> this system`. The same applies to every Supra script below. If the zip was
> downloaded or copied from a network share, also run
> `Unblock-File -Path supra-installer-*.zip` **before** extracting, so the files
> are not tagged as coming from the internet.
>
> The installer relaxes the machine policy to `RemoteSigned` for later runs, but
> cannot do so for its own launch.

> **Paths below use the `C:\supra` default.** If you installed elsewhere,
> substitute your `-InstallPath` everywhere. The installer prints every command
> with the correct paths for your install when it finishes — copy them from
> there rather than from this guide.

The installer will:

1. Create the `SupraService` local account and grant it "Log on as a service".
2. Install NSSM to `<InstallPath>\nssm` and add it to the system PATH.
3. Extract the search engine, generate demo TLS certificates, and reset the
   admin password to the default.
4. Install the Supra License Validator plugin and the custom Index Management plugin.
5. Extract the dashboards and install all 13 dashboards plugins.
6. Install the Fluentd runtime from the bundled fluent-package MSI (to `C:\opt\fluent`).
7. Deploy the hardened `fluent.conf` and validate it with a dry run.
8. Register the three Windows Services and open the firewall ports.

Expect 10–25 minutes depending on disk speed. The installer prints a timing
summary when it finishes.

> The installer does **not** start the services. Licensing comes first.

### Step 4: License Activation

```powershell
# 1. Get this machine's fingerprint (MFP)
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\get-fingerprint.ps1

# 2. Send the MFP to your Supra vendor and receive license.key in return.

# 3. Install the license
Copy-Item .\license.key -Destination C:\supra\opensearch\config\supra-license\

# 4. Confirm the license reads back as expected BEFORE starting the service
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\supra-license-info.ps1
```

The inspector prints the customer, license type (Permanent or Temporary),
validity window, tier, node/device limits, the machine it is bound to, and
whether the RSA signature is authentic:

```
==============================================
          Supra License Information
==============================================
  Customer        : NTPC Tamilnadu Energy Company Ltd
  License type    : Permanent (perpetual)
  Validity        : No expiry
  Issued on       : 2026-04-04
  Expires on      : 9999-12-31
  Tier            : enterprise
  Max nodes       : 999
  Bound to machine: 691659e8...460e259
  Signature       : VALID (signature authentic, not tampered)
  Overall status  : ACTIVE
==============================================
```

Exit code `0` means ACTIVE; `2` means EXPIRED or UNTRUSTED. **"Bound to machine"
must match the fingerprint from step 1**, or the search engine will refuse to start.

### Step 5: Start Services and Initialize Security

Open a **new** PowerShell window (so the updated PATH picks up `nssm` and the
`OPENSEARCH_JAVA_HOME` the installer sets):

```powershell
# Start the search engine first
nssm start SupraSearch

# Initialize the security index
powershell -ExecutionPolicy Bypass -File C:\supra\supra-init-security.ps1

# Start the dashboards
nssm start SupraDashboards
```

`supra-init-security.ps1` waits for the node to accept connections, then runs
`securityadmin.bat` with the bundled JDK and this installation's real paths. It
is safe to re-run.

> **Do not call `securityadmin.bat` directly.** It resolves the JVM only from
> `OPENSEARCH_JAVA_HOME` or `JAVA_HOME` and aborts with `Unable to find java
> runtime / OPENSEARCH_JAVA_HOME or JAVA_HOME must be defined` when neither is
> set in your shell. It also needs six absolute paths that change with
> `-InstallPath`. The wrapper handles both.
>
> If you must run it by hand, set the JDK first:
>
> ```powershell
> $env:OPENSEARCH_JAVA_HOME = 'C:\supra\opensearch\jdk'
> & 'C:\supra\opensearch\plugins\opensearch-security\tools\securityadmin.bat' `
>     -cd 'C:\supra\opensearch\config\opensearch-security\' `
>     -icl -nhnv `
>     -cacert 'C:\supra\opensearch\config\root-ca.pem' `
>     -cert   'C:\supra\opensearch\config\kirk.pem' `
>     -key    'C:\supra\opensearch\config\kirk-key.pem'
> ```

### Step 6: Apply the Index Template (Required)

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-index-template.ps1
```

This is not optional. It disables date/numeric type-guessing and maps every
dynamic field as `keyword`, which makes `400 - Rejected by OpenSearch` mapping
conflicts structurally impossible. Run it **before** logs start flowing. It
retries for up to five minutes while OpenSearch Security finishes initializing,
and is safe to re-run.

If you changed the admin password first:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-index-template.ps1 -OsPass 'YourNewPassword'
```

### Step 7: Start the Log Collector

```powershell
nssm start SupraLogCollector
```

### Default Credentials

| Field | Value |
|---|---|
| URL | `http://<server-ip>:5601` |
| Username | `admin` |
| Password | `admin` |

**Change the password before production use** — see [Section 9.1](#91-change-the-default-admin-password).

---

## 5. Post-Installation Verification

### 5.1 Check Services Are Running

```powershell
Get-Service SupraSearch, SupraDashboards, SupraLogCollector |
    Select-Object Name, Status, StartType
```

All three should report `Running` and `Automatic`.

### 5.2 Verify Search Engine Health

```powershell
curl.exe -sk -u admin:admin "https://localhost:9200/_cluster/health?pretty"
```

> **Use `curl.exe`, not `Invoke-RestMethod`.** The search engine negotiates
> TLS 1.3. PowerShell 5.1 runs on .NET Framework, which does not support TLS 1.3,
> so `Invoke-RestMethod` / `Invoke-WebRequest` fail with *"The underlying
> connection was closed"* no matter what `SecurityProtocol` or certificate
> callback you set. `curl.exe` uses Windows schannel, supports TLS 1.3, and ships
> with Windows Server 2019+ and Windows 10/11. `-k` skips validation of the
> self-signed demo certificate.

Expect `"status" : "green"` (or `"yellow"` on a single node before the template
sets `number_of_replicas: 0`).

### 5.3 Verify the License

```powershell
# From the CLI
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\supra-license-info.ps1

# Or from the running node, via the plugin's REST endpoint
curl.exe -sk -u admin:admin "https://localhost:9200/_supra/license?pretty"
```

The `GET /_supra/license` endpoint is new in this build — it returns the same
license details plus live device usage, and can be read from the Dashboards
Dev Tools console.

### 5.4 Verify the Index Template Was Applied

```powershell
curl.exe -sk -u admin:admin "https://localhost:9200/_index_template/supra-logs?pretty"
```

Confirm `date_detection: false` and the `everything_else_as_keyword` dynamic
template are present.

### 5.5 Verify the Collector Is Listening

```powershell
Get-NetUDPEndpoint -LocalPort 514,1514,2514,5140 | Select-Object LocalAddress,LocalPort
Get-NetTCPConnection -LocalPort 1514,2514,5140,24224 -State Listen | Select-Object LocalAddress,LocalPort
```

Send a test message and confirm it is indexed:

```powershell
# Send a test syslog datagram to the network-device port
$udp = New-Object System.Net.Sockets.UdpClient
$msg = [Text.Encoding]::ASCII.GetBytes("<14>Supra test message from $env:COMPUTERNAME")
$udp.Send($msg, $msg.Length, "127.0.0.1", 2514) | Out-Null
$udp.Close()

Start-Sleep -Seconds 15
curl.exe -sk -u admin:admin "https://localhost:9200/supra-network-*/_search?q=Supra+test&pretty"
```

### 5.6 Verify Logs Are Being Indexed

```powershell
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v"
```

You should see `supra-ied-*`, `supra-windows-*`, `supra-network-*` or
`supra-logs-*` indices appear as sources start reporting.

### 5.7 Access the Web UI

Browse to `http://<server-ip>:5601` and log in as `admin` / `admin`.

---

## 6. Forwarding Logs from Devices

Replace `<SUPRA_IP>` with the Supra server's address throughout.

### 6.1 Windows Endpoints (NXLog)

The installer bundles a self-contained endpoint kit at
`C:\supra-installer\nxlog-agent\`. Copy that folder to each Windows endpoint
and run, **as Administrator**:

```powershell
.\install-nxlog.ps1 -SupraServerIP <SUPRA_IP>
```

This installs NXLog CE offline from the bundled MSI, rewrites `nxlog.conf` to
point at your server, and starts the service. It forwards Security, System,
Application and PowerShell event logs as JSON over **TCP/1514**.

> The kit ships without an MSI unless one was placed at `nxlog\nxlog-ce-*.msi`
> at build time. Download NXLog CE from
> <https://nxlog.co/products/nxlog-community-edition/download> and re-run the
> build if `install-nxlog.ps1` reports the MSI is missing.

Verify on the endpoint:

```powershell
Get-Service nxlog
Get-Content 'C:\Program Files\nxlog\data\nxlog.log' -Tail 50
```

### 6.2 Cisco IOS / IOS-XE

```
configure terminal
 logging host <SUPRA_IP> transport udp port 2514
 logging trap informational
 logging source-interface GigabitEthernet0/0
 service timestamps log datetime msec localtime show-timezone
end
write memory
```

### 6.3 Cisco Nexus (NX-OS)

```
configure terminal
 logging server <SUPRA_IP> 6 port 2514
 logging timestamp milliseconds
end
copy running-config startup-config
```

### 6.4 Juniper (Junos)

```
set system syslog host <SUPRA_IP> any info
set system syslog host <SUPRA_IP> port 2514
set system syslog host <SUPRA_IP> source-address <DEVICE_IP>
commit
```

### 6.5 Palo Alto (PAN-OS)

Device → Server Profiles → Syslog → Add:
- Name `Supra`, Server `<SUPRA_IP>`, Transport `UDP`, Port `2514`, Format `BSD`

Then attach the profile under Device → Log Settings for System, Config and
Threat logs.

### 6.6 Fortinet FortiGate

```
config log syslogd setting
    set status enable
    set server "<SUPRA_IP>"
    set port 2514
    set facility local7
    set format default
end
```

### 6.7 Linux Servers (rsyslog)

```bash
# /etc/rsyslog.d/60-supra-forward.conf
*.*  @<SUPRA_IP>:5140      # UDP
# *.* @@<SUPRA_IP>:5140    # TCP - more reliable
```

```bash
sudo systemctl restart rsyslog
```

### 6.8 IED Devices (IEC 61850)

Point the device's syslog target at `<SUPRA_IP>` port **514**. Configuration
varies by vendor — consult the device manual. IED traffic is parsed by the
dedicated pipeline and lands in `supra-ied-*`.

### 6.9 VMware ESXi

```
esxcli system syslog config set --loghost='udp://<SUPRA_IP>:2514'
esxcli system syslog reload
esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true
```

---

## 7. Log Collector Configuration

### 7.1 Configuration File

`C:\supra\log-collector\fluent.conf` — deployed verbatim from the packaged
hardened config. It defines a dedicated source per device class, tags each
stream, normalizes timestamps to IST (+05:30), and routes to a matching index
prefix with an on-disk buffer.

After editing, always validate before restarting:

```powershell
& C:\opt\fluent\bin\fluentd.bat --dry-run -c C:\supra\log-collector\fluent.conf
nssm restart SupraLogCollector
```

The installer runs this same dry run automatically and warns if the config is
rejected.

### 7.2 Changing the Search Engine Password

The collector authenticates to the search engine with the credentials embedded
in `fluent.conf`. If you change the admin password, update all four `<match>`
blocks:

```powershell
(Get-Content C:\supra\log-collector\fluent.conf -Raw) `
    -replace '(?m)^(\s*password\s+).*$', '${1}YOUR_NEW_PASSWORD' |
    Set-Content C:\supra\log-collector\fluent.conf -Encoding UTF8

nssm restart SupraLogCollector
```

### 7.3 Collector Logs

```powershell
Get-Content C:\supra\log-collector\log-collector-stdout.log -Tail 50 -Wait
Get-Content C:\supra\log-collector\log-collector-stderr.log -Tail 50
```

---

## 8. Index Management

### 8.1 View Indices

```powershell
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v&s=index"
```

### 8.2 Create an Index Pattern (Required for Dashboards)

In the web UI: **Management → Dashboards Management → Index Patterns → Create**.

Create one per source type, using `@timestamp` as the time field:

- `supra-ied-*`
- `supra-windows-*`
- `supra-network-*`
- `supra-logs-*`

### 8.3 Retention Policy (Automatic Cleanup)

**Index Management → State Management Policies → Create policy**. A typical
90-day retention:

```json
{
  "policy": {
    "description": "Supra 90-day retention",
    "default_state": "hot",
    "states": [
      { "name": "hot",
        "actions": [],
        "transitions": [{ "state_name": "delete", "conditions": { "min_index_age": "90d" } }] },
      { "name": "delete", "actions": [{ "delete": {} }], "transitions": [] }
    ],
    "ism_template": [{ "index_patterns": ["supra-*"], "priority": 100 }]
  }
}
```

### 8.4 Re-applying the Index Template

The template only affects indices created **after** it is applied. Existing
badly-mapped indices keep their old mappings until they roll over (daily, with
`logstash_format`). To force it for today:

```powershell
# WARNING: deletes today's data for that source
curl.exe -sk -u admin:admin -X DELETE "https://localhost:9200/supra-windows-$(Get-Date -Format 'yyyy.MM.dd')"
```

---

## 9. Users and Roles

### 9.1 Change the Default Admin Password

1. Generate a new hash:

```powershell
& C:\supra\opensearch\plugins\opensearch-security\tools\hash.bat -p 'YourNewPassword'
```

2. Put the hash in `C:\supra\opensearch\config\opensearch-security\internal_users.yml`
   under `admin: hash:`.

3. Re-apply the security configuration:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-init-security.ps1
```

4. Update `fluent.conf` ([Section 7.2](#72-changing-the-search-engine-password))
   and restart the collector.

### 9.2 Create Roles and Users

Use **Security → Roles / Internal Users / Role Mappings** in the web UI.
Recommended baseline:

| Role | Index permissions | Use |
|---|---|---|
| `supra_readonly` | `read`, `search` on `supra-*` | Analysts |
| `supra_operator` | `read`, `write` on `supra-*` | Operations |
| `all_access` | everything | Administrators only |

Map every non-admin user to `opensearch_dashboards_user` as well, or the UI
will not load for them.

---

## 10. Dashboards Setup

1. **Discover** — ad-hoc search across an index pattern.
2. **Visualize** — build charts (top talkers, severity over time, event counts).
3. **Dashboard** — combine visualizations into a single view.

Recommended starting dashboards:

- **Security Overview** — failed logons, privilege escalation, account changes (`supra-windows-*`)
- **Network Operations** — interface flaps, BGP/OSPF events, config changes (`supra-network-*`)
- **IED Health** — protection events, communication loss (`supra-ied-*`)
- **Infrastructure** — service failures, disk and auth errors (`supra-logs-*`)

Export/import via **Dashboards Management → Saved Objects**.

---

## 11. Alerts and Notifications

1. **Notifications → Channels** — add an SMTP, Slack, or webhook channel.
2. **Alerting → Monitors → Create monitor** — define an extraction query or
   visual definition over a `supra-*` index pattern.
3. **Add trigger** — set the condition and severity, and attach the channel.

Useful starting monitors:

| Monitor | Condition |
|---|---|
| Brute force | > 10 failed logons from one source in 5 min |
| Collector down | 0 documents indexed in 15 min |
| Disk pressure | cluster health not `green` |
| IED comms loss | no events from an IED in 30 min |

---

## 12. Service Management

### Start / Stop / Restart

```powershell
nssm start   SupraSearch
nssm stop    SupraLogCollector
nssm restart SupraDashboards

# Native equivalents also work
Restart-Service SupraDashboards
```

Start order matters: `SupraSearch` first, then the other two (both declare a
service dependency on it, so Windows enforces this on boot).

### Status and Logs

```powershell
Get-Service Supra* | Format-Table Name, Status, StartType

Get-Content C:\supra\opensearch\logs\search-stderr.log -Tail 50
Get-Content C:\supra\dashboards\logs\dashboards-stderr.log -Tail 50
Get-Content C:\supra\log-collector\log-collector-stderr.log -Tail 50
```

The search engine also writes its own rotating logs to
`C:\supra\opensearch\logs\supra*.log`.

### Auto-Start on Boot

All three services are registered `SERVICE_AUTO_START`. To disable one:

```powershell
nssm set SupraLogCollector Start SERVICE_DEMAND_START
```

---

## 13. Backup and Restore

### 13.1 Register a Snapshot Repository

Add the backup path to `C:\supra\opensearch\config\opensearch.yml`:

```yaml
path.repo: ["D:\\supra-backups"]
```

Restart `SupraSearch`, then register it:

```powershell
$body = '{"type":"fs","settings":{"location":"D:\\supra-backups","compress":true}}'
$body | Out-File -Encoding ascii repo.json
curl.exe -sk -u admin:admin -X PUT "https://localhost:9200/_snapshot/supra_backup" `
    -H "Content-Type: application/json" -d "@repo.json"
```

### 13.2 Take a Snapshot

```powershell
$name = "snapshot-$(Get-Date -Format 'yyyy.MM.dd')"
curl.exe -sk -u admin:admin -X PUT "https://localhost:9200/_snapshot/supra_backup/${name}?wait_for_completion=true"
```

### 13.3 Restore

```powershell
curl.exe -sk -u admin:admin -X POST "https://localhost:9200/_snapshot/supra_backup/snapshot-2026.08.07/_restore"
```

### 13.4 Schedule a Nightly Snapshot

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument '-NoProfile -File C:\supra\backup-snapshot.ps1'
$trigger = New-ScheduledTaskTrigger -Daily -At 2am
Register-ScheduledTask -TaskName 'Supra Nightly Snapshot' -Action $action `
    -Trigger $trigger -User 'SYSTEM' -RunLevel Highest
```

Also back up `C:\supra\opensearch\config\` (including `supra-license\`) and
`C:\supra\log-collector\fluent.conf`.

---

## 14. Troubleshooting

### "running scripts is disabled on this system"

```
File C:\supra\supra-index-template.ps1 cannot be loaded because running scripts
is disabled on this system.
    + FullyQualifiedErrorId : UnauthorizedAccess
```

The machine's PowerShell execution policy blocks unsigned scripts. Run any Supra
script with an explicit bypass, which applies to that one process only:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-index-template.ps1
```

To allow scripts for future sessions (the installer does this automatically, but
Group Policy can override it):

```powershell
Get-ExecutionPolicy -List                                     # see which scope wins
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

If `Get-ExecutionPolicy -List` shows a value under `MachinePolicy` or
`UserPolicy`, it is enforced by Group Policy and cannot be changed locally —
keep using `-ExecutionPolicy Bypass`.

A related failure: scripts extracted from a zip that was downloaded or copied
from a network share carry a "came from the internet" tag, which `RemoteSigned`
rejects. Clear it with:

```powershell
Get-ChildItem C:\supra -Recurse -Include *.ps1 | Unblock-File
```

### "Unable to find java runtime" from securityadmin.bat

```
Unable to find java runtime
OPENSEARCH_JAVA_HOME or JAVA_HOME must be defined
```

`securityadmin.bat` resolves the JVM only from `OPENSEARCH_JAVA_HOME` or
`JAVA_HOME`. The services get it from NSSM, but an interactive shell does not,
so calling the batch file directly fails on a fresh install. Use the wrapper,
which points at the bundled JDK and fills in this installation's paths:

```powershell
powershell -ExecutionPolicy Bypass -File C:\supra\supra-init-security.ps1
```

If you installed outside `C:\supra`, the wrapper still works — it derives the
paths from its own location. Pass `-OsHome` only when running it from elsewhere:

```powershell
powershell -ExecutionPolicy Bypass -File D:\Syslog_Windows\supra-init-security.ps1 -OsHome D:\Syslog_Windows\opensearch
```

The installer also sets `OPENSEARCH_JAVA_HOME` at machine scope, so a **new**
terminal picks it up automatically. Verify with:

```powershell
[Environment]::GetEnvironmentVariable('OPENSEARCH_JAVA_HOME','Machine')
```

### "The term ... securityadmin.bat is not recognized"

The path does not exist — usually because the command was copied from this guide
(which shows the `C:\supra` default) onto a machine installed elsewhere. Use the
paths the installer printed when it finished, or just run
`supra-init-security.ps1`, which needs no paths at all.

### SupraSearch will not start

```powershell
Get-Content C:\supra\opensearch\logs\search-stderr.log -Tail 80
Get-ChildItem C:\supra\opensearch\logs\*.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 80
```

Common causes:

| Symptom in log | Cause | Fix |
|---|---|---|
| `License validation failed` | Missing/expired/wrong-machine license | Run `supra-license-info.ps1`; compare "Bound to machine" against `get-fingerprint.ps1` |
| `bind address already in use` | Something else on :9200 | `Get-NetTCPConnection -LocalPort 9200` |
| `Could not reserve enough space` | Heap larger than free RAM | Lower `-Xmx` in `config\jvm.options` |
| Service starts then stops | `AppDirectory` wrong | `nssm dump SupraSearch` |

### License errors on start-up

```powershell
# What this machine reports
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\get-fingerprint.ps1

# What the license was issued for
powershell -ExecutionPolicy Bypass -File C:\supra\opensearch\config\supra-license\supra-license-info.ps1
```

The two fingerprints must match exactly. They will differ if the server's
motherboard, CPU or first disk changed — request a re-issued license.

A `Signature : INVALID` result means the file was modified in transit or a
different public key is installed. Re-request the file; do not hand-edit it.

### Dashboards shows "OpenSearch unavailable"

```powershell
Get-Service SupraSearch
curl.exe -sk -u admin:admin "https://localhost:9200"
nssm restart SupraDashboards
```

If the search engine is healthy, the usual cause is a password mismatch between
`opensearch_dashboards.yml` and the security config.

### Log Collector will not start / dies immediately

```powershell
& C:\opt\fluent\bin\fluentd.bat --dry-run -c C:\supra\log-collector\fluent.conf
Get-Content C:\supra\log-collector\log-collector-stderr.log -Tail 50
```

A dry run that fails prints the offending line number. If it passes but the
service still dies, check that `C:\opt\fluent\bin\fluentd.bat` exists — a
failed MSI install leaves the folder present but empty.

### "400 - Rejected by OpenSearch" in the collector log

The index template was not applied, or was applied after the current index was
created. Run `C:\supra\supra-index-template.ps1`, then delete the affected
index (see [Section 8.4](#84-re-applying-the-index-template)).

### No logs appearing

Work outward from the collector:

```powershell
# 1. Is the collector listening?
Get-NetUDPEndpoint -LocalPort 514,1514,2514,5140

# 2. Is the firewall open?
Get-NetFirewallRule -DisplayName 'Supra Log Collector*' | Select-Object DisplayName, Enabled

# 3. Are packets arriving? (install Wireshark, or check the collector log)
Get-Content C:\supra\log-collector\log-collector-stdout.log -Tail 50 -Wait

# 4. Are documents being indexed?
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v"
```

If packets arrive but nothing indexes, the collector cannot authenticate to the
search engine — check the credentials in `fluent.conf`.

### Services disappear after deleting the installer folder

This was a bug in builds before 3.6.0, where NSSM registered services pointing
at the extracted installer folder. Current builds copy `nssm.exe` to
`C:\supra\nssm` first. If you hit it on an older install, run
`scripts\windows\fix-nssm-imagepath.ps1` or `repair-services.ps1`.

### High disk usage

```powershell
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v&s=store.size:desc"
```

Set up a retention policy ([Section 8.3](#83-retention-policy-automatic-cleanup))
rather than deleting indices by hand.

---

## 15. Appendix

### A. Default Ports

| Port | Protocol | Service | Purpose |
|---|---|---|---|
| 9200 | TCP | Supra Search Engine | REST API (HTTPS) |
| 5601 | TCP | Supra Dashboards | Web UI (HTTP) |
| 514 | UDP + TCP | Supra Log Collector | IED syslog |
| 1514 | UDP + TCP | Supra Log Collector | Windows JSON (NXLog) |
| 2514 | UDP + TCP | Supra Log Collector | Network device syslog |
| 5140 | UDP + TCP | Supra Log Collector | Linux rsyslog |
| 24224 | TCP | Supra Log Collector | Fluentd forward |

### B. File Locations

| Path | Contents |
|---|---|
| `C:\supra\opensearch\` | Search engine install |
| `C:\supra\opensearch\config\opensearch.yml` | Search engine config |
| `C:\supra\opensearch\config\jvm.options` | JVM heap settings |
| `C:\supra\opensearch\config\supra-license\` | License, public key, fingerprint + inspector tools |
| `C:\supra\opensearch\logs\` | Search engine logs |
| `C:\supra\dashboards\` | Dashboards install |
| `C:\supra\log-collector\fluent.conf` | Collector config |
| `C:\supra\supra-index-template.ps1` | Index template installer |
| `C:\supra\supra-init-security.ps1` | Security initializer (wraps securityadmin.bat) |
| `C:\supra\nssm\nssm.exe` | Service manager |
| `C:\opt\fluent\` | Fluentd runtime |

### C. Useful API Commands

All use `curl.exe` — see the note in [Section 5.2](#52-verify-search-engine-health)
for why `Invoke-RestMethod` cannot be used against this endpoint on PowerShell 5.1.
Replace `admin:admin` if you changed the password.

```powershell
# Cluster health
curl.exe -sk -u admin:admin "https://localhost:9200/_cluster/health?pretty"

# List indices by size
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/indices/supra-*?v&s=store.size:desc"

# Document count for one source
curl.exe -sk -u admin:admin "https://localhost:9200/supra-windows-*/_count?pretty"

# Search
curl.exe -sk -u admin:admin "https://localhost:9200/supra-*/_search?q=error&size=5&pretty"

# License details + live device usage
curl.exe -sk -u admin:admin "https://localhost:9200/_supra/license?pretty"

# Installed plugins
curl.exe -sk -u admin:admin "https://localhost:9200/_cat/plugins?v"
```

### D. Syslog Severity Levels

| Level | Name | Meaning |
|---|---|---|
| 0 | Emergency | System unusable |
| 1 | Alert | Immediate action required |
| 2 | Critical | Critical condition |
| 3 | Error | Error condition |
| 4 | Warning | Warning condition |
| 5 | Notice | Normal but significant |
| 6 | Informational | Informational message |
| 7 | Debug | Debug-level message |

### E. Uninstallation

```powershell
cd C:\supra-installer
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

This stops and removes the three services, removes the firewall rules,
uninstalls the Fluentd runtime, removes NSSM from the PATH, and clears the install
directory contents.

Not removed automatically:

```powershell
# The service account
Remove-LocalUser -Name SupraService

# The install directory itself
Remove-Item -Recurse -Force C:\supra
```

NXLog agents on remote endpoints are **not** touched. Uninstall each one there:

```powershell
msiexec /x nxlog-ce-<version>.msi /quiet
```

---

*Supra SIEM Platform | Installation and User Guide (Windows) | Version 3.6.0 | Rev. August 2026*
