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

  @override
  void initState() {
    super.initState();
    _kontrol = CameraController(
      kameralar.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _kontrol!.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((e) {
      setState(() => _hata = 'Kamera açılamadı: $e');
    });
  }

  @override
  void dispose() {
    _kontrol?.dispose();
    super.dispose();
  }

  Future<void> _cek() async {
    final foto = await _kontrol!.takePicture();
    setState(() => _sonFoto = foto.path);
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
      body: Stack(
        children: [
          Center(child: CameraPreview(_kontrol!)),
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
    );
  }
}
