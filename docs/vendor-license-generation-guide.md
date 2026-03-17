# Supra License Generation Guide (Vendor)

**Version:** 3.6.0
**Audience:** Supra vendors and license administrators
**Confidentiality:** Internal use only — do not distribute to customers

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [One-Time Setup: Generate RSA Keypair](#3-one-time-setup-generate-rsa-keypair)
4. [Generating a License](#4-generating-a-license)
5. [License File Format](#5-license-file-format)
6. [License Parameters Reference](#6-license-parameters-reference)
7. [Distributing Licenses](#7-distributing-licenses)
8. [Key Management](#8-key-management)
9. [Examples](#9-examples)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

Supra uses RSA-2048 signed, hardware-locked licenses. As a vendor, you:

1. Generate an RSA keypair (one-time setup)
2. Ship the **public key** with every Supra installer
3. Receive a Machine Fingerprint (MFP) from each customer
4. Sign a license with the **private key** and send `license.key` to the customer

The private key must never leave your secure environment. The public key is safe to distribute.

---

## 2. Prerequisites

- **Java 17+** (included with OpenSearch, or install separately)
- **OpenSSL** (for key generation via shell script, optional)
- Access to the `opensearch-license-validator/license-generator/` directory

---

## 3. One-Time Setup: Generate RSA Keypair

You need to generate an RSA-2048 keypair once. The same keypair is used for all licenses.

### Option A: Using the shell script

```bash
cd opensearch-license-validator
bash generate-keys.sh
```

This creates:

```
keys/private.key   # RSA private key (PEM format) — KEEP SECRET
keys/public.key    # RSA public key (PEM format) — ship with installers
```

### Option B: Using the Java tool

```bash
cd opensearch-license-validator/license-generator
javac LicenseGenerator.java
java LicenseGenerator --generate-keys --output-dir ../keys
```

### Option C: Using OpenSSL directly

```bash
mkdir -p keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/private.key
openssl rsa -pubout -in keys/private.key -out keys/public.key
```

All three methods produce compatible PEM keys.

---

## 4. Generating a License

### 4.1 Compile the License Generator

```bash
cd opensearch-license-validator/license-generator
javac LicenseGenerator.java
```

### 4.2 Create a License

When a customer sends you their Machine Fingerprint (MFP), run:

```bash
java LicenseGenerator --create-license \
    --fingerprint <MFP> \
    --customer "Customer Name" \
    --expiry 2027-12-31 \
    --private-key ../keys/private.key \
    --output license.key
```

This produces a `license.key` file to send to the customer.

### 4.3 Full Command Reference

```
java LicenseGenerator --create-license
    --fingerprint <MFP>          # Required: 64-char hex machine fingerprint
    --customer <name>             # Required: customer/organization name
    --expiry <YYYY-MM-DD>         # Required: license expiry date
    --private-key <path>          # Required: path to RSA private key (PEM)
    [--tier <tier>]               # Optional: license tier (default: standard)
    [--max-nodes <n>]             # Optional: max cluster nodes (default: 1)
    [--output <path>]             # Optional: output file (default: license.key)
```

---

## 5. License File Format

The license file contains a single line in the format:

```
<base64-encoded-JSON-payload>.<base64-encoded-RSA-signature>
```

The JSON payload contains:

```json
{
    "customer": "Acme Corp",
    "fingerprint": "a1b2c3d4e5f6...",
    "issuedAt": "2026-03-17",
    "expiresAt": "2027-12-31",
    "tier": "standard",
    "maxNodes": 1
}
```

The signature is computed over the raw JSON bytes using `SHA256withRSA`.

The Supra plugin validates the license by:

1. Splitting the file on `.`
2. Verifying the RSA signature against the public key
3. Decoding and parsing the JSON payload
4. Recomputing the machine fingerprint locally
5. Comparing the fingerprint in the license with the local fingerprint
6. Checking that the current date is before `expiresAt`

---

## 6. License Parameters Reference

| Parameter     | Type   | Required | Description                                          |
|---------------|--------|----------|------------------------------------------------------|
| `fingerprint` | String | Yes      | 64-character hex SHA-256 of hardware identifiers     |
| `customer`    | String | Yes      | Customer or organization name                        |
| `expiry`      | Date   | Yes      | License expiry date in `YYYY-MM-DD` format           |
| `private-key` | Path   | Yes      | Path to the RSA private key file (PEM, PKCS#8)       |
| `tier`        | String | No       | License tier: `standard`, `enterprise`, etc.         |
| `max-nodes`   | Int    | No       | Maximum number of nodes in the cluster (default: 1)  |
| `output`      | Path   | No       | Output file path (default: `license.key`)            |

---

## 7. Distributing Licenses

### What to send to customers

- `license.key` — the signed license file

### What to ship with every installer

- `public.key` — the RSA public key (same for all customers)
- `get-fingerprint.sh` (Linux) or `get-fingerprint.ps1` (Windows)

### Delivery method

The `license.key` file contains no secrets — it can be sent via email, file transfer, or any convenient method. It is cryptographically signed and cannot be tampered with.

---

## 8. Key Management

### Private key security

The RSA private key (`keys/private.key`) is the foundation of the entire licensing system.

- **Never** distribute the private key
- **Never** commit it to version control
- Store it in a secure location (encrypted drive, HSM, or secrets manager)
- Limit access to authorized personnel only
- Back up the key securely — if lost, you cannot generate licenses compatible with deployed public keys

### Key rotation

If you need to rotate keys:

1. Generate a new keypair
2. Ship the new `public.key` with future installers
3. Existing installations must be updated with the new `public.key` to accept licenses signed with the new private key
4. Old licenses remain valid until their expiry, but only on installations using the old `public.key`

### Revoking a license

There is no built-in revocation mechanism. To effectively revoke a license:

- Issue a replacement license with an earlier expiry date
- On the next renewal cycle, decline to issue a new license

---

## 9. Examples

### Generate a standard 1-year license

```bash
java LicenseGenerator --create-license \
    --fingerprint e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
    --customer "Acme Corp" \
    --expiry 2027-03-17 \
    --private-key ../keys/private.key
```

### Generate an enterprise license for a 3-node cluster

```bash
java LicenseGenerator --create-license \
    --fingerprint e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
    --customer "Big Enterprise Inc" \
    --expiry 2028-01-01 \
    --tier enterprise \
    --max-nodes 3 \
    --private-key ../keys/private.key \
    --output big-enterprise-license.key
```

### Batch license generation

For generating multiple licenses, you can script the process:

```bash
#!/bin/bash
# batch-generate.sh
# Input: CSV file with format: customer,fingerprint,expiry

while IFS=',' read -r customer fingerprint expiry; do
    output="${customer// /_}-license.key"
    java LicenseGenerator --create-license \
        --fingerprint "$fingerprint" \
        --customer "$customer" \
        --expiry "$expiry" \
        --private-key ../keys/private.key \
        --output "$output"
    echo "Generated: $output"
done < customers.csv
```

---

## 10. Troubleshooting

### "InvalidKeySpecException" when signing

The private key file is not in PKCS#8 format. If you generated the key with older OpenSSL, convert it:

```bash
openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt \
    -in old-private.key -out keys/private.key
```

### Customer reports "fingerprint mismatch"

The customer's hardware may have changed, or they ran the fingerprint tool on a different machine. Ask them to re-run the fingerprint tool on the exact machine where Supra is installed and send the new MFP.

### Customer reports "signature verification failed"

The `public.key` on their machine does not match the private key used to sign the license. Ensure the customer has the correct `public.key` installed. This can happen if:

- The keypair was rotated but the customer has an old public key
- The `public.key` file was corrupted during transfer

### Fingerprint is all zeros or "UNKNOWN"

The fingerprint tool could not read hardware identifiers. On Linux, this typically means:

- The tool was not run with `sudo` (required to read DMI data)
- The machine is a virtual machine with no DMI data exposed

On Windows:

- WMI service may be disabled
- Running in a container environment without hardware access

### Verifying a license file manually

To inspect a license without deploying it:

```bash
# Extract and decode the payload (first part before the dot)
echo "<license-content>" | cut -d. -f1 | base64 -d
```

This prints the JSON payload so you can verify the customer, fingerprint, and expiry.

---

## Quick Reference

```
# One-time setup
bash generate-keys.sh

# Compile (once)
cd license-generator && javac LicenseGenerator.java

# Generate license
java LicenseGenerator --create-license \
    --fingerprint <MFP> \
    --customer "<name>" \
    --expiry <YYYY-MM-DD> \
    --private-key ../keys/private.key \
    --output license.key
```

---

*Document generated for Supra Stack v3.6.0 — Vendor internal use only*
