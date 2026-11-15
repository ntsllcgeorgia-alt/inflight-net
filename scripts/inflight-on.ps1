# inflight-on.ps1 — tune Windows for a high-latency, contended satellite link.
# REQUIRES ADMIN. Every change is backed up to state\inflight-backup.json.
# Reverse with inflight-off.ps1.
#
#   powershell -ExecutionPolicy Bypass -File .\inflight-on.ps1
#   ...       -File .\inflight-on.ps1 -Mtu 1420 -DisableIPv6 -Experimental

param(
  [int]$Mtu = 0,              # 0 = auto-discover
  [switch]$DisableIPv6,       # portals are usually v4-only; v6 adds 20s stalls
  [switch]$Experimental,      # bigger TCP window scaling (can upset old middleboxes)
  [switch]$KeepDns            # don't touch DNS (use before you've passed the portal)
)

$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Write-Host "Run this in an ADMIN PowerShell." -ForegroundColor Red; exit 1
}

$root  = Split-Path -Parent $PSScriptRoot
$state = Join-Path $root 'state'
if (-not (Test-Path $state)) { New-Item -ItemType Directory -Path $state | Out-Null }
$backupFile = Join-Path $state 'inflight-backup.json'

# GUARD (ratchet bug): never overwrite an existing backup. Running inflight-on
# twice without an inflight-off in between captures the ALREADY-TUNED values as
# the "baseline" - which permanently bakes the satellite MTU in, because
# inflight-off then faithfully restores you to the clamped state forever.
if (Test-Path $backupFile) {
  Write-Host "Inflight tuning is ALREADY APPLIED." -ForegroundColor Yellow
  Write-Host "  backup: $backupFile" -ForegroundColor Yellow
  Write-Host "Run inflight-off.ps1 first if you want to re-tune. Aborting so your" -ForegroundColor Yellow
  Write-Host "true pre-flight baseline is not overwritten." -ForegroundColor Yellow
  exit 1
}

function Step($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    $m" -ForegroundColor Yellow }

$if = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|Hyper-V' } | Select-Object -First 1
if (-not $if) { Write-Host "No active adapter." -ForegroundColor Red; exit 1 }
Ok "Adapter: $($if.Name) [$($if.InterfaceDescription)]"

# ---------------------------------------------------------------- BACKUP
# Capture EVERY setting this script changes. Anything set below but not
# recorded here can never be restored by inflight-off.ps1.
$heurBefore = ((netsh int tcp show heuristics | Select-String 'Window Scaling heuristics\s*:\s*(\w+)').Matches.Groups[1].Value)
$rssBefore  = ((netsh int tcp show global     | Select-String 'Receive-Side Scaling State\s*:\s*(\w+)').Matches.Groups[1].Value)
$tcpBefore  = Get-NetTCPSetting -SettingName Internet

$backup = @{
  ifName        = $if.Name
  ifIndex       = $if.ifIndex
  mtu           = (Get-NetIPInterface -InterfaceIndex $if.ifIndex -AddressFamily IPv4).NlMtu
  autotuning    = $tcpBefore.AutoTuningLevelLocal
  congestion    = $tcpBefore.CongestionProvider
  timestamps    = $tcpBefore.Timestamps
  ecn           = $tcpBefore.EcnCapability
  nonSackRtt    = "$($tcpBefore.NonSackRttResiliency)"
  heuristics    = $heurBefore
  rss           = $rssBefore
  throttleIndex = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -EA SilentlyContinue).NetworkThrottlingIndex
  dns           = ((Get-DnsClientServerAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4).ServerAddresses -join ',')
  ipv6Enabled   = (Get-NetAdapterBinding -Name $if.Name -ComponentID ms_tcpip6).Enabled
  doDownMode    = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name DODownloadMode -EA SilentlyContinue).DODownloadMode
  wlanPower     = $null
  pausedProcs   = @()
  stoppedSvcs   = @()
  ts            = (Get-Date).ToString('s')
}

# ---------------------------------------------------------------- 1. MTU
Step "MTU clamp (satellite links tunnel traffic; a too-large MTU means silent drops)"
if ($Mtu -eq 0) {
  $lo=1200; $hi=1472; $best=1200
  while ($lo -le $hi) {
    $mid=[math]::Floor(($lo+$hi)/2)
    $o = ping -n 1 -f -l $mid -w 4000 1.1.1.1 2>&1 | Out-String
    if ($o -match 'Reply from') { $best=$mid; $lo=$mid+1 } else { $hi=$mid-1 }
  }
  $Mtu = $best + 28
  Ok "discovered path MTU = $Mtu"
}
if ($Mtu -ge 1280 -and $Mtu -le 1500) {
  netsh interface ipv4 set subinterface "$($if.Name)" mtu=$Mtu store=persistent | Out-Null
  Ok "MTU $($backup.mtu) -> $Mtu"
} else { Warn "skipping implausible MTU $Mtu (was $($backup.mtu))" }

