################################################################################
# Supra Search Engine Setup for Windows Server (Build from Source)
################################################################################

$ErrorActionPreference = "Stop"
$BaseDir = "C:\Hitachi"
$OpenSearchDir = Join-Path $BaseDir "OpenSearch"

Write-Host "=== Supra Search Engine Setup (Build from Source - Windows) ==="

# Step 1: Verify prerequisites
Write-Host "Checking prerequisites..."
try {
    $javaVer = & java -version 2>&1 | Select-Object -First 1
    if ($javaVer -notmatch "17|21|24") {
        Write-Host "ERROR: JDK 17+ is required. Download from: https://adoptium.net/" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Java: $javaVer"
} catch {
    Write-Host "ERROR: Java not found in PATH. Install JDK 17+ from https://adoptium.net/" -ForegroundColor Red
    exit 1
}

$env:JAVA_HOME = (Get-Command java).Source | Split-Path | Split-Path
Write-Host "Using JAVA_HOME=$env:JAVA_HOME"

# Step 2: Build
Write-Host "Building Supra Search Engine (this may take a while)..."
Push-Location $OpenSearchDir
& .\gradlew.bat :distribution:archives:windows-zip:assemble -Dbuild.snapshot=false
Pop-Location

# Step 3: Locate the distribution zip
$distZip = Get-ChildItem -Path (Join-Path $OpenSearchDir "distribution\archives\windows-zip\build\distributions") -Filter "opensearch-*.zip" | Select-Object -First 1
if (-not $distZip) {
    Write-Host "ERROR: Build output not found. Check build logs." -ForegroundColor Red
    exit 1
}
Write-Host "Built distribution: $($distZip.FullName)"

# Step 4: Extract to install location
$InstallDir = Join-Path $BaseDir "opensearch-dist"
Write-Host "Extracting to $InstallDir..."
if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$tempExtract = Join-Path $env:TEMP "os-build-extract"
if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
Expand-Archive -Path $distZip.FullName -DestinationPath $tempExtract -Force
$topDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
if ($topDir) {
    Get-ChildItem -Path $topDir.FullName | Move-Item -Destination $InstallDir -Force
} else {
    Get-ChildItem -Path $tempExtract | Move-Item -Destination $InstallDir -Force
}
Remove-Item -Recurse -Force $tempExtract

Write-Host ""
Write-Host "Supra Search Engine built and installed to: $InstallDir"
Write-Host ""
Write-Host "To start:"
Write-Host "  & `"$InstallDir\bin\opensearch.bat`""
Write-Host ""
Write-Host "Verify with:"
Write-Host "  Invoke-WebRequest -Uri https://localhost:9200 -SkipCertificateCheck"
