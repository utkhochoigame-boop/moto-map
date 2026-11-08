import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    show ThemeReader;

import 'engine.dart';

const mapUrl =
    'https://github.com/utkhochoigame-boop/moto-map/releases/download/map-data/vietnam.pmtiles';
const routeBase =
    'https://github.com/utkhochoigame-boop/moto-map/releases/download/route-data';

class DataFile {
  final String name, label, url;
  final int minBytes;
  const DataFile(this.name, this.label, this.url, this.minBytes);
}

const mapFile =
    DataFile('vietnam.pmtiles', 'Bản đồ', mapUrl, 20 * 1024 * 1024);
const graphFile =
    DataFile('graph.bin', 'Dữ liệu đường đi', '$routeBase/graph.bin', 100 * 1024);
const searchFile = DataFile(
    'search.tsv', 'Dữ liệu tìm kiếm', '$routeBase/search.tsv', 50 * 1024);
const allFiles = [mapFile, graphFile, searchFile];

// Giao diện bản đồ cho dữ liệu Protomaps v4
const _styleJson = r'''
{
  "version": 8,
  "name": "moto",
  "sources": {"protomaps": {"type": "vector"}},
  "layers": [
    {"id":"bg","type":"background","paint":{"background-color":"#f3f0e8"}},
    {"id":"earth","type":"fill","source":"protomaps","source-layer":"earth","paint":{"fill-color":"#f3f0e8"}},
    {"id":"forest","type":"fill","source":"protomaps","source-layer":"landcover","filter":["==","kind","forest"],"paint":{"fill-color":"#dcebd2"}},
    {"id":"park","type":"fill","source":"protomaps","source-layer":"landuse","filter":["==","kind","park"],"paint":{"fill-color":"#d3e8c8"}},
    {"id":"water","type":"fill","source":"protomaps","source-layer":"water","paint":{"fill-color":"#a5d8f0"}},
    {"id":"buildings","type":"fill","source":"protomaps","source-layer":"buildings","minzoom":14,"paint":{"fill-color":"#e4e0d8"}},

    {"id":"minor_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":13,"filter":["==","kind","minor_road"],"paint":{"line-color":"#cfcabf","line-width":{"stops":[[13,1.8],[18,15]]}}},
    {"id":"major_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":8,"filter":["==","kind","major_road"],"paint":{"line-color":"#d9b65a","line-width":{"stops":[[8,1.2],[12,3.5],[18,19]]}}},
    {"id":"highway_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":5,"filter":["==","kind","highway"],"paint":{"line-color":"#d98a1f","line-width":{"stops":[[5,1.2],[10,3.5],[14,7],[18,24]]}}},

    {"id":"minor","type":"line","source":"protomaps","source-layer":"roads","minzoom":13,"filter":["==","kind","minor_road"],"paint":{"line-color":"#ffffff","line-width":{"stops":[[13,1],[18,12]]}}},
    {"id":"major","type":"line","source":"protomaps","source-layer":"roads","minzoom":8,"filter":["==","kind","major_road"],"paint":{"line-color":"#ffe08a","line-width":{"stops":[[8,0.7],[12,2.5],[18,16]]}}},
    {"id":"highway","type":"line","source":"protomaps","source-layer":"roads","minzoom":5,"filter":["==","kind","highway"],"paint":{"line-color":"#ffb84d","line-width":{"stops":[[5,0.7],[10,2.5],[14,5],[18,20]]}}},
    {"id":"rail","type":"line","source":"protomaps","source-layer":"roads","minzoom":10,"filter":["==","kind","rail"],"paint":{"line-color":"#b0aaa0","line-width":1}},

    {"id":"road_names","type":"symbol","source":"protomaps","source-layer":"roads","minzoom":14,"layout":{"symbol-placement":"line","text-field":"{name}","text-size":11},"paint":{"text-color":"#555555","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"region","type":"symbol","source":"protomaps","source-layer":"places","minzoom":5,"maxzoom":9,"filter":["==","kind","region"],"layout":{"text-field":"{name}","text-size":12},"paint":{"text-color":"#777777","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"locality","type":"symbol","source":"protomaps","source-layer":"places","minzoom":6,"filter":["==","kind","locality"],"layout":{"text-field":"{name}","text-size":{"stops":[[6,11],[14,18]]}},"paint":{"text-color":"#222222","text-halo-color":"#ffffff","text-halo-width":2}},
    {"id":"neighbourhood","type":"symbol","source":"protomaps","source-layer":"places","minzoom":13,"filter":["==","kind","neighbourhood"],"layout":{"text-field":"{name}","text-size":12},"paint":{"text-color":"#666666","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"pois","type":"symbol","source":"protomaps","source-layer":"pois","minzoom":16,"layout":{"text-field":"{name}","text-size":11},"paint":{"text-color":"#8a5a2b","text-halo-color":"#ffffff","text-halo-width":1.5}}
  ]
}
''';

