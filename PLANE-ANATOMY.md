# Anatomy of the Airplane Internet — Southwest WN1786 (ELP→DAL)

A full teardown of how the internet actually reaches your laptop at 35,000 ft,
built from **live measurements taken on this flight** (2026-07-26) plus public
research. Every number below the "Measured" headings is real data pulled off the
aircraft network, not spec-sheet marketing.

---

## TL;DR — the one-paragraph version

Your laptop talks Wi-Fi to an access point in the ceiling. That AP feeds an
onboard **gateway/PEP** (a small Linux server running Kong + CherryPy). The
gateway's antenna on the belly/tail of the 737 shoots a **Ku-band** signal
**22,236 miles straight up** to an **Astranis MicroGEO satellite** (NuView Alpha
or Bravo), which relays it back down to an **Anuvu teleport (ground station)**
that egresses to the real internet through the **Denver internet exchange**. The
round trip is ~**780 ms of pure physics**. An onboard proxy hides most of that
from your apps by faking local TCP acknowledgements. This is the oldest, slowest
Southwest connectivity tier — being replaced fleet-wide by Starlink through 2026.

---

## The physical stack, top to bottom

```
   YOUR LAPTOP  (MediaTek MT7925, 5 GHz, ch 149, ~400 Mbps link rate)
        │  Wi-Fi 802.11ac
        ▼
   CEILING ACCESS POINT  ×4 around the cabin (each 2.4 + 5 GHz)
        │  wired ethernet in the crown of the fuselage
        ▼
   ONBOARD GATEWAY / PEP   172.19.0.1   (MAC 58:68:61:0a:89:b7)
   • Kong 3.4.2 API gateway + CherryPy (Python) web stack
   • Captive portal ("avp-portals" = Anuvu Video/Portal)
   • TCP Performance-Enhancing Proxy  ← the magic, explained below
        │  coax to the antenna
        ▼
   Ku-BAND AERO ANTENNA  (Anuvu Airconnect shipset, belly/tailcone radome)
        │  ▲ 22,236 mi UP        ~250 ms one way
        ▼ │
   ASTRANIS MicroGEO SATELLITE   "NuView Alpha" or "NuView Bravo"
   • Ku-band, geostationary, built + operated by Astranis for Anuvu
   • Launched 2024-12-29 on a Falcon 9; in service over CONUS since ~Jul 2025
   • ~50 Gbps added capacity across N. America + Caribbean
        │  ▲ 22,236 mi DOWN
        ▼
   ANUVU TELEPORT / GROUND STATION  (this flight: routed via Denver)
   • 192.168.142.2, 10.92.x, 10.95.x  = internal ground network
        │
        ▼
   IX-DENVER  (Denver Internet Exchange, 206.53.175.0/24)
        │
        ▼
   CLOUDFLARE EDGE (172.68.32.12, colo=DEN)  →  THE INTERNET
   Public egress IP seen by websites: 67.54.x  (geolocates to Denver)
```

---

## The traceroute that proves it (measured on this flight)

```
hop  RTT                     IP                what it is
 1   5–11 ms                 172.19.0.1        onboard gateway/PEP  ← still on the plane
 2   651–730 ms              10.44.48.199      ★ THE SATELLITE HOP ★ (+640 ms in one leap)
 4   689–738 ms              192.168.142.2     teleport internal
 6   711–748 ms              10.92.108.3       Anuvu ground network
 7   702–853 ms              10.95.15.45       Anuvu ground network
 9   725–782 ms              206.53.175.29     IX-Denver
10   707–778 ms              206.53.175.20     IX-Denver
11   715–738 ms              172.68.32.12      Cloudflare edge (Denver)
12   731–840 ms              1.1.1.1           destination
```

**Read hop 1 → hop 2.** Latency explodes from 11 ms to 651 ms in a single step.
That +640 ms *is* the trip to geostationary orbit and back. No hop after it adds
meaningful latency — the entire delay of airplane internet lives in that one
leap, and it is **the speed of light over 45,000+ miles**, not congestion. No
software, no payment tier, no "booster" can reduce it. It is physics.

---

## The PEP — why your ping says 21 ms but the satellite is 780 ms

The single most important trick in satellite internet.

- **ICMP ping to 1.1.1.1: ~780 ms.** This is the *honest* round trip — ICMP is
  passed straight through to the destination.
- **TCP handshake to 1.1.1.1:443: ~21 ms.** This is a *lie the gateway tells you
  on purpose.*

The onboard gateway runs a **Performance-Enhancing Proxy**. When your laptop
opens a TCP connection, the PEP **terminates it locally on the plane** and
immediately sends back the acknowledgements itself — from 11 ms away — instead of
waiting 780 ms for the real server to answer. The PEP then runs its *own*
separate, heavily-tuned TCP session across the satellite link on your behalf.

Why this matters:
- Standard TCP interprets 780 ms of delay as a broken network and refuses to
  speed up (it never opens its send window). The PEP sidesteps that entirely.
- It means **your** TCP tuning can only help the short hop to the PEP — the
  satellite leg is the PEP's job. So the winning move for you is **not** bigger
  windows; it's **many parallel connections**, because each one gets its own PEP
  session and its own slice of the satellite pipe.
- It's also why `linkbench.py` mis-reads the link as "Starlink" — it times the
  TCP handshake, which the PEP masks.

