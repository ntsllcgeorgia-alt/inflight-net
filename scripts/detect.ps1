# detect.ps1 — read-only. Identifies WHICH inflight system you're on and measures the link.
# No admin required. Run this FIRST, on the plane, after joining the Wi-Fi.

$ErrorActionPreference = 'SilentlyContinue'
function H($t){ Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }

H "ADAPTER"
$if = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|Hyper-V' } | Sort-Object -Property LinkSpeed -Descending | Select-Object -First 1
if (-not $if) { Write-Host "No active adapter." -ForegroundColor Red; exit 1 }
"{0}  ({1})  {2}" -f $if.Name, $if.InterfaceDescription, $if.LinkSpeed

$cfg = Get-NetIPConfiguration -InterfaceIndex $if.ifIndex
$gw  = $cfg.IPv4DefaultGateway.NextHop
$ip  = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
$dns = ($cfg.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses -join ', '
"IP      : $ip"
"Gateway : $gw"
"DNS     : $dns"

H "WI-FI RADIO"
$wl = netsh wlan show interfaces
$wl | Select-String 'SSID|BSSID|Signal|Radio type|Band|Channel|Receive rate|Transmit rate|Authentication'

H "LATENCY FINGERPRINT  (this is how we tell the satellite apart)"
$targets = @('1.1.1.1','8.8.8.8')
$rtts = @()
foreach ($t in $targets) {
  $r = Test-Connection -ComputerName $t -Count 6 -ErrorAction SilentlyContinue
  if ($r) {
    $ms = ($r | Measure-Object -Property ResponseTime -Average).Average
    $mn = ($r | Measure-Object -Property ResponseTime -Minimum).Minimum
    $mx = ($r | Measure-Object -Property ResponseTime -Maximum).Maximum
    $rtts += $ms
    "{0,-10} avg {1,6:N0} ms   min {2,5} ms   max {3,5} ms   jitter {4,4} ms" -f $t,$ms,$mn,$mx,($mx-$mn)
  } else { "{0,-10} ICMP blocked (normal on some portals)" -f $t }
}
if ($rtts.Count -eq 0) {
  # ICMP blocked -> fall back to TCP handshake timing
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('1.1.1.1',443); $c.Close() } catch {}
  $sw.Stop(); $rtts += $sw.ElapsedMilliseconds
  "TCP handshake to 1.1.1.1:443 = {0} ms (ICMP was blocked)" -f $sw.ElapsedMilliseconds
}
$avg = ($rtts | Measure-Object -Average).Average

H "VERDICT"
# SSID first - a phone hotspot also shows low RTT and would otherwise look like Starlink.
$ssid = ($wl | Select-String '^\s+SSID\s+:' | Select-Object -First 1) -replace '.*:\s*',''
$isInflight = $ssid -match 'southwest|wifi.?onboard|gogo|united_?wifi|inflight|_?wifi$' -or $gw -match '^10\.(1[0-9]|2[0-9])\.'
if (-not $isInflight -and $avg -lt 200) {
  Write-Host "  NOT on an aircraft network - SSID '$ssid' looks like a phone hotspot or lounge Wi-Fi." -ForegroundColor Yellow
  Write-Host "  Avg RTT: $([math]::Round($avg)) ms. Use this run as your GROUND BASELINE." -ForegroundColor Yellow
  Write-Host "  Re-run once you're on SouthwestWiFi to fingerprint the satellite."
}
if     ($avg -lt 120) { $sys='STARLINK (LEO) - or a terrestrial/cellular link, see above'; $note='Low orbit. Treat it like normal broadband. Big wins available.' }
elseif ($avg -lt 450) { $sys='GROUND / LEO-degraded';$note='Still on the ground or a LEO link under load.' }
elseif ($avg -lt 750) { $sys='VIASAT Ka-band (GEO)'; $note='Geostationary, ~22,236 mi up. Latency is physics - cannot be fixed. Bandwidth CAN.' }
else                  { $sys='ANUVU Ku-band (GEO)';  $note='Oldest Southwest kit. Narrowest pipe, worst contention. Tuning matters most here.' }
Write-Host "  Link looks like: $sys" -ForegroundColor Yellow
Write-Host "  Avg RTT: $([math]::Round($avg)) ms"
Write-Host "  $note"

H "MTU DISCOVERY (binary search, don't-fragment)"
$lo=1200; $hi=1472; $best=1200
while ($lo -le $hi) {
  $mid = [math]::Floor(($lo+$hi)/2)
  $out = ping -n 1 -f -l $mid -w 4000 1.1.1.1 2>&1 | Out-String
  if ($out -match 'Reply from') { $best=$mid; $lo=$mid+1 } else { $hi=$mid-1 }
}
"Largest unfragmented payload : $best bytes"
"=> Optimal interface MTU     : $($best+28)"
$cur = (Get-NetIPInterface -InterfaceIndex $if.ifIndex -AddressFamily IPv4).NlMtu
"Current interface MTU        : $cur"
if (($best+28) -lt $cur) { Write-Host "  MISMATCH - every large packet is being fragmented or dropped. inflight-on.ps1 fixes this." -ForegroundColor Red }

H "CAPTIVE PORTAL"
try {
  $r = Invoke-WebRequest -Uri 'http://captive.apple.com/hotspot-detect.html' -MaximumRedirection 0 -TimeoutSec 8 -UseBasicParsing
  if ($r.Content -match 'Success') { Write-Host "  AUTHENTICATED - you have real internet." -ForegroundColor Green }
  else { Write-Host "  Portal is intercepting." -ForegroundColor Yellow }
} catch {
  $loc = $_.Exception.Response.Headers['Location']
  Write-Host "  NOT authenticated. Portal redirect -> $loc" -ForegroundColor Yellow
  Write-Host "  Southwest portal: http://getconnected.southwestwifi.com"
}

H "TCP STACK (what we're going to change)"
netsh int tcp show global
"Adapter MAC : $($if.MacAddress)"

H "UPLINK HOGS RUNNING RIGHT NOW"
$hogs = 'OneDrive','Dropbox','Creative Cloud','CCXProcess','Teams','ms-teams','Slack','steam','EpicGamesLauncher','Agent','backgroundTaskHost','SearchIndexer','iCloudServices','GoogleDriveFS','Code'
Get-Process | Where-Object { $hogs -contains $_.ProcessName } | Select-Object ProcessName, Id, @{n='MB';e={[math]::Round($_.WS/1MB)}} | Format-Table -AutoSize
Write-Host "Next: run inflight-on.ps1 as admin." -ForegroundColor Green