void main() => runApp(const MotoMapApp());

class MotoMapApp extends StatelessWidget {
  const MotoMapApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moto Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.orange, useMaterial3: true),
      home: const Gate(),
    );
  }
}

enum Phase { checking, needDownload, downloading, loading, ready }

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  Phase _phase = Phase.checking;
  List<DataFile> _missing = [];
  RoadGraph? _graph;
  SearchIndex? _index;
  String? _mapPath;
  String? _error;
  String _curLabel = '';
  int _curIndex = 0;
  int _gotMb = 0;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check({String? error}) async {
    setState(() {
      _phase = Phase.checking;
      _error = error;
    });
    final dir = await getApplicationSupportDirectory();
    final missing = <DataFile>[];
    for (final f in allFiles) {
      final file = File('${dir.path}/${f.name}');
      if (!await file.exists() || await file.length() < f.minBytes) {
        missing.add(f);
      }
    }
    if (!mounted) return;
    if (missing.isNotEmpty) {
      setState(() {
        _missing = missing;
        _phase = Phase.needDownload;
      });
      return;
    }
    setState(() => _phase = Phase.loading);
    try {
      final graph = await RoadGraph.load('${dir.path}/${graphFile.name}');
      final index = await SearchIndex.load('${dir.path}/${searchFile.name}');
      if (!mounted) return;
      setState(() {
        _graph = graph;
        _index = index;
        _mapPath = '${dir.path}/${mapFile.name}';
        _phase = Phase.ready;
      });
    } catch (e) {
      for (final f in [graphFile, searchFile]) {
        try {
          await File('${dir.path}/${f.name}').delete();
        } catch (_) {}
      }
      if (mounted) await _check(error: 'Dữ liệu bị lỗi, hãy tải lại: $e');
    }
  }

  Future<void> _downloadAll() async {
    setState(() {
      _phase = Phase.downloading;
      _error = null;
    });
    try {
      final dir = await getApplicationSupportDirectory();
      for (var i = 0; i < _missing.length; i++) {
        await _downloadOne(dir, _missing[i], i);
      }
      await _check();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Tải lỗi: $e';
          _phase = Phase.needDownload;
        });
      }
    }
  }

  Future<void> _downloadOne(Directory dir, DataFile f, int index) async {
    setState(() {
      _curLabel = f.label;
      _curIndex = index;
      _gotMb = 0;
      _progress = 0;
    });
    final client = HttpClient();
    final target = File('${dir.path}/${f.name}');
    final part = File('${target.path}.part');
    try {
      final req = await client.getUrl(Uri.parse(f.url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw '${f.label}: máy chủ trả về mã ${res.statusCode}';
      }
      final total = res.contentLength;
      final sink = part.openWrite();
      var got = 0;
      var lastUi = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (got - lastUi > 2 * 1024 * 1024) {
          lastUi = got;
          if (mounted) {
            setState(() {
              _gotMb = got ~/ (1024 * 1024);
              _progress = total > 0 ? got / total : 0;
            });
          }
        }
      }
      await sink.flush();
      await sink.close();
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case Phase.checking:
        return const Scaffold(
            body: Center(child: CircularProgressIndicator()));
      case Phase.loading:
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Đang nạp dữ liệu đường đi và tìm kiếm...'),
              ],
            ),
          ),
        );
      case Phase.ready:
        return MapPage(path: _mapPath!, graph: _graph!, index: _index!);
      case Phase.needDownload:
      case Phase.downloading:
        break;
    }
    final downloading = _phase == Phase.downloading;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.map, size: 72),
              const SizedBox(height: 16),
              const Text('Cần tải dữ liệu để dùng offline',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                  'Cần tải: ${_missing.map((e) => e.label).join(', ')}.\nNên dùng wifi, giữ màn hình sáng và để app mở cho đến khi tải xong.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (downloading) ...[
                LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                const SizedBox(height: 8),
                Text('(${_curIndex + 1}/${_missing.length}) $_curLabel: '
                    '$_gotMb MB'
                    '${_progress > 0 ? ' (${(_progress * 100).round()}%)' : ''}'),
              ] else
                FilledButton.icon(
                  onPressed: _downloadAll,
                  icon: const Icon(Icons.download),
                  label: const Text('Tải xuống'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String catLabel(String c) {
  const m = {
    'street': 'Đường',
    'cafe': 'Quán cà phê',
    'restaurant': 'Nhà hàng',
    'fast_food': 'Quán ăn nhanh',
    'fuel': 'Trạm xăng',
    'hospital': 'Bệnh viện',
    'clinic': 'Phòng khám',
    'pharmacy': 'Nhà thuốc',
    'bank': 'Ngân hàng',
    'atm': 'ATM',
    'school': 'Trường học',
    'university': 'Đại học',
    'marketplace': 'Chợ',
    'supermarket': 'Siêu thị',
    'convenience': 'Cửa hàng tiện lợi',
    'hotel': 'Khách sạn',
    'park': 'Công viên',
    'place_of_worship': 'Nơi thờ tự',
    'police': 'Công an',
    'suburb': 'Phường / khu vực',
    'quarter': 'Khu phố',
    'neighbourhood': 'Khu dân cư',
    'city': 'Thành phố',
    'town': 'Thị xã / thị trấn',
    'village': 'Làng / xã',
    'hamlet': 'Ấp',
    'station': 'Nhà ga / bến xe',
    'parking': 'Bãi đỗ xe',
    'building': 'Tòa nhà',
    'cinema': 'Rạp phim',
    'mall': 'Trung tâm thương mại',
  };
  return m[c] ?? c;
}

IconData catIcon(String c) {
  switch (c) {
    case 'street':
      return Icons.add_road;
    case 'cafe':
      return Icons.local_cafe;
    case 'restaurant':
    case 'fast_food':
      return Icons.restaurant;
    case 'fuel':
      return Icons.local_gas_station;
    case 'hospital':
    case 'clinic':
    case 'pharmacy':
      return Icons.local_hospital;
    case 'city':
    case 'town':
    case 'village':
    case 'suburb':
    case 'quarter':
    case 'neighbourhood':
    case 'hamlet':
      return Icons.location_city;
    default:
      return Icons.place;
  }
}

String fmtDist(double m) =>
    m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

String fmtTime(double s) {
  final min = (s / 60).round();
  if (min < 60) return '$min phút';
  return '${min ~/ 60} giờ ${min % 60} phút';
}

class MapPage extends StatefulWidget {
  final String path;
  final RoadGraph graph;
  final SearchIndex index;
  const MapPage(
      {super.key,
      required this.path,
      required this.graph,
      required this.index});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _controller = MapController();
  late final Future<PmTilesVectorTileProvider> _provider =
      PmTilesVectorTileProvider.fromSource(widget.path);
  final _theme =
      ThemeReader().read(jsonDecode(_styleJson) as Map<String, dynamic>);
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  StreamSubscription<Position>? _sub;
  LatLng? _me;
  bool _followed = false;
  String _status = 'Đang lấy vị trí...';

  List<GeoPlace> _results = [];
  LatLng _searchCenter = const LatLng(10.8, 106.7);
  Pt? _dest;
  String _destName = '';
  RouteResult? _route;
  bool _routing = false;

  @override
  void initState() {
    super.initState();
    _provider.then((_) {}, onError: (e) {
      if (mounted) setState(() => _status = 'Lỗi đọc bản đồ: $e');
    });
    _startLocation();
  }

  Future<void> _startLocation() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      if (mounted) setState(() => _status = 'Hãy bật GPS (Vị trí) trên điện thoại');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      if (mounted) setState(() => _status = 'Chưa được cấp quyền vị trí');
      return;
    }
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((p) {
      if (!mounted) return;
      final point = LatLng(p.latitude, p.longitude);
      setState(() {
        _me = point;
        _status = 'Offline | GPS ~${p.accuracy.round()} m | Nhấn giữ bản đồ để chọn điểm đến';
      });
      if (!_followed) {
        _followed = true;
        _controller.move(point, 15);
      }
    });
  }

  LatLng _center() {
    try {
      return _controller.camera.center;
    } catch (_) {
      return _me ?? const LatLng(10.8, 106.7);
    }
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () {
      final c = _center();
      final r = widget.index.search(v, c.latitude, c.longitude);
      if (mounted) {
        setState(() {
          _searchCenter = c;
          _results = r;
        });
      }
    });
  }

  void _setDest(Pt p, String name) {
    setState(() {
      _dest = p;
      _destName = name;
      _route = null;
      _results = [];
    });
  }

  void _selectPlace(GeoPlace p) {
    _focus.unfocus();
    _text.text = p.name;
    _setDest(Pt(p.lat, p.lon), p.name);
    _controller.move(LatLng(p.lat, p.lon), 16);
  }

  void _clearDest() {
    _text.clear();
    setState(() {
      _dest = null;
      _route = null;
      _results = [];
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _computeRoute() async {
    final d = _dest;
    final me = _me;
    if (d == null) return;
    if (me == null) {
      _snack('Chưa có vị trí GPS, hãy bật GPS và đợi vài giây');
      return;
    }
    setState(() => _routing = true);
    await Future.delayed(const Duration(milliseconds: 80));
    try {
      final r = widget.graph.route(Pt(me.latitude, me.longitude), d);
      if (!mounted) return;
      setState(() => _route = r);
      var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
      for (final p in r.points) {
        if (p.lat < minLat) minLat = p.lat;
        if (p.lat > maxLat) maxLat = p.lat;
        if (p.lon < minLon) minLon = p.lon;
        if (p.lon > maxLon) maxLon = p.lon;
      }
      _controller.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)),
        padding: const EdgeInsets.fromLTRB(40, 180, 40, 220),
      ));
    } on RouteException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Lỗi tính đường: $e');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget _searchBar() {
    return Card(
      margin: EdgeInsets.zero,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        onChanged: _onQuery,
        decoration: InputDecoration(
          hintText: 'Tìm địa điểm, tên đường, hẻm...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _text.text.isEmpty && _dest == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearDest,
                ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _resultsList() {
    return Card(
      margin: const EdgeInsets.only(top: 4),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 330),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: _results.length,
          itemBuilder: (context, i) {
            final p = _results[i];
            final km = distMeters(
                    Pt(p.lat, p.lon),
                    Pt(_searchCenter.latitude, _searchCenter.longitude)) /
                1000;
            return ListTile(
              dense: true,
              leading: Icon(catIcon(p.cat)),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${catLabel(p.cat)} • ${km.toStringAsFixed(1)} km'),
              onTap: () => _selectPlace(p),
            );
          },
        ),
      ),
    );
  }

  Widget _panel() {
    final r = _route;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_destName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (r != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    '${fmtDist(r.meters)} • ${fmtTime(r.seconds)} (xe máy, ước tính)'),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_routing)
                  const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 3))
                else
                  FilledButton.icon(
                    onPressed: _computeRoute,
                    icon: const Icon(Icons.directions),
                    label: Text(r == null ? 'Chỉ đường' : 'Tính lại'),
                  ),
                const SizedBox(width: 8),
                TextButton(onPressed: _clearDest, child: const Text('Xóa')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dest = _dest;
    final route = _route;
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: const LatLng(10.8, 106.7),
              initialZoom: 8,
              maxZoom: 18,
              onTap: (tapPosition, point) {
                _focus.unfocus();
                if (_results.isNotEmpty) setState(() => _results = []);
              },
              onLongPress: (tapPosition, point) {
                _focus.unfocus();
                _text.clear();
                _setDest(Pt(point.latitude, point.longitude),
                    'Điểm đã chọn trên bản đồ');
              },
            ),
            children: [
              FutureBuilder<PmTilesVectorTileProvider>(
                future: _provider,
                builder: (context, snap) {
                  if (!snap.hasData) return const SizedBox.shrink();
                  return VectorTileLayer(
                    theme: _theme,
                    tileProviders: TileProviders({'protomaps': snap.data!}),
                  );
                },
              ),
              if (route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route.points
                          .map((p) => LatLng(p.lat, p.lon))
                          .toList(),
                      strokeWidth: 6,
                      color: Colors.blue,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              MarkerLayer(markers: [
                if (_me != null)
                  Marker(
                    point: _me!,
                    width: 44,
                    height: 44,
                    child: const Icon(Icons.navigation,
                        color: Colors.blue, size: 40),
                  ),
                if (dest != null)
                  Marker(
                    point: LatLng(dest.lat, dest.lon),
                    width: 44,
                    height: 44,
                    child: Transform.translate(
                      offset: const Offset(0, -20),
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 44),
                    ),
                  ),
              ]),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _searchBar(),
                    if (_results.isNotEmpty)
                      _resultsList()
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(_status),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (dest != null)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 88, 12),
                  child: _panel(),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_me != null) _controller.move(_me!, 16);
        },
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
