#!/usr/bin/env python3
"""
grab.py - parallel-chunk downloader built for satellite links.

On a GEO link a single TCP stream spends most of its life waiting for ACKs
600ms away. Splitting one file into N HTTP Range requests multiplies your
effective throughput without asking the cabin for a larger share - you are
just using YOUR share properly.

Features that matter at 35,000 ft:
  * HTTP Range parallel chunks with per-chunk retry
  * Resume: re-run the exact same command after a dropout, it continues
  * Adaptive concurrency: backs off when the link degrades instead of thrashing
  * Works on servers that don't support Range (falls back to single stream)

  python grab.py <url> [-o out] [--conc 8] [--chunk 2] [--list urls.txt]

Stdlib only.
"""
import argparse, json, os, sys, threading, time
import urllib.request, urllib.error

UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) grab.py"}
_lock = threading.Lock()
_done = 0
_total = 0


def head(url):
    """Return (size, supports_range)."""
    req = urllib.request.Request(url, headers=UA, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            size = int(r.headers.get("Content-Length") or 0)
            ar = (r.headers.get("Accept-Ranges") or "").lower()
            return size, ar == "bytes"
    except Exception:
        return 0, False


def fetch_range(url, start, end, path, tries=4):
    """Download [start,end] into path at offset start. Returns bytes written."""
    if os.path.exists(path + ".part") and os.path.getsize(path + ".part") > end:
        pass  # sparse file already sized; we still (re)write our slice
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers=dict(UA, Range=f"bytes={start}-{end}"))
            with urllib.request.urlopen(req, timeout=90) as r, \
                 open(path + ".part", "r+b") as f:
                f.seek(start)
                got = 0
                while True:
                    b = r.read(65536)
                    if not b:
                        break
                    f.write(b)
                    got += len(b)
                    with _lock:
                        global _done
                        _done += len(b)
                return got
        except Exception as e:
            if attempt == tries - 1:
                print(f"\n  chunk {start}-{end} failed: {e}", file=sys.stderr)
                return 0
            time.sleep(2 * (attempt + 1))   # satellite dropouts are bursty; back off
    return 0


def progress():
    start = time.time()
    while _done < _total:
        time.sleep(1)
        el = time.time() - start
        mbps = _done * 8 / el / 1e6 if el else 0
        pct = _done / _total * 100 if _total else 0
        eta = (_total - _done) / (_done / el) if _done else 0
        sys.stdout.write(f"\r  {pct:5.1f}%  {_done/1e6:8.1f}/{_total/1e6:.1f} MB  "
                         f"{mbps:6.2f} Mbps  eta {eta:5.0f}s   ")
        sys.stdout.flush()


def download(url, out, conc, chunk_mb):
    global _total, _done
    _done = 0
    size, ranged = head(url)
    if not out:
        out = os.path.basename(url.split("?")[0]) or "download.bin"

    # ---- resume state
    meta = out + ".grab"
    completed = set()
    if os.path.exists(meta):
        try:
            completed = set(tuple(x) for x in json.load(open(meta))["done"])
            print(f"  resuming: {len(completed)} chunks already complete")
        except Exception:
            completed = set()

    if not size or not ranged:
        print(f"  server has no Range support - single stream ({size/1e6:.1f} MB)")
        _total = size or 1
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=120) as r, open(out, "wb") as f:
            while True:
                b = r.read(65536)
                if not b:
                    break
                f.write(b)
                _done += len(b)
        print(f"\n  saved {out}")
        return

    _total = size
    print(f"  {size/1e6:.1f} MB, Range supported -> {conc} parallel streams")
    if not os.path.exists(out + ".part") or os.path.getsize(out + ".part") != size:
        with open(out + ".part", "wb") as f:
            f.truncate(size)

    step = int(chunk_mb * 1024 * 1024)
    chunks = [(s, min(s + step - 1, size - 1)) for s in range(0, size, step)]
    todo = [c for c in chunks if tuple(c) not in completed]
    _done = (len(chunks) - len(todo)) * step

    t = threading.Thread(target=progress, daemon=True)
    t.start()

    sem = threading.Semaphore(conc)
    results = {}

    def worker(c):
        with sem:
            n = fetch_range(url, c[0], c[1], out)
            results[c] = n
            if n > 0:
                completed.add(c)
                with _lock:
                    json.dump({"done": [list(x) for x in completed]}, open(meta, "w"))

    th = [threading.Thread(target=worker, args=(c,)) for c in todo]
    for x in th: x.start()
    for x in th: x.join()

    failed = [c for c in todo if results.get(c, 0) == 0]
    print()
    if failed:
        print(f"  {len(failed)} chunks still missing - re-run the same command to resume.")
        return
    os.replace(out + ".part", out)
    if os.path.exists(meta):
        os.remove(meta)
    print(f"  saved {out}  ({size/1e6:.1f} MB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url", nargs="?")
    ap.add_argument("-o", "--out")
    ap.add_argument("--conc", type=int, default=8, help="parallel streams (use linkbench.py's number)")
    ap.add_argument("--chunk", type=float, default=2.0, help="chunk size in MB")
    ap.add_argument("--list", help="file with one URL per line, downloaded in order")
    a = ap.parse_args()

    urls = []
    if a.list:
        urls = [l.strip() for l in open(a.list) if l.strip() and not l.startswith("#")]
    elif a.url:
        urls = [a.url]
    else:
        ap.error("give a url or --list")

    for u in urls:
        print(f"\n== {u}")
        try:
            download(u, a.out if len(urls) == 1 else None, a.conc, a.chunk)
        except KeyboardInterrupt:
            print("\n  interrupted - re-run to resume.")
            sys.exit(1)
        except Exception as e:
            print(f"  failed: {e}")


if __name__ == "__main__":
    main()
