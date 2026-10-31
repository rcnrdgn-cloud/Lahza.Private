import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as imglib;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:audioplayers/audioplayers.dart';

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
  // Uygulama otomatik: elle açılan iskelet/el jesti modu kaldırıldı.
  // Kod geliştirme sırasında teşhis için true yapılabilir.
  static const bool _iskeletGoster = false;
  int _elSayac = 0;
  int _geriSayim = 0;
  Timer? _geriSayimZamanlayici;

  // Otomatik çekim (her zaman açık)
  static const int esik = 75;

  // Zirve yakalama: son ~1.5 saniyenin kareleri hafızada tutulur
  final List<_Kare> _tampon = [];
  static const int tamponBoyu = 8;
  DateTime? _zirveBaslangic;
  int _zirvePuan = 0;
  bool _kaydediliyor = false;
  int _cekimSayisi = 0;
  DateTime _sonCekim = DateTime(2000);
  bool _flas = false;

  // Bu oturumda çekilenler (en yenisi başta); her çekim orijinal + efektli +
  // film sürümleri. Sol alttaki küçük resme dokununca görüntüleyicide açılır.
  final List<List<_Surum>> _cekimler = [];
  bool _gosteriliyor = false; // görüntüleyici açıkken analiz ve otomatik çekim durur

  // Kalibrasyon ayrıntıları (puanlar, ham değerler, etiketler) varsayılan olarak gizli
  // Kalibrasyon ayrıntıları kullanıcıya gösterilmez; teşhis için kodda true
  // yapılabilir (ekranda düğme yok).
  static const bool _ayrinti = false;

  // Fotoğrafçı gözü: kompozisyon, yüzdeki ışık, yüzün netliği, arka plandan
  // ayrışma ve an. Hepsi iyi olduğunda "işte bu" denir.
  Rect? _anaYuz; // en büyük yüz, dik (ekranda görünen) görüntü koordinatlarında
  Size _dikBoyut = Size.zero;
  int _grupUyumu = 100; // gözü açık ve kameraya dönük kişilerin oranı
  double _anaYaw = 0; // ana yüzün sağa-sola dönüşü (derece, mutlak)
  double _anaEgim = 0; // ana yüzün yukarı(+)/aşağı(-) eğimi (derece)
  double _etkilesim = 0; // iki kişi birbirine yakın ve dönük mü (0-1)

  // Ara Güler modu: poz değil hayat, insan yaşadığı yerle birlikte, belgesel
  // siyah-beyaz. Kendini "görsel tarihçi" sayan fotoğrafçının yaklaşımı.
  // Ara Güler gözü kendiliğinden devreye girer (bkz. _yuzAnaliz); ani
  // geçişleri önlemek için birkaç ardışık ölçümle karar verilir.
  bool _guler = false;
  int _gulerSayac = 0;

  // Otomatik zoom: elle zoom yok; uygulama yüzün kadrajdaki büyüklüğüne göre
  // kendisi yaklaşır ve geri açılır.
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;
  double _tabanZoom = 1.0; // normal görüş (1x); ultra geniş açıya inilmez
  bool _zoomAyarlaniyor = false;
  int _yuzAnalizNo = 0; // her yüz analizinde artar
  int _sonZoomAnalizNo = -1; // zoom en son hangi analize göre değişti
  DateTime _sonYuzZamani = DateTime(2000);
  static const double zoomUstSinir = 4.0; // daha fazlası dijitalde çok bozulur

  // Aşama 1: odak/pozlama noktası yüzde; pozlama düzeltmesi çekimlerden
  // öğrenilir ve kamera başına (ön/arka) saklanır.
  Offset? _olcumNoktasi;
  DateTime _sonOlcumZamani = DateTime(2000);
  double _pozDuzeltme = 0; // EV
  double _minPoz = 0;
  double _maxPoz = 0;
  Map<String, dynamic> _ogrenilen = {};

  // Benzer kareleri eleme: "işte bu an" denen kare beklemeden kaydedilir; aynı
  // sahnenin sonraki anları (30 sn içinde) son kaydedilenden belirgin biçimde
  // iyi değilse kaydedilmez. 64 bitten en çok bu kadarı farklıysa benzer.
  // Denemede: aynı sahnede 10px kayma 4, %5 zum 5, 30px kayma 13 bit;
  // farklı sahneler 27 bit ve üstü.
  static const int benzerlikEsigi = 16;
  int? _sonIz; // son kaydedilen karenin parmak izi
  int _sonKayitPuan = 0;
  DateTime _sonKayitZamani = DateTime(2000);
  int _elenen = 0;
  double _egimSapma = 0; // telefonun yataydan sapması (derece)
  StreamSubscription<AccelerometerEvent>? _ivmeAbone;
  // Telefonun dönme hızı (rad/sn, yumuşatılmış). Bulanıklığı yapan şey kameranın
  // dönmesidir; karedeki değişim ise elin yavaş kaymasını da titreme sanır.
  double _titreme = 0;
  DateTime _sonJiro = DateTime(2000);
  StreamSubscription<GyroscopeEvent>? _jiroAbone;
  _Degerlendirme _degerlendirme = _Degerlendirme();

  @override
  void initState() {
    super.initState();
    // Arka kamerayla başla; ön kameraya düğmeyle geçilir
    final arka = kameralar
        .indexWhere((k) => k.lensDirection == CameraLensDirection.back);
    _kameraBaslat(arka < 0 ? 0 : arka);
    _sesHazirla();
    _ivmeAbone = accelerometerEventStream(
            samplingPeriod: SensorInterval.uiInterval)
        .listen((e) {
      final yatay = math.sqrt(e.x * e.x + e.y * e.y);
      if (yatay < 4) return; // telefon yere paralel: eğim anlamsız
      // Dikey ya da yatay tutuşa göre en yakın düz konumdan sapma
      var aci = (math.atan2(e.x, e.y) * 180 / math.pi).abs() % 90;
      if (aci > 45) aci = 90 - aci;
      _egimSapma = _egimSapma * 0.7 + aci * 0.3;
    }, onError: (_) {});
    _jiroAbone = gyroscopeEventStream(
            samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
      final hiz = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      _titreme = _titreme * 0.8 + hiz * 0.2;
      _sonJiro = DateTime.now();
    }, onError: (_) {});
  }

  Future<void> _kameraBaslat(int index) async {
    final kontrol = CameraController(
      kameralar[index],
      ResolutionPreset.veryHigh, // 1080p: zoomlu karede de yeterli ayrıntı
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
      try {
        _minZoom = await kontrol.getMinZoomLevel();
        _maxZoom = await kontrol.getMaxZoomLevel();
      } catch (_) {
        _minZoom = _maxZoom = 1.0;
      }
      _tabanZoom = _aralikta(1.0, _minZoom, _maxZoom);
      _zoom = _tabanZoom;
      _olcumNoktasi = null;
      try {
        _minPoz = await kontrol.getMinExposureOffset();
        _maxPoz = await kontrol.getMaxExposureOffset();
        await _ogrenilenYukle();
        final kayitli = _ogrenilen['poz_${kameralar[index].lensDirection.name}'];
        _pozDuzeltme = kayitli is num ? kayitli.toDouble() : 0.0;
        _pozDuzeltme = _aralikta(_pozDuzeltme, _minPoz, _maxPoz);
        await kontrol.setExposureOffset(_pozDuzeltme);
      } catch (_) {
        _minPoz = _maxPoz = 0;
      }
      await kontrol.startImageStream(_analiz);
      setState(() {});
    } catch (e) {
      setState(() => _hata = 'Kamera açılamadı: $e');
    }
  }

  @override
  void dispose() {
    _kontrol?.dispose();
    _yuzDedektoru.close();
    _pozDedektoru.close();
    _geriSayimZamanlayici?.cancel();
    _ivmeAbone?.cancel();
    _jiroAbone?.cancel();
    _ses.dispose();
    super.dispose();
  }

  // Lahza'nın imza sesi her çekimde çalar: uygulamanın çalıştığını ve
  // fotoğraf çektiğini çevredekiler de duyar. Başka uygulamadaki müziği
  // kesmez (ses odağı almaz).
  final AudioPlayer _ses = AudioPlayer();
  String? _sesDosyasi;

  Future<void> _sesHazirla() async {
    try {
      await _ses.setAudioContext(
          AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers)
              .build());
      final dosya = File('${Directory.systemTemp.path}/lahza_sesi.wav');
      await dosya.writeAsBytes(lahzaSesi());
      _sesDosyasi = dosya.path;
    } catch (_) {}
  }

  void _sesCal() {
    final yol = _sesDosyasi;
    if (yol == null) return;
    _ses.play(DeviceFileSource(yol)).catchError((_) {});
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
    _tampon.clear();
    _sonIz = null; // öbür kameranın sahnesi başka
    await _kameraBaslat((_kameraIndex + 1) % kameralar.length);
    _degisiyor = false;
  }

  // Odak ve pozlama yüze göre: kamera netliği ve ışığı tüm kadraja göre değil,
  // ana yüzün olduğu noktaya göre ayarlar. Yüz belirgin biçimde yer
  // değiştirince (en sık 0,7 sn'de bir) güncellenir; 2 sn yüz yoksa sıfırlanır.
  void _olcumNoktasiGuncelle() {
    final kontrol = _kontrol;
    if (kontrol == null || _cekiliyor) return;
    final simdi = DateTime.now();
    if (simdi.difference(_sonOlcumZamani).inMilliseconds < 700) return;
    final kutu = _anaYuz;
    final gw = _dikBoyut.width;
    final gh = _dikBoyut.height;
    Offset? nokta;
    if (_yuzSayisi > 0 && kutu != null && gw > 0 && gh > 0) {
      var x = kutu.center.dx / gw;
      final y = kutu.center.dy / gh;
      // Ön kamerada önizleme aynalanır; nokta ekrandaki konuma göre verilir
      if (kameralar[_kameraIndex].lensDirection == CameraLensDirection.front) {
        x = 1 - x;
      }
      nokta = Offset(_aralikta(x, 0, 1), _aralikta(y, 0, 1));
      final eski = _olcumNoktasi;
      if (eski != null && (eski - nokta).distance < 0.06) return;
    } else {
      if (_olcumNoktasi == null ||
          simdi.difference(_sonYuzZamani).inMilliseconds < 2000) {
        return;
      }
    }
    _olcumNoktasi = nokta;
    _sonOlcumZamani = simdi;
    if (kontrol.value.focusPointSupported) {
      kontrol.setFocusPoint(nokta).catchError((_) {});
    }
    if (kontrol.value.exposurePointSupported) {
      kontrol.setExposurePoint(nokta).catchError((_) {});
    }
  }

  // Kendi kendini düzelten pozlama: her çekimde yüzün parlaklığı hedefle
  // karşılaştırılır ve pozlama düzeltmesi azar azar ayarlanır (integral
  // denetim: hata sıfırlanana kadar birikir). Öğrenilen değer kamera başına
  // saklanır; uygulama bir dahaki açılışta oradan başlar. Ara Güler modunda
  // hedef daha koyu (dramatik ışık makbul).
  void _pozlamadanOgren() {
    final kontrol = _kontrol;
    final yl = _degerlendirme.yuzParlaklik;
    if (kontrol == null || _yuzSayisi == 0 || yl <= 0 || _maxPoz <= _minPoz) {
      return;
    }
    final hedef = _guler ? 110.0 : 128.0;
    final hata = hedef - yl;
    if (hata.abs() < 10) return;
    _pozDuzeltme = _aralikta(_pozDuzeltme + hata / 60 * 0.3,
        math.max(_minPoz, -1.5), math.min(_maxPoz, 1.5));
    kontrol.setExposureOffset(_pozDuzeltme).catchError((_) => 0.0);
    _ogrenilen['poz_${kameralar[_kameraIndex].lensDirection.name}'] =
        double.parse(_pozDuzeltme.toStringAsFixed(3));
    _ogrenilenKaydet();
  }

  Future<Directory> _arsivKlasoru() async {
    final kok = await getApplicationDocumentsDirectory();
    final klasor = Directory('${kok.path}/arsiv');
    if (!await klasor.exists()) await klasor.create(recursive: true);
    return klasor;
  }

  Future<void> _ogrenilenYukle() async {
    try {
      final f = File('${(await _arsivKlasoru()).path}/ogrenilen.json');
      if (await f.exists()) {
        final v = jsonDecode(await f.readAsString());
        if (v is Map<String, dynamic>) _ogrenilen = v;
      }
    } catch (_) {}
  }

  Future<void> _ogrenilenKaydet() async {
    try {
      final f = File('${(await _arsivKlasoru()).path}/ogrenilen.json');
      await f.writeAsString(jsonEncode(_ogrenilen));
    } catch (_) {}
  }

  // Aşama 2 — öğrenme verisi: çekim anındaki sahne ve kararlar. Sonradan
  // hangi sahnede hangi görünümün tutulduğunu öğrenmek için arşive yazılır.
  Map<String, dynamic> _anOzellikleri(bool otomatik) {
    final d = _degerlendirme;
    double k(double v) => double.parse(v.toStringAsFixed(2));
    return {
      'otomatik': otomatik,
      'kamera': kameralar[_kameraIndex].lensDirection.name,
      'zoom': k(_zoom),
      'pozDuzeltme': k(_pozDuzeltme),
      'parlaklik': k(_hamParlaklik),
      'netlik': k(_hamNetlik),
      'hareket': k(_hamHareket),
      'titreme': k(_titreme),
      'egim': k(_egimSapma),
      'yuzSayisi': _yuzSayisi,
      'tamBoy': _tamBoy,
      'guler': _guler,
      'baskin': _baskin,
      'baskinPuan': _baskinPuan,
      'puan': _toplamPuan,
      'yuzParlaklik': k(d.yuzParlaklik),
      'puanlar': {
        'kompozisyon': d.kompozisyon,
        'yuzIsigi': d.yuzIsigi,
        'yuzNetligi': d.yuzNetligi,
        'ayrisma': d.ayrisma,
        'an': d.an,
        'kendiligindenlik': d.kendiligindenlik,
        'baglam': d.baglam,
      },
    };
  }

  // Görüntüleyicide bir sürüme ne kadar bakıldığı (örtük beğeni sinyali)
  void _bakisKaydet(String kayit, String surum, int ms) {
    if (kayit.isEmpty) return;
    () async {
      try {
        final f = File('${(await _arsivKlasoru()).path}/bakislar.jsonl');
        final satir = jsonEncode({
          'kayit': kayit,
          'surum': surum,
          'ms': ms,
          'zaman': DateTime.now().toIso8601String(),
        });
        await f.writeAsString('$satir\n', mode: FileMode.append);
      } catch (_) {}
    }();
  }

  double _zoomSiniri() => math.min(_maxZoom, zoomUstSinir);

  // Otomatik zoom. Yüz kadrajda küçük kalırsa telefon sabitken ve yüz kadrajın
  // ortasına yakınken yumuşak adımlarla yaklaşır; yüz kadrajı fazla doldurursa,
  // kenara taşarsa ya da 2 sn kimse görünmezse yavaşça geri açılır. Ara Güler
  // modunda, tam boy kadrajda ve kalabalıkta zoom yapılmaz: insan çevresiyle
  // birlikte görünmeli. Zirve izlenirken ve çekim sırasında zoom değişmez.
  void _otomatikZoom(int sabit) {
    final kontrol = _kontrol;
    if (kontrol == null ||
        _zoomAyarlaniyor ||
        _cekiliyor ||
        _zirveBaslangic != null ||
        _maxZoom <= _tabanZoom) {
      return;
    }
    final ust = _zoomSiniri();
    final kutu = _anaYuz;
    final gw = _dikBoyut.width;
    final gh = _dikBoyut.height;
    double hedef = _zoom;

    if (_yuzSayisi == 0 || kutu == null || gw == 0 || gh == 0) {
      // Kısa kayıplarda bekle; 2 sn kimse yoksa geniş kadraja dön
      if (DateTime.now().difference(_sonYuzZamani).inMilliseconds < 2000) {
        return;
      }
      hedef = _tabanZoom;
    } else if (_guler || _tamBoy || _yuzSayisi >= 3) {
      hedef = _tabanZoom;
    } else {
      // Bir önceki zoom adımından sonra yeni bir yüz ölçümü gelmeden karar verme
      if (_yuzAnalizNo == _sonZoomAnalizNo) return;
      final gen = kutu.width / gw;
      final cx = kutu.center.dx / gw;
      final cy = kutu.center.dy / gh;
      final kenarda = kutu.left < gw * 0.02 ||
          kutu.right > gw * 0.98 ||
          kutu.top < gh * 0.02 ||
          kutu.bottom > gh * 0.98;
      if (kenarda || gen > 0.40) {
        hedef = _zoom / 1.25; // fazla yakın ya da taşıyor: geri aç
      } else if (gen < 0.12) {
        // Portre için yüz genişliğin ~%22'si olsun
        hedef = _zoom * 0.22 / math.max(gen, 0.01);
        // Yaklaşınca yüz merkezden uzaklaşır; kadrajdan çıkmayacak kadar yaklaş
        final sapma = math.max((cx - 0.5).abs(), (cy - 0.5).abs());
        if (sapma > 0.01) hedef = math.min(hedef, _zoom * 0.36 / sapma);
        // Titreyen elde yaklaşma (zoom titremeyi büyütür)
        if (sabit < 60) hedef = _zoom;
      } else {
        return; // yüz zaten iyi boyutta
      }
    }

    hedef = _aralikta(hedef, _tabanZoom, ust);
    // Yumuşak geçiş: her adımda en fazla %12
    final adim = _zoom * 0.12;
    final yeni = _zoom + _aralikta(hedef - _zoom, -adim, adim);
    if ((yeni - _zoom).abs() < 0.02) return;

    _zoomAyarlaniyor = true;
    _sonZoomAnalizNo = _yuzAnalizNo;
    kontrol.setZoomLevel(yeni).then((_) {
      if (mounted) setState(() => _zoom = yeni);
    }).catchError((_) {}).whenComplete(() => _zoomAyarlaniyor = false);
  }

  // Kareyi dik (ekranda görünen) hâle getirmek için gereken dönüş: sensör açısı
  // ile telefonun o anki dönüşü birlikte (ML Kit'in resmi Flutter örneğindeki
  // hesap). Yalnızca sensör açısı kullanılırsa yatay tutuşta yüz bulunamaz ve
  // kaydedilen fotoğraf yan yatık çıkar.
  int _donus() {
    final kamera = kameralar[_kameraIndex];
    const acilar = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final cihaz = acilar[_kontrol?.value.deviceOrientation] ?? 0;
    return kamera.lensDirection == CameraLensDirection.front
        ? (kamera.sensorOrientation + cihaz) % 360
        : (kamera.sensorOrientation - cihaz + 360) % 360;
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
    final rotasyon = InputImageRotationValue.fromRawValue(_donus());
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
      Rect? anaYuz;
      Size dikBoyut = Size.zero;
      int grupUyumu = 100;
      double anaYaw = 0, anaEgim = 0, etkilesim = 0;
      bool gulerUygun = false;
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
          etkilesim = kirp(yakin * 0.5 + donuk * 0.5);
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
        final dikey = _donus() % 180 != 0;
        final kareGenislik = (dikey ? img.height : img.width).toDouble();
        if (a.boundingBox.width / kareGenislik > 0.3) teknik.add('Yakın çekim');
        if (_tamBoy) teknik.add('Tam boy');

        // Ara Güler gözü: arka kamerada, insan kameraya değil başka yere
        // bakıyorsa (fark edilmeden yakalanmış) ve çevresiyle birlikte
        // görünüyorsa (yüz küçük ya da birden çok kişi) sahne bir hayat anıdır.
        final onden =
            kameralar[_kameraIndex].lensDirection == CameraLensDirection.front;
        final kendiliginden = yaw > 15 || egim < -10;
        final cevreli = a.boundingBox.width / kareGenislik < 0.2 || n >= 2;
        gulerUygun = !onden && kendiliginden && cevreli;

        anaYuz = a.boundingBox;
        dikBoyut = dikey
            ? Size(img.height.toDouble(), img.width.toDouble())
            : Size(img.width.toDouble(), img.height.toDouble());
        int uyumlu = 0;
        for (final y in yuzler) {
          final sol = y.leftEyeOpenProbability ?? 0.5;
          final sag = y.rightEyeOpenProbability ?? 0.5;
          if (math.min(sol, sag) > 0.5 && (y.headEulerAngleY ?? 0).abs() < 30) {
            uyumlu++;
          }
        }
        grupUyumu = (uyumlu * 100 / n).round();
        anaYaw = yaw;
        anaEgim = egim;

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
          _anaYuz = anaYuz;
          _yuzAnalizNo++;
          if (yuzler.isNotEmpty) _sonYuzZamani = DateTime.now();
          _dikBoyut = dikBoyut;
          _grupUyumu = grupUyumu;
          _anaYaw = anaYaw;
          _anaEgim = anaEgim;
          _etkilesim = etkilesim;
          _gulerSayac = (_gulerSayac + (gulerUygun ? 1 : -1)).clamp(0, 6).toInt();
          if (_gulerSayac >= 4) {
            _guler = true;
          } else if (_gulerSayac <= 1) {
            _guler = false;
          }
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
      final dikey = _donus() % 180 != 0;
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
    if (_gosteriliyor) return;
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
      // Jiroskop varsa sabitliği telefonun dönme hızı belirler (0.08 rad/sn
      // altı tam sabit, 0.6 üstü sarsıntı); yoksa eski kare farkı yöntemi.
      final jiroVar = DateTime.now().difference(_sonJiro).inMilliseconds < 1000;
      final sabit = jiroVar
          ? (100 - (_titreme - 0.08) / 0.52 * 100).clamp(0, 100).round()
          : (100 - (hareket - 2) * 8).clamp(0, 100).round();
      double t = isik * 0.3 + net * 0.3 + sabit * 0.4;
      if (sabit < 50 && _baskin != 'Enerjik') t = t * 0.5;

      // Kadrajda insan varsa puanı fotoğrafçı gözü verir: kompozisyon, yüzdeki
      // ışık, yüzün netliği, ayrışma ve anın gücü birlikte
      var degerlendirme = _Degerlendirme();
      if (_yuzSayisi > 0 && _baskin != null) {
        degerlendirme =
            _fotografciGozu(b, satir, w, h, parlaklik, netlik, sabit);
        t = degerlendirme.puan.toDouble();
      } else if (_guler) {
        // Ara Güler: insan yoksa fotoğraf da yok
        t = 0;
        degerlendirme.ipucu = 'İnsan yoksa fotoğraf yok — hayatın içine bak';
      }

      if (mounted) {
        setState(() {
          _degerlendirme = degerlendirme;
          _isikPuani = isik;
          _netlikPuani = net;
          _sabitlikPuani = sabit;
          _toplamPuan = t.round();
          _hamParlaklik = parlaklik;
          _hamNetlik = netlik;
          _hamHareket = hareket;
        });
      }

      _otomatikZoom(sabit);
      _olcumNoktasiGuncelle();

      // Kareyi puanıyla birlikte hafızaya al (zirve seçimi için)
      final tr = t.round();
      if (img.planes.length >= 3) {
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
          kategori: _efektKategorisi(),
          etiketler: Map<String, int>.from(_kategoriler),
          teknik: List<String>.from(_teknik),
          yuzVar: _yuzSayisi > 0,
        ));
        if (_tampon.length > tamponBoyu) _tampon.removeAt(0);
      }

      // Otomatik çekim: "işte bu an" kararı verildiği kare beklemeden kaydedilir.
      // Yüz varsa karar fotoğrafçı gözünündür (ekrandaki ✓ ipucuyla aynı an),
      // yoksa puan eşiği. Arka arkaya akmasın diye çekimler arası en az 1 sn.
      if (!_cekiliyor &&
          _geriSayim == 0 &&
          _tampon.isNotEmpty &&
          DateTime.now().difference(_sonCekim).inMilliseconds > 1000) {
        final an = _yuzSayisi > 0
            ? (degerlendirme.ipucu?.startsWith('✓') ?? false)
            : tr >= esik;
        if (an) _anlikKaydet(_tampon.last);
      }
    } finally {
      _isleniyor = false;
    }
  }

  // Kaydedilecek efektli kopyanın görünümü: Ara Güler modunda her zaman
  // belgesel siyah-beyaz, aksi halde yeterince güçlü baskın ruh hali.
  String? _efektKategorisi() {
    if (_guler) return _yuzSayisi > 0 ? 'Ara Güler' : null;
    return (_yuzSayisi > 0 && _baskin != null && _baskinPuan >= 60)
        ? _baskin
        : null;
  }

  // Dik (ekranda görünen) görüntüdeki bir noktayı ham sensör karesine çevirir.
  Offset _hamNokta(double u, double v, int w, int h) {
    switch (_donus()) {
      case 90:
        return Offset(v, h - 1 - u);
      case 180:
        return Offset(w - 1 - u, h - 1 - v);
      case 270:
        return Offset(w - 1 - v, u);
      default:
        return Offset(u, v);
    }
  }

  // Bir fotoğrafçının deklanşöre basmadan önce baktığı şeyleri puanlar ve
  // puanı en çok düşüren sorun için tek bir ipucu üretir.
  _Degerlendirme _fotografciGozu(Uint8List b, int satir, int w, int h,
      double parlaklik, double netlik, int sabit) {
    final d = _Degerlendirme();
    final kutu = _anaYuz;
    final gw = _dikBoyut.width;
    final gh = _dikBoyut.height;
    if (kutu == null || gw == 0 || gh == 0) return d;

    // Yüz bölgesini ham karede bul; ışığını, iki yarısını ve netliğini ölç
    final p1 = _hamNokta(kutu.left, kutu.top, w, h);
    final p2 = _hamNokta(kutu.right, kutu.bottom, w, h);
    final hx0 = math.max(0, math.min(p1.dx, p2.dx).floor());
    final hx1 = math.min(w - 2, math.max(p1.dx, p2.dx).ceil());
    final hy0 = math.max(0, math.min(p1.dy, p2.dy).floor());
    final hy1 = math.min(h - 2, math.max(p1.dy, p2.dy).ceil());
    // Ekrandaki sol-sağ ayrımı, sensör 90/270° döndüyse ham karede dikey eksendir
    final dikey = _donus() % 180 != 0;
    final orta = dikey ? (hy0 + hy1) ~/ 2 : (hx0 + hx1) ~/ 2;
    final adim = math.max(2, (hx1 - hx0) ~/ 40);
    int toplam = 0, adet = 0, kenar = 0;
    int ya = 0, yaAdet = 0, yb = 0, ybAdet = 0;
    for (int y = hy0; y < hy1; y += adim) {
      final o = y * satir;
      for (int x = hx0; x < hx1; x += adim) {
        final v = b[o + x];
        toplam += v;
        adet++;
        kenar += (v - b[o + x + 1]).abs() + (v - b[o + satir + x]).abs();
        if ((dikey ? y : x) < orta) {
          ya += v;
          yaAdet++;
        } else {
          yb += v;
          ybAdet++;
        }
      }
    }
    if (adet == 0) return d;
    final yl = toplam / adet;
    final yk = kenar / adet;
    final la = yaAdet == 0 ? yl : ya / yaAdet;
    final lb = ybAdet == 0 ? yl : yb / ybAdet;
    final oran = math.max(la, lb) / math.max(1.0, math.min(la, lb));

    // 1) Yüzdeki ışık: yüz iyi pozlanmış mı, karşı ışık var mı, ışık yüze
    //    derinlik veriyor mu (bir yan hafif daha aydınlık) yoksa sert mi
    double isik =
        100 - math.max(0.0, 95 - yl) * 1.5 - math.max(0.0, yl - 190) * 2.5;
    final karsiIsik = parlaklik - yl > 45;
    if (karsiIsik) isik -= (parlaklik - yl - 45) * 1.2;
    if (oran > 1.15 && oran < 2.2) isik += 8;
    if (oran > 3.0) isik -= 15;

    // 2) Yüz netliği: fotoğrafçı kadrajın ortasına değil gözlere odaklanır
    // (ölçek: telefonda net yüzde ~8, hafif yumuşamış yüzde ~5 ölçüldü)
    final yuzNet = (yk - 2) / 6 * 100;

    // 3) Ayrışma: yüz arka plandan daha net mi (bokeh), arka plan kalabalık mı
    final ayrisma = 50 +
        (yk / math.max(0.5, netlik) - 1) * 50 -
        math.max(0.0, netlik - 12) * 3 +
        math.max(0.0, 8 - netlik) * 3; // sade, düz arka plan konuyu öne çıkarır

    // 4) Kompozisyon: üçler kuralı, baş boşluğu, kesik yüz, konu büyüklüğü,
    //    telefonun düz tutulması
    final cx = kutu.center.dx / gw;
    final gozHatti = (kutu.top + kutu.height * 0.4) / gh;
    final yatayUzak = math.min(
        math.min((cx - 1 / 3).abs(), (cx - 2 / 3).abs()), (cx - 0.5).abs() + 0.04);
    final yatayP = _aralikta(1 - yatayUzak / 0.17, 0, 1);
    final hedefY = _tamBoy ? 0.18 : 0.33;
    final dikeyP = _aralikta(1 - (gozHatti - hedefY).abs() / 0.2, 0, 1);
    double komp = 30 + yatayP * 35 + dikeyP * 35;
    final yuzGen = kutu.width / gw;
    final kenardaKesik = kutu.left < gw * 0.01 ||
        kutu.right > gw * 0.99 ||
        kutu.bottom > gh * 0.99;
    final basKesik = kutu.top < gh * 0.015 && yuzGen < 0.5;
    final konuKucuk =
        !_tamBoy && yuzGen < 0.08 && _zoom >= _zoomSiniri() - 0.05;
    final yamuk = _egimSapma > 2 && _egimSapma < 15;
    if (kenardaKesik) komp -= 45;
    if (basKesik) komp -= 30;
    if (konuKucuk) komp -= 20;
    if (yamuk) komp -= (_egimSapma - 2) * 2.5;

    // 5) An: ifadenin gücü; grupta herkesin gözü açık ve kameraya dönük olmalı
    final gozSorun = _gozKapali && !gozKapaliOlabilir.contains(_baskin);
    double an = _baskinPuan * (_yuzSayisi >= 2 ? _grupUyumu / 100 : 1.0);
    if (gozSorun) an *= 0.3;

    d.yuzParlaklik = yl;
    d.ham =
        'yüz ışığı ${yl.toStringAsFixed(0)} · ışık oranı ${oran.toStringAsFixed(2)} · yüz kenar ${yk.toStringAsFixed(1)} · telefon eğimi ${_egimSapma.toStringAsFixed(1)}°';
    if (_guler) {
      return _gulerGozu(d, yl, yk, oran, yuzGen, kenardaKesik, yamuk,
          gozSorun, sabit);
    }

    double puan = _aralikta(komp, 0, 100) * 0.25 +
        _aralikta(isik, 0, 100) * 0.2 +
        _aralikta(yuzNet, 0, 100) * 0.2 +
        _aralikta(an, 0, 100) * 0.25 +
        _aralikta(ayrisma, 0, 100) * 0.1;
    if (sabit < 50 && _baskin != 'Enerjik') puan *= 0.6;

    d.kompozisyon = _aralikta(komp, 0, 100).round();
    d.yuzIsigi = _aralikta(isik, 0, 100).round();
    d.yuzNetligi = _aralikta(yuzNet, 0, 100).round();
    d.ayrisma = _aralikta(ayrisma, 0, 100).round();
    d.an = _aralikta(an, 0, 100).round();
    d.puan = puan.round();

    // En önemli sorundan başlayarak tek bir ipucu. Kesik yüz, kapalı göz ve
    // sarsıntı fotoğrafı bozar; geri kalanlar puan eşiği aşıldıysa ince ayardır
    // ve "işte bu an" demeye engel olmaz (puan ile ipucu çelişmesin).
    if (kenardaKesik) {
      d.ipucu = 'Yüz kadrajdan taşıyor — biraz geri çekil';
    } else if (basKesik) {
      d.ipucu = 'Başın üstü kesiliyor — telefonu biraz yukarı kaldır';
    } else if (gozSorun) {
      d.ipucu = 'Gözler kapalı';
    } else if (_yuzSayisi >= 2 && _grupUyumu < 70) {
      d.ipucu = 'Herkes kameraya baksın';
    } else if (sabit < 50 && _baskin != 'Enerjik') {
      d.ipucu = 'Telefonu sabit tut';
    } else if (d.puan >= esik) {
      d.ipucu = '✓ İşte bu an';
    } else if (yamuk) {
      d.ipucu = 'Telefonu düzelt (${_egimSapma.toStringAsFixed(0)}° yamuk)';
    } else if (karsiIsik || yl < 70) {
      d.ipucu = 'Yüz karanlık — ışığa doğru dön';
    } else if (yl > 205) {
      d.ipucu = 'Yüzde ışık patlıyor — gölgeye geç';
    } else if (yuzNet < 40) {
      d.ipucu = 'Yüz net değil';
    } else if (konuKucuk) {
      d.ipucu = 'Yaklaş — konu çok küçük';
    } else if (gozHatti > hedefY + 0.12) {
      d.ipucu = 'Telefonu biraz aşağı indir — gözler üst üçte bire gelsin';
    } else if (gozHatti < hedefY - 0.15 && yuzGen < 0.5) {
      d.ipucu = 'Telefonu biraz yukarı kaldır';
    } else if (yatayP < 0.4) {
      d.ipucu = 'Konuyu üçte bir çizgisine ya da ortaya al';
    } else if (an < 50) {
      d.ipucu = 'Kadraj hazır — anı bekle';
    }
    return d;
  }

  // Ara Güler'in gözüyle puanlama. Kendini sanatçı değil "görsel tarihçi" ve
  // foto muhabiri sayardı: poz verdirmez, insanları onu fark etmedikleri anda,
  // yaşadıkları yerle birlikte çekerdi. Burada kural kitabı kompozisyon değil;
  // kendiliğindenlik, bağlam ve anın anlamı öne geçer.
  _Degerlendirme _gulerGozu(_Degerlendirme d, double yl, double yk,
      double oran, double yuzGen, bool kenardaKesik, bool yamuk,
      bool gozSorun, int sabit) {
    final onden =
        kameralar[_kameraIndex].lensDirection == CameraLensDirection.front;

    // Kendiliğindenlik: kameraya dönük bakış poz demektir; yana ya da aşağı
    // bakan, işine dalmış insan kendiliğindendir. Selfie doğası gereği pozdur.
    double kendi = math.max(_aralikta((_anaYaw - 8) / 20, 0, 1),
        _aralikta((-_anaEgim - 8) / 15, 0, 1));
    if (onden) kendi *= 0.5;

    // Bağlam: yüz kadrajı doldurmasın; insan yaşadığı yerle birlikte görünsün
    double baglam = yuzGen <= 0.22
        ? _aralikta(yuzGen / 0.06, 0.4, 1)
        : _aralikta(1 - (yuzGen - 0.22) / 0.3, 0.2, 1);
    if (_tamBoy) baglam = math.min(1.0, baglam + 0.2);
    if (_yuzSayisi >= 2) baglam = math.min(1.0, baglam + 0.1);

    // Anın anlamı: güçlü bir ifade (hüzün, ciddiyet de olur) ya da insanlar
    // arasındaki etkileşim. Gülümseme şart değil.
    double anlam = math.max(_baskinPuan.toDouble(), _etkilesim * 100);
    if (gozSorun) anlam *= 0.3;

    // Işık: dramatik, yandan gelen ışık makbul; kusur yalnızca yüzün karanlıkta
    // kaybolması ya da patlaması
    double isik =
        90 - math.max(0.0, 45 - yl) * 2 - math.max(0.0, yl - 215) * 2.5;
    if (oran > 1.3 && oran < 3.5) isik += 10;

    final net = _aralikta((yk - 2) / 6 * 100, 0, 100);

    double puan = kendi * 100 * 0.3 +
        _aralikta(anlam, 0, 100) * 0.25 +
        baglam * 100 * 0.2 +
        _aralikta(isik, 0, 100) * 0.15 +
        net * 0.1;
    if (kenardaKesik) puan *= 0.6;
    if (yamuk) puan -= (_egimSapma - 2) * 1.5;
    if (sabit < 50) puan *= 0.6;
    puan = _aralikta(puan, 0, 100);

    d.kendiligindenlik = (kendi * 100).round();
    d.baglam = (baglam * 100).round();
    d.yuzIsigi = _aralikta(isik, 0, 100).round();
    d.yuzNetligi = net.round();
    d.an = _aralikta(anlam, 0, 100).round();
    d.puan = puan.round();

    if (kenardaKesik) {
      d.ipucu = 'Yüz kadrajdan taşıyor — biraz geri çekil';
    } else if (gozSorun) {
      d.ipucu = 'Gözler kapalı';
    } else if (sabit < 50) {
      d.ipucu = 'Telefonu sabit tut';
    } else if (d.puan >= esik) {
      d.ipucu = '✓ İşte bu an';
    } else if (kendi < 0.4) {
      d.ipucu = onden
          ? 'Ara Güler poz istemezdi — arka kamerayla hayata bak'
          : 'Poz değil hayat — fark edilmeden bekle';
    } else if (yuzGen > 0.4) {
      d.ipucu = 'Geri çekil — insanı yaşadığı yerle göster';
    } else if (yl < 45) {
      d.ipucu = 'Yüz karanlıkta kayboluyor';
    } else if (anlam < 50) {
      d.ipucu = 'Anı bekle';
    }
    return d;
  }

  // Fotoğrafın bir kopyasını ve etiketlerini uygulamanın kendi arşivine yazar
  // (ileride etiketlerle arama yapılabilen arşiv ekranı için).
  Future<void> _arsiveEkle(
      Uint8List jpeg,
      Map<String, int> etiketler,
      List<String> teknik,
      String? anaEtiket,
      String kayitId,
      Map<String, dynamic> ozellikler,
      String? filmAdi) async {
    try {
      final klasor = await _arsivKlasoru();
      final ad = '$kayitId.jpg';
      await File('${klasor.path}/$ad').writeAsBytes(jpeg);
      final kayit = jsonEncode({
        'id': kayitId,
        'dosya': ad,
        'zaman': DateTime.now().toIso8601String(),
        'ana': anaEtiket,
        'film': filmAdi,
        'etiketler': etiketler,
        'teknik': teknik,
        'ozellikler': ozellikler,
      });
      await File('${klasor.path}/etiketler.jsonl')
          .writeAsString('$kayit\n', mode: FileMode.append);
    } catch (_) {}
  }

  // "İşte bu an" denen kareyi hemen kaydeder. Son kaydedilenle (30 sn içinde)
  // aynı sahneyse ve ondan en az 8 puan iyi değilse kaydetmez, elenen sayılır.
  void _anlikKaydet(_Kare kare) {
    _sonCekim = DateTime.now();
    final iz = kareIzi(kare.y, kare.genislik, kare.yukseklik, kare.ySatir);
    final onceki = _sonIz;
    final yakinZamanda =
        _sonCekim.difference(_sonKayitZamani).inSeconds < 30;
    if (onceki != null &&
        yakinZamanda &&
        hammingMesafesi(iz, onceki) <= benzerlikEsigi &&
        kare.puan < _sonKayitPuan + 8) {
      setState(() => _elenen++);
      return;
    }
    _sonIz = iz;
    _sonKayitPuan = kare.puan;
    _sonKayitZamani = _sonCekim;
    setState(() => _flas = true);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _flas = false);
    });
    _sesCal();
    _kareyiKaydet(kare, _donus(), _anOzellikleri(true));
    _pozlamadanOgren();
  }

  // Kareyi JPEG'e çevirip efektli ve film kopyalarıyla galeriye kaydeder.
  Future<void> _kareyiKaydet(
      _Kare enIyi, int donus, Map<String, dynamic> ozellikler) async {
    _kaydediliyor = true;
    final kayitId = 'lahza_${DateTime.now().millisecondsSinceEpoch}';
    if (mounted) setState(() => _cekimSayisi++);
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
        'donus': donus,
        'kategori': enIyi.kategori,
        'yuz': enIyi.yuzVar,
      });
      final Uint8List jpeg = sonuc['orijinal'];
      await _galeriIzni();
      await Gal.putImageBytes(jpeg, album: 'Lahza', name: _dosyaAdi('orijinal'));
      final surumler = [
        _Surum('Orijinal', await _geciciYaz(jpeg), kayitId),
      ];
      final albumler = [
        'Lahza',
        ...await _kopyalariKaydet(sonuc, enIyi.kategori, surumler),
      ];
      await _arsiveEkle(jpeg, enIyi.etiketler, enIyi.teknik, enIyi.kategori,
          kayitId, ozellikler, sonuc['filmAdi'] as String?);
      _cekimEkle(surumler);
      _bildir('Kaydedildi: ${albumler.join(' · ')}');
    } catch (e) {
      if (mounted) setState(() => _yuzHata = 'kayıt: $e');
      _bildir('Kayıt hatası: $e', hata: true);
    } finally {
      _kaydediliyor = false;
    }
  }

  Future<void> _cek() async {
    final kontrol = _kontrol;
    if (_cekiliyor || kontrol == null) return;
    _cekiliyor = true;
    final kategori = _efektKategorisi();
    final yuzVar = _yuzSayisi > 0;
    final etiketAni = Map<String, int>.from(_kategoriler);
    final teknikAni = List<String>.from(_teknik);
    final ozellikAni = _anOzellikleri(false);
    final kayitId = 'lahza_${DateTime.now().millisecondsSinceEpoch}';
    XFile? foto;
    try {
      await kontrol.stopImageStream();
      foto = await kontrol.takePicture();
      _sesCal();
      _pozlamadanOgren();
      _sonCekim = DateTime.now();
      setState(() {
        _cekimSayisi++;
        _flas = true;
      });
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _flas = false);
      });
    } catch (e) {
      _bildir('Çekim hatası: $e', hata: true);
    } finally {
      // Analiz hemen devam etsin; kayıt ve kopyalar arka planda sürer
      _oncekiKare = null;
      try {
        await kontrol.startImageStream(_analiz);
      } catch (_) {}
      _cekiliyor = false;
    }
    if (foto == null) return;

    final surumler = [_Surum('Orijinal', foto.path, kayitId)];
    _cekimEkle(surumler);
    try {
      await _galeriIzni();
      await Gal.putImage(foto.path, album: 'Lahza');
      final kopyalar = await compute(dosyayaEfektUygula,
          {'yol': foto.path, 'kategori': kategori, 'yuz': yuzVar});
      await _arsiveEkle(await File(foto.path).readAsBytes(), etiketAni,
          teknikAni, kategori, kayitId, ozellikAni,
          kopyalar?['filmAdi'] as String?);
      final albumler = [
        'Lahza',
        if (kopyalar != null)
          ...await _kopyalariKaydet(kopyalar, kategori, surumler),
      ];
      if (mounted) setState(() {});
      _bildir('Kaydedildi: ${albumler.join(' · ')}');
    } catch (e) {
      if (mounted) setState(() => _yuzHata = 'kayıt: $e');
      _bildir('Kayıt hatası: $e', hata: true);
    }
  }

  Future<void> _galeriIzni() async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      await Gal.requestAccess(toAlbum: true);
    }
  }

  // Klasör düzeni: orijinaller Pictures/Lahza, kopyalar onun alt klasörlerinde
  // (Pictures/Lahza/Portra 400, Pictures/Lahza/Neşeli ...).
  // Ruh hali efektli ve film kopyalarını kendi albümlerine yazar, görüntüleyici
  // için sürümlere ekler ve yazılan albümlerin adlarını döndürür.
  Future<List<String>> _kopyalariKaydet(Map<String, dynamic> kopyalar,
      String? kategori, List<_Surum> surumler) async {
    final albumler = <String>[];
    final efektli = kopyalar['efektli'];
    if (efektli is Uint8List && kategori != null) {
      final album = 'Lahza/$kategori';
      await Gal.putImageBytes(efektli, album: album, name: _dosyaAdi(kategori));
      albumler.add(album);
      surumler.add(
          _Surum(kategori, await _geciciYaz(efektli), surumler.first.kayit));
    }
    final film = kopyalar['film'];
    final filmAdi = kopyalar['filmAdi'];
    if (film is Uint8List && filmAdi is String) {
      final album = 'Lahza/$filmAdi';
      await Gal.putImageBytes(film, album: album, name: _dosyaAdi(filmAdi));
      albumler.add(album);
      surumler.add(
          _Surum(filmAdi, await _geciciYaz(film), surumler.first.kayit));
    }
    return albumler;
  }

  // Galeri dosya adı: zaman damgası + sürüm (Türkçe harfler sadeleştirilir).
  // Ad verilmezse eklenti her kopyayı "image" adıyla kaydeder.
  String _dosyaAdi(String surum) {
    const harf = {'ç': 'c', 'ğ': 'g', 'ı': 'i', 'ö': 'o', 'ş': 's', 'ü': 'u',
        'Ç': 'C', 'Ğ': 'G', 'İ': 'I', 'Ö': 'O', 'Ş': 'S', 'Ü': 'U'};
    final sade = surum
        .split('')
        .map((c) => harf[c] ?? c)
        .join()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return 'lahza_${DateTime.now().millisecondsSinceEpoch}_$sade';
  }

  Future<String> _geciciYaz(Uint8List veri) async {
    final dosya = File(
        '${Directory.systemTemp.path}/lahza_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await dosya.writeAsBytes(veri);
    return dosya.path;
  }

  void _cekimEkle(List<_Surum> surumler) {
    if (!mounted) return;
    setState(() {
      _cekimler.insert(0, surumler);
      if (_cekimler.length > 30) _cekimler.removeLast();
      _sonFoto = surumler.first.yol;
    });
  }

  // Kaydın sonucunu deklanşörün üstünde kısa bir bildirimle gösterir.
  void _bildir(String mesaj, {bool hata = false}) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(mesaj),
      duration: Duration(seconds: hata ? 8 : 3),
      backgroundColor: hata ? Colors.red.shade800 : Colors.black87,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 200),
    ));
  }

  Future<void> _gostericiAc() async {
    if (_cekimler.isEmpty) return;
    _gosteriliyor = true;
    _tampon.clear();
    _zirveBaslangic = null;
    _zirvePuan = 0;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _FotoGosterici(
          cekimler: [for (final c in _cekimler) List<_Surum>.from(c)],
          bakisKaydet: _bakisKaydet),
    ));
    _gosteriliyor = false;
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: UcteBirCizer()),
                    if (_iskeletGoster && _poz != null)
                      CustomPaint(
                        painter: IskeletCizer(
                          _poz!,
                          _resimBoyutu,
                          kameralar[_kameraIndex].lensDirection ==
                              CameraLensDirection.front,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 52,
              right: 52,
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (_ayrinti) _rozet('Işık', _isikPuani),
                      if (_ayrinti) _rozet('Netlik', _netlikPuani),
                      if (_ayrinti) _rozet('Sabitlik', _sabitlikPuani),
                      yuzRozeti,
                      if (_ayrinti) _rozet('Toplam', _toplamPuan),
                    ],
                  ),
                  if (_ayrinti && _yuzSayisi > 0) const SizedBox(height: 6),
                  if (_ayrinti && _yuzSayisi > 0)
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: _guler
                          ? [
                              _rozet('Kendiliğindenlik',
                                  _degerlendirme.kendiligindenlik),
                              _rozet('Bağlam', _degerlendirme.baglam),
                              _rozet('Yüz ışığı', _degerlendirme.yuzIsigi),
                              _rozet('Yüz netliği', _degerlendirme.yuzNetligi),
                              _rozet('An', _degerlendirme.an),
                            ]
                          : [
                              _rozet('Kompozisyon', _degerlendirme.kompozisyon),
                              _rozet('Yüz ışığı', _degerlendirme.yuzIsigi),
                              _rozet('Yüz netliği', _degerlendirme.yuzNetligi),
                              _rozet('Ayrışma', _degerlendirme.ayrisma),
                              _rozet('An', _degerlendirme.an),
                            ],
                    ),
                  if (_ayrinti) const SizedBox(height: 6),
                  if (_ayrinti)
                    Text(
                      'ham: parlaklık ${_hamParlaklik.toStringAsFixed(0)} · netlik ${_hamNetlik.toStringAsFixed(1)} · hareket ${_hamHareket.toStringAsFixed(1)} · titreme ${_titreme.toStringAsFixed(2)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  if (_ayrinti && _yuzSayisi > 0)
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
                  if (_ayrinti && _yuzSayisi > 0)
                    Text(
                      '$_hamYuz\n${_degerlendirme.ham}\n$katSatiri',
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
                child: GestureDetector(
                  onTap: _gostericiAc,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(_sonFoto!),
                        width: 70, height: 70, fit: BoxFit.cover),
                  ),
                ),
              ),
            Positioned(
              bottom: 110,
              left: 90,
              right: 90,
              child: Column(
                children: [
                  if ((_yuzSayisi > 0 || _guler) &&
                      _degerlendirme.ipucu != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _degerlendirme.ipucu!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _degerlendirme.ipucu!.startsWith('✓')
                              ? const Color(0xFFF2A33A)
                              : Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Text(
                    _elenen > 0
                        ? 'Çekilen: $_cekimSayisi · Benzer elenen: $_elenen'
                        : 'Çekilen: $_cekimSayisi',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  if (_zoom > _tabanZoom + 0.05)
                    Text(
                      'Otomatik zoom ${_zoom.toStringAsFixed(1)}×',
                      style: const TextStyle(
                          color: Color(0xFFF2A33A), fontSize: 12),
                    ),
                  if (_guler)
                    const Text(
                      'Ara Güler gözüyle',
                      style: TextStyle(color: Color(0xFFF2A33A), fontSize: 12),
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
            // Ön/arka kamera: uygulamadaki tek seçim
            if (kameralar.length > 1)
              Positioned(
                right: 24,
                bottom: 34,
                child: GestureDetector(
                  onTap: _kameraDegistir,
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black54,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.cameraswitch,
                        color: Colors.white, size: 26),
                  ),
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

// Bir çekimin bir sürümü: etiket (Orijinal, ruh hali ya da film adı) ve dosya
class _Surum {
  final String etiket;
  final String yol;
  final String kayit; // arşivdeki çekim kimliği (öğrenme verisini bağlar)
  const _Surum(this.etiket, this.yol, this.kayit);
}

// Son çekimleri ve her çekimin sürümlerini tam ekranda gösterir. Sağa-sola
// kaydırarak sürümler ve önceki çekimler arasında geçilir; iki parmakla
// yakınlaştırılır.
class _FotoGosterici extends StatefulWidget {
  final List<List<_Surum>> cekimler;
  // Her sürüme ne kadar bakıldığını bildirir (kayıt kimliği, sürüm, ms)
  final void Function(String kayit, String surum, int ms) bakisKaydet;
  const _FotoGosterici({required this.cekimler, required this.bakisKaydet});
  @override
  State<_FotoGosterici> createState() => _FotoGostericiState();
}

class _FotoGostericiState extends State<_FotoGosterici> {
  late final List<(int, int)> _sira = [
    for (int c = 0; c < widget.cekimler.length; c++)
      for (int s = 0; s < widget.cekimler[c].length; s++) (c, s),
  ];
  int _simdiki = 0;
  final Stopwatch _bakis = Stopwatch()..start();

  // O an ekrandaki sürüme bakılan süreyi bildir (0,3 sn altı sayılmaz)
  void _bakisiBitir() {
    final ms = _bakis.elapsedMilliseconds;
    _bakis.reset();
    if (ms < 300) return;
    final (c, s) = _sira[_simdiki];
    final surum = widget.cekimler[c][s];
    widget.bakisKaydet(surum.kayit, surum.etiket, ms);
  }

  @override
  void dispose() {
    _bakisiBitir();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (c, s) = _sira[_simdiki];
    final cekim = widget.cekimler[c];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            itemCount: _sira.length,
            onPageChanged: (i) {
              _bakisiBitir();
              setState(() => _simdiki = i);
            },
            itemBuilder: (_, i) {
              final (ci, si) = _sira[i];
              return InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.file(File(widget.cekimler[ci][si].yol),
                      fit: BoxFit.contain),
                ),
              );
            },
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(
                      '${cekim[s].etiket}  ·  ${s + 1}/${cekim.length}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    c == 0 ? 'Son çekim' : '$c çekim önce',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  IconButton(
                    tooltip: 'Galeride aç',
                    icon: const Icon(Icons.photo_library_outlined,
                        color: Colors.white),
                    onPressed: () => Gal.open(),
                  ),
                ],
              ),
            ),
          ),
          // Bu sürümün telefondaki klasörü (galeri eklentisi Pictures/<albüm>
          // altına yazar; galeri uygulaması bunu albüm olarak gösterir)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Klasör: Pictures/Lahza${cekim[s].etiket == 'Orijinal' ? '' : '/${cekim[s].etiket}'}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
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

// Karenin parlaklık düzleminden 64 bitlik parmak izi (dHash): 9x8 ızgarada her
// hücre sağ komşusundan daha parlak mı? Aynı sahnenin kareleri birkaç bit
// farkla aynı izi verir; pozlama ya da küçük kıpırdanmalar onu pek değiştirmez.
int kareIzi(Uint8List y, int w, int h, int satir) {
  final hucre = List<double>.filled(72, 0);
  final hw = w / 9;
  final hh = h / 8;
  for (int r = 0; r < 8; r++) {
    for (int c = 0; c < 9; c++) {
      final x0 = (c * hw).floor();
      final x1 = ((c + 1) * hw).floor();
      final y0 = (r * hh).floor();
      final y1 = ((r + 1) * hh).floor();
      int toplam = 0, adet = 0;
      for (int yy = y0; yy < y1; yy += 6) {
        final o = yy * satir;
        for (int xx = x0; xx < x1; xx += 6) {
          toplam += y[o + xx];
          adet++;
        }
      }
      hucre[r * 9 + c] = adet == 0 ? 0.0 : toplam / adet;
    }
  }
  int iz = 0;
  for (int r = 0; r < 8; r++) {
    for (int c = 0; c < 8; c++) {
      iz <<= 1;
      if (hucre[r * 9 + c] > hucre[r * 9 + c + 1]) iz |= 1;
    }
  }
  return iz;
}

// İki parmak izi arasında farklı olan bit sayısı (0 = aynı, 64 = tamamen farklı)
int hammingMesafesi(int a, int b) {
  var x = a ^ b;
  int n = 0;
  while (x != 0) {
    x &= x - 1;
    n++;
  }
  return n;
}

// Fotoğrafçı gözünün bir kare için verdiği puanlar ve ipucu
class _Degerlendirme {
  int kompozisyon = 0;
  int yuzIsigi = 0;
  int yuzNetligi = 0;
  int ayrisma = 0;
  int an = 0;
  int kendiligindenlik = 0; // Ara Güler modu
  int baglam = 0; // Ara Güler modu
  int puan = 0;
  String? ipucu;
  String ham = '';
  double yuzParlaklik = 0; // yüz bölgesinin ortalama parlaklığı (0-255)
}

// Kadraja üçler kuralı çizgilerini çok silik olarak çizer.
class UcteBirCizer extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final kalem = Paint()
      ..color = Colors.white.withAlpha(60)
      ..strokeWidth = 0.8;
    for (final k in [1 / 3, 2 / 3]) {
      canvas.drawLine(
          Offset(size.width * k, 0), Offset(size.width * k, size.height), kalem);
      canvas.drawLine(
          Offset(0, size.height * k), Offset(size.width, size.height * k), kalem);
    }
  }

  @override
  bool shouldRepaint(covariant UcteBirCizer eski) => false;
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
  final bool yuzVar;
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
    required this.yuzVar,
  });
}

