#!/usr/bin/env python3
"""Build a per-corner curb ramp inventory for Dayton Ave N (N 60th - N 85th St).

Reads data/raw/* (from fetch.py) and data/requests.csv, writes:
  output/corners.csv      one row per intersection corner
  output/corners.geojson  same, as points
  output/map.html         Leaflet map (data embedded; open directly in a browser)

Each corner can need up to two ramps: one for crossing Dayton ("main") and one
for crossing the cross street ("cross"). A corner with only one of the two is
reported as "partial" -- for a stroller that is still a dead end.

Standard library only. Run from the repo root:  python3 scripts/build.py
"""
import csv
import json
import math
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
OUT = ROOT / "output"

MAIN_STREET = "Dayton Avenue North"
FIRST_ST, LAST_ST = 60, 85

MATCH_RADIUS_M = 30   # evidence farther than this from an intersection is ignored
CORNER_OFFSET_M = 9   # where to draw a corner marker, diagonally from the center
LEG_PROBE_M = 25      # a street node this far out along an axis means a leg exists
JOG_THRESHOLD_M = 10  # N and S approaches of Dayton offset by more than this = jog

M_PER_DEG_LAT = 111_320
M_PER_DEG_LON = 111_320 * math.cos(math.radians(47.68))

OPPOSITE = {"N": "S", "S": "N", "E": "W", "W": "E"}


def to_xy(lat, lon, lat0, lon0):
    return (lon - lon0) * M_PER_DEG_LON, (lat - lat0) * M_PER_DEG_LAT


def from_xy(x, y, lat0, lon0):
    return lat0 + y / M_PER_DEG_LAT, lon0 + x / M_PER_DEG_LON


def ordinal(n):
    suf = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suf}"


def ms_to_date(ms):
    if not ms:
        return ""
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).date().isoformat()


def load(name):
    return json.loads((RAW / name).read_text())


# --------------------------------------------------------------------------
# Intersections (from OSM street geometry)
# --------------------------------------------------------------------------

ROAD_TYPES = {"residential", "tertiary", "secondary", "primary", "unclassified"}


def load_osm():
    els = load("osm.json")["elements"]
    nodes = {e["id"]: e for e in els if e["type"] == "node"}
    ways = [e for e in els if e["type"] == "way" and "highway" in e.get("tags", {})]
    return nodes, ways