# ---------------------------------------------------------------- 2. TCP for long fat pipes
Step "TCP window scaling / congestion control for high bandwidth-delay product"
# At 600ms RTT and 20 Mbps the BDP is ~1.5 MB. Default 64KB windows cap you at ~0.9 Mbps.
$lvl = if ($Experimental) { 'experimental' } else { 'normal' }
netsh int tcp set global autotuninglevel=$lvl        | Out-Null
netsh int tcp set heuristics disabled                | Out-Null   # stops Windows shrinking the window on "unfamiliar" networks
netsh int tcp set global timestamps=enabled          | Out-Null   # better RTT estimation + PAWS on long pipes
netsh int tcp set global ecncapability=disabled      | Out-Null   # inflight PEPs mishandle ECN
netsh int tcp set global rss=enabled                 | Out-Null
netsh int tcp set global nonsackrttresiliency=enabled| Out-Null   # survives the loss bursts satellite links produce
netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null  # CTCP fills long pipes far faster than CUBIC
Ok "autotuning=$lvl, heuristics=off, CTCP, timestamps=on, ECN=off"
Warn "NOTE: delayed-ACK/Nagle deliberately LEFT ON - the uplink is the scarce resource here, unlike on a home LAN."

# ---------------------------------------------------------------- 3. Windows packet throttle
Step "Removing Windows' 10-packets/ms cap on non-multimedia apps"
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex -Value 0xffffffff -Type DWord
Ok "NetworkThrottlingIndex -> disabled (was $($backup.throttleIndex))"

# ---------------------------------------------------------------- 4. Wi-Fi radio
Step "Wi-Fi radio: kill power-save napping, maximise roaming aggressiveness"
$pm = Get-NetAdapterPowerManagement -Name $if.Name -EA SilentlyContinue
if ($pm) {
  $backup.wlanPower = $pm.AllowComputerToTurnOffDevice
  $pm.AllowComputerToTurnOffDevice = 'Disabled'
  Set-NetAdapterPowerManagement -InputObject $pm -EA SilentlyContinue
  Ok "device power-off -> disabled"
}
foreach ($kw in @('*PowerSaveMode','PowerSaveMode','Power Saving Mode')) {
  Set-NetAdapterAdvancedProperty -Name $if.Name -DisplayName $kw -DisplayValue 'Disabled' -EA SilentlyContinue
}
foreach ($kw in @('Roaming Aggressiveness','Roaming Sensitivity Level','RoamingPreferredBandType')) {
  Set-NetAdapterAdvancedProperty -Name $if.Name -DisplayName $kw -DisplayValue 'Highest' -EA SilentlyContinue
}
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setactive SCHEME_CURRENT 2>$null
Ok "power plan wireless adapter -> Maximum Performance (AC + battery)"

# ---------------------------------------------------------------- 5. Stop competing with yourself
Step "Suspending background uploaders (they eat the uplink, which throttles ALL your downloads)"
$hogs = 'OneDrive','Dropbox','GoogleDriveFS','iCloudServices','iCloudDrive','CCXProcess',
        'Creative Cloud','Adobe Desktop Service','Teams','ms-teams','Slack','steam',
        'steamwebhelper','EpicGamesLauncher','Agent','Spotify','Backup and Sync'
foreach ($p in Get-Process | Where-Object { $hogs -contains $_.ProcessName }) {
  try {
    # suspend, don't kill - resumes cleanly on landing
    $h = [Diagnostics.Process]::GetProcessById($p.Id)
    Add-Type -Name W -Namespace N -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h); [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);' -EA SilentlyContinue
    [N.W]::NtSuspendProcess($h.Handle) | Out-Null
    $backup.pausedProcs += $p.Id
    Ok "suspended $($p.ProcessName) (pid $($p.Id))"
  } catch {}
}

Step "Stopping update / telemetry services"
foreach ($s in 'wuauserv','DoSvc','BITS','WSearch','MapsBroker') {
  $svc = Get-Service $s -EA SilentlyContinue
  if ($svc -and $svc.Status -eq 'Running') {
    $backup.stoppedSvcs += $s
    Stop-Service $s -Force -EA SilentlyContinue
    Ok "stopped $s"
  }
}
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -Name DODownloadMode -Value 100 -Type DWord
Ok "Delivery Optimization -> bypass (no peer/CDN background pulls)"

# ---------------------------------------------------------------- 6. IPv6
if ($DisableIPv6) {
  Step "Disabling IPv6 on the adapter (portal is v4-only; v6 attempts stall ~20s each)"
  Disable-NetAdapterBinding -Name $if.Name -ComponentID ms_tcpip6 -EA SilentlyContinue
  Ok "ms_tcpip6 disabled"
}

# ---------------------------------------------------------------- 7. DNS
if (-not $KeepDns) {
  Step "DNS -> Cloudflare + DoH (portal DNS on a GEO link can cost 400-900ms per lookup)"
  Warn "if the captive portal is not yet accepted, re-run with -KeepDns and do DNS after."
  Set-DnsClientServerAddress -InterfaceIndex $if.ifIndex -ServerAddresses ('1.1.1.1','1.0.0.1') -EA SilentlyContinue
  # register the DoH templates so Windows encrypts + reuses one warm connection
  netsh dns add encryption server=1.1.1.1 dohtemplate=https://cloudflare-dns.com/dns-query autoupgrade=yes 2>$null | Out-Null
  netsh dns add encryption server=1.0.0.1 dohtemplate=https://cloudflare-dns.com/dns-query autoupgrade=yes 2>$null | Out-Null
  Clear-DnsClientCache
  Ok "DNS set (was: $($backup.dns))"
}

# ---------------------------------------------------------------- SAVE
$backup | ConvertTo-Json -Depth 4 | Set-Content -Path $backupFile -Encoding utf8
Write-Host ""
Write-Host "DONE. Backup -> $backupFile" -ForegroundColor Green
Write-Host "Next:  python py\linkbench.py        (find your concurrency sweet spot)" -ForegroundColor Green
Write-Host "Undo:  inflight-off.ps1" -ForegroundColor Green
