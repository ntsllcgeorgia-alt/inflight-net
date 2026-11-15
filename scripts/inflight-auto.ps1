# inflight-auto.ps1 - fingerprint the satellite, then apply the profile that matches it.
# ADMIN. Fully reversible via inflight-off.ps1 / the backup this writes.
#
# Why this exists: the correct tuning is DIFFERENT per system, and on GEO links several
# choices are the OPPOSITE of normal LAN tuning. Guessing wrong makes things worse.
param(
  [switch]$KeepDns,        # skip DNS changes (use if the captive portal isn't passed yet)
  [switch]$Experimental,   # larger RWIN scaling - only if linkbench says you're window-capped
  [switch]$WhatIf          # measure + report the plan, change nothing
)

$ErrorActionPreference = 'Continue'
$state = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
New-Item -ItemType Directory -Path $state -Force | Out-Null
$bk = @{ when = (Get-Date).ToString('o') }

function Hd($m){ Write-Host "`n$m" -ForegroundColor Yellow }
function Ok($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function No($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Nt($m){ Write-Host "  [--]   $m" -ForegroundColor DarkGray }
function Wn($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 0. the link
Hd "LINK"
$wifi = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wi-?Fi|Wireless' } | Select-Object -First 1
if (-not $wifi) {
  $wifi = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
  if (-not $wifi) { No "no active adapter - join the aircraft Wi-Fi first"; exit 1 }
  Wn "no Wi-Fi adapter up; using $($wifi.Name)"
}
$IF = $wifi.Name
$GUID = $wifi.InterfaceGuid
$ssid = (netsh wlan show interfaces | Select-String 'SSID\s+:' | Select-Object -First 1) -replace '.*:\s*',''
Ok "$IF  SSID=$ssid"

# ------------------------------------------------------- 1. satellite fingerprint
Hd "FINGERPRINT  (median RTT is the tell)"
$samples = @()
foreach ($t in '1.1.1.1','8.8.8.8') {
  $r = Test-Connection $t -Count 15 -EA SilentlyContinue
  if ($r) { $samples += $r.ResponseTime }
}
if (-not $samples.Count) { No "no ICMP replies - portal not passed, or ICMP blocked"; exit 1 }
$sorted = $samples | Sort-Object
$median = $sorted[[int]($sorted.Count/2)]
$min    = ($samples | Measure-Object -Minimum).Minimum
$max    = ($samples | Measure-Object -Maximum).Maximum
$jit    = $max - $min
"  median {0} ms   min {1}   max {2}   spread {3} ms" -f $median,$min,$max,$jit | Write-Host

if     ($median -lt 100) { $sys='STARLINK'; $orbit='LEO ~340 mi' }
elseif ($median -lt 300) { $sys='TERRESTRIAL/ATG'; $orbit='ground towers' }
elseif ($median -lt 640) { $sys='VIASAT'; $orbit='GEO 22,236 mi (Ka-band)' }
else                     { $sys='ANUVU'; $orbit='GEO 22,236 mi (Ku-band)' }
$isGeo = $sys -in @('VIASAT','ANUVU')
Write-Host "  => $sys   ($orbit)" -ForegroundColor Cyan
$bk.system = $sys; $bk.medianRtt = $median

# ------------------------------------------------------------- 2. path MTU
Hd "PATH MTU  (IFC links tunnel your traffic; 1500-sized packets get dropped silently)"
$lo=1200; $hi=1472; $best=0
while ($lo -le $hi) {
  $mid=[int](($lo+$hi)/2)
  $p = ping -f -l $mid -n 1 -w 3000 1.1.1.1 2>&1 | Out-String
  if ($p -match 'Reply from') { $best=$mid; $lo=$mid+1 } else { $hi=$mid-1 }
}
$optMtu = $best + 28
$curMtu = (Get-NetIPInterface -InterfaceAlias $IF -AddressFamily IPv4).NlMtu
"  largest payload {0}  => optimal MTU {1}   (current {2})" -f $best,$optMtu,$curMtu | Write-Host
$bk.mtu = $curMtu

# ------------------------------------------------------------- 3. the plan
Hd "PLAN for $sys"
if ($isGeo) {
  Nt "GEO: ~480 ms is pure speed-of-light. Nothing fixes that; we fix what it BREAKS."
  Nt "Nagle + delayed-ACK stay ON - your uplink is the scarcest thing on the aircraft,"
  Nt "and extra ACK packets directly slow every download you have."
  Nt "CTCP over CUBIC - delay-aware, ramps far faster on a long fat pipe."
} else {
  Nt "LEO/terrestrial: behaves like real broadband. Treat it normally."
  Nt "Nagle OFF is safe here - latency is low enough that coalescing only hurts."
}
if ($WhatIf) { Wn "WhatIf - stopping before any change."; exit 0 }

# ------------------------------------------------------------- 4. apply
Hd "APPLYING"

# 4a. MTU
if ($optMtu -ne $curMtu -and $optMtu -ge 1200) {
  try { Set-NetIPInterface -InterfaceAlias $IF -AddressFamily IPv4 -NlMtu $optMtu -EA Stop
        Ok "MTU $curMtu -> $optMtu" } catch { No "MTU: $_" }
} else { Ok "MTU already optimal ($curMtu)" }

# 4b. TCP window - the #1 killer on high-BDP links
$bdp = [int](($median/1000.0) * 25e6 / 8 / 1024)   # KB at an optimistic 25 Mbps
$lvl = if ($Experimental) { 'experimental' } else { 'normal' }
netsh int tcp set global autotuninglevel=$lvl | Out-Null
Ok "RWIN autotuning = $lvl   (est BDP ~$bdp KB; 64 KB default would cap you hard)"

# 4c. congestion control
netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null
Ok "congestion provider = CTCP (delay-aware; CUBIC misreads satellite bit-errors as congestion)"

# 4d. things IFC middleboxes mishandle
netsh int tcp set global ecncapability=disabled | Out-Null
netsh int tcp set global timestamps=disabled     | Out-Null
netsh int tcp set heuristics disabled            | Out-Null
netsh int tcp set global rss=enabled             | Out-Null
Ok "ECN off, timestamps off, heuristics off, RSS on"

# 4e. Nagle - direction depends on the system
$ipk = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$GUID"
if (Test-Path $ipk) {
  $bk.ackfreq = (Get-ItemProperty $ipk -Name TcpAckFrequency -EA SilentlyContinue).TcpAckFrequency
  $bk.nodelay = (Get-ItemProperty $ipk -Name TCPNoDelay      -EA SilentlyContinue).TCPNoDelay
  if ($isGeo) {
    if ($null -ne $bk.ackfreq) { Remove-ItemProperty $ipk -Name TcpAckFrequency -EA SilentlyContinue }
    if ($null -ne $bk.nodelay) { Remove-ItemProperty $ipk -Name TCPNoDelay      -EA SilentlyContinue }
    Ok "Nagle + delayed-ACK left ON (correct for GEO - protects the scarce uplink)"
  } else {
    Set-ItemProperty $ipk -Name TcpAckFrequency -Value 1 -Type DWord -EA SilentlyContinue
    Set-ItemProperty $ipk -Name TCPNoDelay      -Value 1 -Type DWord -EA SilentlyContinue
    Ok "Nagle OFF (correct for LEO/terrestrial)"
  }
}

# 4f. radio power-save - each nap costs a micro-spike
try {
  $pm = Get-CimInstance MSPower_DeviceEnable -Namespace root\wmi -EA Stop |
        Where-Object { $_.InstanceName -match [regex]::Escape($wifi.PnPDeviceID) }
  if ($pm) { $pm | ForEach-Object { $_.Enable = $false; Set-CimInstance -InputObject $_ -EA Stop }
             Ok "Wi-Fi radio power-save disabled" }
} catch { Nt "radio power-save: $($_.Exception.Message)" }
powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setdcvalueindex SCHEME_CURRENT SUB_NONE 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setactive SCHEME_CURRENT 2>$null

# 4g. uplink hogs - one photo syncing delays every ACK you send
$bk.paused = @()
foreach ($n in 'OneDrive','OneDrive.Sync.Service','Creative Cloud','Creative Cloud Helper',
               'Creative Cloud UI Helper','CCXProcess','SearchIndexer','Dropbox','backgroundTaskHost') {
  Get-Process -Name $n -EA SilentlyContinue | ForEach-Object {
    try { $_.Kill(); if ($bk.paused -notcontains $n) { $bk.paused += $n; Ok "suspended $n" } } catch {}
  }
}
try { Stop-Service wuauserv -Force -EA Stop; Ok "Windows Update service stopped" } catch { Nt "wuauserv: already stopped or protected" }

# 4h. DNS last - the portal needs to hijack DNS until you're authenticated
if ($KeepDns) {
  Nt "DNS unchanged (-KeepDns)"
} else {
  $bk.dns = (Get-DnsClientServerAddress -InterfaceAlias $IF -AddressFamily IPv4).ServerAddresses
  try {
    Set-DnsClientServerAddress -InterfaceAlias $IF -ServerAddresses '1.1.1.1','8.8.8.8' -EA Stop
    Ok "DNS -> 1.1.1.1 / 8.8.8.8  (was: $($bk.dns -join ', '))"
    Wn "if the portal stops working, re-run with -KeepDns or run inflight-off.ps1"
  } catch { No "DNS: $_" }
}

$bk | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $state 'inflight-auto-backup.json') -Encoding utf8

Hd "DONE - $sys profile applied"
Write-Host "  backup : $(Join-Path $state 'inflight-auto-backup.json')"
Write-Host "  next   : python .\py\linkbench.py   (find your concurrency number)"
Write-Host "  revert : .\scripts\inflight-off.ps1 (admin)`n"
