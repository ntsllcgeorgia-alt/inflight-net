# inflight-net

Make airline satellite Wi-Fi usable on a Windows laptop.

It figures out **which satellite system the plane is on** from the latency
fingerprint, then applies the tuning that matches it — because the right settings
for a geostationary link are different from a LAN's, and several are the exact
opposite. Everything is reversible with one command.

Works as a [Claude Code](https://claude.com/claude-code) skill, or as plain
PowerShell + Python scripts with no Claude at all.

---

## Already boarding? Do this.

```powershell
git clone https://github.com/ntsllcgeorgia-alt/inflight-net.git
cd inflight-net
```

Join the plane's Wi-Fi, clear the captive portal in a browser, then **open
PowerShell as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\inflight-auto.ps1
```

That one command fingerprints the satellite and applies the matching profile.
On landing:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\inflight-off.ps1
```

Add `-WhatIf` to the first command to see what it would change without changing
anything. Add `-KeepDns` if you haven't passed the captive portal yet — the
portal needs to hijack DNS to show you its login page.

---

## Flying to China (or anywhere behind a national firewall)

**Run it with `-KeepDns` on this route.** One command changes:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\inflight-auto.ps1 -KeepDns
```

The tuning sets DNS to `1.1.1.1` / `8.8.8.8`. Both are blocked and
DNS-poisoned inside China. Every other part of the tuning — the window scaling,
MTU clamp, CTCP, power-save — is pure TCP and works fine there. It's only the
DNS line that bites, and `-KeepDns` skips exactly that.

If you already ran it without the flag and the internet dies on approach or
after landing, that's the cause. Fix:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\inflight-off.ps1
```

Other things that are true on this route and not on a domestic hop:

- **Wi-Fi often cuts out over mainland Chinese airspace.** Several carriers
  switch the satellite link off there, or route it through a ground gateway
  where the firewall applies. Nothing you can fix in software. Get your
  downloading done over the Pacific.
- **Have your VPN installed and tested before you land.** The app stores and
  most VPN provider sites are blocked from inside, so it's hard to fix after
  arrival. Install it at the gate if you haven't.
- **Roaming works.** Data on international roaming routes back through your home
  carrier, so it comes out unfiltered. Usually the easiest path for a short trip.
- **Expect Google, Gmail, WhatsApp, Instagram and most AI chat sites to be
  unreachable** on local Wi-Fi. WeChat is the thing everyone actually uses.

## A note on the satellite names

The vendor labels (`STARLINK` / `VIASAT` / `ANUVU`) are calibrated against
Southwest's fleet. On an international carrier you're more likely on Panasonic,
Gogo 2Ku, or Viasat, so **the name it prints may be wrong.**

That doesn't matter. The tuning keys off the round-trip time, not the vendor —
the script sorts the link into low-orbit vs geostationary, and that split is
physics. A 600 ms link needs the same treatment whoever is selling it. Read the
printed name as "geostationary" or "low orbit" and ignore the brand.

## What it's actually fixing

The plane's pipe usually isn't the problem. These are, in order:

1. **Your TCP window is too small for the link.** At 600 ms round-trip, a default
   64 KB window caps a single download at **~0.9 Mbps** no matter how fat the
   satellite pipe is. This is the number one killer and almost nobody fixes it.
2. **Serial round-trips.** DNS + TCP handshake + TLS + first byte = **~3 seconds
   before a page even starts** on a geostationary link.
3. **MTU mismatch.** Inflight Wi-Fi tunnels your traffic. Full-size packets get
   silently dropped and TCP reads that as congestion and slows down. Clamping MTU
   is a big invisible win.
4. **Your own uploads.** OneDrive syncing one photo saturates the tiny upstream,
   which delays your ACKs, which throttles everything you're downloading.

## Which satellite am I on?

Ping `1.1.1.1` and read the round-trip time:

| RTT | System | Orbit | What to expect |
|---|---|---|---|
| **20–90 ms** | Starlink | low, ~340 mi | Behaves like real broadband |
| **550–700 ms** | Viasat | geostationary, 22,236 mi | Good bandwidth, brutal latency |
| **650–900 ms** | Anuvu | geostationary | Oldest kit, worst contention |

On a geostationary link ~480 ms of that is pure speed of light — the signal goes
22,236 miles up and back, twice. No software fixes that. What software *can* fix
is everything that latency breaks, which is most of TCP's default behavior.

## The tools

| File | Admin? | What it does |
|---|---|---|
| `scripts/inflight-auto.ps1` | **yes** | **Start here.** Fingerprint + apply the matching profile |
| `scripts/inflight-off.ps1` | **yes** | Restore everything from the backup it wrote |
| `scripts/preflight.ps1` | no | Run in the lounge before boarding — caches npm/pip/git/docs so you never fetch them at 0.9 Mbps |
| `scripts/detect.ps1` | no | Read-only: satellite ID, MTU discovery, portal state, bandwidth hogs |
| `scripts/connect-southwest.ps1` | **yes** | Join the network, pin 5 GHz, auto-reconnect, open the portal |
| `scripts/portal.ps1` | no | Open the captive portal in a throwaway browser profile with cert checks off (these certs are often expired) |
| `scripts/prefer-plane.ps1` | **yes** | Make aircraft Wi-Fi the primary route when a phone tether is also connected |
| `scripts/quic-off.ps1` | no | Force TCP where a middlebox is mangling QUIC |
| `scripts/sat-console.ps1` | no | Isolate the pure satellite hop + live geometry |
| `py/linkbench.py` | no | Measures RTT/jitter/bandwidth-delay-product, sweeps concurrency, gives you your magic number |
| `py/watch.py` | no | Live monitor — tells you when you're in a good window to push a big transfer |
| `py/grab.py` | no | Parallel chunked downloader with per-chunk retry and resume across dropouts |
| `py/sat_track.py` | no | Works out the exact satellite you're on, and where to look out the window |

All Python is **standard library only** — you can't `pip install` at 35,000 feet.

```powershell
python .\py\linkbench.py                      # find your best concurrency
python .\py\watch.py                          # leave running in a 2nd terminal
python .\py\grab.py <url> --conc 8            # download with resume
```

## Why some choices look backwards

- **Nagle and delayed-ACK are deliberately left ON.** Gaming guides tell you to
  disable them, and on a home LAN that's right because the uplink is free.
  Inflight the uplink is the scarcest thing on the aircraft — more ACK packets
  directly slow your downloads. Opposite link, opposite call.
- **CTCP instead of CUBIC.** CTCP is delay-aware and opens the window much faster
  on a long fat pipe. CUBIC reads satellite bit-errors as congestion and backs off.
- **ECN off.** The performance-enhancing proxies used inflight mishandle ECN bits.
- **Window autotuning `normal`, not `experimental`.** The bigger scaling factor
  gets mangled by some inflight middleboxes. Only go experimental if `linkbench.py`
  says you're still window-capped.

## What this does not do

This maximizes **your** share of the link. It doesn't take anyone else's.
No deauth, no ARP poisoning, no MAC flooding, no session farming. Past the legal
problem, all of those get your MAC blackholed by the gateway mid-flight — the
exact outcome you don't want. The tuning here beats hogging anyway, because on a
geostationary link latency is the constraint, not your slice of the pipe.

## Using it as a Claude Code skill

Clone it into your skills folder and Claude will drive it for you:

```powershell
git clone https://github.com/ntsllcgeorgia-alt/inflight-net.git "$HOME\.claude\skills\inflight-net"
```

Then just say `/inflight-net`, or "the plane wifi is slow", or "restore my
network after the flight."

## Notes

- Windows only. The tuning uses `netsh`, `Set-NetTCPSetting` and Wi-Fi adapter
  power settings.
- Admin scripts write a backup to `state/` first; `inflight-off.ps1` reads it back.
- Tested against Southwest's three systems, but the fingerprint-and-tune approach
  applies to any airline's satellite Wi-Fi.

MIT licensed. No warranty — it changes TCP settings on your machine.
