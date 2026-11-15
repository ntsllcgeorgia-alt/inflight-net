# inflight-off.ps1 — restore everything inflight-on.ps1 changed. REQUIRES ADMIN.
# Run this when you land.

$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Write-Host "Run this in an ADMIN PowerShell." -ForegroundColor Red; exit 1
}

$root = Split-Path -Parent $PSScriptRoot
$backupFile = Join-Path $root 'state\inflight-backup.json'
if (-not (Test-Path $backupFile)) { Write-Host "No backup found at $backupFile - nothing to restore." -ForegroundColor Yellow; exit 0 }
$b = Get-Content $backupFile -Raw | ConvertFrom-Json
function Ok($m){ Write-Host "    $m" -ForegroundColor Green }
Write-Host "[*] Restoring state captured $($b.ts)" -ForegroundColor Cyan

netsh interface ipv4 set subinterface "$($b.ifName)" mtu=$($b.mtu) store=persistent | Out-Null
Ok "MTU -> $($b.mtu)"

netsh int tcp set global autotuninglevel=$($b.autotuning) | Out-Null
netsh int tcp set global ecncapability=$($b.ecn)          | Out-Null
netsh int tcp set global timestamps=$($b.timestamps)      | Out-Null
netsh int tcp set supplemental template=internet congestionprovider=$($b.congestion) | Out-Null

# These three were previously set by inflight-on but never captured, so they
# survived every "restore" and silently accumulated across flights.
if ($b.heuristics) { netsh int tcp set heuristics $($b.heuristics) | Out-Null; Ok "scaling heuristics -> $($b.heuristics)" }
else               { netsh int tcp set heuristics default          | Out-Null; Ok "scaling heuristics -> default (not in backup)" }

if ($b.nonSackRtt) { netsh int tcp set global nonsackrttresiliency=$($b.nonSackRtt) | Out-Null; Ok "nonSackRttResiliency -> $($b.nonSackRtt)" }
else               { netsh int tcp set global nonsackrttresiliency=disabled         | Out-Null; Ok "nonSackRttResiliency -> disabled (not in backup)" }

if ($b.rss)        { netsh int tcp set global rss=$($b.rss) | Out-Null; Ok "RSS -> $($b.rss)" }

Ok "TCP -> autotuning=$($b.autotuning), congestion=$($b.congestion)"

if ($null -ne $b.throttleIndex) {
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -Value ([uint32]$b.throttleIndex) -Type DWord
} else {
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -Value 10 -Type DWord
}
Ok "NetworkThrottlingIndex restored"

if ($b.wlanPower) {
  $pm = Get-NetAdapterPowerManagement -Name $b.ifName -EA SilentlyContinue
  if ($pm) { $pm.AllowComputerToTurnOffDevice = $b.wlanPower; Set-NetAdapterPowerManagement -InputObject $pm -EA SilentlyContinue; Ok "radio power mgmt restored" }
}

if ($b.ipv6Enabled -eq $true) { Enable-NetAdapterBinding -Name $b.ifName -ComponentID ms_tcpip6 -EA SilentlyContinue; Ok "IPv6 re-enabled" }

if ([string]::IsNullOrWhiteSpace($b.dns)) {
  Set-DnsClientServerAddress -InterfaceIndex $b.ifIndex -ResetServerAddresses -EA SilentlyContinue
  Ok "DNS -> DHCP"
} else {
  Set-DnsClientServerAddress -InterfaceIndex $b.ifIndex -ServerAddresses ($b.dns -split ',') -EA SilentlyContinue
  Ok "DNS -> $($b.dns)"
}

Add-Type -Name W2 -Namespace N2 -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);' -EA SilentlyContinue
foreach ($procId in $b.pausedProcs) {   # NOT $pid - that's a read-only automatic variable
  try { $p=[Diagnostics.Process]::GetProcessById([int]$procId); [N2.W2]::NtResumeProcess($p.Handle) | Out-Null; Ok "resumed pid $procId ($($p.ProcessName))" } catch {}
}
foreach ($s in $b.stoppedSvcs) { Start-Service $s -EA SilentlyContinue; Ok "started $s" }

if ($null -ne $b.doDownMode) {
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name DODownloadMode -Value ([int]$b.doDownMode) -Type DWord
} else {
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name DODownloadMode -EA SilentlyContinue
}
Ok "Delivery Optimization restored"

netsh dns delete encryption server=1.1.1.1 2>$null | Out-Null
netsh dns delete encryption server=1.0.0.1 2>$null | Out-Null
Clear-DnsClientCache

# undo the kill-QUIC lever if it was applied
Get-NetFirewallRule -DisplayName 'inflight-net-kill-QUIC' -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name QuicAllowed -EA SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome'  -Name QuicAllowed -EA SilentlyContinue
Ok "QUIC re-enabled (firewall rule + browser policy cleared)"

Rename-Item $backupFile "inflight-backup.restored.json" -Force -EA SilentlyContinue
Write-Host "`nRestored. You're back to normal." -ForegroundColor Green
