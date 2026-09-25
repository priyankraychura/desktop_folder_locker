/// App-wide names and identifiers. Change the product name here only.
///
/// The app was called Folder Locker before. The identifiers that existing
/// installs and vaults rely on keep that name: the data folder, the
/// registry ids, the `.flk` extension and the vault format's labels.
abstract final class AppInfo {
  static const String name = 'Cloak';
  static const String version = '1.3.9';
  static const String tagline = 'Encrypt and hide your folders on Windows';
  static const String repositoryUrl =
      'https://github.com/priyankraychura/desktop_folder_locker';

  /// The app's license (the LICENSE file).
  static const String legalese =
      'Copyright (C) 2026 Priyank Raychura\n'
      'Free software under the GNU General Public License, version 3 or '
      'later.';

  /// Folder under `%APPDATA%` that holds settings, keys and journals.
  static const String dataFolderName = 'FolderLocker';

  /// Extension of vault files (with the dot).
  static const String vaultExtension = '.flk';

  /// Windows registry identifiers (per-user, under HKCU\Software\Classes).
  static const String vaultProgId = 'FolderLocker.Vault';
  static const String lockVerbKey = 'FolderLocker.Lock';

  /// Resource id of the vault icon inside the executable (Runner.rc).
  static const int vaultIconResourceId = 102;

  /// Where to get Dokany, which opens vaults as drives.
  static const String dokanyDownloadUrl =
      'https://github.com/dokan-dev/dokany/releases/latest';
}
