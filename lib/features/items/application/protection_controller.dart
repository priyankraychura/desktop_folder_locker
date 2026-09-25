import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_info.dart';
import '../../../core/di/core_providers.dart';
import '../../../engine/crypto/kdf_params.dart';
import '../../../engine/drive/drive_operations.dart';
import '../../../engine/drive/drive_service.dart';
import '../../../engine/engine_exception.dart';
import '../../../engine/engine_runner.dart';
import '../../../engine/format/key_slot.dart';
import '../../../engine/operations/lock_operation.dart';
import '../../../engine/operations/operation_progress.dart';
import '../../../engine/operations/unlock_operation.dart';
import '../../../engine/vault/drive_vault.dart';
import '../../../engine/vault/fs_utils.dart';
import '../../../engine/vault/vault_keys.dart';
import '../../../platform/access_control.dart';
import '../../../platform/file_system_info.dart';
import '../../../platform/shell_actions.dart';
import '../../auth/application/session_controller.dart';
import '../domain/protected_item.dart';
import 'item_key_cache.dart';
import 'items_controller.dart';
import 'path_guard.dart';
import 'relock_keys.dart';

enum OperationKind {
  locking,
  unlocking,

  /// Opening a vault as a drive.
  opening,
}

/// The operation currently running, shown by the progress overlay.
@immutable
class ActiveOperation {
  const ActiveOperation({
    required this.kind,
    required this.itemName,
    this.progress,
    this.cancel,
  });

  final OperationKind kind;
  final String itemName;
  final OperationProgress? progress;
  final VoidCallback? cancel;

  ActiveOperation copyWith({
    OperationProgress? progress,
    VoidCallback? cancel,
  }) => ActiveOperation(
    kind: kind,
    itemName: itemName,
    progress: progress ?? this.progress,
    cancel: cancel ?? this.cancel,
  );
}

/// What the user asked for in the "Protect" dialog.
class ProtectRequest {
  const ProtectRequest({
    required this.path,
    required this.method,
    required this.hide,
    required this.passwordMode,
    this.customPassword,
    this.passwordHint,
  }) : assert(
         method != ProtectionMethod.none || hide,
         'An item needs a protection method, or at least to be hidden',
       );

  final String path;
  final ProtectionMethod method;
  final bool hide;
  final PasswordMode passwordMode;
  final String? customPassword;
  final String? passwordHint;
}

/// App-level reasons an action can't run (engine errors are separate).
enum ProtectionIssue {
  pathNotAllowed,
  appLocked,
  passwordRequired,
  busy,
  notFound,
  stillProtected,
  hideFailed,

  /// Adding or removing a Windows permission rule failed.
  accessRuleFailed,

  /// Only folders can become drives.
  driveNeedsFolder,
}

class ProtectionException implements Exception {
  const ProtectionException(this.issue, {this.pathProblem, this.accessProblem});

  final ProtectionIssue issue;
  final PathProblem? pathProblem;
  final AccessProblem? accessProblem;

  @override
  String toString() => 'ProtectionException(${issue.name})';
}

/// What "Lock again" needs before it can run.
enum LockRequirement { none, appUnlock, customPassword }

class UnlockOutcome {
  const UnlockOutcome(this.item, {required this.renamed});

  final ProtectedItem item;

  /// `true` when something already existed at the original location and
  /// the item was restored under a new name (`Name (2)`).
  final bool renamed;
}

final protectionControllerProvider =
    NotifierProvider<ProtectionController, ActiveOperation?>(
      ProtectionController.new,
    );

/// Runs protect / unlock / lock-again workflows and exposes the running
/// operation (with progress) as its state.
class ProtectionController extends Notifier<ActiveOperation?> {
  @override
  ActiveOperation? build() {
    final closed = ref
        .read(driveServiceProvider)
        .unmounted
        .listen(_driveClosed);
    ref.onDispose(closed.cancel);
    return null;
  }

