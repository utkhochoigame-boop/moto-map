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

const mapUrl =
    'https://github.com/utkhochoigame-boop/moto-map/releases/download/map-data/vietnam.pmtiles';

// Giao diện bản đồ cho dữ liệu Protomaps v4
const _styleJson = r'''
{
  "version": 8,
  "name": "moto",
  "sources": {"protomaps": {"type": "vector"}},
  "layers": [
    {"id":"bg","type":"background","paint":{"background-color":"#f3f0e8"}},
    {"id":"earth","type":"fill","source":"protomaps","source-layer":"earth","paint":{"fill-color":"#f3f0e8"}},
    {"id":"forest","type":"fill","source":"protomaps","source-layer":"landcover","filter":["==",["get","kind"],"forest"],"paint":{"fill-color":"#dcebd2"}},
    {"id":"park","type":"fill","source":"protomaps","source-layer":"landuse","filter":["==",["get","kind"],"park"],"paint":{"fill-color":"#d3e8c8"}},
    {"id":"water","type":"fill","source":"protomaps","source-layer":"water","paint":{"fill-color":"#a5d8f0"}},
    {"id":"buildings","type":"fill","source":"protomaps","source-layer":"buildings","minzoom":14,"paint":{"fill-color":"#e4e0d8"}},

    {"id":"minor_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":13,"filter":["==",["get","kind"],"minor_road"],"paint":{"line-color":"#cfcabf","line-width":["interpolate",["linear"],["zoom"],13,1.8,18,15]}},
    {"id":"major_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":8,"filter":["==",["get","kind"],"major_road"],"paint":{"line-color":"#d9b65a","line-width":["interpolate",["linear"],["zoom"],8,1.2,12,3.5,18,19]}},
    {"id":"highway_casing","type":"line","source":"protomaps","source-layer":"roads","minzoom":5,"filter":["==",["get","kind"],"highway"],"paint":{"line-color":"#d98a1f","line-width":["interpolate",["linear"],["zoom"],5,1.2,10,3.5,14,7,18,24]}},

    {"id":"minor","type":"line","source":"protomaps","source-layer":"roads","minzoom":13,"filter":["==",["get","kind"],"minor_road"],"paint":{"line-color":"#ffffff","line-width":["interpolate",["linear"],["zoom"],13,1,18,12]}},
    {"id":"major","type":"line","source":"protomaps","source-layer":"roads","minzoom":8,"filter":["==",["get","kind"],"major_road"],"paint":{"line-color":"#ffe08a","line-width":["interpolate",["linear"],["zoom"],8,0.7,12,2.5,18,16]}},
    {"id":"highway","type":"line","source":"protomaps","source-layer":"roads","minzoom":5,"filter":["==",["get","kind"],"highway"],"paint":{"line-color":"#ffb84d","line-width":["interpolate",["linear"],["zoom"],5,0.7,10,2.5,14,5,18,20]}},
    {"id":"rail","type":"line","source":"protomaps","source-layer":"roads","minzoom":10,"filter":["==",["get","kind"],"rail"],"paint":{"line-color":"#b0aaa0","line-width":1}},

    {"id":"road_names","type":"symbol","source":"protomaps","source-layer":"roads","minzoom":14,"layout":{"symbol-placement":"line","text-field":["get","name"],"text-size":11},"paint":{"text-color":"#555555","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"region","type":"symbol","source":"protomaps","source-layer":"places","minzoom":5,"maxzoom":9,"filter":["==",["get","kind"],"region"],"layout":{"text-field":["get","name"],"text-size":12},"paint":{"text-color":"#777777","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"locality","type":"symbol","source":"protomaps","source-layer":"places","minzoom":6,"filter":["==",["get","kind"],"locality"],"layout":{"text-field":["get","name"],"text-size":["interpolate",["linear"],["zoom"],6,11,14,18]},"paint":{"text-color":"#222222","text-halo-color":"#ffffff","text-halo-width":2}},
    {"id":"neighbourhood","type":"symbol","source":"protomaps","source-layer":"places","minzoom":13,"filter":["==",["get","kind"],"neighbourhood"],"layout":{"text-field":["get","name"],"text-size":12},"paint":{"text-color":"#666666","text-halo-color":"#ffffff","text-halo-width":1.5}},
    {"id":"pois","type":"symbol","source":"protomaps","source-layer":"pois","minzoom":16,"layout":{"text-field":["get","name"],"text-size":11},"paint":{"text-color":"#8a5a2b","text-halo-color":"#ffffff","text-halo-width":1.5}}
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

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  String? _path;
  bool _checking = true;
  bool _downloading = false;
  double _progress = 0;
  int _gotMb = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/vietnam.pmtiles');
  }

  Future<void> _check() async {
    final f = await _file();
    final ok = await f.exists() && await f.length() > 20 * 1024 * 1024;
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (ok) _path = f.path;
    });
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0;
      _gotMb = 0;
    });
    final client = HttpClient();
    try {
      final f = await _file();
      final req = await client.getUrl(Uri.parse(mapUrl));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw 'Máy chủ trả về mã ${res.statusCode}';
      }
      final total = res.contentLength;
      final part = File('${f.path}.part');
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
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      if (mounted) {
        setState(() {
          _path = f.path;
          _downloading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Tải lỗi: $e';
          _downloading = false;
        });
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_path != null) return MapPage(path: _path!);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.map, size: 72),
              const SizedBox(height: 16),
              const Text('Tải bản đồ miền Nam để dùng offline',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                  'Dung lượng vài trăm MB. Nên dùng wifi, giữ màn hình sáng và để app mở cho đến khi tải xong.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (_downloading) ...[
                LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                const SizedBox(height: 8),
                Text('Đã tải $_gotMb MB'
                    '${_progress > 0 ? ' (${(_progress * 100).round()}%)' : ''}'),
              ] else
                FilledButton.icon(
                  onPressed: _download,
                  icon: const Icon(Icons.download),
                  label: const Text('Tải bản đồ'),
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

class MapPage extends StatefulWidget {
  final String path;
  const MapPage({super.key, required this.path});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _controller = MapController();
  late final Future<PmTilesVectorTileProvider> _provider =
      PmTilesVectorTileProvider.fromSource(widget.path);
  final _theme =
      ThemeReader().read(jsonDecode(_styleJson) as Map<String, dynamic>);
  StreamSubscription<Position>? _sub;
  LatLng? _me;
  bool _followed = false;
  String _status = 'Đang lấy vị trí...';

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
        _status = 'Bản đồ offline | GPS ~${p.accuracy.round()} m';
      });
      if (!_followed) {
        _followed = true;
        _controller.move(point, 15);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: const MapOptions(
              initialCenter: LatLng(10.8, 106.7),
              initialZoom: 8,
              maxZoom: 18,
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
              if (_me != null)
                MarkerLayer(markers: [
                  Marker(
                    point: _me!,
                    width: 44,
                    height: 44,
                    child: const Icon(Icons.navigation,
                        color: Colors.blue, size: 40),
                  ),
                ]),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_status),
                ),
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
