import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Dong tim duong va tim kiem offline (Dart thuan, khong phu thuoc Flutter).

class Pt {
  final double lat, lon;
  const Pt(this.lat, this.lon);
}

class RouteResult {
  final List<Pt> points;
  final double meters;
  final double seconds;
  const RouteResult(this.points, this.meters, this.seconds);
}

class RouteException implements Exception {
  final String message;
  RouteException(this.message);
  @override
  String toString() => message;
}

// ----------------------------- Do thi duong -----------------------------
class RoadGraph {
  final int n, m;
  final Int32List lat, lon, adj, to, cost, seg, segOff, gLat, gLon;

  RoadGraph._(
    this.n,
    this.m,
    this.lat,
    this.lon,
    this.adj,
    this.to,
    this.cost,
    this.seg,
    this.segOff,
    this.gLat,
    this.gLon,
  );

  static Future<RoadGraph> load(String path) async {
    final bytes = await File(path).readAsBytes();
    return RoadGraph.fromBytes(bytes);
  }

  static RoadGraph fromBytes(Uint8List input) {
    var b = input;
    if (b.offsetInBytes % 4 != 0) b = Uint8List.fromList(b);
    final h = b.buffer.asInt32List(b.offsetInBytes, 5);
    if (h[0] != 0x4D4D4731) {
      throw RouteException('File dữ liệu đường đi không hợp lệ');
    }
    final n = h[1], m = h[2], s = h[3], g = h[4];
    var off = b.offsetInBytes + 20;
    Int32List take(int count) {
      final v = b.buffer.asInt32List(off, count);
      off += count * 4;
      return v;
    }

    final lat = take(n);
    final lon = take(n);
    final adj = take(n + 1);
    final to = take(m);
    final cost = take(m);
    final seg = take(m);
    final segOff = take(s + 1);
    final gLat = take(g);
    final gLon = take(g);
    return RoadGraph._(n, m, lat, lon, adj, to, cost, seg, segOff, gLat, gLon);
  }

  /// Nut gan nhat; tra ve -1 neu xa hon [maxMeters].
  int nearest(double la, double lo, {double maxMeters = 3000}) {
    final qLat = (la * 1e6).round();
    final qLon = (lo * 1e6).round();
    final k = math.cos(la * math.pi / 180);
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < n; i++) {
      final dy = (lat[i] - qLat).toDouble();
      final dx = (lon[i] - qLon) * k;
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return -1;
    return math.sqrt(bestD) * 0.1113 <= maxMeters ? best : -1;
  }

  RouteResult route(Pt from, Pt dest) {
    final s = nearest(from.lat, from.lon);
    final t = nearest(dest.lat, dest.lon);
    if (s < 0) {
      throw RouteException('Vị trí xuất phát nằm ngoài vùng dữ liệu đường đi');
    }
    if (t < 0) {
      throw RouteException('Điểm đến nằm ngoài vùng dữ liệu đường đi');
    }
    final tLat = lat[t], tLon = lon[t];
    final kc = math.cos(tLat / 1e6 * math.pi / 180);
    // Toc do toi da trong du lieu <= 50 km/h => 0.72 giay*10 tren moi met.
    int h(int i) {
      final dy = (lat[i] - tLat) * 0.11054;
      final dx = (lon[i] - tLon) * 0.11132 * kc;
      return (math.sqrt(dx * dx + dy * dy) * 0.72).floor();
    }

    const inf = 0x3fffffff;
    final g = Int32List(n)..fillRange(0, n, inf);
    final prevN = Int32List(n)..fillRange(0, n, -1);
    final prevE = Int32List(n);
    final closed = Uint8List(n);
    final heap = _Heap();
    g[s] = 0;
    heap.push(h(s), s);
    while (heap.size > 0) {
      final u = heap.pop();
      if (closed[u] == 1) continue;
      closed[u] = 1;
      if (u == t) break;
      final gu = g[u];
      final end = adj[u + 1];
      for (var e = adj[u]; e < end; e++) {
        final v = to[e];
        if (closed[v] == 1) continue;
        final ng = gu + cost[e];
        if (ng < g[v]) {
          g[v] = ng;
          prevN[v] = u;
          prevE[v] = e;
          heap.push(ng + h(v), v);
        }
      }
    }
    if (g[t] >= inf) {
      throw RouteException('Không tìm được đường đi giữa hai điểm này');
    }

    // Dung lai duong di
    final nodes = <int>[t];
    final edges = <int>[];
    for (var v = t; v != s;) {
      edges.add(prevE[v]);
      v = prevN[v];
      nodes.add(v);
    }
    final ns = nodes.reversed.toList();
    final es = edges.reversed.toList();
    final pts = <Pt>[from];
    Pt nodePt(int i) => Pt(lat[i] / 1e6, lon[i] / 1e6);
    for (var k = 0; k < es.length; k++) {
      pts.add(nodePt(ns[k]));
      final sc = seg[es[k]];
      final id = sc >> 1;
      final a = segOff[id], b = segOff[id + 1];
      if ((sc & 1) == 0) {
        for (var j = a; j < b; j++) {
          pts.add(Pt(gLat[j] / 1e6, gLon[j] / 1e6));
        }
      } else {
        for (var j = b - 1; j >= a; j--) {
          pts.add(Pt(gLat[j] / 1e6, gLon[j] / 1e6));
        }
      }
    }
    pts.add(nodePt(t));
    pts.add(dest);
    var meters = 0.0;
    for (var i = 1; i < pts.length; i++) {
      meters += distMeters(pts[i - 1], pts[i]);
    }
    return RouteResult(pts, meters, g[t] / 10.0);
  }
}

