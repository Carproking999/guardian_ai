import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    cameras = [];
  }
  runApp(const GuardianApp());
}

class GuardianApp extends StatelessWidget {
  const GuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Guardian AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.red,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: const GuardHome(),
    );
  }
}

class GuardHome extends StatefulWidget {
  const GuardHome({super.key});

  @override
  State<GuardHome> createState() => _GuardHomeState();
}

class _GuardHomeState extends State<GuardHome> {
  bool _guardActive = false;
  bool _permissionsOk = false;
  String _status = "Guard is OFF";
  int _eventCount = 0;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;

  final double _triggerThresholdDb = 65.0;

  DateTime? _lastTrigger;
  final Duration _cooldown = const Duration(seconds: 15);

  List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _tts.setLanguage("hi-IN");
    _tts.setSpeechRate(0.45);
    _tts.setVolume(1.0);
  }

  Future<void> _checkPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
    ].request();

    final ok = statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;

    setState(() {
      _permissionsOk = ok;
    });
  }

  Future<void> _toggleGuard() async {
    if (!_permissionsOk) {
      await _checkPermissions();
      if (!_permissionsOk) {
        _showSnack("Camera and microphone permissions are required.");
        return;
      }
    }

    if (_guardActive) {
      await _stopGuard();
    } else {
      await _startGuard();
    }
  }

  Future<void> _startGuard() async {
    setState(() {
      _guardActive = true;
      _status = "Guard is ON — listening...";
    });

    try {
      _noiseMeter = NoiseMeter();
      _noiseSubscription = _noiseMeter!.noise.listen(
        _onNoiseReading,
        onError: (e) {
          _showSnack("Microphone error: $e");
        },
      );
    } catch (e) {
      _showSnack("Could not start listening: $e");
      setState(() {
        _guardActive = false;
        _status = "Guard is OFF";
      });
    }
  }

  Future<void> _stopGuard() async {
    await _noiseSubscription?.cancel();
    _noiseSubscription = null;
    if (await _audioRecorder.isRecording()) {
      await _audioRecorder.stop();
    }
    setState(() {
      _guardActive = false;
      _status = "Guard is OFF";
    });
  }

  void _onNoiseReading(NoiseReading reading) {
    if (!_guardActive) return;

    final now = DateTime.now();
    if (_lastTrigger != null && now.difference(_lastTrigger!) < _cooldown) {
      return;
    }

    if (reading.meanDecibel >= _triggerThresholdDb) {
      _lastTrigger = now;
      _triggerCapture();
    }
  }

  Future<void> _triggerCapture() async {
    setState(() {
      _status = "Sound detected! Capturing...";
      _eventCount++;
    });

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');

    try {
      if (cameras.isNotEmpty) {
        final controller = CameraController(
          cameras.first,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await controller.initialize();
        final dir = await getApplicationDocumentsDirectory();
        final photoPath = '${dir.path}/guard_$timestamp.jpg';
        final file = await controller.takePicture();
        await file.saveTo(photoPath);
        await controller.dispose();
        _addLog("Photo captured: guard_$timestamp.jpg");
      }
    } catch (e) {
      _addLog("Photo capture failed: $e");
    }

    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final audioPath = '${dir.path}/guard_audio_$timestamp.m4a';
        await _audioRecorder.start(
          const RecordConfig(),
          path: audioPath,
        );
        _addLog("Audio recording started: guard_audio_$timestamp.m4a");

        Future.delayed(const Duration(seconds: 20), () async {
          await _tts.speak(
            "Aap bina permission ke andar aa gaye hain. "
            "Aapki recording shuru ho gayi hai. "
            "Kripya yahan se chale jayein.",
          );
          _addLog("Warning spoken to intruder.");

          if (await _audioRecorder.isRecording()) {
            await _audioRecorder.stop();
            _addLog("Audio recording saved.");
          }
        });
      }
    } catch (e) {
      _addLog("Audio recording failed: $e");
    }

    setState(() {
      _status = "Guard is ON — listening...";
    });
  }

  void _addLog(String message) {
    setState(() {
      _log.insert(0, "${DateTime.now().toLocal().toString().substring(11, 19)}  $message");
      if (_log.length > 50) _log.removeLast();
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _noiseSubscription?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardian AI'),
        backgroundColor: Colors.black,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _toggleGuard,
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _guardActive ? Colors.red : Colors.grey[800],
                  boxShadow: _guardActive
                      ? [
                          BoxShadow(
                            color: Colors.red.withOpacity(0.6),
                            blurRadius: 30,
                            spreadRadius: 5,
                          )
                        ]
                      : [],
                ),
                child: Icon(
                  _guardActive ? Icons.shield : Icons.shield_outlined,
                  size: 80,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _status,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              "Events triggered: $_eventCount",
              style: TextStyle(color: Colors.grey[400]),
            ),
            const SizedBox(height: 20),
            if (!_permissionsOk)
              const Text(
                "Camera & microphone permission needed",
                style: TextStyle(color: Colors.orange),
              ),
            const Divider(color: Colors.grey),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("Activity Log", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _log[index],
                      style: const TextStyle(fontSize: 13, color: Colors.greenAccent),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
