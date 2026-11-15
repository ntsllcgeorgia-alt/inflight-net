# preflight.ps1 — run in the LOUNGE, on good Wi-Fi, before boarding.
# No admin needed. This is the single highest-value script in the skill:
# anything cached here is something you never fetch at 0.9 Mbps over a satellite.

param(
  [string]$Project = $PWD.Path,   # repo to git-fetch + npm-install before boarding
  [string]$UrlList,                  # optional: text file, one URL per line
  [switch]$SkipGit,
  [switch]$SkipNpm
)

$ErrorActionPreference = 'Continue'
function Step($m){ Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    $m" -ForegroundColor Yellow }

$t0 = Get-Date
Write-Host "PREFLIGHT CACHE WARM - do this before you board" -ForegroundColor Yellow

Step "Link check (make sure you're on the FAST connection right now)"
$r = Test-Connection 1.1.1.1 -Count 4 -EA SilentlyContinue
if ($r) {
  $avg = ($r | Measure-Object ResponseTime -Average).Average
  Ok "RTT $([math]::Round($avg)) ms"
  if ($avg -gt 200) { Warn "that's slow for a lounge/hotspot - consider switching networks before caching" }
} else { Warn "ICMP blocked; continuing anyway" }

if (-not $SkipGit) {
  Step "git fetch --all (so you can work offline against every branch)"
  if (Test-Path (Join-Path $Project '.git')) {
    Push-Location $Project
    $out = git fetch --all --tags --prune 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { Ok "fetched $Project" }
    else { Warn "git fetch FAILED (exit $LASTEXITCODE) - you will not have remote refs offline:"; Write-Host $out }
    Pop-Location
  } else { Warn "no .git at $Project" }
}

if (-not $SkipNpm) {
  Step "npm dependencies (Expo/RN installs are brutal over satellite)"
  if (Test-Path (Join-Path $Project 'package.json')) {
    Push-Location $Project
    if (-not (Test-Path 'node_modules')) {
      Warn "node_modules missing - installing now while you have bandwidth"
      npm install 2>&1 | Select-Object -Last 5
    } else {
      Ok "node_modules present"
    }
    Pop-Location
  }
}

Step "Docs / references worth having offline"
$docs = @(
  'https://reactnative.dev/docs/getting-started',
  'https://docs.expo.dev/'
)
$cacheDir = Join-Path $env:USERPROFILE 'inflight-cache'
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
foreach ($u in $docs) {
  try {
    $name = ($u -replace '[^a-zA-Z0-9]','_') + '.html'
    Invoke-WebRequest -Uri $u -OutFile (Join-Path $cacheDir $name) -UseBasicParsing -TimeoutSec 30
    Ok "cached $u"
  } catch { Warn "skip $u" }
}

if ($UrlList -and (Test-Path $UrlList)) {
  Step "Custom URL list -> $cacheDir"
  Get-Content $UrlList | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object {
    $u = $_.Trim()
    try {
      $name = Split-Path $u -Leaf
      if (-not $name) { $name = ($u -replace '[^a-zA-Z0-9]','_') }
      Invoke-WebRequest -Uri $u -OutFile (Join-Path $cacheDir $name) -UseBasicParsing -TimeoutSec 120
      Ok "cached $name"
    } catch { Warn "failed $u" }
  }
}

Step "Baseline benchmark (compare this against the plane later)"
$py = Get-Command python -EA SilentlyContinue
if ($py) {
  $bench = Join-Path (Split-Path -Parent $PSScriptRoot) 'py\linkbench.py'
  $out   = Join-Path (Split-Path -Parent $PSScriptRoot) 'state\baseline-ground.json'
  python $bench --quick --json $out
  Ok "baseline saved -> $out"
} else { Warn "python not on PATH - skipping baseline" }

Step "Pre-emptively pause the uploaders so they don't wake up mid-flight"
Warn "run inflight-on.ps1 (admin) once you're connected on the plane - it handles this"

Write-Host "`nPreflight done in $([int]((Get-Date)-$t0).TotalSeconds)s. Cache: $cacheDir" -ForegroundColor Green
