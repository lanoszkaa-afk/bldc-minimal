import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// Win32 constants
const int GENERIC_READ = 0x80000000;
const int GENERIC_WRITE = 0x40000000;
const int OPEN_EXISTING = 3;
const int INVALID_HANDLE_VALUE = -1;
const int FILE_FLAG_OVERLAPPED = 0x40000000;
const int PURGE_RXCLEAR = 0x0008;
const int PURGE_TXCLEAR = 0x0004;
const int SETDTR = 5;
const int CLRDTR = 6;
const int SETRTS = 3;
const int CLRRTS = 4;
const int NOPARITY = 0;
const int ONESTOPBIT = 0;
const int CBR_115200 = 115200;

final _kernel32 = DynamicLibrary.open('kernel32.dll');

// CreateFileW
typedef _CreateFileW_C = IntPtr Function(
    Pointer<Utf16> lpFileName,
    Uint32 dwDesiredAccess,
    Uint32 dwShareMode,
    Pointer lpSecurityAttributes,
    Uint32 dwCreationDisposition,
    Uint32 dwFlagsAndAttributes,
    IntPtr hTemplateFile);
typedef _CreateFileW_Dart = int Function(
    Pointer<Utf16> lpFileName,
    int dwDesiredAccess,
    int dwShareMode,
    Pointer lpSecurityAttributes,
    int dwCreationDisposition,
    int dwFlagsAndAttributes,
    int hTemplateFile);
final _CreateFileW =
    _kernel32.lookupFunction<_CreateFileW_C, _CreateFileW_Dart>('CreateFileW');

// CloseHandle
typedef _CloseHandle_C = Int32 Function(IntPtr hObject);
typedef _CloseHandle_Dart = int Function(int hObject);
final _CloseHandle =
    _kernel32.lookupFunction<_CloseHandle_C, _CloseHandle_Dart>('CloseHandle');

// ReadFile
typedef _ReadFile_C = Int32 Function(IntPtr hFile, Pointer lpBuffer,
    Uint32 nNumberOfBytesToRead, Pointer<Uint32> lpNumberOfBytesRead, Pointer lpOverlapped);
typedef _ReadFile_Dart = int Function(int hFile, Pointer lpBuffer,
    int nNumberOfBytesToRead, Pointer<Uint32> lpNumberOfBytesRead, Pointer lpOverlapped);
final _ReadFile =
    _kernel32.lookupFunction<_ReadFile_C, _ReadFile_Dart>('ReadFile');

// WriteFile
typedef _WriteFile_C = Int32 Function(IntPtr hFile, Pointer lpBuffer,
    Uint32 nNumberOfBytesToWrite, Pointer<Uint32> lpNumberOfBytesWritten, Pointer lpOverlapped);
typedef _WriteFile_Dart = int Function(int hFile, Pointer lpBuffer,
    int nNumberOfBytesToWrite, Pointer<Uint32> lpNumberOfBytesWritten, Pointer lpOverlapped);
final _WriteFile =
    _kernel32.lookupFunction<_WriteFile_C, _WriteFile_Dart>('WriteFile');

// GetCommState
typedef _GetCommState_C = Int32 Function(IntPtr hFile, Pointer lpDCB);
typedef _GetCommState_Dart = int Function(int hFile, Pointer lpDCB);
final _GetCommState =
    _kernel32.lookupFunction<_GetCommState_C, _GetCommState_Dart>('GetCommState');

// SetCommState
typedef _SetCommState_C = Int32 Function(IntPtr hFile, Pointer lpDCB);
typedef _SetCommState_Dart = int Function(int hFile, Pointer lpDCB);
final _SetCommState =
    _kernel32.lookupFunction<_SetCommState_C, _SetCommState_Dart>('SetCommState');

// SetCommTimeouts
typedef _SetCommTimeouts_C = Int32 Function(IntPtr hFile, Pointer lpCommTimeouts);
typedef _SetCommTimeouts_Dart = int Function(int hFile, Pointer lpCommTimeouts);
final _SetCommTimeouts =
    _kernel32.lookupFunction<_SetCommTimeouts_C, _SetCommTimeouts_Dart>('SetCommTimeouts');

// EscapeCommFunction
typedef _EscapeCommFunction_C = Int32 Function(IntPtr hFile, Uint32 dwFunc);
typedef _EscapeCommFunction_Dart = int Function(int hFile, int dwFunc);
final _EscapeCommFunction =
    _kernel32.lookupFunction<_EscapeCommFunction_C, _EscapeCommFunction_Dart>('EscapeCommFunction');

// PurgeComm
typedef _PurgeComm_C = Int32 Function(IntPtr hFile, Uint32 dwFlags);
typedef _PurgeComm_Dart = int Function(int hFile, int dwFlags);
final _PurgeComm =
    _kernel32.lookupFunction<_PurgeComm_C, _PurgeComm_Dart>('PurgeComm');

// SetupComm
typedef _SetupComm_C = Int32 Function(IntPtr hFile, Uint32 dwInQueue, Uint32 dwOutQueue);
typedef _SetupComm_Dart = int Function(int hFile, int dwInQueue, int dwOutQueue);
final _SetupComm =
    _kernel32.lookupFunction<_SetupComm_C, _SetupComm_Dart>('SetupComm');

/// Simple Win32 serial port wrapper with DTR/RTS control
class Win32Serial {
  int _handle = INVALID_HANDLE_VALUE;
  Timer? _readTimer;
  final StreamController<String> _dataController = StreamController<String>.broadcast();
  bool _isOpen = false;
  int _debugReadCount = 0;

  bool get isOpen => _isOpen;
  Stream<String> get dataStream => _dataController.stream;

