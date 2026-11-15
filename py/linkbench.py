#!/usr/bin/env python3
"""
linkbench.py - measure an inflight satellite link and find the concurrency sweet spot.

Stdlib only (no pip - you won't be able to install on the plane).

  python linkbench.py            # full run, ~90s
  python linkbench.py --quick    # ~30s

What it tells you that a speed test won't:
  * Bandwidth-delay product -> the TCP window you actually need
  * How many parallel connections this link rewards before it collapses
  * Whether the bottleneck is the satellite or the cabin AP
"""
import argparse, json, socket, ssl, statistics, sys, threading, time
import urllib.request

CF = "https://speed.cloudflare.com/__down?bytes={}"
UA = {"User-Agent": "Mozilla/5.0 linkbench"}


def tcp_rtt(host="1.1.1.1", port=443, n=8):
    out = []
    for _ in range(n):
        s = socket.socket()
        s.settimeout(10)
        t = time.perf_counter()
        try:
            s.connect((host, port))
            out.append((time.perf_counter() - t) * 1000)
        except Exception:
            pass
        finally:
            s.close()
        time.sleep(0.15)
    return out


def dns_time(name="www.google.com", n=5):
    out = []
    for _ in range(n):
        t = time.perf_counter()
        try:
            socket.getaddrinfo(name, 443)
            out.append((time.perf_counter() - t) * 1000)
        except Exception:
            pass
    return out


def grab(nbytes, timeout=45):
    """Download nbytes, return (bytes, seconds)."""
    req = urllib.request.Request(CF.format(nbytes), headers=UA)
    t = time.perf_counter()
    got = 0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            while True:
                b = r.read(65536)
                if not b:
                    break
                got += len(b)
    except Exception:
        pass
    return got, time.perf_counter() - t


def parallel_mbps(conc, nbytes, timeout=45):
    res = [None] * conc
    def w(i):
        res[i] = grab(nbytes, timeout)
    th = [threading.Thread(target=w, args=(i,)) for i in range(conc)]
    t = time.perf_counter()
    for x in th: x.start()
    for x in th: x.join()
    wall = time.perf_counter() - t
    total = sum(r[0] for r in res if r)
    return (total * 8 / wall / 1e6) if wall > 0 else 0.0, total, wall


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--json", help="write results to this file")
    a = ap.parse_args()

    print("== RTT ==")
    rtts = tcp_rtt(n=5 if a.quick else 10)
    if not rtts:
        print("  no TCP reachability - are you past the captive portal?")
        sys.exit(1)
    rtt = statistics.median(rtts)
    jit = statistics.pstdev(rtts) if len(rtts) > 1 else 0
    print(f"  median {rtt:7.1f} ms   min {min(rtts):7.1f}   max {max(rtts):7.1f}   jitter {jit:5.1f}")

    if rtt < 120:      link = "Starlink (LEO)"
    elif rtt < 450:    link = "ground / LEO under load"
    elif rtt < 750:    link = "Viasat Ka-band (GEO)"
    else:              link = "Anuvu Ku-band (GEO)"
    print(f"  looks like: {link}")

    d = dns_time()
    if d:
        print(f"\n== DNS ==\n  median {statistics.median(d):.0f} ms "
              f"({'portal DNS is a tax - switch to DoH' if statistics.median(d) > 300 else 'ok'})")

    print("\n== CONCURRENCY SWEEP ==")
    size = 2_000_000 if a.quick else 5_000_000
    levels = [1, 4, 8] if a.quick else [1, 2, 4, 8, 12, 16]
    best = (0, 1)
    rows = []
    for c in levels:
        mbps, tot, wall = parallel_mbps(c, size // max(1, c // 2 or 1))
        rows.append({"conc": c, "mbps": round(mbps, 2), "bytes": tot, "sec": round(wall, 1)})
        bar = "#" * int(min(mbps, 60))
        print(f"  {c:2d} conn  {mbps:7.2f} Mbps  {bar}")
        if mbps > best[0]:
            best = (mbps, c)
        elif mbps < best[0] * 0.75:
            print("     (throughput collapsing - stopping sweep)")
            break
        time.sleep(1)

    mbps, conc = best
    bdp = mbps * 1e6 / 8 * (rtt / 1000.0)
    print("\n== VERDICT ==")
    print(f"  Peak throughput      : {mbps:.2f} Mbps at {conc} parallel connections")
    print(f"  Bandwidth-delay prod : {bdp/1024:,.0f} KB  <- TCP window must exceed this")
    if bdp > 64 * 1024:
        print("  ! BDP > 64 KB: without window scaling you are capped far below the real link.")
        print("    inflight-on.ps1 sets autotuning + scaling to cover this.")
    print(f"  Use {conc} parallel streams in grab.py:  --conc {conc}")
    if conc >= 8:
        print("  This link rewards parallelism heavily - single-stream downloads waste it.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump({"rtt_ms": rtt, "jitter_ms": jit, "link": link,
                       "peak_mbps": mbps, "best_conc": conc, "bdp_bytes": bdp,
                       "sweep": rows}, f, indent=2)
        print(f"\n  wrote {a.json}")


if __name__ == "__main__":
    main()
