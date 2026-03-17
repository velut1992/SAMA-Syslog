# Supra Machine Fingerprint Generator (Windows)
# Produces the same fingerprint as MachineFingerprint.java

$ErrorActionPreference = "SilentlyContinue"

function Get-WmicValue {
    param([string]$Query)
    try {
        $result = & wmic $Query.Split(' ') 2>$null | Where-Object { $_.Trim() -ne "" } | Select-Object -Skip 1 -First 1
        if ($result) { return $result.Trim() }
    } catch {}
    return "UNKNOWN"
}

$cpuId = Get-WmicValue "cpu get ProcessorId"
$boardSerial = Get-WmicValue "baseboard get SerialNumber"
$diskSerial = Get-WmicValue "diskdrive where Index=0 get SerialNumber"

if ([string]::IsNullOrWhiteSpace($cpuId)) { $cpuId = "UNKNOWN" }
if ([string]::IsNullOrWhiteSpace($boardSerial)) { $boardSerial = "UNKNOWN" }
if ([string]::IsNullOrWhiteSpace($diskSerial)) { $diskSerial = "UNKNOWN" }

$raw = "${cpuId}|${boardSerial}|${diskSerial}"
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
$fingerprint = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })

Write-Host "Machine Fingerprint (MFP): $fingerprint"