---

## The satellite: Astranis NuView (MicroGEO)

Southwest's legacy Wi-Fi (this flight) rides Anuvu's Ku-band GEO network. Since
2025 that includes two purpose-built small satellites:

| | |
|---|---|
| Names | **NuView Alpha** (NuView-A) and **NuView Bravo** (NuView-B) |
| Builder/operator | **Astranis** (private GEO — a new model vs. giant traditional birds) |
| Band | **Ku-band**, geostationary (~35,786 km / 22,236 mi altitude) |
| Launched | 2024-12-29, SpaceX Falcon 9; operational over CONUS ~July 2025 |
| Capacity | ~50 Gbps added, focused on North America + Caribbean |
| Older capacity | Also leans on traditional wide-beam Ku-band GEO fleet |

"MicroGEO" = a smaller, cheaper satellite parked in the same geostationary slot
as the giants. Same altitude, so **same ~780 ms latency** — the win is capacity
and cost, not speed-of-light. Anuvu's newer "Dedicated Space" modem on the 737
claims ~2× download / 4× upload / 35% higher peak vs. the previous generation.

---

## Measured performance on this flight (after tuning)

| Metric | Value | Note |
|---|---|---|
| True satellite RTT (ICMP) | **~780 ms** | 743–864 ms, jitter ~120 ms |
| PEP-spoofed TCP RTT | ~21 ms | the gateway faking local ACKs |
| Single-stream throughput | **7.6 Mbps** | what one download/tab gets |
| Peak throughput | **19.6 Mbps @ 12 streams** | your real ceiling, shared w/ cabin |
| Parallelism gain | **2.6×** | why `grab.py --conc 12` matters |
| Path MTU | 1402 payload → **1430 MTU** | link tunnels traffic; 1500 fragments |
| Wi-Fi link | 5 GHz, ch 149, 802.11ac, 400 Mbps, 89% | pinned to 5 GHz to dodge the 2.4 crowd |
| Public egress | 67.54.x (Denver) | teleport is Denver-fed on this route |

---

## The onboard software stack (fingerprinted)

- **`Via: kong/3.4.2`** — Kong API gateway fronts every portal request.
- **`Server: CherryPy/unknown`** — Python CherryPy behind Kong.
- **Captive portal** — a webpack SPA tagged `_sentryBundlerPluginAppKey:avp-portals`,
  Sentry release `SWA-…`, with a **FlightPath3D** moving-map module. 100%
  client-side JS, which is why an expired TLS cert on one script silently
  freezes the whole page.
- Portal hosts (all on one wildcard cert, **expired 2026-07-06**):
  `getconnected`, `initial`, `pa`, `connected`, `media`, `tracker`,
  `flightdata`, `publicflightdata`, `stream`, `.southwestwifi.com`.
- Two onboard subnets seen: **172.19.0.0** (your client side, gateway
  172.19.0.1) and **172.18.0.0** (DNS at 172.18.0.1) — both answer as the same
  Kong/CherryPy gateway.

---

## Why the portal wouldn't load (and the fix that worked)

Southwest let the `*.southwestwifi.com` certificate **expire on 2026-07-06**.
The portal is a JS SPA that pulls scripts from `media.`, `initial.`, `pa.` etc.
Clicking "proceed anyway" in a normal browser whitelists only the *one* hostname
you clicked; the *other* hosts still hard-fail their cert check, their scripts
never load, and the page hangs while looking fine. It is not an attack — the
cert is genuinely issued to "Southwest Airlines Co., Dallas TX" by IdenTrust; it
just lapsed.

**Fix:** launch a throwaway browser profile with cert checks fully off
(`portal.ps1` → `--ignore-certificate-errors`), so every portal host loads.

---

## Practical rules this anatomy dictates

1. **Parallelize everything.** The PEP gives each connection its own satellite
   session. 1 stream = 7.6 Mbps; 12 streams = 19.6 Mbps. Use `grab.py --conc 12`.
2. **Latency is unfixable.** 780 ms is 45,000 miles of light. Video calls,
   gaming, SSH will always feel laggy. Downloads, email, git, web, and this
   Claude session are fine.
3. **Guard your uplink.** The upstream to the satellite is tiny. One background
   uploader (OneDrive, Creative Cloud) starves your ACKs and throttles *all*
   your downloads. `inflight-on.ps1` suspends them.
4. **Ride the windows.** Beam/satellite handovers drop you for 5–20 s and the
   cabin contends for the shared pipe. `watch.py` flags GOOD WINDOW vs congested.
5. **This is the worst tier.** If a future Southwest flight pings at 20–90 ms,
   you're on **Starlink** (LEO) and can treat it like real broadband.

---

## Sources
- Runway Girl Network — *Anuvu MicroGEO satellites now operational over the US* (Aug 2025)
- Via Satellite — *2 Astranis MicroGEO Satellites Enter Service for Anuvu* (Aug 2025)
- SpaceNews — *Astranis brings Anuvu satellites online* (2025)
- Runway Girl Network — *Anuvu Dedicated Space modem equipage* (Apr 2025)
- Runway Girl Network / Via Satellite — Southwest Starlink transition (Feb–Jun 2026)
- Live network measurements, WN1786 ELP→DAL, 2026-07-26 (traceroute, RDAP, TLS, HTTP fingerprinting)
```