  /// Open COM port with baud rate, toggle DTR to reset Arduino, purge buffers
  Future<void> open(String portName, int baudRate) async {
    // Win32 requires \\.\COMx format for COM10+
    final winName = portName.startsWith(r'\\') ? portName : r'\\.\' + portName;
    final lpFileName = winName.toNativeUtf16();

    try {
      _handle = _CreateFileW(
        lpFileName,
        GENERIC_READ | GENERIC_WRITE,
        0, // no sharing
        nullptr,
        OPEN_EXISTING,
        0, // synchronous
        0,
      );
    } finally {
      calloc.free(lpFileName);
    }

    if (_handle == INVALID_HANDLE_VALUE || _handle == 0) {
      throw Exception('Nie można otworzyć portu $portName');
    }

    // NATYCHMIAST wyłącz DTR/RTS zanim cokolwiek innego
    // CreateFileW asertuje DTR - wyłącz ASAP żeby Arduino się nie resetowało
    _EscapeCommFunction(_handle, CLRDTR);
    _EscapeCommFunction(_handle, CLRRTS);
    print('WIN32: CLRDTR+CLRRTS done immediately after CreateFileW');

    // Setup buffers
    _SetupComm(_handle, 4096, 4096);

    // Configure DCB - z fDtrControl=DISABLE żeby SetCommState nie re-asertowało DTR
    final dcb = calloc<Uint8>(28 * 4); // DCB struct ~112 bytes
    dcb.cast<Uint32>().value = 28 * 4;
    
    if (_GetCommState(_handle, dcb) == 0) {
      calloc.free(dcb);
      _CloseHandle(_handle);
      throw Exception('GetCommState failed');
    }

    // Set baud rate (offset 4)
    (dcb + 4).cast<Uint32>().value = baudRate;
    
    // Set flags (offset 8) - disable DTR and RTS to prevent Arduino reset
    int flags = (dcb + 8).cast<Uint32>().value;
    flags &= ~(0x3 << 4);   // Clear fDtrControl (bits 4-5) = DTR_CONTROL_DISABLE
    flags &= ~(0x3 << 12);  // Clear fRtsControl (bits 12-13) = RTS_CONTROL_DISABLE
    (dcb + 8).cast<Uint32>().value = flags;
    
    // Set byte size (offset 18) 
    (dcb + 18).cast<Uint8>().value = 8;
    // Set parity (offset 19)
    (dcb + 19).cast<Uint8>().value = NOPARITY;
    // Set stop bits (offset 20)
    (dcb + 20).cast<Uint8>().value = ONESTOPBIT;

    if (_SetCommState(_handle, dcb) == 0) {
      calloc.free(dcb);
      _CloseHandle(_handle);
      throw Exception('SetCommState failed');
    }
    calloc.free(dcb);
    print('WIN32: SetCommState done with fDtrControl=DISABLE');

    // Set timeouts - non-blocking read with 100ms max wait
    final timeouts = calloc<Uint32>(5);
    timeouts[0] = 100; // ReadIntervalTimeout
    timeouts[1] = 0;   // ReadTotalTimeoutMultiplier
    timeouts[2] = 100; // ReadTotalTimeoutConstant
    timeouts[3] = 0;   // WriteTotalTimeoutMultiplier
    timeouts[4] = 100; // WriteTotalTimeoutConstant
    _SetCommTimeouts(_handle, timeouts.cast());
    calloc.free(timeouts);

    // Arduino mogło się zresetować od CreateFileW DTR pulse
    // Czekaj na zakończenie bootu Arduino (~2s)
    print('WIN32: Waiting 2.5s for Arduino boot...');
    await Future.delayed(const Duration(milliseconds: 2500));

    // Wyczyść bufory - usuń wszystkie boot messages
    _PurgeComm(_handle, PURGE_RXCLEAR | PURGE_TXCLEAR);
    print('WIN32: PurgeComm done - buffers cleared');

    _isOpen = true;
    _debugReadCount = 0;

    // Start polling for data - od teraz powinny być tylko nowe dane
    _startReading();
    print('WIN32: Reading started');
  }

  void _startReading() {
    final buf = calloc<Uint8>(1024);
    final bytesRead = calloc<Uint32>();

    _readTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!_isOpen || _handle == INVALID_HANDLE_VALUE) return;

      final result = _ReadFile(_handle, buf, 1024, bytesRead, nullptr);
      if (result != 0 && bytesRead.value > 0) {
        final data = Uint8List.fromList(buf.asTypedList(bytesRead.value));
        _debugReadCount++;
        if (_debugReadCount <= 10) {
          final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          print('WIN32_READ #$_debugReadCount (${data.length} bytes): $hex');
        }
        final text = utf8.decode(data, allowMalformed: true);
        if (text.isNotEmpty) {
          _dataController.add(text);
        }
      }
    });
  }

  void write(String data) {
    if (!_isOpen || _handle == INVALID_HANDLE_VALUE) return;
    final encoded = utf8.encode(data);
    final buf = calloc<Uint8>(encoded.length);
    for (int i = 0; i < encoded.length; i++) {
      buf[i] = encoded[i];
    }
    final bytesWritten = calloc<Uint32>();
    _WriteFile(_handle, buf, encoded.length, bytesWritten, nullptr);
    calloc.free(buf);
    calloc.free(bytesWritten);
  }

  void close() {
    _isOpen = false;
    _readTimer?.cancel();
    _readTimer = null;
    if (_handle != INVALID_HANDLE_VALUE && _handle != 0) {
      _CloseHandle(_handle);
      _handle = INVALID_HANDLE_VALUE;
    }
  }

  void dispose() {
    close();
    _dataController.close();
  }
}