  ItemsController get _items => ref.read(itemsControllerProvider.notifier);
  ItemKeyCache get _cache => ref.read(itemKeyCacheProvider);
  RelockKeys get _relock => ref.read(relockKeysProvider);
  SessionState get _session => ref.read(sessionControllerProvider);
  EngineRunner get _runner => ref.read(engineRunnerProvider);
  String get _journalDir => ref.read(appPathsProvider).journalDir;
  AccessRules get _rules => ref.read(accessRulesProvider);
  DriveService get _drives => ref.read(driveServiceProvider);

  PathGuard get _guard => PathGuard(
    appDataDir: ref.read(appPathsProvider).root,
    executableDir: p.dirname(ref.read(executablePathProvider)),
    environment: ref.read(environmentProvider),
    userFolders: ref.read(userFoldersProvider),
  );

  /// `null` if [path] may be protected.
  PathProblem? checkPath(String path) => _guard.check(path, _items.items);

  /// Why [path] can't use Block access or Read-only, or `null`.
  AccessProblem? accessRuleProblem(String path) => _rules.check(path);

  /// A key that opens [item] without asking the user, if the session has
  /// one.
  VaultCredential? sessionCredential(ProtectedItem item) {
    final cached = _cache[item.id];
    if (cached != null) {
      return DerivedKeyCredential(cached.key, cached.slotType);
    }
    final masterKey = _session.masterKey;
    if (item.passwordMode == PasswordMode.master &&
        !item.needsPassword &&
        _session.isUnlocked &&
        masterKey != null) {
      return DerivedKeyCredential(masterKey, KeySlotType.masterPassword);
    }
    return null;
  }

  /// Keeps [masterKey] for [item], so it can be locked again while the app
  /// is locked. The key belongs to the cache from now on.
  void rememberMasterKey(ProtectedItem item, DerivedKey masterKey) =>
      _cache.put(item.id, masterKey, KeySlotType.masterPassword);

  LockRequirement lockRequirement(ProtectedItem item) {
    // Closing a drive needs no key.
    if (!item.method.encrypts || item.isMounted) return LockRequirement.none;
    final cached = _cache[item.id]?.slotType;
    // Keys made when it was unlocked lock it without a password.
    final prepared =
        item.method == ProtectionMethod.encrypt && _relock.has(item.id);
    return switch (item.passwordMode) {
      PasswordMode.master =>
        _session.isUnlocked || cached == KeySlotType.masterPassword || prepared
            ? LockRequirement.none
            : LockRequirement.appUnlock,
      PasswordMode.custom =>
        cached == KeySlotType.customPassword || prepared
            ? LockRequirement.none
            : LockRequirement.customPassword,
    };
  }

  /// Protects a new file or folder.
  Future<ProtectedItem> protectNew(ProtectRequest request) async {
    _ensureIdle();
    final path = p.normalize(request.path);
    final problem = checkPath(path);
    if (problem != null) {
      throw ProtectionException(
        ProtectionIssue.pathNotAllowed,
        pathProblem: problem,
      );
    }
    if (request.method.encrypts &&
        request.passwordMode == PasswordMode.master &&
        !_session.isUnlocked) {
      throw const ProtectionException(ProtectionIssue.appLocked);
    }
    if (request.method == ProtectionMethod.drive &&
        !FsUtils.isDirectory(path)) {
      throw const ProtectionException(ProtectionIssue.driveNeedsFolder);
    }

    final now = DateTime.now();
    final item = ProtectedItem(
      id: _newId(),
      name: p.basename(path),
      kind: FsUtils.isDirectory(path) ? ItemKind.folder : ItemKind.file,
      itemPath: path,
      method: request.method,
      hide: request.hide,
      passwordMode: request.passwordMode,
      passwordHint: _clean(request.passwordHint),
      status: ProtectionStatus.unprotected,
      addedAt: now,
      updatedAt: now,
    );
    // Saved before starting, so crash recovery can match the journal.
    await _items.upsert(item);
    try {
      return await _protect(item, customPassword: request.customPassword);
    } on Object {
      // Kept only if a half-applied permission rule could not be undone.
      if (!(_items.byId(item.id)?.isProtected ?? false)) {
        await _items.remove(item.id);
      }
      rethrow;
    }
  }

