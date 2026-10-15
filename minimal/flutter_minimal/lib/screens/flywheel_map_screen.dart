import 'package:flutter/material.dart';
import 'package:libserialport_plus/libserialport_plus.dart';
import 'package:usb_serial/usb_serial.dart' as usb;

import 'map_editor_screen.dart';

/// Edytor map korekty flywheel (rozbieganie/hamowanie).
/// Deleguje do generycznego MapEditorScreen z przełącznikiem UP/DOWN.
class FlywheelMapScreen extends StatefulWidget {
  final SerialPort? serialPort;
  final usb.UsbPort? usbPort;
  final bool isConnected;
  final Stream<String>? dataStream;
  final double flywheelMaxRPM;

  const FlywheelMapScreen({
    super.key,
    this.serialPort,
    this.usbPort,
    required this.isConnected,
    this.dataStream,
    this.flywheelMaxRPM = 8000.0,
  });

  @override
  State<FlywheelMapScreen> createState() => _FlywheelMapScreenState();
}

class _FlywheelMapScreenState extends State<FlywheelMapScreen> {
  bool _up = true;

  static final List<int> _flatMap = List<int>.filled(kMapSize, 100);

  String get _maxRpmLabel => '${widget.flywheelMaxRPM.round()} RPM';

  String _pointRpmLabel(int index) {
    final rpm = index / kMapLast * widget.flywheelMaxRPM;
    return '${rpm.round()} RPM';
  }

  MapEditorConfig get _config => _up ? _buildUpConfig() : _buildDownConfig();

  MapEditorConfig _buildUpConfig() => MapEditorConfig(
    title: 'Flywheel v4.8 — Rozbieganie (error = fly - avg <0)',
    defaultMap: _flatMap,
    loadCommand: 'sfwup',
    startMarker: 'fwupstart',
    endMarker: 'fwupend',
    setCommandPrefix: 'set fwupmap',
    exportName: 'Flywheel Up Map v4.8-state',
    exportDescription: 'v4.8-state: 25-element multiplier for error*flyK* gain, acceleration error<0 (fly lags) 0-1000% 100=1.0, tau=flyTau*J',
    exportFilePrefix: 'flywheel_up_map_',
    shareSubject: 'Mapa flywheel (rozbieganie) BLDC',
    shareText: 'Eksport mapy korekty flywheel przy rozbieganiu (0-1000%)',
    saveDialogTitle: 'Zapisz mapę flywheel (rozbieganie)',
    backupJsonKey: 'fwUpMap',
    bottomRightLabel: _maxRpmLabel,
    presetsDescending: false,
    presetLowValue: 100,
    presetHighValue: 1000,
    chartColor: Colors.green,
    valueMin: 0,
    valueMax: 1000,
    defaultValue: 100,
    chartScaleMax: 1000,
    valueUnit: '%',
    valueRangeHint: 'Mnoznik korekty (0-1000%, 100 = 1.0)',
    bottomLeftLabel: '0 RPM',
    blendTitle: 'Wypłaszczenie (blend z liniową)',
    pointLabelBuilder: _pointRpmLabel,
    blendHints: const [
      'Prawie oryginalna — minimalna zmiana',
      'Lekkie wypłaszczenie — bardziej równa korekta',
      'Umiarkowane wypłaszczenie — wyraźnie prostsza krzywa',
      'Mocne wypłaszczenie — prawie liniowa zależność od RPM',
      'Bardzo blisko liniowej — korekta równomierna w całym zakresie RPM',
    ],
    flatPresetLabel: 'Płaska (1.0)',
  );

  MapEditorConfig _buildDownConfig() => MapEditorConfig(
    title: 'Flywheel v4.8 — Hamowanie (error = fly - avg >0)',
    defaultMap: _flatMap,
    loadCommand: 'sfwdown',
    startMarker: 'fwdownstart',
    endMarker: 'fwdownend',
    setCommandPrefix: 'set fwdownmap',
    exportName: 'Flywheel Down Map v4.8-state',
    exportDescription: 'v4.8-state: 25-element multiplier for error*flyK* gain, braking error>0 (fly leads) 0-1000% 100=1.0, tau=flyTau*J',
    exportFilePrefix: 'flywheel_down_map_',
    shareSubject: 'Mapa flywheel (hamowanie) BLDC',
    shareText: 'Eksport mapy korekty flywheel przy hamowaniu (0-1000%)',
    saveDialogTitle: 'Zapisz mapę flywheel (hamowanie)',
    backupJsonKey: 'fwDownMap',
    bottomRightLabel: _maxRpmLabel,
    presetsDescending: false,
    presetLowValue: 100,
    presetHighValue: 1000,
    chartColor: Colors.deepOrange,
    valueMin: 0,
    valueMax: 1000,
    defaultValue: 100,
    chartScaleMax: 1000,
    valueUnit: '%',
    valueRangeHint: 'Mnoznik korekty (0-1000%, 100 = 1.0)',
    bottomLeftLabel: '0 RPM',
    blendTitle: 'Wypłaszczenie (blend z liniową)',
    pointLabelBuilder: _pointRpmLabel,
    blendHints: const [
      'Prawie oryginalna — minimalna zmiana',
      'Lekkie wypłaszczenie — bardziej równa korekta',
      'Umiarkowane wypłaszczenie — wyraźnie prostsza krzywa',
      'Mocne wypłaszczenie — prawie liniowa zależność od RPM',
      'Bardzo blisko liniowej — korekta równomierna w całym zakresie RPM',
    ],
    flatPresetLabel: 'Płaska (1.0)',
  );

  @override
  Widget build(BuildContext context) {
    return MapEditorScreen(
      key: ValueKey(_up),
      serialPort: widget.serialPort,
      usbPort: widget.usbPort,
      isConnected: widget.isConnected,
      dataStream: widget.dataStream,
      config: _config,
      secondaryActionIcon: Icons.swap_horiz,
      secondaryActionLabel: _up
          ? 'Przełącz na mapę HAMOWANIA'
          : 'Przełącz na mapę ROZBIEGANIA',
      onSecondaryAction: () => setState(() => _up = !_up),
    );
  }
}
