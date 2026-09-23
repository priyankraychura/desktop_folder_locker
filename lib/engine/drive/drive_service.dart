import '../crypto/crypto_service.dart';
import '../operations/operation_progress.dart';

/// Why a drive operation failed (engine-level failures such as a damaged
/// vault are [EngineException]s instead).
enum DriveErrorCode {
  /// The drive helper is not installed next to the app.
  helperMissing,

  /// The drive helper stopped while it was needed.
  helperStopped,

  /// Dokany, which provides the drive, is not installed.
  dokanyMissing,

  /// Dokany could not start the drive.
  mountFailed,

  /// No drive letter is free.
  noDriveLetter,

  /// The vault is open as a drive already.
  alreadyMounted,

  /// Windows did not close the drive (usually a program still uses it).
  unmountFailed,

  /// Programs still have files open on the drive (see
  /// [DriveService.unmount]).
  inUse,
}

class DriveException implements Exception {
  const DriveException(this.code, this.message);

  final DriveErrorCode code;
  final String message;

  @override
  String toString() => 'DriveException(${code.name}): $message';
}

/// Whether drives can be opened on this PC.
class DokanyStatus {
  const DokanyStatus({required this.installed, this.reason});

  final bool installed;

  /// Why not, when [installed] is `false`.
  final String? reason;
}

/// What a vault holds (after an import or export).
class DriveStats {
  const DriveStats({
    required this.files,
    required this.folders,
    required this.bytes,
  });

  final int files;
  final int folders;
  final int bytes;
}

/// A vault open as a drive.
class DriveMount {
  const DriveMount({required this.mountPoint});

  /// For example `V:\`.
  final String mountPoint;
}

/// Lets the caller stop an import or export.
class DriveCancelToken {
  void Function()? _onCancel;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }

  /// Called by the service; runs right away if already cancelled.
  void onCancel(void Function() action) {
    _onCancel = action;
    if (_cancelled) action();
  }
}

/// The drive helper, which reads and writes the files of drive vaults and
/// opens them as drives (see `native/`).
abstract interface class DriveService {
  Future<DokanyStatus> status();

  /// Vault folders whose drive closed without [unmount] (for example
  /// ejected in Explorer, or the helper stopped).
  Stream<String> get unmounted;

  /// Encrypts the contents of the folder [source] into the vault folder
  /// [vault] (which has its header already), then checks the result.
  Future<DriveStats> importFolder({
    required String vault,
    required SecureKey key,
    required String source,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  });

  /// Decrypts the vault into the new folder [target], then checks it.
  Future<DriveStats> exportFolder({
    required String vault,
    required SecureKey key,
    required String target,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  });

  Future<DriveMount> mount({
    required String vault,
    required SecureKey key,
    required String label,
  });

  /// Closes the drive of a vault. Does nothing if it isn't open.
  ///
  /// While programs have files open on the drive, throws
  /// [DriveErrorCode.inUse], unless [force] is set: then the drive closes
  /// anyway, and unsaved changes in those files are lost.
  Future<void> unmount(String vault, {bool force = false});

  /// Stops the helper, which closes every drive.
  Future<void> dispose();
}
