# quic-off.ps1 - force all traffic onto TCP so the aircraft PEP can accelerate it.
# The onboard Performance-Enhancing Proxy fakes local ACKs for TCP but CANNOT
# touch UDP. QUIC/HTTP-3 runs over UDP 443, so it crosses the full ~700 ms link
# unaccelerated. Blocking UDP 443 makes browsers/apps fall back to TCP (HTTP/2),
# which the PEP speeds up. ADMIN. Reverse: quic-off.ps1 -Revert (or inflight-off.ps1).

param([switch]$Revert)
$ErrorActionPreference='Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Write-Host "Run as ADMIN." -ForegroundColor Red; Start-Sleep 6; exit 1
}
$rule = 'inflight-net-kill-QUIC'
function Ok($m){ Write-Host "    $m" -ForegroundColor Green }

if ($Revert) {
  Get-NetFirewallRule -DisplayName $rule -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'  -Name QuicAllowed -EA SilentlyContinue
  Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome'   -Name QuicAllowed -EA SilentlyContinue
  Ok "QUIC re-enabled (firewall rule + browser policy removed)."
  return
}

# 1. firewall: block outbound QUIC (UDP 443) - immediate, app-agnostic
Get-NetFirewallRule -DisplayName $rule -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
New-NetFirewallRule -DisplayName $rule -Direction Outbound -Protocol UDP -RemotePort 443 -Action Block -Profile Any | Out-Null
Ok "Firewall: outbound UDP 443 (QUIC) blocked -> apps fall back to TCP."

# 2. browser policy: hard-disable QUIC in Edge + Chrome (belt and braces; needs restart)
foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge','HKLM:\SOFTWARE\Policies\Google\Chrome') {
  New-Item -Path $k -Force | Out-Null
  Set-ItemProperty -Path $k -Name QuicAllowed -Value 0 -Type DWord
}
Ok "Browser policy: QuicAllowed=0 for Edge + Chrome (restart browser to take effect)."

# 3. sanity: confirm TCP 443 still open (we must NOT have cut off HTTPS)
$t = Test-NetConnection 1.1.1.1 -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($t) { Ok "Verified: TCP 443 still reachable - internet intact, just TCP-only now." }
else { Write-Host "    WARNING: TCP 443 test failed - run -Revert if the connection dropped." -ForegroundColor Yellow }

Write-Host "`nDone. All HTTPS now rides TCP through the PEP. Restart your browser for full effect." -ForegroundColor Green
Start-Sleep 4
