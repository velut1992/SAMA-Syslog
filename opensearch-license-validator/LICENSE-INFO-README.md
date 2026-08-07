# Inspecting a Supra license

A Supra license file (`license.key`) is **not encrypted** — it is a base64-encoded
JSON document plus an RSA signature (`<payload>.<signature>`). The signature makes
the file tamper-proof; it does **not** hide the contents. So the licensed details
(permanent vs temporary, validity, tier, device/node counts, bound machine) can be
read at any time without the vendor's private key.

## On the server (operators) — `supra-license-info.sh`

```bash
# auto-detects ./license.key or config/supra-license/license.key
./supra-license-info.sh

# or point at explicit files
./supra-license-info.sh /etc/supra-search/config/supra-license/license.key \
                        /etc/supra-search/config/supra-license/public.key
```

Sample output:

```
==============================================
          Supra License Information
==============================================
  Customer        : PowerGrid KPS-3
  License type    : Permanent (perpetual)
  Validity        : No expiry
  Issued on       : 2026-06-16
  Expires on      : 9999-12-31
  Tier            : standard
  Max nodes       : 1
  Max devices     : not specified
  Bound to machine: 6f719b0350eaaa44abddd...
  Signature       : VALID (signature authentic, not tampered)
  Overall status  : ACTIVE
==============================================
```

- **License type** — `Permanent (perpetual)` for a lifetime license (expiry
  `9999-12-31`), otherwise `Temporary` with days remaining / expired.
- **Signature** — if `public.key` and `openssl` are present, the file is verified
  as authentic and unmodified. Without them the details are still decoded but the
  signature line shows `not checked`.
- **Exit code** — `0` active, `2` expired/untrusted, `1` unreadable — so it can be
  used in monitoring scripts.

To confirm the license is bound to *this* machine, compare **Bound to machine**
with the output of `get-fingerprint.sh`.

## In OpenSearch Dashboards — `GET /_supra/license`

Once the license validator plugin is installed, the validated license is served
as JSON at `GET /_supra/license`. A customer can read it without shell access or
the private key: open **Dashboards → Dev Tools (Console)** and run

```
GET /_supra/license
```

Sample response:

```json
{
  "customer": "PowerGrid KPS-3",
  "license_type": "Permanent (perpetual)",
  "validity": "No expiry",
  "status": "ACTIVE",
  "issued_at": "2026-06-16",
  "expires_at": "9999-12-31",
  "tier": "standard",
  "max_nodes": 1,
  "max_devices": "not specified",
  "bound_to_machine": "6f719b0350eaaa44abddd...",
  "signature_verified": true
}
```

The endpoint only returns details after the plugin has verified the RSA
signature, the machine fingerprint and the expiry at node startup — so a
response always describes an authentic license bound to this machine. (If the
license were invalid the node would not have started.)

## Vendor side — `LicenseGenerator --inspect`

Same details, useful when issuing a license:

```bash
javac LicenseGenerator.java     # once
java LicenseGenerator --inspect --license powergrid-kps-3-lifetime.key
```
