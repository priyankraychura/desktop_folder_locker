/// App-wide names and identifiers. Change the product name here only.
abstract final class AppInfo {
  static const String name = 'Folder Locker';
  static const String version = '1.2.0';
  static const String tagline = 'Encrypt and hide your folders on Windows';
  static const String repositoryUrl =
      'https://github.com/priyankraychura/desktop_folder_locker';

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
