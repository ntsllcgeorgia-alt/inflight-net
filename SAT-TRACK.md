# sat-track — locate the satellite carrying your flight

Part of the `inflight-net` skill. `py/sat_track.py`.

## What it does (and the honest limit)

You **cannot** directly connect to a Ku-band GEO satellite from a laptop. Your
Wi-Fi radio is 2.4/5 GHz; the satellite listens on 12–18 GHz. Talking to it needs
a ~1-ft pointed dish, several watts of licensed transmit power, and a leased
transponder — and transmitting on that uplink unlicensed would jam the aircraft's
service. The satellite is also a dumb "bent-pipe" relay; there's no login on it.

What this tool does instead is the only real form of "connecting" to it that a
laptop can: it **reaches out over the very link the satellite provides, pulls the
bird's authoritative live orbital elements from Celestrak, computes exactly where
it is right now, and tells you where to look out the window to see it.** Passive,
legal, and precise.

## Use

```bash
python py/sat_track.py --from ELP --to DAL --heading 85   # route midpoint + heading
python py/sat_track.py --lat 31.8 --lon -102.4            # exact position
python py/sat_track.py --sat "NUVIEW"                     # one bird
```

`--heading` (aircraft compass heading) adds **which side of the plane** — left or
right window.

## How it works

1. **Live fetch** — GP/TLE elements from `celestrak.org` over the aircraft link.
2. **Propagation** — solves Kepler's equation, builds the ECI position vector,
   rotates to Earth-fixed coordinates using GMST → sub-satellite lat/lon/alt.
   **Validated against GOES-18 (0.2° error) and GALAXY 19 (0.0° error).**
3. **Look angles** — closed-form azimuth / elevation / slant range from your
   position to each geostationary bird, plus one-way light time = range ÷ c.

## Measured result — WN1786, ELP→DAL, 2026-07-27 01:54 UTC

Southwest's Anuvu Wi-Fi rides the **Astranis NuView** MicroGEO birds:

| | NuView Alpha | NuView Bravo |
|---|---|---|
| NORAD ID | 62455 | 62457 |
| Slot | **83.1° W** (over the equator, ~eastern US meridian) | 83.1° W |
| From the plane | **SSW, 47° above horizon, right-side windows** | same |
| Distance | **37,253 km** | 37,252 km |
| Round-trip light time | **249 ms** | 249 ms |

That 249 ms is the hard floor under every page load — it's pure distance at the
speed of light, and no tuning, payment tier, or "booster" can reduce it. Both
birds are co-located in the same 83°W slot (a common two-satellite cluster).

The tool also lists every other Americas Ku bird above your horizon (the GALAXY
fleet, GOES-18, Telstar 19V) with live positions — handy because Anuvu also
leases capacity on those, so on another flight your bird may differ.

## Companion: sat-console.ps1 — touch the satellite directly

`scripts/sat-console.ps1` gets as physically close to the bird as a laptop can,
in 5 stages, and isolates the satellite hop itself:

```powershell
.\scripts\sat-console.ps1 -Rounds 20
```

1. **Modem** — pings `172.19.0.1`, the onboard gateway wired to the antenna
   (~5 ms; pure on-plane latency).
2. **First hop across the bird** — traceroute finds the first node on the far
   side of the satellite (~680–740 ms).
3. **Isolate the satellite** — (across-bird RTT − modem RTT) = the **pure space
   segment**, every terrestrial hop subtracted out. Measured on WN1786: **~680 ms**.
4. **Live geometry** — calls `sat_track.py` for NuView's current az/el/range.
5. **Watch it breathe** — samples end-to-end RTT and flags `SPIKE`/`DROP` on beam
   or satellite handovers.

Caveats: Stage 3's km figure over-reads true altitude (ICMP includes modem/PEP +
ground-to-teleport processing, not just vacuum flight) — the clean physics number
is Stage 4's 248 ms / 37,114 km. Internal hops answer only traceroute, not direct
echo, so Stage 5 tracks end-to-end RTT rather than per-hop columns.

## Who owns what in this chain (WN1786, verified 2026-07)

- **Satellite:** NuView Alpha/Bravo — **built AND operated by Astranis** (SF);
  debut of a privately-owned GEO network. 50 Gbps combined over the US.
- **Capacity leased by:** **Anuvu** (Santa Ana, CA; owned by Platinum Equity) —
  runs Ku-band IFC on 800+ aircraft across 6 airlines.
- **Airline:** **Southwest** — 803 all-737 aircraft, ~3,274 flights/day, biggest
  Anuvu customer. Migrating to Starlink through 2026.
- Chain: **Southwest → pays Anuvu → runs on Astranis's satellite.**

## Sources
Celestrak GP catalog (live). NuView = Astranis MicroGEO for Anuvu (Runway Girl
Network, Via Satellite, SpaceNews, Aug 2025). Southwest scale: SEC 10-K FY2025.
