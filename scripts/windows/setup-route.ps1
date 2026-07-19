# ============================================================================
# setup-route.ps1 - Add a route from Windows to the Multipass VM subnet.
# ----------------------------------------------------------------------------
# The route from Windows to the lab VMs (10.215.138.0/24) is not persistent
# across reboots, and WSL2's own IP changes on every boot too. This script
# resolves the current WSL2 IP dynamically and (re)adds the route. Requires
# Administrator - self-elevates if not already running elevated.
#
# Usage (from any PowerShell window):
#   .\setup-route.ps1
# ============================================================================
$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching elevated..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit -File `"$PSCommandPath`""
    exit
}

$subnet = "10.215.138.0"
$mask = "255.255.255.0"

$wslIp = (wsl.exe hostname -I).Trim().Split(" ")[0]
if (-not $wslIp) {
    Write-Error "Could not determine WSL2 IP. Is WSL2 running?"
    exit 1
}

route delete $subnet 2>$null | Out-Null
Write-Host "Adding route: $subnet/$mask via $wslIp"
route add $subnet mask $mask $wslIp

Write-Host ""
Write-Host "Verify:"
route print -4 | Select-String "10.215.138"
