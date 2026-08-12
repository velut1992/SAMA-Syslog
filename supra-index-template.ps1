################################################################################
# Supra OpenSearch index template (Windows) - run ONCE on the production server.
#
# Windows counterpart of supra-index-template.sh. This is the piece that makes
# the "400 - Rejected by OpenSearch" errors structurally impossible:
#   * date_detection / numeric_detection OFF  -> OpenSearch never guesses a type
#   * every dynamic field mapped as keyword    -> a value that is a number in one
#     event and a string in another can NEVER conflict (both stored as keyword)
#   * ignore_malformed = true                  -> a bad value is dropped from the
#     doc instead of rejecting the whole document
#   * total_fields.limit raised                -> Windows events add many fields
#   * number_of_replicas 0                     -> single-node box stays GREEN
#
# Applies to every supra-* index (supra-ied-*, supra-network-*, supra-windows-*,
# supra-logs-*). Re-running is safe (idempotent PUT).
#
# Run this AFTER SupraSearch is started and securityadmin has been run.
#
# Usage:
#   powershell -File supra-index-template.ps1
#   powershell -File supra-index-template.ps1 -OsPass 'YourNewPassword'
#
# Exit codes: 0 = template acknowledged, 1 = not acknowledged within the window
################################################################################

[CmdletBinding()]
param(
    [string]$OsUrl  = $(if ($env:OS_URL)  { $env:OS_URL }  else { "https://localhost:9200" }),
    [string]$OsUser = $(if ($env:OS_USER) { $env:OS_USER } else { "admin" }),
    [string]$OsPass = $(if ($env:OS_PASS) { $env:OS_PASS } else { "admin" }),
    [int]$MaxTries  = 60,     # 60 x 5s = up to 5 minutes
    [int]$SleepSecs = 5
)

$ErrorActionPreference = "Stop"
$endpoint = "$OsUrl/_index_template/supra-logs"

# The node presents the security plugin's demo certificate, which is self-signed.
# PowerShell 5.1 has no -SkipCertificateCheck, so validation is disabled globally
# for this process only.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

$body = @'
{
  "index_patterns": ["supra-*"],
  "priority": 200,
  "template": {
    "settings": {
      "index.number_of_replicas": 0,
      "index.refresh_interval": "5s",
      "index.mapping.total_fields.limit": 4000,
      "index.mapping.ignore_malformed": true
    },
    "mappings": {
      "date_detection": false,
      "numeric_detection": false,
      "dynamic_templates": [
        { "messages_as_text": { "match": "*essage", "mapping": { "type": "text" } } },
        { "everything_else_as_keyword": { "match_mapping_type": "*", "mapping": { "type": "keyword", "ignore_above": 8191 } } }
      ],
      "properties": {
        "@timestamp":        { "type": "date" },
        "message":           { "type": "text" },
        "Message":           { "type": "text" },
        "raw_message":       { "type": "text" },
        "event_description": { "type": "text" }
      }
    }
  }
}
'@

$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${OsUser}:${OsPass}"))

Write-Host "Installing index template 'supra-logs' on $OsUrl ..."

# The PUT is idempotent. It is issued repeatedly because a service that has
# opened :9200 has NOT necessarily finished initializing OpenSearch Security -
# a PUT sent too early comes back "OpenSearch Security not initialized".
function Invoke-PutTemplate {
    try {
        $resp = Invoke-WebRequest -Uri $endpoint -Method Put `
            -Headers @{ Authorization = $authHeader } `
            -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -UseBasicParsing -TimeoutSec 30
        return $resp.Content
    } catch {
        # Echo the error body and let the retry loop decide, mirroring the
        # shell version rather than aborting on the first 503/401.
        $r = $_.Exception.Response
        if ($r) {
            try {
                $reader = New-Object IO.StreamReader($r.GetResponseStream())
                return $reader.ReadToEnd()
            } catch { return '' }
        }
        return ''
    }
}

$response = ''
for ($attempt = 1; $attempt -le $MaxTries; $attempt++) {
    $response = Invoke-PutTemplate
    if ($response -match '"acknowledged"\s*:\s*true') { break }

    if ($response -match '(?i)not initialized') {
        Write-Host "  attempt $attempt/$MaxTries : OpenSearch Security still initializing; retrying in ${SleepSecs}s..."
    } elseif (-not $response) {
        Write-Host "  attempt $attempt/$MaxTries : no response yet (cluster starting); retrying in ${SleepSecs}s..."
    } else {
        Write-Host "  attempt $attempt/$MaxTries : not acknowledged yet; retrying in ${SleepSecs}s..."
    }
    Start-Sleep -Seconds $SleepSecs
}

Write-Host $response
if ($response -match '"acknowledged"\s*:\s*true') {
    Write-Host "OK: template installed." -ForegroundColor Green
    Write-Host "NOTE: existing supra-* indices keep their old mapping. The template"
    Write-Host "      applies to indices created from now on (a new one rolls daily"
    Write-Host "      with logstash_format). To apply today immediately, delete the"
    Write-Host "      current bad index, e.g.:  supra-windows-$(Get-Date -Format 'yyyy.MM.dd')"
    exit 0
} else {
    Write-Warning "did not see acknowledged:true after $MaxTries attempts - check the response above."
    exit 1
}
