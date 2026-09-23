import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/constants/app_info.dart';
import '../../../engine/vault/drive_vault.dart';
import '../domain/protected_item.dart';

/// Why a path can't be protected.
enum PathProblem {
  notFound,
  driveRoot,
  systemLocation,
  userFolderRoot,
  appFolder,
  isVault,
  isLink,
  alreadyProtected,
  insideProtectedItem,
  containsProtectedItem,
}

/// Decides which files and folders may be locked.
///
/// Locking system folders (or a folder that contains them) could break
/// Windows or other apps, so they are refused, like Anvi's exclusion list.
class PathGuard {
  PathGuard({
    required this.appDataDir,
    required this.executableDir,
    Map<String, String>? environment,
  }) : _env = environment ?? Platform.environment;

  final String appDataDir;
  final String executableDir;
  final Map<String, String> _env;

  static const List<String> _userFolderNames = [
    '3D Objects',
    'AppData',
    'Contacts',
    'Desktop',
    'Documents',
    'Downloads',
    'Favorites',
    'Links',
    'Music',
    'OneDrive',
    'Pictures',
    'Saved Games',
    'Searches',
    'Videos',
  ];

  static const List<String> _systemNames = [
    r'$recycle.bin',
    'system volume information',
    'recovery',
    'pagefile.sys',
    'hiberfil.sys',
    'swapfile.sys',
  ];

  /// Folders that may never be locked, nor anything inside them.
  List<String> get _systemRoots => [
    for (final name in [
      'SystemRoot',
      'windir',
      'ProgramFiles',
      'ProgramFiles(x86)',
      'ProgramW6432',
      'ProgramData',
      'APPDATA',
      'LOCALAPPDATA',
    ])
      ?_env[name],
    appDataDir,
    executableDir,
  ];

  /// Folders that may not be locked themselves, but their contents may
  /// (for example `Documents\Secret` is fine, `Documents` is not).
  List<String> get _userRoots {
    final profile = _env['USERPROFILE'];
    final systemDrive = _env['SystemDrive'];
    return [
      ?profile,
      if (profile != null)
        for (final name in _userFolderNames) p.join(profile, name),
      if (systemDrive != null) ...[
        p.join('$systemDrive\\', 'Users'),
        p.join('$systemDrive\\', 'Users', 'Public'),
      ],
    ];
  }

  PathProblem? check(String path, List<ProtectedItem> items) {
    final normalized = p.normalize(path);
    final type = FileSystemEntity.typeSync(normalized, followLinks: false);
    if (type == FileSystemEntityType.notFound) return PathProblem.notFound;
    if (type == FileSystemEntityType.link) return PathProblem.isLink;
    if (p.dirname(normalized) == normalized ||
        p.rootPrefix(normalized) == normalized) {
      return PathProblem.driveRoot;
    }
    // A vault file, a drive vault folder, or anything inside one.
    if (normalized.toLowerCase().endsWith(AppInfo.vaultExtension) ||
        p
            .split(normalized)
            .any((part) => part.toLowerCase().endsWith(DriveVault.extension))) {
      return PathProblem.isVault;
    }
    if (_systemNames.contains(p.basename(normalized).toLowerCase())) {
      return PathProblem.systemLocation;
    }

    for (final root in [appDataDir, executableDir]) {
      if (_same(root, normalized) ||
          _inside(normalized, root) ||
          _inside(root, normalized)) {
        return PathProblem.appFolder;
      }
    }
    for (final root in _systemRoots) {
      if (_same(root, normalized) ||
          _inside(normalized, root) ||
          _inside(root, normalized)) {
        return PathProblem.systemLocation;
      }
    }
    for (final root in _userRoots) {
      if (_same(root, normalized) || _inside(root, normalized)) {
        return PathProblem.userFolderRoot;
      }
    }

    for (final item in items) {
      for (final itemPath in {item.itemPath, ?item.vaultPath}) {
        if (_same(itemPath, normalized)) return PathProblem.alreadyProtected;
        if (_inside(normalized, itemPath)) {
          return PathProblem.insideProtectedItem;
        }
        if (_inside(itemPath, normalized)) {
          return PathProblem.containsProtectedItem;
        }
      }
    }
    return null;
  }

  static String _key(String path) => p.normalize(path).toLowerCase();

  static bool _same(String a, String b) => _key(a) == _key(b);

  /// Whether [child] is inside [parent].
  static bool _inside(String child, String parent) =>
      p.isWithin(_key(parent), _key(child));
}
