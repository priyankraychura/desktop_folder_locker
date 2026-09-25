import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

import 'windows/win32_ffi.dart';

/// Folders Windows and other programs rely on, wherever they really are:
/// the current user's Desktop, Documents… (which may have been moved, for
/// example to `D:\Documents` or into OneDrive) and the profile folder of
/// every account on the PC.
///
/// Locking one of them, or a folder that contains one, would break the
/// account that owns it, so `PathGuard` refuses them (like Anvi's
/// exclusion list, which reads the same registry key).
abstract final class UserFolders {
  /// `FOLDERID_…` of the current user's main folders.
  static const List<String> _knownFolderIds = [
    'B4BFCC3A-DB2C-424C-B029-7FE99A87C641', // Desktop
    'FDD39AD0-238F-46AF-ADB4-6C85480369C7', // Documents
    '374DE290-123F-4565-9164-39C4925E467B', // Downloads
    '4BD8D571-6D19-48D3-BE97-422220080E43', // Music
    '33E28130-4E1E-4676-835A-98395C3BC3BB', // Pictures
    '18989B1D-99B5-455B-841C-AB7C74E4DDFC', // Videos
    '1777F761-68AD-4D8A-87BD-30B759FA33DD', // Favorites
    '4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4', // Saved Games
    'A52BBA46-E9E1-435F-B3D9-28DAA648C0F6', // OneDrive
    '0762D272-C50A-4BB0-A382-697DCD729B80', // Users (all profiles)
    'DFDF76A2-C82A-4D63-906A-5644AC457385', // Public
  ];

  static const String _profileList =
      r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList';

  /// Empty outside Windows, or when nothing can be read.
  static List<String> find() {
    if (!Platform.isWindows) return const [];
    return {..._knownFolders(), ..._profiles()}.toList();
  }

  static Iterable<String> _knownFolders() sync* {
    for (final id in _knownFolderIds) {
      try {
        if (Win32.knownFolderPath(id) case final path?) yield path;
      } on Object {
        // Not on this version of Windows.
      }
    }
  }

  static List<String> _profiles() {
    try {
      final list = LOCAL_MACHINE.open(_profileList);
      try {
        return [
          for (final sid in list.keys)
            if (list.getString('ProfileImagePath', path: sid, expandPaths: true)
                case final path? when path.isNotEmpty)
              path,
        ];
      } finally {
        list.close();
      }
    } on Object {
      return const [];
    }
  }
}
