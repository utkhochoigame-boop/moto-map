import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

void main() => runApp(const MotoMapApp());

class MotoMapApp extends StatelessWidget {
  const MotoMapApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Moto Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.orange, useMaterial3: true),
      home: const MapPage(),
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});
  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _controller = MapController();
  StreamSubscription<Position>? _sub;
  LatLng? _me;
  bool _followed = false;
  String _status = 'Đang lấy vị trí...';

  @override
  void initState() {
    super.initState();
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
        _status = 'Độ chính xác ~${p.accuracy.round()} m';
      });
      if (!_followed) {
        _followed = true;
        _controller.move(point, 16);
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
              initialCenter: LatLng(16.0, 106.0),
              initialZoom: 5.5,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.utkho.moto_map',
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
