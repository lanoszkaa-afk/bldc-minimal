/// Mixin do parsowania linii z danych serial (obsługa \r\n).
/// Używany przez ekrany konfiguracji i map do ujednolicenia
/// logiki buforowania i podziału na linie.
mixin SerialLineParser {
  String _serialLineBuffer = '';

  /// Przetwarza surowy tekst z portu serial na linie.
  /// Wywołuje [onLine] dla każdej kompletnej linii (niepustej, trimowanej).
  void parseSerialText(String text, void Function(String line) onLine) {
    _serialLineBuffer += text;
    while (_serialLineBuffer.contains('\n') || _serialLineBuffer.contains('\r')) {
      int idx = -1;
      for (int i = 0; i < _serialLineBuffer.length; i++) {
        if (_serialLineBuffer[i] == '\n' || _serialLineBuffer[i] == '\r') {
          idx = i;
          break;
        }
      }
      if (idx == -1) break;
      final line = _serialLineBuffer.substring(0, idx).trim();
      int next = idx + 1;
      if (next < _serialLineBuffer.length &&
          _serialLineBuffer[idx] == '\r' &&
          _serialLineBuffer[next] == '\n') {
        next++;
      }
      _serialLineBuffer = _serialLineBuffer.substring(next);
      if (line.isEmpty) continue;
      onLine(line);
    }
  }

  void resetSerialBuffer() {
    _serialLineBuffer = '';
  }
}
