import 'ai_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'welcome_robot.dart';

const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

List<CameraDescription> cameras = [];
final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    cameras = [];
  }

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await notifications.initialize(initSettings);

  runApp(const GuardianApp());
}

class GuardianApp extends StatefulWidget {
  const GuardianApp({super.key});

  @override
  State<GuardianApp> createState() => _GuardianAppState();
}

class _GuardianAppState extends State<GuardianApp> {
  bool _showWelcome = true;

  void _finishWelcome() {
    setState(() {
      _showWelcome = false;
    });
  }

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
      home: _showWelcome
          ? WelcomeRobotScreen(onFinished: _finishWelcome)
          : const LockGate(),
    );
  }
}

// ---------------- PIN LOCK GATE ----------------
class LockGate extends StatefulWidget {
  const LockGate({super.key});
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  String? _savedPin;
  bool _loading = true;
  bool _unlocked = false;
  String _entered = "";
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPin();
  }

  Future<void> _loadPin() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _savedPin = prefs.getString('app_pin');
      _loading = false;
    });
  }

  Future<void> _savePin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_pin', pin);
    setState(() {
      _savedPin = pin;
      _unlocked = true;
    });
  }

  void _submit() {
    if (_savedPin == null) {
      if (_entered.length < 4) {
        setState(() => _error = "PIN kam se kam 4 digit ka rakhein");
        return;
      }
      _savePin(_entered);
    } else {
      if (_entered == _savedPin) {
        setState(() => _unlocked = true);
      } else {
        setState(() {
          _error = "Galat PIN";
          _entered = "";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_unlocked) {
      return const GuardHome();
    }

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, size: 60, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                _savedPin == null ? "Naya PIN set karein" : "PIN daalein",
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextField(
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(fontSize: 24, letterSpacing: 8),
                decoration: const InputDecoration(counterText: ""),
                onChanged: (v) => _entered = v,
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.orange)),
                ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _submit,
                child: Text(_savedPin == null ? "PIN Set Karein" : "Unlock"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- MAIN GUARD SCREEN ----------------
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

  bool _silentMode = false;
  bool _batterySaver = false;
  String? _homeWifiName;
  String? _emergencyNumber;

  final AudioRecorder _audioRecorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
    final AIService _aiService = AIService();
  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;

  final double _triggerThresholdDb = 65.0;
  DateTime? _lastTrigger;
  final Duration _cooldown = const Duration(seconds: 15);

  int _rapidTriggerCount = 0;
  DateTime? _rapidWindowStart;

  List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _tts.setLanguage("hi-IN");
    _tts.setSpeechRate(0.45);
    _tts.setVolume(1.0);
    _loadSettings();
    _cleanOldFiles();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _silentMode = prefs.getBool('silent_mode') ?? false;
      _batterySaver = prefs.getBool('battery_saver') ?? false;
      _homeWifiName = prefs.getString('home_wifi');
      _emergencyNumber = prefs.getString('emergency_number');
    });
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is String) await prefs.setString(key, value);
  }

  // Auto-delete files older than 7 days
  Future<void> _cleanOldFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir.listSync();
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final f in files) {
        if (f is File) {
          final stat = await f.stat();
          if (stat.modified.isBefore(cutoff)) {
            await f.delete();
          }
        }
      }
    } catch (e) {
      // ignore cleanup errors
    }
  }

  Future<void> _checkPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.storage,
      Permission.notification,
    ].request();

    final ok = statuses[Permission.camera]!.isGranted &&
        statuses[Permission.microphone]!.isGranted;

    setState(() {
      _permissionsOk = ok;
    });
  }

  Future<bool> _isOnHomeWifi() async {
    if (_homeWifiName == null || _homeWifiName!.isEmpty) return false;
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) return false;
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      if (ssid == null) return false;
      final cleanSsid = ssid.replaceAll('"', '');
      return cleanSsid == _homeWifiName;
    } catch (e) {
      return false;
    }
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
      final onHomeWifi = await _isOnHomeWifi();
      if (onHomeWifi) {
        _showSnack("Aap home WiFi par hain — guard mode zaroori nahi.");
        _addLog("Guard mode skipped: home WiFi detected.");
        return;
      }
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

    _trackRapidTriggers();

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');

    await _showNotification(
      "Guardian AI Alert",
      "Kisi ke room mein enter hone ki awaz detect hui.",
    );

    // 1. Take a photo
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

    // 2. Audio recording (shorter if battery saver is on)
    final recordSeconds = _batterySaver ? 10 : 20;

    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final audioPath = '${dir.path}/guard_audio_$timestamp.m4a';
        await _audioRecorder.start(
          const RecordConfig(),
          path: audioPath,
        );
        _addLog("Audio recording started: guard_audio_$timestamp.m4a");

        Future.delayed(Duration(seconds: recordSeconds), () async {
          if (!_silentMode) {
            await _tts.speak(
              "Aap bina permission ke andar aa gaye hain. "
              "Aapki recording shuru ho gayi hai. "
              "Kripya yahan se chale jayein.",
            );
            _addLog("Warning spoken to intruder.");
          }

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

  // If 3+ events happen within 2 minutes, treat as suspicious and offer SOS
  void _trackRapidTriggers() {
    final now = DateTime.now();
    if (_rapidWindowStart == null ||
        now.difference(_rapidWindowStart!) > const Duration(minutes: 2)) {
      _rapidWindowStart = now;
      _rapidTriggerCount = 1;
    } else {
      _rapidTriggerCount++;
    }

    if (_rapidTriggerCount >= 3) {
      _rapidTriggerCount = 0;
      _offerSOS();
    }
  }

  Future<void> _offerSOS() async {
    if (_emergencyNumber == null || _emergencyNumber!.isEmpty) return;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Baar baar activity detect hui"),
        content: const Text("Kya aap apne emergency contact ko SMS bhejna chahte hain?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Nahi"),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _sendSOS();
            },
            child: const Text("Haan, SMS bhejein"),
          ),
        ],
      ),
    );
  }

  Future<void> _sendSOS() async {
    if (_emergencyNumber == null) return;
    final uri = Uri.parse(
      "sms:$_emergencyNumber?body=${Uri.encodeComponent('Guardian AI alert: Bar bar activity detect hui mere room mein. Turant check karein.')}",
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      _addLog("SOS SMS app opened for $_emergencyNumber");
    }
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'guardian_channel',
      'Guardian Alerts',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
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
        actions: [
          IconButton(
            icon: const Icon(Icons.mic),
            tooltip: 'Live AI Chat',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LiveChatScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.translate),
            tooltip: 'Live Translate',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TranslateScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.photo_library),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GalleryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              _loadSettings();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _toggleGuard,
              child: Container(
                width: 170,
                height: 170,
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
                  size: 75,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _status,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              "Events triggered: $_eventCount",
              style: TextStyle(color: Colors.grey[400]),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (_silentMode) const Chip(label: Text("Silent Mode")),
                if (_batterySaver) const Chip(label: Text("Battery Saver")),
              ],
            ),
            if (!_permissionsOk)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  "Camera & microphone permission needed",
                  style: TextStyle(color: Colors.orange),
                ),
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