// YUV420 kareyi döndürülmüş JPEG'e çevirir; ruh hali efektli ve film/renk
// görünümlü kopyaları da üretir (arka planda, ayrı iş parçacığında çalışır).
Map<String, dynamic> kareyiJpegYap(Map<String, dynamic> v) {
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
  return _kopyalariUret(sonuc, kategori, v['yuz'] == true, true);
}

// Tam çözünürlüklü bir fotoğraf dosyasından efektli ve film kopyalarını üretir
// (orijinal zaten kaydedildiği için yeniden kodlanmaz).
Map<String, dynamic>? dosyayaEfektUygula(Map<String, dynamic> v) {
  final String yol = v['yol'];
  final String? kategori = v['kategori'];
  final veri = File(yol).readAsBytesSync();
  final im = imglib.decodeJpg(veri);
  if (im == null) return null;
  final duz = imglib.bakeOrientation(im);
  return _kopyalariUret(duz, kategori, v['yuz'] == true, false);
}

// 'orijinal', 'efektli' (ruh hali) ve 'film' + 'filmAdi' (uygun film/renk
// görünümü) anahtarlı JPEG'ler. Olmayan kopya haritada yer almaz.
Map<String, dynamic> _kopyalariUret(
    imglib.Image im, String? kategori, bool yuzVar, bool orijinalDahil) {
  Uint8List jpg(imglib.Image x) =>
      Uint8List.fromList(imglib.encodeJpg(x, quality: 92));
  final sonuc = <String, dynamic>{};
  if (orijinalDahil) sonuc['orijinal'] = jpg(im);
  final film = filmSec(im, kategori, yuzVar);
  if (film != null) {
    // efektUygula görüntüyü yerinde değiştirir; film kopyası ayrı bir kopyadan
    sonuc['film'] = jpg(efektUygula(imglib.Image.from(im), film));
    sonuc['filmAdi'] = film;
  }
  if (kategori != null) sonuc['efektli'] = jpg(efektUygula(im, kategori));
  return sonuc;
}

