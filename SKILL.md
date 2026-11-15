---
name: inflight-net
description: Maximize your laptop throughput on airline satellite Wi-Fi (Southwest = Anuvu Ku-band, Viasat Ka-band, or Starlink LEO depending on tail number). Detects which satellite system the plane uses from its latency fingerprint, then tunes Windows for a high bandwidth-delay-product link — MTU clamp, TCP window scaling, CTCP, radio power-save, uplink-hog suspension — plus Python tools to benchmark, monitor good windows, and pull files in parallel chunks with resume. Fully reversible. Triggers on "/inflight-net", "airplane wifi", "plane internet is slow", "inflight wifi", "I'm about to fly", "southwest wifi", "make the plane wifi faster", "restore my network after the flight".
---

# Inflight Net — squeeze a satellite link dry

## What you're actually connected to

Southwest runs **three different systems** and you don't get to choose. The cabin
crew won't know which one you're on. The **latency fingerprint tells you**:

| RTT to 1.1.1.1 | System | Band | Orbit | What it means |
|---|---|---|---|---|
| **20–90 ms** | **Starlink** | Ku (phased array) | LEO, ~340 mi | New. Rolling out since Jun 2026, 300 jets by Dec 2026. Behaves like real broadband. |
| **550–700 ms** | **Viasat** | Ka-band | GEO, 22,236 mi | Line-fit on new 737 MAX since 2022. Decent bandwidth, brutal latency. |
| **650–900 ms** | **Anuvu** (ex-Global Eagle) | Ku-band | GEO + MicroGEO | Oldest kit, on legacy 737-700/800. Narrowest pipe, worst contention. Being replaced by Starlink. |

**Why GEO feels broken:** the signal goes 22,236 miles up and 22,236 back, twice
per round trip. That's ~480 ms of pure speed-of-light, before any processing. No
software fixes that. What software *can* fix is everything that latency breaks —
which is most of TCP's default behavior.

**The real bottleneck, in order:**
1. **TCP window too small for the bandwidth-delay product.** At 600 ms RTT, a
   default 64 KB window caps a single stream at **~0.9 Mbps** no matter how fat
   the satellite pipe is. This is the #1 killer and almost nobody fixes it.
2. **Serial round-trips.** DNS lookup (600 ms) + TCP handshake (600 ms) + TLS
   (1200 ms) + first byte (600 ms) = **3 seconds before a page starts**. Fixed by
   connection reuse, DoH, and fewer distinct hosts.
3. **MTU mismatch.** The IFC link tunnels your traffic. Packets sized for a
   normal 1500-byte path get silently dropped, and TCP interprets that as
   congestion and slows down. Clamping MTU is a large, invisible win.
4. **Your own uplink.** OneDrive syncing one photo saturates the tiny upstream,
   which delays your ACKs, which throttles every download you have.
5. Contention with the cabin — the part you cannot and should not fight.

## Scope — what this does NOT do

This maximizes **your** share. It does not take other passengers' bandwidth.
No deauth, no ARP poisoning, no MAC flooding, no multi-MAC session farming.
Beyond the legal problem, all of those get your MAC blackholed by the IFC
gateway mid-flight, which is exactly the outcome you don't want. The tuning
below beats hogging anyway, because on a GEO link **latency is the constraint,
not your slice of the pipe.**

---

## Run order

### Before you board (in the lounge, on good Wi-Fi) — biggest win of all
```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude\skills\inflight-net\scripts\preflight.ps1"
```
Pulls down everything you'd otherwise fetch at 0.9 Mbps: npm/pip caches, docs,
model weights, `git fetch --all`, Docker pulls, and any URL list you give it.
**One minute here saves an hour up there.**

### On the plane, after joining `SouthwestWiFi` and accepting the portal
```powershell
# 1. read-only - identifies the satellite, measures MTU, finds hogs
powershell -ExecutionPolicy Bypass -File ".\scripts\detect.ps1"

# 2. ADMIN - the actual tuning. Reversible.
powershell -ExecutionPolicy Bypass -File ".\scripts\inflight-on.ps1" -DisableIPv6

# 3. find how many parallel streams this link rewards
python .\py\linkbench.py

# 4. leave running in a 2nd terminal - tells you when to push big transfers
python .\py\watch.py

# 5. pull files using that concurrency number, with resume across dropouts
python .\py\grab.py <url> --conc 8
python .\py\grab.py --list urls.txt --conc 8
```

### On landing
```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\inflight-off.ps1"   # ADMIN
```

## Files

| File | Admin | Does |
|---|---|---|
| `scripts/preflight.ps1` | no | Cache everything before boarding |
| `scripts/connect-southwest.ps1` | **yes** | Join SouthwestWiFi, pin 5 GHz, auto-reconnect, open portal |
| `scripts/portal.ps1` | no | Open captive portal in a throwaway browser profile with cert checks off (Southwest's cert is expired) |
| `scripts/prefer-plane.ps1` | **yes** | Make aircraft Wi-Fi the primary route when a phone tether is also plugged in |
| `scripts/detect.ps1` | no | Satellite fingerprint, MTU discovery, portal state, hog list |
| `scripts/sat-console.ps1` | no | Isolate the pure satellite hop + live geometry (see SAT-TRACK.md) |
| `py/sat_track.py` | no | Locate the exact satellite you're on; where to look out the window (see SAT-TRACK.md) |
| `scripts/inflight-on.ps1` | **yes** | MTU clamp, TCP window scaling + CTCP, throttle removal, radio power-save off, suspend uploaders, DoH DNS |
| `scripts/inflight-off.ps1` | **yes** | Restore all of it from `state\inflight-backup.json` |
| `py/linkbench.py` | no | RTT/jitter/BDP + concurrency sweep → your magic number |
| `py/watch.py` | no | Live monitor; flags GOOD WINDOW / congested / OUTAGE |
| `py/grab.py` | no | Parallel Range downloader, per-chunk retry, resume after dropout |

All Python is **stdlib only** — you cannot `pip install` on a plane.

## Design notes (why some choices look backwards)

- **Nagle and delayed-ACK are deliberately LEFT ON.** The `warzone-net` skill
  turns them off, because on a home LAN the uplink is free. Inflight the uplink
  is the scarcest resource on the aircraft — more ACK packets directly slow your
  downloads. Opposite link, opposite call.
- **CTCP over CUBIC.** CTCP is delay-aware and ramps the window far faster on a
  long fat pipe. CUBIC's loss-based backoff misreads satellite bit-errors as
  congestion.
- **ECN off.** Inflight performance-enhancing proxies (PEPs) mishandle ECN bits.
- **`autotuninglevel=normal`, not `experimental`, by default.** Experimental's
  larger scaling factor gets mangled by some IFC middleboxes. Use
  `-Experimental` only if `linkbench.py` shows you're still window-capped.
- **DNS is changed last**, and skipped with `-KeepDns` if you haven't passed the
  captive portal — the portal needs to hijack DNS to show you its login page.

## Sources
Southwest IFC providers and the Starlink transition:
Runway Girl Network, Via Satellite, Viasat investor relations, Simple Flying (Feb–Jun 2026).
