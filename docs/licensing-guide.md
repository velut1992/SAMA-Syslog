# Supra Licensing Guide

**Version:** 3.6.0
**Applies to:** Linux and Windows Server installations

---

## Table of Contents

1. [Overview](#1-overview)
2. [How Licensing Works](#2-how-licensing-works)
3. [Activating a License (Linux)](#3-activating-a-license-linux)
4. [Activating a License (Windows)](#4-activating-a-license-windows)
5. [Starting Services After Licensing](#5-starting-services-after-licensing)
6. [License Renewal](#6-license-renewal)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Overview

Supra uses a hardware-locked licensing system to ensure each installation is authorized. Every Supra installation requires a valid license file tied to the specific machine it runs on.

The license is verified each time the Supra Search Engine starts. Without a valid license, the Search Engine will not start.

---

## 2. How Licensing Works

Each machine has a unique **Machine Fingerprint (MFP)** — a 64-character hex string derived from the machine's hardware identifiers (CPU, motherboard, and disk serial numbers).

The licensing process works as follows:

```
1. Install Supra on the target machine
2. Run the fingerprint tool to obtain the MFP
3. Send the MFP to your Supra vendor
4. Vendor generates a signed license file tied to your MFP
5. Place the license file on the machine
6. Start Supra services
```

The license file is cryptographically signed with RSA-2048. It cannot be forged, modified, or transferred to a different machine.

---

## 3. Activating a License (Linux)

### 3.1 Get the Machine Fingerprint

After running the Supra installer, execute:

```bash
sudo bash /opt/supra/opensearch/config/supra-license/get-fingerprint.sh
```

Output:

```
Machine Fingerprint (MFP): a1b2c3d4e5f6...  (64-character hex string)
```

### 3.2 Request a License

Send the MFP to your Supra vendor along with:

- Your organization name
- Desired license tier (if applicable)
- Number of cluster nodes (if applicable)

The vendor will provide a `license.key` file.

### 3.3 Install the License

Copy the `license.key` file to the license directory:

```bash
sudo cp license.key /opt/supra/opensearch/config/supra-license/
sudo chown supra:supra /opt/supra/opensearch/config/supra-license/license.key
sudo chmod 600 /opt/supra/opensearch/config/supra-license/license.key
```

### 3.4 Verify the License Directory

The following files should be present:

```bash
ls -la /opt/supra/opensearch/config/supra-license/
```

Expected contents:

| File                 | Description                          |
|----------------------|--------------------------------------|
| `public.key`         | RSA public key (installed by default)|
| `license.key`        | Your license file                    |
| `get-fingerprint.sh` | Fingerprint generation tool          |

---

## 4. Activating a License (Windows)

### 4.1 Get the Machine Fingerprint

After running the Supra installer, open PowerShell as Administrator and execute:

```powershell
powershell -File C:\supra\opensearch\config\supra-license\get-fingerprint.ps1
```

Output:

```
Machine Fingerprint (MFP): a1b2c3d4e5f6...  (64-character hex string)
```

### 4.2 Request a License

Send the MFP to your Supra vendor (same process as Linux — see section 3.2).

### 4.3 Install the License

```powershell
Copy-Item license.key -Destination C:\supra\opensearch\config\supra-license\
```

### 4.4 Verify the License Directory

```powershell
Get-ChildItem C:\supra\opensearch\config\supra-license\
```

Expected contents:

| File                    | Description                          |
|-------------------------|--------------------------------------|
| `public.key`            | RSA public key (installed by default)|
| `license.key`           | Your license file                    |
| `get-fingerprint.ps1`   | Fingerprint generation tool          |

---

## 5. Starting Services After Licensing

### Linux

```bash
# Start Search Engine
sudo systemctl start supra-search

# Wait for it to become ready (check logs or poll the endpoint)
curl -sk https://localhost:9200

# Start remaining services
sudo systemctl start supra-dashboards
sudo systemctl start supra-log-collector
```

### Windows

```powershell
# Start Search Engine
nssm start SupraSearch

# Wait for it to become ready
Invoke-WebRequest -Uri https://localhost:9200 -SkipCertificateCheck

# Start remaining services
nssm start SupraDashboards
nssm start SupraLogCollector
```

On first start after licensing, you will also need to initialize the security index. See the relevant installation guide for your platform.

---

## 6. License Renewal

When your license approaches its expiry date:

1. Run the fingerprint tool again to confirm the MFP (it should be the same unless hardware has changed)
2. Send the MFP to your vendor to request a renewed license
3. Replace the existing `license.key` with the new one
4. Restart the Search Engine:

**Linux:**

```bash
sudo systemctl restart supra-search
```

**Windows:**

```powershell
nssm restart SupraSearch
```

---

## 7. Troubleshooting

### "License file not found"

The `license.key` file is missing from the `config/supra-license/` directory. Follow sections 3 or 4 to install it.

The error message includes the machine's MFP, which you can use to request a license.

### "License signature verification failed"

The license file has been corrupted or tampered with. Request a fresh license from your vendor.

### "License fingerprint mismatch"

The license was generated for a different machine. The error message shows both the licensed fingerprint and the current machine's fingerprint.

This can happen if:

- The license was copied from another machine
- Hardware components (CPU, motherboard, or primary disk) were replaced

Request a new license using the current machine's MFP.

### "License has expired"

The license has passed its expiry date. Contact your vendor for renewal. The error message includes the MFP.

### "Public key not found"

The `public.key` file is missing from the `config/supra-license/` directory. This file is normally installed automatically by the installer. Re-run the installer or contact your vendor.

### MFP changed after hardware replacement

If you replace the CPU, motherboard, or primary disk, the MFP will change and your existing license will become invalid. You will need to request a new license with the new MFP.

### Getting the MFP from Java (alternative)

If the shell scripts are not available, you can get the MFP directly from the Java class included in the plugin:

```bash
# Linux
cd /opt/supra/opensearch
./jdk/bin/java -cp "plugins/supra-license-validator/*" com.supra.plugins.MachineFingerprint
```

```powershell
# Windows
cd C:\supra\opensearch
.\jdk\bin\java -cp "plugins\supra-license-validator\*" com.supra.plugins.MachineFingerprint
```

---

*Document generated for Supra Stack v3.6.0*
