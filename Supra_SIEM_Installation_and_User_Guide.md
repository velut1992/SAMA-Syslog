# Supra SIEM Platform - Installation and User Guide

**Version:** 3.6.0
**Date:** March 2026
**Platform:** Linux x64 (Ubuntu/Debian/RHEL/CentOS)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Installation](#4-installation)
5. [Post-Installation Verification](#5-post-installation-verification)
6. [Syslog Configuration on Devices](#6-syslog-configuration-on-devices)
7. [Fluentd Configuration](#7-fluentd-configuration)
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

| Component | Purpose | Port |
|-----------|---------|------|
| **OpenSearch 3.6.0** | Log storage, indexing, and search engine | 9200 (HTTPS) |
| **OpenSearch Dashboards** | Web UI for visualization, dashboards, and alerts | 5601 (HTTP) |
| **Fluentd** | Log collector - receives syslog from devices | 5140 (syslog), 24224 (forward) |

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
         |    Port 5140           |     Port 5140          |
         +----------+------------+----------+--------------+
                    |                       |
                    v                       v
           +--------+-----------------------+--------+
           |              Fluentd                     |
           |  - Receives syslog on port 5140          |
           |  - Receives forwarded logs on port 24224 |
           |  - Parses and tags logs                  |
           +-------------------+----------------------+
                               |
                               | HTTPS (port 9200)
                               v
           +-------------------+----------------------+
           |             OpenSearch                    |
           |  - Indexes and stores logs               |
           |  - Full-text search                      |
           |  - Security analytics                    |
           +-------------------+----------------------+
                               |
                               v
           +-------------------+----------------------+
           |       OpenSearch Dashboards               |
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

- Linux x64 (Ubuntu 20.04+, RHEL 8+, CentOS 8+, Debian 10+)
- Ruby 3.0+ (for Fluentd)
- Root/sudo access

### Network Requirements

Ensure the following ports are open on the Supra server:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 5140 | UDP/TCP | Inbound | Syslog from devices |
| 24224 | TCP | Inbound | Fluentd forward protocol |
| 9200 | TCP | Localhost | OpenSearch API |
| 5601 | TCP | Inbound | Dashboards Web UI |

### Firewall Rules (on the Supra server)

```bash
# Ubuntu/Debian (ufw)
sudo ufw allow 5140/udp comment "Syslog UDP"
sudo ufw allow 5140/tcp comment "Syslog TCP"
sudo ufw allow 5601/tcp comment "Supra Dashboards"

# RHEL/CentOS (firewalld)
sudo firewall-cmd --permanent --add-port=5140/udp
sudo firewall-cmd --permanent --add-port=5140/tcp
sudo firewall-cmd --permanent --add-port=5601/tcp
sudo firewall-cmd --reload
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
1. Create a `supra` system user
2. Apply system tuning (`vm.max_map_count=262144`)
3. Install OpenSearch to `/opt/supra/opensearch`
4. Initialize security certificates and default credentials
5. Install OpenSearch Dashboards to `/opt/supra/dashboards`
6. Install extra plugins (Security Analytics, Index Management, Notifications)
7. Install Fluentd and configure it
8. Create and enable systemd services
9. Start all services

### Step 4: Verify Installation

```bash
# Check OpenSearch
curl -sk -u admin:admin https://localhost:9200

# Check Dashboards (wait 1-2 minutes for startup)
curl -s -o /dev/null -w "%{http_code}" http://localhost:5601

# Check all services
sudo systemctl status opensearch opensearch-dashboards fluentd
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

### 5.3 Verify Fluentd is Running

```bash
sudo systemctl status fluentd

# Test syslog reception
logger -n 127.0.0.1 -P 5140 -d "Test syslog message from Supra"
```

### 5.4 Verify Logs are Being Indexed

```bash
# Check for fluentd indices
curl -sk -u admin:admin https://localhost:9200/_cat/indices?v
```

You should see indices like `fluentd-YYYY.MM.DD`.

---

## 6. Syslog Configuration on Devices

Configure your network devices, servers, and applications to send syslog to the Supra server on **port 5140 (UDP)**.

### 6.1 Cisco Routers and Switches (IOS/IOS-XE)

```
configure terminal
logging host <SUPRA_SERVER_IP> transport udp port 5140
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
logging server <SUPRA_SERVER_IP> 6 port 5140 facility local7
logging source-interface loopback0
logging timestamp milliseconds
end
copy running-config startup-config
```

### 6.3 Juniper Routers and Switches (Junos)

```
set system syslog host <SUPRA_SERVER_IP> port 5140
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
   - **Port:** `5140`
   - **Facility:** `LOG_LOCAL7`
3. Navigate to **Objects > Log Forwarding** and create a profile using the syslog server
4. Apply the log forwarding profile to security rules under **Policies > Security**
5. **Commit** the changes

### 6.5 Fortinet FortiGate Firewalls

```
config log syslogd setting
    set status enable
    set server "<SUPRA_SERVER_IP>"
    set port 5140
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
*.* @<SUPRA_SERVER_IP>:5140

# Or via TCP (more reliable)
*.* @@<SUPRA_SERVER_IP>:5140
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
    network("<SUPRA_SERVER_IP>" port(5140) transport("udp"));
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
    Port        5140
    Exec        to_syslog_bsd();
</Output>

<Route supra_route>
    Path        in_eventlog => out_supra
</Route>
```

3. Restart the NXLog service

**Option B: Snare Agent**

1. Download and install Snare for Windows
2. Configure the syslog destination: `<SUPRA_SERVER_IP>:5140` (UDP)
3. Select event log sources (Security, System, Application)

### 6.9 IED Devices (Intelligent Electronic Devices - IEC 61850)

IED configuration varies by manufacturer. General steps:

**ABB REL670 / REB670:**
1. Access the IED via PCM600 engineering tool
2. Navigate to **Communication > Syslog**
3. Set **Syslog Server IP:** `<SUPRA_SERVER_IP>`
4. Set **Syslog Port:** `5140`
5. Set **Severity Level:** `Informational`
6. Download configuration to IED

**Siemens SIPROTEC 5:**
1. Open DIGSI 5 engineering tool
2. Navigate to **Communication > Syslog Client**
3. Configure:
   - Server Address: `<SUPRA_SERVER_IP>`
   - Server Port: `5140`
   - Protocol: UDP
4. Transfer settings to device

**SEL (Schweitzer Engineering Laboratories):**
1. Connect via SEL terminal (serial or network)
2. Configure syslog:
```
SET SYSLOG_IP1 <SUPRA_SERVER_IP>
SET SYSLOG_PORT1 5140
SET SYSLOG_SEV INFO
```

**GE Multilin:**
1. Access via EnerVista software
2. Navigate to **Settings > Communications > Syslog**
3. Set Server IP and Port (5140)

> **Note:** If the IED does not support syslog natively, use a gateway/relay server running rsyslog to collect IED logs (serial, GOOSE, MMS) and forward them to Supra.

### 6.10 HP/Aruba Switches

```
logging <SUPRA_SERVER_IP> transport udp 5140
logging severity info
logging facility local7
```

### 6.11 VMware ESXi

```bash
esxcli system syslog config set --loghost='udp://<SUPRA_SERVER_IP>:5140'
esxcli system syslog reload
```

**Verify:**
```bash
esxcli system syslog config get
```

---

## 7. Fluentd Configuration

The Fluentd configuration file is located at:

```
/opt/supra/fluentd/fluent.conf
```

### 7.1 Default Configuration

```xml
# Syslog input - receives syslog from all devices
<source>
  @type syslog
  port 5140
  tag system
</source>

# Forward input - for Fluentd-to-Fluentd forwarding
<source>
  @type forward
  port 24224
</source>

# Send all logs to OpenSearch
<match **>
  @type opensearch
  host localhost
  port 9200
  scheme https
  ssl_verify false
  user admin
  password admin
  logstash_format true
  logstash_prefix fluentd
  flush_interval 10s
</match>
```

### 7.2 Advanced: Separate Indices per Device Type

To create separate indices for different device types, update the Fluentd config:

```xml
# Syslog input with facility-based tagging
<source>
  @type syslog
  port 5140
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

Install the required plugin:
```bash
sudo gem install fluent-plugin-rewrite-tag-filter --no-document
```

After any config change:
```bash
sudo systemctl restart fluentd
```

### 7.3 Enable TCP Syslog (in addition to UDP)

```xml
<source>
  @type syslog
  port 5140
  protocol_type udp
  tag syslog.udp
</source>

<source>
  @type syslog
  port 5140
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
3. Enter the pattern: `fluentd-*` (or `router-logs-*`, `firewall-logs-*`, etc.)
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
        "index_patterns": ["fluentd-*"],
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
        { "index_patterns": ["fluentd-*"], "priority": 100 }
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
    "index_patterns": ["fluentd-*", "router-logs-*", "switch-logs-*", "firewall-logs-*", "ied-logs-*"],
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

**Step 4:** Update the Fluentd config with the new password:
```bash
sudo nano /opt/supra/fluentd/fluent.conf
# Change: password admin -> password YOUR_NEW_PASSWORD
sudo systemctl restart fluentd
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
| Index patterns | `fluentd-*`, `firewall-logs-*`, `router-logs-*` |
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
        "index_patterns": ["fluentd-*", "firewall-logs-*", "router-logs-*", "switch-logs-*", "ied-logs-*"],
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
- Index pattern: `fluentd-*`
- Y-axis: Count
- X-axis: Date Histogram on `@timestamp` (interval: hourly)
- Save as: "Log Volume Over Time"

**Example 2: Top Log Sources (Pie Chart)**
- Type: **Pie**
- Index pattern: `fluentd-*`
- Slice: Terms aggregation on `host` (size: 10)
- Save as: "Top Log Sources"

**Example 3: Severity Distribution (Bar Chart)**
- Type: **Vertical Bar**
- Index pattern: `fluentd-*`
- Y-axis: Count
- X-axis: Terms on `severity` or `priority`
- Save as: "Log Severity Distribution"

**Example 4: Recent Logs Table**
- Type: **Data Table**
- Index pattern: `fluentd-*`
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
- Index: `fluentd-*`
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
- Index: `fluentd-*`
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
   - **Data source:** `fluentd-*` (or `firewall-logs-*`)
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
sudo systemctl start opensearch opensearch-dashboards fluentd
sudo systemctl stop opensearch-dashboards fluentd opensearch
sudo systemctl restart opensearch opensearch-dashboards fluentd

# Individual services
sudo systemctl start opensearch
sudo systemctl stop opensearch
sudo systemctl restart opensearch

sudo systemctl start opensearch-dashboards
sudo systemctl stop opensearch-dashboards

sudo systemctl start fluentd
sudo systemctl stop fluentd
```

### Check Service Status

```bash
sudo systemctl status opensearch opensearch-dashboards fluentd
```

### View Logs

```bash
# OpenSearch logs
journalctl -u opensearch -f

# Dashboards logs
journalctl -u opensearch-dashboards -f

# Fluentd logs
journalctl -u fluentd -f

# All Supra logs
journalctl -u opensearch -u opensearch-dashboards -u fluentd --since "1 hour ago"
```

### Enable/Disable Auto-Start on Boot

```bash
# Enable auto-start
sudo systemctl enable opensearch opensearch-dashboards fluentd

# Disable auto-start
sudo systemctl disable opensearch opensearch-dashboards fluentd
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
  -d '{ "indices": "fluentd-*" }'
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
journalctl -u opensearch --no-pager -n 50

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
sudo systemctl restart opensearch-dashboards
```

### No logs appearing in Dashboards

1. **Check Fluentd is running:**
   ```bash
   sudo systemctl status fluentd
   ```

2. **Test syslog reception:**
   ```bash
   logger -n 127.0.0.1 -P 5140 -d "Test message"
   ```

3. **Check if indices exist:**
   ```bash
   curl -sk -u admin:admin https://localhost:9200/_cat/indices?v
   ```

4. **Verify index pattern exists in Dashboards:**
   Go to **Stack Management > Index Patterns** and ensure `fluentd-*` is created.

5. **Check Fluentd logs for errors:**
   ```bash
   journalctl -u fluentd --no-pager -n 50
   ```

### Device syslog not reaching Supra

1. **Verify network connectivity:**
   ```bash
   # From the device (or a machine on the same network)
   nc -vuz <SUPRA_SERVER_IP> 5140
   ```

2. **Check firewall on Supra server:**
   ```bash
   sudo ufw status         # Ubuntu
   sudo firewall-cmd --list-ports  # RHEL
   ```

3. **Test with tcpdump:**
   ```bash
   sudo tcpdump -i any port 5140 -nn
   ```

4. **Verify device syslog config:** Refer to [Section 6](#6-syslog-configuration-on-devices).

### High disk usage

```bash
# Check index sizes
curl -sk -u admin:admin "https://localhost:9200/_cat/indices?v&s=store.size:desc"

# Delete old indices manually
curl -sk -u admin:admin -X DELETE "https://localhost:9200/fluentd-2025.01.*"

# Set up automatic cleanup - see Section 8.3
```

---

## 17. Appendix

### A. Default Ports Summary

| Port | Service | Protocol |
|------|---------|----------|
| 5140 | Fluentd syslog input | UDP/TCP |
| 24224 | Fluentd forward input | TCP |
| 9200 | OpenSearch API | HTTPS |
| 5601 | Dashboards Web UI | HTTP |

### B. File Locations

| File/Directory | Purpose |
|---------------|---------|
| `/opt/supra/opensearch/` | OpenSearch installation |
| `/opt/supra/opensearch/config/opensearch.yml` | OpenSearch configuration |
| `/opt/supra/opensearch/config/opensearch-security/` | Security plugin configs |
| `/opt/supra/dashboards/` | Dashboards installation |
| `/opt/supra/dashboards/config/opensearch_dashboards.yml` | Dashboards configuration |
| `/opt/supra/fluentd/fluent.conf` | Fluentd configuration |
| `/etc/systemd/system/opensearch.service` | OpenSearch service file |
| `/etc/systemd/system/opensearch-dashboards.service` | Dashboards service file |
| `/etc/systemd/system/fluentd.service` | Fluentd service file |

### C. Useful API Commands

```bash
# Cluster health
curl -sk -u admin:admin https://localhost:9200/_cluster/health?pretty

# List all indices
curl -sk -u admin:admin https://localhost:9200/_cat/indices?v

# Node stats
curl -sk -u admin:admin https://localhost:9200/_nodes/stats?pretty

# Search logs
curl -sk -u admin:admin https://localhost:9200/fluentd-*/_search?pretty \
  -H "Content-Type: application/json" \
  -d '{ "query": { "match": { "message": "error" } }, "size": 10 }'

# Count documents in an index
curl -sk -u admin:admin https://localhost:9200/fluentd-*/_count

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

To completely remove Supra:

```bash
sudo bash /opt/supra/uninstall.sh
```

Or manually:
```bash
sudo systemctl stop opensearch opensearch-dashboards fluentd
sudo systemctl disable opensearch opensearch-dashboards fluentd
sudo rm -f /etc/systemd/system/{opensearch,opensearch-dashboards,fluentd}.service
sudo systemctl daemon-reload
sudo rm -rf /opt/supra
sudo rm -f /etc/sysctl.d/99-supra.conf
sudo sysctl --system
```

---

**Document Version:** 1.0
**Last Updated:** March 2026
**Product:** Supra SIEM Platform v3.6.0
