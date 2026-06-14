# Supra SIEM Platform - Installation and User Guide

**Version:** 3.6.0
**Date:** June 2026
**Platform:** Ubuntu 22.04 LTS (jammy), x86_64 — fully offline installer

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Post-Installation Verification](#5-post-installation-verification)
6. [Syslog Configuration on Devices](#6-syslog-configuration-on-devices)
7. [Log Collector (Fluentd) Configuration](#7-log-collector-fluentd-configuration)
8. [Index Management](#8-index-management)
9. [Creating Users and Roles](#9-creating-users-and-roles)
10. [Dashboards Setup](#10-dashboards-setup)
11. [Alerts and Notifications](#11-alerts-and-notifications)
12. [Reports](#12-reports)
13. [Security Analytics (SIEM)](#13-security-analytics-siem)
14. [Service Management](#14-service-management)
15. [Backup and Restore](#15-backup-and-restore)
16. [Troubleshooting](#16-troubleshooting)
17. [Appendix](#17-appendix)

---

## 1. Overview

Supra SIEM is a centralized log management and security analytics platform built on:

| Component | systemd service | Purpose | Port |
|-----------|-----------------|---------|------|
| **Supra Search Engine** (OpenSearch 3.6.0 + Supra License Validator + Index Management) | `supra-search` | Log storage, indexing, search engine, license enforcement | 9200 (HTTPS) |
| **Supra Dashboards** (OpenSearch Dashboards + SIEM plugins) | `supra-dashboards` | Web UI for visualization, dashboards, alerts | 5601 (HTTP) |
| **Supra Log Collector** (fluent-package 5.0.9 + fluent-plugin-opensearch) | `supra-log-collector` | Receives syslog from devices and forwards to the search engine | 514 (syslog), 24224 (forward) |
| **Supra Index Template** (one-shot) | `supra-index-template` | Auto-applies the `supra-*` index template once the search engine is healthy | — |

**What it does:**
- Collects syslog from network devices (routers, switches, firewalls, IEDs, servers)
- Stores and indexes logs in OpenSearch
- Provides dashboards, alerts, reports, and security analytics via the web UI

---

## 2. Architecture

```
+------------------+     +------------------+     +------------------+
|  Network Devices |     |   Servers/Apps   |     |   IED Devices    |
|  (Routers, FW,   |     |  (Linux, Windows)|     |  (IEC 61850)     |
|   Switches)      |     |                  |     |                  |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         |    Syslog (UDP/TCP)    |     Syslog (UDP/TCP)   |
         |    Port 514           |     Port 514          |
         +----------+------------+----------+--------------+
                    |                       |
                    v                       v
           +--------+-----------------------+--------+
           |          Supra Log Collector             |
           |  (fluent-package 5.0.9 + opensearch out) |
           |  - Receives syslog on UDP/514            |
           |  - Receives forwarded logs on TCP/24224  |
           |  - Tags, enriches, ships to search       |
           +-------------------+----------------------+
                               |
                               | HTTPS (port 9200)
                               v
           +-------------------+----------------------+
           |           Supra Search Engine            |
           |       (OpenSearch + License Validator)   |
           |  - Indexes and stores logs               |
           |  - supra-index-template one-shot         |
           |    auto-applies the supra-* template     |
           |  - Full-text search + security analytics |
           +-------------------+----------------------+
                               |
                               v
           +-------------------+----------------------+
           |            Supra Dashboards              |
           |  - Web UI (port 5601)                    |
           |  - Dashboards & Visualizations           |
           |  - Alerts & Notifications                |
           |  - Reports & Security Analytics          |
           +------------------------------------------+
```

---

## 3. Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 cores | 8+ cores |
| RAM | 8 GB | 16+ GB |
| Disk | 100 GB | 500+ GB (SSD recommended) |
| Network | 1 Gbps | 1 Gbps |

### Software Requirements

- **Ubuntu 22.04 LTS (jammy), x86_64 only.** The installer is fully offline and the
  bundled `fluent-package` `.deb`s link against jammy library ABIs (`libssl3`,
  `libffi8`, `libreadline8`, `libncurses6`, `libtinfo6`, `libyaml-0-2`,
  `libgmp10`, `zlib1g`). `install.sh` enforces this and refuses to run on
  20.04/24.04/RHEL/CentOS or non-amd64.
- **No internet access required.** Everything ships in the tarball: OpenSearch,
  OpenSearch Dashboards, dashboards plugins, fluent-package, all of
  fluent-plugin-opensearch's pure-Ruby dependency gems, and the index-template
  bootstrap. Ruby is **not** a prerequisite — fluent-package brings its own
  embedded Ruby at `/opt/fluent/`.
- Root / sudo access.

### Network Requirements

Ensure the following ports are open on the Supra server:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 514 | UDP | Inbound | Syslog from devices |
| 24224 | TCP | Inbound | Fluentd forward protocol |
| 9200 | TCP | Localhost | Supra Search Engine API |
| 5601 | TCP | Inbound | Supra Dashboards Web UI |

### Firewall Rules (on the Supra server, Ubuntu 22.04 / ufw)

```bash
sudo ufw allow 514/udp comment "Supra syslog (UDP)"
sudo ufw allow 24224/tcp comment "Supra fluentd forward"
sudo ufw allow 5601/tcp comment "Supra Dashboards UI"
```

---

## 4. Installation

### Step 1: Transfer the Installer

Copy the installer tarball to the target server:

```bash
scp supra-installer-3.6.0-linux-x64.tar.gz user@<server-ip>:/tmp/
```

### Step 2: Extract the Installer

```bash
cd /tmp
tar -xzf supra-installer-3.6.0-linux-x64.tar.gz
```

### Step 3: Run the Installer

```bash
cd supra-installer
sudo bash install.sh
```

The installer will automatically:
1. Verify host OS is Ubuntu 22.04 jammy / amd64, and abort otherwise
2. Create a `supra` system user
3. Apply system tuning (`vm.max_map_count=262144`)
4. Install Supra Search Engine to `/opt/supra/opensearch`, install the Supra
   License Validator plugin, install the Index Management plugin
5. Initialize security certificates and default credentials (admin/admin)
6. Install Supra Dashboards to `/opt/supra/dashboards` with all SIEM plugins
7. Install **Supra Log Collector** fully offline:
   - Install jammy dependency libs from bundled `.deb`s
   - Install `fluent-package` 5.0.9 (embedded Ruby at `/opt/fluent/`)
   - Install `fluent-plugin-opensearch` from bundled `.gem`s (`--local --ignore-dependencies`)
   - Deploy the bundled `fluent.conf` to `/opt/supra/log-collector/`
   - Disable the stock `fluentd.service` shipped with fluent-package
8. Install the index-template bootstrap script to `/opt/supra/index-template/`
9. Install and **enable** (but do not start) four systemd services:
   `supra-search`, `supra-dashboards`, `supra-log-collector`, `supra-index-template`

> **Note:** Services are not started by the installer — license activation
> must happen first (Step 4). The `supra-index-template` one-shot will fire
> automatically as soon as `supra-search` is started and reports healthy on
> `:9200`.

### Step 4: License Activation

Activation is required before the search engine will accept queries.

```bash
# 1. Get this machine's fingerprint (MFP):
sudo bash /opt/supra/opensearch/config/supra-license/get-fingerprint.sh

# 2. Send the MFP to your Supra vendor and receive license.key in return.

# 3. Install the license:
sudo cp license.key /opt/supra/opensearch/config/supra-license/
sudo chown supra:supra /opt/supra/opensearch/config/supra-license/license.key
sudo chmod 600 /opt/supra/opensearch/config/supra-license/license.key
```

### Step 5: Start Services and Verify

```bash
# Start the search engine first
sudo systemctl start supra-search

# supra-index-template auto-fires once :9200 is healthy. To watch it:
journalctl -u supra-index-template -f

# Once supra-search is up, start the rest
sudo systemctl start supra-dashboards
sudo systemctl start supra-log-collector

# Verify
curl -sk -u admin:admin https://localhost:9200
curl -s -o /dev/null -w "%{http_code}" http://localhost:5601
sudo systemctl status supra-search supra-dashboards supra-log-collector supra-index-template
```

### Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| OpenSearch / Dashboards | `admin` | `admin` |

> **IMPORTANT:** Change the default password immediately after installation. See [Section 9](#9-creating-users-and-roles).

---

## 5. Post-Installation Verification

### 5.1 Access the Web UI

Open a browser and navigate to:

```
http://<server-ip>:5601
```

Login with `admin` / `admin`.

### 5.2 Verify OpenSearch Health

```bash
curl -sk -u admin:admin https://localhost:9200/_cluster/health?pretty
```

Expected output should show `"status": "green"` or `"yellow"` (yellow is normal for single-node).

### 5.3 Verify Log Collector is Running

```bash
sudo systemctl status supra-log-collector

# Test syslog reception (UDP/514 is privileged - logger needs sudo)
sudo logger -n 127.0.0.1 -P 514 -d "Test syslog message from Supra"
```

### 5.4 Verify the Index Template Has Been Applied

The `supra-index-template` one-shot installs an index template named
`supra-logs` covering all `supra-*` indices. This is what prevents the
"400 - Rejected by OpenSearch" mapping conflicts from heterogeneous syslog.

```bash
# Confirm it ran cleanly
journalctl -u supra-index-template --no-pager | tail -20

# Inspect the template itself
curl -sk -u admin:admin https://localhost:9200/_index_template/supra-logs?pretty
```

### 5.5 Verify Logs are Being Indexed

```bash
# Check for supra-logs indices
curl -sk -u admin:admin https://localhost:9200/_cat/indices?v
```

You should see indices like `supra-logs-YYYY.MM.DD`.

---

## 6. Syslog Configuration on Devices

Configure your network devices, servers, and applications to send syslog to the Supra server on **port 514 (UDP)**.

### 6.1 Cisco Routers and Switches (IOS/IOS-XE)

```
configure terminal
logging host <SUPRA_SERVER_IP> transport udp port 514
logging trap informational
logging facility local7
logging source-interface Loopback0
logging on
end
write memory
```

**Verify:**
```
show logging
```

### 6.2 Cisco Nexus Switches (NX-OS)

```
configure terminal
logging server <SUPRA_SERVER_IP> 6 port 514 facility local7
logging source-interface loopback0
logging timestamp milliseconds
end
copy running-config startup-config
```

### 6.3 Juniper Routers and Switches (Junos)

```
set system syslog host <SUPRA_SERVER_IP> port 514
set system syslog host <SUPRA_SERVER_IP> any info
set system syslog host <SUPRA_SERVER_IP> authorization any
set system syslog host <SUPRA_SERVER_IP> firewall any
set system syslog host <SUPRA_SERVER_IP> interactive-commands any
commit
```

**Verify:**
```
show system syslog
```

### 6.4 Palo Alto Firewalls (PAN-OS)

1. Navigate to **Device > Server Profiles > Syslog**
2. Click **Add** and configure:
   - **Name:** `Supra-SIEM`
   - **Syslog Server:** `<SUPRA_SERVER_IP>`
   - **Transport:** `UDP`
   - **Port:** `514`
   - **Facility:** `LOG_LOCAL7`
3. Navigate to **Objects > Log Forwarding** and create a profile using the syslog server
4. Apply the log forwarding profile to security rules under **Policies > Security**
5. **Commit** the changes

### 6.5 Fortinet FortiGate Firewalls

```
config log syslogd setting
    set status enable
    set server "<SUPRA_SERVER_IP>"
    set port 514
    set facility local7
    set source-ip ""
    set format default
end
```

**Verify:**
```
diagnose log test
get log syslogd setting
```

### 6.6 Linux Servers (rsyslog)

Edit `/etc/rsyslog.conf` or create `/etc/rsyslog.d/supra.conf`:

```bash
# Send all logs to Supra via UDP
*.* @<SUPRA_SERVER_IP>:514

# Or via TCP (more reliable)
*.* @@<SUPRA_SERVER_IP>:514
```

Restart rsyslog:

```bash
sudo systemctl restart rsyslog
```

**Verify:**
```bash
logger "Test message to Supra SIEM"
```

### 6.7 Linux Servers (syslog-ng)

Edit `/etc/syslog-ng/syslog-ng.conf`:

```
destination d_supra {
    network("<SUPRA_SERVER_IP>" port(514) transport("udp"));
};

log {
    source(s_sys);
    destination(d_supra);
};
```

Restart syslog-ng:
```bash
sudo systemctl restart syslog-ng
```

### 6.8 Windows Servers

Windows does not natively support syslog. Use one of these agents:

**Option A: NXLog (Recommended)**

1. Download and install NXLog Community Edition
2. Edit `C:\Program Files\nxlog\conf\nxlog.conf`:

```xml
<Input in_eventlog>
    Module      im_msvistalog
    Query       <QueryList><Query Id="0"><Select Path="Security">*</Select>\
                <Select Path="System">*</Select>\
                <Select Path="Application">*</Select></Query></QueryList>
</Input>

<Output out_supra>
    Module      om_udp
    Host        <SUPRA_SERVER_IP>
    Port        514
    Exec        to_syslog_bsd();
</Output>

<Route supra_route>
    Path        in_eventlog => out_supra
</Route>
```

3. Restart the NXLog service

**Option B: Snare Agent**

1. Download and install Snare for Windows
2. Configure the syslog destination: `<SUPRA_SERVER_IP>:514` (UDP)
3. Select event log sources (Security, System, Application)

### 6.9 IED Devices (Intelligent Electronic Devices - IEC 61850)

IED configuration varies by manufacturer. General steps:

**ABB REL670 / REB670:**
1. Access the IED via PCM600 engineering tool
2. Navigate to **Communication > Syslog**
3. Set **Syslog Server IP:** `<SUPRA_SERVER_IP>`
4. Set **Syslog Port:** `514`
5. Set **Severity Level:** `Informational`
6. Download configuration to IED

**Siemens SIPROTEC 5:**
1. Open DIGSI 5 engineering tool
2. Navigate to **Communication > Syslog Client**
3. Configure:
   - Server Address: `<SUPRA_SERVER_IP>`
   - Server Port: `514`
   - Protocol: UDP
4. Transfer settings to device

**SEL (Schweitzer Engineering Laboratories):**
1. Connect via SEL terminal (serial or network)
2. Configure syslog:
```
SET SYSLOG_IP1 <SUPRA_SERVER_IP>
SET SYSLOG_PORT1 514
SET SYSLOG_SEV INFO
```

**GE Multilin:**
1. Access via EnerVista software
2. Navigate to **Settings > Communications > Syslog**
3. Set Server IP and Port (514)

> **Note:** If the IED does not support syslog natively, use a gateway/relay server running rsyslog to collect IED logs (serial, GOOSE, MMS) and forward them to Supra.

### 6.10 HP/Aruba Switches

```
logging <SUPRA_SERVER_IP> transport udp 514
logging severity info
logging facility local7
```

### 6.11 VMware ESXi

```bash
esxcli system syslog config set --loghost='udp://<SUPRA_SERVER_IP>:514'
esxcli system syslog reload
```

**Verify:**
```bash
esxcli system syslog config get
```

---

## 7. Log Collector (Fluentd) Configuration

The log collector is shipped as `fluent-package` 5.0.9, with its own embedded
Ruby and binaries under `/opt/fluent/`. The systemd unit invokes it as:

```
/opt/fluent/bin/fluentd -c /opt/supra/log-collector/fluent.conf
```

The configuration file lives at:

```
/opt/supra/log-collector/fluent.conf
```

> **Air-gapped install — read this before editing.** Do **not** run
> `gem install ...` to add plugins on a deployed box. The server has no
> internet access. If you need an extra Fluentd plugin, build the bundle
> on a build host (`fluent-gem fetch <plugin>`), copy the resulting `.gem`s
> to the target, and install with:
> ```bash
> sudo /opt/fluent/bin/fluent-gem install --local --ignore-dependencies *.gem
> sudo systemctl restart supra-log-collector
> ```

### 7.1 Default Configuration

The installer deploys this config (lightly trimmed for the guide; see the
real file on disk for full debug/enrichment blocks):

```
<system>
  log_level info
</system>

# Syslog input (UDP/514) - all devices and NXLog agents land here.
<source>
  @type syslog
  port 514
  bind 0.0.0.0
  tag syslog
  <parse>
    message_format auto
  </parse>
</source>

# Forward input (TCP/24224) - from other Fluentd / fluent-bit agents.
<source>
  @type forward
  port 24224
  bind 0.0.0.0
</source>

# Tag every syslog message with the collector identity.
<filter syslog.**>
  @type record_transformer
  <record>
    log_collector "supra"
  </record>
</filter>

# Ship everything to the Supra search engine.
<match **>
  @type copy
  <store>
    @type opensearch
    host localhost
    port 9200
    scheme https
    ssl_verify false
    user admin
    password admin
    logstash_format true
    logstash_prefix supra-logs
    include_tag_key true
    tag_key fluentd_tag
    flush_interval 5s
    <buffer>
      @type memory
      flush_mode interval
      flush_interval 5s
      retry_max_interval 30s
      retry_forever true
      chunk_limit_size 4MB
      queue_limit_length 64
    </buffer>
  </store>
</match>
```

Daily indices land at `supra-logs-YYYY.MM.DD` and inherit the `supra-logs`
index template applied by `supra-index-template.service` (date detection off,
keyword by default, `ignore_malformed: true`).

### 7.2 Advanced: Separate Indices per Device Type

To create separate indices for different device types, update the Fluentd config:

```xml
# Syslog input with facility-based tagging
<source>
  @type syslog
  port 514
  tag syslog
  <parse>
    message_format auto
  </parse>
</source>

# Tag logs by source IP for device identification
<match syslog.**>
  @type rewrite_tag_filter
  <rule>
    key source
    pattern /^10\.1\.1\./
    tag device.router
  </rule>
  <rule>
    key source
    pattern /^10\.1\.2\./
    tag device.switch
  </rule>
  <rule>
    key source
    pattern /^10\.1\.3\./
    tag device.firewall
  </rule>
  <rule>
    key source
    pattern /^10\.1\.4\./
    tag device.ied
  </rule>
  <rule>
    key source
    pattern /.+/
    tag device.other
  </rule>
</match>

# Router logs
<match device.router>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix router-logs
  flush_interval 10s
</match>

# Switch logs
<match device.switch>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix switch-logs
  flush_interval 10s
</match>

# Firewall logs
<match device.firewall>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix firewall-logs
  flush_interval 10s
</match>

# IED logs
<match device.ied>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix ied-logs
  flush_interval 10s
</match>

# All other logs
<match device.other>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix other-logs
  flush_interval 10s
</match>
```

The `fluent-plugin-rewrite-tag-filter` plugin is required for the example
above. On an air-gapped server it must be staged from `.gem`s, not pulled
from rubygems.org:

```bash
# On a build host with internet:
/opt/fluent/bin/fluent-gem fetch fluent-plugin-rewrite-tag-filter
# (also fetch any dependency .gem files it reports)

# Then copy the .gem(s) to the target server and install offline:
sudo /opt/fluent/bin/fluent-gem install --local --ignore-dependencies *.gem
```

After any config change:
```bash
sudo systemctl restart supra-log-collector
```

### 7.3 Enable TCP Syslog (in addition to UDP)

```xml
<source>
  @type syslog
  port 514
  protocol_type udp
  tag syslog.udp
</source>

<source>
  @type syslog
  port 514
  protocol_type tcp
  tag syslog.tcp
</source>
```

---

## 8. Index Management

### 8.1 View Indices

**Via Dashboards UI:**
1. Go to **Menu > Index Management > Indices**

**Via API:**
```bash
curl -sk -u admin:admin https://localhost:9200/_cat/indices?v&s=index
```

### 8.2 Create an Index Pattern (Required for Dashboards)

1. Go to **Menu > Stack Management > Index Patterns**
2. Click **Create index pattern**
3. Enter the pattern: `supra-logs-*` (or `router-logs-*`, `firewall-logs-*`, etc.)
4. Select `@timestamp` as the time field
5. Click **Create index pattern**

Repeat for each log type if using separate indices.

### 8.3 Index Lifecycle Policy (Automatic Cleanup)

Create a policy to automatically delete old logs:

1. Go to **Menu > Index Management > Index Policies**
2. Click **Create Policy**
3. Use this JSON policy (keeps logs for 90 days):

```json
{
  "policy": {
    "description": "Delete logs older than 90 days",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": {
              "min_index_age": "90d"
            }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [
          {
            "delete": {}
          }
        ],
        "transitions": []
      }
    ],
    "ism_template": [
      {
        "index_patterns": ["supra-logs-*"],
        "priority": 100
      }
    ]
  }
}
```

**Via API:**
```bash
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_plugins/_ism/policies/delete-after-90d \
  -H "Content-Type: application/json" \
  -d '{
    "policy": {
      "description": "Delete logs older than 90 days",
      "default_state": "hot",
      "states": [
        {
          "name": "hot",
          "actions": [],
          "transitions": [
            {
              "state_name": "delete",
              "conditions": { "min_index_age": "90d" }
            }
          ]
        },
        {
          "name": "delete",
          "actions": [{ "delete": {} }],
          "transitions": []
        }
      ],
      "ism_template": [
        { "index_patterns": ["supra-logs-*"], "priority": 100 }
      ]
    }
  }'
```

### 8.4 Index Templates

Create a template to control how new indices are configured:

```bash
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_index_template/syslog-template \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns": ["supra-logs-*", "router-logs-*", "switch-logs-*", "firewall-logs-*", "ied-logs-*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 0
      },
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "host": { "type": "keyword" },
          "ident": { "type": "keyword" },
          "message": { "type": "text" },
          "pid": { "type": "keyword" },
          "priority": { "type": "keyword" },
          "facility": { "type": "keyword" },
          "severity": { "type": "keyword" }
        }
      }
    }
  }'
```

---

## 9. Creating Users and Roles

### 9.1 Change the Default Admin Password

**Step 1:** Generate a password hash:
```bash
sudo /opt/supra/opensearch/plugins/opensearch-security/tools/hash.sh -p YOUR_NEW_PASSWORD
```

**Step 2:** Edit the internal users file:
```bash
sudo nano /opt/supra/opensearch/config/opensearch-security/internal_users.yml
```

Replace the `hash` value under the `admin` user with the new hash.

**Step 3:** Apply the changes:
```bash
export OPENSEARCH_JAVA_HOME=/opt/supra/opensearch/jdk
sudo -u supra $OPENSEARCH_JAVA_HOME/bin/java -cp "/opt/supra/opensearch/plugins/opensearch-security/*" \
  /opt/supra/opensearch/plugins/opensearch-security/tools/securityadmin.sh \
  -f /opt/supra/opensearch/config/opensearch-security/internal_users.yml \
  -t internalusers -icl -nhnv \
  -cacert /opt/supra/opensearch/config/root-ca.pem \
  -cert /opt/supra/opensearch/config/kirk.pem \
  -key /opt/supra/opensearch/config/kirk-key.pem
```

**Step 4:** Update the Log Collector config with the new password:
```bash
sudo nano /opt/supra/log-collector/fluent.conf
# Change: password admin -> password YOUR_NEW_PASSWORD
sudo systemctl restart supra-log-collector
```

**Step 5:** Update the index-template service environment with the new password
so the one-shot can still authenticate on re-runs:
```bash
sudo systemctl edit supra-index-template.service
# In the override, add:
#   [Service]
#   Environment=OS_PASS=YOUR_NEW_PASSWORD
sudo systemctl daemon-reload
```

### 9.2 Create a New Role

**Via Dashboards UI:**

1. Go to **Menu > Security > Roles**
2. Click **Create role**
3. Configure:

| Field | Example for "SOC Analyst" |
|-------|---------------------------|
| Role name | `soc_analyst` |
| Cluster permissions | `cluster_monitor` |
| Index patterns | `supra-logs-*`, `firewall-logs-*`, `router-logs-*` |
| Index permissions | `read`, `search` |
| Tenant permissions | Global (Read Only) |

4. Click **Create**

**Via API:**
```bash
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_plugins/_security/api/roles/soc_analyst \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_permissions": ["cluster_monitor"],
    "index_permissions": [
      {
        "index_patterns": ["supra-logs-*", "firewall-logs-*", "router-logs-*", "switch-logs-*", "ied-logs-*"],
        "allowed_actions": ["read", "search"]
      }
    ],
    "tenant_permissions": [
      {
        "tenant_patterns": ["global_tenant"],
        "allowed_actions": ["kibana_all_read"]
      }
    ]
  }'
```

### 9.3 Create a New User

**Via Dashboards UI:**

1. Go to **Menu > Security > Internal Users**
2. Click **Create internal user**
3. Fill in:
   - **Username:** `john.doe`
   - **Password:** (set a strong password)
4. Click **Create**

**Via API:**
```bash
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_plugins/_security/api/internalusers/john.doe \
  -H "Content-Type: application/json" \
  -d '{
    "password": "SecureP@ssw0rd!",
    "backend_roles": [],
    "attributes": {
      "department": "SOC",
      "full_name": "John Doe"
    }
  }'
```

### 9.4 Map User to Role

**Via Dashboards UI:**

1. Go to **Menu > Security > Roles**
2. Click on `soc_analyst`
3. Go to the **Mapped users** tab
4. Click **Map users**
5. Add `john.doe` under **Users**
6. Click **Map**

Also map the user to `opensearch_dashboards_user` role so they can access the UI:

1. Go to **Roles > opensearch_dashboards_user > Mapped users**
2. Map `john.doe`

**Via API:**
```bash
# Map to custom role
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_plugins/_security/api/rolesmapping/soc_analyst \
  -H "Content-Type: application/json" \
  -d '{ "users": ["john.doe"] }'

# Map to dashboards access role
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_plugins/_security/api/rolesmapping/opensearch_dashboards_user \
  -H "Content-Type: application/json" \
  -d '{ "users": ["john.doe"] }'
```

### 9.5 Recommended Roles

| Role | Cluster Permissions | Index Permissions | Use Case |
|------|--------------------|--------------------|----------|
| `soc_analyst` | `cluster_monitor` | `read`, `search` on all log indices | Read-only log analysis |
| `soc_manager` | `cluster_monitor` | `read`, `search`, `crud` on all log indices | Log analysis + manage saved objects |
| `admin_full` | `*` (all) | `*` on `*` | Full admin access |
| `report_viewer` | `cluster_monitor` | `read` on all log indices | View dashboards and reports only |
| `device_admin` | `cluster_monitor` | `read`, `search` on specific device indices | Per-device-type access |

---

## 10. Dashboards Setup

### 10.1 Create Visualizations

1. Go to **Menu > Visualize**
2. Click **Create visualization**
3. Select a visualization type:

**Example 1: Log Volume Over Time (Area Chart)**
- Type: **Area**
- Index pattern: `supra-logs-*`
- Y-axis: Count
- X-axis: Date Histogram on `@timestamp` (interval: hourly)
- Save as: "Log Volume Over Time"

**Example 2: Top Log Sources (Pie Chart)**
- Type: **Pie**
- Index pattern: `supra-logs-*`
- Slice: Terms aggregation on `host` (size: 10)
- Save as: "Top Log Sources"

**Example 3: Severity Distribution (Bar Chart)**
- Type: **Vertical Bar**
- Index pattern: `supra-logs-*`
- Y-axis: Count
- X-axis: Terms on `severity` or `priority`
- Save as: "Log Severity Distribution"

**Example 4: Recent Logs Table**
- Type: **Data Table**
- Index pattern: `supra-logs-*`
- Columns: `@timestamp`, `host`, `ident`, `severity`, `message`
- Save as: "Recent Log Events"

### 10.2 Create a Dashboard

1. Go to **Menu > Dashboard**
2. Click **Create new dashboard**
3. Click **Add** and select the visualizations created above
4. Arrange the panels as needed
5. Add time filter (top right) to set the default time range
6. Click **Save** and name it: "Supra SIEM Overview"

### 10.3 Recommended Dashboards

| Dashboard | Visualizations to Include |
|-----------|---------------------------|
| **SIEM Overview** | Log volume over time, top sources, severity distribution, recent events table |
| **Firewall Dashboard** | Firewall log volume, top blocked IPs, allowed vs denied traffic, top rules triggered |
| **Network Devices** | Router/switch log volume, interface up/down events, top devices by log count |
| **IED Monitoring** | IED event timeline, protection trip events, communication failures |
| **Authentication** | Failed logins over time, top failed usernames, login sources, brute force patterns |

### 10.4 Import/Export Dashboards

**Export:**
1. Go to **Menu > Stack Management > Saved Objects**
2. Select dashboards and visualizations
3. Click **Export** to download as JSON

**Import:**
1. Go to **Menu > Stack Management > Saved Objects**
2. Click **Import** and upload the JSON file

---

## 11. Alerts and Notifications

### 11.1 Configure Notification Channels

Before creating alerts, set up where notifications should be sent:

1. Go to **Menu > Notifications > Channels**
2. Click **Create channel**

**Email Channel:**
- Name: `SOC-Email`
- Type: Email
- SMTP Host: `smtp.yourcompany.com`
- Port: `587`
- Sender: `supra-alerts@yourcompany.com`
- Recipients: `soc-team@yourcompany.com`

**Webhook Channel (e.g., Slack, Teams):**
- Name: `SOC-Slack`
- Type: Webhook
- URL: `https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK`

### 11.2 Create Alert Monitors

1. Go to **Menu > Alerting > Monitors**
2. Click **Create monitor**

**Example 1: High Volume Alert (DDoS/Log Storm)**
- Name: `High Log Volume Alert`
- Method: Visual editor
- Index: `supra-logs-*`
- Time field: `@timestamp`
- Frequency: Every 5 minutes
- Condition: Count is ABOVE `10000` in the last `5 minutes`
- Action: Send notification to `SOC-Email`

**Example 2: Failed Login Detection**
- Name: `Multiple Failed Logins`
- Method: Extraction query
- Query:
```json
{
  "query": {
    "bool": {
      "must": [
        { "match": { "message": "authentication failure" } },
        { "range": { "@timestamp": { "gte": "now-5m" } } }
      ]
    }
  }
}
```
- Condition: Hits > 5
- Action: Send notification to `SOC-Email`

**Example 3: Firewall Deny Spike**
- Name: `Firewall Deny Spike`
- Index: `firewall-logs-*`
- Condition: Count of `deny` or `drop` messages > 500 in 10 minutes
- Action: Send notification to `SOC-Slack`

**Example 4: IED Protection Trip**
- Name: `IED Protection Trip Event`
- Index: `ied-logs-*`
- Query: Match `message` containing `TRIP` or `PROTECTION`
- Condition: Count > 0
- Severity: Critical
- Action: Send to `SOC-Email` and `SOC-Slack`

**Example 5: Device Offline (No Logs Received)**
- Name: `Device Offline Detection`
- Method: Visual editor
- Index: `supra-logs-*`
- Condition: Count from a specific host is BELOW `1` in the last `15 minutes`
- Action: Send notification to `SOC-Email`

### 11.3 View Alert History

Go to **Menu > Alerting > Alerts** to see triggered alerts and their history.

---

## 12. Reports

### 12.1 Generate On-Demand Reports

1. Navigate to any **Dashboard** or **Visualization**
2. Click **Reporting** in the top menu bar (or the share icon)
3. Select format:
   - **PDF** - For printable reports
   - **PNG** - For image snapshots
   - **CSV** - For data export
4. Click **Generate**

### 12.2 Schedule Automated Reports

1. Go to **Menu > Reporting**
2. Click **Create report definition**
3. Configure:
   - **Name:** `Daily SIEM Summary`
   - **Source:** Select a dashboard (e.g., "Supra SIEM Overview")
   - **Format:** PDF
   - **Schedule:** Daily at 08:00 AM
   - **Delivery:** Email to `soc-manager@yourcompany.com`
4. Click **Create**

### 12.3 Recommended Report Schedule

| Report | Source Dashboard | Frequency | Recipients |
|--------|----------------|-----------|------------|
| Daily SIEM Summary | SIEM Overview | Daily 8:00 AM | SOC Team |
| Weekly Firewall Report | Firewall Dashboard | Weekly (Monday) | Network Team |
| Monthly Security Report | Security Analytics | Monthly (1st) | Management |
| IED Event Report | IED Monitoring | Daily 6:00 AM | Substation Team |

---

## 13. Security Analytics (SIEM)

The Security Analytics plugin provides threat detection using pre-built and custom rules.

### 13.1 Create a Detector

1. Go to **Menu > Security Analytics > Detectors**
2. Click **Create detector**
3. Configure:
   - **Name:** `Network Threat Detector`
   - **Data source:** `supra-logs-*` (or `firewall-logs-*`)
   - **Log type:** Select appropriate type (e.g., `network`, `linux`, `windows`)
   - **Detection rules:** Select from pre-built rules or add custom ones
   - **Schedule:** Run every 1 minute
4. Set up alert triggers (optional)
5. Click **Create**

### 13.2 Pre-built Detection Rules

The Security Analytics plugin comes with pre-built Sigma rules for:

- Brute force attacks
- Port scanning
- Privilege escalation
- Malware indicators
- Suspicious network connections
- Lateral movement
- Data exfiltration patterns

### 13.3 Create Custom Detection Rules

1. Go to **Menu > Security Analytics > Detection rules**
2. Click **Create detection rule**
3. Write a rule in Sigma format:

```yaml
title: Multiple Failed SSH Logins
description: Detects multiple failed SSH login attempts
status: experimental
logsource:
    product: linux
    service: sshd
detection:
    selection:
        message|contains: "Failed password"
    condition: selection | count() > 5
    timeframe: 5m
level: high
tags:
    - attack.credential_access
    - attack.t1110
```

### 13.4 View Security Findings

1. Go to **Menu > Security Analytics > Findings**
2. Filter by severity, detector, or time range
3. Click on a finding for detailed analysis

---

## 14. Service Management

### Start/Stop/Restart Services

```bash
# All services
sudo systemctl start supra-search supra-dashboards supra-log-collector
sudo systemctl stop supra-dashboards supra-log-collector supra-search
sudo systemctl restart supra-search supra-dashboards supra-log-collector

# Individual services
sudo systemctl start supra-search
sudo systemctl stop supra-search
sudo systemctl restart supra-search

sudo systemctl start supra-dashboards
sudo systemctl stop supra-dashboards

sudo systemctl start supra-log-collector
sudo systemctl stop supra-log-collector
```

### Check Service Status

```bash
sudo systemctl status supra-search supra-dashboards supra-log-collector supra-index-template
```

### The `supra-index-template` One-shot

`supra-index-template.service` is a `Type=oneshot` unit that fires whenever
`supra-search` is started. It polls `:9200/_cluster/health` for up to ~5 min,
then PUTs the `supra-logs` index template. Re-runs are idempotent, so it is
safe to restart manually:

```bash
sudo systemctl restart supra-index-template
journalctl -u supra-index-template --no-pager | tail -30
```

Timeout / credentials can be tuned via a systemd override:

```bash
sudo systemctl edit supra-index-template.service
# Example override:
#   [Service]
#   Environment=OS_BOOT_RETRIES=40
#   Environment=OS_BOOT_SLEEP=15
#   Environment=OS_PASS=YOUR_NEW_PASSWORD
sudo systemctl daemon-reload
```

### View Logs

```bash
# OpenSearch logs
journalctl -u supra-search -f

# Dashboards logs
journalctl -u supra-dashboards -f

# Log Collector logs
journalctl -u supra-log-collector -f

# All Supra logs
journalctl -u supra-search -u supra-dashboards -u supra-log-collector -u supra-index-template --since "1 hour ago"
```

### Enable/Disable Auto-Start on Boot

```bash
# Enable auto-start
sudo systemctl enable supra-search supra-dashboards supra-log-collector

# Disable auto-start
sudo systemctl disable supra-search supra-dashboards supra-log-collector
```

---

## 15. Backup and Restore

### 15.1 Register a Snapshot Repository

```bash
curl -sk -u admin:admin -X PUT \
  https://localhost:9200/_snapshot/supra_backup \
  -H "Content-Type: application/json" \
  -d '{
    "type": "fs",
    "settings": {
      "location": "/opt/supra/backups"
    }
  }'
```

> Add `path.repo: ["/opt/supra/backups"]` to `opensearch.yml` and restart OpenSearch first.

### 15.2 Create a Snapshot

```bash
# Snapshot all indices
curl -sk -u admin:admin -X PUT \
  "https://localhost:9200/_snapshot/supra_backup/snapshot_$(date +%Y%m%d)?wait_for_completion=true"
```

### 15.3 Restore from Snapshot

```bash
curl -sk -u admin:admin -X POST \
  https://localhost:9200/_snapshot/supra_backup/snapshot_20260306/_restore \
  -H "Content-Type: application/json" \
  -d '{ "indices": "supra-logs-*" }'
```

### 15.4 Automated Daily Backup (Cron)

```bash
# Add to crontab: sudo crontab -e
0 2 * * * curl -sk -u admin:admin -X PUT "https://localhost:9200/_snapshot/supra_backup/snapshot_$(date +\%Y\%m\%d)?wait_for_completion=true" >> /var/log/supra-backup.log 2>&1
```

---

## 16. Troubleshooting

### OpenSearch won't start

```bash
# Check logs
journalctl -u supra-search --no-pager -n 50

# Common fix: increase vm.max_map_count
sudo sysctl -w vm.max_map_count=262144

# Check disk space
df -h /opt/supra

# Check JVM heap
cat /opt/supra/opensearch/config/jvm.options | grep -E "^-Xm"
```

### Dashboards shows "OpenSearch unavailable"

```bash
# Verify OpenSearch is running
curl -sk -u admin:admin https://localhost:9200

# Check dashboards config
cat /opt/supra/dashboards/config/opensearch_dashboards.yml | grep opensearch.hosts

# Restart dashboards
sudo systemctl restart supra-dashboards
```

### Installer fails with "Unsupported OS"

The installer is built for **Ubuntu 22.04 LTS (jammy), amd64 only**. The
bundled `fluent-package` `.deb`s link against jammy library ABIs and would
either fail to install or downgrade host libraries on other releases.

```bash
# Confirm the host is jammy:
cat /etc/os-release | grep -E '^(ID|VERSION_CODENAME)='
# Should show:  ID=ubuntu  and  VERSION_CODENAME=jammy
```

If you are on 20.04 (focal) or 24.04 (noble), redeploy on a jammy host. The
installer will refuse to proceed by design — running it past the OS guard
would corrupt the system library set.

### Log Collector fails to bind UDP/514

UDP/514 is a privileged port. The `supra-log-collector.service` unit grants
`CAP_NET_BIND_SERVICE` to the `supra` user so this works, but a stock
`fluentd.service` (the one bundled with fluent-package) does not — and if it
is still enabled it will race for the port.

```bash
# Confirm the stock fluentd unit is disabled:
sudo systemctl is-enabled fluentd      # expected: disabled / masked
sudo systemctl disable --now fluentd 2>/dev/null

# Check who currently holds :514:
sudo ss -lupn | grep ':514 '
```

### `supra-index-template` failed or did not run

```bash
journalctl -u supra-index-template --no-pager | tail -50
```

Common causes:
- `supra-search` is not healthy yet — the one-shot waits up to ~5 min by
  default. If startup is slow, extend `OS_BOOT_RETRIES` / `OS_BOOT_SLEEP`
  via `systemctl edit supra-index-template.service`.
- Admin password was changed but the override was not added (Section 9.1
  Step 5).
- License has not been installed yet — the search engine may be up on
  `:9200` but reject mutating requests until a valid license is present.

After fixing the underlying issue, re-run the one-shot:
```bash
sudo systemctl restart supra-index-template
```

### No logs appearing in Dashboards

1. **Check Log Collector is running:**
   ```bash
   sudo systemctl status supra-log-collector
   ```

2. **Test syslog reception (UDP/514 is privileged):**
   ```bash
   sudo logger -n 127.0.0.1 -P 514 -d "Test message"
   ```

3. **Check if indices exist:**
   ```bash
   curl -sk -u admin:admin https://localhost:9200/_cat/indices?v
   ```

4. **Verify index pattern exists in Dashboards:**
   Go to **Stack Management > Index Patterns** and ensure `supra-logs-*` is created.

5. **Check Log Collector logs for errors:**
   ```bash
   journalctl -u supra-log-collector --no-pager -n 50
   ```

### Device syslog not reaching Supra

1. **Verify network connectivity:**
   ```bash
   # From the device (or a machine on the same network)
   nc -vuz <SUPRA_SERVER_IP> 514
   ```

2. **Check firewall on Supra server:**
   ```bash
   sudo ufw status
   ```

3. **Test with tcpdump:**
   ```bash
   sudo tcpdump -i any port 514 -nn
   ```

4. **Verify device syslog config:** Refer to [Section 6](#6-syslog-configuration-on-devices).

### High disk usage

```bash
# Check index sizes
curl -sk -u admin:admin "https://localhost:9200/_cat/indices?v&s=store.size:desc"

# Delete old indices manually
curl -sk -u admin:admin -X DELETE "https://localhost:9200/supra-logs-2025.01.*"

# Set up automatic cleanup - see Section 8.3
```

---

## 17. Appendix

### A. Default Ports Summary

| Port | Service | Protocol |
|------|---------|----------|
| 514 | Supra Log Collector syslog input | UDP |
| 24224 | Supra Log Collector forward input | TCP |
| 9200 | Supra Search Engine API | HTTPS |
| 5601 | Supra Dashboards Web UI | HTTP |

### B. File Locations

| File / Directory | Purpose |
|---|---|
| `/opt/supra/opensearch/` | Supra Search Engine installation |
| `/opt/supra/opensearch/config/opensearch.yml` | Search engine configuration |
| `/opt/supra/opensearch/config/opensearch-security/` | Security plugin configs |
| `/opt/supra/opensearch/config/supra-license/` | License key + public key + fingerprint tool |
| `/opt/supra/dashboards/` | Supra Dashboards installation |
| `/opt/supra/dashboards/config/opensearch_dashboards.yml` | Dashboards configuration |
| `/opt/supra/log-collector/fluent.conf` | Log Collector configuration |
| `/opt/supra/index-template/supra-index-template.sh` | Index template bootstrap script |
| `/opt/fluent/bin/fluentd` | Log Collector binary (fluent-package embedded Ruby) |
| `/opt/fluent/bin/fluent-gem` | Offline gem installer used for fluent plugins |
| `/etc/systemd/system/supra-search.service` | Search engine service unit |
| `/etc/systemd/system/supra-dashboards.service` | Dashboards service unit |
| `/etc/systemd/system/supra-log-collector.service` | Log Collector service unit |
| `/etc/systemd/system/supra-index-template.service` | Index template one-shot unit |
| `/etc/sysctl.d/99-supra.conf` | `vm.max_map_count=262144` tuning |

### C. Useful API Commands

```bash
# Cluster health
curl -sk -u admin:admin https://localhost:9200/_cluster/health?pretty

# List all indices
curl -sk -u admin:admin https://localhost:9200/_cat/indices?v

# Node stats
curl -sk -u admin:admin https://localhost:9200/_nodes/stats?pretty

# Search logs
curl -sk -u admin:admin https://localhost:9200/supra-logs-*/_search?pretty \
  -H "Content-Type: application/json" \
  -d '{ "query": { "match": { "message": "error" } }, "size": 10 }'

# Count documents in an index
curl -sk -u admin:admin https://localhost:9200/supra-logs-*/_count

# List all users
curl -sk -u admin:admin https://localhost:9200/_plugins/_security/api/internalusers?pretty

# List all roles
curl -sk -u admin:admin https://localhost:9200/_plugins/_security/api/roles?pretty
```

### D. Syslog Severity Levels

| Code | Severity | Description |
|------|----------|-------------|
| 0 | Emergency | System is unusable |
| 1 | Alert | Action must be taken immediately |
| 2 | Critical | Critical conditions |
| 3 | Error | Error conditions |
| 4 | Warning | Warning conditions |
| 5 | Notice | Normal but significant condition |
| 6 | Informational | Informational messages |
| 7 | Debug | Debug-level messages |

### E. Uninstallation

To completely remove Supra (preferred — also purges fluent-package):

```bash
sudo bash /tmp/supra-installer/uninstall.sh
```

Or manually:
```bash
sudo systemctl stop supra-search supra-dashboards supra-log-collector supra-index-template
sudo systemctl disable supra-search supra-dashboards supra-log-collector supra-index-template
sudo rm -f /etc/systemd/system/{supra-search,supra-dashboards,supra-log-collector,supra-index-template}.service
sudo systemctl daemon-reload

# Purge the offline-installed fluent-package
sudo dpkg --purge --force-all fluent-package

sudo rm -rf /opt/supra
sudo rm -f /etc/sysctl.d/99-supra.conf
sudo sysctl --system
```

> The jammy dependency libraries (`libssl3`, `libffi8`, etc.) installed by
> the bundled `.deb`s are left in place — they are standard Ubuntu packages
> and are typically required by other system software.

---

**Document Version:** 1.0
**Last Updated:** March 2026
**Product:** Supra SIEM Platform v3.6.0