  /// Applies an item's protection again after it was unlocked (for a
  /// drive: closes the drive).
  ///
  /// A drive with files open in programs only closes with [force] (see
  /// [DriveService.unmount]); otherwise it throws [DriveErrorCode.inUse].
  Future<ProtectedItem> lockAgain(
    ProtectedItem item, {
    String? customPassword,
    String? passwordHint,
    bool force = false,
  }) {
    _ensureIdle();
    if (item.isMounted) return _unmount(item, force: force);
    final next = passwordHint == null
        ? item
        : item.copyWith(
            passwordHint: _clean(passwordHint),
            clearPasswordHint: _clean(passwordHint) == null,
          );
    return _protect(next, customPassword: customPassword);
  }

  /// Unlocks an item: decrypts it, opens it as a drive, removes its
  /// permission rule and/or shows it again.
  ///
  /// Without a [credential], the session key is used; if there is none,
  /// throws [ProtectionIssue.passwordRequired] so the UI can ask.
  Future<UnlockOutcome> unlock(
    ProtectedItem item, {
    VaultCredential? credential,
  }) async {
    _ensureIdle();
    if (!item.isProtected) return UnlockOutcome(item, renamed: false);
    return switch (item.method) {
      ProtectionMethod.encrypt => _decrypt(item, credential),
      ProtectionMethod.drive => _mount(item, credential),
      ProtectionMethod.blockAccess ||
      ProtectionMethod.readOnly => _removeRule(item),
      ProtectionMethod.none => _show(item),
    };
  }

  /// Turns a drive item back into a normal folder (decrypted on the disk),
  /// and deletes its vault. It can be locked again later.
  Future<UnlockOutcome> decryptDrive(
    ProtectedItem item, {
    VaultCredential? credential,
  }) async {
    _ensureIdle();
    final vaultPath = item.vaultPath;
    if (!item.isDrive || vaultPath == null || !FsUtils.isDirectory(vaultPath)) {
      throw const ProtectionException(ProtectionIssue.notFound);
    }
    final key =
        credential ??
        sessionCredential(item) ??
        (throw const ProtectionException(ProtectionIssue.passwordRequired));

    state = ActiveOperation(kind: OperationKind.unlocking, itemName: item.name);
    try {
      // The password is checked before an open drive is closed.
      final opened = await _runner.openDriveKey(vaultPath, key);
      final DriveExportResult result;
      try {
        if (opened.derivedKey case final derived?) {
          _cache.put(item.id, derived, opened.openedWith);
        }
        if (item.isMounted) {
          await _drives.unmount(vaultPath);
          await _items.upsert(
            item.copyWith(
              status: ProtectionStatus.protected,
              clearMountPoint: true,
            ),
          );
        }
        final cancel = DriveCancelToken();
        state = state?.copyWith(cancel: cancel.cancel);
        result = await _driveOperations.export(
          operationId: _newId(),
          vaultPath: vaultPath,
          folderPath: item.itemPath,
          journalDir: _journalDir,
          dataKey: opened.dataKey,
          tag: item.id,
          onProgress: (progress) => state = state?.copyWith(progress: progress),
          cancel: cancel,
        );
      } finally {
        opened.dataKey.dispose();
      }
      final updated = (_items.byId(item.id) ?? item).copyWith(
        status: ProtectionStatus.unprotected,
        itemPath: result.folderPath,
        clearVaultPath: true,
        clearMountPoint: true,
        needsPassword: false,
        sizeBytes: result.stats.bytes,
        fileCount: result.stats.files,
        unlockedAt: DateTime.now(),
      );
      await _items.upsert(updated);
      ShellActions.notifyChanged(vaultPath);
      ShellActions.notifyChanged(result.folderPath);
      return UnlockOutcome(
        updated,
        renamed: !p.equals(result.folderPath, item.itemPath),
      );
    } finally {
      state = null;
    }
  }

