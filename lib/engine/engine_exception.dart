/// Error codes produced by the locking engine.
///
/// The UI maps each code to a friendly message, so the engine never has to
/// know about wording or translations.
enum EngineErrorCode {
  /// The password or recovery key does not open this vault.
  wrongPassword,

  /// A file inside the item is open in another program.
  inUse,

  /// Windows denied access to the item.
  accessDenied,

  /// The item (or the vault) does not exist anymore.
  notFound,

  /// Something already exists where the engine wants to write.
  alreadyExists,

  /// The location is protected (system folder, drive root, app data…).
  protectedLocation,

  /// The item contains something the vault format can't store safely.
  unsupportedContent,

  /// Not enough free space on the drive.
  diskFull,

  /// The vault file is damaged or was modified.
  corruptVault,

  /// The vault was created by a newer version of the app.
  unsupportedVersion,

  /// The user cancelled the operation.
  cancelled,

  /// Any other file system error.
  ioError,
}

/// An error raised by the locking engine.
///
/// Instances are sent between isolates, so they only hold plain data.
class EngineException implements Exception {
  const EngineException(this.code, this.message, {this.path});

  final EngineErrorCode code;

  /// Technical details, useful in logs. Not shown to users as-is.
  final String message;

  /// The file or folder the error is about, when known.
  final String? path;

  @override
  String toString() =>
      'EngineException(${code.name}): $message${path == null ? '' : ' [$path]'}';
}
