import 'dart:io';
import 'dart:typed_data';
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
  Uint8List? _oncekiKare;

  int _isikPuani = 0;
  int _netlikPuani = 0;
  int _sabitlikPuani = 0;
  int _toplamPuan = 0;
  double _hamParlaklik = 0;
  double _hamNetlik = 0;
  double _hamHareket = 0;

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

  // Her 5 karede bir ışık, netlik ve sabitlik ölçer.
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

      // 1) Parlaklık + hareket için küçük örnek (tüm kare, 8 pikselde bir)
      final kucuk = Uint8List(((h + 7) ~/ 8) * ((w + 7) ~/ 8));
      int toplam = 0;
      int k = 0;
      for (int y = 0; y < h; y += 8) {
        final o = y * satir;
        for (int x = 0; x < w; x += 8) {
          final v = b[o + x];
          toplam += v;
          kucuk[k++] = v;
        }
      }
      if (k == 0) return;
      final parlaklik = toplam / k;

      // 2) Hareket: önceki örnekle karşılaştır
      double hareket = 0;
      final onceki = _oncekiKare;
      if (onceki != null && onceki.length == kucuk.length) {
        int fark = 0;
        for (int i = 0; i < kucuk.length; i++) {
          fark += (kucuk[i] - onceki[i]).abs();
        }
        hareket = fark / kucuk.length;
      }
      _oncekiKare = kucuk;

      // 3) Netlik: sadece merkez bölge (%60)
      final x0 = (w * 0.2).toInt();
      final x1 = (w * 0.8).toInt();
      final y0 = (h * 0.2).toInt();
      final y1 = (h * 0.8).toInt();
      int kenar = 0;
      int kAdet = 0;
      for (int y = y0; y < y1; y += 4) {
        final o = y * satir;
        for (int x = x0; x < x1; x += 4) {
          final v = b[o + x];
          kenar += (v - b[o + x + 1]).abs() + (v - b[o + satir + x]).abs();
          kAdet++;
        }
      }
      final netlik = kAdet == 0 ? 0.0 : kenar / kAdet;

      // Puanlar (0-100)
      final isik =
          (100 - ((parlaklik - 130).abs() / 130 * 100)).clamp(0, 100).round();
      final net = (netlik / 35 * 100).clamp(0, 100).round();
      final sabit = (100 - (hareket - 2) * 8).clamp(0, 100).round();
      var t = isik * 0.3 + net * 0.3 + sabit * 0.4;
      if (sabit < 50) t = t * 0.5;

      if (mounted) {
        setState(() {
          _isikPuani = isik;
          _netlikPuani = net;
          _sabitlikPuani = sabit;
          _toplamPuan = t.round();
          _hamParlaklik = parlaklik;
          _hamNetlik = netlik;
          _hamHareket = hareket;
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
      _oncekiKare = null;
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: renk.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$ad $puan',
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(child: CameraPreview(_kontrol!)),
            Positioned(
              top: 10,
              left: 8,
              right: 8,
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _rozet('Işık', _isikPuani),
                      _rozet('Netlik', _netlikPuani),
                      _rozet('Sabitlik', _sabitlikPuani),
                      _rozet('Toplam', _toplamPuan),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ham: parlaklık ${_hamParlaklik.toStringAsFixed(0)} · netlik ${_hamNetlik.toStringAsFixed(1)} · hareket ${_hamHareket.toStringAsFixed(1)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
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
