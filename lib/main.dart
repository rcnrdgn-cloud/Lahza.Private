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
        if (_gozKapali && _baskin != 'Düşünceli' && t > 50) t = 50.0;
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

      // Kareyi puanıyla birlikte hafızaya al (zirve seçimi için)
      final tr = t.round();
      if (_otomatik && img.planes.length >= 3) {
        _tampon.add(_Kare(
          y: Uint8List.fromList(img.planes[0].bytes),
          u: Uint8List.fromList(img.planes[1].bytes),
          v: Uint8List.fromList(img.planes[2].bytes),
          genislik: w,
          yukseklik: h,
          ySatir: img.planes[0].bytesPerRow,
          uvSatir: img.planes[1].bytesPerRow,
          uvAdim: img.planes[1].bytesPerPixel ?? 1,
          puan: tr,
          kategori: (_yuzSayisi > 0 && _baskin != null && _baskinPuan >= 60)
              ? _baskin
              : null,
        ));
        if (_tampon.length > tamponBoyu) _tampon.removeAt(0);
      }

      // Otomatik çekim: eşik aşılınca zirveyi izle, düşüşe geçince en iyi kareyi kaydet
      if (_otomatik && !_cekiliyor && !_kaydediliyor && _geriSayim == 0) {
        final simdi = DateTime.now();
        final bekleme = simdi.difference(_sonCekim).inMilliseconds;
        if (bekleme > 3000) {
          if (tr >= esik) {
            _zirveBaslangic ??= simdi;
            if (tr > _zirvePuan) _zirvePuan = tr;
            final sure = simdi.difference(_zirveBaslangic!).inMilliseconds;
            if (tr <= _zirvePuan - 8 || sure > 1500) _zirveKaydet();
          } else if (_zirveBaslangic != null) {
            _zirveKaydet();
          }
        }
      }
    } finally {
      _isleniyor = false;
    }
  }

  // Hafızadaki en yüksek puanlı kareyi JPEG'e çevirip galeriye kaydeder.
  Future<void> _zirveKaydet() async {
    _zirveBaslangic = null;
    _zirvePuan = 0;
    if (_tampon.isEmpty || _kaydediliyor) return;
    _kaydediliyor = true;
    _sonCekim = DateTime.now();
    var enIyi = _tampon.first;
    for (final k in _tampon) {
      if (k.puan > enIyi.puan) enIyi = k;
    }
    _tampon.clear();
    setState(() {
      _cekimSayisi++;
      _flas = true;
    });
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _flas = false);
    });
    try {
      final sonuc = await compute(kareyiJpegYap, {
        'y': enIyi.y,
        'u': enIyi.u,
        'v': enIyi.v,
        'w': enIyi.genislik,
        'h': enIyi.yukseklik,
        'ySatir': enIyi.ySatir,
        'uvSatir': enIyi.uvSatir,
        'uvAdim': enIyi.uvAdim,
        'donus': kameralar[_kameraIndex].sensorOrientation,
        'kategori': enIyi.kategori,
      });
      final jpeg = sonuc[0];
      if (!await Gal.hasAccess()) {
        await Gal.requestAccess();
      }
      // Orijinal her zaman 'Lahza' albümüne, efektli kopya kategori albümüne
      await Gal.putImageBytes(jpeg, album: 'Lahza');
      if (sonuc.length > 1 && enIyi.kategori != null) {
        await Gal.putImageBytes(sonuc[1], album: 'Lahza - ${enIyi.kategori}');
      }
      final dosya = File(
          '${Directory.systemTemp.path}/lahza_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await dosya.writeAsBytes(jpeg);
      if (mounted) setState(() => _sonFoto = dosya.path);
    } catch (e) {
      if (mounted) setState(() => _yuzHata = 'kayıt: $e');
    } finally {
      _kaydediliyor = false;
    }
  }

  Future<void> _cek() async {
    final kontrol = _kontrol;
    if (_cekiliyor || kontrol == null) return;
    _cekiliyor = true;
    final kategori = (_yuzSayisi > 0 && _baskin != null && _baskinPuan >= 60)
        ? _baskin
        : null;
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
        if (kategori != null) {
          final efektli = await compute(
              dosyayaEfektUygula, {'yol': foto.path, 'kategori': kategori});
          if (efektli != null) {
            await Gal.putImageBytes(efektli, album: 'Lahza - $kategori');
          }
        }
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
    final Widget yuzRozeti;
    if (!_yuzDestekli) {
      yuzRozeti = _griRozet('Yüz analizi yok');
    } else if (_yuzSayisi == 0) {
      yuzRozeti = _griRozet('Yüz yok');
    } else if (_gozKapali && _baskin != 'Düşünceli') {
      yuzRozeti = _rozet('Göz kapalı', 0);
    } else {
      yuzRozeti = _rozet(_baskin ?? 'Yüz $_yuzSayisi', _baskinPuan);
    }
    String kisalt(String ad) => ad.substring(0, 1);
    final katSatiri = _kategoriler.entries
        .map((e) => '${kisalt(e.key)} ${e.value}')
        .join(' · ');
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: CameraPreview(
                kontrol,
                child: (_iskeletGoster && _poz != null)
                    ? CustomPaint(
                        painter: IskeletCizer(
                          _poz!,
                          _resimBoyutu,
                          kameralar[_kameraIndex].lensDirection ==
                              CameraLensDirection.front,
                        ),
                      )
                    : null,
              ),
            ),
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
                  if (_yuzSayisi > 0)
                    Text(
                      '$_hamYuz\n$katSatiri',
                      textAlign: TextAlign.center,
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
                  _tampon.clear();
                  _zirveBaslangic = null;
                  _zirvePuan = 0;
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
              right: 20,
              bottom: 188,
              child: _yuvarlakDugme(
                renk: _iskeletGoster ? Colors.green : Colors.black54,
                onTap: () => setState(() => _iskeletGoster = !_iskeletGoster),
                icerik: const Icon(Icons.accessibility_new,
                    color: Colors.white, size: 28),
              ),
            ),
            Positioned(
              bottom: 110,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    'Çekilen: $_cekimSayisi',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  if (_zirveBaslangic != null)
                    const Text(
                      '● Zirve izleniyor',
                      style: TextStyle(color: Color(0xFFF2A33A), fontSize: 12),
                    ),
                  if (_iskeletGoster)
                    const Text(
                      'Poz modu: elini başının üstüne kaldır, 3 sn sonra çeker',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                ],
              ),
            ),
            if (_geriSayim > 0)
              Center(
                child: Text(
                  '$_geriSayim',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 120,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(blurRadius: 12, color: Colors.black)],
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

// Vücut iskeletini kamera görüntüsünün üzerine çizer.
class IskeletCizer extends CustomPainter {
  final Pose poz;
  final Size resim;
  final bool ayna;
  IskeletCizer(this.poz, this.resim, this.ayna);

  static const List<List<PoseLandmarkType>> baglar = [
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow],
    [PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist],
    [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow],
    [PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist],
    [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip],
    [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip],
    [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
    [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee],
    [PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
    [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee],
    [PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (resim.width == 0 || resim.height == 0) return;
    final sx = size.width / resim.width;
    final sy = size.height / resim.height;
    Offset? nokta(PoseLandmarkType t) {
      final l = poz.landmarks[t];
      if (l == null || l.likelihood < 0.5) return null;
      final x = l.x * sx;
      return Offset(ayna ? size.width - x : x, l.y * sy);
    }

    final cizgi = Paint()
      ..color = const Color(0xFFF2A33A)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final daire = Paint()..color = Colors.white;
    for (final b in baglar) {
      final a = nokta(b[0]);
      final c = nokta(b[1]);
      if (a != null && c != null) canvas.drawLine(a, c, cizgi);
    }
    for (final t in PoseLandmarkType.values) {
      final p = nokta(t);
      if (p != null) canvas.drawCircle(p, 4, daire);
    }
  }

  @override
  bool shouldRepaint(covariant IskeletCizer eski) => true;
}

// Hafızada tutulan tek bir kamera karesi ve puanı
class _Kare {
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int genislik;
  final int yukseklik;
  final int ySatir;
  final int uvSatir;
  final int uvAdim;
  final int puan;
  final String? kategori;
  _Kare({
    required this.y,
    required this.u,
    required this.v,
    required this.genislik,
    required this.yukseklik,
    required this.ySatir,
    required this.uvSatir,
    required this.uvAdim,
    required this.puan,
    required this.kategori,
  });
}

// YUV420 kareyi döndürülmüş JPEG'e çevirir (arka planda, ayrı iş parçacığında çalışır).
List<Uint8List> kareyiJpegYap(Map<String, dynamic> v) {
  final Uint8List yb = v['y'];
  final Uint8List ub = v['u'];
  final Uint8List vb = v['v'];
  final int w = v['w'];
  final int h = v['h'];
  final int ySatir = v['ySatir'];
  final int uvSatir = v['uvSatir'];
  final int uvAdim = v['uvAdim'];
  final int donus = v['donus'];
  final String? kategori = v['kategori'];
  final im = imglib.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    final yo = y * ySatir;
    final uo = (y >> 1) * uvSatir;
    for (int x = 0; x < w; x++) {
      final yy = yb[yo + x];
      final ui = uo + (x >> 1) * uvAdim;
      final uu = ub[ui] - 128;
      final vv = vb[ui] - 128;
      int r = yy + ((1436 * vv) >> 10);
      int g = yy - ((352 * uu + 731 * vv) >> 10);
      int b = yy + ((1815 * uu) >> 10);
      r = r < 0 ? 0 : (r > 255 ? 255 : r);
      g = g < 0 ? 0 : (g > 255 ? 255 : g);
      b = b < 0 ? 0 : (b > 255 ? 255 : b);
      im.setPixelRgb(x, y, r, g, b);
    }
  }
  final sonuc = donus == 0 ? im : imglib.copyRotate(im, angle: donus);
  final orijinal = Uint8List.fromList(imglib.encodeJpg(sonuc, quality: 92));
  if (kategori == null) return [orijinal];
  final efektli = efektUygula(sonuc, kategori);
  return [orijinal, Uint8List.fromList(imglib.encodeJpg(efektli, quality: 92))];
}

// Tam çözünürlüklü bir fotoğraf dosyasına kategori efektini uygular.
Uint8List? dosyayaEfektUygula(Map<String, dynamic> v) {
  final String yol = v['yol'];
  final String kategori = v['kategori'];
  final veri = File(yol).readAsBytesSync();
  final im = imglib.decodeJpg(veri);
  if (im == null) return null;
  final duz = imglib.bakeOrientation(im);
  final efektli = efektUygula(duz, kategori);
  return Uint8List.fromList(imglib.encodeJpg(efektli, quality: 92));
}

// Her ruh haline uygun görünüm. (Görüntüyü yerinde değiştirir.)
imglib.Image efektUygula(imglib.Image im, String kategori) {
  switch (kategori) {
    case 'Karizmatik':
      // Siyah-beyaz, yüksek kontrast, kenarları karartılmış
      imglib.grayscale(im);
      imglib.adjustColor(im, contrast: 1.35, gamma: 0.95);
      imglib.vignette(im, start: 0.35, end: 0.95, amount: 0.7);
      return im;
    case 'Eğlenceli':
      // Canlı ve sıcak renkler
      imglib.adjustColor(im, saturation: 1.3, contrast: 1.1, brightness: 1.05);
      imglib.colorOffset(im, red: 8, blue: -6);
      return im;
    case 'Düşünceli':
      // Soluk, serin tonlar, yumuşak kenar karartma
      imglib.adjustColor(im, saturation: 0.55, contrast: 0.92, brightness: 0.97);
      imglib.colorOffset(im, red: -6, blue: 8);
      imglib.vignette(im, start: 0.4, end: 1.0, amount: 0.5);
      return im;
    case 'Samimi':
      // Sıcak, yumuşak, hafif pembe-altın tonlar
      imglib.adjustColor(im, saturation: 1.1, contrast: 0.95, brightness: 1.06);
      imglib.colorOffset(im, red: 12, green: 4, blue: -8);
      return im;
  }
  return im;
}