// ---------------- GALLERY SCREEN ----------------
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<FileSystemEntity> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final all = dir.listSync()
      ..sort((a, b) => b.path.compareTo(a.path));
    setState(() {
      _files = all.where((f) => f.path.contains('guard_')).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Captured Files")),
      body: _files.isEmpty
          ? const Center(child: Text("Koi files nahi hain abhi tak"))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                final isImage = file.path.endsWith('.jpg');
                return ListTile(
                  leading: Icon(isImage ? Icons.image : Icons.mic),
                  title: Text(file.path.split('/').last),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.redAccent),
                    onPressed: () async {
                      await File(file.path).delete();
                      _loadFiles();
                    },
                  ),
                );
              },
            ),
    );
  }
}

// ---------------- SETTINGS SCREEN ----------------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _silentMode = false;
  bool _batterySaver = false;
  final _wifiController = TextEditingController();
  final _emergencyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _silentMode = prefs.getBool('silent_mode') ?? false;
      _batterySaver = prefs.getBool('battery_saver') ?? false;
      _wifiController.text = prefs.getString('home_wifi') ?? '';
      _emergencyController.text = prefs.getString('emergency_number') ?? '';
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('silent_mode', _silentMode);
    await prefs.setBool('battery_saver', _batterySaver);
    await prefs.setString('home_wifi', _wifiController.text.trim());
    await prefs.setString('emergency_number', _emergencyController.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text("Silent Mode"),
            subtitle: const Text("Warning bola nahi jayega, sirf recording hogi"),
            value: _silentMode,
            onChanged: (v) => setState(() => _silentMode = v),
          ),
          SwitchListTile(
            title: const Text("Battery Saver"),
            subtitle: const Text("Kam recording duration, battery bachegi"),
            value: _batterySaver,
            onChanged: (v) => setState(() => _batterySaver = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _wifiController,
            decoration: const InputDecoration(
              labelText: "Home WiFi naam (SSID)",
              helperText: "Isse jude hone par guard mode auto-skip hoga",
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emergencyController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: "Emergency contact number",
              helperText: "Baar baar alert aane par SMS bhejne ke liye",
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _save, child: const Text("Save")),
        ],
      ),
    );
  }
}

// ---------------- GEMINI HELPER ----------------
Future<String> askGemini(String prompt) async {
  if (geminiApiKey.isEmpty) {
    return "Error: API key set nahi hai.";
  }
  final url = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$geminiApiKey',
  );
  try {
    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ]
      }),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['candidates'][0]['content']['parts'][0]['text'] ??
          "Koi jawab nahi mila.";
    } else {
      return "Error: ${response.statusCode} — ${response.body}";
    }
  } catch (e) {
    return "Connection error: $e";
  }
}

