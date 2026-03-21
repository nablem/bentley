#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory = $true)]
    [string]$Server,
    [string]$ServerConfigDir = $(if ($env:SERVER_CONFIG_DIR) { $env:SERVER_CONFIG_DIR } else { "/etc/bentley" }),
    [string]$AppReleaseBin = $(if ($env:APP_RELEASE_BIN) { $env:APP_RELEASE_BIN } else { "/opt/bentley/_build/prod/rel/bentley/bin/bentley" }),
    [string]$ServiceGroup = $(if ($env:SERVICE_GROUP) { $env:SERVICE_GROUP } else { "bentley" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "==> Uploading config files"
scp .\notifiers.yaml .\snipers.yaml .\suspicious_terms.txt "$Server`:/tmp/"
if ($LASTEXITCODE -ne 0) {
    throw "scp failed with exit code $LASTEXITCODE"
}

$remote = @"
set -euo pipefail;
sudo install -o root -g '$ServiceGroup' -m 640 /tmp/notifiers.yaml '$ServerConfigDir/notifiers.yaml';
sudo install -o root -g '$ServiceGroup' -m 640 /tmp/snipers.yaml '$ServerConfigDir/snipers.yaml';
sudo install -o root -g '$ServiceGroup' -m 640 /tmp/suspicious_terms.txt '$ServerConfigDir/suspicious_terms.txt';
'$AppReleaseBin' rpc Bentley.Notifiers.reload;
'$AppReleaseBin' rpc Bentley.Snipers.reload;
'$AppReleaseBin' rpc Bentley.SuspiciousTermsCache.reload
"@

Write-Host "==> Installing + reloading"
ssh -T $Server ($remote -replace "`r", "")
if ($LASTEXITCODE -ne 0) {
    throw "remote install/reload failed with exit code $LASTEXITCODE"
}

Write-Host "==> Done"