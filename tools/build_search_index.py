#!/usr/bin/env python3
"""Builds the car page's offline search index for Armenia from OpenStreetMap.

    tools/.venv/bin/python tools/build_search_index.py [armenia-latest.osm.pbf]

Writes, under docs/car/data/:
  am-search.json     places, streets and named points of interest
  am-addresses.json  house addresses (loaded only when a query contains a number)
  am-chargers.json   EV charging stations with their connectors

Names are stored as they are in OSM (Armenian, English, Russian, alternative names); the car
page transliterates and folds them at load time, so "kaskad", "Каскад", "Կասկադ" and "cascade"
all meet. Coordinates are integers in 1e-5 degrees (~1 m).

Data © OpenStreetMap contributors, ODbL.
"""
import json
import math
import sys
import time
from collections import defaultdict
from pathlib import Path

import osmium

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tools/data/armenia-latest.osm.pbf"
OUT = ROOT / "docs/car/data"

PLACE_KIND = {"city": 0, "town": 0, "village": 1, "hamlet": 1, "suburb": 2, "neighbourhood": 2, "quarter": 2}
POI_KEYS = ("amenity", "shop", "tourism", "leisure", "office", "healthcare", "historic", "craft", "sport")
ROAD_TYPES = {"motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified",
              "living_street", "service", "pedestrian", "motorway_link", "trunk_link", "primary_link",
              "secondary_link", "tertiary_link"}
SKIP_AMENITY = {"parking", "bench", "waste_basket", "toilets", "drinking_water", "parking_space",
                "bicycle_parking", "vending_machine", "shelter", "recycling", "grit_bin", "clock"}


def names(tags):
    """Primary name plus the variants search should also match."""
    main = tags.get("name") or tags.get("name:hy") or tags.get("name:en")
    if not main:
        return None
    alts = []
    for k in ("name:en", "name:ru", "name:hy", "int_name", "alt_name", "old_name", "official_name", "short_name"):
        v = tags.get(k)
        if v and v != main and v not in alts:
            alts.append(v)
    return main, alts


def fix(lat, lon):
    return round(lat * 1e5), round(lon * 1e5)


