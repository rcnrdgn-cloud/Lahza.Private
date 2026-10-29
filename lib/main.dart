import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as imglib;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

late List<CameraDescription> kameralar;

// Kapalı/kırpılmış gözün kusur sayılmadığı ruh halleri
const Set<String> gozKapaliOlabilir = {'Gizemli', 'Komik', 'Muzip'};

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
      enableContours: true,
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
  bool _tamBoy = false;
  List<String> _teknik = [];

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
      double enBuyuk(double x, double y) => x > y ? x : y;
      final kat = <String, int>{};
      final teknik = <String>[];
      String ham = '';
      if (yuzler.isNotEmpty) {
        final a = yuzler.first;
        final n = yuzler.length;
        final s = a.smilingProbability ?? 0.0;
        final gl = a.leftEyeOpenProbability ?? 0.5;
        final gr = a.rightEyeOpenProbability ?? 0.5;
        final g = gl < gr ? gl : gr;
        final yaw = (a.headEulerAngleY ?? 0).abs(); // sağa-sola dönüş
        final egim = a.headEulerAngleX ?? 0; // + yukarı, - aşağı
        final yatik = (a.headEulerAngleZ ?? 0).abs(); // başın yana yatıklığı
        final sabit = _sabitlikPuani / 100.0;
        final hareket = kirp((_hamHareket - 3) / 8); // orta-yüksek hareket = canlılık
        final kollar = _kollarYukari ? 1.0 : 0.0;

        // Ağız açıklığı (yüz hatlarından): kahkaha veya şaşkınlık işareti
        double agiz = 0;
        final ust = a.contours[FaceContourType.upperLipBottom];
        final alt = a.contours[FaceContourType.lowerLipTop];
        if (ust != null &&
            alt != null &&
            ust.points.isNotEmpty &&
            alt.points.isNotEmpty) {
          final u = ust.points[ust.points.length ~/ 2];
          final l = alt.points[alt.points.length ~/ 2];
          agiz = kirp(((l.y - u.y).abs() / a.boundingBox.height) / 0.12);
        }

        // Çarpık gülüş: ağız köşelerinden biri diğerinden belirgin yukarıda
        double carpik = 0;
        final dudak = a.contours[FaceContourType.upperLipTop];
        if (dudak != null && dudak.points.length >= 2) {
          final k1 = dudak.points.first;
          final k2 = dudak.points.last;
          carpik = kirp(((k1.y - k2.y).abs() / a.boundingBox.height) / 0.05);
        }
        // Göz kırpma: bir göz açık, diğeri kapalı
        final kirpma = kirp(((gl - gr).abs() - 0.3) / 0.4);
        final abartiliEgim = kirp((yatik - 12) / 18);

        // NEŞELİ: içten gülümseme, gözlerde mutluluk
        double nese = s * 0.7 + g * 0.15 + agiz * s * 0.15;
        if (g < 0.3) nese *= 0.7;
        kat['Neşeli'] = (kirp(nese) * 100).round();

        // EĞLENCELİ: sosyal etkileşim, kahkaha, kollar havada
        final gulenOrani = (gulenSayisi > 3 ? 3 : gulenSayisi) / 3;
        final eglence = (n >= 2 ? 0.25 : 0.0) +
            gulenOrani * 0.25 +
            agiz * s * 0.25 +
            kollar * 0.15 +
            hareket * 0.1;
        kat['Eğlenceli'] = (kirp(eglence) * 100).round();

        // ENERJİK: hareket, canlı beden dili
        final enerji = hareket * 0.5 + kollar * 0.3 + agiz * 0.1 + s * 0.1;
        kat['Enerjik'] = (kirp(enerji) * 100).round();

        // KARİZMATİK: kendinden emin bakış, düz duruş, kontrollü ifade
        final bakis = enBuyuk(kirp(1 - (yaw - 25).abs() / 20), yaw < 8 ? 0.6 : 0.0);
        final sakin = kirp(1 - (s - 0.2).abs() * 2.5);
        final duz = kirp(1 - yatik / 20);
        double karizma =
            bakis * 0.3 + sakin * 0.2 + duz * 0.15 + sabit * 0.2 + g * 0.15;
        if (g < 0.4) karizma *= 0.5;
        kat['Karizmatik'] = (kirp(karizma) * 100).round();

        // GİZEMLİ / CİDDİ: dolaylı bakış, minimal mimik, dramatik ışık
        final ciddi = kirp(1 - s * 2);
        final dolayli = kirp(enBuyuk(yaw - 12, -egim - 6) / 20);
        final karanlik = kirp((150 - _hamParlaklik) / 80);
        final gizem =
            ciddi * 0.35 + dolayli * 0.35 + sabit * 0.15 + karanlik * 0.15;
        kat['Gizemli'] = (kirp(gizem) * 100).round();

        // SAMİMİ: yakınlık, sıcak etkileşim, doğal gülümseme
        double samimi;
        if (n >= 2) {
          final b2 = yuzler[1];
          final r1 = a.boundingBox;
          final r2 = b2.boundingBox;
          final mesafe =
              (r1.center - r2.center).distance / ((r1.width + r2.width) / 2);
          final yakin = kirp((3.0 - mesafe) / 2.0);
          final s2 = b2.smilingProbability ?? 0.0;
          final donuk =
              ((b2.headEulerAngleY ?? 0).abs() > 15 && yaw > 15) ? 1.0 : 0.0;
          samimi = yakin * 0.45 + ((s + s2) / 2) * 0.35 + donuk * 0.2;
        } else {
          // Tek kişide: yumuşak, doğal tebessüm
          samimi = kirp(1 - (s - 0.5).abs() * 3) * 0.55;
        }
        kat['Samimi'] = (kirp(samimi) * 100).round();

        // ŞAŞKIN: ağız açık ama gülüş yok, gözler açık
        final saskin = agiz * kirp(1 - s * 2) * (g > 0.8 ? 1.0 : 0.6);
        kat['Şaşkın'] = (kirp(saskin) * 100).round();

        // KOMİK: abartılı ifade — kahkaha, göz kırpma, uçuk baş açısı, şaşkın surat
        // En güçlü tek abartı işareti yeterli; kahkaha ve kollar üstüne eklenir.
        final abarti = enBuyuk(kirpma, enBuyuk(abartiliEgim, saskin));
        final komik = abarti * 0.55 + agiz * s * 0.3 + kollar * 0.15;
        kat['Komik'] = (kirp(komik) * 100).round();

        // COOL: zahmetsiz rahatlık — gevşek göz, gülüşsüz/hafif ifade, hafif baş
        // yatıklığı, sakin. Karizmatik'ten farkı: dik ve doğrudan değil, rahat.
        final rahatGoz = kirp(1 - (g - 0.7).abs() * 4);
        final hafifYatik = kirp(1 - (yatik - 10).abs() / 10);
        final yanBakis = kirp(1 - (yaw - 20).abs() / 15);
        final cool = rahatGoz * 0.25 +
            kirp(1 - s * 2.5) * 0.25 +
            hafifYatik * 0.2 +
            sabit * 0.15 +
            yanBakis * 0.15;
        kat['Cool'] = (kirp(cool) * 100).round();

        // MUZİP: şakacı bakış — yarım/çarpık gülüş veya göz kırpma
        final yarimGulus = kirp(1 - (s - 0.55).abs() * 3);
        final muzip = enBuyuk(carpik * yarimGulus, kirpma) * 0.7 +
            yarimGulus * 0.2 +
            hafifYatik * 0.1;
        kat['Muzip'] = (kirp(muzip) * 100).round();

        // Teknik etiketler
        if (kameralar[_kameraIndex].lensDirection == CameraLensDirection.front) {
          teknik.add('Selfie');
        }
        teknik.add(n == 1 ? 'Portre' : (n == 2 ? 'İkili' : 'Grup'));
        final dikey = kameralar[_kameraIndex].sensorOrientation % 180 != 0;
        final kareGenislik = (dikey ? img.height : img.width).toDouble();
        if (a.boundingBox.width / kareGenislik > 0.3) teknik.add('Yakın çekim');
        if (_tamBoy) teknik.add('Tam boy');

        ham = 'dönüş ${yaw.toStringAsFixed(0)}° · eğim ${egim.toStringAsFixed(0)}° · yatık ${yatik.toStringAsFixed(0)}° · gülüş ${(s * 100).round()} · göz ${(g * 100).round()} · ağız ${(agiz * 100).round()} · çarpık ${(carpik * 100).round()}';
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
          _teknik = teknik;
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
      bool tamBoy = false;
      if (poz != null) {
        final sol = poz.landmarks[PoseLandmarkType.leftAnkle];
        final sag = poz.landmarks[PoseLandmarkType.rightAnkle];
        tamBoy = (sol != null && sol.likelihood > 0.5) ||
            (sag != null && sag.likelihood > 0.5);
      }
      _tamBoy = tamBoy;

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
      if (sabit < 50 && _baskin != 'Enerjik') t = t * 0.5;

      // Kadrajda insan varsa yüz puanı da hesaba katılır
      // Kadrajda insan varsa anın gücü (en baskın ruh hali) hesaba katılır
      if (_yuzSayisi > 0 && _baskin != null) {
        t = t * 0.5 + _baskinPuan * 0.5;
        if (_gozKapali && !gozKapaliOlabilir.contains(_baskin) && t > 50) {
          t = 50.0;
        }
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
          etiketler: Map<String, int>.from(_kategoriler),
          teknik: List<String>.from(_teknik),
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

  // Fotoğrafın bir kopyasını ve etiketlerini uygulamanın kendi arşivine yazar
  // (ileride etiketlerle arama yapılabilen arşiv ekranı için).
  Future<void> _arsiveEkle(Uint8List jpeg, Map<String, int> etiketler,
      List<String> teknik, String? anaEtiket) async {
    try {
      final kok = await getApplicationDocumentsDirectory();
      final klasor = Directory('${kok.path}/arsiv');
      if (!await klasor.exists()) await klasor.create(recursive: true);
      final ad = 'lahza_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File('${klasor.path}/$ad').writeAsBytes(jpeg);
      final kayit = jsonEncode({
        'dosya': ad,
        'zaman': DateTime.now().toIso8601String(),
        'ana': anaEtiket,
        'etiketler': etiketler,
        'teknik': teknik,
      });
      await File('${klasor.path}/etiketler.jsonl')
          .writeAsString('$kayit\n', mode: FileMode.append);
    } catch (_) {}
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
      await _arsiveEkle(jpeg, enIyi.etiketler, enIyi.teknik, enIyi.kategori);
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
    final etiketAni = Map<String, int>.from(_kategoriler);
    final teknikAni = List<String>.from(_teknik);
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
        await _arsiveEkle(
            await File(foto.path).readAsBytes(), etiketAni, teknikAni, kategori);
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

  Widget _etiket(String yazi, Color renk) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: renk,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        yazi,
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
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
    } else if (_gozKapali && !gozKapaliOlabilir.contains(_baskin)) {
      yuzRozeti = _rozet('Göz kapalı', 0);
    } else {
      yuzRozeti = _rozet(_baskin ?? 'Yüz $_yuzSayisi', _baskinPuan);
    }
    const kisaltma = {
      'Neşeli': 'Ne',
      'Eğlenceli': 'Eğ',
      'Enerjik': 'En',
      'Karizmatik': 'Ka',
      'Gizemli': 'Gi',
      'Samimi': 'Sa',
      'Şaşkın': 'Şa',
      'Komik': 'Ko',
      'Cool': 'Co',
      'Muzip': 'Mu',
    };
    final katSatiri = _kategoriler.entries
        .map((e) => '${kisaltma[e.key] ?? e.key} ${e.value}')
        .join(' · ');
    // Öne çıkan etiketler (40 ve üstü, en yüksek 3) + teknik etiketler
    final sirali = _kategoriler.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final oneCikan = sirali.where((e) => e.value >= 40).take(3).toList();
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
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final e in oneCikan)
                            _etiket('${e.key} ${e.value}', const Color(0xFFF2A33A)),
                          for (final t in _teknik) _etiket(t, Colors.white24),
                        ],
                      ),
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
  final Map<String, int> etiketler;
  final List<String> teknik;
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
    required this.etiketler,
    required this.teknik,
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

