################################################################################
# Supra License Inspector (Windows)
#
# Decodes a Supra license file into human-readable form so operators can see at a
# glance whether a license is Permanent or Temporary, its validity window, tier,
# licensed device/node counts and which machine it is bound to.
#
# The license file is NOT encrypted -- it is base64(JSON payload).base64(RSA
# signature). The signature only makes it tamper-proof; the details are plainly
# readable, so this tool needs no private key. If the matching public.key is
# available it will additionally verify the signature so you know the file is
# authentic and unmodified.
#
# This is the Windows counterpart of supra-license-info.sh and produces the same
# report and the same exit codes.
#
# Usage:
#   .\supra-license-info.ps1 [-LicenseFile <path>] [-PublicKey <path>]
#
# Defaults (typical install layout):
#   LicenseFile -> .\license.key, then config\supra-license\license.key,
#                  then C:\supra\opensearch\config\supra-license\license.key
#   PublicKey   -> alongside the license file
#
# Exit codes: 0 = ACTIVE, 1 = usage/parse error, 2 = EXPIRED or UNTRUSTED
################################################################################

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$LicenseFile,

    [Parameter(Position = 1)]
    [string]$PublicKey
)

$ErrorActionPreference = "Stop"

# --- locate the license file --------------------------------------------------
if (-not $LicenseFile) {
    $candidates = @(
        (Join-Path $PSScriptRoot "license.key")
        ".\license.key"
        "config\supra-license\license.key"
        "C:\supra\opensearch\config\supra-license\license.key"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { $LicenseFile = $c; break }
    }
}

if (-not $LicenseFile -or -not (Test-Path -LiteralPath $LicenseFile -PathType Leaf)) {
    Write-Error "license file not found. Usage: .\supra-license-info.ps1 [-LicenseFile <path>] [-PublicKey <path>]"
    exit 1
}

# default public key location: next to the license file
if (-not $PublicKey) {
    $cand = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $LicenseFile)) "public.key"
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $PublicKey = $cand }
}

# --- split and decode ---------------------------------------------------------
$content = (Get-Content -LiteralPath $LicenseFile -Raw) -replace '\s', ''
$dot = $content.IndexOf('.')
if ($dot -lt 1 -or $dot -eq $content.Length - 1) {
    Write-Error "invalid license format (expected <payload>.<signature>)."
    exit 1
}
$payloadB64 = $content.Substring(0, $dot)
$sigB64     = $content.Substring($dot + 1)

try {
    $payloadBytes = [Convert]::FromBase64String($payloadB64)
    $payload      = [Text.Encoding]::UTF8.GetString($payloadBytes)
} catch {
    Write-Error "could not decode license payload."
    exit 1
}

try {
    $lic = $payload | ConvertFrom-Json
} catch {
    Write-Error "license payload is not valid JSON."
    exit 1
}

function Get-Field($obj, $name) {
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return "$($p.Value)" }
    return ''
}

$customer    = Get-Field $lic 'customer'
$fingerprint = Get-Field $lic 'fingerprint'
$issued      = Get-Field $lic 'issuedAt'
$expires     = Get-Field $lic 'expiresAt'
$type        = Get-Field $lic 'type'        # may be absent on older licenses
$tier        = Get-Field $lic 'tier'
$maxNodes    = Get-Field $lic 'maxNodes'
$maxDevices  = Get-Field $lic 'maxDevices'  # may be absent on older licenses

# --- derive permanent vs temporary + remaining validity -----------------------
$licenseKind = ''
$validity    = ''
$status      = 'ACTIVE'

if ($type) {
    # explicit signed type wins, if present
    if ($type -in @('permanent', 'perpetual')) { $licenseKind = 'Permanent (perpetual)' }
    else                                       { $licenseKind = 'Temporary' }
}

$expYear = 0
if ($expires -match '^(\d{4})') { $expYear = [int]$Matches[1] }

if ($expYear -ge 9999) {
    if (-not $licenseKind) { $licenseKind = 'Permanent (perpetual)' }
    $validity = 'No expiry'
} else {
    if (-not $licenseKind) { $licenseKind = 'Temporary' }
    [datetime]$expDate = [datetime]::MinValue
    if ([datetime]::TryParse($expires, [ref]$expDate)) {
        $days = [math]::Floor(($expDate - (Get-Date)).TotalDays)
        if ($days -lt 0) {
            $status   = 'EXPIRED'
            $validity = "Expired $([math]::Abs($days)) day(s) ago"
        } else {
            $validity = "$days day(s) remaining"
        }
    } else {
        $validity = "Expires $expires"
    }
}

# --- optional signature verification ------------------------------------------
# PowerShell 5.1 runs on .NET Framework, which has no RSA.ImportSubjectPublicKeyInfo,
# so the PEM SubjectPublicKeyInfo is unwrapped by hand down to the RSA modulus and
# exponent. The provider is forced to PROV_RSA_AES (24) because the default
# PROV_RSA_FULL provider cannot verify SHA-256 signatures.
function Read-Asn1Length([byte[]]$der, [ref]$pos) {
    $first = $der[$pos.Value]; $pos.Value++
    if ($first -lt 0x80) { return [int]$first }
    $n = $first -band 0x7F
    $len = 0
    for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $der[$pos.Value]; $pos.Value++ }
    return $len
}

