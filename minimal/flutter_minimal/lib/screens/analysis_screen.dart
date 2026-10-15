import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/log_data.dart';

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  List<LogDataRow> _data = [];
  LogStatistics? _stats;
  bool _isLoading = false;
  String? _error;
  String? _fileName;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Wybierz plik CSV',
      );
      if (result == null || result.files.single.path == null) {
        setState(() {
          _isLoading = false;
        });
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final path = result.files.single.path!;
      _fileName = result.files.single.name;
      if (!_fileName!.toLowerCase().endsWith('.csv')) {
        setState(() {
          _error = 'Wybierz plik CSV';
          _isLoading = false;
        });
        return;
      }
      final file = File(path);
      final content = await file.readAsString();
      final data = <LogDataRow>[];
      for (final line in content.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final row = LogDataRow.fromCsvLine(t);
        if (row != null) data.add(row);
      }
      if (data.isEmpty) {
        setState(() {
          _error = 'Brak danych w pliku';
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _data = data;
        _stats = LogStatistics.calculate(data);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Blad: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName ?? 'Analiza'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFile,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
                      const SizedBox(height: 16),
                      Text(_error!),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadFile,
                        child: const Text('Sprobuj ponownie'),
                      ),
                    ],
                  ),
                )
              : _data.isEmpty
                  ? const Center(child: Text('Brak danych'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildStatistics(),
                          const SizedBox(height: 24),
                          _buildRPMChart(),
                          const SizedBox(height: 24),
                          _buildPWMChart(),
                          const SizedBox(height: 24),
                          _buildADCChart(),
                          const SizedBox(height: 24),
                          _buildClutchChart(),
                          const SizedBox(height: 24),
                          _buildAlphaChart(),
                          const SizedBox(height: 24),
                          _buildCombinedChart(),
                          const SizedBox(height: 24),
                          _buildFlywheelVsEngineChart(),
                          const SizedBox(height: 24),
                          _buildCorrectionChart(),
                          const SizedBox(height: 24),
                          _buildKickChart(),
                          const SizedBox(height: 24),
                          _buildRawCorrChart(),
                          const SizedBox(height: 24),
                          _buildADCRawVsPWMChart(),
                        ],
                      ),
                    ),
    );
  }

  Widget _buildStatistics() {
    if (_stats == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Statystyki',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _statCard('Probki', '${_stats!.totalSamples}'),
                _statCard('Czas', '${_stats!.durationSeconds.toStringAsFixed(1)} s'),
                _statCard('RPM min', '${_stats!.minRPM.toStringAsFixed(0)}'),
                _statCard('RPM max', '${_stats!.maxRPM.toStringAsFixed(0)}'),
                _statCard('RPM srednia', '${_stats!.avgRPM.toStringAsFixed(0)}'),
                _statCard('PWM min', '${_stats!.minPWM}'),
                _statCard('PWM max', '${_stats!.maxPWM}'),
                _statCard('PWM srednia', '${_stats!.avgPWM.toStringAsFixed(0)}'),
                _statCard('Error min', '${_stats!.minError.toStringAsFixed(0)} RPM'),
                _statCard('Error max', '${_stats!.maxError.toStringAsFixed(0)} RPM'),
                _statCard('Error avg', '${_stats!.avgError.toStringAsFixed(0)} RPM'),
                _statCard('Fly min', '${_stats!.minFlyRPM.toStringAsFixed(0)}'),
                _statCard('Fly max', '${_stats!.maxFlyRPM.toStringAsFixed(0)}'),
                if (_stats!.minAccel != null) _statCard('Accel max', '${_stats!.maxAccel!.toStringAsFixed(0)} RPM/s'),
                if (_stats!.minAccel != null) _statCard('Accel avg', '${_stats!.avgAccel!.toStringAsFixed(0)} RPM/s'),
                if (_stats!.minKick != null) _statCard('Kick min', '${_stats!.minKick!.toStringAsFixed(0)}'),
                if (_stats!.minKick != null) _statCard('Kick max', '${_stats!.maxKick!.toStringAsFixed(0)}'),
                if (_stats!.minRawCorr != null) _statCard('RawCorr min', '${_stats!.minRawCorr!.toStringAsFixed(0)}'),
                if (_stats!.minRawCorr != null) _statCard('RawCorr max', '${_stats!.maxRawCorr!.toStringAsFixed(0)}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          Text(value,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildRPMChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RPM vs Czas',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.averagedRPM))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: _stats!.maxRPM * 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPWMChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PWM vs Czas',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.targetPWM.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.lastPWM.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: 1023,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('Target PWM', Colors.green),
                _legend('Last PWM', Colors.orange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildADCChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ADC (Throttle) vs Czas',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.adc.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.teal,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                          show: true,
                          color: Colors.teal.withOpacity(0.2)),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: 1023,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClutchChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sprzeglo (%) vs Czas',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('0% = puszczone, 100% = wcisniete',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 150,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(), e.clutchPercent.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.pink,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                          show: true,
                          color: Colors.pink.withOpacity(0.2)),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: 100,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlphaChart() {
    final alphas = _data.map((e) => e.error).toList(); // v4.8: error = fly - avg [RPM], v4.7: alpha dRPM/dt
    final allMin = alphas.reduce((a, b) => a < b ? a : b);
    final allMax = alphas.reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Error / Alpha vs Czas (v4.8: error = fly - avg [RPM])',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('v4.8-state: error = flywheelRPM - averagedRPM; error<0 rozpedzanie (tnij PWM), error>0 hamowanie (dodaj PWM). v4.7: alpha = dRPM/dt [RPM/s]',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(e.timeMs.toDouble(), e.error))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data.map((e) =>
                          FlSpot(e.timeMs.toDouble(), e.averagedRPM)).toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: allMin < 0 ? allMin * 1.1 : -allMax * 0.1,
                  maxY: allMax > 0 ? allMax * 1.1 : -allMin * 0.1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('Error/Alpha (RPM / RPM/s)', Colors.orange),
                _legend('Averaged RPM', Colors.blue),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCombinedChart() {
    final rpmMax = _stats!.maxRPM;
    final alphaMax = _stats!.maxError.abs() > _stats!.minError.abs()
        ? _stats!.maxError.abs()
        : _stats!.minError.abs();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RPM + Error/Alpha + PWM (skalowane) v4.8',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('Niebieski = RPM, Zielony = Error (fly-avg RPM) / Alpha, Pomaranczowy = PWM. Skalowane — ksztalt, nie skala.',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(),
                              e.averagedRPM / (rpmMax <= 0 ? 1 : rpmMax) * 100))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(),
                              e.error / (alphaMax <= 0 ? 1 : alphaMax) * 100))
                          .toList(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(), e.lastPWM / 1023.0 * 100))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: 100,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('RPM (% max)', Colors.blue),
                _legend('Error/Alpha (% max)', Colors.green),
                _legend('PWM (%)', Colors.orange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlywheelVsEngineChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Flywheel RPM vs Engine RPM',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('v4.8-state: niebieski = silnik (avg), pomaranczowy = kolo (fly) podaza z tau=J*alpha. Odstep = error = fly-avg -> corr. v4.7: linie pokrywaja sie (fly==avg).',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.averagedRPM))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) =>
                              FlSpot(e.timeMs.toDouble(), e.flywheelRPM))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: _stats!.maxRPM * 1.1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('Engine RPM', Colors.blue),
                _legend('Flywheel RPM', Colors.orange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCorrectionChart() {
    final alphas = _data.map((e) => e.error).toList();
    final pwmDeltas = _data.map((e) => (e.lastPWM - e.targetPWM).toDouble()).toList();
    final allMin = [alphas.reduce((a, b) => a < b ? a : b), pwmDeltas.reduce((a, b) => a < b ? a : b)].reduce((a, b) => a < b ? a : b);
    final allMax = [alphas.reduce((a, b) => a > b ? a : b), pwmDeltas.reduce((a, b) => a > b ? a : b)].reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Korekta flywheel v4.8',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('Niebieski = error (fly-avg RPM), Pomaranczowy = korekta PWM (last-target). error<0 tnij, error>0 dodaj; corr=error*flyK*gain*map',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(e.timeMs.toDouble(), e.error))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(e.timeMs.toDouble(), (e.lastPWM - e.targetPWM).toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: allMin < 0 ? allMin * 1.1 : -allMax * 0.1,
                  maxY: allMax > 0 ? allMax * 1.1 : -allMin * 0.1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('Error (fly-avg)', Colors.blue),
                _legend('Korekta PWM', Colors.orange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKickChart() {
    if (_data.every((e) => e.kick == null)) return const SizedBox.shrink();
    final kicks = _data.where((e) => e.kick != null).map((e) => e.kick!.toDouble()).toList();
    final deltas = _data.map((e) => (e.lastPWM - e.targetPWM).toDouble()).toList();
    final allMin = [kicks.reduce((a, b) => a < b ? a : b), deltas.reduce((a, b) => a < b ? a : b)].reduce((a, b) => a < b ? a : b);
    final allMax = [kicks.reduce((a, b) => a > b ? a : b), deltas.reduce((a, b) => a > b ? a : b)].reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kick z pochodnej (dRPM/dt)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('Pomaranczowy = kick, Zielony = efektywna korekta PWM (lastPWM - targetPWM)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data.map((e) => FlSpot(e.timeMs.toDouble(), (e.kick ?? 0).toDouble())).toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data.map((e) => FlSpot(e.timeMs.toDouble(), (e.lastPWM - e.targetPWM).toDouble())).toList(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: allMin < 0 ? allMin * 1.1 : -allMax * 0.1,
                  maxY: allMax > 0 ? allMax * 1.1 : -allMin * 0.1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('Kick', Colors.orange),
                _legend('Efektywna korekta', Colors.green),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRawCorrChart() {
    if (_data.every((e) => e.rawCorr == null)) return const SizedBox.shrink();
    final raws = _data.where((e) => e.rawCorr != null).map((e) => e.rawCorr!.toDouble()).toList();
    final deltas = _data.map((e) => (e.lastPWM - e.targetPWM).toDouble()).toList();
    final allMin = [raws.reduce((a, b) => a < b ? a : b), deltas.reduce((a, b) => a < b ? a : b)].reduce((a, b) => a < b ? a : b);
    final allMax = [raws.reduce((a, b) => a > b ? a : b), deltas.reduce((a, b) => a > b ? a : b)].reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RawCorr vs efektywna korekta (slew-rate)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Center(
              child: Text('Niebieski = rawCorr (korekcja IIR PRZED limiterem), Pomaranczowy = efektywna (po limiterze). Rozjazd = dzialanie slew-rate.',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data.map((e) => FlSpot(e.timeMs.toDouble(), (e.rawCorr ?? 0).toDouble())).toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data.map((e) => FlSpot(e.timeMs.toDouble(), (e.lastPWM - e.targetPWM).toDouble())).toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: allMin < 0 ? allMin * 1.1 : -allMax * 0.1,
                  maxY: allMax > 0 ? allMax * 1.1 : -allMin * 0.1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('RawCorr (przed slew)', Colors.blue),
                _legend('Efektywna (po slew)', Colors.orange),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildADCRawVsPWMChart() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ADC Raw vs Last PWM',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                  titlesData: _titles(),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(), e.lastPWM.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.orange,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: _data
                          .map((e) => FlSpot(
                              e.timeMs.toDouble(), e.adcRaw.toDouble()))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  minX: _data.first.timeMs.toDouble(),
                  maxX: _data.last.timeMs.toDouble(),
                  minY: 0,
                  maxY: 1023,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legend('RPM', Colors.blue),
              ],
            ),
          ],
        ),
      ),
    );
  }

  FlTitlesData _titles() {
    return FlTitlesData(
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 50,
          getTitlesWidget: (value, meta) {
            return Text(value.toInt().toString(),
                style: const TextStyle(fontSize: 10));
          },
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 30,
          getTitlesWidget: (value, meta) {
            return Text('${(value / 1000).toStringAsFixed(1)}s',
                style: const TextStyle(fontSize: 10));
          },
        ),
      ),
      rightTitles: const AxisTitles(
        sideTitles: SideTitles(showTitles: false),
      ),
      topTitles: const AxisTitles(
        sideTitles: SideTitles(showTitles: false),
      ),
    );
  }

  Widget _legend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 3, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