// Değeri 0-255 aralığına sıkıştırır (taşmayı önler).
int _sinirla(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

// Her ruh haline uygun görünüm. Tüm hesaplar piksel piksel ve sınırlandırılarak
// yapılır; böylece koyu bölgeler beyaza, açık bölgeler siyaha "taşmaz".
imglib.Image efektUygula(imglib.Image im, String kategori) {
  bool gri = false;
  double kontrast = 1.0;
  double doygunluk = 1.0;
  double parlaklik = 1.0;
  double dr = 0, dg = 0, db = 0;
  double vBaslangic = 1.0; // kenar karartmanın başladığı mesafe (0-1)
  double vMiktar = 0.0; // kenarda ne kadar kararacağı (0-1)
  double soluk = 0.0; // siyahları kaldırma (mat görünüm), 0-255

  switch (kategori) {
    case 'Karizmatik': // siyah-beyaz, güçlü ama yumuşak kontrast, vinyet
      gri = true;
      kontrast = 1.25;
      vBaslangic = 0.55;
      vMiktar = 0.45;
      break;
    case 'Neşeli': // aydınlık ve sıcak
      doygunluk = 1.2;
      kontrast = 1.05;
      parlaklik = 1.06;
      dr = 8;
      db = -6;
      break;
    case 'Enerjik': // güçlü kontrast, canlı renkler
      doygunluk = 1.25;
      kontrast = 1.2;
      break;
    case 'Gizemli': // karanlık, soluk, serin, belirgin vinyet
      doygunluk = 0.5;
      kontrast = 1.1;
      parlaklik = 0.92;
      dr = -6;
      db = 8;
      vBaslangic = 0.45;
      vMiktar = 0.5;
      break;
    case 'Komik': // pop: çok canlı renkler, belirgin kontrast, hafif sıcak
      doygunluk = 1.45;
      kontrast = 1.15;
      parlaklik = 1.05;
      dr = 6;
      dg = 4;
      db = -6;
      break;
    case 'Cool': // mat ve serin: kaldırılmış siyahlar, hafif soluk, mavi gölge
      doygunluk = 0.85;
      kontrast = 1.08;
      dr = -6;
      db = 10;
      soluk = 22;
      break;
    case 'Muzip': // sıcak, hafif canlı, yumuşak vinyet
      doygunluk = 1.15;
      kontrast = 1.05;
      parlaklik = 1.03;
      dr = 10;
      dg = 2;
      db = -6;
      vBaslangic = 0.65;
      vMiktar = 0.25;
      break;
    case 'Şaşkın': // hafif canlandırma
      doygunluk = 1.15;
      kontrast = 1.05;
      break;
    case 'Eğlenceli': // canlı ve sıcak
      doygunluk = 1.35;
      kontrast = 1.1;
      parlaklik = 1.04;
      dr = 6;
      db = -4;
      break;
    case 'Düşünceli': // soluk, serin, hafif vinyet
      doygunluk = 0.55;
      kontrast = 0.92;
      parlaklik = 0.97;
      dr = -6;
      db = 8;
      vBaslangic = 0.6;
      vMiktar = 0.35;
      break;
    case 'Samimi': // sıcak ve yumuşak
      doygunluk = 1.1;
      kontrast = 0.95;
      parlaklik = 1.05;
      dr = 12;
      dg = 4;
      db = -8;
      break;
    default:
      return im;
  }

  final cx = im.width / 2;
  final cy = im.height / 2;
  final enUzak = math.sqrt(cx * cx + cy * cy);

  for (final p in im) {
    double r = p.r.toDouble() * parlaklik;
    double g = p.g.toDouble() * parlaklik;
    double b = p.b.toDouble() * parlaklik;

    final l = 0.299 * r + 0.587 * g + 0.114 * b;
    if (gri) {
      r = l;
      g = l;
      b = l;
    } else {
      r = l + (r - l) * doygunluk;
      g = l + (g - l) * doygunluk;
      b = l + (b - l) * doygunluk;
    }

    r = (r - 128) * kontrast + 128 + dr;
    g = (g - 128) * kontrast + 128 + dg;
    b = (b - 128) * kontrast + 128 + db;

    if (soluk > 0) {
      final f = 1 - soluk / 255;
      r = soluk + r * f;
      g = soluk + g * f;
      b = soluk + b * f;
    }

    if (vMiktar > 0) {
      final dx = p.x - cx;
      final dy = p.y - cy;
      final d = math.sqrt(dx * dx + dy * dy) / enUzak;
      if (d > vBaslangic) {
        var t = (d - vBaslangic) / (1 - vBaslangic);
        if (t > 1) t = 1;
        final f = 1 - vMiktar * t * t;
        r *= f;
        g *= f;
        b *= f;
      }
    }

    p.r = _sinirla(r);
    p.g = _sinirla(g);
    p.b = _sinirla(b);
  }
  return im;
}
