#!/usr/bin/env python3
"""Dung du lieu offline cho app Moto Map.

Cach dung:
  python tools/build_data.py roads <roads.osm.pbf> <graph.bin>
  python tools/build_data.py search <named.osm.pbf> <search.tsv>
"""
import sys
import unicodedata
from array import array

import numpy as np
import osmium

# ---- Ho so xe may (km/h). Toc do toi da <= 50 de heuristic cua app dung. ----
SPEED = {
    "trunk": 45, "trunk_link": 35,
    "primary": 40, "primary_link": 32,
    "secondary": 38, "secondary_link": 30,
    "tertiary": 35, "tertiary_link": 28,
    "unclassified": 28, "residential": 25,
    "living_street": 12, "service": 12, "road": 20,
}
# motorway (cao toc) bi loai: xe may khong duoc di.
MAGIC = 0x4D4D4731  # 'MMG1'
SIDE_STREETS = set(SPEED) | {"pedestrian"}


def road_speed(tags):
    hw = tags.get("highway")
    sp = SPEED.get(hw)
    if sp is None:
        return None
    if tags.get("area") == "yes":
        return None
    moto = tags.get("motorcycle")
    if moto in ("no", "private"):
        return None
    if moto not in ("yes", "designated", "permissive"):
        for key in ("motor_vehicle", "vehicle", "access"):
            if tags.get(key) in ("no", "private"):
                return None
    if hw == "service" and tags.get("service") in ("parking_aisle", "driveway"):
        sp = 8
    ms = tags.get("maxspeed")
    if ms and "mph" not in ms:
        try:
            v = float(ms.split()[0])
            if 5 <= v <= 130:
                sp = min(sp, v)
        except ValueError:
            pass
    return float(sp)


def directions(tags):
    """Tra ve (di_xuoi, di_nguoc)."""
    ow = tags.get("oneway")
    if ow in ("yes", "true", "1"):
        return True, False
    if ow in ("-1", "reverse"):
        return False, True
    if ow in ("no", "false", "0"):
        return True, True
    if tags.get("junction") in ("roundabout", "circular"):
        return True, False
    return True, True


def way_arrays(w):
    n = len(w.nodes)
    refs = np.fromiter((x.ref for x in w.nodes), np.int64, count=n)
    lons = np.fromiter((x.lon for x in w.nodes), np.float64, count=n)
    lats = np.fromiter((x.lat for x in w.nodes), np.float64, count=n)
    return refs, lats, lons


