import 'package:flutter/material.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'map_editor_screen.dart';

/// Wrapper sprzęgła — deleguje do generycznego MapEditorScreen.
class ClutchMapScreen extends StatelessWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;

  static const _defaultClutchMap = [
    1023, 965, 906, 848, 789, 730, 672, 642, 555, 496,
    437, 401, 364, 334, 310, 286, 266, 246, 230, 217,
    205, 203, 200, 198, 195
  ];

  const ClutchMapScreen({
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
      config: const MapEditorConfig(
        title: 'Mapa Sprzęgła',
        defaultMap: _defaultClutchMap,
        loadCommand: 'scc',
        startMarker: 'clstart',
        endMarker: 'clend',
        setCommandPrefix: 'set clmap',
        exportName: 'Clutch Map',
        exportDescription: '25-element PWM map for clutch control (0-1023, 10-bit)',
        exportFilePrefix: 'clutch_map_',
        shareSubject: 'Mapa sprzęgła BLDC',
        shareText: 'Eksport mapy sprzęgła (10-bit PWM)',
        saveDialogTitle: 'Zapisz mapę sprzęgła',
        backupJsonKey: 'clutchMap',
        bottomRightLabel: 'Puszczone',
        presetsDescending: true,
      ),
    );
  }
}
