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

const int kMapSize = 25;
const int kMapLast = kMapSize - 1;

/// Konfiguracja definiująca różnice między mapą sprzęgła a mapą gazu.
class MapEditorConfig {
  final String title;
  final List<int> defaultMap;
  final String loadCommand;       // 'scc' lub 'sth'
  final String startMarker;       // 'clstart' lub 'thstart'
  final String endMarker;         // 'clend' lub 'thend'
  final String setCommandPrefix;  // 'set clmap' lub 'set thmap'
  final String exportName;        // 'Clutch Map' lub 'Throttle Map'
  final String exportDescription;
  final String exportFilePrefix;  // 'clutch_map_' lub 'throttle_map_'
  final String shareSubject;
  final String shareText;
  final String saveDialogTitle;
  final String backupJsonKey;     // 'clutchMap' lub 'throttleMap'
  final String bottomRightLabel;  // 'Puszczone' lub 'Puszczony'
  final bool presetsDescending;   // true = 1023→197, false = 197→1023
  final int presetLowValue;
  final int presetHighValue;
  final MaterialColor chartColor;

  // Zakres wartosci mapy (np. PWM 0-1023 lub mnoznik 0-1000)
  final int valueMin;
  final int valueMax;
  final int defaultValue;         // wartosc plaskiej mapy / preset 'flat'
  final int chartScaleMax;        // skala osi Y wykresu (np. 1023 lub 1000)
  final String valueUnit;         // 'PWM' lub '%'
  final String valueRangeHint;    // podtytul wykresu (opis zakresu)
  final String bottomLeftLabel;   // etykieta pod wykresem z lewej
  final String blendTitle;        // tytul karty blend
  final List<String> blendHints;  // opisy suwaka blend (5 poziomow)
  final String? flatPresetLabel;  // null = ukryj preset plaski
  final String Function(int index)? pointLabelBuilder; // null = 'Punkt <i>'

  // Wygładzanie (moving average)
  final String smoothTitle;       // tytul karty smooth
  final String smoothDescription; // opis pod tytulem
  final List<String> smoothHints; // opisy suwaka smooth (5 poziomow)

  const MapEditorConfig({
    required this.title,
    required this.defaultMap,
    required this.loadCommand,
    required this.startMarker,
    required this.endMarker,
    required this.setCommandPrefix,
    required this.exportName,
    required this.exportDescription,
    required this.exportFilePrefix,
    required this.shareSubject,
    required this.shareText,
    required this.saveDialogTitle,
    required this.backupJsonKey,
    required this.bottomRightLabel,
    required this.presetsDescending,
    this.presetLowValue = 197,
    this.presetHighValue = 1023,
    this.chartColor = Colors.blue,
    this.valueMin = 0,
    this.valueMax = 1023,
    this.defaultValue = 0,
    this.chartScaleMax = 1023,
    this.valueUnit = 'PWM',
    this.valueRangeHint = 'Wartości PWM (0-1023, 10-bit)',
    this.bottomLeftLabel = 'Wciśnięte',
    this.blendTitle = 'Wypłaszczenie (blend z liniową)',
    this.blendHints = const [
      'Prawie oryginalna — minimalna zmiana',
      'Lekkie wypłaszczenie — szybsza reakcja na początku',
      'Umiarkowane wypłaszczenie — wyraźnie żywszy gaz',
      'Mocne wypłaszczenie — agresywna reakcja',
      'Bardzo blisko liniowej — maksymalna bezpośredniość',
    ],
    this.flatPresetLabel,
    this.pointLabelBuilder,
    this.smoothTitle = 'Wygładzanie (moving average)',
    this.smoothDescription = 'Uśrednia wartości sąsiednich punktów — wygładza ostre skoki krzywej.',
    this.smoothHints = const [
      'Prawie bez zmian — minimalne wygładzenie',
      'Lekkie wygładzenie — usunięcie drobnych skoków',
      'Umiarkowane wygładzenie — wyraźnie gładsza krzywa',
      'Mocne wygładzenie — zwarta, płynna linia',
      'Bardzo mocne wygładzenie — prawie prosta',
    ],
  });
}

