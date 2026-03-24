# Supra Machine Fingerprint Generator (Windows)
# Produces the same fingerprint as MachineFingerprint.java
#
# Uses Get-CimInstance (stable, modern) with wmic as fallback for older systems.
# The fingerprint is derived from: CPU ID | Motherboard Serial | Disk Serial

$ErrorActionPreference = "SilentlyContinue"

function Get-HardwareValue {
    param(
        [string]$CimClass,
        [string]$CimProperty,
        [string]$CimFilter,
        [string]$WmicQuery
    )
    # Primary: Get-CimInstance (reliable on Windows 10/11)
    try {
        $params = @{ ClassName = $CimClass; ErrorAction = "Stop" }
        if ($CimFilter) { $params["Filter"] = $CimFilter }
        $result = (Get-CimInstance @params | Select-Object -First 1).$CimProperty
        if (-not [string]::IsNullOrWhiteSpace($result)) {
            return $result.Trim()
        }
    } catch {}
    # Fallback: wmic (for older Windows versions)
    try {
        $result = & wmic $WmicQuery.Split(' ') 2>$null | Where-Object { $_.Trim() -ne "" } | Select-Object -Skip 1 -First 1
        if ($result) { return $result.Trim() }
    } catch {}
    return "UNKNOWN"
}

$cpuId = Get-HardwareValue -CimClass "Win32_Processor" -CimProperty "ProcessorId" -WmicQuery "cpu get ProcessorId"
$boardSerial = Get-HardwareValue -CimClass "Win32_BaseBoard" -CimProperty "SerialNumber" -WmicQuery "baseboard get SerialNumber"
$diskSerial = Get-HardwareValue -CimClass "Win32_DiskDrive" -CimProperty "SerialNumber" -CimFilter "Index=0" -WmicQuery "diskdrive where Index=0 get SerialNumber"

if ([string]::IsNullOrWhiteSpace($cpuId)) { $cpuId = "UNKNOWN" }
if ([string]::IsNullOrWhiteSpace($boardSerial)) { $boardSerial = "UNKNOWN" }
if ([string]::IsNullOrWhiteSpace($diskSerial)) { $diskSerial = "UNKNOWN" }

$raw = "${cpuId}|${boardSerial}|${diskSerial}"
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
$fingerprint = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })

Write-Host ""
Write-Host "Machine Fingerprint (MFP): $fingerprint"
Write-Host ""
Write-Host "Components (for debugging):"
Write-Host "  CPU ID:         $cpuId"
Write-Host "  Board Serial:   $boardSerial"
Write-Host "  Disk Serial:    $diskSerial"
Write-Host ""
