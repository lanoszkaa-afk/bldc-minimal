import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:usb_serial/usb_serial.dart' as usb;
import 'package:share_plus/share_plus.dart';

import '../utils/serial_line_parser.dart';
import 'clutch_map_screen.dart';
import 'flywheel_map_screen.dart';
import 'map_editor_screen.dart';
import 'ramp_map_screen.dart';
import 'throttle_map_screen.dart';

class ConfigScreen extends StatefulWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;

  const ConfigScreen({
    super.key,
    this.serialPort,
    this.usbPort,
    required this.isConnected,
    this.dataStream,
  });

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> with SerialLineParser {
  bool _isLoading = false;
  String _status = 'Rozłączony';
  String? _error;

  final Map<String, dynamic> _config = {
    'paryBiegunow': 5,
    'filtrHalla': 100,
    'intervalPetli': 5,
    'adcMin': 195,
    'adcMax': 854,
    'pwmMin': 196,
    'pwmMax': 1023,
    'clutchAdcMin': 179,
    'clutchAdcMax': 683,
    'clutchEnabled': true,
    'throttleMapEnabled': true,
    'flywheelEnabled': true,
    'fwGainUpEnabled': true,
    'fwGainDownEnabled': true,
    'flywheelInertia': 4.0,
    'flywheelMaxRPM': 8000.0,
    'fwGainUp': 4.0,
    'fwGainDown': 3.0,
    'idleRPM': 50.0,
    'fwDeadbandEnabled': true,
    'fwDeadbandRPM': 50.0,
    'flySlewEnabled': true,
    'flySlewRecover': 350.0,
    'rpmAlpha': 0.06,
    'flyAlphaTau': 0.04, // tau baza inercji kola v4.8 (wczesniej filtr dRPM/dt)
    'flyKfw': 0.05, // wzmocnienie bledu kola v4.8
  };

  // Fabryczne presety tylko Flutter (nie w firmware) - skala tau=J*TAU, corr=error*K*gain
  static const Map<String, Map<String, dynamic>> kFactoryPresets = {
    'Bardzo lekkie': {'flywheelInertia': 1.0, 'flyAlphaTau': 0.02, 'flyKfw': 0.03, 'fwGainUp': 2.0, 'fwGainDown': 2.0, 'flySlewRecover': 150.0},
    'Lekkie': {'flywheelInertia': 2.0, 'flyAlphaTau': 0.03, 'flyKfw': 0.04, 'fwGainUp': 3.0, 'fwGainDown': 2.5, 'flySlewRecover': 250.0},
    'Średnie': {'flywheelInertia': 4.0, 'flyAlphaTau': 0.04, 'flyKfw': 0.05, 'fwGainUp': 4.0, 'fwGainDown': 3.0, 'flySlewRecover': 350.0},
    'Mocne': {'flywheelInertia': 6.0, 'flyAlphaTau': 0.05, 'flyKfw': 0.07, 'fwGainUp': 5.0, 'fwGainDown': 4.0, 'flySlewRecover': 500.0},
    'Bardzo mocne': {'flywheelInertia': 8.0, 'flyAlphaTau': 0.05, 'flyKfw': 0.10, 'fwGainUp': 6.0, 'fwGainDown': 5.0, 'flySlewRecover': 700.0},
  };

  List<String> _presets = [];
  final TextEditingController _presetNameController = TextEditingController();

  late final Map<String, TextEditingController> _controllers;
  StreamSubscription? _readSubscription;
  final List<String> _responseBuffer = [];
  bool _readingConfig = false;
  Timer? _configTimeout;

  String? _pendingCmd;
  Timer? _pendingTimer;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final key in _config.keys) key: TextEditingController(),
    };
    _updateControllers();
    _setupSerialListener();
    _loadPresets();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final isOpen = widget.isConnected ||
          (widget.serialPort != null && widget.serialPort!.isOpen()) ||
          (widget.usbPort != null);
      if (isOpen) {
        _readConfig();
      }
    });
  }

  void _updateControllers() {
    for (final entry in _config.entries) {
      _controllers[entry.key]?.text = entry.value.toString();
    }
  }

  void _setupSerialListener() {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (isOpen) {
      setState(() { _status = 'Połączony'; });

      if (widget.dataStream != null) {
        _readSubscription = widget.dataStream!.listen(
          (String text) { _onSerialData(text); },
          onError: (e) {
            if (mounted) setState(() { _status = 'Błąd: $e'; });
          },
        );
      }
    }
  }

  String? _pendingKey; // config key to update on OK confirmation

  void _clearPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingCmd = null;
    _pendingKey = null;
  }

  void _setPending(String cmd, {String? configKey}) {
    _clearPending();
    _pendingCmd = cmd;
    _pendingKey = configKey;
    _pendingTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _pendingCmd != null) {
        setState(() { _isLoading = false; _readingConfig = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Timeout: $_pendingCmd'), backgroundColor: Colors.orange.shade700),
        );
        _pendingCmd = null;
        _pendingKey = null;
      }
    });
  }

  void _onSerialData(String text) {
    parseSerialText(text, (line) {
      if (!_readingConfig && line == 'cs') {
        _readingConfig = true;
        _responseBuffer.clear();
        return;
      }
      if (_readingConfig) {
        if (line == 'cfe') {
          _parseConfigResponse();
        } else {
          _responseBuffer.add(line);
        }
        return;
      }

      // Potwierdzenie OK (dla set, gc, i wszystkich komend)
      if (line == 'OK') {
        if (_pendingCmd != null) {
          final cmd = _pendingCmd!;
          final key = _pendingKey;
          _clearPending();
          setState(() {
            _isLoading = false;
            if (key != null && _config.containsKey(key)) {
              _config[key] = cmd.contains('on');
            }
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('OK: $cmd'), backgroundColor: Colors.green.shade700,
                duration: const Duration(seconds: 2)),
            );
          }
        }
        return;
      }

      // Obsluga bledow (e:...)
      if (line.startsWith('e:') || line.startsWith('E:')) {
        _clearPending();
        setState(() { _isLoading = false; _readingConfig = false; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Blad: $line'), backgroundColor: Colors.red.shade700, duration: const Duration(seconds: 3)),
          );
        }
      }
    });
  }

  void _parseConfigResponse() {
    _configTimeout?.cancel();
    _configTimeout = null;

    final keyMapping = {
      'poles': 'paryBiegunow',
      'filter': 'filtrHalla',
      'loop': 'intervalPetli',
      'gasmin': 'adcMin',
      'gasmax': 'adcMax',
      'pwmmin': 'pwmMin',
      'pwmmax': 'pwmMax',
      'clmin': 'clutchAdcMin',
      'clmax': 'clutchAdcMax',
      'clen': 'clutchEnabled',
      'then': 'throttleMapEnabled',
      'flywheel': 'flywheelEnabled',
      'fwgainupenabled': 'fwGainUpEnabled',
      'fwgaindownenabled': 'fwGainDownEnabled',
      'flywheelinertia': 'flywheelInertia',
      'flywheelmax': 'flywheelMaxRPM',
        'fwgainup': 'fwGainUp',
        'fwgaindown': 'fwGainDown',
      'fwdeadband': 'fwDeadbandEnabled',
      'fwdeadbandrpm': 'fwDeadbandRPM',
      'fwslew': 'flySlewRecover',
      'fwslewenabled': 'flySlewEnabled',
      'idle': 'idleRPM',
      'rpma': 'rpmAlpha',
      'alpha': 'flyAlphaTau',
      'flyk': 'flyKfw',
      'flyrpm': 'flywheelRPM', // tylko do odczytu, debug
    };

    for (final line in _responseBuffer) {
      if (line == 'cs' || line == 'cfe') continue;
      final parts = line.split(',');
      if (parts.length == 2) {
        final shortKey = parts[0].trim();
        final value = parts[1].trim();
        final fullKey = keyMapping[shortKey];

        if (fullKey != null && _config.containsKey(fullKey)) {
          if (fullKey == 'clutchEnabled' || fullKey == 'throttleMapEnabled' || fullKey == 'flywheelEnabled' || fullKey == 'fwGainUpEnabled' || fullKey == 'fwGainDownEnabled' || fullKey == 'fwDeadbandEnabled' || fullKey == 'flySlewEnabled') {
            _config[fullKey] = (value.toLowerCase() == 'true' || value == '1');
          } else if (fullKey == 'flywheelInertia' || fullKey == 'flywheelMaxRPM' || fullKey == 'fwGainUp' || fullKey == 'fwGainDown' || fullKey == 'idleRPM' || fullKey == 'fwDeadbandRPM' || fullKey == 'flySlewRecover' || fullKey == 'rpmAlpha' || fullKey == 'flyAlphaTau' || fullKey == 'flyKfw') {
            _config[fullKey] = double.tryParse(value) ?? _config[fullKey];
          } else if (fullKey == 'flywheelRPM') {
            // read-only debug, ignore
          } else {
            _config[fullKey] = int.tryParse(value) ?? _config[fullKey];
          }
        }
      }
    }

    setState(() {
      _readingConfig = false;
      _responseBuffer.clear();
      _updateControllers();
    });
  }

  void _readConfig() {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) {
      setState(() { _error = 'Najpierw połącz się z portem w głównym oknie'; });
      return;
    }

    setState(() {
      _isLoading = true;
      _readingConfig = false;
      _responseBuffer.clear();
      resetSerialBuffer();
    });
    _setPending('gc');

    try {
      if (widget.usbPort != null) {
        widget.usbPort!.write(Uint8List.fromList(utf8.encode('gc\r\n')));
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(Uint8List.fromList(utf8.encode('gc\r\n')));
      }
    } catch (e) {
      _clearPending();
      setState(() {
        _isLoading = false;
        _readingConfig = false;
        _error = 'Błąd wysyłania: $e';
      });
    }
  }

  void _saveParameter(String param, String value) {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) {
      setState(() { _error = 'Brak połączenia'; });
      return;
    }

    String cmd = '';
    switch (param) {
      case 'paryBiegunow': cmd = 'set poles $value'; break;
      case 'filtrHalla': cmd = 'set filter $value'; break;
      case 'intervalPetli': cmd = 'set loop $value'; break;
      case 'pwmMin': cmd = 'set pwmmin $value'; break;
      case 'pwmMax': cmd = 'set pwmmax $value'; break;
      case 'adcMin': cmd = 'set gasmin $value'; break;
      case 'adcMax': cmd = 'set gasmax $value'; break;
      case 'clutchAdcMin': cmd = 'set clmin $value'; break;
      case 'clutchAdcMax': cmd = 'set clmax $value'; break;
      case 'flywheelInertia': cmd = 'set flywheelinertia $value'; break;
      case 'flywheelMaxRPM': cmd = 'set flywheelmax $value'; break;
      case 'fwGainUp': cmd = 'set fwgainup $value'; break;
      case 'fwGainDown': cmd = 'set fwgaindown $value'; break;
      case 'fwDeadbandRPM': cmd = 'set fwdeadbandrpm $value'; break;
      case 'flySlewRecover': cmd = 'set fwslew $value'; break;
      case 'rpmAlpha': cmd = 'set rpma $value'; break;
      case 'flyAlphaTau': cmd = 'set alpha $value'; break;
      case 'flyKfw': cmd = 'set flyk $value'; break;
      case 'idleRPM': cmd = 'set idle $value'; break;
      default: return;
    }

    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }

      _setPending(cmd);
    } catch (e) {
      setState(() { _error = 'Błąd zapisu: $e'; });
    }
  }

  Future<void> _toggleClutch(bool value) async {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    final cmd = value ? 'set clen on' : 'set clen off';
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
      _setPending(cmd, configKey: 'clutchEnabled');
    } catch (e) { setState(() { _error = 'Błąd: $e'; }); }
  }

  Future<void> _toggleThrottleMap(bool value) async {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    final cmd = value ? 'set then on' : 'set then off';
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
      _setPending(cmd, configKey: 'throttleMapEnabled');
    } catch (e) { setState(() { _error = 'Błąd: $e'; }); }
  }

  Future<void> _toggleFlywheel(bool value) async {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    final cmd = value ? 'set flywheel on' : 'set flywheel off';
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
      _setPending(cmd, configKey: 'flywheelEnabled');
    } catch (e) { setState(() { _error = 'Błąd: $e'; }); }
  }

  void _calibrateThrottle() {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kalibracja gazu'),
        content: const Text(
          'ZATRZYMAJ SILNIK!\n\n'
          'FAZA 1: Puść gaz całkowicie (3s + 5s kalibracji)\n'
          'FAZA 2: Wciśnij PEŁNY gaz (3s + 5s kalibracji)\n\n'
          'Czy chcesz kontynuować?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Anuluj')),
          ElevatedButton(onPressed: () { Navigator.of(context).pop(); _startCalibrationWithMonitor(); }, child: const Text('Rozpocznij')),
        ],
      ),
    );
  }

  void _calibrateClutch() {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kalibracja sprzęgła'),
        content: const Text(
          'ZATRZYMAJ SILNIK!\n\n'
          'FAZA 1: Puść sprzęgło całkowicie\n'
          '  → Zapisze ADC min\n'
          '  → 3s + 5s kalibracji\n\n'
          'FAZA 2: Wciśnij sprzęgło do końca\n'
          '  → Zapisze ADC max\n'
          '  → 3s + 5s kalibracji\n\n'
          'Czy chcesz kontynuować?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Anuluj')),
          ElevatedButton(onPressed: () { Navigator.of(context).pop(); _startClutchCalibrationWithMonitor(); }, child: const Text('Rozpocznij')),
        ],
      ),
    );
  }

  void _startCalibrationWithMonitor() {
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('cal\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
    } catch (e) { setState(() { _error = 'Błąd: $e'; }); return; }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CalibrationMonitorDialog(
        dataStream: widget.dataStream,
        title: 'Kalibracja gazu',
      ),
    );
  }

  void _startClutchCalibrationWithMonitor() {
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('cc\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
    } catch (e) { setState(() { _error = 'Błąd: $e'; }); return; }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CalibrationMonitorDialog(
        dataStream: widget.dataStream,
        title: 'Kalibracja sprzęgła',
      ),
    );
  }

  void _openClutchMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ClutchMapScreen(
          serialPort: widget.serialPort,
          usbPort: widget.usbPort,
          isConnected: widget.isConnected,
          dataStream: widget.dataStream,
        ),
      ),
    );
  }

  void _openThrottleMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ThrottleMapScreen(
          serialPort: widget.serialPort,
          usbPort: widget.usbPort,
          isConnected: widget.isConnected,
          dataStream: widget.dataStream,
        ),
      ),
    );
  }

  void _openFlywheelMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FlywheelMapScreen(
          serialPort: widget.serialPort,
          usbPort: widget.usbPort,
          isConnected: widget.isConnected,
          dataStream: widget.dataStream,
          flywheelMaxRPM: (_config['flywheelMaxRPM'] as num?)?.toDouble() ?? 8000.0,
        ),
      ),
    );
  }

  void _openRampMap() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RampMapScreen(
          serialPort: widget.serialPort,
          usbPort: widget.usbPort,
          isConnected: widget.isConnected,
          dataStream: widget.dataStream,
        ),
      ),
    );
  }

  Future<String> _presetsFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}${Platform.pathSeparator}presets.json';
  }

  Future<void> _loadPresets() async {
    try {
      final path = await _presetsFilePath();
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = json.decode(content) as Map<String, dynamic>;
        if (mounted) setState(() => _presets = decoded.keys.toList()..sort());
      }
    } catch (_) {}
  }

  Future<void> _savePreset() async {
    final name = _presetNameController.text.trim();
    if (name.isEmpty) return;
    try {
      final path = await _presetsFilePath();
      final file = File(path);
      Map<String, dynamic> all = {};
      if (await file.exists()) {
        all = json.decode(await file.readAsString()) as Map<String, dynamic>;
      }
      all[name] = Map<String, dynamic>.from(_config);
      all[name]!['paryBiegunow'] = int.tryParse(_controllers['paryBiegunow']?.text ?? '') ?? _config['paryBiegunow'];
      all[name]!['filtrHalla'] = int.tryParse(_controllers['filtrHalla']?.text ?? '') ?? _config['filtrHalla'];
      all[name]!['intervalPetli'] = int.tryParse(_controllers['intervalPetli']?.text ?? '') ?? _config['intervalPetli'];
      all[name]!['adcMin'] = int.tryParse(_controllers['adcMin']?.text ?? '') ?? _config['adcMin'];
      all[name]!['adcMax'] = int.tryParse(_controllers['adcMax']?.text ?? '') ?? _config['adcMax'];
      all[name]!['pwmMin'] = int.tryParse(_controllers['pwmMin']?.text ?? '') ?? _config['pwmMin'];
      all[name]!['pwmMax'] = int.tryParse(_controllers['pwmMax']?.text ?? '') ?? _config['pwmMax'];
      all[name]!['clutchAdcMin'] = int.tryParse(_controllers['clutchAdcMin']?.text ?? '') ?? _config['clutchAdcMin'];
      all[name]!['clutchAdcMax'] = int.tryParse(_controllers['clutchAdcMax']?.text ?? '') ?? _config['clutchAdcMax'];
      all[name]!['flywheelInertia'] = double.tryParse(_controllers['flywheelInertia']?.text ?? '') ?? _config['flywheelInertia'];
      all[name]!['flywheelMaxRPM'] = double.tryParse(_controllers['flywheelMaxRPM']?.text ?? '') ?? _config['flywheelMaxRPM'];
      all[name]!['fwGainUp'] = double.tryParse(_controllers['fwGainUp']?.text ?? '') ?? _config['fwGainUp'];
      all[name]!['fwGainDown'] = double.tryParse(_controllers['fwGainDown']?.text ?? '') ?? _config['fwGainDown'];
      all[name]!['idleRPM'] = double.tryParse(_controllers['idleRPM']?.text ?? '') ?? _config['idleRPM'];      all[name]!['clutchEnabled'] = _config['clutchEnabled'];
      all[name]!['throttleMapEnabled'] = _config['throttleMapEnabled'];
      all[name]!['flywheelEnabled'] = _config['flywheelEnabled'];      await file.writeAsString(json.encode(all));
      _presetNameController.clear();
      if (mounted) {
        setState(() => _presets = all.keys.toList()..sort());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Zapisano preset "$name"')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Błąd zapisu presetu: $e');
    }
  }

  Future<void> _loadPreset(String name) async {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    try {
      final path = await _presetsFilePath();
      final file = File(path);
      if (!await file.exists()) return;
      final all = json.decode(await file.readAsString()) as Map<String, dynamic>;
      final preset = all[name] as Map<String, dynamic>;
      if (preset == null) return;

      for (final key in _saveParameterKeys) {
        if (preset.containsKey(key)) {
          _saveParameter(key, preset[key].toString());
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      for (final key in _toggleKeys) {
        if (preset.containsKey(key)) {
          _toggleParameter(key, preset[key] as bool);
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Załadowano preset "$name"')));
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) _readConfig();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Błąd ładowania presetu: $e');
    }
  }

  Future<void> _deletePreset(String name) async {
    try {
      final path = await _presetsFilePath();
      final file = File(path);
      if (!await file.exists()) return;
      final all = json.decode(await file.readAsString()) as Map<String, dynamic>;
      all.remove(name);
      await file.writeAsString(json.encode(all));
      if (mounted) {
        setState(() => _presets = all.keys.toList()..sort());
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Usunięto preset "$name"')));
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Błąd usuwania presetu: $e');
    }
  }

  Future<void> _applyFactoryPreset(String name) async {
    final preset = kFactoryPresets[name];
    if (preset == null) return;
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() => _error = 'Brak połączenia - preset wczytany lokalnie'); }
    // lokalnie w _config + wyslij do Arduino jesli polaczony
    for (final entry in preset.entries) {
      _config[entry.key] = entry.value;
      _controllers[entry.key]?.text = entry.value.toString();
      if (isOpen) {
        _saveParameter(entry.key, entry.value.toString());
        await Future.delayed(const Duration(milliseconds: 80));
      }
    }
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Zastosowano fabryczny preset "$name"'), backgroundColor: Colors.teal.shade700));
      if (isOpen) Future.delayed(const Duration(seconds: 1), () { if (mounted) _readConfig(); });
    }
  }

  static const List<String> _saveParameterKeys = [
    'paryBiegunow', 'filtrHalla', 'intervalPetli',
    'pwmMin', 'pwmMax', 'adcMin', 'adcMax',
    'clutchAdcMin', 'clutchAdcMax',
    'flywheelInertia', 'flywheelMaxRPM', 'fwGainUp', 'fwGainDown',
    'idleRPM', 'fwDeadbandRPM', 'flySlewRecover',
    'rpmAlpha', 'flyAlphaTau', 'flyKfw'
  ];

  static const List<String> _toggleKeys = [
    'clutchEnabled', 'throttleMapEnabled',
    'flywheelEnabled',
    'fwGainUpEnabled', 'fwGainDownEnabled', 'fwDeadbandEnabled', 'flySlewEnabled'
  ];

  void _toggleParameter(String param, bool value) {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) return;

    String cmd = '';
    switch (param) {
      case 'clutchEnabled': cmd = value ? 'set clen on' : 'set clen off'; break;
      case 'throttleMapEnabled': cmd = value ? 'set then on' : 'set then off'; break;
      case 'flywheelEnabled': cmd = value ? 'set flywheel on' : 'set flywheel off'; break;
      case 'fwGainUpEnabled': cmd = value ? 'set fwgainenabledup on' : 'set fwgainenabledup off'; break;
      case 'fwGainDownEnabled': cmd = value ? 'set fwgainenableddown on' : 'set fwgainenableddown off'; break;
      case 'fwDeadbandEnabled': cmd = value ? 'set fwdeadband on' : 'set fwdeadband off'; break;
      case 'flySlewEnabled': cmd = value ? 'set fwslew on' : 'set fwslew off'; break;      default: return;
    }
    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
    } catch (_) {}
  }

  void _resetConfig() {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);
    if (!isOpen) { setState(() { _error = 'Brak połączenia'; }); return; }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset ustawień'),
        content: const Text('Czy na pewno chcesz przywrócić ustawienia domyślne?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Anuluj')),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              try {
                final cmdBytes = Uint8List.fromList(utf8.encode('reset\r\n'));
                if (widget.usbPort != null) {
                  widget.usbPort!.write(cmdBytes);
                } else if (widget.serialPort != null) {
                  widget.serialPort!.write(cmdBytes);
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Przywrócono ustawienia domyślne')),
                  );
                }
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) _readConfig();
                });
              } catch (e) { setState(() { _error = 'Błąd: $e'; }); }
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup() async {
    final isOpen = widget.isConnected ||
                   (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                   (widget.usbPort != null);

    Map<String, dynamic> configData = {};
    Map<String, int> clutchMapForJson = {};
    Map<String, int> throttleMapForJson = {};
    Map<String, int> fwUpMapForJson = {};
    Map<String, int> fwDownMapForJson = {};
    Map<String, int> rampMapForJson = {};

    if (!isOpen) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Eksport bez połączenia'),
          content: const Text('Brak połączenia z Arduino.\n\nEksport lokalny zapisze 26 parametrów (teraz kompletny), ale 5 map (sprzęgło/gaz/flywheel/rampa) tylko z Arduino przez kabel - bez kabla mapy będą puste.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Anuluj')),
            ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Eksportuj')),
          ],
        ),
      );
      if (confirmed != true) return;

      final flutterToArduino = {
        'paryBiegunow': 'poles',
        'filtrHalla': 'filter',
        'intervalPetli': 'loop',
        'adcMin': 'gasmin',
        'adcMax': 'gasmax',
        'pwmMin': 'pwmmin',
        'pwmMax': 'pwmmax',
        'clutchAdcMin': 'clmin',
        'clutchAdcMax': 'clmax',
        'clutchEnabled': 'clen',
        'throttleMapEnabled': 'then',
        'flywheelEnabled': 'flywheel',
        'fwGainUpEnabled': 'fwgainupenabled',
        'fwGainDownEnabled': 'fwgaindownenabled',
        'flywheelInertia': 'flywheelinertia',
        'flywheelMaxRPM': 'flywheelmax',
        'fwGainUp': 'fwgainup',
        'fwGainDown': 'fwgaindown',
        'fwDeadbandEnabled': 'fwdeadband',
        'fwDeadbandRPM': 'fwdeadbandrpm',
        'flySlewEnabled': 'fwslewenabled',
        'flySlewRecover': 'fwslew',
        'idleRPM': 'idle',
        'rpmAlpha': 'rpma',
        'flyAlphaTau': 'alpha',
        'flyKfw': 'flyk',
      };

      for (final entry in _config.entries) {
        final arduinoKey = flutterToArduino[entry.key];
        if (arduinoKey != null) {
          if (entry.value is bool) {
            configData[arduinoKey] = entry.value ? '1' : '0';
          } else {
            configData[arduinoKey] = entry.value.toString();
          }
        }
      }
    } else {
      setState(() { _isLoading = true; _status = 'Eksportowanie konfiguracji...'; });

      try {
        String _exportLineBuffer = '';
        void _parseExportLines(String text, void Function(String) onLine) {
          _exportLineBuffer += text;
          while (_exportLineBuffer.contains('\n') || _exportLineBuffer.contains('\r')) {
            int idx = -1;
            for (int i = 0; i < _exportLineBuffer.length; i++) {
              if (_exportLineBuffer[i] == '\n' || _exportLineBuffer[i] == '\r') { idx = i; break; }
            }
            if (idx == -1) break;
            final line = _exportLineBuffer.substring(0, idx).trim();
            int next = idx + 1;
            if (next < _exportLineBuffer.length && _exportLineBuffer[idx] == '\r' && _exportLineBuffer[next] == '\n') next++;
            _exportLineBuffer = _exportLineBuffer.substring(next);
            if (line.isEmpty) continue;
            onLine(line);
          }
        }

        final completer = Completer<void>();
        final responseBuffer = <String>[];
        StreamSubscription? sub;
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'cs') { responseBuffer.clear(); }
            else if (line == 'cfe') { if (!completer.isCompleted) completer.complete(); }
            else if (!completer.isCompleted) { responseBuffer.add(line); }
          });
        });

        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('gc\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('gc\r\n')));
        }
        await completer.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in responseBuffer) {
          final parts = line.split(',');
          if (parts.length == 2) {
            configData[parts[0]] = parts[1];
          }
        }

        // Clutch map
        final clutchCompleter = Completer<void>();
        final clutchBuffer = <String>[];
        _exportLineBuffer = '';
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'clstart') { clutchBuffer.clear(); }
            else if (line == 'clend') { if (!clutchCompleter.isCompleted) clutchCompleter.complete(); }
            else if (!clutchCompleter.isCompleted) { clutchBuffer.add(line); }
          });
        });
        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('scc\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('scc\r\n')));
        }
        await clutchCompleter.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in clutchBuffer) {
          final parts = line.split(':');
          if (parts.length == 2) {
            final idx = int.tryParse(parts[0]);
            final val = int.tryParse(parts[1]);
            if (idx != null && val != null) {
              clutchMapForJson[idx.toString()] = val;
            }
          }
        }

        // Throttle map
        final throttleCompleter = Completer<void>();
        final throttleBuffer = <String>[];
        _exportLineBuffer = '';
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'thstart') { throttleBuffer.clear(); }
            else if (line == 'thend') { if (!throttleCompleter.isCompleted) throttleCompleter.complete(); }
            else if (!throttleCompleter.isCompleted) { throttleBuffer.add(line); }
          });
        });
        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('sth\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('sth\r\n')));
        }
        await throttleCompleter.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in throttleBuffer) {
          final parts = line.split(':');
          if (parts.length == 2) {
            final idx = int.tryParse(parts[0]);
            final val = int.tryParse(parts[1]);
            if (idx != null && val != null) {
              throttleMapForJson[idx.toString()] = val;
            }
          }
        }

        // Flywheel up map
        final fwUpCompleter = Completer<void>();
        final fwUpBuffer = <String>[];
        _exportLineBuffer = '';
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'fwupstart') { fwUpBuffer.clear(); }
            else if (line == 'fwupend') { if (!fwUpCompleter.isCompleted) fwUpCompleter.complete(); }
            else if (!fwUpCompleter.isCompleted) { fwUpBuffer.add(line); }
          });
        });
        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('sfwup\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('sfwup\r\n')));
        }
        await fwUpCompleter.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in fwUpBuffer) {
          final parts = line.split(':');
          if (parts.length == 2) {
            final idx = int.tryParse(parts[0]);
            final val = int.tryParse(parts[1]);
            if (idx != null && val != null) {
              fwUpMapForJson[idx.toString()] = val;
            }
          }
        }

        // Flywheel down map
        final fwDownCompleter = Completer<void>();
        final fwDownBuffer = <String>[];
        _exportLineBuffer = '';
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'fwdownstart') { fwDownBuffer.clear(); }
            else if (line == 'fwdownend') { if (!fwDownCompleter.isCompleted) fwDownCompleter.complete(); }
            else if (!fwDownCompleter.isCompleted) { fwDownBuffer.add(line); }
          });
        });
        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('sfwdown\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('sfwdown\r\n')));
        }
        await fwDownCompleter.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in fwDownBuffer) {
          final parts = line.split(':');
          if (parts.length == 2) {
            final idx = int.tryParse(parts[0]);
            final val = int.tryParse(parts[1]);
            if (idx != null && val != null) {
              fwDownMapForJson[idx.toString()] = val;
            }
          }
        }

        // Ramp map (rampgasmap)
        final rampCompleter = Completer<void>();
        final rampBuffer = <String>[];
        _exportLineBuffer = '';
        sub = widget.dataStream!.listen((text) {
          _parseExportLines(text, (line) {
            if (line == 'srampstart') { rampBuffer.clear(); }
            else if (line == 'srampend') { if (!rampCompleter.isCompleted) rampCompleter.complete(); }
            else if (!rampCompleter.isCompleted) { rampBuffer.add(line); }
          });
        });
        if (widget.usbPort != null) {
          widget.usbPort!.write(Uint8List.fromList(utf8.encode('sramp\r\n')));
        } else if (widget.serialPort != null) {
          widget.serialPort!.write(Uint8List.fromList(utf8.encode('sramp\r\n')));
        }
        await rampCompleter.future.timeout(const Duration(seconds: 3));
        await sub.cancel();

        for (final line in rampBuffer) {
          final parts = line.split(':');
          if (parts.length == 2) {
            final idx = int.tryParse(parts[0]);
            final val = int.tryParse(parts[1]);
            if (idx != null && val != null) {
              rampMapForJson[idx.toString()] = val;
            }
          }
        }

      } catch (e) {
        setState(() { _error = 'Błąd odczytu z Arduino: $e'; _isLoading = false; _status = 'Połączony'; });
        return;
      } finally {
        setState(() { _isLoading = false; _status = 'Połączony'; });
      }
    }

    try {
      final backup = {
        'version': '4.8',
        'timestamp': DateTime.now().toIso8601String(),
        'source': isOpen ? 'arduino' : 'local',
        'config': configData,
        'clutchMap': clutchMapForJson,
        'throttleMap': throttleMapForJson,
        'fwUpMap': fwUpMapForJson,
        'fwDownMap': fwDownMapForJson,
        'rampMap': rampMapForJson,
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(backup);
      final fileName = 'bldc_backup_${DateTime.now().millisecondsSinceEpoch}.json';

      if (Platform.isAndroid) {
        try {
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/$fileName');
          await tempFile.writeAsString(jsonStr);

          final result = await Share.shareXFiles(
            [XFile(tempFile.path)],
            subject: 'Backup konfiguracji BLDC',
            text: 'Eksport konfiguracji BLDC Flywheel v4.8-state (flywheelRPM = avg + error, tau=J*alpha)',
          );

          if (mounted) {
            if (result.status == ShareResultStatus.success) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Plik udostępniony'), backgroundColor: Colors.green),
              );
            } else if (result.status == ShareResultStatus.dismissed) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Anulowano')),
              );
            }
          }
          return;
        } catch (e) { print('Share failed: $e'); }
      }

      try {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'Zapisz backup konfiguracji',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        if (path == null) return;
        final file = File(path);
        await file.writeAsString(jsonStr);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Backup zapisany: $path'), backgroundColor: Colors.green),
          );
        }
      } catch (e) {
        final appDir = await getExternalStorageDirectory();
        String? dir = appDir?.path;
        if (dir == null) {
          final docsDir = await getApplicationDocumentsDirectory();
          dir = docsDir.path;
        }
        final localPath = '$dir${Platform.pathSeparator}$fileName';
        final file = File(localPath);
        await file.writeAsString(jsonStr);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Zapisano lokalnie: $localPath'), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (e) { setState(() { _error = 'Błąd eksportu: $e'; }); }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Wybierz backup konfiguracji',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final jsonStr = await file.readAsString();
      final backup = jsonDecode(jsonStr) as Map<String, dynamic>;

      final config = backup['config'] as Map<String, dynamic>?;
      final clutchMap = backup['clutchMap'] as Map<String, dynamic>?;
      final throttleMap = backup['throttleMap'] as Map<String, dynamic>?;
      final fwUpMap = backup['fwUpMap'] as Map<String, dynamic>?;
      final fwDownMap = backup['fwDownMap'] as Map<String, dynamic>?;
      final rampMap = backup['rampMap'] as Map<String, dynamic>?;

      if (config == null) {
        setState(() { _error = 'Nieprawidłowy format pliku backup'; });
        return;
      }

      final keyMapping = {
        'poles': 'paryBiegunow',
        'filter': 'filtrHalla',
        'loop': 'intervalPetli',
        'gasmin': 'adcMin',
        'gasmax': 'adcMax',
        'pwmmin': 'pwmMin',
        'pwmmax': 'pwmMax',
        'clmin': 'clutchAdcMin',
        'clmax': 'clutchAdcMax',
        'clen': 'clutchEnabled',
        'then': 'throttleMapEnabled',
        'flywheel': 'flywheelEnabled',
        'fwgainupenabled': 'fwGainUpEnabled',
        'fwgaindownenabled': 'fwGainDownEnabled',
      'flywheelinertia': 'flywheelInertia',
      'flywheelmax': 'flywheelMaxRPM',
      'fwgainup': 'fwGainUp',
      'fwgaindown': 'fwGainDown',
        'fwdeadband': 'fwDeadbandEnabled',
        'fwdeadbandrpm': 'fwDeadbandRPM',
        'fwslew': 'flySlewRecover',
        'fwslewenabled': 'flySlewEnabled',
        'idle': 'idleRPM',
        'rpma': 'rpmAlpha',
        'alpha': 'flyAlphaTau',
        'flyk': 'flyKfw',
        'flyrpm': 'flywheelRPM',
      };

      for (final entry in config.entries) {
        final flutterKey = keyMapping[entry.key];
        if (flutterKey != null && _config.containsKey(flutterKey)) {
          final value = entry.value.toString();

          if (flutterKey == 'clutchEnabled' || flutterKey == 'throttleMapEnabled' || flutterKey == 'flywheelEnabled' || flutterKey == 'fwGainUpEnabled' || flutterKey == 'fwGainDownEnabled' || flutterKey == 'fwDeadbandEnabled' || flutterKey == 'flySlewEnabled') {
            _config[flutterKey] = (value == '1' || value.toLowerCase() == 'true');
          } else if (flutterKey == 'flywheelInertia' || flutterKey == 'flywheelMaxRPM' || flutterKey == 'fwGainUp' || flutterKey == 'fwGainDown' || flutterKey == 'idleRPM' || flutterKey == 'fwDeadbandRPM' || flutterKey == 'flySlewRecover' || flutterKey == 'rpmAlpha' || flutterKey == 'flyAlphaTau' || flutterKey == 'flyKfw') {
            _config[flutterKey] = double.tryParse(value) ?? _config[flutterKey];
          } else if (flutterKey == 'flywheelRPM') {
            // read-only debug, skip
          } else {
            _config[flutterKey] = int.tryParse(value) ?? _config[flutterKey];
          }
        }
      }

      setState(() { _updateControllers(); });

      final isOpen = widget.isConnected ||
                     (widget.serialPort != null && widget.serialPort!.isOpen()) ||
                     (widget.usbPort != null);

      if (!isOpen) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Konfiguracja wczytana lokalnie. Połącz się z Arduino aby wysłać.'), duration: Duration(seconds: 4)),
          );
        }
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Wysłać do Arduino?'),
          content: Text('Plik: ${result.files.single.name}\nData: ${backup['timestamp'] ?? 'nieznana'}\n\nKonfiguracja została wczytana lokalnie.\nCzy wysłać ją teraz do kontrolera Arduino?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Nie teraz')),
            ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Wyślij')),
          ],
        ),
      );

      if (confirmed != true) return;

      setState(() { _isLoading = true; _status = 'Przywracanie konfiguracji...'; });

      final keyToCmd = {
        'poles': (v) => 'set poles $v',
        'filter': (v) => 'set filter $v',
        'loop': (v) => 'set loop $v',
        'gasmin': (v) => 'set gasmin $v',
        'gasmax': (v) => 'set gasmax $v',
        'pwmmin': (v) => 'set pwmmin $v',
        'pwmmax': (v) => 'set pwmmax $v',
        'clmin': (v) => 'set clmin $v',
        'clmax': (v) => 'set clmax $v',
        'clen': (v) => (v == '1' || v == 'true') ? 'set clen on' : 'set clen off',
        'then': (v) => (v == '1' || v == 'true') ? 'set then on' : 'set then off',
        'flywheel': (v) => (v == '1' || v == 'true') ? 'set flywheel on' : 'set flywheel off',
        'fwgainupenabled': (v) => (v == '1' || v == 'true') ? 'set fwgainenabledup on' : 'set fwgainenabledup off',
        'fwgaindownenabled': (v) => (v == '1' || v == 'true') ? 'set fwgainenableddown on' : 'set fwgainenableddown off',
        'fwdeadband': (v) => (v == '1' || v == 'true') ? 'set fwdeadband on' : 'set fwdeadband off',
        'flywheelinertia': (v) => 'set flywheelinertia $v',
        'flywheelmax': (v) => 'set flywheelmax $v',
        'fwgainup': (v) => 'set fwgainup $v',
        'fwgaindown': (v) => 'set fwgaindown $v',
        'fwdeadbandrpm': (v) => 'set fwdeadbandrpm $v',
        'fwslew': (v) => 'set fwslew $v',
        'fwslewenabled': (v) => (v == '1' || v == 'true') ? 'set fwslew on' : 'set fwslew off',
        'flyk': (v) => 'set flyk $v',
        'idle': (v) => 'set idle $v',
        'rpma': (v) => 'set rpma $v',
        'alpha': (v) => 'set alpha $v',      };

      int sent = 0;

      if (config != null) {
        for (final entry in config.entries) {
          final cmdBuilder = keyToCmd[entry.key];
          if (cmdBuilder != null) {
            final cmd = cmdBuilder(entry.value.toString());
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      }

      if (clutchMap != null) {
        for (final entry in clutchMap.entries) {
          final idx = int.tryParse(entry.key);
          final val = int.tryParse(entry.value.toString());
          if (idx != null && val != null && idx >= 0 && idx < kMapSize) {
            final cmd = 'set clmap $idx $val';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      }

      if (throttleMap != null) {
        for (final entry in throttleMap.entries) {
          final idx = int.tryParse(entry.key);
          final val = int.tryParse(entry.value.toString());
          if (idx != null && val != null && idx >= 0 && idx < kMapSize) {
            final cmd = 'set thmap $idx $val';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      }

      if (fwUpMap != null) {
        for (final entry in fwUpMap.entries) {
          final idx = int.tryParse(entry.key);
          final val = int.tryParse(entry.value.toString());
          if (idx != null && val != null && idx >= 0 && idx < kMapSize && val >= 0 && val <= 1000) {
            final cmd = 'set fwupmap $idx $val';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      }

      if (fwDownMap != null) {
        for (final entry in fwDownMap.entries) {
          final idx = int.tryParse(entry.key);
          final val = int.tryParse(entry.value.toString());
          if (idx != null && val != null && idx >= 0 && idx < kMapSize && val >= 0 && val <= 1000) {
            final cmd = 'set fwdownmap $idx $val';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      }

      if (rampMap != null) {
        for (final entry in rampMap.entries) {
          final idx = int.tryParse(entry.key);
          final val = int.tryParse(entry.value.toString());
          if (idx != null && val != null && idx >= 0 && idx < kMapSize && val >= 0 && val <= 2000) {
            final cmd = 'set rampgasmap $idx $val';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            sent++;
            await Future.delayed(const Duration(milliseconds: 50));
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Przywrócono $sent parametrów')),
        );
      }

      await Future.delayed(const Duration(seconds: 1));
      _readConfig();
    } catch (e) {
      setState(() { _error = 'Błąd importu: $e'; });
    } finally {
      setState(() { _isLoading = false; _status = 'Połączony'; });
    }
  }

  Widget _buildConfigField(String label, String param, {String unit = '', bool isInt = false, String? description}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: const TextStyle(fontSize: 13)),
                    ),
                    if (description != null)
                      Tooltip(
                        message: description,
                        child: const Icon(Icons.info_outline, size: 18, color: Colors.blue),
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _controllers[param],
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _saveParameter(param, _controllers[param]?.text ?? ''),
                child: const Text('Zapisz', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(left: 0, top: 2, bottom: 4),
              child: Text(
                description!,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _configTimeout?.cancel();
    _clearPending();
    _readSubscription?.cancel();
    _presetNameController.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Konfiguracja BLDC Flywheel'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Status
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Status: ', style: TextStyle(fontWeight: FontWeight.bold)),
                              Text(
                                _status,
                                style: TextStyle(color: _status == 'Połączony' ? Colors.green : Colors.red),
                              ),
                            ],
                          ),
                          if (_error != null)
                            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: _readConfig,
                            icon: const Icon(Icons.download, size: 18),
                            label: const Text('Odczytaj konfigurację'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Silnik i pętla
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Silnik i pętla', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          _buildConfigField('Pary biegunów (poles)', 'paryBiegunow', isInt: true),
                          _buildConfigField('Filtr Halla (filter)', 'filtrHalla', isInt: true),
                          _buildConfigField('Interwał pętli (loop)', 'intervalPetli', isInt: true),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // PWM
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('PWM', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          _buildConfigField('PWM min (pwmmin)', 'pwmMin', isInt: true),
                          _buildConfigField('PWM max (pwmmax)', 'pwmMax', isInt: true),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Filtry
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Filtry', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          _buildConfigField('Filtr RPM (rpma)', 'rpmAlpha',
                            unit: 'alpha',
                            description: 'rpma. Wygładzenie RPM w pętli halla: im niższa wartość, tym gładszy odczyt RPM (mniejsza reakcja na szum). Zakres: 0.05-1.0. Domyślnie 0.06.'),
                          _buildConfigField('Tau filtra pochodnej (alpha)', 'flyAlphaTau',
                            unit: 's',
                            description: 'alpha. Stała czasowa filtra pochodnej dRPM/dt. Zbyt duża tau zabija reakcję (alpha wygładzone do ~0), zbyt mała = szum halla. Zakres: 0.005-0.5. Domyślnie 0.04.'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Gaz (A0)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Gaz (A0)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Mapa gazu (then)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['throttleMapEnabled'] ?? true,
                                onChanged: _toggleThrottleMap,
                              ),
                              Text(
                                (_config['throttleMapEnabled'] ?? true) ? 'WŁĄCZONA' : 'WYŁĄCZONA',
                                style: TextStyle(fontSize: 12, color: (_config['throttleMapEnabled'] ?? true) ? Colors.green : Colors.grey, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _buildConfigField('ADC min (gasmin)', 'adcMin', isInt: true),
                          _buildConfigField('ADC max (gasmax)', 'adcMax', isInt: true),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: _calibrateThrottle,
                            icon: const Icon(Icons.settings, size: 18),
                            label: const Text('Kalibracja gazu'),
                          ),
                          const SizedBox(height: 4),
                          ElevatedButton.icon(
                            onPressed: _openThrottleMap,
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('Edytuj mapę gazu'),
                          ),
                          const SizedBox(height: 4),
                          ElevatedButton.icon(
                            onPressed: _openRampMap,
                            icon: const Icon(Icons.speed, size: 18),
                            label: const Text('Mapa rampy gazu (rampgasmap)'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Sprzęgło (A2)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Sprzęgło (A2)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Obsługa sprzęgła (clen)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['clutchEnabled'] ?? true,
                                onChanged: _toggleClutch,
                              ),
                              Text(
                                (_config['clutchEnabled'] ?? true) ? 'WŁĄCZONE' : 'WYŁĄCZONE',
                                style: TextStyle(fontSize: 12, color: (_config['clutchEnabled'] ?? true) ? Colors.green : Colors.orange, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _buildConfigField('ADC min sprzęgła (clmin)', 'clutchAdcMin', isInt: true),
                          _buildConfigField('ADC max sprzęgła (clmax)', 'clutchAdcMax', isInt: true),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: _calibrateClutch,
                            icon: const Icon(Icons.precision_manufacturing, size: 18),
                            label: const Text('Kalibracja sprzęgła'),
                          ),
                          const SizedBox(height: 4),
                          ElevatedButton.icon(
                            onPressed: _openClutchMap,
                            icon: const Icon(Icons.table_chart, size: 18),
                            label: const Text('Edytuj mapę sprzęgła'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Flywheel (Virtual)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Flywheel (Virtual)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Flywheel (flywheel)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['flywheelEnabled'] ?? true,
                                onChanged: _toggleFlywheel,
                              ),
                              Text(
                                (_config['flywheelEnabled'] ?? true) ? 'WŁĄCZONY' : 'WYŁĄCZONY',
                                style: TextStyle(fontSize: 12, color: (_config['flywheelEnabled'] ?? true) ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (!(_config['flywheelEnabled'] ?? true))
                            Container(
                              padding: const EdgeInsets.all(8),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.warning, color: Colors.orange, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text('Flywheel wylaczony! RPM bedzie surowe bez wygladzania.',
                                      style: TextStyle(color: Colors.orange, fontSize: 12)),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Korekta wzrost (fwGainUp)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['fwGainUpEnabled'] ?? true,
                                onChanged: (v) {
                                  setState(() { _config['fwGainUpEnabled'] = v; });
                                  _toggleParameter('fwGainUpEnabled', v);
                                },
                              ),
                              Text(
                                (_config['fwGainUpEnabled'] ?? true) ? 'WŁĄCZONA' : 'WYŁĄCZONA',
                                style: TextStyle(fontSize: 12, color: (_config['fwGainUpEnabled'] ?? true) ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Korekta spadek (fwGainDown)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['fwGainDownEnabled'] ?? true,
                                onChanged: (v) {
                                  setState(() { _config['fwGainDownEnabled'] = v; });
                                  _toggleParameter('fwGainDownEnabled', v);
                                },
                              ),
                              Text(
                                (_config['fwGainDownEnabled'] ?? true) ? 'WŁĄCZONA' : 'WYŁĄCZONA',
                                style: TextStyle(fontSize: 12, color: (_config['fwGainDownEnabled'] ?? true) ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Bezwladnosc J (model fizyczny). Mnoznik sily korekty: corr = -alpha * J * gain. Wieksze J = mocniejsza korekta przy przyspieszaniu/hamowaniu.',
                              style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
                            ),
                          ),
                          _buildConfigField('Inercja (flywheelInertia)', 'flywheelInertia',
                            unit: '',
                            description: 'flywheelinertia. Bezwladnosc J (model fizyczny): mnoznik sily korekty corr = -alpha * J * gain. Większe J = mocniejsza korekta przy przyspieszaniu/hamowaniu. Zakres: 0.1-10.0.'),
                          _buildConfigField('Max RPM (flywheelMaxRPM)', 'flywheelMaxRPM',
                            unit: 'RPM',
                            description: 'flywheelmax. Zakres wirtualnych obrotow kola. Im wyzszy tym slabsza korekta PWM. Zakres: 1000-50000.'),
                          _buildConfigField('Wzmocnienie wzrost (fwGainUp)', 'fwGainUp',
                            unit: '',
                            description: 'fwgainup. Mnoznik korekty przy przyspieszaniu (ciecie PWM). Zakres: 0.1-30.0.'),
                          _buildConfigField('Wzmocnienie spadek (fwGainDown)', 'fwGainDown',
                            unit: '',
                            description: 'fwgaindown. Mnoznik korekty przy opadaniu (boost PWM). Zakres: 0.1-30.0.'),
                          _buildConfigField('Bieg jałowy', 'idleRPM',
                            unit: 'RPM',
                            description: 'idle. Minimalne RPM przy braku impulsów. Zakres: 50-1000.'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Deadband startu (fwDeadband)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['fwDeadbandEnabled'] ?? true,
                                onChanged: (v) {
                                  setState(() { _config['fwDeadbandEnabled'] = v; });
                                  _toggleParameter('fwDeadbandEnabled', v);
                                },
                              ),
                              Text(
                                (_config['fwDeadbandEnabled'] ?? true) ? 'WŁĄCZONY' : 'WYŁĄCZONY',
                                style: TextStyle(fontSize: 12, color: (_config['fwDeadbandEnabled'] ?? true) ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          _buildConfigField('Próg deadbandu (fwDeadbandRPM)', 'fwDeadbandRPM',
                            unit: 'RPM',
                            description: 'fwdeadbandrpm. Poniżej tych obrotów korekta flywheel jest wyłączona (czysty gaz przy starcie). Zakres: 0-5000.'),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(flex: 2, child: Text('Rampa powrotu korekty (fwslew)', style: TextStyle(fontSize: 13))),
                              Switch(
                                value: _config['flySlewEnabled'] ?? true,
                                onChanged: (v) {
                                  setState(() { _config['flySlewEnabled'] = v; });
                                  _toggleParameter('flySlewEnabled', v);
                                },
                              ),
                              Text(
                                (_config['flySlewEnabled'] ?? true) ? 'WŁĄCZONY' : 'WYŁĄCZONY',
                                style: TextStyle(fontSize: 12,
                                  color: (_config['flySlewEnabled'] ?? true) ? Colors.green : Colors.red,
                                  fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          _buildConfigField('Rampa powrotu korekty (fwslew)', 'flySlewRecover',
                            unit: 'ms',
                            description: 'fwslew. Asymetryczna rampa powrotu: wejście w korektę natychmiastowe, a powrót korekty PWM do 0 ograniczony tak, by pełny zakres PWM został pokonany w zadanym czasie (ms). 0 + wyłącznik = off. Zakres: 0-2000.'),
                          const SizedBox(height: 4),
                          ElevatedButton.icon(
                            onPressed: _openFlywheelMap,
                            icon: const Icon(Icons.timeline, size: 18),
                            label: const Text('Edytuj mapy flywheel (wzrost/spadek)'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Fabryczne presety flywheel - tylko Flutter (nie w firmware)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Fabryczne presety flywheel', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 4),
                          const Text('Skala tau=J*TAU, corr=error*K*gain. Bardzo lekkie ~ brak kola, Bardzo mocne ~ traktor.', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8, runSpacing: 8,
                            children: [
                              for (final name in kFactoryPresets.keys)
                                ElevatedButton(
                                  onPressed: () => _applyFactoryPreset(name),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: name=='Średnie' ? Colors.teal : name=='Bardzo lekkie' ? Colors.grey.shade200 : name=='Bardzo mocne' ? Colors.orange.shade700 : name=='Mocne' ? Colors.orange.shade300 : Colors.teal.shade100,
                                    foregroundColor: name=='Średnie' || name=='Bardzo mocne' ? Colors.white : Colors.black87,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                  child: Text(name, style: const TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Presety user
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Presety user (presets.json)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _presetNameController,
                                  decoration: const InputDecoration(
                                    labelText: 'Nazwa presetu',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _presets.contains(_presetNameController.text.trim())
                                    ? null
                                    : _savePreset,
                                child: const Text('Zapisz'),
                              ),
                            ],
                          ),
                          if (_presets.isNotEmpty) ...[
                            const Divider(height: 1),
                            const SizedBox(height: 4),
                            ..._presets.map((name) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                                  IconButton(
                                    icon: const Icon(Icons.download, size: 18, color: Colors.blue),
                                    onPressed: () => _loadPreset(name),
                                    tooltip: 'Załaduj',
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                    onPressed: () => _deletePreset(name),
                                    tooltip: 'Usuń',
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            )),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Backup / Restore
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Backup / Restore', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _exportBackup,
                                  icon: const Icon(Icons.upload, size: 18),
                                  label: const Text('Export do pliku'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _importBackup,
                                  icon: const Icon(Icons.download, size: 18),
                                  label: const Text('Import z pliku'),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Reset
                  ElevatedButton.icon(
                    onPressed: _resetConfig,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Przywróć ustawienia domyślne'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }
}

class _CalibrationMonitorDialog extends StatefulWidget {
  final Stream<String>? dataStream;
  final String title;

  const _CalibrationMonitorDialog({this.dataStream, this.title = 'Kalibracja'});

  @override
  State<_CalibrationMonitorDialog> createState() => _CalibrationMonitorDialogState();
}

class _CalibrationMonitorDialogState extends State<_CalibrationMonitorDialog> {
  final List<String> _lines = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _subscription;
  bool _calibrationDone = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.dataStream?.listen((text) {
      final lines = text.replaceAll('\r', '\n').split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        _lines.add(trimmed);
        if (trimmed.contains('ok:') ||
            trimmed.startsWith('e:') ||
            trimmed.startsWith('gasmin=') ||
            trimmed.startsWith('gasmax=') ||
            trimmed.startsWith('clmin=') ||
            trimmed.startsWith('clmax=')) {
          _calibrationDone = true;
        }
      }
      if (mounted) {
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Text(widget.title),
          const Spacer(),
          if (!_calibrationDone)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          if (_calibrationDone)
            const Icon(Icons.check_circle, color: Colors.green, size: 22),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.all(8),
          child: _lines.isEmpty
              ? const Center(
                  child: Text('Oczekiwanie na dane...', style: TextStyle(color: Colors.grey, fontFamily: 'Consolas', fontSize: 13)),
                )
              : SingleChildScrollView(
                  controller: _scrollController,
                  child: SelectableText(
                    _lines.join('\n'),
                    style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Consolas', fontSize: 13),
                  ),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_calibrationDone ? 'Zamknij' : 'Zamknij (w tle)'),
        ),
      ],
    );
  }
}