class Collector(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.places, self.pois, self.chargers, self.addresses = [], [], [], []
        self.street_points = defaultdict(list)     # name -> [(lat, lon, alts, highway)]

    def point_of(self, obj):
        if isinstance(obj, osmium.osm.Node):
            return obj.location.lat, obj.location.lon
        pts = [(n.location.lat, n.location.lon) for n in obj.nodes if n.location.valid()]
        if not pts:
            return None
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)

    def handle(self, obj):
        tags = {t.k: t.v for t in obj.tags}
        if not tags:
            return
        if tags.get("amenity") == "charging_station":
            p = self.point_of(obj)
            if p:
                sockets = sorted({k.split(":")[1] for k in tags if k.startswith("socket:") and k.count(":") == 1})
                self.chargers.append({
                    "n": tags.get("name") or tags.get("operator") or "Charging station",
                    "o": tags.get("operator") or tags.get("brand") or "",
                    "s": sockets, "c": tags.get("capacity", ""),
                    "p": tags.get("charging_station:output") or tags.get("socket:type2_combo:output") or "",
                    "ll": fix(*p),
                })
        nm = names(tags)
        # Addresses (a house number plus a street), named or not.
        if "addr:housenumber" in tags and "addr:street" in tags:
            p = self.point_of(obj)
            if p:
                self.addresses.append((tags["addr:street"], tags["addr:housenumber"], tags.get("addr:city", ""), *fix(*p)))
        if not nm:
            return
        main, alts = nm
        place = tags.get("place")
        if place in PLACE_KIND and isinstance(obj, osmium.osm.Node):
            self.places.append((PLACE_KIND[place], main, alts, *fix(obj.location.lat, obj.location.lon),
                                int(tags.get("population", "0") or 0) if tags.get("population", "0").isdigit() else 0))
            return
        hw = tags.get("highway")
        if hw in ROAD_TYPES and isinstance(obj, osmium.osm.Way):
            nodes = [n for n in obj.nodes if n.location.valid()]
            if nodes:
                mid = nodes[len(nodes) // 2].location
                self.street_points[main].append((mid.lat, mid.lon, alts))
            return
        cat = next((f"{k}={tags[k]}" for k in POI_KEYS if k in tags), None)
        if cat and not (cat.startswith("amenity=") and tags["amenity"] in SKIP_AMENITY):
            p = self.point_of(obj)
            if p:
                self.pois.append((cat.split("=", 1)[1], main, alts, *fix(*p)))

    def node(self, n):
        self.handle(n)

    def way(self, w):
        self.handle(w)


def km(a, b):
    """Rough distance in km between two fixed-point coordinates."""
    dlat = (a[0] - b[0]) / 1e5 * 111.32
    dlon = (a[1] - b[1]) / 1e5 * 111.32 * math.cos(math.radians(a[0] / 1e5))
    return math.hypot(dlat, dlon)


def main():
    t0 = time.time()
    c = Collector()
    c.apply_file(str(SRC), locations=True)
    print(f"parsed in {time.time() - t0:.0f}s: {len(c.places)} places, {len(c.street_points)} street names, "
          f"{len(c.pois)} POIs, {len(c.addresses)} addresses, {len(c.chargers)} chargers")

    # Nearest town/village for context ("Kentron, Yerevan"), via a coarse grid.
    towns = [p for p in c.places if p[0] in (0, 1)]
    grid = defaultdict(list)
    for i, p in enumerate(towns):
        grid[(p[3] // 20000, p[4] // 20000)].append(i)

    def nearest_town(ll):
        gx, gy = ll[0] // 20000, ll[1] // 20000
        best, bd = -1, 1e9
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for i in grid.get((gx + dx, gy + dy), ()):
                    d = km(ll, (towns[i][3], towns[i][4])) * (0.4 if towns[i][0] == 0 else 1)  # towns pull harder
                    if d < bd:
                        best, bd = i, d
        return best

    # Streets: one entry per street per area (segments of the same name within 3 km are joined).
    streets = []
    for name, pts in c.street_points.items():
        clusters = []
        for lat, lon, alts in pts:
            ll = fix(lat, lon)
            for cl in clusters:
                if km(ll, cl["ll"]) < 3:
                    cl["n"] += 1
                    cl["alts"].update(alts)
                    break
            else:
                clusters.append({"ll": ll, "n": 1, "alts": set(alts)})
        for cl in clusters:
            streets.append((name, sorted(cl["alts"]), *cl["ll"]))

    entries = []   # [kind, name, alts, lat, lon, town index, detail]
    # kind: 0 city/town, 1 village, 2 district, 3 point of interest, 4 street
    town_index = {id(t): i for i, t in enumerate(towns)}
    for p in c.places:
        entries.append([p[0], p[1], p[2], p[3], p[4], -1 if p[0] != 2 else nearest_town((p[3], p[4])), p[5]])
    for s in streets:
        entries.append([4, s[0], s[1], s[2], s[3], nearest_town((s[2], s[3])), ""])
    for p in c.pois:
        entries.append([3, p[1], p[2], p[3], p[4], nearest_town((p[3], p[4])), p[0]])

    OUT.mkdir(parents=True, exist_ok=True)
    search = {
        "v": 1, "built": time.strftime("%Y-%m-%d"), "source": "© OpenStreetMap contributors (ODbL)",
        "towns": [[t[1], t[2][:3]] for t in towns],
        "e": entries,
    }
    (OUT / "am-search.json").write_text(json.dumps(search, ensure_ascii=False, separators=(",", ":")))

    # Addresses grouped by street name to keep the file small: {street: [[number, lat, lon], ...]}.
    by_street = defaultdict(list)
    for street, hn, city, lat, lon in c.addresses:
        by_street[street].append([hn, lat, lon])
    (OUT / "am-addresses.json").write_text(json.dumps(
        {"v": 1, "streets": by_street}, ensure_ascii=False, separators=(",", ":")))

    (OUT / "am-chargers.json").write_text(json.dumps(
        {"v": 1, "built": time.strftime("%Y-%m-%d"), "chargers": c.chargers}, ensure_ascii=False, separators=(",", ":")))

    for f in ("am-search.json", "am-addresses.json", "am-chargers.json"):
        print(f, f"{(OUT / f).stat().st_size / 1e6:.1f} MB")
    print(f"{len(entries)} search entries ({len(streets)} streets) in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