// Fotoğrafa uygun film simülasyonunu ya da renk derecelendirmesini seçer.
// Yüz varsa ruh haline, yoksa sahnenin kendisine (ışık, renk, yeşillik,
// gökyüzü) bakar. Ara Güler modunda renkli film uygulanmaz.
String? filmSec(imglib.Image im, String? kategori, bool yuzVar) {
  if (kategori == 'Ara Güler') return null;
  double topL = 0, topDoy = 0, topSicak = 0;
  int n = 0, yesil = 0, gok = 0, sicak = 0;
  for (int y = 0; y < im.height; y += 8) {
    for (int x = 0; x < im.width; x += 8) {
      final p = im.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final l = 0.299 * r + 0.587 * g + 0.114 * b;
      final enb = math.max(r, math.max(g, b));
      final enk = math.min(r, math.min(g, b));
      topL += l;
      topDoy += enb <= 0 ? 0.0 : (enb - enk) / enb;
      topSicak += r - b;
      if (g > r + 10 && g > b + 10) yesil++;
      if (b > r + 15 && l > 110) gok++;
      if (r > b + 35 && l > 60) sicak++;
      n++;
    }
  }
  if (n == 0) return null;
  final ortL = topL / n;
  final ortDoy = topDoy / n;
  final ortSicak = topSicak / n;

  // Gece / loş yapay ışık: tungsten sinema filmi
  if (ortL < 70) return 'CineStill 800T';
  if (yuzVar) {
    switch (kategori) {
      case 'Eğlenceli':
        return 'Gold 200'; // nostaljik eğlence, eski albüm havası
      case 'Enerjik':
      case 'Karizmatik':
      case 'Şaşkın':
        return 'Sinematik'; // turkuaz-turuncu, film karesi gibi
      case 'Komik':
        return 'Ektachrome'; // canlı, doygun
      case 'Cool':
      case 'Düşünceli':
        return 'Pro 400H'; // serin, ferah
      case 'Gizemli':
        return 'CineStill 800T'; // gece sineması
      default:
        return 'Portra 400'; // Samimi, Neşeli, Muzip ve diğer portreler
    }
  }
  if (yesil / n > 0.3) return 'Pro 400H'; // doğa, yeşillik
  if (gok / n > 0.15 && sicak / n > 0.12) return 'Sinematik'; // gök + sıcak ışık
  if (ortSicak > 25 && ortL > 120) return 'Gold 200'; // güneşli, sıcak sahne
  if (ortDoy > 0.35) return 'Ektachrome'; // renkli sahne
  return 'Portra 400';
}