  Future<UnlockOutcome> _mount(
    ProtectedItem item,
    VaultCredential? credential,
  ) async {
    final vaultPath = item.vaultPath;
    if (vaultPath == null || !FsUtils.isDirectory(vaultPath)) {
      throw const ProtectionException(ProtectionIssue.notFound);
    }
    final key =
        credential ??
        sessionCredential(item) ??
        (throw const ProtectionException(ProtectionIssue.passwordRequired));

    state = ActiveOperation(kind: OperationKind.opening, itemName: item.name);
    try {
      final opened = await _runner.openDriveKey(vaultPath, key);
      if (opened.derivedKey case final derived?) {
        _cache.put(item.id, derived, opened.openedWith);
      }
      final DriveMount mount;
      try {
        mount = await _drives.mount(
          vault: vaultPath,
          key: opened.dataKey,
          label: item.name,
        );
      } finally {
        opened.dataKey.dispose();
      }
      final updated = (_items.byId(item.id) ?? item).copyWith(
        status: ProtectionStatus.unprotected,
        mountPoint: mount.mountPoint,
        unlockedAt: DateTime.now(),
      );
      await _items.upsert(updated);
      return UnlockOutcome(updated, renamed: false);
    } finally {
      state = null;
    }
  }

  Future<ProtectedItem> _unmount(
    ProtectedItem item, {
    required bool force,
  }) async {
    state = ActiveOperation(kind: OperationKind.locking, itemName: item.name);
    try {
      await _drives.unmount(item.vaultPath!, force: force);
      final updated = (_items.byId(item.id) ?? item).copyWith(
        status: ProtectionStatus.protected,
        clearMountPoint: true,
      );
      await _items.upsert(updated);
      return updated;
    } finally {
      state = null;
    }
  }

  /// A drive closed by itself (ejected in Explorer, or the helper stopped).
  Future<void> _driveClosed(String vaultPath) async {
    final item = _items.byPath(vaultPath);
    if (item == null || !item.isMounted) return;
    await _items.upsert(
      item.copyWith(status: ProtectionStatus.protected, clearMountPoint: true),
    );
  }

  DriveOperations get _driveOperations =>
      DriveOperations(crypto: ref.read(cryptoProvider), drives: _drives);

  Future<UnlockOutcome> _decrypt(
    ProtectedItem item,
    VaultCredential? credential,
  ) async {
    final vaultPath = item.vaultPath;
    if (vaultPath == null || !FsUtils.exists(vaultPath)) {
      throw const ProtectionException(ProtectionIssue.notFound);
    }
    final key =
        credential ??
        sessionCredential(item) ??
        (throw const ProtectionException(ProtectionIssue.passwordRequired));

    state = ActiveOperation(kind: OperationKind.unlocking, itemName: item.name);
    try {
      final result = await _track(
        _runner.unlock(
          UnlockRequest(
            operationId: _newId(),
            vaultPath: vaultPath,
            targetPath: item.itemPath,
            journalDir: _journalDir,
            tag: item.id,
          ),
          key,
        ),
      );
      if (result.derivedKey case final derived?) {
        _cache.put(item.id, derived, result.openedWith);
      }
      final updated = item.copyWith(
        status: ProtectionStatus.unprotected,
        itemPath: result.restoredPath,
        clearVaultPath: true,
        needsPassword: false,
        sizeBytes: result.totalBytes,
        fileCount: result.fileCount,
        unlockedAt: DateTime.now(),
      );
      await _items.upsert(updated);
      await _prepareRelock(updated);
      ShellActions.notifyChanged(vaultPath);
      ShellActions.notifyChanged(result.restoredPath);
      return UnlockOutcome(
        updated,
        renamed: !p.equals(result.restoredPath, item.itemPath),
      );
    } finally {
      state = null;
    }
  }

