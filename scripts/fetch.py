#!/usr/bin/env python3
"""Download curb ramp data for the Dayton Ave N study area into data/raw/.

Sources:
  1. SDOT "Curb Ramps (Active)" and "Curb Ramp Work Orders" ArcGIS feature
     services (Seattle GeoData)
  2. Project Sidewalk Seattle v3 rawLabels API
  3. OpenStreetMap (Overpass API, falling back to the OSM editing API in tiles)

Standard library only. Run from the repo root:  python3 scripts/fetch.py
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"

# Study area: Dayton Ave N, N 60th St to N 85th St, padded a little so corner
# points just outside the nominal box are still captured.
SOUTH, WEST, NORTH, EAST = 47.668, -122.362, 47.693, -122.348

# Narrow corridor around Dayton Ave N (lon ~ -122.3527) for OSM, which is dense
# with building nodes and would exceed the OSM API's 50k-node limit otherwise.
OSM_WEST, OSM_EAST = -122.3550, -122.3505

CITY_URL = (
    "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/"
    "Curb_Ramps_(Active)/FeatureServer/0/query"
)
CITY_WO_URL = (
    "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/"
    "Curb_Ramp_Work_Orders/FeatureServer/0/query"
)
PS_URL = "https://sidewalk-sea.cs.washington.edu/v3/api/rawLabels"
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
OSM_API_URL = "https://api.openstreetmap.org/api/0.6/map.json"

UA = "trebuche-curb-ramp-survey/0.1 (neighborhood accessibility project)"


def get(url, params=None, data=None, timeout=120):
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def save(name, obj, source_url):
    path = RAW / name
    obj = {
        "_fetched": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "_source": source_url,
        **obj,
    }
    path.write_text(json.dumps(obj))
    print(f"  wrote {path.relative_to(ROOT)}")


def fetch_city():
    print("SDOT curb ramps ...")
    params = {
        "geometry": f"{WEST},{SOUTH},{EAST},{NORTH}",
        "geometryType": "esriGeometryEnvelope",
        "inSR": 4326,
        "outSR": 4326,
        "spatialRel": "esriSpatialRelIntersects",
        "where": "1=1",
        "outFields": "*",
        "resultRecordCount": 2000,
        "f": "geojson",
    }
    d = json.loads(get(CITY_URL, params))
    if d.get("properties", {}).get("exceededTransferLimit"):
        sys.exit("City query exceeded transfer limit; add paging.")
    print(f"  {len(d['features'])} ramp records")
    save("city_curb_ramps.geojson", d, CITY_URL)


def fetch_city_work_orders():
    print("SDOT curb ramp work orders ...")
    # WORKDESC is deliberately excluded: it can contain residents' names and
    # contact details copied from service requests.
    fields = [
        "UNITID", "INT_UNITDESC", "CURRENT_STATUS", "CANCELLEDFLAG", "CLOSEDDT",
        "ESTCOMPDT", "GROUPPROJNAME", "PROBLEMDESC", "SOURCE", "WO_ADDDTTM",
    ]
    params = {
        "geometry": f"{WEST},{SOUTH},{EAST},{NORTH}",
        "geometryType": "esriGeometryEnvelope",
        "inSR": 4326,
        "outSR": 4326,
        "spatialRel": "esriSpatialRelIntersects",
        "where": "1=1",
        "outFields": ",".join(fields),
        "f": "geojson",
    }
    d = json.loads(get(CITY_WO_URL, params))
    print(f"  {len(d['features'])} work orders")
    save("city_work_orders.geojson", d, CITY_WO_URL)


def fetch_project_sidewalk():
    print("Project Sidewalk labels ...")
    params = {"bbox": f"{WEST},{SOUTH},{EAST},{NORTH}"}
    d = json.loads(get(PS_URL, params, timeout=300))
    print(f"  {len(d['features'])} labels")
    save("project_sidewalk_labels.geojson", d, PS_URL)


def fetch_osm():
    print("OpenStreetMap ...")
    bbox = f"{SOUTH},{OSM_WEST},{NORTH},{OSM_EAST}"
    q = f"""[out:json][timeout:90];
(
  node({bbox})[kerb];
  node({bbox})[highway=crossing];
  way({bbox})[highway];
);
out body; >; out skel qt;"""
    for url in OVERPASS_URLS:
        try:
            d = json.loads(get(url, data={"data": q}, timeout=150))
            print(f"  {len(d['elements'])} elements via {url}")
            save("osm.json", {"elements": d["elements"]}, url)
            return
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"  {url} failed: {e}")

    # Fallback: OSM editing API, tiled north-south along the corridor.
    print("  falling back to OSM API tiles")
    elements = {}
    lat = SOUTH
    step = 0.005
    while lat < NORTH:
        top = min(lat + step, NORTH)
        params = {"bbox": f"{OSM_WEST},{lat},{OSM_EAST},{top}"}
        d = json.loads(get(OSM_API_URL, params, timeout=180))
        for e in d["elements"]:
            elements[(e["type"], e["id"])] = e
        print(f"    tile {lat:.3f}-{top:.3f}: {len(d['elements'])} elements")
        lat = top
        time.sleep(1)  # be polite to the OSM API
    # Ways are clipped at tile edges; that's fine for corner-scale analysis.
    save("osm.json", {"elements": list(elements.values())}, OSM_API_URL)


if __name__ == "__main__":
    RAW.mkdir(parents=True, exist_ok=True)
    which = set(sys.argv[1:]) or {"city", "ps", "osm"}
    if "city" in which:
        fetch_city()
        fetch_city_work_orders()
    if "ps" in which:
        fetch_project_sidewalk()
    if "osm" in which:
        fetch_osm()
