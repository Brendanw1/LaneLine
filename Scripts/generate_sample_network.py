#!/usr/bin/env python3
"""Generate LaneLine's bundled SF sample network (Resources/SFSampleNetwork.json).

Nodes are real SF intersections with plausible elevations; edge lengths are
haversine-computed at build time by the app, so the JSON stores topology and
attributes only. This script validates connectivity and grade sanity before
writing.
"""
import json
import math
import sys
from collections import defaultdict, deque

# id: (lat, lon, elevation_m)
NODES = {
    # Valencia St corridor (Class IV separated bikeway)
    "v24":            (37.75215, -122.42060, 19),
    "v20":            (37.75880, -122.42130, 14),
    "v16":            (37.76490, -122.42190, 12),
    "vmkt":           (37.77100, -122.42260, 16),
    # Mission St (arterial, no facility)
    "m24":            (37.75230, -122.41860, 18),
    "m20":            (37.75890, -122.41930, 13),
    "m16":            (37.76500, -122.41990, 11),
    "m13":            (37.77000, -122.42030, 12),
    # Market St
    "mkt_church":     (37.76730, -122.42920, 30),
    "mkt_oct":        (37.77130, -122.42400, 17),
    "mkt_vn":         (37.77500, -122.41940, 20),
    "mkt_7":          (37.77970, -122.41270, 11),
    "mkt_4":          (37.78560, -122.40480, 8),
    "mkt_beale":      (37.79240, -122.39660, 4),
    "ferry":          (37.79550, -122.39370, 3),
    # Folsom / SoMa / Embarcadero
    "fol_11":         (37.77400, -122.41540, 12),
    "fol_8":          (37.77760, -122.41080, 10),
    "fol_5":          (37.78150, -122.40360, 8),
    "fol_2":          (37.78560, -122.39480, 6),
    "emb_fol":        (37.79020, -122.38970, 3),
    # The Wiggle + Duboce bikeway
    "dub_ch":         (37.76930, -122.42900, 26),
    "dub_st":         (37.76940, -122.43320, 22),
    "stei_wal":       (37.77120, -122.43340, 24),
    "wal_pier":       (37.77130, -122.43560, 27),
    "pier_haight":    (37.77180, -122.43570, 30),
    "haight_scott":   (37.77170, -122.43660, 32),
    "scott_fell":     (37.77520, -122.43700, 33),
    # Fell / Oak couplet + Panhandle
    "div_fell":       (37.77430, -122.43800, 35),
    "fell_baker":     (37.77440, -122.44120, 38),
    "oak_scott":      (37.77430, -122.43640, 32),
    "oak_div":        (37.77340, -122.43770, 37),
    "oak_baker":      (37.77350, -122.44190, 40),
    "pan_masonic":    (37.77280, -122.44660, 44),
    "stanyan":        (37.77150, -122.45330, 48),
    "ggp":            (37.77250, -122.46030, 55),
    # Haight St (hillier, higher-stress alternative)
    "haight_fill":    (37.77210, -122.43060, 30),
    "haight_div":     (37.77120, -122.43870, 42),
    "haight_masonic": (37.77020, -122.44540, 58),
    "haight_stanyan": (37.76900, -122.45300, 76),
    # Castro / Duboce hill (steep shortcut the router should weigh)
    "17_val":         (37.76340, -122.42180, 13),
    "17_church":      (37.76310, -122.42870, 22),
    "17_castro":      (37.76260, -122.43520, 44),
    "castro_14":      (37.76750, -122.43530, 58),
    "dub_castro":     (37.76930, -122.43510, 38),
}

# (from, to, street, facility, protection, road_class, surface, one_way, confidence)
E = lambda f, t, street, fac, prot, rc, surf, ow=False, conf=0.95: dict(
    fromNode=f, toNode=t, streetName=street, facilityType=fac,
    protectionLevel=prot, roadClass=rc, surfaceType=surf, oneWay=ow,
    confidence=conf)

