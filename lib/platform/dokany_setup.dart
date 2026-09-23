import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// How installing Dokany went.
enum DokanySetupResult {
  installed,

  /// Installed; Windows has to restart to finish.
  restartNeeded,

  /// The user said no, to the administrator prompt or in Dokany's setup.
  cancelled,
  failed,
}

class DokanySetupOutcome {
  const DokanySetupOutcome(this.result, {this.code = 0, this.logPath});

  final DokanySetupResult result;

  /// Windows Installer's exit code, or the Windows error when it could not
  /// start.
  final int code;

  /// Dokany setup's log, when it failed.
  final String? logPath;
}

/// Installs Dokany, the driver that drive vaults need.
abstract interface class DokanyInstaller {
  /// Whether the app came with Dokany's installer.
  bool get isAvailable;

  /// Runs it: Windows asks for administrator permission, and Dokany's setup
  /// shows its progress.
  Future<DokanySetupOutcome> install();
}

/// Installs the Dokany that ships next to the app (`dokany\Dokan_x64.msi`,
/// see `installer/get-dokany.ps1`), the same one the installer offers.
class BundledDokanyInstaller implements DokanyInstaller {
  BundledDokanyInstaller(String executableDir)
    : _msi = p.join(executableDir, 'dokany', 'Dokan_x64.msi');

  final String _msi;

  @override
  bool get isAvailable => Platform.isWindows && File(_msi).existsSync();

  @override
  Future<DokanySetupOutcome> install() async {
    if (!isAvailable) {
      return const DokanySetupOutcome(
        DokanySetupResult.failed,
        code: _errorFileNotFound,
      );
    }
    final log = p.join(Directory.systemTemp.path, 'FolderLocker-Dokany.log');
    final parameters = '/i "$_msi" /passive /norestart /l*v "$log"';
    // The administrator prompt belongs to the app's window.
    final owner = _getForegroundWindow().address;
    final (started, code) = await Isolate.run(
      () => _runAsAdministrator('msiexec.exe', parameters, owner),
    );
    if (!started) {
      return DokanySetupOutcome(
        code == _errorCancelled
            ? DokanySetupResult.cancelled
            : DokanySetupResult.failed,
        code: code,
      );
    }
    return switch (code) {
      0 => const DokanySetupOutcome(DokanySetupResult.installed),
      _restartRequired || _restartStarted => DokanySetupOutcome(
        DokanySetupResult.restartNeeded,
        code: code,
      ),
      _userCancelled => DokanySetupOutcome(
        DokanySetupResult.cancelled,
        code: code,
      ),
      _ => DokanySetupOutcome(
        DokanySetupResult.failed,
        code: code,
        logPath: log,
      ),
    };
  }
}

// Windows Installer exit codes and Windows errors.
const int _errorFileNotFound = 2;
const int _errorCancelled = 1223;
const int _userCancelled = 1602;
const int _restartStarted = 1641;
const int _restartRequired = 3010;

/// Starts [file] with administrator rights and waits for it. Returns
/// whether it started, and its exit code (or the Windows error).
(bool, int) _runAsAdministrator(String file, String parameters, int owner) {
  // ShellExecuteEx may use COM. The thread may have it already, in another
  // mode: then it's left as it is.
  final comReady =
      _coInitializeEx(
        nullptr,
        _coinitApartmentThreaded | _coinitDisableOle1Dde,
      ) >=
      0;
  try {
    return using((arena) {
      final info = arena<_ShellExecuteInfo>()
        ..ref.cbSize = sizeOf<_ShellExecuteInfo>()
        ..ref.fMask = _seeMaskNoCloseProcess | _seeMaskNoAsync | _seeMaskNoUi
        ..ref.hwnd = Pointer.fromAddress(owner)
        ..ref.lpVerb = 'runas'.toNativeUtf16(allocator: arena)
        ..ref.lpFile = file.toNativeUtf16(allocator: arena)
        ..ref.lpParameters = parameters.toNativeUtf16(allocator: arena)
        ..ref.nShow = _swShowNormal;
      if (_shellExecuteEx(info) == 0) return (false, _getLastError());
      final process = info.ref.hProcess;
      if (process == nullptr) return (true, 0);
      try {
        _waitForSingleObject(process, _infinite);
        final code = arena<Uint32>();
        if (_getExitCodeProcess(process, code) == 0) {
          return (true, _getLastError());
        }
        return (true, code.value);
      } finally {
        _closeHandle(process);
      }
    });
  } finally {
    if (comReady) _coUninitialize();
  }
}

const int _seeMaskNoCloseProcess = 0x00000040;
const int _seeMaskNoAsync = 0x00000100;
const int _seeMaskNoUi = 0x00000400;
const int _swShowNormal = 1;
const int _infinite = 0xFFFFFFFF;
const int _coinitApartmentThreaded = 0x2;
const int _coinitDisableOle1Dde = 0x4;

/// `SHELLEXECUTEINFOW`.
final class _ShellExecuteInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int fMask;
  external Pointer<Void> hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;
  @Int32()
  external int nShow;
  external Pointer<Void> hInstApp;
  external Pointer<Void> lpIDList;
  external Pointer<Utf16> lpClass;
  external Pointer<Void> hkeyClass;
  @Uint32()
  external int dwHotKey;
  external Pointer<Void> hIconOrMonitor;
  external Pointer<Void> hProcess;
}

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

final int Function(Pointer<_ShellExecuteInfo>) _shellExecuteEx = _shell32
    .lookupFunction<
      Int32 Function(Pointer<_ShellExecuteInfo>),
      int Function(Pointer<_ShellExecuteInfo>)
    >('ShellExecuteExW');

final int Function(Pointer<Void>, int) _waitForSingleObject = _kernel32
    .lookupFunction<
      Uint32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('WaitForSingleObject');

final int Function(Pointer<Void>, Pointer<Uint32>) _getExitCodeProcess =
    _kernel32.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Uint32>)
    >('GetExitCodeProcess');

final int Function(Pointer<Void>) _closeHandle = _kernel32
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'CloseHandle',
    );

final int Function() _getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

final Pointer<Void> Function() _getForegroundWindow = _user32
    .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetForegroundWindow',
    );

final int Function(Pointer<Void>, int) _coInitializeEx = _ole32
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)
    >('CoInitializeEx');

final void Function() _coUninitialize = _ole32
    .lookupFunction<Void Function(), void Function()>('CoUninitialize');