def build_graph(src, out):
    from scipy.sparse import csr_matrix
    from scipy.sparse.csgraph import connected_components

    print("[graph] luot 1: dem nut giao", flush=True)
    chunks, big = [], []
    nways = 0
    for w in osmium.FileProcessor(src, osmium.osm.WAY):
        if road_speed(w.tags) is None:
            continue
        nways += 1
        chunks.append(np.fromiter((x.ref for x in w.nodes), np.int64,
                                  count=len(w.nodes)))
        if len(chunks) >= 100000:
            big.append(np.concatenate(chunks))
            chunks = []
    if chunks:
        big.append(np.concatenate(chunks))
    if not big:
        raise SystemExit("Khong co duong nao trong du lieu")
    allrefs = np.concatenate(big)
    del big, chunks
    ids, counts = np.unique(allrefs, return_counts=True)
    junc = ids[counts >= 2]
    del allrefs, ids, counts
    print(f"[graph] {nways} duong, {len(junc)} nut giao", flush=True)

    print("[graph] luot 2: tao canh", flush=True)
    ef, et = array("q"), array("q")          # nut dau/cuoi (osm id)
    flat, flon = array("d"), array("d")      # toa do nut dau
    tlat, tlon = array("d"), array("d")      # toa do nut cuoi
    edist, espeed, eflag = array("f"), array("f"), array("b")
    gstart = array("i")
    glat, glon = array("i"), array("i")
    done = 0
    proc2 = osmium.FileProcessor(src, osmium.osm.NODE | osmium.osm.WAY)
    for w in proc2.with_locations():
        if not w.is_way():
            continue
        sp = road_speed(w.tags)
        if sp is None:
            continue
        try:
            refs, lats, lons = way_arrays(w)
        except osmium.InvalidLocationError:
            continue
        n = len(refs)
        if n < 2:
            continue
        fwd, bwd = directions(w.tags)
        flag = (1 if fwd else 0) | (2 if bwd else 0)
        if len(junc):
            pos = np.searchsorted(junc, refs)
            pos[pos >= len(junc)] = 0
            isj = junc[pos] == refs
        else:
            isj = np.zeros(n, dtype=bool)
        isj[0] = True
        isj[-1] = True
        coslat = np.cos(np.radians(lats.mean()))
        d = np.hypot(np.diff(lats) * 110540.0,
                     np.diff(lons) * 111320.0 * coslat)
        cum = np.concatenate(([0.0], np.cumsum(d)))
        ilat = np.rint(lats * 1e6).astype("<i4")
        ilon = np.rint(lons * 1e6).astype("<i4")
        jp = np.nonzero(isj)[0]
        for a, b in zip(jp[:-1], jp[1:]):
            if refs[a] == refs[b]:
                continue
            ef.append(int(refs[a]))
            et.append(int(refs[b]))
            flat.append(float(lats[a]))
            flon.append(float(lons[a]))
            tlat.append(float(lats[b]))
            tlon.append(float(lons[b]))
            edist.append(float(cum[b] - cum[a]))
            espeed.append(sp)
            eflag.append(flag)
            gstart.append(len(glat))
            glat.frombytes(ilat[a + 1:b].tobytes())
            glon.frombytes(ilon[a + 1:b].tobytes())
        done += 1
        if done % 200000 == 0:
            print(f"[graph]  ... {done} duong", flush=True)
    gstart.append(len(glat))

    ne = len(ef)
    print(f"[graph] {ne} doan duong", flush=True)
    efa = np.frombuffer(ef, dtype=np.int64)
    eta = np.frombuffer(et, dtype=np.int64)
    allref = np.concatenate((efa, eta))
    alllat = np.concatenate((np.frombuffer(flat, np.float64),
                             np.frombuffer(tlat, np.float64)))
    alllon = np.concatenate((np.frombuffer(flon, np.float64),
                             np.frombuffer(tlon, np.float64)))
    uref, first = np.unique(allref, return_index=True)
    nlat = np.rint(alllat[first] * 1e6).astype("<i4")
    nlon = np.rint(alllon[first] * 1e6).astype("<i4")
    fi = np.searchsorted(uref, efa)
    ti = np.searchsorted(uref, eta)
    dist = np.frombuffer(edist, np.float32).astype(np.float64)
    speed = np.frombuffer(espeed, np.float32).astype(np.float64)
    cost_all = np.maximum(1, np.rint(dist * 3.6 / speed * 10.0)).astype(np.int64)
    flags = np.frombuffer(eflag, np.int8)
    eid = np.arange(ne, dtype=np.int64)

    fw = (flags & 1) != 0
    bw = (flags & 2) != 0
    s_src = np.concatenate((fi[fw], ti[bw]))
    s_dst = np.concatenate((ti[fw], fi[bw]))
    s_seg = np.concatenate((eid[fw] * 2, eid[bw] * 2 + 1))
    s_cost = np.concatenate((cost_all[fw], cost_all[bw]))
    nn = len(uref)

    print("[graph] giu thanh phan lien thong lon nhat", flush=True)
    g = csr_matrix((np.ones(len(s_src), dtype=np.int8), (s_src, s_dst)),
                   shape=(nn, nn))
    _, labels = connected_components(g, directed=True, connection="strong")
    keep_label = np.argmax(np.bincount(labels))
    keep = labels == keep_label
    emask = keep[s_src] & keep[s_dst]
    newidx = np.cumsum(keep) - 1
    s_src = newidx[s_src[emask]]
    s_dst = newidx[s_dst[emask]]
    s_seg = s_seg[emask]
    s_cost = s_cost[emask]
    nlat = nlat[keep]
    nlon = nlon[keep]
    nn = len(nlat)

    order = np.argsort(s_src, kind="stable")
    s_src, s_dst, s_seg, s_cost = (s_src[order], s_dst[order],
                                   s_seg[order], s_cost[order])
    adj = np.concatenate(([0], np.cumsum(np.bincount(s_src, minlength=nn))))
    segoff = np.frombuffer(gstart, dtype=np.int32)
    glat_a = np.frombuffer(glat, dtype=np.int32)
    glon_a = np.frombuffer(glon, dtype=np.int32)

    print(f"[graph] {nn} nut, {len(s_src)} canh co huong", flush=True)
    with open(out, "wb") as f:
        np.array([MAGIC, nn, len(s_src), ne, len(glat_a)], "<i4").tofile(f)
        for arr in (nlat, nlon, adj, s_dst, s_cost, s_seg, segoff,
                    glat_a, glon_a):
            np.asarray(arr).astype("<i4").tofile(f)
    print("[graph] xong ->", out, flush=True)