class MapEditorScreen extends StatefulWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;
  final MapEditorConfig config;
  final IconData? secondaryActionIcon;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  const MapEditorScreen({
    super.key,
    this.serialPort,
    this.usbPort,
    required this.isConnected,
    this.dataStream,
    required this.config,
    this.secondaryActionIcon,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  @override
  State<MapEditorScreen> createState() => _MapEditorScreenState();
}

class _MapEditorScreenState extends State<MapEditorScreen> with SerialLineParser {
  bool _isLoading = true;
  String? _error;

  late final List<int> _map;

  // Tryb edycji: 'simple' = 3 punkty, 'advanced' = 10 punktów, 'expert' = wszystkie 50
  String _editMode = 'simple';

  // Blend slider value
  double _blendValue = 0;
  List<int>? _blendBaseMap;  // mapa bazowa do blendowania (zapamiętana przy pierwszym ruchu)

  // Smooth slider value
  double _smoothValue = 0;
  List<int>? _smoothBaseMap;  // mapa bazowa do wygładzania (zapamiętana przy pierwszym ruchu)

  // Historia dla undo
  final List<List<int>> _history = [];
  static const int _maxHistory = 10;

  StreamSubscription? _readSubscription;
  final List<String> _responseBuffer = [];
  bool _readingMap = false;
  Timer? _loadTimeout;

  // Zapis mapy: liczymy potwierdzenia "OK" z firmware, zeby wykryc odrzucone komendy.
  bool _savingMap = false;
  int _saveOkCount = 0;
  int _saveErrCount = 0;

  @override
  void initState() {
    super.initState();
    _map = List.from(widget.config.defaultMap);
    _setupSerialListener();
    _loadMap();
  }

  void _saveToHistory() {
    _history.add(List.from(_map));
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    // Reset blend base when map changes externally
    _blendBaseMap = null;
    _blendValue = 0;
    _smoothBaseMap = null;
    _smoothValue = 0;
  }

  void _undo() {
    if (_history.isNotEmpty) {
      setState(() {
        _map.setAll(0, _history.removeLast());
      });
    }
  }

  void _setupSerialListener() {
    if (widget.dataStream != null) {
      _readSubscription = widget.dataStream!.listen(
        (String text) {
          _onSerialData(text);
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              _error = 'Błąd: $e';
            });
          }
        },
      );
    }
  }

  void _onSerialData(String text) {
    parseSerialText(text, (line) {
      if (_savingMap) {
        if (line == 'OK') {
          _saveOkCount++;
        } else if (line.startsWith('e:')) {
          _saveErrCount++;
        }
        return;
      }
      if (!_readingMap && line == widget.config.startMarker) {
        _readingMap = true;
        _responseBuffer.clear();
        return;
      }
      if (_readingMap) {
        if (line == widget.config.endMarker) {
          _parseMapResponse();
        } else {
          _responseBuffer.add(line);
        }
      }
    });
  }

  void _parseMapResponse() {
    _loadTimeout?.cancel();
    _loadTimeout = null;

    for (final line in _responseBuffer) {
      final parts = line.split(':');
      if (parts.length == 2) {
        final idx = int.tryParse(parts[0].trim());
        if (idx != null && idx >= 0 && idx < kMapSize) {
          final val = int.tryParse(parts[1].trim());
          if (val != null) {
            _map[idx] = val.clamp(widget.config.valueMin, widget.config.valueMax);
          }
        }
      }
    }

    setState(() {
      _isLoading = false;
      _readingMap = false;
      _responseBuffer.clear();
    });
  }

  void _loadMap() {
    final isOpen = widget.isConnected ||
        (widget.serialPort != null && widget.serialPort!.isOpen()) ||
        (widget.usbPort != null);
    if (!isOpen) {
      setState(() {
        _isLoading = false;
        _error = 'Rozłączony';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _readingMap = false;
      _responseBuffer.clear();
      resetSerialBuffer();
    });

    try {
      final cmdBytes = Uint8List.fromList(utf8.encode('${widget.config.loadCommand}\r\n'));
      if (widget.usbPort != null) {
        widget.usbPort!.write(cmdBytes);
      } else if (widget.serialPort != null) {
        widget.serialPort!.write(cmdBytes);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Błąd: $e';
      });
      return;
    }

    _loadTimeout = Timer(const Duration(seconds: 5), () {
      if (mounted && _isLoading) {
        setState(() {
          _isLoading = false;
          _readingMap = false;
          resetSerialBuffer();
          _error = 'Timeout - brak odpowiedzi';
        });
      }
    });
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    _readSubscription?.cancel();
    super.dispose();
  }

  void _saveAllToArduino() {
    int savedCount = 0;
    bool hasError = false;
    _saveOkCount = 0;
    _saveErrCount = 0;
    _savingMap = true;

    for (int i = 0; i < kMapSize; i++) {
      Future.delayed(Duration(milliseconds: i * 30), () {
        if (mounted && !hasError) {
          try {
            final clampedValue = _map[i].clamp(widget.config.valueMin, widget.config.valueMax);
            final cmd = '${widget.config.setCommandPrefix} $i $clampedValue';
            final cmdBytes = Uint8List.fromList(utf8.encode('$cmd\r\n'));
            if (widget.usbPort != null) {
              widget.usbPort!.write(cmdBytes);
            } else if (widget.serialPort != null) {
              widget.serialPort!.write(cmdBytes);
            }
            savedCount++;

            if (savedCount == kMapSize && mounted) {
              // Daj firmware chwilę na potwierdzenia "OK", potem podsumuj.
              Future.delayed(const Duration(milliseconds: 700), () {
                if (!mounted) return;
                _savingMap = false;
                if (_saveOkCount >= kMapSize) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Mapa zapisana do EEPROM')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Ostrzeżenie: potwierdzono tylko $_saveOkCount/$kMapSize komend'
                        '${_saveErrCount > 0 ? ' (${_saveErrCount} odrzuconych)' : ''}',
                      ),
                    ),
                  );
                }
              });
            }
          } catch (e) {
            hasError = true;
            _savingMap = false;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Błąd zapisu: $e')),
              );
            }
          }
        }
      });
    }
  }

  // Interpolacja liniowa między punktami kontrolnymi
  void _interpolateMap(List<int> controlIndices) {
    for (int i = 0; i < controlIndices.length - 1; i++) {
      final startIdx = controlIndices[i];
      final endIdx = controlIndices[i + 1];
      final startVal = _map[startIdx];
      final endVal = _map[endIdx];

      for (int j = startIdx + 1; j < endIdx; j++) {
        final t = (j - startIdx) / (endIdx - startIdx);
        _map[j] = (startVal + (endVal - startVal) * t).round();
      }
    }
  }

  void _updateControlPoint(int index, double value) {
    _map[index] = value.round().clamp(widget.config.valueMin, widget.config.valueMax);

    // Automatyczna interpolacja w zależności od trybu
    if (_editMode == 'simple') {
      _interpolateMap([0, kMapLast ~/ 2, kMapLast]);
    } else if (_editMode == 'advanced') {
      _interpolateMap([0, 2, 5, 8, 11, 13, 16, 19, 22, kMapLast]);
    }
    // W trybie expert nie interpolujemy - każdy punkt niezależny
  }

  String _getBlendDescription(double blend) {
    final b = blend / 100.0;
    final hints = widget.config.blendHints;
    if (b < 0.15) return hints[0];
    if (b < 0.35) return hints[1];
    if (b < 0.6) return hints[2];
    if (b < 0.8) return hints[3];
    return hints[4];
  }

  void _applyBlend() {
    // Zapamiętaj aktualną mapę jako bazę przy pierwszym ruchu suwaka
    if (_blendBaseMap == null) {
      _blendBaseMap = List.from(_map);
      _history.add(List.from(_map));
      if (_history.length > _maxHistory) {
        _history.removeAt(0);
      }
    }

    final blend = _blendValue / 100.0;
    final baseMap = _blendBaseMap!;

    // Wypłaszczenie: liniowa pomiędzy końcami aktualnej mapy, więc końce
    // zostają nienaruszone, a środek dąży do linii prostej. Działa tak samo
    // dla gazu/sprzęgła i map flywheel (mnożniki 0-1000).
    final startVal = baseMap[0];
    final endVal = baseMap[kMapLast];

    for (int i = 0; i < kMapSize; i++) {
      final t = i / kMapLast;
      final linear = (startVal + t * (endVal - startVal)).round();
      _map[i] = (baseMap[i] + blend * (linear - baseMap[i])).round();
    }
    setState(() {});
  }

  String _getSmoothDescription(double smooth) {
    final hints = widget.config.smoothHints;
    if (smooth < 15) return hints[0];
    if (smooth < 35) return hints[1];
    if (smooth < 60) return hints[2];
    if (smooth < 80) return hints[3];
    return hints[4];
  }

  void _applySmooth() {
    // Zapamiętaj aktualną mapę jako bazę przy pierwszym ruchu suwaka
    if (_smoothBaseMap == null) {
      _smoothBaseMap = List.from(_map);
      _history.add(List.from(_map));
      if (_history.length > _maxHistory) {
        _history.removeAt(0);
      }
    }

    final strength = _smoothValue / 100.0;
    final baseMap = _smoothBaseMap!;

    // Radius okna uśredniania: 1..12 (przy 100% pokrywa ~pół mapy)
    final radius = (1 + strength * 11).round();
    final out = List<int>.filled(kMapSize, 0);
    for (int i = 0; i < kMapSize; i++) {
      int sum = 0;
      int count = 0;
      for (int j = i - radius; j <= i + radius; j++) {
        if (j >= 0 && j < kMapSize) {
          sum += baseMap[j];
          count++;
        }
      }
      out[i] = (sum / count).round();
    }

    // Mieszamy oryginał z wygładzonym — suwak 0% = bez zmian
    for (int i = 0; i < kMapSize; i++) {
      _map[i] = (baseMap[i] + strength * (out[i] - baseMap[i])).round();
    }
    setState(() {});
  }

  void _setPreset(String preset) {
    _saveToHistory();
    final low = widget.config.presetLowValue;
    final high = widget.config.presetHighValue;
    final range = high - low;
    final desc = widget.config.presetsDescending;

    switch (preset) {
      case 'flat':
        for (int i = 0; i < kMapSize; i++) {
          _map[i] = widget.config.defaultValue.clamp(widget.config.valueMin, widget.config.valueMax);
        }
        break;
      case 'linear':
        for (int i = 0; i < kMapSize; i++) {
          if (desc) {
            _map[i] = (high - ((range * i) ~/ kMapLast)).clamp(widget.config.valueMin, widget.config.valueMax);
          } else {
            _map[i] = (low + ((range * i) ~/ kMapLast)).clamp(widget.config.valueMin, widget.config.valueMax);
          }
        }
        break;
      case 'exponential':
        for (int i = 0; i < kMapSize; i++) {
          final t = i / kMapLast;
          final val = desc
              ? low + (range * (1 - t * t))
              : low + (range * t * t);
          _map[i] = val.round().clamp(widget.config.valueMin, widget.config.valueMax);
        }
        break;
      case 'logarithmic':
        for (int i = 0; i < kMapSize; i++) {
          final t = i / kMapLast;
          final val = desc
              ? low + (range * (1 - (t * t * t)))
              : low + (range * (t * t * t));
          _map[i] = val.round().clamp(widget.config.valueMin, widget.config.valueMax);
        }
        break;
    }
    setState(() {});
  }

  Future<void> _exportMapToFile() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rozpoczynam eksport...'),
          duration: Duration(seconds: 1),
        ),
      );
    }

    try {
      final mapData = {
        'name': widget.config.exportName,
        'description': widget.config.exportDescription,
        'version': 2,
        'created': DateTime.now().toIso8601String(),
        'data': _map,
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(mapData);
      final fileName = '${widget.config.exportFilePrefix}${DateTime.now().year}${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}_${DateTime.now().hour}${DateTime.now().minute}.json';

      // Android - użyj Share API
      if (Platform.isAndroid) {
        try {
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/$fileName');
          await tempFile.writeAsString(jsonStr);

          final result = await Share.shareXFiles(
            [XFile(tempFile.path)],
            subject: widget.config.shareSubject,
            text: widget.config.shareText,
          );

          if (mounted) {
            if (result.status == ShareResultStatus.success) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Plik udostępniony'),
                  backgroundColor: Colors.green,
                ),
              );
            } else if (result.status == ShareResultStatus.dismissed) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Anulowano')),
              );
            }
          }
          return;
        } catch (e) {
          // Kontynuuj do fallback
        }
      }

      // Windows/Desktop - użyj saveFile
      try {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: widget.config.saveDialogTitle,
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['json'],
        );

        if (path != null) {
          final file = File(path);
          await file.writeAsString(jsonStr);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Zapisano: $path'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 3),
              ),
            );
          }
          return;
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Anulowano'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      } catch (e) {
        // Jeśli saveFile nie działa, spróbuj lokalnie
      }

      // Fallback: Zapisz lokalnie
      try {
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
            SnackBar(
              content: Text('Zapisano lokalnie: $localPath'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      } catch (e2) {
        throw Exception('Nie udało się zapisać pliku: $e2');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Błąd zapisu: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _importMapFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Wybierz plik mapy lub backup',
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      String jsonStr;
      if (result.files.first.bytes != null) {
        jsonStr = utf8.decode(result.files.first.bytes!);
      } else if (result.files.first.path != null) {
        final file = File(result.files.first.path!);
        jsonStr = await file.readAsString();
      } else {
        throw Exception('Brak danych');
      }

      final mapData = jsonDecode(jsonStr) as Map<String, dynamic>;

      List<int>? mapValues;

      // Format 1: Plik mapy z kluczem "data" (array)
      if (mapData.containsKey('data')) {
        final data = mapData['data'] as List<dynamic>;
        if (data.length != kMapSize) {
          throw Exception('Nieprawidłowa liczba elementów w "data": ${data.length}');
        }
        mapValues = data.map((e) => (e as num).toInt()).toList();
      }
      // Format 2: Backup z kluczem specyficznym dla mapy (object z kluczami "0"-"24")
      else if (mapData.containsKey(widget.config.backupJsonKey)) {
        final mapObj = mapData[widget.config.backupJsonKey] as Map<String, dynamic>;
        if (mapObj.length != kMapSize) {
          throw Exception('Nieprawidłowa liczba elementów w "${widget.config.backupJsonKey}": ${mapObj.length}');
        }
        mapValues = List<int>.filled(kMapSize, 0);
        for (int i = 0; i < kMapSize; i++) {
          final key = i.toString();
          if (!mapObj.containsKey(key)) {
            throw Exception('Brak klucza "$key" w ${widget.config.backupJsonKey}');
          }
          final val = mapObj[key];
          if (val == null) {
            throw Exception('Wartość null dla klucza "$key"');
          }
          mapValues[i] = (val is int) ? val : int.parse(val.toString());
        }
      }
      else {
        throw Exception('Nieznany format pliku. Oczekiwano klucza "data" lub "${widget.config.backupJsonKey}". Znalezione klucze: ${mapData.keys.join(", ")}');
      }

      if (mapValues == null) {
        throw Exception('Nie udało się wczytać mapy');
      }

      _saveToHistory();
      for (int i = 0; i < kMapSize; i++) {
        _map[i] = mapValues[i].clamp(widget.config.valueMin, widget.config.valueMax);
      }

      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Wczytano mapę: ${_map[0]} → ${_map[kMapLast]} ${widget.config.valueUnit}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Błąd importu: $e'),
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  List<int> _getControlIndices() {
    switch (_editMode) {
      case 'simple':
        return [0, kMapLast ~/ 2, kMapLast];
      case 'advanced':
        return [0, 2, 5, 8, 11, 13, 16, 19, 22, kMapLast];
      case 'expert':
        return List.generate(kMapSize, (i) => i);
      default:
        return [0, kMapLast ~/ 2, kMapLast];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(widget.config.title),
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (widget.secondaryActionIcon != null && widget.onSecondaryAction != null)
            IconButton(
              onPressed: widget.onSecondaryAction,
              icon: Icon(widget.secondaryActionIcon),
              tooltip: widget.secondaryActionLabel ?? '',
            ),
          IconButton(
            onPressed: _history.isNotEmpty ? _undo : null,
            icon: const Icon(Icons.undo),
            tooltip: 'Cofnij',
          ),
          IconButton(
            onPressed: _loadMap,
            icon: const Icon(Icons.refresh),
            tooltip: 'Odśwież',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Ładowanie mapy...'),
                ],
              ),
            )
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Wypłaszczenie (blend slider)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.config.blendTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _getBlendDescription(_blendValue),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            Row(
                              children: [
                                const Text('0%', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                Expanded(
                                  child: Slider(
                                    value: _blendValue,
                                    min: 0,
                                    max: 100,
                                    divisions: 100,
                                    label: '${_blendValue.round()}%',
                                    onChanged: (val) {
                                      setState(() {
                                        _blendValue = val;
                                        _applyBlend();
                                      });
                                    },
                                  ),
                                ),
                                const Text('100%', style: TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Wygładzanie (smooth slider)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.config.smoothTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.config.smoothDescription,
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _getSmoothDescription(_smoothValue),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            Row(
                              children: [
                                const Text('0%', style: TextStyle(fontSize: 11, color: Colors.grey)),
                                Expanded(
                                  child: Slider(
                                    value: _smoothValue,
                                    min: 0,
                                    max: 100,
                                    divisions: 100,
                                    label: '${_smoothValue.round()}%',
                                    onChanged: (val) {
                                      setState(() {
                                        _smoothValue = val;
                                        _applySmooth();
                                      });
                                    },
                                  ),
                                ),
                                const Text('100%', style: TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Wykres podglądu
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            const Text(
                              'Podgląd mapy',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              widget.config.valueRangeHint,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 200,
                              child: CustomPaint(
                                size: const Size(double.infinity, 200),
                                painter: _MapPainter(
                                  map: _map,
                                  color: widget.config.chartColor,
                                  scaleMax: widget.config.chartScaleMax,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${widget.config.bottomLeftLabel} (${_map[0]} ${widget.config.valueUnit})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                Text(
                                  '${widget.config.bottomRightLabel} (${_map[kMapLast]} ${widget.config.valueUnit})',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Wybór trybu edycji
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Tryb edycji',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 12),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'simple',
                                  label: Text('Prosty'),
                                  icon: Icon(Icons.looks_one),
                                ),
                                ButtonSegment(
                                  value: 'advanced',
                                  label: Text('Zaawansowany'),
                                  icon: Icon(Icons.looks_two),
                                ),
                                ButtonSegment(
                                  value: 'expert',
                                  label: Text('Ekspert'),
                                  icon: Icon(Icons.looks_3),
                                ),
                              ],
                              selected: {_editMode},
                              onSelectionChanged: (Set<String> newSelection) {
                                setState(() {
                                  _editMode = newSelection.first;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _editMode == 'simple'
                                  ? '3 punkty kontrolne (początek, środek, koniec)'
                                  : _editMode == 'advanced'
                                      ? '10 punktów kontrolnych'
                                      : '$kMapSize punktów - pełna kontrola (${widget.config.valueMin}-${widget.config.valueMax} ${widget.config.valueUnit})',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Suwaki edycji
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Edycja punktów',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ..._getControlIndices().map((index) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          widget.config.pointLabelBuilder?.call(index) ?? 'Punkt $index',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: widget.config.chartColor.shade100,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            '${_map[index]} ${widget.config.valueUnit}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Slider(
                                      value: _map[index].toDouble(),
                                      min: widget.config.valueMin.toDouble(),
                                      max: widget.config.valueMax.toDouble(),
                                      divisions: widget.config.valueMax - widget.config.valueMin,
                                      label: '${_map[index]} ${widget.config.valueUnit}',
                                      onChangeStart: (_) => _saveToHistory(),
                                      onChanged: (value) {
                                        setState(() {
                                          _updateControlPoint(index, value);
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Presety
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Presety',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (widget.config.flatPresetLabel != null)
                                  ElevatedButton.icon(
                                    onPressed: () => _setPreset('flat'),
                                    icon: const Icon(Icons.horizontal_rule, size: 18),
                                    label: Text(widget.config.flatPresetLabel!),
                                  ),
                                ElevatedButton.icon(
                                  onPressed: () => _setPreset('linear'),
                                  icon: const Icon(Icons.show_chart, size: 18),
                                  label: const Text('Liniowa'),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () => _setPreset('exponential'),
                                  icon: const Icon(Icons.trending_down, size: 18),
                                  label: const Text('Parabola'),
                                ),
                                ElevatedButton.icon(
                                  onPressed: () => _setPreset('logarithmic'),
                                  icon: const Icon(Icons.trending_flat, size: 18),
                                  label: const Text('Sześcian'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Import/Export
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Import/Export',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _exportMapToFile,
                                    icon: const Icon(Icons.upload_file, size: 18),
                                    label: const Text('Eksport'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _importMapFromFile,
                                    icon: const Icon(Icons.download, size: 18),
                                    label: const Text('Import'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Przyciski akcji
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _saveAllToArduino,
                            icon: const Icon(Icons.upload),
                            label: const Text('ZAPISZ DO ARDUINO'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _loadMap,
                          icon: const Icon(Icons.download),
                          label: const Text('Odczytaj'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16.0),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _MapPainter extends CustomPainter {
  final List<int> map;
  final Color color;
  final int scaleMax;

  _MapPainter({required this.map, required this.color, this.scaleMax = 1023});

  @override
  void paint(Canvas canvas, Size size) {
    final padding = 20.0;
    final chartWidth = size.width - 2 * padding;
    final chartHeight = size.height - 2 * padding;

    // Siatka
    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = padding + chartHeight * i / 4;
      canvas.drawLine(
        Offset(padding, y),
        Offset(size.width - padding, y),
        gridPaint,
      );
    }

    // Ramka
    canvas.drawRect(
      Rect.fromLTRB(padding, padding, size.width - padding, size.height - padding),
      Paint()
        ..color = Colors.grey.shade400
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    // Linia mapy
    final path = Path();
    bool first = true;
    for (int i = 0; i < kMapSize; i++) {
      final x = padding + chartWidth * i / kMapLast;
      final y = padding + chartHeight * (1 - map[i] / scaleMax);  // Skalowanie 0..scaleMax
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // Wypełnienie
    final fillPath = Path.from(path);
    fillPath.lineTo(padding + chartWidth, size.height - padding);
    fillPath.lineTo(padding, size.height - padding);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withOpacity(0.3),
            color.withOpacity(0.05),
          ],
        ).createShader(Rect.fromLTRB(
          padding,
          padding,
          size.width - padding,
          size.height - padding,
        )),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
