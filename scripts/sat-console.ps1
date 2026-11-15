# sat-console.ps1 - get as close to the bird as a laptop physically can.
# Touches each stage of the climb to orbit and isolates the satellite hop itself.
# Read-only, battery-friendly. Run: -Rounds N for a live watch.

param([int]$Rounds = 6)

function Section($t){ Write-Host "`n== $t ==" -ForegroundColor Cyan }
function Avg($pings){ if($pings){ [math]::Round((($pings | Measure-Object ResponseTime -Average).Average)) } else { $null } }
$modem = '172.19.0.1'

Section "STAGE 1 - the onboard modem (closest device to the antenna)"
$ground = Avg (Test-Connection $modem -Count 4 -EA SilentlyContinue)
if ($null -eq $ground) { $ground = 5 }
Write-Host ("Modem {0} : {1} ms avg  (pure ON-PLANE latency, never leaves the cabin)" -f $modem,$ground)

Section "STAGE 2 - first hop on the FAR side of the satellite"
$tr = tracert -d -h 6 -w 1500 1.1.1.1 2>&1
$hops = @()
foreach ($line in $tr) {
  if ($line -match '^\s*(\d+)\s+(?:(\d+)\s*ms|\*)\s+(?:(\d+)\s*ms|\*)\s+(?:(\d+)\s*ms|\*)\s+(\d{1,3}(?:\.\d{1,3}){3})') {
    $vals = @($matches[2],$matches[3],$matches[4]) | Where-Object { $_ } | ForEach-Object { [int]$_ }
    $avg = if ($vals) { [math]::Round(($vals | Measure-Object -Average).Average) } else { 0 }
    $hops += [pscustomobject]@{ Hop=[int]$matches[1]; IP=$matches[5]; Ms=$avg }
  }
}
$hops | Format-Table -AutoSize | Out-String | Write-Host
$firstAcross = $hops | Where-Object { $_.IP -ne $modem -and $_.Ms -gt 300 } | Select-Object -First 1

Section "STAGE 3 - ISOLATE THE SATELLITE (space segment only)"
if ($firstAcross) {
  Write-Host ("Ground side (modem)          : {0} ms" -f $ground)
  Write-Host ("Across the bird ({0}) : {1} ms" -f $firstAcross.IP,$firstAcross.Ms)
  $space = $firstAcross.Ms - $ground
  Write-Host ("  PURE SATELLITE ROUND TRIP  : {0} ms" -f $space) -ForegroundColor Yellow
  $kmOneWay = ($space/1000.0/2.0) * 299792.458
  Write-Host ("  At light speed that is {0:N0} km each way - the bird is that far up + slant." -f $kmOneWay)
} else {
  Write-Host "couldn't isolate the space hop this pass (ICMP throttled) - rerun"
}

Section "STAGE 4 - live geometry to the bird (where it is right now)"
python "$PSScriptRoot\..\py\sat_track.py" --sat NUVIEW --lat 32.3 --lon -97.0 2>&1 |
  Select-String 'NUVIEW|UP:|round-trip|floor' | ForEach-Object { Write-Host $_.ToString() }

Section "STAGE 5 - watch it breathe ($Rounds rounds; catches beam handovers)"
# helper: one ping via .NET (works on PS 5.1), own timeout, "--" if it drops/rate-limits
$pinger = New-Object System.Net.NetworkInformation.Ping
function Ping1($ip){
  if (-not $ip) { return '  --' }
  try {
    $r = $pinger.Send($ip, 3000)
    if ($r.Status -eq 'Success') { '{0,4}' -f [int]$r.RoundtripTime } else { '  --' }
  } catch { '  --' }
}
# Internal hops (modem, space-hop) only answer traceroute, not direct echo, so we
# watch end-to-end RTT through the bird - the number that spikes on a handover.
$samples = @()
for ($i=1; $i -le $Rounds; $i++) {
  $far = Ping1 '1.1.1.1'
  if ($far -ne '  --') { $samples += [int]$far }
  $base = if ($samples.Count) { ($samples | Measure-Object -Average).Average } else { 700 }
  $tag = if ($far -eq '  --') { '  <-- DROP (outage / handover gap)' }
         elseif ([int]$far -gt ($base * 1.5 + 200)) { '  <-- SPIKE (beam/satellite handover)' }
         else { '' }
  Write-Host ("{0}  through-the-bird RTT {1} ms{2}" -f (Get-Date -f HH:mm:ss),$far,$tag)
  Start-Sleep -Milliseconds 800
}
if ($samples.Count) {
  Write-Host ("`nSteady end-to-end: min {0} / avg {1:N0} / max {2} ms over {3} good samples" -f `
    ($samples|Measure-Object -Minimum).Minimum,($samples|Measure-Object -Average).Average,($samples|Measure-Object -Maximum).Maximum,$samples.Count)
}
Write-Host "`nThat's as close to the satellite as this machine can get." -ForegroundColor Green
