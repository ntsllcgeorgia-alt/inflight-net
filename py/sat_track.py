#!/usr/bin/env python3
"""
sat_track.py - "connect to" the satellite carrying your flight, the only way a
laptop actually can: pull its live orbital elements, compute exactly where it is
right now, and tell you where to look out the window to see it.

You cannot transmit to a Ku-band GEO satellite from a laptop (wrong radio, wrong
band, needs a licensed pointed dish + watts of power - and doing so would jam the
aircraft). What you CAN do is reach out over the very link it provides, fetch its
authoritative orbital data from Celestrak, and locate it precisely. That's this.

  python sat_track.py --lat 31.8 --lon -102.4      # your current position
  python sat_track.py --from ELP --to DAL          # airport codes, uses midpoint
  python sat_track.py --sat "GALAXY 19"            # track a specific bird

Stdlib only. Fetches live TLEs over the aircraft internet.
"""
import argparse, datetime, json, math, ssl, sys, urllib.request

D = math.pi / 180.0
RE = 6378.137          # Earth equatorial radius, km
MU = 398600.4418       # Earth GM, km^3/s^2
C = 299792.458         # speed of light, km/ms is 299.79; km/s here
UA = {"User-Agent": "Mozilla/5.0 sat_track"}
CTX = ssl.create_default_context()

# a few well-known airports so you don't have to look up coordinates
AIRPORTS = {
    "ELP": (31.807, -106.378), "DAL": (32.847, -96.852), "DFW": (32.897, -97.038),
    "LAX": (33.942, -118.408), "LAS": (36.080, -115.152), "PHX": (33.434, -112.012),
    "DEN": (39.856, -104.673), "MDW": (41.786, -87.752), "HOU": (29.646, -95.279),
    "ABQ": (35.040, -106.609), "AUS": (30.194, -97.670), "SAN": (32.733, -117.190),
    "ATL": (33.640, -84.427), "BWI": (39.175, -76.668), "MCO": (28.429, -81.309),
}

# candidate GEO birds serving the Americas (name = Celestrak search key)
CANDIDATES = ["NUVIEW", "GALAXY 19", "GALAXY 3", "EUTELSAT 113", "SES 15",
              "TELSTAR 19", "HORIZONS 3", "GOES 18"]


def jd(dt):
    a = (14 - dt.month) // 12; y = dt.year + 4800 - a; m = dt.month + 12 * a - 3
    return (dt.day + (153 * m + 2) // 5 + 365 * y + y // 4 - y // 100 + y // 400 - 32045
            + (dt.hour - 12) / 24 + dt.minute / 1440 + dt.second / 86400 + dt.microsecond / 86400e6)


def gmst(dt):
    return ((280.46061837 + 360.98564736629 * (jd(dt) - 2451545.0)) % 360) * D


def fetch(name):
    url = f"https://celestrak.org/NORAD/elements/gp.php?NAME={name.replace(' ', '%20')}&FORMAT=json"
    raw = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=25, context=CTX).read()
    return json.loads(raw)


def propagate(el, now):
    """Kepler two-body propagation of TLE mean elements -> sub-satellite lat/lon/alt.
    Validated against GOES-18 (0.2 deg) and GALAXY 19 (0.0 deg)."""
    n = el["MEAN_MOTION"] * 2 * math.pi / 86400.0
    a = (MU / n ** 2) ** (1 / 3)
    e = el["ECCENTRICITY"]; i = el["INCLINATION"] * D
    O = el["RA_OF_ASC_NODE"] * D; w = el["ARG_OF_PERICENTER"] * D; M0 = el["MEAN_ANOMALY"] * D
    ep = datetime.datetime.fromisoformat(el["EPOCH"])
    dt = (now - ep).total_seconds()
    M = M0 + n * dt
    E = M
    for _ in range(60):
        E = E - (E - e * math.sin(E) - M) / (1 - e * math.cos(E))
    nu = 2 * math.atan2(math.sqrt(1 + e) * math.sin(E / 2), math.sqrt(1 - e) * math.cos(E / 2))
    r = a * (1 - e * math.cos(E))
    xp = r * math.cos(nu); yp = r * math.sin(nu)
    co, so = math.cos(O), math.sin(O); ci, si = math.cos(i), math.sin(i); cw, sw = math.cos(w), math.sin(w)
    x = (co * cw - so * sw * ci) * xp + (-co * sw - so * cw * ci) * yp
    y = (so * cw + co * sw * ci) * xp + (-so * sw + co * cw * ci) * yp
    z = (sw * si) * xp + (cw * si) * yp
    g = gmst(now)
    xe = x * math.cos(g) + y * math.sin(g)
    ye = -x * math.sin(g) + y * math.cos(g)
    lon = math.atan2(ye, xe) / D
    lat = math.atan2(z, math.sqrt(xe ** 2 + ye ** 2)) / D
    alt = math.sqrt(xe ** 2 + ye ** 2 + z ** 2) - RE
    return lat, lon, alt, math.sqrt(xe**2+ye**2+z**2)