// ---------------- LIVE AI CHAT SCREEN ----------------
class LiveChatScreen extends StatefulWidget {
  const LiveChatScreen({super.key});
  @override
  State<LiveChatScreen> createState() => _LiveChatScreenState();
}

class _LiveChatScreenState extends State<LiveChatScreen> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _listening = false;
  bool _busy = false;
  String _heard = "";
  List<Map<String, String>> _messages = [];

  String _language = "hi-IN";

  @override
  void initState() {
    super.initState();
    _tts.setLanguage(_language);
  }

  Future<void> _startListening() async {
    final available = await _speech.initialize();
    if (!available) {
      _showSnack("Speech recognition available nahi hai.");
      return;
    }
    setState(() {
      _listening = true;
      _heard = "";
    });
    _speech.listen(
      localeId: _language,
      onResult: (result) {
        setState(() {
          _heard = result.recognizedWords;
        });
        if (result.finalResult) {
          _handleFinalSpeech(result.recognizedWords);
        }
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _listening = false);
  }

  Future<void> _handleFinalSpeech(String text) async {
    if (text.trim().isEmpty) return;
    await _stopListening();
    setState(() {
      _busy = true;
      _messages.add({'role': 'user', 'text': text});
    });

    final reply = await askGemini(text);
      
final reply = await _aiService.sendMessage(text);
    setState(() {
      _messages.add({'role': 'ai', 'text': reply});
      _busy = false;
    });

    await _tts.setLanguage(_language);
    await _tts.speak(reply);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Live AI Chat"),
        actions: [
          DropdownButton<String>(
            value: _language,
            dropdownColor: Colors.black,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: "hi-IN", child: Text("Hindi")),
              DropdownMenuItem(value: "ur-PK", child: Text("Urdu")),
              DropdownMenuItem(value: "en-US", child: Text("English")),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _language = v);
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.red[900] : Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(msg['text'] ?? ''),
                  ),
                );
              },
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_heard.isNotEmpty && _listening)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _heard,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: GestureDetector(
              onTap: _listening ? _stopListening : _startListening,
              child: CircleAvatar(
                radius: 32,
                backgroundColor: _listening ? Colors.red : Colors.grey[700],
                child: Icon(
                  _listening ? Icons.stop : Icons.mic,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- LIVE TRANSLATE SCREEN ----------------
class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key});
  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _listening = false;
  bool _busy = false;

  String _fromLang = "ur-PK";
  String _toLang = "en-US";

  String _originalText = "";
  String _translatedText = "";

  final Map<String, String> _langNames = {
    "hi-IN": "Hindi",
    "ur-PK": "Urdu",
    "en-US": "English",
  };

  Future<void> _startListening() async {
    final available = await _speech.initialize();
    if (!available) {
      _showSnack("Speech recognition available nahi hai.");
      return;
    }
    setState(() {
      _listening = true;
      _originalText = "";
      _translatedText = "";
    });
    _speech.listen(
      localeId: _fromLang,
      onResult: (result) {
        setState(() {
          _originalText = result.recognizedWords;
        });
        if (result.finalResult) {
          _translate(result.recognizedWords);
        }
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _listening = false);
  }

  Future<void> _translate(String text) async {
    if (text.trim().isEmpty) return;
    await _stopListening();
    setState(() => _busy = true);

    final fromName = _langNames[_fromLang];
    final toName = _langNames[_toLang];
    final prompt =
        "Translate this $fromName text to $toName. Reply with ONLY the translation, nothing else: \"$text\"";

    final result = await askGemini(prompt);

    setState(() {
      _translatedText = result.trim();
      _busy = false;
    });

    await _tts.setLanguage(_toLang);
    await _tts.speak(_translatedText);
  }

  void _swapLanguages() {
    setState(() {
      final temp = _fromLang;
      _fromLang = _toLang;
      _toLang = temp;
      _originalText = "";
      _translatedText = "";
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Widget _langDropdown(String value, ValueChanged<String?> onChanged) {
    return DropdownButton<String>(
      value: value,
      dropdownColor: Colors.grey[900],
      items: _langNames.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Live Translate")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _langDropdown(_fromLang, (v) {
                  if (v != null) setState(() => _fromLang = v);
                }),
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: _swapLanguages,
                ),
                _langDropdown(_toLang, (v) {
                  if (v != null) setState(() => _toLang = v);
                }),
              ],
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _originalText.isEmpty ? "Bolne ke liye mic dabayein..." : _originalText,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red[900],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _translatedText.isEmpty ? "Translation yahan aayega" : _translatedText,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _listening ? _stopListening : _startListening,
              child: CircleAvatar(
                radius: 32,
                backgroundColor: _listening ? Colors.red : Colors.grey[700],
                child: Icon(
                  _listening ? Icons.stop : Icons.mic,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
