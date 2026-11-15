#!/usr/bin/env python3
"""
watch.py - live inflight link monitor. Leave it running in a second terminal.

Cabin Wi-Fi is not steady - it comes in windows. Contention rises when the
cabin wakes up, the satellite beam handover drops you for 5-20s, and the AP
above your row is not the one you're associated with. This tells you WHEN to
push a big transfer instead of guessing.

  python watch.py                # 10s samples
  python watch.py --interval 5 --csv link.csv

Stdlib only.
"""
import argparse, csv, socket, statistics, sys, time
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 watch.py"}
PROBE = "https://speed.cloudflare.com/__down?bytes=300000"


def rtt(host="1.1.1.1", port=443, n=3):
    out = []
    for _ in range(n):
        s = socket.socket(); s.settimeout(8)
        t = time.perf_counter()
        try:
            s.connect((host, port)); out.append((time.perf_counter() - t) * 1000)
        except Exception:
            pass
        finally:
            s.close()
    return out


def spot_mbps():
    t = time.perf_counter(); got = 0
    try:
        with urllib.request.urlopen(urllib.request.Request(PROBE, headers=UA), timeout=25) as r:
            while True:
                b = r.read(32768)
                if not b: break
                got += len(b)
    except Exception:
        return 0.0
    el = time.perf_counter() - t
    return got * 8 / el / 1e6 if el else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=10)
    ap.add_argument("--csv")
    a = ap.parse_args()

    w = None
    if a.csv:
        f = open(a.csv, "w", newline="")
        w = csv.writer(f); w.writerow(["time", "rtt_ms", "jitter_ms", "loss_pct", "mbps", "state"])

    hist = []
    print(f"{'time':8} {'rtt':>7} {'jit':>6} {'loss':>5} {'Mbps':>7}  state")
    print("-" * 52)
    try:
        while True:
            r = rtt(n=4)
            loss = (4 - len(r)) / 4 * 100
            med = statistics.median(r) if r else float("nan")
            jit = statistics.pstdev(r) if len(r) > 1 else 0.0
            mb = spot_mbps() if loss < 100 else 0.0
            hist.append(mb)
            if len(hist) > 30: hist.pop(0)
            base = statistics.median(hist) if hist else mb

            if loss >= 75:      state, col = "OUTAGE - beam handover or you left coverage", "\033[91m"
            elif mb == 0:       state, col = "stalled", "\033[91m"
            elif mb > base*1.4: state, col = "GOOD WINDOW - push your big transfer NOW", "\033[92m"
            elif mb < base*0.6: state, col = "congested - cabin is busy, wait", "\033[93m"
            else:               state, col = "steady", ""

            line = (f"{time.strftime('%H:%M:%S')} {med:7.0f} {jit:6.1f} {loss:4.0f}% {mb:7.2f}  {state}")
            print(f"{col}{line}\033[0m" if col else line)
            if w:
                w.writerow([time.strftime("%H:%M:%S"), round(med, 1), round(jit, 1), loss, round(mb, 2), state]); f.flush()
            time.sleep(a.interval)
    except KeyboardInterrupt:
        if hist:
            print(f"\nsession: median {statistics.median(hist):.2f} Mbps, peak {max(hist):.2f} Mbps over {len(hist)} samples")


if __name__ == "__main__":
    main()