  Future<UnlockOutcome> _removeRule(ProtectedItem item) async {
    if (!FsUtils.exists(item.itemPath)) {
      throw const ProtectionException(ProtectionIssue.notFound);
    }
    state = ActiveOperation(kind: OperationKind.unlocking, itemName: item.name);
    try {
      await _guardRule(() => _rules.remove(item.itemPath));
      // Shown after the rule is gone: the rule also blocks attribute changes.
      if (item.hide) _setHidden(item.itemPath, hidden: false);
      final updated = item.copyWith(
        status: ProtectionStatus.unprotected,
        unlockedAt: DateTime.now(),
      );
      await _items.upsert(updated);
      ShellActions.notifyChanged(item.itemPath);
      return UnlockOutcome(updated, renamed: false);
    } finally {
      state = null;
    }
  }

  Future<UnlockOutcome> _show(ProtectedItem item) async {
    _setHidden(item.itemPath, hidden: false);
    final updated = item.copyWith(
      status: ProtectionStatus.unprotected,
      unlockedAt: DateTime.now(),
    );
    await _items.upsert(updated);
    ShellActions.notifyChanged(item.itemPath);
    return UnlockOutcome(updated, renamed: false);
  }

  /// Unlocks a vault that is not in the list (for example copied from
  /// another PC) and starts managing it.
  Future<UnlockOutcome> unlockUnknownVault(
    String vaultPath,
    VaultCredential credential,
  ) async {
    _ensureIdle();
    final now = DateTime.now();
    final isDrive = DriveVault.isDrivePath(vaultPath);
    if (isDrive) vaultPath = DriveVault.folderOf(vaultPath);
    final name = p.basenameWithoutExtension(vaultPath);
    final placeholder = ProtectedItem(
      id: _newId(),
      name: name,
      kind: ItemKind.folder,
      itemPath: p.join(p.dirname(vaultPath), name),
      vaultPath: vaultPath,
      method: isDrive ? ProtectionMethod.drive : ProtectionMethod.encrypt,
      hide: false,
      passwordMode: PasswordMode.custom,
      status: ProtectionStatus.protected,
      addedAt: now,
      updatedAt: now,
    );
    await _items.upsert(placeholder);
    try {
      final outcome = await unlock(placeholder, credential: credential);
      final keystoreSalt = _session.keystore?.kdf.salt;
      final cached = _cache[placeholder.id];
      final isOurMaster =
          cached != null &&
          cached.slotType == KeySlotType.masterPassword &&
          keystoreSalt != null &&
          listEquals(cached.key.kdf.salt, keystoreSalt);
      final restoredKind = isDrive || FsUtils.isDirectory(outcome.item.itemPath)
          ? ItemKind.folder
          : ItemKind.file;
      final adopted = ProtectedItem(
        id: outcome.item.id,
        name: p.basename(outcome.item.itemPath),
        kind: restoredKind,
        itemPath: outcome.item.itemPath,
        vaultPath: isDrive ? vaultPath : null,
        method: placeholder.method,
        hide: false,
        passwordMode: isOurMaster ? PasswordMode.master : PasswordMode.custom,
        status: ProtectionStatus.unprotected,
        sizeBytes: outcome.item.sizeBytes,
        fileCount: outcome.item.fileCount,
        unlockedAt: outcome.item.unlockedAt,
        mountPoint: outcome.item.mountPoint,
        addedAt: now,
        updatedAt: DateTime.now(),
      );
      await _items.upsert(adopted);
      // Its password mode is known only now.
      await _prepareRelock(adopted);
      return UnlockOutcome(adopted, renamed: outcome.renamed);
    } on Object {
      if (FsUtils.exists(vaultPath)) await _items.remove(placeholder.id);
      rethrow;
    }
  }

  /// Locks every unlocked item that needs no typed password, one after
  /// the other (only those that pass [where], if given).
  ///
  /// Returns the items that stayed unlocked: they need their own
  /// password, a file in them is in use, or another operation was running.
  Future<List<ProtectedItem>> lockAllUnlocked({
    bool Function(ProtectedItem item)? where,
  }) async {
    final left = <ProtectedItem>[];
    for (final listed in [..._items.items]) {
      // The app quit meanwhile (it signed out, or an update closed it).
      if (!ref.mounted) break;
      // The list changes as items are locked: always use the latest copy.
      final item = _items.byId(listed.id);
      if (item == null || item.isProtected || !_items.existsOnDisk(item)) {
        continue;
      }
      if (where != null && !where(item)) continue;
      if (lockRequirement(item) != LockRequirement.none) {
        left.add(item);
        continue;
      }
      try {
        await lockAgain(item);
      } on Object {
        left.add(item);
      }
    }
    return left;
  }

