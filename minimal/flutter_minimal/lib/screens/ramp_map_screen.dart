import 'package:flutter/material.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'map_editor_screen.dart';

/// Mapa rampy gazu (rampgasmap) — czas rampy w ms wg pozycji manetki.
/// Deleguje do generycznego MapEditorScreen.
class RampMapScreen extends StatelessWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;

  static final List<int> _flatMap = [
    900, 900, 900, 900, 900, 900, 900,
    600, 600, 600, 600, 600, 600,
    400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400, 400
  ];

  const RampMapScreen({
    super.key,
    this.serialPort,
    this.usbPort,
    required this.isConnected,
    this.dataStream,
  });

  @override
  Widget build(BuildContext context) {
    return MapEditorScreen(
      serialPort: serialPort,
      usbPort: usbPort,
      isConnected: isConnected,
      dataStream: dataStream,
      config: MapEditorConfig(
        title: 'Mapa Ramy Gazu',
        defaultMap: _flatMap,
        loadCommand: 'sramp',
        startMarker: 'srampstart',
        endMarker: 'srampend',
        setCommandPrefix: 'set rampgasmap',
        exportName: 'Ramp Map',
        exportDescription: '25-element throttle ramp time map, ms from pwmMin to pwmMax vs throttle position (0-2000, 0 = off)',
        exportFilePrefix: 'ramp_map_',
        shareSubject: 'Mapa ramy gazu BLDC',
        shareText: 'Eksport mapy rampy gazu (czas rampy, ms od pwmMin do pwmMax, 0-2000 ms)',
        saveDialogTitle: 'Zapisz mapę ramy gazu',
        backupJsonKey: 'rampMap',
        bottomRightLabel: '100%',
        presetsDescending: false,
        presetLowValue: 400,
        presetHighValue: 2000,
        chartColor: Colors.indigo,
        valueMin: 0,
        valueMax: 2000,
        defaultValue: 400,
        chartScaleMax: 2000,
        valueUnit: 'ms',
        valueRangeHint: 'Czas rampy gazu (0-2000 ms, 0 = off)',
        bottomLeftLabel: '0%',
        blendTitle: 'Wypłaszczenie (blend z liniową)',
        pointLabelBuilder: _pointLabel,
        blendHints: const [
          'Prawie oryginalna — minimalna zmiana',
          'Lekkie wypłaszczenie — bardziej równa rampa',
          'Umiarkowane wypłaszczenie — wyraźnie prostsza krzywa',
          'Mocne wypłaszczenie — prawie liniowa zależność od pozycji manetki',
          'Bardzo blisko liniowej — rampa równomierna w całym zakresie',
        ],
        flatPresetLabel: 'Domyślna moze_to (900/600/400)',
      ),
    );
  }

  static String _pointLabel(int index) {
    return '${(index / kMapLast * 100).round()}%';
  }
}
