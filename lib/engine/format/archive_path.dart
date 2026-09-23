import '../engine_exception.dart';

/// Rules for relative paths stored inside a vault.
///
/// Paths use `/` as separator. Every component must be a name Windows can
/// create, so a restored item is always identical to the original, and a
/// crafted vault can never write outside the folder being restored
/// ("zip slip").
abstract final class ArchivePath {
  static final RegExp _forbiddenChars = RegExp(r'[<>:"|?*\\/\x00-\x1f]');
  static final RegExp _reservedName = RegExp(
    r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$',
    caseSensitive: false,
  );

  /// Maximum length of one stored path, in characters.
  static const int maxLength = 32000;

  /// Returns `null` when [relativePath] is acceptable, otherwise the reason.
  static String? problem(String relativePath) {
    if (relativePath.isEmpty) return 'empty path';
    if (relativePath.length > maxLength) return 'path is too long';
    for (final part in relativePath.split('/')) {
      final issue = componentProblem(part);
      if (issue != null) return issue;
    }
    return null;
  }

  /// Returns `null` when [name] is a valid single file or folder name.
  static String? componentProblem(String name) {
    if (name.isEmpty) return 'empty name';
    if (name == '.' || name == '..') return 'relative name "$name"';
    if (_forbiddenChars.hasMatch(name)) return 'invalid character in "$name"';
    if (name.endsWith('.') || name.endsWith(' ')) {
      return 'name "$name" ends with a dot or space';
    }
    if (_reservedName.hasMatch(name)) return 'reserved name "$name"';
    return null;
  }

  /// Throws a [EngineErrorCode.corruptVault] error for invalid paths read
  /// from a vault.
  static void checkStored(String relativePath) {
    final issue = problem(relativePath);
    if (issue != null) {
      throw EngineException(
        EngineErrorCode.corruptVault,
        'Invalid path in vault: $issue',
      );
    }
  }

  /// Throws a [EngineErrorCode.unsupportedContent] error for source files
  /// the vault can't store.
  static void checkSource(String relativePath, String absolutePath) {
    final issue = problem(relativePath);
    if (issue != null) {
      throw EngineException(
        EngineErrorCode.unsupportedContent,
        'Unsupported file name: $issue',
        path: absolutePath,
      );
    }
  }
}
