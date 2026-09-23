import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/file_system_info.dart';
import '../engine_exception.dart';

/// File system helpers shared by the lock and unlock operations.
abstract final class FsUtils {
  /// Converts a dart:io error into an [EngineException] with a useful code.
  static EngineException mapError(
    FileSystemException error, {
    String? path,
    bool renaming = false,
  }) {
    final code = error.osError?.errorCode;
    final target = path ?? error.path;
    final message = error.osError?.message ?? error.message;
    final EngineErrorCode kind;
    if (Platform.isWindows) {
      kind = switch (code) {
        2 || 3 => EngineErrorCode.notFound,
        // Renaming a folder fails with "access denied" when a program has a
        // file inside it open.
        5 when renaming => EngineErrorCode.inUse,
        5 => EngineErrorCode.accessDenied,
        32 || 33 => EngineErrorCode.inUse,
        80 || 183 => EngineErrorCode.alreadyExists,
        39 || 112 => EngineErrorCode.diskFull,
        206 => EngineErrorCode.unsupportedContent,
        _ => EngineErrorCode.ioError,
      };
    } else {
      kind = switch (code) {
        2 => EngineErrorCode.notFound,
        1 || 13 => EngineErrorCode.accessDenied,
        16 || 26 => EngineErrorCode.inUse,
        17 || 39 => EngineErrorCode.alreadyExists,
        28 => EngineErrorCode.diskFull,
        36 => EngineErrorCode.unsupportedContent,
        _ => EngineErrorCode.ioError,
      };
    }
    return EngineException(kind, message, path: target);
  }

  /// Runs [action], converting file system errors to [EngineException].
  static T guard<T>(
    T Function() action, {
    String? path,
    bool renaming = false,
  }) {
    try {
      return action();
    } on FileSystemException catch (e) {
      throw mapError(e, path: path, renaming: renaming);
    }
  }

  static bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  static bool isDirectory(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory;

  /// Renames a file or folder.
  static void rename(String from, String to) {
    if (exists(to)) {
      throw EngineException(
        EngineErrorCode.alreadyExists,
        'Target already exists',
        path: to,
      );
    }
    guard(
      () {
        if (isDirectory(from)) {
          Directory(from).renameSync(to);
        } else {
          File(from).renameSync(to);
        }
      },
      path: from,
      renaming: true,
    );
  }

  /// Deletes a file or folder tree, clearing read-only flags first.
  ///
  /// Never follows links. Returns the paths that could not be deleted.
  static List<String> deleteTree(String path) {
    final failures = <String>[];
    _deleteTree(path, failures);
    return failures;
  }

  static void _deleteTree(String path, List<String> failures) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    try {
      switch (type) {
        case FileSystemEntityType.notFound:
          return;
        case FileSystemEntityType.directory:
          final children = Directory(path).listSync(followLinks: false);
          for (final child in children) {
            _deleteTree(child.path, failures);
          }
          FileSystemInfo.setAttributes(path, 0);
          Directory(path).deleteSync();
        case FileSystemEntityType.link:
          Link(path).deleteSync();
        default:
          FileSystemInfo.setAttributes(path, 0);
          File(path).deleteSync();
      }
    } on FileSystemException {
      failures.add(path);
    }
  }

  /// Returns [desired] if nothing exists there, otherwise the first free
  /// variant: `Name (2)`, `Name (3)`… (the extension is kept for files).
  static String freePath(String desired, {bool keepExtension = true}) {
    if (!exists(desired)) return desired;
    final dir = p.dirname(desired);
    final extension = keepExtension ? p.extension(desired) : '';
    final base = extension.isEmpty
        ? p.basename(desired)
        : p.basenameWithoutExtension(desired);
    for (var i = 2; i < 10000; i++) {
      final candidate = p.join(dir, '$base ($i)$extension');
      if (!exists(candidate)) return candidate;
    }
    throw EngineException(
      EngineErrorCode.alreadyExists,
      'No free name available',
      path: desired,
    );
  }

  /// Throws [EngineErrorCode.diskFull] if the drive of [path] has less
  /// than [bytesNeeded] free (only checked where the OS tells us).
  static void checkFreeSpace(String path, int bytesNeeded) {
    final free = FileSystemInfo.freeSpace(path);
    if (free != null && free < bytesNeeded) {
      throw EngineException(
        EngineErrorCode.diskFull,
        'Not enough free space: $bytesNeeded bytes needed, $free available',
        path: path,
      );
    }
  }
}
