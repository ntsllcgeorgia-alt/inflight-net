# portal.ps1 — open the Southwest captive portal in a throwaway Chrome profile
# that ignores the expired certificate on ALL southwestwifi.com hosts.
#
# Why this is needed: Southwest's wildcard cert expired 2026-07-06. Clicking
# "proceed anyway" in your normal browser only whitelists the ONE hostname you
# clicked. The portal page then loads scripts from pa. / initial. / media. /
# tracker.southwestwifi.com, each of which throws its own cert error and is
# silently hard-blocked - so the page renders but never advances.
#
# This launches an ISOLATED Chrome profile (your real profile, cookies, saved
# cards and passwords are NOT used) with cert checking off, just for the portal.
# Close the window when you're done - the profile is disposable.

param([string]$Url = 'http://getconnected.southwestwifi.com')

$profileDir = Join-Path $env:TEMP 'sw-portal-profile'
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

$chrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$edge = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$exe = if ($chrome) { $chrome } elseif ($edge) { $edge } else { $null }
if (-not $exe) { Write-Host "No Chrome or Edge found." -ForegroundColor Red; exit 1 }

Write-Host "Launching $(Split-Path $exe -Leaf) in an isolated profile with cert checks off..." -ForegroundColor Cyan
Write-Host "This window is ONLY for the portal. Close it when you're connected." -ForegroundColor Yellow

& $exe `
  --user-data-dir="$profileDir" `
  --ignore-certificate-errors `
  --ignore-ssl-errors `
  --allow-insecure-localhost `
  --no-first-run `
  --no-default-browser-check `
  --new-window $Url

Write-Host "If the page still stalls, try these in that window:" -ForegroundColor Green
Write-Host "   http://neverssl.com"
Write-Host "   http://192.168.1.1  /  http://172.19.0.1   (the gateway itself)"
Write-Host "   http://getconnected.southwestwifi.com/initial"