double distMeters(Pt a, Pt b) {
  final k = math.cos((a.lat + b.lat) / 2 * math.pi / 180);
  final dy = (b.lat - a.lat) * 110540.0;
  final dx = (b.lon - a.lon) * 111320.0 * k;
  return math.sqrt(dx * dx + dy * dy);
}

class _Heap {
  Int32List _k = Int32List(4096), _v = Int32List(4096);
  int size = 0;

  void push(int k, int v) {
    if (size == _k.length) {
      final nk = Int32List(size * 2)..setRange(0, size, _k);
      final nv = Int32List(size * 2)..setRange(0, size, _v);
      _k = nk;
      _v = nv;
    }
    var i = size++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_k[p] <= k) break;
      _k[i] = _k[p];
      _v[i] = _v[p];
      i = p;
    }
    _k[i] = k;
    _v[i] = v;
  }

  int pop() {
    final top = _v[0];
    size--;
    if (size > 0) {
      final k = _k[size], v = _v[size];
      var i = 0;
      while (true) {
        var c = 2 * i + 1;
        if (c >= size) break;
        if (c + 1 < size && _k[c + 1] < _k[c]) c++;
        if (_k[c] >= k) break;
        _k[i] = _k[c];
        _v[i] = _v[c];
        i = c;
      }
      _k[i] = k;
      _v[i] = v;
    }
    return top;
  }
}

// ------------------------------ Tim kiem ------------------------------
const _foldFrom =
    'àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ';
const _foldTo =
    'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
Map<int, int>? _foldMap;

/// Bo dau tieng Viet, ha chu thuong, gom khoang trang (khop voi build_data.py).
String foldText(String s) {
  final map = _foldMap ??= () {
    final f = _foldFrom.runes.toList();
    final t = _foldTo.runes.toList();
    return {for (var i = 0; i < f.length; i++) f[i]: t[i]};
  }();
  final out = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    if (r >= 0x300 && r <= 0x36F) continue; // dau ghep roi
    out.writeCharCode(map[r] ?? r);
  }
  return out
      .toString()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .join(' ');
}

class GeoPlace {
  final String name, cat, norm;
  final double lat, lon;
  const GeoPlace(this.name, this.lat, this.lon, this.cat, this.norm);
}

class SearchIndex {
  final List<GeoPlace> places;
  SearchIndex(this.places);

  static Future<SearchIndex> load(String path) async {
    final lines = await File(path).readAsLines();
    return SearchIndex.fromLines(lines);
  }

  static SearchIndex fromLines(List<String> lines) {
    final list = <GeoPlace>[];
    for (final line in lines) {
      final p = line.split('\t');
      if (p.length < 5) continue;
      final la = double.tryParse(p[1]), lo = double.tryParse(p[2]);
      if (la == null || lo == null) continue;
      list.add(GeoPlace(p[0], la, lo, p[3], p[4]));
    }
    return SearchIndex(list);
  }

  List<GeoPlace> search(
    String query,
    double cLat,
    double cLon, {
    int limit = 25,
  }) {
    final q = foldText(query);
    if (q.length < 2) return [];
    final toks = q.split(' ');
    final scored = <MapEntry<double, GeoPlace>>[];
    final k = math.cos(cLat * math.pi / 180);
    for (final p in places) {
      final s = p.norm;
      var ok = true;
      for (final t in toks) {
        if (!s.contains(t)) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      final dyk = (p.lat - cLat) * 110.54;
      final dxk = (p.lon - cLon) * 111.32 * k;
      final distKm = math.sqrt(dxk * dxk + dyk * dyk);
      var score = s.startsWith(toks[0]) ? 0.0 : 30.0;
      score += (s.length - q.length).abs() * 0.5;
      score += math.min(distKm, 300.0) * 0.8;
      scored.add(MapEntry(score, p));
    }
    scored.sort((a, b) => a.key.compareTo(b.key));
    return scored.take(limit).map((e) => e.value).toList();
  }
}