# ------------------------------- TIM KIEM -------------------------------
def fold(s):
    s = s.replace("đ", "d").replace("Đ", "D")
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return " ".join(s.lower().split())


POI_KEYS = ("amenity", "shop", "tourism", "leisure", "historic", "office",
            "healthcare", "railway", "aeroway", "public_transport")


def clean(s):
    return " ".join(s.replace("\t", " ").replace("\n", " ").split())


def poi_cat(tags):
    for k in POI_KEYS:
        v = tags.get(k)
        if v:
            if k == "railway" and v not in ("station", "halt"):
                continue
            if k == "public_transport" and v != "station":
                continue
            return k if v == "yes" else v
    return None


def build_search(src, out):
    rows, seen = [], set()

    def add(name, lat, lon, cat, tags, dedupe=False):
        name = clean(name)
        if not name:
            return
        norm = fold(name)
        en = tags.get("name:en")
        if en:
            en = fold(en)
            if en and en != norm:
                norm = norm + " " + en
        if dedupe:
            key = (norm, round(lat / 0.01), round(lon / 0.01))
            if key in seen:
                return
            seen.add(key)
        rows.append(f"{name}\t{lat:.5f}\t{lon:.5f}\t{cat}\t{norm}")

    proc = osmium.FileProcessor(src, osmium.osm.NODE | osmium.osm.WAY)
    for o in proc.with_locations():
        name = o.tags.get("name")
        if not name:
            continue
        if o.is_node():
            loc = o.location
            if not loc.valid():
                continue
            place = o.tags.get("place")
            if place:
                add(name, loc.lat, loc.lon, place, o.tags)
                continue
            cat = poi_cat(o.tags)
            if cat:
                add(name, loc.lat, loc.lon, cat, o.tags)
        else:
            try:
                n = len(o.nodes)
                if n < 2:
                    continue
                hw = o.tags.get("highway")
                if hw in SIDE_STREETS:
                    mid = o.nodes[n // 2]
                    add(name, mid.lat, mid.lon, "street", o.tags, dedupe=True)
                    continue
                cat = poi_cat(o.tags)
                if not cat and o.tags.get("building"):
                    cat = "building"
                if cat:
                    lats = [x.lat for x in o.nodes]
                    lons = [x.lon for x in o.nodes]
                    add(name, sum(lats) / n, sum(lons) / n, cat, o.tags)
            except osmium.InvalidLocationError:
                continue
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(rows))
        f.write("\n")
    print(f"[search] {len(rows)} dia diem -> {out}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("roads", "search"):
        raise SystemExit(__doc__)
    if sys.argv[1] == "roads":
        build_graph(sys.argv[2], sys.argv[3])
    else:
        build_search(sys.argv[2], sys.argv[3])
