import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

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
  int _kameraIndex = 0;
  String? _sonFoto;
  String? _hata;
  bool _cekiliyor = false;
  bool _isleniyor = false;
  bool _degisiyor = false;
  int _kareSayaci = 0;
  Uint8List? _oncekiKare;

  // Görüntü puanları
  int _isikPuani = 0;
  int _netlikPuani = 0;
  int _sabitlikPuani = 0;
  int _toplamPuan = 0;
  double _hamParlaklik = 0;
  double _hamNetlik = 0;
  double _hamHareket = 0;

  // Yüz analizi
  final FaceDetector _yuzDedektoru = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  bool _yuzIsleniyor = false;
  bool _yuzDestekli = true;
  int _yuzSayisi = 0;
  int? _yuzPuani;
  bool _gozKapali = false;
  String _yuzHata = '';

  // Otomatik çekim
  static const int esik = 80;
  static const int gerekenArdisik = 3;
  bool _otomatik = false;
  int _iyiSayac = 0;
  int _cekimSayisi = 0;
  DateTime _sonCekim = DateTime(2000);
  bool _flas = false;

  @override
  void initState() {
    super.initState();
    _kameraBaslat(0);
  }

  Future<void> _kameraBaslat(int index) async {
    final kontrol = CameraController(
      kameralar[index],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await kontrol.initialize();
      if (!mounted) return;
      _kontrol = kontrol;
      _kameraIndex = index;
      _oncekiKare = null;
      _yuzSayisi = 0;
      _yuzPuani = null;
      await kontrol.startImageStream(_analiz);
      setState(() {});
    } catch (e) {
      setState(() => _hata = 'Kamera açılamadı: $e');
    }
  }

  Future<void> _kameraDegistir() async {
    if (kameralar.length < 2 || _degisiyor || _cekiliyor) return;
    _degisiyor = true;
    final eski = _kontrol;
    setState(() => _kontrol = null);
    try {
      await eski?.stopImageStream();
    } catch (_) {}
    await eski?.dispose();
    await _kameraBaslat((_kameraIndex + 1) % kameralar.length);
    _degisiyor = false;
  }

  @override
  void dispose() {
    _kontrol?.dispose();
    _yuzDedektoru.close();
    super.dispose();
  }

  // Kamera karesini (YUV420, 3 düzlem) ML Kit'in istediği NV21 biçimine çevirir.
  Uint8List? _nv21Yap(CameraImage img) {
    if (img.planes.length < 3) return null;
    final w = img.width;
    final h = img.height;
    final out = Uint8List(w * h + (w ~/ 2) * (h ~/ 2) * 2);
    final yP = img.planes[0];
    int i = 0;
    for (int y = 0; y < h; y++) {
      out.setRange(i, i + w, yP.bytes, y * yP.bytesPerRow);
      i += w;
    }
    final uP = img.planes[1];
    final vP = img.planes[2];
    final satir = uP.bytesPerRow;
    final adim = uP.bytesPerPixel ?? 1;
    for (int y = 0; y < h ~/ 2; y++) {
      for (int x = 0; x < w ~/ 2; x++) {
        final idx = y * satir + x * adim;
        out[i++] = vP.bytes[idx];
        out[i++] = uP.bytes[idx];
      }
    }
    return out;
  }

  InputImage? _girdiOlustur(CameraImage img) {
    final rotasyon = InputImageRotationValue.fromRawValue(
        kameralar[_kameraIndex].sensorOrientation);
    if (rotasyon == null) return null;
    final veri = _nv21Yap(img);
    if (veri == null) return null;
    return InputImage.fromBytes(
      bytes: veri,
      metadata: InputImageMetadata(
        size: Size(img.width.toDouble(), img.height.toDouble()),
        rotation: rotasyon,
        format: InputImageFormat.nv21,
        bytesPerRow: img.width,
      ),
    );
  }

  Future<void> _yuzAnaliz(CameraImage img) async {
    final girdi = _girdiOlustur(img);
    if (girdi == null) {
      _yuzDestekli = false;
      return;
    }
    _yuzIsleniyor = true;
    try {
      final yuzler = await _yuzDedektoru.processImage(girdi);
      int? enDusuk;
      bool kapali = false;
      for (final y in yuzler) {
        final sol = y.leftEyeOpenProbability ?? 0.5;
        final sag = y.rightEyeOpenProbability ?? 0.5;
        final goz = sol < sag ? sol : sag;
        final gulus = y.smilingProbability ?? 0.5;
        if (goz < 0.4) kapali = true;
        final p = (goz * 60 + gulus * 40).round();
        if (enDusuk == null || p < enDusuk) enDusuk = p;
      }
      if (mounted) {
        setState(() {
          _yuzSayisi = yuzler.length;
          _yuzPuani = enDusuk;
          _gozKapali = kapali;
        });
      }
      if (_yuzHata.isNotEmpty && mounted) setState(() => _yuzHata = '');
    } catch (e) {
      if (mounted) setState(() => _yuzHata = e.toString());
    } finally {
      _yuzIsleniyor = false;
    }
  }

  // Her 5 karede bir ışık, netlik ve sabitlik ölçer; 10 karede bir yüz arar.
  void _analiz(CameraImage img) {
    _kareSayaci++;
    if (_kareSayaci % 10 == 0 && !_yuzIsleniyor) {
      _yuzAnaliz(img);
    }
    if (_isleniyor || _kareSayaci % 5 != 0) return;
    _isleniyor = true;
    try {
      final plane = img.planes[0];
      final b = plane.bytes;
      final satir = plane.bytesPerRow;
      final w = img.width;
      final h = img.height;

      // 1) Parlaklık + hareket için küçük örnek
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

      // 2) Hareket
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

      // 3) Netlik: merkez bölge
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

      // Puanlar
      final isik =
          (100 - ((parlaklik - 130).abs() / 130 * 100)).clamp(0, 100).round();
      final net = (netlik / 8 * 100).clamp(0, 100).round();
      final sabit = (100 - (hareket - 2) * 8).clamp(0, 100).round();
      double t = isik * 0.3 + net * 0.3 + sabit * 0.4;
      if (sabit < 50) t = t * 0.5;

      // Kadrajda insan varsa yüz puanı da hesaba katılır
      final yp = _yuzPuani;
      if (_yuzSayisi > 0 && yp != null) {
        t = t * 0.6 + yp * 0.4;
        if (_gozKapali && t > 50) t = 50.0;
      }

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

      // Otomatik çekim kararı
      if (_otomatik && !_cekiliyor) {
        if (t.round() >= esik) {
          _iyiSayac++;
        } else {
          _iyiSayac = 0;
        }
        final bekleme = DateTime.now().difference(_sonCekim).inMilliseconds;
        if (_iyiSayac >= gerekenArdisik && bekleme > 3000) {
          _iyiSayac = 0;
          _cek();
        }
      }
    } finally {
      _isleniyor = false;
    }
  }

  Future<void> _cek() async {
    final kontrol = _kontrol;
    if (_cekiliyor || kontrol == null) return;
    _cekiliyor = true;
    try {
      await kontrol.stopImageStream();
      final foto = await kontrol.takePicture();
      _sonCekim = DateTime.now();
      setState(() {
        _sonFoto = foto.path;
        _cekimSayisi++;
        _flas = true;
      });
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _flas = false);
      });
      try {
        if (!await Gal.hasAccess()) {
          await Gal.requestAccess();
        }
        await Gal.putImage(foto.path, album: 'Lahza');
      } catch (_) {}
      _oncekiKare = null;
      await kontrol.startImageStream(_analiz);
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

  Widget _griRozet(String yazi) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        yazi,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }

  Widget _yuvarlakDugme({
    required Widget icerik,
    required VoidCallback onTap,
    Color renk = Colors.black54,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: renk,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: icerik,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_hata != null) {
      return Scaffold(body: Center(child: Text(_hata!)));
    }
    final kontrol = _kontrol;
    if (kontrol == null || !kontrol.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final yuzRozeti = !_yuzDestekli
        ? _griRozet('Yüz analizi yok')
        : (_yuzSayisi > 0
            ? _rozet(_gozKapali ? 'Göz kapalı' : 'Yüz $_yuzSayisi',
                _yuzPuani ?? 0)
            : _griRozet('Yüz yok'));
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(child: CameraPreview(kontrol)),
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
                      yuzRozeti,
                      _rozet('Toplam', _toplamPuan),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ham: parlaklık ${_hamParlaklik.toStringAsFixed(0)} · netlik ${_hamNetlik.toStringAsFixed(1)} · hareket ${_hamHareket.toStringAsFixed(1)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (_yuzHata.isNotEmpty)
                    Text(
                      'yüz hatası: $_yuzHata',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
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
              right: 20,
              bottom: 36,
              child: _yuvarlakDugme(
                renk: _otomatik ? Colors.green : Colors.black54,
                onTap: () => setState(() {
                  _otomatik = !_otomatik;
                  _iyiSayac = 0;
                }),
                icerik: Text(
                  _otomatik ? 'OTO\nAÇIK' : 'OTO\nKAPALI',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (kameralar.length > 1)
              Positioned(
                right: 20,
                bottom: 112,
                child: _yuvarlakDugme(
                  onTap: _kameraDegistir,
                  icerik: const Icon(Icons.cameraswitch,
                      color: Colors.white, size: 28),
                ),
              ),
            Positioned(
              bottom: 110,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'Çekilen: $_cekimSayisi',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            if (_flas)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: Colors.white70),
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