// Lahza'nın imza sesi: iki yumuşak cam tını, beşli aralıkla yükselen
// (Do6 → Sol6), "işte bu!" hissi. Mekanik deklanşör sesinden bilerek farklı ve
// çok hafif (en yüksek genlik %22). Ses dosyası taşımamak için 16 bit mono
// WAV olarak burada üretilir.
Uint8List lahzaSesi() {
  const ornek = 44100;
  const sure = 0.34; // saniye
  const tepe = 0.22;
  // frekans (Hz), başlangıç (sn), sönme (sn), genlik
  const notalar = [
    [1046.5, 0.0, 0.060, 1.0],
    [1568.0, 0.070, 0.095, 0.8],
  ];
  final n = (ornek * sure).toInt();
  final ham = Float64List(n);
  double en = 0;
  for (int i = 0; i < n; i++) {
    final t = i / ornek;
    double v = 0;
    for (final nota in notalar) {
      final f = nota[0];
      final dt = t - nota[1];
      if (dt < 0) continue;
      final atak = math.min(1.0, dt / 0.004); // 4 ms yumuşak giriş
      final zarf = nota[3] * atak * math.exp(-dt / nota[2]);
      // temel + hafif 2. ve 3. harmonik: cam/çan tınısı
      v += zarf *
          (math.sin(2 * math.pi * f * dt) +
              0.12 * math.sin(2 * math.pi * 2 * f * dt) +
              0.04 * math.sin(2 * math.pi * 3 * f * dt));
    }
    ham[i] = v;
    if (v.abs() > en) en = v.abs();
  }
  final son = (ornek * 0.02).toInt(); // 20 ms yumuşak çıkış, tık olmasın
  for (int k = 0; k < son; k++) {
    ham[n - son + k] *= 1 - k / son;
  }

  final veri = ByteData(44 + n * 2);
  void etiket(int o, String yazi) {
    for (int k = 0; k < 4; k++) {
      veri.setUint8(o + k, yazi.codeUnitAt(k));
    }
  }

  etiket(0, 'RIFF');
  veri.setUint32(4, 36 + n * 2, Endian.little);
  etiket(8, 'WAVE');
  etiket(12, 'fmt ');
  veri.setUint32(16, 16, Endian.little);
  veri.setUint16(20, 1, Endian.little); // PCM
  veri.setUint16(22, 1, Endian.little); // mono
  veri.setUint32(24, ornek, Endian.little);
  veri.setUint32(28, ornek * 2, Endian.little);
  veri.setUint16(32, 2, Endian.little);
  veri.setUint16(34, 16, Endian.little);
  etiket(36, 'data');
  veri.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    veri.setInt16(44 + i * 2, (ham[i] / en * tepe * 32767).round(),
        Endian.little);
  }
  return veri.buffer.asUint8List();
}

