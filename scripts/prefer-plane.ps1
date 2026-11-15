# prefer-plane.ps1 — make the aircraft Wi-Fi the primary route, phone tether the backup.
# ADMIN. Reverse with -Revert.
#
# Windows picks the default route by lowest InterfaceMetric. A USB-tethered
# iPhone shows up as a wired NIC and wins by default, so all your traffic keeps
# going over cellular even after you join the plane. This flips that, while
# leaving the phone connected as automatic failover.

param(
  [string]$PlaneAlias = 'Wi-Fi',
  [string]$PhoneAlias = 'Ethernet 4',
  [switch]$Revert
)
$ErrorActionPreference='Continue'
$log = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\prefer-plane-log.txt'
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c; Add-Content $log "$(Get-Date -f 'HH:mm:ss')  $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Say "NOT ELEVATED - rerun as admin." Red; Start-Sleep 8; exit 1
}

if ($Revert) {
  Say "Reverting to automatic metrics" Cyan
  Set-NetIPInterface -InterfaceAlias $PlaneAlias -AutomaticMetric Enabled -EA Continue
  Set-NetIPInterface -InterfaceAlias $PhoneAlias -AutomaticMetric Enabled -EA Continue
} else {
  Say "Plane '$PlaneAlias' -> metric 5   |   Phone '$PhoneAlias' -> metric 60 (failover)" Cyan
  Set-NetIPInterface -InterfaceAlias $PlaneAlias -InterfaceMetric 5  -EA Continue
  Set-NetIPInterface -InterfaceAlias $PhoneAlias -InterfaceMetric 60 -EA Continue
}

Get-NetIPInterface -AddressFamily IPv4 |
  Where-Object { $_.InterfaceAlias -in @($PlaneAlias,$PhoneAlias) } |
  Select-Object InterfaceAlias,InterfaceMetric,NlMtu | Format-Table -AutoSize |
  Out-String | ForEach-Object { Say $_ }

Say "Default route now prefers:" Green
(Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Sort-Object { (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } |
  Select-Object -First 1 InterfaceAlias,NextHop | Out-String) | ForEach-Object { Say $_ }

Say "Done." Green
Start-Sleep 6