def find_intersections(nodes, ways):
    """Intersections along MAIN_STREET, found geometrically.

    Many Dayton intersections have neighborhood traffic circles where the named
    ways stop short of the center, so shared nodes can't be relied on. Dayton
    also jogs at N 64th and N 65th; each jog becomes two T-intersections.
    """
    main_segs = []
    for w in ways:
        if w["tags"].get("name") == MAIN_STREET:
            pts = [(nodes[n]["lat"], nodes[n]["lon"]) for n in w["nodes"] if n in nodes]
            main_segs += list(zip(pts, pts[1:]))
    main_lon = sorted(a[1] for a, _ in main_segs)[len(main_segs) // 2]

    cross_pts = defaultdict(list)
    for w in ways:
        m = re.fullmatch(r"North (\d+)(?:st|nd|rd|th) Street", w["tags"].get("name", ""))
        if m and w["tags"]["highway"] in ROAD_TYPES and FIRST_ST <= int(m.group(1)) <= LAST_ST:
            cross_pts[int(m.group(1))] += [
                (nodes[n]["lat"], nodes[n]["lon"]) for n in w["nodes"] if n in nodes
            ]

    result = []
    for num in sorted(cross_pts):
        pts = cross_pts[num]
        near = [p for p in pts if abs(p[1] - main_lon) * M_PER_DEG_LON < 80]
        if not near:
            continue
        lat = sorted(p[0] for p in near)[len(near) // 2]

        def approach(sign):
            """Longitude of Dayton 15 m south (-1) or north (+1) of this street.

            15 m clears a traffic circle but stays short of the next block.
            """
            target = lat + sign * 15 / M_PER_DEG_LAT
            for (alat, alon), (blat, blon) in main_segs:
                if min(alat, blat) <= target <= max(alat, blat) and alat != blat:
                    t = (target - alat) / (blat - alat)
                    return alon + t * (blon - alon)
            return None

        s_lon, n_lon = approach(-1), approach(+1)
        if s_lon is not None and n_lon is not None and \
                abs(s_lon - n_lon) * M_PER_DEG_LON > JOG_THRESHOLD_M:
            (wl, wd), (el, ed) = sorted([(s_lon, "S"), (n_lon, "N")])
            centers = [(wl, "W", {wd}), (el, "E", {ed})]
        else:
            lons = [x for x in (s_lon, n_lon) if x is not None]
            centers = [(sum(lons) / len(lons), "",
                        {d for d, x in (("S", s_lon), ("N", n_lon)) if x is not None})]

        for lon, suffix, legs in centers:
            legs = set(legs)
            for p in pts:
                x, y = to_xy(p[0], p[1], lat, lon)
                if abs(y) < 10 and abs(x) > LEG_PROBE_M:
                    legs.add("E" if x > 0 else "W")
            name = f"N {ordinal(num)} St" + (f" ({'west' if suffix == 'W' else 'east'} side of jog)" if suffix else "")
            result.append({
                "id": f"{num}{suffix}", "cross_street": name,
                "lat": lat, "lon": lon, "legs": "".join(d for d in "NESW" if d in legs),
            })
    return result


def corners_for(ix):
    """Four corners; for each, which crossings start there.

    Corner (ns, ew) e.g. ('N','E'):
      main  crossing: across Dayton's ns leg toward the opposite ew side
      cross crossing: across the cross street's ew leg toward the opposite ns side
    """
    legs = set(ix["legs"])
    out = []
    for q in ("NE", "NW", "SE", "SW"):
        ns, ew = q
        needs = []
        if ns in legs:
            needs.append("main")
        if ew in legs:
            needs.append("cross")
        x = CORNER_OFFSET_M * (1 if ew == "E" else -1)
        y = CORNER_OFFSET_M * (1 if ns == "N" else -1)
        lat, lon = from_xy(x, y, ix["lat"], ix["lon"])
        out.append({
            "corner_id": f"dayton-{ix['id']}-{q}",
            "intersection_id": ix["id"],
            "cross_street": ix["cross_street"],
            "corner": q,
            "corner_type": "corner" if len(needs) == 2 else "T-intersection landing",
            "needs": needs,
            "lat": round(lat, 6),
            "lon": round(lon, 6),
        })
    return out


def assign(points, intersections):
    """Group (lat, lon, payload) by (intersection_id, quadrant)."""
    by_corner = defaultdict(list)
    for lat, lon, payload in points:
        best, best_d = None, MATCH_RADIUS_M
        for ix in intersections:
            x, y = to_xy(lat, lon, ix["lat"], ix["lon"])
            if math.hypot(x, y) < best_d:
                best, best_d, bx, by = ix, math.hypot(x, y), x, y
        if best is not None:
            q = ("N" if by >= 0 else "S") + ("E" if bx >= 0 else "W")
            by_corner[(best["id"], q)].append(payload)
    return by_corner


def coverage_verdict(needs, covered, any_ramp, any_missing, gaps_mean_missing=False):
    """present / partial / missing / unknown from per-crossing coverage.

    gaps_mean_missing: whether a needed crossing with no evidence at all should
    count as lacking a ramp. True for the SDOT inventory (surveyed corners list
    every ramp); False for OSM, where an unmapped kerb just means unmapped.
    """
    if needs and all(n in covered for n in needs):
        return "present"
    if any_ramp and (any_missing or (covered and gaps_mean_missing)):
        return "partial"
    if any_ramp:
        # Ramp(s) present but direction unknown: count as present.
        return "present"
    if any_missing:
        return "missing"
    return "unknown"


# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

def city_evidence(intersections, corners):
    feats = load("city_curb_ramps.geojson")["features"]
    wos = load("city_work_orders.geojson")["features"]
    open_wo = defaultdict(list)
    for f in wos:
        a = f["properties"]
        if a["PROBLEMDESC"] == "Planned Construction" and not a["CLOSEDDT"] \
                and a["CANCELLEDFLAG"] != "Y":
            open_wo[a["UNITID"]].append(a["GROUPPROJNAME"].strip())

    pts = [(f["geometry"]["coordinates"][1], f["geometry"]["coordinates"][0], f["properties"])
           for f in feats]
    needs = {(c["intersection_id"], c["corner"]): c["needs"] for c in corners}
    out = {}
    for key, recs in assign(pts, intersections).items():
        ns, ew = key[1]
        built = [r for r in recs if r["CATEGORY"].strip() in ("SINGLE", "SHARED")]
        noramp = [r for r in recs if r["CATEGORY"].strip() == "NORAMP"]
        stubs = [r for r in recs if not r["CATEGORY"].strip()]
        covered = set()
        for r in built:
            d = r["DIRECTION"].strip()
            if r["CATEGORY"].strip() == "SHARED" or d == OPPOSITE[ns] + OPPOSITE[ew]:
                covered |= {"main", "cross"}
            elif d == OPPOSITE[ew]:
                covered.add("main")
            elif d == OPPOSITE[ns]:
                covered.add("cross")
        v = coverage_verdict(needs.get(key, []), covered, bool(built), bool(noramp),
                             gaps_mean_missing=True)
        installs = sorted(ms_to_date(r["INSTALL_DATE"]) for r in built if r["INSTALL_DATE"])
        observed = sorted(
            ms_to_date(r[k]) for r in recs
            for k in ("INSTALL_DATE", "VERIFICATION_DATE", "ASSESSMENT_DATE") if r[k]
        )
        planned = sorted({p for r in recs for p in open_wo.get(r["UNITID"], [])} - {""})
        out[key] = {
            "city": v if (built or noramp) else "unassessed",
            "city_covers": "+".join(sorted(covered)),
            "city_ramp_count": len(built),
            "city_noramp_count": len(noramp),
            "city_placeholder_count": len(stubs),
            "city_install_date": installs[-1] if installs else "",
            "city_last_observed": observed[-1] if observed else "",
            "city_condition": "/".join(sorted({r["CONDITION"].strip() for r in built} - {""})),
            "city_ada": "/".join(sorted({r["ADA_COMPLIANT"].strip() for r in recs} - {""})),
            "city_planned_project": "; ".join(planned),
            "city_ids": " ".join(sorted(r["UNITID"] for r in recs)),
        }
    return out


def ps_evidence(intersections):
    feats = load("project_sidewalk_labels.geojson")["features"]
    pts = []
    for f in feats:
        p = f["properties"]
        if p["label_type"] in ("CurbRamp", "NoCurbRamp") and p.get("correct") is not False:
            pts.append((f["geometry"]["coordinates"][1], f["geometry"]["coordinates"][0], p))
    out = {}
    for key, labels in assign(pts, intersections).items():
        ramps = [p for p in labels if p["label_type"] == "CurbRamp"]
        noramp = [p for p in labels if p["label_type"] == "NoCurbRamp"]
        dates = sorted(p["image_capture_date"] for p in labels if p.get("image_capture_date"))
        sev = [p["severity"] for p in ramps if p.get("severity")]
        out[key] = {
            # Project Sidewalk labels carry no reliable crossing direction, so a
            # mix of CurbRamp and NoCurbRamp at one corner is read as partial.
            "ps": coverage_verdict([], set(), bool(ramps), bool(noramp)),
            "ps_ramp_labels": len(ramps),
            "ps_noramp_labels": len(noramp),
            "ps_validated": sum(1 for p in labels if p.get("correct") is True),
            "ps_ramp_max_severity": max(sev) if sev else "",
            "ps_ramp_issues": "; ".join(sorted({t for p in ramps for t in (p.get("tags") or [])})),
            "ps_image_date": dates[-1] if dates else "",
            "ps_label_ids": " ".join(str(p["label_id"]) for p in labels),
        }
    return out


OSM_PRESENT = {"lowered", "flush", "no", "none"}
OSM_MISSING = {"raised", "regular", "rolled", "yes"}


def osm_evidence(nodes, ways, intersections, corners):
    """kerb=* nodes; crossing direction comes from the crossing way's bearing."""
    crossing_ways = defaultdict(list)
    for w in ways:
        t = w["tags"]
        if t.get("footway") == "crossing" or (t["highway"] == "footway" and "crossing" in t):
            for n in w["nodes"]:
                crossing_ways[n].append(w)

    def crossing_kind(n):
        for w in crossing_ways.get(n["id"], []):
            a, b = nodes.get(w["nodes"][0]), nodes.get(w["nodes"][-1])
            if a and b:
                x, y = to_xy(b["lat"], b["lon"], a["lat"], a["lon"])
                # Dayton runs N-S, so an E-W crossing crosses Dayton.
                return "main" if abs(x) > abs(y) else "cross"
        return None

    pts = [(n["lat"], n["lon"], n) for n in nodes.values() if n.get("tags", {}).get("kerb")]
    needs = {(c["intersection_id"], c["corner"]): c["needs"] for c in corners}
    out = {}
    for key, ns in assign(pts, intersections).items():
        covered, missing_dirs = set(), set()
        any_ramp = any_missing = False
        detail = []
        for n in ns:
            k = n["tags"]["kerb"]
            kind = crossing_kind(n)
            detail.append(f"{kind or '?'}:{k}")
            if k in OSM_PRESENT:
                any_ramp = True
                if kind:
                    covered.add(kind)
            elif k in OSM_MISSING:
                any_missing = True
                if kind:
                    missing_dirs.add(kind)
        stamps = sorted(n["timestamp"][:10] for n in ns if n.get("timestamp"))
        v = coverage_verdict(needs.get(key, []), covered, any_ramp, any_missing)
        if v == "present" and not set(needs.get(key, [])) <= covered:
            # Lowered kerb(s) mapped, but not for every crossing at this
            # corner: consistent with either present or partial, so no vote.
            v = "ramp (partly mapped)"
        out[key] = {
            "osm": v,
            "osm_kerbs": " ".join(sorted(detail)),
            "osm_last_edit": stamps[-1] if stamps else "",
            "osm_node_ids": " ".join(str(n["id"]) for n in ns),
        }
    return out


# --------------------------------------------------------------------------
# Combine
# --------------------------------------------------------------------------

def combine(row):
    """Overall status, whether sources disagree, and an explanatory note."""
    votes = {s: row[s] for s in ("city", "ps", "osm") if row[s] in ("present", "partial", "missing")}
    if not votes:
        return "unknown", False, ""
    distinct = set(votes.values())
    if len(distinct) == 1:
        return distinct.pop(), False, ""

    # Disagreement. Observation dates: if the city verified or installed the
    # ramp after the other sources looked, trust the city.
    city_seen = row.get("city_last_observed", "")
    if "city" in votes and city_seen:
        seen = {"ps": row.get("ps_image_date", ""), "osm": row.get("osm_last_edit", "")}
        others = [s for s in votes if s != "city" and votes[s] != votes["city"]]
        stale = [s for s in others if seen[s] and seen[s] < city_seen[:len(seen[s])]]
        if others and stale == others:
            return votes["city"], True, f"city record ({city_seen}) is newer than {'/'.join(stale)}"

    # Everyone agrees a ramp is lacking somewhere: that's a need either way.
    if distinct <= {"partial", "missing"}:
        return "partial", True, "sources differ on whether one or both crossings lack a ramp"
    return "conflict", True, ""


def load_requests():
    path = ROOT / "data" / "requests.csv"
    if not path.exists():
        return {}
    with path.open() as f:
        return {r["corner_id"]: r for r in csv.DictReader(f) if r.get("corner_id")}


FIELDS = [
    "corner_id", "intersection_id", "cross_street", "corner", "corner_type", "lat", "lon",
    "overall", "sources_disagree", "note",
    "city", "city_install_date", "city_last_observed", "city_covers",
    "city_ramp_count", "city_noramp_count", "city_placeholder_count",
    "city_condition", "city_ada", "city_planned_project", "city_ids",
    "ps", "ps_ramp_labels", "ps_noramp_labels", "ps_validated",
    "ps_ramp_max_severity", "ps_ramp_issues", "ps_image_date", "ps_label_ids",
    "osm", "osm_kerbs", "osm_last_edit", "osm_node_ids",
    "request_filed", "request_date", "request_ref", "request_status",
]


def main():
    nodes, ways = load_osm()
    intersections = find_intersections(nodes, ways)
    corners = [c for ix in intersections for c in corners_for(ix)]
    city = city_evidence(intersections, corners)
    ps = ps_evidence(intersections)
    osm = osm_evidence(nodes, ways, intersections, corners)
    requests = load_requests()

    rows = []
    for c in corners:
        key = (c["intersection_id"], c["corner"])
        row = {f: "" for f in FIELDS}
        row.update({k: v for k, v in c.items() if k != "needs"})
        row.update(city="no record", ps="unknown", osm="unknown")
        row.update(city.get(key, {}))
        row.update(ps.get(key, {}))
        row.update(osm.get(key, {}))
        overall, disagree, note = combine(row)
        row.update(overall=overall, sources_disagree="yes" if disagree else "", note=note)
        if row["city_planned_project"]:
            row["note"] = "; ".join(x for x in (row["note"], f"SDOT planned: {row['city_planned_project']}") if x)
        req = requests.get(c["corner_id"])
        if req:
            row.update(request_filed="yes", request_date=req.get("date_filed", ""),
                       request_ref=req.get("sdot_reference", ""), request_status=req.get("status", ""))
        rows.append(row)

    OUT.mkdir(exist_ok=True)
    with (OUT / "corners.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)

    fetched = {k: load(fn).get("_fetched", "") for k, fn in (
        ("city", "city_curb_ramps.geojson"), ("ps", "project_sidewalk_labels.geojson"), ("osm", "osm.json"))}
    gj = {
        "type": "FeatureCollection",
        "metadata": {"fetched": fetched},
        "features": [
            {"type": "Feature",
             "geometry": {"type": "Point", "coordinates": [r["lon"], r["lat"]]},
             "properties": {k: v for k, v in r.items() if k not in ("lat", "lon")}}
            for r in rows
        ],
    }
    (OUT / "corners.geojson").write_text(json.dumps(gj, indent=1) + "\n")
    template = (ROOT / "scripts" / "map_template.html").read_text()
    (OUT / "map.html").write_text(template.replace("/*__DATA__*/null", json.dumps(gj)))

    print(f"{len(intersections)} intersections: {' '.join(i['id'] for i in intersections)}")
    print(f"{len(rows)} corners")
    print("overall:", dict(Counter(r["overall"] for r in rows)))
    print("sources disagree:", sum(1 for r in rows if r["sources_disagree"]))
    for s in ("city", "ps", "osm"):
        print(f"  {s}:", dict(Counter(r[s] for r in rows)))


if __name__ == "__main__":
    main()