  /// Stops managing an item. Only allowed once it is unlocked (or its
  /// files are gone), so nothing stays encrypted without being listed. A
  /// drive item must be decrypted to a folder first.
  Future<void> remove(ProtectedItem item) async {
    if ((item.isProtected || item.hasVault) &&
        FsUtils.exists(item.currentPath)) {
      throw const ProtectionException(ProtectionIssue.stillProtected);
    }
    _cache.remove(item.id);
    _relock.remove(item.id);
    await _items.remove(item.id);
  }

  // -------------------------------------------------------------------------

  static const int _hiddenBits = FileSystemInfo.hidden | FileSystemInfo.system;

  /// The bits to clear to show [path] again. A folder with a `desktop.ini`
  /// (a custom icon, or a translated name like Windows' own folders) may
  /// need System to use it, so it keeps System: without Hidden it still
  /// shows.
  static int _bitsToShow(String path) =>
      FsUtils.isDirectory(path) && FsUtils.exists(p.join(path, 'desktop.ini'))
      ? FileSystemInfo.hidden
      : _hiddenBits;

  Future<ProtectedItem> _protect(
    ProtectedItem item, {
    String? customPassword,
  }) async {
    if (!FsUtils.exists(item.itemPath)) {
      throw const ProtectionException(ProtectionIssue.notFound);
    }
    state = ActiveOperation(kind: OperationKind.locking, itemName: item.name);
    try {
      final updated = switch (item.method) {
        ProtectionMethod.encrypt => await _lockEncrypted(item, customPassword),
        ProtectionMethod.drive => await _lockDrive(item, customPassword),
        ProtectionMethod.blockAccess ||
        ProtectionMethod.readOnly => await _applyRule(item),
        ProtectionMethod.none => _hide(item),
      };
      await _items.upsert(updated);
      return updated;
    } finally {
      state = null;
    }
  }

  Future<ProtectedItem> _lockEncrypted(
    ProtectedItem item,
    String? customPassword,
  ) async {
    final updated = await _encrypt(item, customPassword);
    if (item.hide) _setHidden(updated.vaultPath!, hidden: true);
    ShellActions.notifyChanged(updated.vaultPath!);
    ShellActions.notifyChanged(item.itemPath);
    return updated;
  }

  Future<ProtectedItem> _applyRule(ProtectedItem item) async {
    final path = item.itemPath;
    if (_rules.check(path) case final problem?) {
      throw ProtectionException(
        ProtectionIssue.accessRuleFailed,
        accessProblem: problem,
      );
    }
    // Saved as locked first: if the app stops halfway, the item still
    // shows as locked, and "Unlock" removes whatever was applied.
    final locked = item.copyWith(status: ProtectionStatus.protected);
    await _items.upsert(locked);
    try {
      // Hidden first, because the rule also blocks attribute changes.
      if (item.hide) _setHidden(path, hidden: true);
      await _guardRule(
        () => _rules.apply(
          path,
          item.method == ProtectionMethod.readOnly
              ? AccessRule.readOnly
              : AccessRule.blockAll,
        ),
      );
    } on Object {
      // Put everything back the way it was. If that fails too, the item
      // stays listed as locked, so "Unlock" can remove what was applied.
      var undone = true;
      try {
        await _rules.remove(path);
      } on Object {
        undone = false;
      }
      if (undone) {
        if (item.hide) {
          FileSystemInfo.updateAttributes(path, remove: _bitsToShow(path));
        }
        await _items.upsert(item);
      }
      rethrow;
    }
    ShellActions.notifyChanged(path);
    return locked;
  }

