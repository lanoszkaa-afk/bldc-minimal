class LogDataRow {
  final int timeMs;
  final int adcRaw;
  final int adc;
  final int targetPWM;
  final double averagedRPM;
  final double flywheelRPM; // v4.8: stan kola [RPM] z kol 6 (wczesniej alpha dRPM/dt)
  final double alpha; // alias: error = flywheelRPM - averagedRPM [RPM]; dla starych logow v4.7 = dRPM/dt [RPM/s]
  final int clutchPercent;
  final int lastPWM;

  // Dodatkowe kolumny (opcjonalne, 9-12)
  final double? rpmDelta;
  final double? accel;
  final double? kick;
  final double? rawCorr;

  // v4.8: flywheelRPM podaza za averagedRPM z tau = flyTauBase * J
  // error = flywheelRPM - averagedRPM -> corr = error * flyKfw * gain
  double get error => flywheelRPM - averagedRPM;

  LogDataRow({
    required this.timeMs,
    required this.adcRaw,
    required this.adc,
    required this.targetPWM,
    required this.averagedRPM,
    required this.flywheelRPM,
    required this.alpha,
    required this.clutchPercent,
    required this.lastPWM,
    this.rpmDelta,
    this.accel,
    this.kick,
    this.rawCorr,
  });

  static bool isCsvDataLine(String line) {
    if (line.isEmpty) return false;
    final parts = line.split(',');
    if (parts.length < 7 || parts.length > 12) return false;
    if (int.tryParse(parts[0].trim()) == null) return false;
    return true;
  }

  static LogDataRow? fromCsvLine(String line) {
    if (!isCsvDataLine(line)) return null;
    final parts = line.split(',');
    try {
      final timeMs = int.parse(parts[0].trim());
      final adcRaw = int.parse(parts[1].trim());
      final adc = int.parse(parts[2].trim());
      final targetPWM = int.parse(parts[3].trim());
      final averagedRPM = double.parse(parts[4].trim());
      final col6 = double.parse(parts[5].trim());
      final clutchPercent = int.parse(parts[6].trim());
      final lastPWM = int.parse(parts[7].trim());

      // Heurystyka v4.7 vs v4.8: v4.7 alpha to RPM/s, czesto |alpha| > 8000 lub >> fly range
      // v4.8 flywheelRPM to 0-8000 RPM, blisko averagedRPM. Jesli col6 jest daleko poza 0-10000 lub |col6| >> 5000 i roznica >4000, traktuj jako legacy alpha.
      double flywheelRPM;
      double alpha;
      if (col6.abs() > 12000 || (col6.abs() > 8000 && (col6 - averagedRPM).abs() > 5000)) {
        // legacy v4.7: col6 = alpha dRPM/dt
        alpha = col6;
        flywheelRPM = averagedRPM; // brak stanu, error nieznany
      } else {
        // v4.8: col6 = flywheelRPM
        flywheelRPM = col6;
        alpha = flywheelRPM - averagedRPM; // error
      }

      return LogDataRow(
        timeMs: timeMs,
        adcRaw: adcRaw,
        adc: adc,
        targetPWM: targetPWM,
        averagedRPM: averagedRPM,
        flywheelRPM: flywheelRPM,
        alpha: alpha,
        clutchPercent: clutchPercent,
        lastPWM: lastPWM,
        rpmDelta: parts.length >= 9 ? double.tryParse(parts[8].trim()) : null,
        accel: parts.length >= 10 ? double.tryParse(parts[9].trim()) : null,
        kick: parts.length >= 11 ? double.tryParse(parts[10].trim()) : null,
        rawCorr: parts.length >= 12 ? double.tryParse(parts[11].trim()) : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class LogStatistics {
  final int totalSamples;
  final double durationSeconds;
  final double minRPM;
  final double maxRPM;
  final double avgRPM;
  final double minFlyRPM;
  final double maxFlyRPM;
  final double avgFlyRPM;
  final double minAlpha; // error [RPM] w v4.8, dRPM/dt w v4.7
  final double maxAlpha;
  final double avgAlpha;
  final double minError;
  final double maxError;
  final double avgError;
  final int minPWM;
  final int maxPWM;
  final double avgPWM;
  final double? minAccel;
  final double? maxAccel;
  final double? avgAccel;
  final double? minKick;
  final double? maxKick;
  final double? avgKick;
  final double? minRawCorr;
  final double? maxRawCorr;
  final double? avgRawCorr;

  LogStatistics({
    required this.totalSamples,
    required this.durationSeconds,
    required this.minRPM,
    required this.maxRPM,
    required this.avgRPM,
    required this.minFlyRPM,
    required this.maxFlyRPM,
    required this.avgFlyRPM,
    required this.minAlpha,
    required this.maxAlpha,
    required this.avgAlpha,
    required this.minError,
    required this.maxError,
    required this.avgError,
    required this.minPWM,
    required this.maxPWM,
    required this.avgPWM,
    this.minAccel,
    this.maxAccel,
    this.avgAccel,
    this.minKick,
    this.maxKick,
    this.avgKick,
    this.minRawCorr,
    this.maxRawCorr,
    this.avgRawCorr,
  });

  static LogStatistics calculate(List<LogDataRow> data) {
    if (data.isEmpty) {
      return LogStatistics(
        totalSamples: 0, durationSeconds: 0,
        minRPM: 0, maxRPM: 0, avgRPM: 0,
        minFlyRPM: 0, maxFlyRPM: 0, avgFlyRPM: 0,
        minAlpha: 0, maxAlpha: 0, avgAlpha: 0,
        minError: 0, maxError: 0, avgError: 0,
        minPWM: 0, maxPWM: 0, avgPWM: 0,
      );
    }
    final duration = data.last.timeMs / 1000.0;
    final rpmValues = data.map((e) => e.averagedRPM).toList();
    final flyValues = data.map((e) => e.flywheelRPM).toList();
    final alphaValues = data.map((e) => e.alpha).toList();
    final errorValues = data.map((e) => e.error).toList();
    final pwmValues = data.map((e) => e.lastPWM.toDouble()).toList();

    final accelValues = data.where((e) => e.accel != null).map((e) => e.accel!).toList();
    final kickValues = data.where((e) => e.kick != null).map((e) => e.kick!).toList();
    final rawCorrValues = data.where((e) => e.rawCorr != null).map((e) => e.rawCorr!).toList();

    double? minOf(List<double> v) => v.isEmpty ? null : v.reduce((a, b) => a < b ? a : b);
    double? maxOf(List<double> v) => v.isEmpty ? null : v.reduce((a, b) => a > b ? a : b);
    double? avgOf(List<double> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

    return LogStatistics(
      totalSamples: data.length, durationSeconds: duration,
      minRPM: rpmValues.reduce((a, b) => a < b ? a : b),
      maxRPM: rpmValues.reduce((a, b) => a > b ? a : b),
      avgRPM: rpmValues.reduce((a, b) => a + b) / rpmValues.length,
      minFlyRPM: flyValues.reduce((a, b) => a < b ? a : b),
      maxFlyRPM: flyValues.reduce((a, b) => a > b ? a : b),
      avgFlyRPM: flyValues.reduce((a, b) => a + b) / flyValues.length,
      minAlpha: alphaValues.reduce((a, b) => a < b ? a : b),
      maxAlpha: alphaValues.reduce((a, b) => a > b ? a : b),
      avgAlpha: alphaValues.reduce((a, b) => a + b) / alphaValues.length,
      minError: errorValues.reduce((a, b) => a < b ? a : b),
      maxError: errorValues.reduce((a, b) => a > b ? a : b),
      avgError: errorValues.reduce((a, b) => a + b) / errorValues.length,
      minPWM: pwmValues.reduce((a, b) => a < b ? a : b).toInt(),
      maxPWM: pwmValues.reduce((a, b) => a > b ? a : b).toInt(),
      avgPWM: pwmValues.reduce((a, b) => a + b) / pwmValues.length,
      minAccel: minOf(accelValues),
      maxAccel: maxOf(accelValues),
      avgAccel: avgOf(accelValues),
      minKick: minOf(kickValues),
      maxKick: maxOf(kickValues),
      avgKick: avgOf(kickValues),
      minRawCorr: minOf(rawCorrValues),
      maxRawCorr: maxOf(rawCorrValues),
      avgRawCorr: avgOf(rawCorrValues),
    );
  }
}
