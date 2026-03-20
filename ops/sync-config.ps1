#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [Parameter(Mandatory = $true)]
    [string]$Server,
    [string]$ServerConfigDir = $(if ($env:SERVER_CONFIG_DIR) { $env:SERVER_CONFIG_DIR } else { "/etc/bentley" }),
    [string]$AppReleaseBin = $(if ($env:APP_RELEASE_BIN) { $env:APP_RELEASE_BIN } else { "/opt/bentley/_build/prod/rel/bentley/bin/bentley" }),
    [string]$ServiceGroup = $(if ($env:SERVICE_GROUP) { $env:SERVICE_GROUP } else { "bentley" })
)

# Push local notifiers.yaml, snipers.yaml, and suspicious_terms.txt to the
# server and trigger a live reload - no release rebuild or restart required.
#
# Usage:
#   .\ops\sync-config.ps1 user@your-server
#
# Optional overrides:
#   -ServerConfigDir /etc/bentley
#   -AppReleaseBin /opt/bentley/_build/prod/rel/bentley/bin/bentley
#   -ServiceGroup bentley

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    throw "scp command not found. Install OpenSSH Client on Windows first."
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "ssh command not found. Install OpenSSH Client on Windows first."
}

Write-Host "==> Syncing config files to $Server:/tmp/"
scp .\notifiers.yaml .\snipers.yaml .\suspicious_terms.txt "$Server`:/tmp/"

$remoteScript = @'
CONFIG_DIR="$1"
BIN="$2"
GROUP="$3"

sudo install -o root -g "$GROUP" -m 640 /tmp/notifiers.yaml        "$CONFIG_DIR/notifiers.yaml"
sudo install -o root -g "$GROUP" -m 640 /tmp/snipers.yaml          "$CONFIG_DIR/snipers.yaml"
sudo install -o root -g "$GROUP" -m 640 /tmp/suspicious_terms.txt  "$CONFIG_DIR/suspicious_terms.txt"

"$BIN" rpc "Bentley.Notifiers.reload()"
"$BIN" rpc "Bentley.Snipers.reload()"
"$BIN" rpc "Bentley.SuspiciousTermsCache.reload()"
'@

Write-Host "==> Installing files and reloading on server"
$remoteScript | ssh $Server "bash -s -- '$ServerConfigDir' '$AppReleaseBin' '$ServiceGroup'"

Write-Host "==> Done"