EDGES = [
    # Valencia: Class IV separated bikeway
    E("v24", "v20", "Valencia St", "protectedBikeLane", "fullyProtected", "secondary", "asphalt"),
    E("v20", "v16", "Valencia St", "protectedBikeLane", "fullyProtected", "secondary", "asphalt"),
    E("v16", "vmkt", "Valencia St", "protectedBikeLane", "fullyProtected", "secondary", "asphalt"),
    # Mission: arterial, no facility
    E("m24", "m20", "Mission St", "mixedTraffic", "none", "arterial", "asphalt", conf=0.75),
    E("m20", "m16", "Mission St", "mixedTraffic", "none", "arterial", "asphalt", conf=0.75),
    E("m16", "m13", "Mission St", "mixedTraffic", "none", "arterial", "asphalt", conf=0.75),
    # Cross streets in the Mission
    E("v24", "m24", "24th St", "sharedLane", "sharrows", "tertiary", "asphalt", conf=0.8),
    E("v16", "m16", "16th St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.7),
    # Market St: painted midtown, protected downtown
    E("17_castro", "mkt_church", "Market St", "bikeLane", "standard", "primary", "asphalt"),
    E("mkt_church", "mkt_oct", "Market St", "bikeLane", "standard", "primary", "asphalt"),
    E("vmkt", "mkt_oct", "Market St", "bikeLane", "standard", "primary", "asphalt"),
    E("mkt_oct", "mkt_vn", "Market St", "bikeLane", "buffered", "primary", "asphalt"),
    E("mkt_vn", "mkt_7", "Market St", "protectedBikeLane", "fullyProtected", "primary", "asphalt"),
    E("mkt_7", "mkt_4", "Market St", "protectedBikeLane", "fullyProtected", "primary", "asphalt"),
    E("mkt_4", "mkt_beale", "Market St", "protectedBikeLane", "fullyProtected", "primary", "asphalt"),
    E("mkt_beale", "ferry", "Market St", "protectedBikeLane", "fullyProtected", "primary", "asphalt"),
    # SoMa / Folsom corridor + Embarcadero promenade
    E("m13", "fol_11", "11th St", "bikeLane", "standard", "secondary", "asphalt", conf=0.85),
    E("fol_11", "fol_8", "Folsom St", "bikeLane", "buffered", "secondary", "asphalt"),
    E("fol_8", "fol_5", "Folsom St", "bikeLane", "buffered", "secondary", "asphalt"),
    E("fol_5", "fol_2", "Folsom St", "bikeLane", "buffered", "secondary", "asphalt"),
    E("fol_2", "emb_fol", "Folsom St", "protectedBikeLane", "fullyProtected", "secondary", "asphalt"),
    E("emb_fol", "ferry", "The Embarcadero", "offStreetPath", "fullyProtected", "residential", "concrete"),
    E("fol_5", "mkt_4", "5th St", "bikeLane", "standard", "secondary", "asphalt", conf=0.85),
    E("vmkt", "m13", "Duboce Ave", "mixedTraffic", "none", "primary", "asphalt", conf=0.7),
    # Church St + Duboce bikeway into the Wiggle
    E("mkt_church", "dub_ch", "Church St", "bikeRoute", "none", "tertiary", "asphalt", conf=0.8),
    E("17_church", "mkt_church", "Church St", "bikeRoute", "none", "tertiary", "asphalt", conf=0.8),
    E("dub_ch", "dub_st", "Duboce Ave Bikeway", "offStreetPath", "fullyProtected", "residential", "asphalt"),
    # The Wiggle: calm residential zigzag
    E("dub_st", "stei_wal", "Steiner St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("stei_wal", "wal_pier", "Waller St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("wal_pier", "pier_haight", "Pierce St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("pier_haight", "haight_scott", "Haight St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("haight_scott", "scott_fell", "Scott St", "sharedLane", "sharrows", "residential", "asphalt"),
    # Fell westbound one-way + Oak eastbound one-way (couplet), Panhandle path
    E("scott_fell", "div_fell", "Fell St", "bikeLane", "buffered", "secondary", "asphalt", ow=True),
    E("div_fell", "fell_baker", "Fell St", "bikeLane", "buffered", "secondary", "asphalt", ow=True),
    E("oak_baker", "oak_div", "Oak St", "mixedTraffic", "none", "secondary", "asphalt", ow=True, conf=0.75),
    E("oak_div", "oak_scott", "Oak St", "mixedTraffic", "none", "secondary", "asphalt", ow=True, conf=0.75),
    E("oak_scott", "scott_fell", "Scott St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("fell_baker", "oak_baker", "Baker St", "sharedLane", "sharrows", "residential", "asphalt"),
    E("fell_baker", "pan_masonic", "Panhandle Path", "offStreetPath", "fullyProtected", "residential", "paved"),
    E("pan_masonic", "stanyan", "Panhandle Path", "offStreetPath", "fullyProtected", "residential", "paved"),
    E("stanyan", "ggp", "JFK Promenade", "offStreetPath", "fullyProtected", "residential", "asphalt"),
    # Haight St: direct but hillier and busier
    E("vmkt", "haight_fill", "Haight St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.75),
    E("haight_fill", "haight_div", "Haight St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.75),
    E("haight_div", "haight_masonic", "Haight St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.75),
    E("haight_masonic", "haight_stanyan", "Haight St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.75),
    E("haight_stanyan", "stanyan", "Stanyan St", "mixedTraffic", "none", "secondary", "asphalt", conf=0.7),
    E("haight_div", "div_fell", "Divisadero St", "mixedTraffic", "none", "arterial", "asphalt", conf=0.75),
    # 17th St + Castro, with the steep Castro/Duboce shortcut
    E("v16", "17_val", "Valencia St", "protectedBikeLane", "fullyProtected", "secondary", "asphalt"),
    E("17_val", "17_church", "17th St", "bikeLane", "standard", "tertiary", "asphalt"),
    E("17_church", "17_castro", "17th St", "bikeLane", "standard", "tertiary", "asphalt"),
    E("17_castro", "castro_14", "Castro St", "sharedLane", "sharrows", "residential", "asphalt", conf=0.8),
    E("castro_14", "dub_castro", "Castro St", "sharedLane", "sharrows", "residential", "asphalt", conf=0.8),
    E("dub_castro", "dub_st", "Duboce Ave", "bikeRoute", "none", "residential", "asphalt", conf=0.8),
]


def haversine_m(a, b):
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def main(out_path):
    problems = []
    for e in EDGES:
        f, t = e["fromNode"], e["toNode"]
        if f not in NODES or t not in NODES:
            problems.append(f"unknown node in edge {f}->{t}")
            continue
        length = haversine_m(NODES[f], NODES[t])
        grade = (NODES[t][2] - NODES[f][2]) / length
        if length < 40:
            problems.append(f"suspiciously short edge {f}->{t}: {length:.0f} m")
        if abs(grade) > 0.115:
            problems.append(f"grade sanity {f}->{t}: {grade * 100:.1f}% over {length:.0f} m")

    # Directed connectivity: every node should reach and be reachable from v24.
    fwd, rev = defaultdict(list), defaultdict(list)
    for e in EDGES:
        fwd[e["fromNode"]].append(e["toNode"])
        rev[e["toNode"]].append(e["fromNode"])
        if not e["oneWay"]:
            fwd[e["toNode"]].append(e["fromNode"])
            rev[e["fromNode"]].append(e["toNode"])

    def bfs(adj, start):
        seen, queue = {start}, deque([start])
        while queue:
            for nxt in adj[queue.popleft()]:
                if nxt not in seen:
                    seen.add(nxt)
                    queue.append(nxt)
        return seen

    unreachable = set(NODES) - bfs(fwd, "v24")
    cannot_return = set(NODES) - bfs(rev, "v24")
    if unreachable:
        problems.append(f"unreachable from v24: {sorted(unreachable)}")
    if cannot_return:
        problems.append(f"cannot reach v24: {sorted(cannot_return)}")

    for p in problems:
        print("WARN:", p)

    doc = {
        "metadata": {
            "source": "LaneLine bundled SF sample network",
            "description": (
                "Curated demo subgraph of real SF corridors (Valencia, Market, "
                "Folsom, the Wiggle, Panhandle, Haight, Castro). Feeds the same "
                "NetworkGraphBuilder pipeline as live DataSF/OSM ingestion."
            ),
            "region": "San Francisco",
            "schemaVersion": 1,
        },
        "nodes": [
            {"id": nid, "latitude": lat, "longitude": lon, "elevationMeters": elev}
            for nid, (lat, lon, elev) in sorted(NODES.items())
        ],
        "edges": EDGES,
    }
    with open(out_path, "w") as f:
        json.dump(doc, f, indent=2)

    lengths = [haversine_m(NODES[e["fromNode"]], NODES[e["toNode"]]) for e in EDGES]
    grades = [
        (NODES[e["toNode"]][2] - NODES[e["fromNode"]][2]) / l
        for e, l in zip(EDGES, lengths)
    ]
    print(f"nodes={len(NODES)} edges={len(EDGES)} "
          f"total_km={sum(lengths) / 1000:.1f} "
          f"max_grade={max(abs(g) for g in grades) * 100:.1f}% "
          f"problems={len(problems)}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "SFSampleNetwork.json")
