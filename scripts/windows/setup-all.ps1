################################################################################
# Full Stack Setup: Supra Search Engine + Supra Log Collector
# + Supra Dashboards (Windows Server)
################################################################################

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "============================================"
Write-Host "  Full Stack Setup: Supra Search Engine"
Write-Host "  + Supra Log Collector"
Write-Host "  + Supra Dashboards (Windows Server)"
Write-Host "============================================"
Write-Host ""

Write-Host "[1/3] Setting up Supra Search Engine..."
& "$ScriptDir\setup-opensearch.ps1"
Write-Host ""

Write-Host "[2/3] Setting up Supra Log Collector..."
& "$ScriptDir\setup-log-collector.ps1"
Write-Host ""

Write-Host "[3/3] Setting up Supra Dashboards..."
& "$ScriptDir\setup-dashboards.ps1"
Write-Host ""

Write-Host "============================================"
Write-Host "  Setup Complete!"
Write-Host "============================================"
Write-Host ""
Write-Host "Services:"
Write-Host "  Supra Search Engine:   https://localhost:9200"
Write-Host "  Supra Dashboards:      http://localhost:5601"
Write-Host "  Supra Log Collector:   localhost:5140 (syslog), localhost:24224 (forward)"
Write-Host ""
Write-Host "Start all services (Admin PowerShell):"
Write-Host "  Start-Service SupraSearch"
Write-Host "  Start-Service SupraLogCollector"
Write-Host "  Start-Service SupraDashboards"
