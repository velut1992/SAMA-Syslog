# Supra SIEM Platform — Product Document

**Product:** Supra SIEM Platform
**Release:** 3.6.0
**Document reference:** SUPRA-PD-001
**Revision:** 1.0
**Date:** 2026-08-07

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Key Capabilities](#2-key-capabilities)
3. [Architecture](#3-architecture)
4. [Supported Log Sources](#4-supported-log-sources)
5. [Product Composition](#5-product-composition)
6. [System Requirements](#6-system-requirements)
7. [Deployment](#7-deployment)
8. [Licensing](#8-licensing)
9. [Functional Description](#9-functional-description)
10. [Security and Access Control](#10-security-and-access-control)
11. [Operations and Administration](#11-operations-and-administration)
12. [Quality Assurance and Release](#12-quality-assurance-and-release)
13. [Documentation and Support](#13-documentation-and-support)
14. [Appendices](#14-appendices)

---

## 1. Introduction

### 1.1 What Supra SIEM is

Supra SIEM is a centralised log management and security analytics platform. It
collects log data from across an organisation's IT and operational-technology
estate, stores and indexes it in a search engine, and presents it through a web
interface offering search, dashboards, alerting, scheduled reporting and threat
detection.

It is delivered as a single, self-contained, on-premises product that installs
onto one server without any internet connection at any stage.

### 1.2 At a glance

| Attribute | Value |
|---|---|
| Product name | Supra SIEM Platform |
| Release | 3.6.0 |
| Category | Log management and security analytics (SIEM) |
| Deployment | On-premises, single server, fully offline installation |
| Interfaces | Syslog (UDP/TCP), Fluentd forward protocol, HTTPS REST API, web UI |
| Server platform (Linux) | Ubuntu 22.04 LTS (jammy), x86_64 |
| Server platform (Windows) | Windows x64, services managed via NSSM |
| Licensing | RSA-signed, hardware-locked; perpetual or time-limited |
| Delivered as | `supra-installer-3.6.0-linux-x64.tar.gz` / `supra-installer-3.6.0-windows-x64.zip` |

### 1.3 Designed for isolated networks

The defining characteristic of the product is that it requires **no internet
access**. Every dependency — the search engine, the web interface, all user
interface plugins, the log collector runtime with its own embedded Ruby, and all
of the collector's plugin dependencies — is contained in the installer archive.
Nothing is downloaded at install time.

This is a deliberate design response to the environments the product is deployed
into: substation, operational-technology and other air-gapped networks where an
installer that reaches out to a package repository simply cannot work.

### 1.4 Who uses it

| User | How they use the product |
|---|---|
| Installation engineer | Runs the offline installer, activates the licence, performs handover verification |
| Platform administrator | Manages services, user accounts and roles, retention policies, backups |
| Security analyst | Searches logs, builds and reads dashboards, investigates alerts and detections |
| Operations / SOC team | Receives alert notifications and scheduled reports |

---

## 2. Key Capabilities

| Capability | Description |
|---|---|
| **Centralised log collection** | Receives syslog over UDP and TCP on port 514 from network devices, servers and industrial equipment, plus forwarded streams over the Fluentd forward protocol on TCP/24224. |
| **Indexing and full-text search** | Stores records in time-based indices under the `supra-*` pattern with a controlled field mapping, giving fast full-text and structured search across the whole estate. |
| **Dashboards and visualisation** | A web interface for building visualisations and dashboards over collected log data, with import and export of dashboard definitions. |
| **Alerting and notification** | Monitors evaluate queries on a schedule and raise alerts, delivered to email or to webhook endpoints such as Slack or Microsoft Teams. |
| **Scheduled and on-demand reporting** | Any dashboard or visualisation can be exported as PDF, PNG or CSV, on demand or on a recurring schedule with email delivery. |
| **Security analytics** | Threat detection using Sigma-format rules — a pre-built rule set plus custom rules — evaluated on a schedule against selected indices, producing security findings. |
| **Automated retention** | Index lifecycle policies age out and delete old indices automatically, so the platform manages its own disk footprint. |
| **Role-based access control** | Users, roles and role mappings restrict what each account can see and do, at both cluster and index level. |
| **Backup and restore** | Snapshot-based backup of indices to a registered repository, with documented restore and scheduled-snapshot procedures. |
| **Licence self-inspection** | Customers can read their own licence terms at any time through a REST endpoint or a command-line tool, with no vendor involvement. |
| **Offline installation** | The complete platform installs from one archive with no network access. |

---

## 3. Architecture

### 3.1 Components

The product consists of four managed components, each installed as a system
service.

| Component | Service unit | Function | Ports |
|---|---|---|---|
| **Supra Search Engine** | `supra-search` | Log storage, indexing, search, licence enforcement | 9200 (HTTPS) |
| **Supra Dashboards** | `supra-dashboards` | Web interface: search, visualisation, alerting, reporting, security analytics | 5601 (HTTP) |
| **Supra Log Collector** | `supra-log-collector` | Syslog reception, tagging and enrichment, forwarding to the search engine | 514/UDP, 24224/TCP |
| **Supra Index Template** | `supra-index-template` | One-shot bootstrap that applies the `supra-*` index template once the search engine is healthy | — |

### 3.2 Data flow

```
+------------------+   +------------------+   +------------------+
|  Network Devices |   |   Servers/Apps   |   |   IED Devices    |
|  (Routers, FW,   |   |  (Linux, Windows)|   |  (IEC 61850)     |
|   Switches)      |   |                  |   |                  |
+--------+---------+   +--------+---------+   +--------+---------+
         |                      |                      |
         |   Syslog UDP/TCP 514 |  Syslog UDP/TCP 514  |
         +----------+-----------+----------+-----------+
                    |                      |
                    v                      v
           +--------+----------------------+--------+
           |          Supra Log Collector           |
           |  - receives syslog on UDP/514          |
           |  - receives forwarded logs on TCP/24224|
           |  - tags, enriches, ships onward        |
           +-------------------+--------------------+
                               |
                               | HTTPS 9200
                               v
           +-------------------+--------------------+
           |          Supra Search Engine           |
           |  - indexes and stores log records      |
           |  - applies the supra-* index template  |
           |  - validates the licence at start-up   |
           +-------------------+--------------------+
                               |
                               v
           +-------------------+--------------------+
           |           Supra Dashboards             |
           |  - web UI on 5601                      |
           |  - dashboards, alerts, reports, SIEM   |
           +----------------------------------------+
```

### 3.3 Start-up sequence

The components start in a defined order, enforced by their service definitions:

1. **`supra-search`** starts first. It validates the licence before the node
   becomes available; if validation fails, the node does not start.
2. **`supra-index-template`** fires once the search engine reports healthy on
   port 9200, applies the `supra-*` index template, and exits. Its retry
   behaviour is configurable through the `OS_BOOT_RETRIES` and `OS_BOOT_SLEEP`
   environment settings.
3. **`supra-dashboards`** and **`supra-log-collector`** start once the search
   engine is available.

This ordering guarantees that no log record is indexed before the correct field
mappings are in place — without it, the first records to arrive would define
their own mappings and later records could be rejected or mis-typed.

### 3.4 Network ports

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 514 | UDP | Inbound | Syslog reception from devices |
| 24224 | TCP | Inbound | Fluentd forward protocol |
| 9200 | TCP (HTTPS) | Localhost | Search engine REST API |
| 5601 | TCP (HTTP) | Inbound | Web user interface |

Firewall rules for the inbound ports are documented in the Installation and User
Guide for the supported platform.

---

## 4. Supported Log Sources

The product ingests standard syslog, so it accepts data from any device capable
of emitting it. The following source types are explicitly covered, with
device-side configuration instructions, in the Installation and User Guide.

| Category | Sources |
|---|---|
| Routers and switches | Cisco IOS / IOS-XE, Cisco Nexus (NX-OS), Juniper Junos, HP/Aruba |
| Firewalls | Palo Alto Networks (PAN-OS), Fortinet FortiGate |
| Linux servers | rsyslog, syslog-ng |
| Windows servers | NXLog agent forwarding Windows Event Log |
| Virtualisation | VMware ESXi |
| Industrial / OT | IED devices per IEC 61850 |

Collected records can be routed into separate indices per device type — for
example distinct router, switch, firewall and IED indices — by extending the log
collector configuration. Both the default single-index configuration and the
per-device-type configuration are documented.

---

## 5. Product Composition

### 5.1 Developed by Supra Controls

| Item | Version | Technology |
|---|---|---|
| Supra Licence Validator plugin | 1.0.0 | Java 17 |
| Licence generation and inspection tooling | — | Java 17, Bash, PowerShell |
| Log collector configuration | — | Fluentd configuration |
| Windows agent configuration | — | NXLog configuration |
| Index template bootstrap | — | Bash |
| Service definitions | — | systemd units / NSSM service wrappers |
| Offline installers and setup scripts | — | Bash (Linux), PowerShell (Windows) |
| Offline test harness | — | Bash, Docker |

### 5.2 Incorporated third-party components

| Component | Version | Role |
|---|---|---|
| OpenSearch | 3.6.0 | Search and storage engine |
| OpenSearch Dashboards | 3.6.0 | Web user interface |
| Bundled JDK | as distributed | Java runtime for the search engine |
| fluent-package (Fluentd) | 5.0.9 | Log collector runtime, with embedded Ruby |
| fluent-plugin-opensearch and dependencies | as bundled | Ships collected records into the search engine |
| NXLog | as distributed | Windows log-source agent |
| NSSM | 2.24 | Windows service wrapper |

**User interface plugins bundled at 3.6.0:** alerting, anomaly detection,
assistant, custom import map, index management, notifications, observability,
query insights, reports, search relevance, security analytics, and security.

### 5.3 Version pinning

All third-party components are version-pinned and packaged into the installer
rather than downloaded at install time. The composition of a given release is
therefore fixed: the customer receives exactly the binaries that were tested, and
an upstream change cannot alter a released product retrospectively.

---

## 6. System Requirements

### 6.1 Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 4 cores | 8 or more cores |
| RAM | 8 GB | 16 GB or more |
| Disk | 100 GB | 500 GB or more, SSD |
| Network | 1 Gbps | 1 Gbps |

Disk sizing should be driven by expected daily log volume and the intended
retention period. The retention policy described in Section 9.6 is the primary
control over long-term disk growth.

### 6.2 Software

- **Ubuntu 22.04 LTS (jammy), x86_64** for the Linux installer. The bundled log
  collector packages link against jammy library versions, so the installer
  validates the target platform and refuses to run on 20.04, 24.04, RHEL/CentOS
  or non-amd64 hardware rather than producing a broken installation.
- **Windows x64** for the Windows installer.
- Root or administrator access on the target server.
- **No internet access required**, and no separate Ruby or Java installation
  required — both are bundled.

---

## 7. Deployment

### 7.1 Installation sequence

1. **Transfer** the installer archive to the target server.
2. **Verify integrity** using the published SHA-256 checksum supplied with the
   archive.
3. **Extract** the archive.
4. **Run the installer** as root or administrator. It validates the platform,
   creates the service account, applies required kernel tuning, lays down all
   four components and registers their services.
5. **Activate the licence** — see Section 8.
6. **Start the services** in the defined order and verify.

### 7.2 Post-installation verification

The Installation and User Guide defines a verification procedure that the
installing engineer performs at handover and the customer can witness:

- the web interface is reachable and accepts login;
- the search engine reports healthy cluster status;
- the log collector is running and receives a test syslog message;
- the `supra-*` index template has been applied;
- log records are visible in the web interface.

### 7.3 Installed layout

| Path | Content |
|---|---|
| `/opt/supra/opensearch/` | Search engine, including its bundled JDK |
| `/opt/supra/opensearch/config/supra-license/` | Licence file, public key, fingerprint tool |
| `/opt/supra/dashboards/` | Web user interface |
| `/opt/supra/log-collector/fluent.conf` | Log collector configuration |
| `/opt/supra/index-template/` | Index template bootstrap |
| `/opt/fluent/` | Log collector runtime and embedded Ruby |
| `/etc/systemd/system/supra-*.service` | The four service definitions |
| `/etc/sysctl.d/99-supra.conf` | Kernel tuning required by the search engine |

### 7.4 Removal

An uninstall script is delivered with the installer, providing a controlled
removal of the product, its service definitions and its service account.

---

## 8. Licensing

### 8.1 Licence model

Each installation is licensed by a signed licence file bound to the machine it
runs on. A licence records the customer, the bound machine fingerprint, the issue
and expiry dates, the tier, the node limit and, where applicable, a device limit.
Licences may be **perpetual** (no expiry) or **time-limited**.

### 8.2 Activation

1. The installing engineer runs the fingerprint tool on the target machine to
   obtain its machine fingerprint.
2. The fingerprint is sent to Supra Controls, which issues a signed licence file
   for that specific machine.
3. The licence file is placed in the search engine configuration directory.
4. The search engine is started.

### 8.3 Enforcement

At start-up the search engine:

1. reads the licence file;
2. verifies its RSA signature against the bundled public key;
3. computes this machine's fingerprint and compares it with the licensed one;
4. checks the expiry date;
5. refuses to start if any check fails, logging both the reason and this
   machine's own fingerprint so the fault can be diagnosed immediately.

### 8.4 Reading a licence

The licence payload is signed but not encrypted. This is deliberate: the customer
can always see exactly what they hold, while the signature prevents alteration.
Licence terms can be read through three routes, all producing the same result:

| Route | Used by | Notes |
|---|---|---|
| `GET /_supra/license` | Customer, from the web interface's Dev Tools console | Returns the licence as JSON, together with live device usage over the preceding 24 hours |
| `supra-license-info.sh` | Operator, on the server | Prints a formatted summary and, where the public key and OpenSSL are present, verifies the signature |
| `LicenseGenerator --inspect` | Supra Controls, when issuing | Confirms issued terms before despatch; requires no private key |

The REST endpoint reports the licence only after signature, fingerprint and
expiry checks have passed at start-up, so any response it returns describes an
authentic licence bound to that machine.

---

## 9. Functional Description

### 9.1 Log collection

The log collector receives syslog on UDP/514 and, when configured, TCP/514, and
accepts forwarded streams from other collectors or agents on TCP/24224. Received
records are tagged with the collector identity, may be enriched or classified —
for example by source IP, to route each device type to its own index — and are
then shipped over HTTPS to the search engine.

### 9.2 Storage and indexing

Records are written to time-based indices matching `supra-*`. Field mappings are
governed by the index template applied at bootstrap, which ensures consistent
field types across all indices and therefore reliable searching, aggregation and
visualisation.

### 9.3 Search and discovery

The web interface provides interactive search across selected indices with time
range filtering, field-level filtering and free-text query. A REST API is
available for scripted queries, cluster health checks, index listings and
administrative operations.

### 9.4 Dashboards and visualisation

Users build visualisations over log data and assemble them into dashboards.
Dashboard definitions can be exported and imported, so a standard dashboard set
can be developed once and deployed to multiple sites. Dashboards commonly built
on this platform include:

| Dashboard | Typical content |
|---|---|
| SIEM Overview | Log volume over time, top sources, severity distribution, recent events |
| Firewall | Firewall log volume, top blocked addresses, allowed versus denied traffic, most-triggered rules |
| Network Devices | Router and switch log volume, interface up/down events, top devices by log count |
| IED Monitoring | IED event timeline, protection trip events, communication failures |
| Authentication | Failed logins over time, top failed usernames, login sources, brute-force patterns |

### 9.5 Alerting and notification

Alert monitors run a query on a defined schedule and trigger when the result
meets a configured condition — for example an unusual spike in log volume, or
repeated authentication failures from one source. Triggered alerts are delivered
through notification channels:

| Channel type | Configuration |
|---|---|
| Email | SMTP host, port, sender and recipient list |
| Webhook | Endpoint URL, for delivery into Slack, Microsoft Teams or any webhook receiver |

Alert history is retained and reviewable in the web interface.

### 9.6 Index management and retention

Index lifecycle policies transition and delete indices automatically according to
age. A policy is attached to an index pattern and applies to every matching index
as it is created. A typical policy deletes `supra-logs-*` indices once they reach
a defined age; the retention period itself is the customer's decision, taken
against their own operational and regulatory requirements. Policies can be
created either through the web interface or through the REST API.

### 9.7 Reporting

Any dashboard or visualisation can be exported as **PDF**, **PNG** or **CSV**,
either on demand or on a recurring schedule with email delivery. Typical
scheduled reports include a daily operational summary, weekly per-domain reports
and a monthly management security report.

### 9.8 Security analytics

The security analytics function provides threat detection over collected logs.
Detectors are configured against a data source and log type, run on a schedule,
and evaluate detection rules written in **Sigma** format. A pre-built rule set is
included covering, among others:

- brute-force attacks
- port scanning
- privilege escalation
- malware indicators
- suspicious network connections
- lateral movement
- data exfiltration patterns

Custom Sigma rules can be authored for site-specific detections. Matches produce
security findings, which can be reviewed in the interface and can trigger alerts.

---

## 10. Security and Access Control

### 10.1 Authenticated access

All access to the search engine and the web interface is authenticated. The
search engine API is served over HTTPS.

### 10.2 Users, roles and role mapping

Access control is role-based and applies at both cluster and index level. Roles
define cluster permissions and index permissions; users are mapped to roles.
Representative roles for a typical deployment:

| Role | Cluster permissions | Index permissions | Purpose |
|---|---|---|---|
| `soc_analyst` | monitor | read, search on log indices | Read-only log analysis |
| `soc_manager` | monitor | read, search, create/update/delete on log indices | Analysis plus management of saved objects |
| `report_viewer` | monitor | read on log indices | Dashboards and reports only |
| `device_admin` | monitor | read, search on specific device indices | Access scoped to one device type |
| `admin_full` | all | all | Full administration |

Scoping a role to specific index patterns is the mechanism for restricting a team
to only the device types it is responsible for.

### 10.3 Credential management

The product ships with a default administrative account. **Changing the default
credentials is a required post-installation step** and is documented in the
Installation and User Guide, including the corresponding update to the service
configuration so that the index template bootstrap continues to authenticate
correctly.

### 10.4 Licence key material

The licence signing private key is held solely by Supra Controls, is excluded
from distribution, and is never shipped with the product. Only the corresponding
public key — which can verify but not create licences — is installed on customer
systems.

---

## 11. Operations and Administration

### 11.1 Service management

Each component is a standard system service and is managed with the platform's
normal service tooling: start, stop, restart and status for each of
`supra-search`, `supra-dashboards`, `supra-log-collector`, and the
`supra-index-template` one-shot. Services can be enabled or disabled for
automatic start at boot.

### 11.2 Logs and diagnostics

Each service writes to the system journal and can be followed live per service or
across the whole product. The Installation and User Guide documents diagnostic
procedures for the common failure modes, each with the specific commands to
identify and correct the cause:

| Symptom | Documented cause and correction |
|---|---|
| Search engine will not start | Kernel tuning, disk space, JVM heap, licence validation |
| Web interface reports the search engine unavailable | Engine not running, or configuration mismatch |
| Installer rejects the host | Unsupported operating system or architecture |
| Log collector cannot bind UDP/514 | Port already held, commonly by a stock collector service |
| Index template did not apply | One-shot ordering or authentication |
| No log records appearing | Collector, network path, or device-side configuration |
| Device logs not arriving | Device configuration, firewall, or network routing |
| High disk usage | Missing or mis-scoped retention policy |

### 11.3 Backup and restore

The product supports snapshot-based backup of indices to a registered snapshot
repository. Documented procedures cover repository registration, taking a
snapshot, restoring from a snapshot, and automating a daily snapshot on a
schedule.

### 11.4 Corrective updates

Where a defect is identified after delivery, Supra Controls issues a targeted
offline patch package rather than requiring a full reinstall — consistent with
the offline constraint of the deployment environments.

---

## 12. Quality Assurance and Release

### 12.1 Automated installation testing

Supra Controls maintains an automated test harness that performs a complete
**reset → install → verify → report** cycle against each built installer. It
returns a host to a clean state, installs the product, asserts that the
installation is correct, and writes a timestamped report.

Testing runs both on a local host and across a container matrix covering Ubuntu
20.04, 22.04 and 24.04, with an aggregated summary across the matrix.

### 12.2 Offline behaviour is enforced, not assumed

Because "installs without internet" is the product's defining requirement, it is
verified structurally rather than by observation:

- in local testing, the installer runs inside a private network namespace where
  only loopback exists;
- in container testing, the container is started with no network interface at
  all.

If the installer were to require a package update, a dependency fetch or any
other download, the test fails outright rather than passing quietly on a
connected build machine.

### 12.3 What is verified

Installation-level checks assert creation of the service account, application of
kernel tuning, presence and correct ownership of the search engine and its
bundled JDK, presence of the licence public key, presence of the web interface
and its configuration, correct installation of the log collector package with its
binary, configuration and output plugin, presence of the index template
bootstrap, and the presence and enabled state of all four services.

An optional runtime tier additionally starts the services under a real licence
and confirms that the search engine, web interface and log collector all become
active and that the syslog and forward ports are listening.

### 12.4 Release integrity

Each release is published with a SHA-256 checksum, which the receiving engineer
verifies before extraction. Because the archive is self-contained, there is no
possibility of a partially-delivered or differently-composed installation
resulting from network conditions at the customer site.

---

## 13. Documentation and Support

### 13.1 Documentation delivered with the product

| Document | Purpose |
|---|---|
| Installation and User Guide | Complete installation, configuration, administration and troubleshooting reference |
| Windows Installation Guide | Windows-specific installation procedure |
| Linux Installation Guide | Linux-specific installation procedure |
| Licensing Guide | Licence activation and management |
| Licence Inspection Guide | Reading licence terms by REST endpoint, script or vendor tool |
| Dashboard Setup Guide | Building the standard dashboard set |
| Corrective runbooks | Step-by-step procedures for specific known issues |

Guides are generated from a single controlled source into HTML and PDF, so the
distributed renderings cannot diverge from the original.

### 13.2 Self-service diagnosis

The product is designed so that a customer can diagnose most conditions without
contacting the vendor: service status and logs are accessible through standard
tooling, the troubleshooting section covers the common failure modes with their
corrections, and licence terms can be read directly on the server or through the
web interface.

---

## 14. Appendices

### Appendix A — Port summary

| Port | Protocol | Service |
|---|---|---|
| 514 | UDP | Log collector, syslog input |
| 24224 | TCP | Log collector, forward protocol input |
| 9200 | HTTPS | Search engine API |
| 5601 | HTTP | Web user interface |

### Appendix B — Key file locations

| Path | Purpose |
|---|---|
| `/opt/supra/opensearch/` | Search engine installation |
| `/opt/supra/opensearch/config/opensearch.yml` | Search engine configuration |
| `/opt/supra/opensearch/config/supra-license/` | Licence file, public key, fingerprint tool |
| `/opt/supra/dashboards/` | Web interface installation |
| `/opt/supra/dashboards/config/opensearch_dashboards.yml` | Web interface configuration |
| `/opt/supra/log-collector/fluent.conf` | Log collector configuration |
| `/opt/supra/index-template/supra-index-template.sh` | Index template bootstrap |
| `/opt/fluent/bin/fluentd` | Log collector binary |
| `/etc/systemd/system/supra-*.service` | Service definitions |
| `/etc/sysctl.d/99-supra.conf` | Kernel tuning |

### Appendix C — Syslog severity levels

| Level | Severity | Meaning |
|---|---|---|
| 0 | Emergency | System is unusable |
| 1 | Alert | Immediate action required |
| 2 | Critical | Critical condition |
| 3 | Error | Error condition |
| 4 | Warning | Warning condition |
| 5 | Notice | Normal but significant |
| 6 | Informational | Informational message |
| 7 | Debug | Debug-level message |

### Appendix D — Glossary

| Term | Meaning |
|---|---|
| **Detector** | A scheduled security analytics job that evaluates detection rules against an index and produces findings |
| **Fingerprint** | A hash derived from the host's hardware identifiers, used to bind a licence to one machine |
| **Forward protocol** | The Fluentd-native protocol used to relay records between collectors, on TCP/24224 |
| **IED** | Intelligent Electronic Device — protection and control equipment in a substation, per IEC 61850 |
| **Index** | The unit of storage in the search engine; this product uses time-based indices under `supra-*` |
| **Index template** | Definition applied to new indices, fixing field mappings and settings |
| **ISM policy** | Index State Management policy — automates transitions and deletion of indices by age |
| **Monitor** | A scheduled alerting job that runs a query and triggers when a condition is met |
| **NXLog** | Agent used to forward Windows Event Log data as syslog |
| **Sigma** | An open, vendor-neutral rule format for expressing log-based detections |
| **SIEM** | Security Information and Event Management |
| **Snapshot** | A point-in-time backup of indices to a registered repository |

---

*End of document — SUPRA-PD-001 Rev 1.0*
