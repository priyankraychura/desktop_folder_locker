import '../../../engine/format/archive.dart';

export '../../../engine/format/archive.dart' show ItemKind;

/// Whether an item's protection is currently applied.
enum ProtectionStatus {
  /// Encrypted, blocked, read-only and/or hidden.
  protected,

  /// Temporarily unlocked/visible; can be locked again with one click.
  unprotected,
}

/// Which password opens an encrypted item.
enum PasswordMode { master, custom }

/// How an item's contents are protected. Hiding is a separate option that
/// works with every method.
enum ProtectionMethod {
  /// Encrypted into a vault file in the same place (`Name.flk`).
  encrypt,

  /// A Windows permission rule stops anyone from opening, changing or
  /// deleting it.
  blockAccess,

  /// A Windows permission rule allows opening it, but not changing or
  /// deleting it.
  readOnly,

  /// No protection besides hiding.
  none;

  /// Whether the method uses a Windows permission rule.
  bool get usesAccessRule => this == blockAccess || this == readOnly;
}

/// A file or folder managed by the app.
class ProtectedItem {
  const ProtectedItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.itemPath,
    required this.method,
    required this.hide,
    required this.passwordMode,
    required this.status,
    required this.addedAt,
    required this.updatedAt,
    this.vaultPath,
    this.passwordHint,
    this.sizeBytes,
    this.fileCount,
    this.needsPassword = false,
    this.unlockedAt,
  });

  factory ProtectedItem.fromJson(Map<String, Object?> json) => ProtectedItem(
    id: json['id']! as String,
    name: json['name']! as String,
    kind: ItemKind.values.byName(json['kind']! as String),
    itemPath: json['itemPath']! as String,
    vaultPath: json['vaultPath'] as String?,
    method:
        ProtectionMethod.values.asNameMap()[json['method']] ??
        // Written by 1.0, which only knew "encrypt" (or hide only).
        (json['encrypt'] == true
            ? ProtectionMethod.encrypt
            : ProtectionMethod.none),
    hide: json['hide']! as bool,
    passwordMode: PasswordMode.values.byName(json['passwordMode']! as String),
    passwordHint: json['passwordHint'] as String?,
    status: ProtectionStatus.values.byName(json['status']! as String),
    sizeBytes: json['sizeBytes'] as int?,
    fileCount: json['fileCount'] as int?,
    needsPassword: json['needsPassword'] as bool? ?? false,
    unlockedAt: DateTime.tryParse(json['unlockedAt'] as String? ?? ''),
    addedAt: DateTime.parse(json['addedAt']! as String),
    updatedAt: DateTime.parse(json['updatedAt']! as String),
  );

  final String id;

  /// Display name (the original file or folder name).
  final String name;
  final ItemKind kind;

  /// Where the item lives while it is unprotected (its original location).
  final String itemPath;

  /// The vault file, while an encrypted item is protected.
  final String? vaultPath;
  final ProtectionMethod method;
  final bool hide;
  final PasswordMode passwordMode;
  final String? passwordHint;
  final ProtectionStatus status;
  final int? sizeBytes;
  final int? fileCount;

  /// Set when the vault could not be updated after a master password
  /// change: the next unlock asks for the password instead of using the
  /// session key.
  final bool needsPassword;

  /// When the item was last unlocked (`null` while it is protected). Used
  /// for reminders and to lock it again automatically.
  final DateTime? unlockedAt;
  final DateTime addedAt;
  final DateTime updatedAt;

  bool get isProtected => status == ProtectionStatus.protected;
  bool get encrypt => method == ProtectionMethod.encrypt;
  bool get isEncryptedNow => encrypt && isProtected;

  /// The path that exists on disk right now.
  String get currentPath => isEncryptedNow ? vaultPath ?? itemPath : itemPath;

  ProtectedItem copyWith({
    String? name,
    String? itemPath,
    String? vaultPath,
    bool clearVaultPath = false,
    ProtectionMethod? method,
    bool? hide,
    PasswordMode? passwordMode,
    String? passwordHint,
    bool clearPasswordHint = false,
    ProtectionStatus? status,
    int? sizeBytes,
    int? fileCount,
    bool? needsPassword,
    DateTime? unlockedAt,
  }) => ProtectedItem(
    id: id,
    name: name ?? this.name,
    kind: kind,
    itemPath: itemPath ?? this.itemPath,
    vaultPath: clearVaultPath ? null : vaultPath ?? this.vaultPath,
    method: method ?? this.method,
    hide: hide ?? this.hide,
    passwordMode: passwordMode ?? this.passwordMode,
    passwordHint: clearPasswordHint ? null : passwordHint ?? this.passwordHint,
    status: status ?? this.status,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    fileCount: fileCount ?? this.fileCount,
    needsPassword: needsPassword ?? this.needsPassword,
    // Only kept while the item stays unlocked.
    unlockedAt: (status ?? this.status) == ProtectionStatus.unprotected
        ? unlockedAt ?? this.unlockedAt
        : null,
    addedAt: addedAt,
    updatedAt: DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'itemPath': itemPath,
    'vaultPath': vaultPath,
    'method': method.name,
    'hide': hide,
    'passwordMode': passwordMode.name,
    'passwordHint': passwordHint,
    'status': status.name,
    'sizeBytes': sizeBytes,
    'fileCount': fileCount,
    'needsPassword': needsPassword,
    'unlockedAt': unlockedAt?.toUtc().toIso8601String(),
    'addedAt': addedAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}
