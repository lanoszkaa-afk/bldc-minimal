import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:usb_serial/usb_serial.dart' as usb;
import 'models/log_data.dart';
import 'screens/analysis_screen.dart';
import 'screens/config_screen.dart';
import 'utils/serial_line_parser.dart';

const int baudRate = 115200;

void main() {
  runApp(const BLDCFlywheelApp());
}

class BLDCFlywheelApp extends StatelessWidget {
  const BLDCFlywheelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLDC Flywheel',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SerialLineParser {
  List<String> _ports = [];
  String? _selectedPort;
  SerialPort? _serialPort;
  usb.UsbPort? _usbPort;
  StreamSubscription<Uint8List>? _readSubscription;
  bool _isConnected = false;
  bool _loggingActive = false;
  String? _logFilePath;
  int _csvLinesCount = 0;
  final List<String> _csvBuffer = [];
  final List<String> _monitorLines = [];
  static const int _maxMonitorLines = 2000;
  final ScrollController _scrollController = ScrollController();
  final StreamController<String> _serialDataController = StreamController<String>.broadcast();

  double _throttlePct = 0;
  int _adcMin = 195;
  int _adcMax = 854;

  bool _showRpmMonitor = false;
  bool _logStreaming = false;
  bool _testActive = false;
  bool _disposed = false;
  int _testAdc = 400;
  double _averagedRPM = 0;
  double _flywheelRPM = 0;
  double _alpha = 0; // error = fly - avg [RPM] w v4.8 (wczesniej dRPM/dt)
  double _error = 0;
  int _pwm = 0;
  int _targetPwm = 0;
  double _clutchPct = 0;
  double _accel = 0;
  double _kick = 0;
  double _rawCorr = 0;
  String? _fwVersion;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnect();
    _scrollController.dispose();
    _serialDataController.close();
    super.dispose();
  }

  Future<void> _refreshPorts() async {
    try {
      if (Platform.isAndroid) {
        final devices = await usb.UsbSerial.listDevices();
        setState(() {
          _ports = devices.map((d) => '${d.deviceId}:${d.productName ?? 'USB Device'}').toList();
          if (_ports.isNotEmpty && (_selectedPort == null || !_ports.contains(_selectedPort))) {
            _selectedPort = _ports.first;
          }
        });
      } else {
        final list = SerialPort.getAvailablePorts();
        setState(() {
          _ports = list;
          if (_ports.isNotEmpty && (_selectedPort == null || !_ports.contains(_selectedPort))) {
            _selectedPort = _ports.first;
          }
        });
      }
    } catch (e) {
      final errorMsg = e.toString();
      String userMessage = 'Błąd odświeżania portów: $e';

      if (errorMsg.contains('Permission denied') || errorMsg.contains('code: 13')) {
        userMessage = Platform.isAndroid
          ? 'Brak uprawnień do USB. Upewnij się, że:\n1. Masz podłączone urządzenie przez USB OTG\n2. Nadano uprawnienia w ustawieniach Androida'
          : 'Brak uprawnień do portu szeregowego';
      }

      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(userMessage),
                duration: const Duration(seconds: 5),
              ),
            );
          }
        });
      }
    }
  }

  void _connect() async {
    if (_selectedPort == null || _selectedPort!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wybierz port COM')),
      );
      return;
    }
    try {
      if (Platform.isAndroid) {
        final deviceId = int.parse(_selectedPort!.split(':').first);
        final devices = await usb.UsbSerial.listDevices();
        final device = devices.firstWhere(
          (d) => d.deviceId == deviceId,
          orElse: () => throw Exception('Urządzenie nie znalezione'),
        );

        _usbPort = await device.create();
        if (_usbPort == null) {
          throw Exception('Nie można utworzyć portu USB');
        }

        await _usbPort!.open();
        await _usbPort!.setDTR(true);
        await _usbPort!.setRTS(true);
        await _usbPort!.setPortParameters(
          baudRate,
          usb.UsbPort.DATABITS_8,
          usb.UsbPort.STOPBITS_1,
          usb.UsbPort.PARITY_NONE,
        );

        await Future.delayed(const Duration(seconds: 2));

        _readSubscription = _usbPort!.inputStream?.listen(
          (Uint8List data) {
            final text = String.fromCharCodes(data);
            _onSerialData(text);
          },
          onError: (e) {
            if (mounted) _appendMonitor('[Błąd odczytu: $e]\n');
          },
        );

        _isConnected = true;
        _appendMonitor('[Połączono z ${_selectedPort!.split(':').last} @ $baudRate baud]\n');
        _requestFirmwareVersion();
      } else {
        final port = SerialPort(_selectedPort!);
        port.open(SerialPortMode.readWrite);
        port.setConfig(SerialPortConfig(baudRate: baudRate));

        _serialPort = port;
        _isConnected = true;
        _appendMonitor('[Połączono z $_selectedPort @ $baudRate baud]\n');
        _requestFirmwareVersion();

        final reader = SerialPortReader(port);
        _readSubscription = reader.stream.listen(
          (Uint8List data) {
            final cleanData = Uint8List.fromList(data.map((b) => b & 0x7F).toList());
            final text = utf8.decode(cleanData, allowMalformed: true);
            if (text.isEmpty) return;
            _onSerialData(text);
          },
          onError: (e) {
            if (mounted) _appendMonitor('[Błąd odczytu: $e]\n');
          },
          cancelOnError: false,
        );
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nie można otworzyć portu: $e')),
        );
      }
    }
  }

  void _onSerialData(String text) {
    _serialDataController.add(text);

    parseSerialText(text, (trimmed) {
      _appendMonitor(trimmed + '\n');
      if (trimmed == 'testdone') {
        _testActive = false;
        if (_loggingActive) _stopLog();
      }
      // Update throttle calibration from gc response
      if (trimmed.startsWith('gasmin,')) {
        final v = int.tryParse(trimmed.split(',')[1].trim());
        if (v != null) _adcMin = v;
      } else if (trimmed.startsWith('gasmax,')) {
        final v = int.tryParse(trimmed.split(',')[1].trim());
        if (v != null) _adcMax = v;
      }
      if (_loggingActive && LogDataRow.isCsvDataLine(trimmed)) {
        _csvBuffer.add(trimmed);
        _csvLinesCount++;
        if (_csvBuffer.length > 100000) _csvBuffer.removeAt(0);
      }
      _parseCsvLine(trimmed);
      _detectFirmwareVersion(trimmed);
    });
    if (mounted && !_disposed) setState(() {});
  }

  void _requestFirmwareVersion() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_isConnected) _sendCommand('ver');
    });
    // Also fetch throttle calibration for correct % display
    Future.delayed(const Duration(milliseconds: 800), () {
      if (_isConnected) _sendCommand('gc');
    });
  }

  void _detectFirmwareVersion(String line) {
    final match = RegExp(r'^ready v([0-9A-Za-z.\-_+]+)').firstMatch(line.trim());
    if (match != null && _fwVersion != match.group(1)) {
      setState(() { _fwVersion = match.group(1); });
      _appendMonitor('[Firmware: v${match.group(1)}]\n');
    }
  }

  void _appendMonitor(String text) {
    _monitorLines.addAll(text.split('\n').where((s) => s.isNotEmpty));
    if (_monitorLines.length > _maxMonitorLines) {
      _monitorLines.removeRange(0, _monitorLines.length - _maxMonitorLines);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _parseCsvLine(String line) {
    final parts = line.split(',');
    if (parts.length < 7) return;
    final time = int.tryParse(parts[0]);
    if (time == null) return;
    _targetPwm = int.tryParse(parts[3]) ?? _targetPwm;
    _averagedRPM = double.tryParse(parts[4]) ?? _averagedRPM;
    // v4.8: kol6 = flywheelRPM, error = fly - avg; v4.7 legacy: kol6 = alpha dRPM/dt
    final col6 = parts.length >= 6 ? double.tryParse(parts[5]) : null;
    if (col6 != null) {
      if (col6.abs() > 12000 || (col6.abs() > 8000 && (col6 - _averagedRPM).abs() > 5000)) {
        // legacy v4.7 alpha
        _alpha = col6;
        _flywheelRPM = _averagedRPM;
        _error = 0;
      } else {
        _flywheelRPM = col6;
        _error = _flywheelRPM - _averagedRPM;
        _alpha = _error;
      }
    }
    _clutchPct = double.tryParse(parts[6]) ?? _clutchPct;
    _pwm = int.tryParse(parts[7]) ?? _pwm;
    if (parts.length >= 12) {
      _rawCorr = double.tryParse(parts[11]) ?? _rawCorr;
      _kick = double.tryParse(parts[10]) ?? _kick;
      _accel = double.tryParse(parts[9]) ?? _accel;
    }

    final adcRaw = int.tryParse(parts[1]) ?? _adcMin;
    final range = _adcMax - _adcMin;
    if (range > 10) {
      _throttlePct = ((adcRaw - _adcMin) / range * 100).clamp(0, 100);
    } else {
      _throttlePct = ((adcRaw - 195) / (854 - 195) * 100).clamp(0, 100);
    }
  }

  void _disconnect() {
    _readSubscription?.cancel();
    _readSubscription = null;
    if (_testActive) {
      _testActive = false;
      _sendCommand('test off');
    }
    if (_loggingActive) _stopLog();

    if (Platform.isAndroid) {
      _usbPort?.close();
      _usbPort = null;
    } else {
      if (_serialPort != null) {
        try {
          if (_serialPort!.isOpen()) _serialPort!.close();
          _serialPort!.dispose();
        } catch (_) {}
        _serialPort = null;
      }
    }

    _isConnected = false;
    _fwVersion = null;
    _appendMonitor('[Rozłączono]\n');
    if (mounted && !_disposed) setState(() {});
  }

  void _sendCommand(String cmd) {
    if (Platform.isAndroid) {
      if (_usbPort == null) return;
      try {
        _usbPort!.write(Uint8List.fromList(utf8.encode('$cmd\r\n')));
        _appendMonitor('[Wysłano: $cmd]\n');
        if (mounted && !_disposed) setState(() {});
      } catch (e) {
        _appendMonitor('[Błąd wysyłania: $e]\n');
      }
    } else {
      if (_serialPort == null || !_serialPort!.isOpen()) return;
      try {
        _serialPort!.write(Uint8List.fromList(utf8.encode('$cmd\r\n')));
        _appendMonitor('[Wysłano: $cmd]\n');
        if (mounted && !_disposed) setState(() {});
      } catch (e) {
        _appendMonitor('[Błąd wysyłania: $e]\n');
      }
    }
  }

  Future<Directory> _getLogsDir() async {
    Directory baseDir;
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      baseDir = ext ?? await getApplicationDocumentsDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    final logsDir = Directory('${baseDir.path}${Platform.pathSeparator}logs');
    if (!logsDir.existsSync()) await logsDir.create(recursive: true);
    return logsDir;
  }

  Future<List<FileSystemEntity>> _collectOldLogFiles() async {
    final allFiles = <FileSystemEntity>[];
    final pattern = RegExp(r'bldc_(log|monitor)_.*\.(csv|txt)$', caseSensitive: false);

    try { final logsDir = await _getLogsDir(); await for (final f in logsDir.list()) { if (f is File && pattern.hasMatch(f.path.split(Platform.pathSeparator).last)) allFiles.add(f); } } catch (_) {}

    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final downloadDir = Directory('${ext.parent.path}${Platform.pathSeparator}Download');
          if (downloadDir.existsSync()) { await for (final f in downloadDir.list()) { if (f is File && pattern.hasMatch(f.path.split(Platform.pathSeparator).last)) allFiles.add(f); } }
        }
      } catch (_) {}
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) { await for (final f in ext.list()) { if (f is File && pattern.hasMatch(f.path.split(Platform.pathSeparator).last)) allFiles.add(f); } }
      } catch (_) {}
    }

    return allFiles;
  }

  Future<void> _clearLogsDir() async {
    final files = await _collectOldLogFiles();
    final logsDir = await _getLogsDir();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wyczyścić katalog logów?'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ścieżka: ${logsDir.path}', style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: Colors.grey)),
              const SizedBox(height: 8),
              Text('Znaleziono ${files.length} plików:'),
              const SizedBox(height: 8),
              if (files.isEmpty)
                const Text('Brak plików do usunięcia.')
              else
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: files.length,
                      itemBuilder: (context, i) => Text(
                        files[i].path.split(Platform.pathSeparator).last,
                        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Anuluj')),
          if (files.isNotEmpty)
            ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Wyczyść'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white)),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      int count = 0;
      for (final entity in files) {
        await entity.delete();
        count++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Usunięto $count plików z katalogu logs/')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleTest(bool enable) async {
    if (!_isConnected) return;
    if (enable) {
      _startLog();
      _sendCommand('test on');
      _appendMonitor('[Test reakcji: włączony]\n');
    } else {
      _sendCommand('test off');
      _appendMonitor('[Test reakcji: wyłączony]\n');
      _stopLog();
    }
    setState(() => _testActive = enable);
  }

  Future<void> _startLog() async {
    if (!_isConnected) return;

    _csvBuffer.clear();
    _csvLinesCount = 0;
    _loggingActive = true;
    _logStreaming = true;
    _sendCommand('log on');
    _appendMonitor('[Logowanie rozpoczęte - dane są buforowane]\n');
    setState(() {});
  }

  Future<void> _stopLog() async {
    _sendCommand('log off');
    _loggingActive = false;
    _logStreaming = false;

    if (_csvBuffer.isEmpty) {
      _appendMonitor('[Brak danych do zapisania]\n');
      if (mounted && !_disposed) setState(() {});
      return;
    }

    _appendMonitor('[Zapisywanie $_csvLinesCount wierszy...]\n');

    final content = _csvBuffer.join('\n');

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Zapisz log CSV',
        fileName: 'bldc_log_${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}_'
            '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (path == null) {
        _appendMonitor('[Anulowano zapis]\n');
      } else {
        final file = File(path);
        await file.writeAsString(content, encoding: utf8);
        _appendMonitor('[Zapisano do: $path]\n');
        _logFilePath = path;
      }
    } catch (e) {
      try {
        final logsDir = await _getLogsDir();
        final name = 'bldc_log_${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}_'
            '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.csv';
        final localPath = '${logsDir.path}${Platform.pathSeparator}$name';
        final file = File(localPath);
        await file.writeAsString(content, encoding: utf8);
        _logFilePath = localPath;
        _appendMonitor('[Zapisano w logs/: $name]\n');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Zapisano w logs/: $name')),
          );
        }
      } catch (e2) {
        _appendMonitor('[Błąd zapisu: $e / $e2]\n');
      }
    }

    if (mounted && !_disposed) setState(() {});
  }

  Future<void> _saveMonitorToFile() async {
    final content = _monitorLines.join('\n');
    if (content.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brak danych do zapisania')),
        );
      }
      return;
    }

    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Zapisz monitor',
        fileName: 'bldc_monitor_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_'
            '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );

      if (path == null) return;

      final file = File(path);
      await file.writeAsString(content, encoding: utf8);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Zapisano: $path')),
        );
      }
    } catch (e) {
      try {
        final logsDir = await _getLogsDir();
        final path = '${logsDir.path}${Platform.pathSeparator}bldc_monitor_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_'
            '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.txt';
        final file = File(path);
        await file.writeAsString(content, encoding: utf8);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Zapisano w logs/: ${path.split(Platform.pathSeparator).last}')),
          );
        }
      } catch (_) {}
    }
  }

  Future<void> _shareLogFile() async {
    if (_csvBuffer.isEmpty) {
      _appendMonitor('[Brak danych do udostępnienia]\n');
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = 'bldc_log_${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}_'
          '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.csv';
      final tempPath = '${tempDir.path}${Platform.pathSeparator}$fileName';

      final content = _csvBuffer.join('\n');
      final file = File(tempPath);
      await file.writeAsString(content, encoding: utf8);

      await Share.shareXFiles(
        [XFile(tempPath)],
        subject: 'Log BLDC',
        text: 'Log kontrolera BLDC - $_csvLinesCount wierszy',
      );

      _appendMonitor('[Udostępniono log: $fileName]\n');
    } catch (e) {
      _appendMonitor('[Błąd udostępniania: $e]\n');
    }
  }

  Future<void> _shareMonitor() async {
    final content = _monitorLines.join('\n');
    if (content.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brak danych do udostępnienia')),
        );
      }
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final fileName = 'bldc_monitor_${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_'
          '${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}.txt';
      final tempPath = '${tempDir.path}${Platform.pathSeparator}$fileName';

      final file = File(tempPath);
      await file.writeAsString(content, encoding: utf8);

      await Share.shareXFiles(
        [XFile(tempPath)],
        subject: 'Monitor BLDC',
        text: 'Monitor portu szeregowego - ${_monitorLines.length} linii',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd udostępniania: $e')),
        );
      }
    }
  }

  Future<void> _copyMonitorToClipboard() async {
    final content = _monitorLines.join('\n');
    if (content.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brak danych do skopiowania')),
        );
      }
      return;
    }

    try {
      await Clipboard.setData(ClipboardData(text: content));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Skopiowano ${_monitorLines.length} linii do schowka')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Błąd kopiowania: $e')),
        );
      }
    }
  }

  void _clearMonitor() async {
    setState(() {
      _monitorLines.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Log wyczyszczony')),
      );
    }
  }

  Widget _buildRpmPanel() {
    return Card(
      color: Colors.grey[900],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('LOG', style: TextStyle(fontSize: 12, color: Colors.white70)),
                Switch(
                  value: _logStreaming,
                  activeColor: Colors.redAccent,
                  onChanged: _isConnected ? (val) {
                    _sendCommand(val ? 'log on' : 'log off');
                  } : null,
                ),
                const SizedBox(width: 12),
                const Text('TEST', style: TextStyle(fontSize: 12, color: Colors.amberAccent)),
                Switch(
                  value: _testActive,
                  activeColor: Colors.amberAccent,
                  onChanged: _isConnected ? (val) => _toggleTest(val) : null,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 12),
                Text('Test ADC $_testAdc',
                    style: const TextStyle(fontSize: 11, color: Colors.white70)),
                Expanded(
                  child: Slider(
                    value: _testAdc.toDouble(),
                    min: 196,
                    max: 500,
                    divisions: 76,
                    activeColor: Colors.amberAccent,
                    onChanged: _isConnected ? (val) {
                      setState(() => _testAdc = val.round());
                      _sendCommand('set testadc ${_testAdc}');
                    } : null,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            Text(
              _averagedRPM.toStringAsFixed(0),
              style: const TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: Colors.amberAccent,
                height: 1.0,
              ),
            ),
            const Text('RPM', style: TextStyle(color: Colors.amberAccent, fontSize: 11)),
            const SizedBox(height: 4),
            Text(
              'FLY ${_flywheelRPM.toStringAsFixed(0)}  ERR ${_error.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: Colors.cyanAccent.withValues(alpha: 0.8),
                height: 1.0,
              ),
            ),
            Text(
              'ALPHA/ERR ${_alpha.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.cyanAccent.withValues(alpha: 0.6),
                height: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _rpmGauge('PWM', '$_pwm', Colors.greenAccent),
                _rpmGauge('TARGET', '$_targetPwm', Colors.orangeAccent),
                _rpmGauge('CLUTCH', '${_clutchPct.toStringAsFixed(0)}%', Colors.purpleAccent),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _rpmGauge('ACCEL', '${_accel.toStringAsFixed(0)}', Colors.lightBlueAccent),
                _rpmGauge('KICK', '${_kick.toStringAsFixed(0)}', Colors.yellowAccent),
                _rpmGauge('RAW CORR', '${_rawCorr.toStringAsFixed(0)}', Colors.redAccent),
              ],
            ),
            if (_error != 0) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _error > 0
                      ? Colors.greenAccent.withOpacity(0.3)
                      : Colors.redAccent.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _error > 0
                      ? 'FLY +${_error.toStringAsFixed(0)} RPM (hamowanie -> +PWM)'
                      : 'FLY ${_error.toStringAsFixed(0)} RPM (rozpedzanie -> -PWM)',
                  style: TextStyle(
                    color: _error > 0 ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(width: 8),
                const Text('GAS', style: TextStyle(fontSize: 10, color: Colors.greenAccent)),
                const SizedBox(width: 6),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _throttlePct / 100,
                      minHeight: 14,
                      backgroundColor: Colors.grey[800],
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 36,
                  child: Text('${_throttlePct.toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace'),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rpmGauge(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace', color: color)),
        Text(label, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fwVersion == null ? 'BLDC Flywheel' : 'BLDC Flywheel · v$_fwVersion'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: Icon(_showRpmMonitor ? Icons.speed : Icons.speed_outlined,
              color: _showRpmMonitor ? Colors.amberAccent : null),
            onPressed: () => setState(() => _showRpmMonitor = !_showRpmMonitor),
            tooltip: 'Monitor RPM',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ConfigScreen(
                    serialPort: _serialPort,
                    usbPort: _usbPort,
                    isConnected: _isConnected,
                    dataStream: _serialDataController.stream,
                  ),
                ),
              );
            },
            tooltip: 'Konfiguracja',
          ),
          IconButton(
            icon: const Icon(Icons.analytics),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const AnalysisScreen()),
              );
            },
            tooltip: 'Analiza danych z logu',
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Połączenie', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Flexible(
                          child: DropdownButtonFormField<String>(
                            value: _ports.contains(_selectedPort) ? _selectedPort : (_ports.isNotEmpty ? _ports.first : null),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Port COM',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            items: _ports.map((p) => DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))).toList(),
                            onChanged: _isConnected ? null : (v) => setState(() => _selectedPort = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _isConnected ? null : _refreshPorts,
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Odśwież porty',
                        ),
                        ElevatedButton(
                          onPressed: _isConnected ? _disconnect : _connect,
                          child: Text(_isConnected ? 'Rozłącz' : 'Połącz'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isConnected ? 'Połączono' : 'Rozłączony',
                      style: TextStyle(
                        color: _isConnected ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Logowanie CSV', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: _isConnected && !_loggingActive ? _startLog : null,
                          child: const Text("Start logu"),
                        ),
                        ElevatedButton(
                          onPressed: _loggingActive ? _stopLog : null,
                          child: const Text("Stop logu"),
                        ),
                        OutlinedButton(
                          onPressed: _monitorLines.isNotEmpty ? _saveMonitorToFile : null,
                          child: const Text('Zapisz monitor'),
                        ),
                        OutlinedButton(
                          onPressed: _clearLogsDir,
                          child: const Text('Wyczyść logs/'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                        ),
                        if (_csvBuffer.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: _shareLogFile,
                            icon: const Icon(Icons.share, size: 18),
                            label: const Text('Wyślij log'),
                          ),
                        Text(
                          _loggingActive
                              ? '${_logFilePath != null ? _logFilePath!.split(Platform.pathSeparator).last : ''} ($_csvLinesCount wierszy)'
                              : 'Log wyłączony',
                          style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_showRpmMonitor) ...[
              const SizedBox(height: 8),
              _buildRpmPanel(),
            ],
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          Flexible(
                            child: const Text(
                              'Monitor portu szeregowego',
                              style: TextStyle(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _monitorLines.isNotEmpty ? _clearMonitor : null,
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Wyczyść log',
                          ),
                          IconButton(
                            onPressed: _monitorLines.isNotEmpty ? _copyMonitorToClipboard : null,
                            icon: const Icon(Icons.copy, size: 20),
                            tooltip: 'Kopiuj do schowka',
                          ),
                          if (_monitorLines.isNotEmpty)
                            IconButton(
                              onPressed: _shareMonitor,
                              icon: const Icon(Icons.share, size: 20),
                              tooltip: 'Wyślij monitor',
                            ),
                          Text(
                            '${_monitorLines.length} linii',
                            style: TextStyle(color: Colors.grey[600], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        primary: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(8.0),
                        child: SelectableText(
                          _monitorLines.join('\n'),
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                          scrollPhysics: const ClampingScrollPhysics(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