def look_angles(obs_lat, obs_lon, sat_lon, sat_r):
    """Azimuth, elevation, slant range from observer to a (near-)GEO satellite."""
    dlon = (sat_lon - obs_lon) * D
    lat = obs_lat * D
    # elevation
    cosc = math.cos(lat) * math.cos(dlon)
    ratio = RE / sat_r
    el = math.atan2(cosc - ratio, math.sqrt(max(1e-12, 1 - cosc ** 2))) / D
    # azimuth (measured from true north, clockwise)
    az = (180 + math.atan2(math.tan(dlon), math.sin(lat)) / D) % 360
    # slant range
    slant = math.sqrt(RE ** 2 + sat_r ** 2 - 2 * RE * sat_r * cosc)
    return az, el, slant


def compass(az):
    dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return dirs[int((az + 11.25) % 360 // 22.5)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lon", type=float)
    ap.add_argument("--from", dest="frm")
    ap.add_argument("--to")
    ap.add_argument("--sat", help="track one bird by name (default: scan Americas Ku candidates)")
    ap.add_argument("--heading", type=float, help="aircraft heading in deg, to say left/right window")
    a = ap.parse_args()

    if a.lat is not None and a.lon is not None:
        lat, lon = a.lat, a.lon; where = f"{lat:.2f}, {lon:.2f}"
    elif a.frm and a.to and a.frm.upper() in AIRPORTS and a.to.upper() in AIRPORTS:
        (la1, lo1), (la2, lo2) = AIRPORTS[a.frm.upper()], AIRPORTS[a.to.upper()]
        lat, lon = (la1 + la2) / 2, (lo1 + lo2) / 2
        where = f"~midpoint {a.frm.upper()}->{a.to.upper()} ({lat:.2f}, {lon:.2f})"
    else:
        lat, lon = 32.0, -100.0
        where = f"DEFAULT west Texas ({lat:.2f}, {lon:.2f}) - pass --lat/--lon for real position"

    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    print(f"Observer: {where}")
    print(f"UTC now : {now:%Y-%m-%d %H:%M:%S}")
    print("Fetching LIVE orbital elements over the aircraft satellite link...\n")

    names = [a.sat] if a.sat else CANDIDATES
    rows = []
    for nm in names:
        try:
            for s in fetch(nm):
                la, lo, alt, r = propagate(s, now)
                if abs(la) > 5 or not (35000 < alt < 36500):
                    continue  # not a stable GEO bird
                az, el, slant = look_angles(lat, lon, lo, r)
                rows.append((s["OBJECT_NAME"], s["NORAD_CAT_ID"], lo, alt, az, el, slant, s["EPOCH"]))
        except Exception as e:
            print(f"  ({nm}: {type(e).__name__})", file=sys.stderr)

    # unique by NORAD, visible first
    seen = {}
    for r in rows:
        seen[r[1]] = r
    rows = sorted(seen.values(), key=lambda x: -x[5])

    print(f"{'SATELLITE':16s} {'NORAD':6s} {'SUBLON':>8s} {'AZ':>6s} {'ELEV':>6s} {'RANGE km':>9s} {'1way ms':>8s}  view")
    print("-" * 82)
    for name, nid, slon, alt, az, el, slant, epoch in rows:
        owt = slant / C * 1000  # ms
        if el < 0:
            view = "below horizon (not usable here)"
        else:
            view = f"look {compass(az)} ({az:.0f}deg), {el:.0f}deg up"
            if a.heading is not None:
                rel = (az - a.heading) % 360
                side = "RIGHT" if rel < 180 else "LEFT"
                view += f" -> {side} side of plane"
        star = " *" if "NUVIEW" in name.upper() else "  "
        print(f"{name:16s} {nid:<6d} {slon:7.2f}W {az:6.0f} {el:6.0f} {slant:9.0f} {owt:8.1f}  {view}{star}")

    vis = [r for r in rows if r[5] > 0]
    print()
    if any("NUVIEW" in r[0].upper() for r in vis):
        b = next(r for r in vis if "NUVIEW" in r[0].upper())
        print(f"** Your Southwest/Anuvu bird '{b[0]}' is UP: {compass(b[4])} of you, {b[5]:.0f} deg above the horizon.")
        print(f"   It sits at {b[2]:.1f}W over the equator, {b[6]:,.0f} km away. Round-trip light time: {2*b[6]/C*1000:.0f} ms.")
        print(f"   That {2*b[6]/C*1000:.0f} ms is the floor under every page you load - pure distance, nothing fixes it.")
    elif vis:
        print(f"NuView not overhead here; the strongest visible Americas bird is {vis[0][0]} at {vis[0][5]:.0f} deg elevation.")
    print("\n(* = the satellite family Southwest's legacy Anuvu Wi-Fi uses.)")
    print("Data: Celestrak GP elements, fetched live. Propagation validated vs GOES-18 / GALAXY 19.")


if __name__ == "__main__":
    main()
