################################################################################
# Supra Dashboards Setup for Windows Server (Build from Source)
################################################################################

$ErrorActionPreference = "Stop"
$BaseDir = "C:\Hitachi"
$DashboardsDir = Join-Path $BaseDir "OpenSearch-Dashboards"

Write-Host "=== Supra Dashboards Setup (Build from Source - Windows) ==="

# Step 1: Check Node.js
Write-Host "Checking Node.js..."
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Node.js not found." -ForegroundColor Red
    Write-Host "  Install nvm-windows from: https://github.com/coreybutler/nvm-windows"
    Write-Host "  Then: nvm install <version from .nvmrc>"
    exit 1
}

Push-Location $DashboardsDir
$requiredNode = Get-Content ".nvmrc" -ErrorAction SilentlyContinue
if ($requiredNode) {
    Write-Host "Required Node.js version: $requiredNode"
    $currentNode = & node --version
    Write-Host "Current Node.js version:  $currentNode"
}

# Step 2: Install yarn via corepack
Write-Host "Installing yarn via corepack..."
& npm i -g corepack
& corepack install

# Step 3: Bootstrap
Write-Host "Bootstrapping Supra Dashboards (this may take a while)..."
& yarn osd bootstrap

Pop-Location

Write-Host ""
Write-Host "Supra Dashboards bootstrapped at: $DashboardsDir"
Write-Host ""
Write-Host "To start in dev mode:"
Write-Host "  cd $DashboardsDir"
Write-Host "  yarn start"
Write-Host ""
Write-Host "Access at: http://localhost:5601"