  ProtectedItem _hide(ProtectedItem item) {
    _setHidden(item.itemPath, hidden: true);
    ShellActions.notifyChanged(item.itemPath);
    return item.copyWith(status: ProtectionStatus.protected);
  }

  void _setHidden(String path, {required bool hidden}) {
    final ok = hidden
        ? FileSystemInfo.updateAttributes(path, add: _hiddenBits)
        : FileSystemInfo.updateAttributes(path, remove: _bitsToShow(path));
    if (!ok) throw const ProtectionException(ProtectionIssue.hideFailed);
  }

  /// Turns [AccessControlException]s into [ProtectionException]s.
  Future<void> _guardRule(Future<void> Function() action) async {
    try {
      await action();
    } on AccessControlException catch (error) {
      throw ProtectionException(
        ProtectionIssue.accessRuleFailed,
        accessProblem: error.problem,
      );
    }
  }

  /// The key slots for a new vault of [item], and a new custom key that
  /// the caller remembers on success or disposes.
  Future<({VaultSlotsSpec slots, DerivedKey? newCustomKey, bool current})>
  _slotsFor(ProtectedItem item, String? customPassword) async {
    final recoveryPublicKey = _session.keystore?.recoveryPublicKey;
    switch (item.passwordMode) {
      case PasswordMode.master:
        final cached = _cache[item.id];
        final masterKey =
            _session.masterKey ??
            (cached?.slotType == KeySlotType.masterPassword
                ? cached!.key
                : throw const ProtectionException(ProtectionIssue.appLocked));
        final currentSalt = _session.keystore?.kdf.salt;
        return (
          slots: VaultSlotsSpec(
            master: masterKey,
            recoveryPublicKey: recoveryPublicKey,
          ),
          newCustomKey: null,
          current:
              currentSalt != null &&
              listEquals(masterKey.kdf.salt, currentSalt),
        );
      case PasswordMode.custom:
        if (customPassword != null) {
          final key = await _runner.deriveKey(
            customPassword,
            ref
                .read(kdfPolicyProvider)
                .withSalt(
                  ref.read(cryptoProvider).randomBytes(KdfParams.saltLength),
                ),
          );
          return (
            slots: VaultSlotsSpec(
              custom: key,
              recoveryPublicKey: recoveryPublicKey,
            ),
            newCustomKey: key,
            current: true,
          );
        }
        if (_cache[item.id] case final cached?
            when cached.slotType == KeySlotType.customPassword) {
          return (
            slots: VaultSlotsSpec(
              custom: cached.key,
              recoveryPublicKey: recoveryPublicKey,
            ),
            newCustomKey: null,
            current: true,
          );
        }
        throw const ProtectionException(ProtectionIssue.passwordRequired);
    }
  }

  /// Makes the keys of [item]'s next vault while a key for it is at hand,
  /// so it locks again later without a password (see [RelockKeys]).
  Future<void> _prepareRelock(ProtectedItem item) async {
    if (item.method != ProtectionMethod.encrypt) return;
    try {
      final spec = await _slotsFor(item, null);
      // A vault for an older master password would need that one.
      if (!spec.current) return;
      final prepared = VaultKeys(ref.read(cryptoProvider)).prepare(spec.slots);
      try {
        _relock.save(item.id, prepared);
      } finally {
        prepared.dispose();
      }
    } on Object {
      // Locking it again asks for a password instead.
    }
  }

  /// Whether a vault with [prepared]'s keys opens with the current master
  /// password (or doesn't use it).
  bool _isCurrent(ProtectedItem item, PreparedVault prepared) {
    if (item.passwordMode != PasswordMode.master) return true;
    final salt = _session.keystore?.kdf.salt;
    return salt != null &&
        prepared.header.slots.any(
          (slot) =>
              slot is PasswordKeySlot &&
              slot.isMaster &&
              listEquals(slot.kdf.salt, salt),
        );
  }

