# connect-southwest.ps1 — join the aircraft Wi-Fi and open the payment portal.
# ADMIN. Self-contained: once this runs you lose your hotspot, so it logs
# everything to state\connect-log.txt and opens the browser by itself.

param(
  [string]$Ssid = 'SouthwestWiFi',
  [ValidateSet('5','2.4','auto')][string]$Band = '5',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$state = Join-Path $root 'state'
if (-not (Test-Path $state)) { New-Item -ItemType Directory -Path $state | Out-Null }
$log = Join-Path $state 'connect-log.txt'
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c; Add-Content $log "$(Get-Date -f 'HH:mm:ss')  $m" }

Say "=== connect-southwest.ps1 ===" Cyan
$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN' -and $_.Status -ne 'Disabled' } | Select-Object -First 1
if (-not $if) { Say "No Wi-Fi adapter found." Red; exit 1 }
Say "Adapter: $($if.Name) [$($if.InterfaceDescription)]" Green

# ---- 1. band preference BEFORE connecting, so association picks the right radio
if ($Band -ne 'auto') {
  Say "Preferring $Band GHz (2.4 is where the whole cabin's phones sit; 5 GHz is emptier)" Cyan
  $want = if ($Band -eq '5') { @('Prefer 5GHz Band','Prefer 5.2GHz Band','5GHz','Prefer 5G') } else { @('Prefer 2.4GHz Band','2.4GHz') }
  foreach ($propName in @('Preferred Band','Band Preference','Roaming Preferred Band Type','Preferred Band Type')) {
    $p = Get-NetAdapterAdvancedProperty -Name $if.Name -DisplayName $propName -EA SilentlyContinue
    if ($p) {
      foreach ($v in $want) {
        try { Set-NetAdapterAdvancedProperty -Name $if.Name -DisplayName $propName -DisplayValue $v -EA Stop; Say "  set '$propName' = '$v'" Green; break } catch {}
      }
    }
  }
}

# ---- 2. open-network profile (auto-reconnect: the link WILL drop mid-flight)
Say "Writing open-network profile for '$Ssid'" Cyan
$hex = ($Ssid.ToCharArray() | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ''
$xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$Ssid</name>
  <SSIDConfig><SSID><hex>$hex</hex><name>$Ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>
  </security></MSM>
</WLANProfile>
"@
$pf = Join-Path $env:TEMP 'sw-wifi.xml'
$xml | Set-Content -Path $pf -Encoding ASCII
netsh wlan add profile filename="$pf" interface="$($if.Name)" | Out-String | ForEach-Object { Say $_ }

# ---- 3. connect
Say "Connecting..." Cyan
netsh wlan connect name="$Ssid" interface="$($if.Name)" | Out-String | ForEach-Object { Say $_ }

$ok = $false
for ($i=0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 2
  $st = netsh wlan show interfaces | Out-String
  if ($st -match 'State\s+:\s+connected' -and $st -match [regex]::Escape($Ssid)) { $ok = $true; break }
  Write-Host "." -NoNewline
}
Write-Host ""
if (-not $ok) { Say "Did NOT associate. Connect manually from the taskbar Wi-Fi icon." Red; exit 1 }

$info = netsh wlan show interfaces | Out-String
Say "ASSOCIATED" Green
($info -split "`n" | Select-String 'SSID|BSSID|Signal|Band|Channel|Receive rate') | ForEach-Object { Say ("  " + $_.ToString().Trim()) }

# ---- 4. wait for DHCP
Say "Waiting for DHCP lease..." Cyan
$gw = $null
for ($i=0; $i -lt 20; $i++) {
  Start-Sleep -Seconds 2
  $cfg = Get-NetIPConfiguration -InterfaceIndex $if.ifIndex -EA SilentlyContinue
  $gw = $cfg.IPv4DefaultGateway.NextHop
  if ($gw) { Say "  IP $(($cfg.IPv4Address|Select -First 1).IPAddress)  GW $gw  DNS $((($cfg.DNSServer|? AddressFamily -eq 2).ServerAddresses) -join ',')" Green; break }
  Write-Host "." -NoNewline
}
Write-Host ""
if (-not $gw) { Say "No DHCP lease. Disconnect/reconnect and retry." Red; exit 1 }

# ---- 5. find the real portal URL from the redirect
Say "Probing captive portal..." Cyan
$portal = $null
foreach ($probe in 'http://captive.apple.com/hotspot-detect.html','http://www.msftconnecttest.com/connecttest.txt','http://neverssl.com') {
  try {
    $r = Invoke-WebRequest -Uri $probe -MaximumRedirection 0 -TimeoutSec 10 -UseBasicParsing -EA Stop
    if ($r.Content -match 'Success|Microsoft Connect Test') { Say "Already authenticated - you have internet." Green; $portal='NONE'; break }
  } catch {
    $resp = $_.Exception.Response
    if ($resp) {
      $loc = $resp.Headers['Location']
      if ($loc) { $portal = $loc; Say "Portal redirect -> $loc" Yellow; break }
    }
  }
}
if (-not $portal) { $portal = 'http://getconnected.southwestwifi.com'; Say "No redirect captured; using known Southwest portal." Yellow }

# ---- 6. open it
if ($portal -ne 'NONE' -and -not $NoBrowser) {
  Say "Opening payment page: $portal" Green
  Start-Process $portal
  Start-Sleep -Seconds 2
  Start-Process 'http://getconnected.southwestwifi.com'   # belt and braces
}

Say ""
Say "NEXT: pay/sign in in the browser, then run:" Green
Say "   .\scripts\detect.ps1          (fingerprints the satellite)" Green
Say "   .\scripts\inflight-on.ps1 -DisableIPv6   (ADMIN, the tuning)" Green
Say "Log: $log"
