################################################################################
# Supra Log Collector Setup for Windows Server
################################################################################

$ErrorActionPreference = "Stop"
$BaseDir = "C:\Hitachi"

Write-Host "=== Supra Log Collector Setup (Windows Server) ==="

# Step 1: Check for log collector runtime
$fluentdExe = $null
$tdAgentPath = "C:\opt\td-agent"

if (Test-Path $tdAgentPath) {
    $fluentdExe = Join-Path $tdAgentPath "bin\fluentd.bat"
    Write-Host "  Log Collector runtime found at $tdAgentPath"
} elseif (Get-Command fluentd -ErrorAction SilentlyContinue) {
    $fluentdExe = (Get-Command fluentd).Source
    Write-Host "  Log Collector runtime found at $fluentdExe"
} else {
    Write-Host "Log Collector runtime not found. Attempting to install via gem..." -ForegroundColor Yellow

    if (Get-Command gem -ErrorAction SilentlyContinue) {
        & gem install fluentd --no-document
        & gem install fluent-plugin-opensearch --no-document
        $fluentdExe = (Get-Command fluentd -ErrorAction SilentlyContinue).Source
        if ($fluentdExe) {
            Write-Host "  Log Collector runtime installed via gem."
        }
    } else {
        Write-Host "ERROR: Ruby gem not found." -ForegroundColor Red
        Write-Host "  Option 1: Install td-agent from https://td-agent-package-browser.herokuapp.com/4/windows"
        Write-Host "  Option 2: Install RubyInstaller from https://rubyinstaller.org/ then: gem install fluentd fluent-plugin-opensearch"
        Write-Host "Skipping Log Collector setup."
        exit 0
    }
}

# Step 2: Verify
if ($fluentdExe) {
    & $fluentdExe --version
}

Write-Host ""
Write-Host "Supra Log Collector setup complete!"
Write-Host "Binary: $fluentdExe"
Write-Host "Config: $BaseDir\fluent\fluent.conf"
Write-Host ""
Write-Host "To start manually:"
Write-Host "  & `"$fluentdExe`" -c `"$BaseDir\fluent\fluent.conf`""