function Read-Asn1Integer([byte[]]$der, [ref]$pos) {
    if ($der[$pos.Value] -ne 0x02) { throw "expected INTEGER" }
    $pos.Value++
    $len = Read-Asn1Length $der $pos
    $bytes = New-Object byte[] $len
    [Array]::Copy($der, $pos.Value, $bytes, 0, $len)
    $pos.Value += $len
    # strip the ASN.1 leading zero sign byte
    if ($bytes.Length -gt 1 -and $bytes[0] -eq 0x00) {
        $trimmed = New-Object byte[] ($bytes.Length - 1)
        [Array]::Copy($bytes, 1, $trimmed, 0, $trimmed.Length)
        $bytes = $trimmed
    }
    return ,$bytes
}

function Convert-PemToRsaParameters([string]$pemPath) {
    $pem = Get-Content -LiteralPath $pemPath -Raw
    $b64 = ($pem -replace '-----(BEGIN|END) PUBLIC KEY-----', '') -replace '\s', ''
    $der = [Convert]::FromBase64String($b64)

    $pos = 0
    if ($der[$pos] -ne 0x30) { throw "not a SubjectPublicKeyInfo SEQUENCE" }
    $pos++; [void](Read-Asn1Length $der ([ref]$pos))

    # AlgorithmIdentifier SEQUENCE -- skipped wholesale
    if ($der[$pos] -ne 0x30) { throw "missing AlgorithmIdentifier" }
    $pos++
    $algLen = Read-Asn1Length $der ([ref]$pos)
    $pos += $algLen

    # BIT STRING wrapping the RSAPublicKey
    if ($der[$pos] -ne 0x03) { throw "missing BIT STRING" }
    $pos++; [void](Read-Asn1Length $der ([ref]$pos))
    if ($der[$pos] -ne 0x00) { throw "unexpected unused-bit count" }
    $pos++

    # RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    if ($der[$pos] -ne 0x30) { throw "missing RSAPublicKey SEQUENCE" }
    $pos++; [void](Read-Asn1Length $der ([ref]$pos))

    $modulus  = Read-Asn1Integer $der ([ref]$pos)
    $exponent = Read-Asn1Integer $der ([ref]$pos)

    $p = New-Object System.Security.Cryptography.RSAParameters
    $p.Modulus  = $modulus
    $p.Exponent = $exponent
    return $p
}

$sigResult = 'not checked (public.key unavailable)'
if ($PublicKey -and (Test-Path -LiteralPath $PublicKey -PathType Leaf)) {
    try {
        $rsaParams = Convert-PemToRsaParameters $PublicKey
        $csp = New-Object System.Security.Cryptography.CspParameters(24)  # PROV_RSA_AES
        $csp.Flags = [System.Security.Cryptography.CspProviderFlags]::UseMachineKeyStore
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider($csp)
        $rsa.ImportParameters($rsaParams)

        $sigBytes = [Convert]::FromBase64String($sigB64)
        if ($rsa.VerifyData($payloadBytes, 'SHA256', $sigBytes)) {
            $sigResult = 'VALID (signature authentic, not tampered)'
        } else {
            $sigResult = 'INVALID (signature does NOT match -- file may be tampered or wrong public key)'
            $status = 'UNTRUSTED'
        }
    } catch {
        $sigResult = "not checked (verification error: $($_.Exception.Message))"
    } finally {
        if ($rsa) { $rsa.Dispose() }
    }
}

# --- report -------------------------------------------------------------------
function Or-Unknown($v, $fallback = '<unknown>') { if ($v) { return $v } return $fallback }

Write-Host "=============================================="
Write-Host "          Supra License Information"
Write-Host "=============================================="
Write-Host "  Customer        : $(Or-Unknown $customer)"
Write-Host "  License type    : $licenseKind"
Write-Host "  Validity        : $validity"
Write-Host "  Issued on       : $(Or-Unknown $issued)"
Write-Host "  Expires on      : $(Or-Unknown $expires)"
Write-Host "  Tier            : $(Or-Unknown $tier)"
Write-Host "  Max nodes       : $(Or-Unknown $maxNodes)"
Write-Host "  Max devices     : $(Or-Unknown $maxDevices 'not specified')"
Write-Host "  Bound to machine: $(Or-Unknown $fingerprint)"
Write-Host "  Signature       : $sigResult"
Write-Host "  Overall status  : $status"
Write-Host "=============================================="
Write-Host ""
Write-Host "Note: this machine's own fingerprint can be printed with get-fingerprint.ps1."
Write-Host "It must match 'Bound to machine' above for the license to be accepted."

# exit non-zero if the license is not usable, so it can be scripted
if ($status -eq 'ACTIVE') { exit 0 } else { exit 2 }
