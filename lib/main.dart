import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

late List<CameraDescription> kameralar;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  kameralar = await availableCameras();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: KameraEkrani(),
  ));
}

class KameraEkrani extends StatefulWidget {
  const KameraEkrani({super.key});
  @override
  State<KameraEkrani> createState() => _KameraEkraniState();
}

class _KameraEkraniState extends State<KameraEkrani> {
  CameraController? _kontrol;
  String? _sonFoto;
  String? _hata;
  bool _cekiliyor = false;
  bool _isleniyor = false;
  int _kareSayaci = 0;
  int _isikPuani = 0;
  int _netlikPuani = 0;
  double _hamParlaklik = 0;
  double _hamNetlik = 0;

  @override
  void initState() {
    super.initState();
    _kontrol = CameraController(
      kameralar.first,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _kontrol!.initialize().then((_) async {
      if (!mounted) return;
      await _kontrol!.startImageStream(_analiz);
      setState(() {});
    }).catchError((e) {
      setState(() => _hata = 'Kamera açılamadı: $e');
    });
  }

  @override
  void dispose() {
    _kontrol?.dispose();
    super.dispose();
  }

  // Her 5 karede bir parlaklık ve netlik ölçer.
  void _analiz(CameraImage img) {
    _kareSayaci++;
    if (_isleniyor || _kareSayaci % 5 != 0) return;
    _isleniyor = true;
    try {
      final plane = img.planes[0];
      final b = plane.bytes;
      final satir = plane.bytesPerRow;
      final w = img.width;
      final h = img.height;
      int toplam = 0;
      int fark = 0;
      int adet = 0;
      for (int y = 0; y < h - 1; y += 4) {
        final o = y * satir;
        for (int x = 0; x < w - 1; x += 4) {
          final v = b[o + x];
          toplam += v;
          fark += (v - b[o + x + 1]).abs() + (v - b[o + satir + x]).abs();
          adet++;
        }
      }
      if (adet == 0) return;
      final parlaklik = toplam / adet;
      final netlik = fark / adet;
      final isik =
          (100 - ((parlaklik - 130).abs() / 130 * 100)).clamp(0, 100).round();
      final net = ((netlik - 2) * 8).clamp(0, 100).round();
      if (mounted) {
        setState(() {
          _isikPuani = isik;
          _netlikPuani = net;
          _hamParlaklik = parlaklik;
          _hamNetlik = netlik;
        });
      }
    } finally {
      _isleniyor = false;
    }
  }

  Future<void> _cek() async {
    if (_cekiliyor) return;
    _cekiliyor = true;
    try {
      await _kontrol!.stopImageStream();
      final foto = await _kontrol!.takePicture();
      setState(() => _sonFoto = foto.path);
      await _kontrol!.startImageStream(_analiz);
    } finally {
      _cekiliyor = false;
    }
  }

  Widget _rozet(String ad, int puan) {
    final renk = puan >= 70
        ? Colors.green
        : (puan >= 40 ? Colors.orange : Colors.red);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: renk.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$ad $puan',
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_hata != null) {
      return Scaffold(body: Center(child: Text(_hata!)));
    }
    if (_kontrol == null || !_kontrol!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final toplamPuan = ((_isikPuani + _netlikPuani) / 2).round();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(child: CameraPreview(_kontrol!)),
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _rozet('Işık', _isikPuani),
                  const SizedBox(width: 8),
                  _rozet('Netlik', _netlikPuani),
                  const SizedBox(width: 8),
                  _rozet('Toplam', toplamPuan),
                ],
              ),
            ),
            Positioned(
              top: 52,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'ham: parlaklık ${_hamParlaklik.toStringAsFixed(0)} · netlik ${_hamNetlik.toStringAsFixed(1)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
            if (_sonFoto != null)
              Positioned(
                left: 16,
                bottom: 32,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(_sonFoto!),
                      width: 70, height: 70, fit: BoxFit.cover),
                ),
              ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _cek,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: Colors.grey, width: 4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