// Değeri 0-255 aralığına sıkıştırır (taşmayı önler).
int _sinirla(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

// Değeri [alt, ust] aralığına sıkıştırır (double olarak).
double _aralikta(double v, double alt, double ust) =>
    v < alt ? alt : (v > ust ? ust : v);

// Bir ruh halinin görünüm reçetesi. Tüm renk kaymaları 0-255 ölçeğinde.
class _Gorunum {
  final bool gri; // siyah-beyaz
  final double pozlama; // genel parlaklık çarpanı
  final double egri; // S-eğrisi gücü: + kontrast artar, - yumuşar
  final double doygunluk; // tüm renklere eşit doygunluk
  final double canlilik; // soluk renkleri daha çok canlandırır (cildi yakmaz)
  final List<double> golge; // gölgelere eklenen renk (r, g, b)
  final List<double> isik; // parlak bölgelere eklenen renk (r, g, b)
  final double netlik; // yerel kontrast: + detay/doku, - yumuşak cilt
  final double parlama; // parlak bölgelerden yayılan hafif ışıma
  final double soluk; // siyahları kaldırma (mat görünüm)
  final double tepe; // en parlak beyaz (255 = sınırsız)
  final double vBaslangic; // kenar karartmanın başladığı mesafe (0-1)
  final double vMiktar; // kenarda ne kadar kararacağı (0-1)
  final double gren; // film greni miktarı
  // Renk derecelendirmesi (lift / gamma / gain), kanal başına (r, g, b).
  // Film görünümlerinin asıl kaynağı: her film rengi tonlara göre farklı kaydırır.
  final List<double> kaldirma; // gölgeler: + kaldırır, - bastırır (0 = yok)
  final List<double> gama; // orta tonlar: >1 açar, <1 koyulaştırır
  final List<double> kazanc; // parlak tonlar: >1 artırır, <1 azaltır
  final double halasyon; // parlak ışık çevresinde kırmızımsı hale (sinema filmi)
  const _Gorunum({
    this.gri = false,
    this.pozlama = 1.0,
    this.egri = 0,
    this.doygunluk = 1.0,
    this.canlilik = 0,
    this.golge = const [0, 0, 0],
    this.isik = const [0, 0, 0],
    this.netlik = 0,
    this.parlama = 0,
    this.soluk = 0,
    this.tepe = 255,
    this.vBaslangic = 1.0,
    this.vMiktar = 0,
    this.gren = 0,
    this.kaldirma = const [0, 0, 0],
    this.gama = const [1, 1, 1],
    this.kazanc = const [1, 1, 1],
    this.halasyon = 0,
  });
}

const Map<String, _Gorunum> gorunumler = {
  // Klasik portre: dramatik siyah-beyaz, belirgin doku, hafif selenyum tonu
  'Karizmatik': _Gorunum(
    gri: true,
    egri: 0.55,
    golge: [-2, 0, 5],
    isik: [6, 3, 0],
    netlik: 0.45,
    soluk: 6,
    tepe: 250,
    vBaslangic: 0.5,
    vMiktar: 0.5,
    gren: 9,
  ),
  // Altın saat: aydınlık, sıcak ışık, hafif ışıma
  'Neşeli': _Gorunum(
    pozlama: 1.06,
    egri: 0.2,
    doygunluk: 1.05,
    canlilik: 0.35,
    golge: [2, 0, -2],
    isik: [14, 7, -6],
    netlik: -0.1,
    parlama: 0.22,
    soluk: 6,
    vBaslangic: 0.75,
    vMiktar: 0.15,
  ),
  // Canlı ve sıcak, gölgelerde hafif turkuaz
  'Eğlenceli': _Gorunum(
    pozlama: 1.03,
    egri: 0.4,
    doygunluk: 1.15,
    canlilik: 0.35,
    golge: [-3, 1, 8],
    isik: [10, 4, -6],
    netlik: 0.1,
    parlama: 0.1,
    vBaslangic: 0.7,
    vMiktar: 0.2,
  ),
  // Sinematik turkuaz-turuncu, sert kontrast, keskin
  'Enerjik': _Gorunum(
    egri: 0.6,
    doygunluk: 1.2,
    canlilik: 0.2,
    golge: [-8, 3, 14],
    isik: [14, 5, -8],
    netlik: 0.35,
    vBaslangic: 0.55,
    vMiktar: 0.35,
    gren: 4,
  ),
  // Film noir'a yakın: koyu, soğuk gölgeler, mat siyahlar, güçlü vinyet
  'Gizemli': _Gorunum(
    pozlama: 0.9,
    egri: 0.5,
    doygunluk: 0.55,
    golge: [-6, 1, 12],
    isik: [5, 3, -2],
    netlik: 0.2,
    soluk: 14,
    tepe: 235,
    vBaslangic: 0.4,
    vMiktar: 0.6,
    gren: 12,
  ),
  // Sıcak, yumuşak ve pastel: pürüzsüz cilt, hafif ışıma
  'Samimi': _Gorunum(
    pozlama: 1.04,
    egri: 0.12,
    doygunluk: 1.0,
    canlilik: 0.2,
    golge: [6, 2, -1],
    isik: [12, 6, -6],
    netlik: -0.2,
    parlama: 0.3,
    soluk: 10,
    vBaslangic: 0.7,
    vMiktar: 0.2,
  ),
  // Parlak ve net, hafif serin vurgular
  'Şaşkın': _Gorunum(
    pozlama: 1.04,
    egri: 0.35,
    doygunluk: 1.1,
    canlilik: 0.3,
    golge: [0, 0, 4],
    isik: [4, 5, 8],
    netlik: 0.15,
    vBaslangic: 0.7,
    vMiktar: 0.15,
  ),
  // Pop-art: patlayan renkler, kontrast, sıcak vurgular
  'Komik': _Gorunum(
    pozlama: 1.07,
    egri: 0.4,
    doygunluk: 1.35,
    canlilik: 0.4,
    golge: [0, -2, 10],
    isik: [10, 7, -6],
    netlik: 0.15,
  ),
  // Mat film: turkuaz gölgeler, kaldırılmış siyahlar, soluk renk, gren
  'Cool': _Gorunum(
    egri: 0.35,
    doygunluk: 0.8,
    golge: [-5, 5, 14],
    isik: [8, 5, 0],
    netlik: 0.15,
    soluk: 24,
    tepe: 240,
    vBaslangic: 0.6,
    vMiktar: 0.25,
    gren: 8,
  ),
  // Şeker tonu: sıcak vurgular, gölgelerde hafif pembe-mor, yumuşak ışıma
  'Muzip': _Gorunum(
    pozlama: 1.03,
    egri: 0.3,
    doygunluk: 1.1,
    canlilik: 0.25,
    golge: [6, -2, 10],
    isik: [12, 5, -6],
    parlama: 0.15,
    soluk: 6,
    vBaslangic: 0.65,
    vMiktar: 0.3,
  ),
  // Ara Güler: belgesel siyah-beyaz. Tri-X filme benzer güçlü kontrast, derin
  // siyahlar, belirgin gren, baskı kâğıdı gibi çok hafif sıcak ton. Süsleme yok:
  // cilt yumuşatma ve ışıma kullanılmaz; fotoğraf gerçeği göstermeli.
  'Ara Güler': _Gorunum(
    gri: true,
    egri: 0.7,
    isik: [4, 2, 0],
    netlik: 0.3,
    tepe: 248,
    vBaslangic: 0.5,
    vMiktar: 0.4,
    gren: 14,
  ),
  // ---- Film simülasyonları ve renk derecelendirmesi ----
  // Ruh hali efektinden ayrı, fotoğrafa uygun olan seçilip ikinci bir kopya
  // olarak kaydedilir (bkz. filmSec).

  // Portre filmi (Kodak Portra 400 tarzı): sıcak, doğal ten; yumuşak kontrast,
  // hafif kalkık sıcak gölgeler, pastel renkler, ince gren
  'Portra 400': _Gorunum(
    pozlama: 1.03,
    egri: 0.15,
    doygunluk: 0.92,
    canlilik: 0.1,
    kaldirma: [0.03, 0.025, 0.015],
    gama: [1.02, 1.0, 0.97],
    kazanc: [1.0, 0.99, 0.95],
    golge: [2, 2, -2],
    isik: [6, 3, -4],
    netlik: -0.05,
    soluk: 6,
    tepe: 246,
    gren: 6,
  ),
  // Nostaljik tüketici filmi (Kodak Gold 200 tarzı): sarıya kaçan sıcaklık,
  // doygun renkler, kalkık siyahlar, belirgin gren, hafif vinyet — 90'lar albümü
  'Gold 200': _Gorunum(
    pozlama: 1.04,
    egri: 0.3,
    doygunluk: 1.12,
    canlilik: 0.2,
    kaldirma: [0.03, 0.02, 0.0],
    gama: [1.03, 1.02, 0.94],
    kazanc: [1.02, 1.0, 0.9],
    isik: [10, 8, -8],
    soluk: 8,
    tepe: 244,
    vBaslangic: 0.6,
    vMiktar: 0.3,
    gren: 10,
  ),
  // Fuji tarzı (Pro 400H): serin, ferah; gölgelerde camgöbeği-yeşil, açık
  // pozlanmış pastel görünüm; doğa ve yeşillikte güzel
  'Pro 400H': _Gorunum(
    pozlama: 1.05,
    egri: 0.12,
    doygunluk: 0.9,
    kaldirma: [0.0, 0.03, 0.04],
    gama: [0.98, 1.02, 1.02],
    kazanc: [0.98, 1.0, 1.0],
    golge: [-3, 4, 6],
    isik: [2, 3, 2],
    soluk: 12,
    tepe: 245,
    gren: 6,
  ),
  // Dia filmi (Ektachrome tarzı): canlı, doygun, derin siyahlar, temiz serin
  // beyazlar; renkli sahnelerde
  'Ektachrome': _Gorunum(
    egri: 0.55,
    doygunluk: 1.3,
    canlilik: 0.2,
    kaldirma: [-0.02, -0.01, 0.0],
    gama: [0.98, 1.0, 1.04],
    kazanc: [1.0, 1.0, 1.03],
    golge: [-2, 0, 6],
    netlik: 0.15,
    vBaslangic: 0.6,
    vMiktar: 0.25,
    gren: 3,
  ),
  // Tungsten sinema filmi (CineStill 800T tarzı): gece ve yapay ışık için;
  // serin genel ton, ışıkların çevresinde kırmızı hale, iri gren
  'CineStill 800T': _Gorunum(
    pozlama: 1.05,
    egri: 0.35,
    doygunluk: 1.05,
    kaldirma: [0.0, 0.02, 0.05],
    gama: [0.95, 1.0, 1.08],
    kazanc: [0.97, 1.0, 1.06],
    golge: [-4, 2, 10],
    isik: [6, 2, -2],
    halasyon: 0.5,
    soluk: 6,
    gren: 14,
  ),
  // Sinematik renk derecelendirmesi (turkuaz-turuncu): gölgeler turkuaza,
  // ten ve parlak tonlar turuncuya; zıt renkler konuyu öne çıkarır
  'Sinematik': _Gorunum(
    egri: 0.45,
    doygunluk: 1.05,
    canlilik: 0.15,
    kaldirma: [-0.02, 0.03, 0.06],
    gama: [1.02, 1.0, 0.98],
    kazanc: [1.04, 1.0, 0.94],
    golge: [-16, 6, 22],
    isik: [16, 6, -10],
    netlik: 0.15,
    vBaslangic: 0.55,
    vMiktar: 0.3,
    gren: 3,
  ),
  // Eski sürümlerden kalan kategori: soluk, serin, hafif vinyet
  'Düşünceli': _Gorunum(
    pozlama: 0.97,
    egri: 0.15,
    doygunluk: 0.55,
    golge: [-4, 0, 10],
    isik: [2, 2, 0],
    netlik: -0.05,
    soluk: 12,
    vBaslangic: 0.6,
    vMiktar: 0.35,
    gren: 5,
  ),
};

// Her ruh haline uygun görünüm. Tüm hesaplar piksel piksel ve sınırlandırılarak
// yapılır; böylece koyu bölgeler beyaza, açık bölgeler siyaha "taşmaz".
imglib.Image efektUygula(imglib.Image im, String kategori) {
  final gr = gorunumler[kategori];
  if (gr == null) return im;
  final w = im.width;
  final h = im.height;

  // Kanal başına ton tablosu: önce S-eğrisi, sonra lift / gamma / gain
  final egri = List.generate(3, (_) => Float64List(256));
  for (int i = 0; i < 256; i++) {
    final v = i / 255;
    final yumusak = v * v * (3 - 2 * v);
    final s = v + (yumusak - v) * gr.egri;
    for (int c = 0; c < 3; c++) {
      var t = (s + gr.kaldirma[c] * (1 - s)) * gr.kazanc[c];
      t = t <= 0 ? 0.0 : math.pow(t, 1 / gr.gama[c]).toDouble();
      egri[c][i] = t * 255;
    }
  }

  // Netlik ve ışıma için görüntünün küçültülüp bulanıklaştırılmış kopyası.
  // 1/8 ölçekte bulanıklaştırmak tam boyda bulanıklaştırmaktan çok daha hızlıdır.
  const olcek = 8;
  Float32List? bulanik;
  int kw = 0, kh = 0;
  if (gr.netlik != 0 || gr.parlama > 0 || gr.halasyon > 0) {
    final kucuk = imglib.copyResize(im,
        width: math.max(1, w ~/ olcek),
        height: math.max(1, h ~/ olcek),
        interpolation: imglib.Interpolation.average);
    imglib.gaussianBlur(kucuk, radius: 4);
    kw = kucuk.width;
    kh = kucuk.height;
    bulanik = Float32List(kw * kh * 3);
    int i = 0;
    for (int y = 0; y < kh; y++) {
      for (int x = 0; x < kw; x++) {
        final p = kucuk.getPixel(x, y);
        bulanik[i++] = p.r.toDouble();
        bulanik[i++] = p.g.toDouble();
        bulanik[i++] = p.b.toDouble();
      }
    }
  }

  final cx = w / 2;
  final cy = h / 2;
  final enUzak = math.sqrt(cx * cx + cy * cy);
  final aralik = (gr.tepe - gr.soluk) / 255;
  final br = [0.0, 0.0, 0.0];

  for (final p in im) {
    double r = p.r.toDouble() * gr.pozlama;
    double g = p.g.toDouble() * gr.pozlama;
    double b = p.b.toDouble() * gr.pozlama;

    // Bulanık kopyadan bu noktanın değeri (çift doğrusal örnekleme)
    if (bulanik != null) {
      final fx = _aralikta((p.x + 0.5) / olcek - 0.5, 0, kw - 1.0);
      final fy = _aralikta((p.y + 0.5) / olcek - 0.5, 0, kh - 1.0);
      final x0 = fx.floor();
      final y0 = fy.floor();
      final x1 = math.min(x0 + 1, kw - 1);
      final y1 = math.min(y0 + 1, kh - 1);
      final ax = fx - x0;
      final ay = fy - y0;
      for (int c = 0; c < 3; c++) {
        final a = bulanik[(y0 * kw + x0) * 3 + c];
        final bb = bulanik[(y0 * kw + x1) * 3 + c];
        final cc = bulanik[(y1 * kw + x0) * 3 + c];
        final d = bulanik[(y1 * kw + x1) * 3 + c];
        br[c] = (a + (bb - a) * ax) + ((cc + (d - cc) * ax) - (a + (bb - a) * ax)) * ay;
      }
    }

    // Netlik: pikselin çevresinden farkını büyüt (+) veya küçült (-)
    if (gr.netlik != 0) {
      final l = 0.299 * r + 0.587 * g + 0.114 * b;
      final bl = (0.299 * br[0] + 0.587 * br[1] + 0.114 * br[2]) * gr.pozlama;
      // Orta tonlarda tam, çok koyu/çok açıkta azalan etki (hale oluşmasın)
      final orta = 1 - ((l / 255) * 2 - 1).abs();
      final fark = (l - bl) * gr.netlik * orta;
      r += fark;
      g += fark;
      b += fark;
    }

    if (gr.gri) {
      final l = 0.299 * r + 0.587 * g + 0.114 * b;
      r = l;
      g = l;
      b = l;
    }

    // Tonal eğri
    r = egri[0][_sinirla(r)];
    g = egri[1][_sinirla(g)];
    b = egri[2][_sinirla(b)];

    // Doygunluk + canlılık
    if (!gr.gri) {
      final l = 0.299 * r + 0.587 * g + 0.114 * b;
      final enb = math.max(r, math.max(g, b));
      final enk = math.min(r, math.min(g, b));
      final doy = enb <= 0 ? 0.0 : (enb - enk) / enb;
      final k = gr.doygunluk * (1 + gr.canlilik * (1 - doy));
      r = l + (r - l) * k;
      g = l + (g - l) * k;
      b = l + (b - l) * k;
    }

    // Bölünmüş renk tonlama: gölgeler bir renge, parlak bölgeler başka renge
    final lt = _aralikta((0.299 * r + 0.587 * g + 0.114 * b) / 255, 0, 1);
    final gA = (1 - lt) * (1 - lt);
    final iA = lt * lt;
    r += gr.golge[0] * gA + gr.isik[0] * iA;
    g += gr.golge[1] * gA + gr.isik[1] * iA;
    b += gr.golge[2] * gA + gr.isik[2] * iA;

    // Işıma: bulanık kopyanın parlak kısımlarını "ekran" karışımıyla ekle
    if (gr.parlama > 0) {
      final bl = (0.299 * br[0] + 0.587 * br[1] + 0.114 * br[2]) / 255;
      final maske = _aralikta((bl - 0.45) / 0.55, 0, 1) * gr.parlama;
      r = 255 - (255 - _aralikta(r, 0, 255)) * (1 - br[0] / 255 * maske);
      g = 255 - (255 - _aralikta(g, 0, 255)) * (1 - br[1] / 255 * maske);
      b = 255 - (255 - _aralikta(b, 0, 255)) * (1 - br[2] / 255 * maske);
    }

    // Halasyon: sinema filminde parlak ışığın film tabanından yansıyıp
    // çevresinde bıraktığı kırmızı-turuncu hale
    if (gr.halasyon > 0) {
      final bl = (0.299 * br[0] + 0.587 * br[1] + 0.114 * br[2]) / 255;
      final hale = _aralikta((bl - 0.6) / 0.4, 0, 1) * gr.halasyon;
      r += 90 * hale;
      g += 25 * hale;
    }

    // Mat siyahlar ve yumuşatılmış beyazlar
    if (gr.soluk > 0 || gr.tepe < 255) {
      r = gr.soluk + _aralikta(r, 0, 255) * aralik;
      g = gr.soluk + _aralikta(g, 0, 255) * aralik;
      b = gr.soluk + _aralikta(b, 0, 255) * aralik;
    }

    if (gr.vMiktar > 0) {
      final dx = p.x - cx;
      final dy = p.y - cy;
      final d = math.sqrt(dx * dx + dy * dy) / enUzak;
      if (d > gr.vBaslangic) {
        var t = (d - gr.vBaslangic) / (1 - gr.vBaslangic);
        if (t > 1) t = 1;
        final f = 1 - gr.vMiktar * t * t;
        r *= f;
        g *= f;
        b *= f;
      }
    }

    // Film greni: konuma bağlı sabit gürültü, orta tonlarda daha belirgin
    if (gr.gren > 0) {
      var hs = (p.x * 73856093) ^ (p.y * 19349663);
      hs = (hs ^ (hs >> 13)) * 1274126177;
      hs = hs ^ (hs >> 16);
      final gurultu = ((hs & 0xFF) / 255 - 0.5) * 2;
      final orta = 1 - ((lt * 2) - 1).abs() * 0.6;
      final n = gurultu * gr.gren * orta;
      r += n;
      g += n;
      b += n;
    }

    p.r = _sinirla(r);
    p.g = _sinirla(g);
    p.b = _sinirla(b);
  }
  return im;
}
