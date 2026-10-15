import 'package:flutter/material.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'map_editor_screen.dart';

/// Wrapper gazu — deleguje do generycznego MapEditorScreen.
class ThrottleMapScreen extends StatelessWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;

  static const _defaultThrottleMap = [
    197, 209, 222, 236, 253, 276, 304, 336, 369, 406,
    444, 483, 525, 567, 612, 662, 718, 771, 816, 858,
    897, 933, 966, 1000, 1023
  ];

  const ThrottleMapScreen({
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
        title: 'Mapa Gazu',
        defaultMap: _defaultThrottleMap,
        loadCommand: 'sth',
        startMarker: 'thstart',
        endMarker: 'thend',
        setCommandPrefix: 'set thmap',
        exportName: 'Throttle Map',
        exportDescription: '25-element PWM map for throttle control (0-1023, 10-bit)',
        exportFilePrefix: 'throttle_map_',
        shareSubject: 'Mapa gazu BLDC',
        shareText: 'Eksport mapy gazu (10-bit PWM)',
        saveDialogTitle: 'Zapisz mapę gazu',
        backupJsonKey: 'throttleMap',
        bottomRightLabel: 'Puszczony',
        presetsDescending: false,
      ),
    );
  }
}
