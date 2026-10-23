import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as imglib;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

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

  // An / ruh hali okuma
  Map<String, int> _kategoriler = {};
  String? _baskin;
  int _baskinPuan = 0;
  String _hamYuz = '';
  bool _kollarYukari = false;

  // Poz (iskelet) analizi ve el kaldırma jesti
  final PoseDetector _pozDedektoru = PoseDetector(
    options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
  );
  bool _pozIsleniyor = false;
  Pose? _poz;
  Size _resimBoyutu = Size.zero;
  bool _iskeletGoster = false; // iskelet + el jesti modu
  int _elSayac = 0;
  int _geriSayim = 0;
  Timer? _geriSayimZamanlayici;

  // Otomatik çekim
  static const int esik = 80;
  static const int gerekenArdisik = 3;
  bool _otomatik = false;
  int _iyiSayac = 0;

  // Zirve yakalama: son ~1.5 saniyenin kareleri hafızada tutulur
  final List<_Kare> _tampon = [];
  static const int tamponBoyu = 8;
  DateTime? _zirveBaslangic;
  int _zirvePuan = 0;
  bool _kaydediliyor = false;
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
      _poz = null;
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
    _pozDedektoru.close();
    _geriSayimZamanlayici?.cancel();
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
      final yuzler = List<Face>.from(await _yuzDedektoru.processImage(girdi));
      // En büyük (kameraya en yakın) yüzler önce
      yuzler.sort((x, y) => y.boundingBox.width.compareTo(x.boundingBox.width));

      int? enDusuk;
      bool kapali = false;
      int gulenSayisi = 0;
      for (final y in yuzler) {
        final sol = y.leftEyeOpenProbability ?? 0.5;
        final sag = y.rightEyeOpenProbability ?? 0.5;
        final goz = sol < sag ? sol : sag;
        final gulus = y.smilingProbability ?? 0.5;
        if (goz < 0.4) kapali = true;
        if (gulus > 0.6) gulenSayisi++;
        final p = (goz * 60 + gulus * 40).round();
        if (enDusuk == null || p < enDusuk) enDusuk = p;
      }

      double kirp(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
      final kat = <String, int>{};
      String ham = '';
      if (yuzler.isNotEmpty) {
        final a = yuzler.first;
        final s = a.smilingProbability ?? 0.0;
        final gl = a.leftEyeOpenProbability ?? 0.5;
        final gr = a.rightEyeOpenProbability ?? 0.5;
        final g = gl < gr ? gl : gr;
        final yaw = (a.headEulerAngleY ?? 0).abs(); // sağa-sola dönüş
        final egim = a.headEulerAngleX ?? 0; // + yukarı, - aşağı
        final sabit = _sabitlikPuani / 100.0;

        // Eğlenceli: gülüş, kollar havada, birden fazla gülen kişi
        double e = s * 0.75 +
            (_kollarYukari ? 0.2 : 0) +
            (gulenSayisi >= 2 ? 0.15 : 0);
        if (g < 0.3) e *= 0.7;
        kat['Eğlenceli'] = (kirp(e) * 100).round();

        // Karizmatik: kameraya değil yana bakış (~30°), sakin ifade, hareketsiz
        final bakis = kirp(1 - (yaw - 30).abs() / 25);
        double k = bakis * 0.45 + kirp(1 - s * 1.5) * 0.25 + sabit * 0.3;
        if (g < 0.4) k *= 0.5;
        kat['Karizmatik'] = (kirp(k) * 100).round();

        // Düşünceli / hüzünlü: baş öne eğik, gülüş yok, hareketsiz
        final egik = kirp((-egim - 5) / 20);
        final d = egik * 0.5 + kirp(1 - s * 2) * 0.3 + sabit * 0.2;
        kat['Düşünceli'] = (kirp(d) * 100).round();

        // Samimi: iki yüz birbirine yakın, gülümsüyor, birbirine dönük
        if (yuzler.length >= 2) {
          final b2 = yuzler[1];
          final r1 = a.boundingBox;
          final r2 = b2.boundingBox;
          final mesafe =
              (r1.center - r2.center).distance / ((r1.width + r2.width) / 2);
          final yakin = kirp((3.0 - mesafe) / 2.0);
          final s2 = b2.smilingProbability ?? 0.0;
          final donuk =
              ((b2.headEulerAngleY ?? 0).abs() > 15 && yaw > 15) ? 1.0 : 0.0;
          final sm = yakin * 0.5 + ((s + s2) / 2) * 0.3 + donuk * 0.2;
          kat['Samimi'] = (kirp(sm) * 100).round();
        }

        ham = 'dönüş ${yaw.toStringAsFixed(0)}° · eğim ${egim.toStringAsFixed(0)}° · gülüş ${(s * 100).round()} · göz ${(g * 100).round()}';
      }

      String? baskin;
      int baskinPuan = 0;
      for (final g in kat.entries) {
        if (g.value > baskinPuan) {
          baskin = g.key;
          baskinPuan = g.value;
        }
      }

      if (mounted) {
        setState(() {
          _yuzSayisi = yuzler.length;
          _yuzPuani = enDusuk;
          _gozKapali = kapali;
          _kategoriler = kat;
          _baskin = baskin;
          _baskinPuan = baskinPuan;
          _hamYuz = ham;
          if (_yuzHata.startsWith('PlatformException')) _yuzHata = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _yuzHata = e.toString());
    } finally {
      _yuzIsleniyor = false;
    }
  }

  Future<void> _pozAnaliz(CameraImage img) async {
    final girdi = _girdiOlustur(img);
    if (girdi == null) return;
    _pozIsleniyor = true;
    try {
      final pozlar = await _pozDedektoru.processImage(girdi);
      final poz = pozlar.isNotEmpty ? pozlar.first : null;
      final dikey = kameralar[_kameraIndex].sensorOrientation % 180 != 0;
      final boyut = dikey
          ? Size(img.height.toDouble(), img.width.toDouble())
          : Size(img.width.toDouble(), img.height.toDouble());

      // El kaldırma jesti: bilek burnun üstündeyse
      bool elYukarida = false;
      if (poz != null) {
        final burun = poz.landmarks[PoseLandmarkType.nose];
        for (final t in [
          PoseLandmarkType.leftWrist,
          PoseLandmarkType.rightWrist
        ]) {
          final bilek = poz.landmarks[t];
          if (burun != null &&
              bilek != null &&
              burun.likelihood > 0.5 &&
              bilek.likelihood > 0.5 &&
              bilek.y < burun.y) {
            elYukarida = true;
          }
        }
      }
      // Kollar havada mı? (bilek aynı taraftaki omzun üstünde)
      bool kollar = false;
      if (poz != null) {
        for (final c in [
          [PoseLandmarkType.leftWrist, PoseLandmarkType.leftShoulder],
          [PoseLandmarkType.rightWrist, PoseLandmarkType.rightShoulder],
        ]) {
          final bilek = poz.landmarks[c[0]];
          final omuz = poz.landmarks[c[1]];
          if (bilek != null &&
              omuz != null &&
              bilek.likelihood > 0.5 &&
              omuz.likelihood > 0.5 &&
              bilek.y < omuz.y) {
            kollar = true;
          }
        }
      }
      _kollarYukari = kollar;

      if (elYukarida && _iskeletGoster) {
        _elSayac++;
      } else {
        _elSayac = 0;
      }
      if (_elSayac >= 2 && _geriSayim == 0 && !_cekiliyor) {
        _elSayac = 0;
        _geriSayimBaslat();
      }
      if (mounted) {
        setState(() {
          _poz = poz;
          _resimBoyutu = boyut;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _yuzHata = 'poz: $e');
    } finally {
      _pozIsleniyor = false;
    }
  }

  void _geriSayimBaslat() {
    if (!mounted) return;
    setState(() => _geriSayim = 3);
    _geriSayimZamanlayici?.cancel();
    _geriSayimZamanlayici =
        Timer.periodic(const Duration(seconds: 1), (zamanlayici) {
      if (!mounted) {
        zamanlayici.cancel();
        return;
      }
      if (_geriSayim <= 1) {
        zamanlayici.cancel();
        setState(() => _geriSayim = 0);
        _cek();
      } else {
        setState(() => _geriSayim--);
      }
    });
  }

  // Her 5 karede bir ışık, netlik ve sabitlik ölçer; 10 karede bir yüz ve poz arar.
  void _analiz(CameraImage img) {
    _kareSayaci++;
    if (_kareSayaci % 10 == 0 && !_yuzIsleniyor) {
      _yuzAnaliz(img);
    }
    if (_kareSayaci % 10 == 5 && !_pozIsleniyor) {
      _pozAnaliz(img);
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
      // Kadrajda insan varsa anın gücü (en baskın ruh hali) hesaba katılır
      if (_yuzSayisi > 0 && _baskin != null) {
        t = t * 0.5 + _baskinPuan * 0.5;
     