  Future<ProtectedItem> _encrypt(
    ProtectedItem item,
    String? customPassword,
  ) async {
    ({VaultSlotsSpec slots, DerivedKey? newCustomKey, bool current})? spec;
    PreparedVault? prepared;
    try {
      spec = await _slotsFor(item, customPassword);
    } on ProtectionException {
      // No key at hand: the keys made when it was unlocked, if any.
      prepared = customPassword == null ? _relock.read(item.id) : null;
      if (prepared == null) rethrow;
    }
    var newCustomKey = spec?.newCustomKey;
    try {
      final vaultPath = FsUtils.freePath(
        p.join(
          p.dirname(item.itemPath),
          '${p.basename(item.itemPath)}${AppInfo.vaultExtension}',
        ),
      );
      final request = LockRequest(
        operationId: _newId(),
        itemPath: item.itemPath,
        vaultPath: vaultPath,
        journalDir: _journalDir,
        tag: item.id,
      );
      final LockResult result;
      try {
        result = await _track(
          prepared == null
              ? _runner.lock(request, spec!.slots)
              : _runner.lockPrepared(request, prepared),
        );
      } on EngineException catch (error) {
        // Written with once, they can't be used again.
        if (error.keysUsed) _relock.remove(item.id);
        rethrow;
      }
      // Its next unlock makes new ones.
      _relock.remove(item.id);
      if (newCustomKey != null) {
        // Remember it so "Lock again" won't ask for the password twice.
        _cache.put(item.id, newCustomKey, KeySlotType.customPassword);
        newCustomKey = null;
      }
      return item.copyWith(
        status: ProtectionStatus.protected,
        vaultPath: result.vaultPath,
        sizeBytes: result.totalBytes,
        fileCount: result.fileCount,
        needsPassword: !(spec?.current ?? _isCurrent(item, prepared!)),
      );
    } finally {
      newCustomKey?.dispose();
      prepared?.dispose();
    }
  }

  Future<ProtectedItem> _lockDrive(
    ProtectedItem item,
    String? customPassword,
  ) async {
    final spec = await _slotsFor(item, customPassword);
    var newCustomKey = spec.newCustomKey;
    final cancel = DriveCancelToken();
    state = state?.copyWith(cancel: cancel.cancel);
    try {
      final vaultPath = FsUtils.freePath(
        p.join(
          p.dirname(item.itemPath),
          '${p.basename(item.itemPath)}${DriveVault.extension}',
        ),
      );
      final result = await _driveOperations.lock(
        operationId: _newId(),
        folderPath: item.itemPath,
        vaultPath: vaultPath,
        journalDir: _journalDir,
        slots: spec.slots,
        tag: item.id,
        onProgress: (progress) => state = state?.copyWith(progress: progress),
        cancel: cancel,
      );
      if (newCustomKey != null) {
        _cache.put(item.id, newCustomKey, KeySlotType.customPassword);
        newCustomKey = null;
      }
      if (item.hide) _setHidden(result.vaultPath, hidden: true);
      ShellActions.notifyChanged(result.vaultPath);
      ShellActions.notifyChanged(item.itemPath);
      return item.copyWith(
        status: ProtectionStatus.protected,
        vaultPath: result.vaultPath,
        clearMountPoint: true,
        sizeBytes: result.stats.bytes,
        fileCount: result.stats.files,
        needsPassword: !spec.current,
      );
    } finally {
      newCustomKey?.dispose();
    }
  }

  Future<T> _track<T>(EngineJob<T> job) async {
    state = state?.copyWith(cancel: job.cancel);
    final subscription = job.progress.listen(
      (progress) => state = state?.copyWith(progress: progress),
    );
    try {
      return await job.result;
    } finally {
      await subscription.cancel();
    }
  }

  void _ensureIdle() {
    if (state != null) {
      throw const ProtectionException(ProtectionIssue.busy);
    }
  }

  String _newId() => ref
      .read(cryptoProvider)
      .randomBytes(16)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  static String? _clean(String? text) {
    final trimmed = text?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// Convenience for the UI: true for engine errors caused by a wrong key.
bool isWrongPassword(Object error) =>
    error is EngineException && error.code == EngineErrorCode.wrongPassword;
