# Supra Stack Installation Guide - Windows Server

**Version:** 3.6.0
**Platform:** Windows Server 2016 or later (x64)
**Package:** supra-installer-3.6.0-windows-x64.zip

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Copy and Extract the Installer Package](#2-copy-and-extract-the-installer-package)
3. [Download and Place NSSM (Before Installation)](#3-download-and-place-nssm-before-installation)
4. [Run the Installer](#4-run-the-installer)
5. [Verify the Installation](#5-verify-the-installation)
6. [Managing Services](#6-managing-services)
7. [Log Collector Setup](#7-log-collector-setup)
8. [Uninstallation](#8-uninstallation)
9. [Ports and Firewall](#9-ports-and-firewall)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

- Windows Server 2016 or later (x64)
- Administrator access
- PowerShell 5.1 or later
- Minimum 4 GB RAM (8 GB or more recommended)
- Minimum 10 GB free disk space

---

## 2. Copy and Extract the Installer Package

Copy `supra-installer-3.6.0-windows-x64.zip` to the target Windows Server machine.

Open PowerShell and run:

```powershell
Expand-Archive -Path supra-installer-3.6.0-windows-x64.zip -DestinationPath .
```

This will create a `supra-installer` folder containing all the components.

---

## 3. Download and Place NSSM (Before Installation)

> **IMPORTANT:** This step must be completed BEFORE running the installer script.

NSSM (Non-Sucking Service Manager) is required to register Supra components as Windows Services. The installer will fail if NSSM is not in place.

### 3.1 Download NSSM

Download NSSM from one of the following sources:

- **Official site:** https://nssm.cc/release/nssm-2.24.zip
- **GitHub mirror (if official site is unavailable):** https://github.com/kirillkovalenko/nssm/releases

### 3.2 Extract and Place nssm.exe

```powershell
# Extract the NSSM archive
Expand-Archive -Path nssm-2.24.zip -DestinationPath .\nssm-extract

# Copy the 64-bit nssm.exe into the installer package
Copy-Item .\nssm-extract\nssm-2.24\win64\nssm.exe -Destination .\supra-installer\nssm\nssm.exe
```

### 3.3 Verify NSSM is in Place

```powershell
Test-Path .\supra-installer\nssm\nssm.exe
```

This should return `True`.

### 3.4 Cleanup

```powershell
Remove-Item -Recurse .\nssm-extract
Remove-Item nssm-2.24.zip
```

---

## 4. Run the Installer

Right-click PowerShell and select **"Run as Administrator"**.

Navigate to the directory containing the extracted installer and run:

```powershell
# Install to the default location (C:\supra)
.\supra-installer\install.ps1
```

To install to a custom path:

```powershell
.\supra-installer\install.ps1 -InstallPath "D:\supra"
```

### What the Installer Does

The installer performs the following steps automatically:

1. Creates a local service account (`SupraService`)
2. Extracts and configures Supra Search Engine (OpenSearch)
3. Initializes security demo certificates
4. Sets the admin password to `admin`
5. Configures JVM heap size (50% of available RAM, max 8 GB)
6. Extracts and configures Supra Dashboards
7. Installs extra Dashboards plugins (Security, Alerting, Anomaly Detection, etc.)
8. Applies Supra branding
9. Configures Supra Log Collector
10. Registers all components as Windows Services via NSSM
11. Configures Windows Firewall rules
12. Starts all services and verifies the Search Engine is ready
13. Initializes the security index

---

## 5. Verify the Installation

### 5.1 Check Services are Running

```powershell
Get-Service Supra*
```

Expected output:

| Status  | Name              | DisplayName           |
|---------|-------------------|-----------------------|
| Running | SupraSearch       | Supra Search Engine   |
| Running | SupraDashboards   | Supra Dashboards      |
| Running | SupraLogCollector | Supra Log Collector   |

### 5.2 Test the Search Engine

```powershell
Invoke-WebRequest -Uri https://localhost:9200 -SkipCertificateCheck -Credential (Get-Credential)
```

When prompted, enter:

- **Username:** `admin`
- **Password:** `admin`

A successful response returns a JSON object with cluster information.

### 5.3 Access the Dashboards

Open a web browser and navigate to:

```
http://localhost:5601
```

Login with:

- **Username:** `admin`
- **Password:** `admin`

---

## 6. Managing Services

### Using Windows Service Commands

```powershell
# Start a service
Start-Service SupraSearch

# Stop a service
Stop-Service SupraSearch

# Restart a service
Restart-Service SupraSearch

# Check status of all Supra services
Get-Service Supra*
```

### Using NSSM

```powershell
nssm start SupraSearch
nssm stop SupraSearch
nssm restart SupraSearch

nssm start SupraDashboards
nssm stop SupraDashboards
nssm restart SupraDashboards

nssm start SupraLogCollector
nssm stop SupraLogCollector
nssm restart SupraLogCollector
```

### Service Dependencies

- **SupraDashboards** depends on **SupraSearch** (will start automatically after Search Engine is ready)
- **SupraLogCollector** depends on **SupraSearch**

### Service Startup Order

1. SupraSearch (Supra Search Engine)
2. SupraLogCollector (Supra Log Collector)
3. SupraDashboards (Supra Dashboards)

---

## 7. Log Collector Setup

The Supra Log Collector requires a Fluentd runtime (td-agent) to be installed separately on the Windows Server.

### 7.1 Install td-agent

Download and install td-agent for Windows from:

- https://td-agent-package-browser.herokuapp.com/4/windows

### 7.2 Alternative: Install via RubyInstaller

1. Install RubyInstaller from https://rubyinstaller.org/
2. Open a command prompt and run:

```powershell
gem install fluentd fluent-plugin-opensearch
```

### 7.3 Register the Log Collector Service

After installing td-agent or Fluentd, re-run the installer to register the Log Collector service:

```powershell
.\supra-installer\install.ps1
```

The installer will detect the Fluentd runtime and register the SupraLogCollector service.

---

## 8. Uninstallation

Right-click PowerShell and select **"Run as Administrator"**, then run:

```powershell
# Uninstall from default location (C:\supra)
.\supra-installer\uninstall.ps1

# Uninstall from custom location
.\supra-installer\uninstall.ps1 -InstallPath "D:\supra"
```

The uninstaller will:

1. Stop all Supra services
2. Remove all Supra services from Windows
3. Remove Windows Firewall rules
4. Delete the installation directory

> **Note:** The `SupraService` user account is not removed automatically. To remove it manually:
> ```powershell
> Remove-LocalUser -Name SupraService
> ```

---

## 9. Ports and Firewall

The installer automatically creates Windows Firewall rules for the following ports:

| Service               | Port  | Protocol | Description                     |
|-----------------------|-------|----------|---------------------------------|
| Supra Search Engine   | 9200  | TCP      | Search Engine REST API (HTTPS)  |
| Supra Dashboards      | 5601  | TCP      | Dashboards Web UI (HTTP)        |
| Supra Log Collector   | 5140  | UDP      | Syslog input                    |
| Supra Log Collector   | 24224 | TCP      | Forward input                   |

---

## 10. Troubleshooting

### Search Engine fails to start

- Check logs at: `C:\supra\opensearch\logs\`
- Check stdout/stderr logs: `C:\supra\opensearch\logs\search-stdout.log`
- Verify JVM heap settings: `C:\supra\opensearch\config\jvm.options`
- Ensure sufficient RAM is available

### Dashboards fails to start

- Check logs at: `C:\supra\dashboards\logs\`
- Check stdout/stderr logs: `C:\supra\dashboards\logs\dashboards-stdout.log`
- Verify the Search Engine is running and accessible at `https://localhost:9200`

### Log Collector fails to start

- Check stdout/stderr logs: `C:\supra\log-collector\log-collector-stdout.log`
- Verify td-agent or Fluentd is installed and accessible in PATH
- Verify the Search Engine is running

### NSSM-related issues

- Verify `nssm.exe` is present in the installer's `nssm\` folder
- Run `nssm edit SupraSearch` to view/modify service configuration
- Run `nssm statuscode SupraSearch` to check service status

### Authentication issues

- Default credentials: `admin` / `admin`
- If login fails, the security index may not have initialized properly
- Re-run the security admin tool manually:

```powershell
$OPENSEARCH_HOME = "C:\supra\opensearch"
$env:OPENSEARCH_JAVA_HOME = "$OPENSEARCH_HOME\jdk"
& "$OPENSEARCH_HOME\plugins\opensearch-security\tools\securityadmin.bat" `
    -cd "$OPENSEARCH_HOME\config\opensearch-security" `
    -icl -nhnv `
    -cacert "$OPENSEARCH_HOME\config\root-ca.pem" `
    -cert "$OPENSEARCH_HOME\config\kirk.pem" `
    -key "$OPENSEARCH_HOME\config\kirk-key.pem"
```

---

## Summary of Installation Steps

```
1. Extract installer zip
2. Download NSSM and place nssm.exe in supra-installer\nssm\    <-- BEFORE install.ps1
3. Run install.ps1 as Administrator
4. (Optional) Install td-agent for Log Collector support
5. Verify services and access Dashboards at http://localhost:5601
```

---

*Document generated for Supra Stack v3.6.0 - Windows Server x64*
