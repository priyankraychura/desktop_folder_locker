import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_info.dart';
import '../../../core/di/core_providers.dart';
import '../../../engine/crypto/kdf_params.dart';
import '../../../engine/engine_exception.dart';
import '../../../engine/engine_runner.dart';
import '../../../engine/format/key_slot.dart';
import '../../../engine/operations/lock_operation.dart';
import '../../../engine/operations/operation_progress.dart';
import '../../../engine/operations/unlock_operation.dart';
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

enum OperationKind { locking, unlocking }

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
  ActiveOperation? build() => null;

  ItemsController get _items => ref.read(itemsControllerProvider.notifier);
  ItemKeyCache get _cache => ref.read(itemKeyCacheProvider);
  SessionState get _session => ref.read(sessionControllerProvider);
  EngineRunner get _runner => ref.read(engineRunnerProvider);
  String get _journalDir => ref.read(appPathsProvider).journalDir;
  AccessRules get _rules => ref.read(accessRulesProvider);

  PathGuard get _guard => PathGuard(
    appDataDir: ref.read(appPathsProvider).root,
    executableDir: p.dirname(ref.read(executablePathProvider)),
    environment: ref.read(environmentProvider),
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

  LockRequirement lockRequirement(ProtectedItem item) {
    if (!item.encrypt) return LockRequirement.none;
    final cached = _cache[item.id]?.slotType;
    return switch (item.passwordMode) {
      PasswordMode.master =>
        _session.isUnlocked || cached == KeySlotType.masterPassword
            ? LockRequirement.none
            : LockRequirement.appUnlock,
      PasswordMode.custom =>
        cached == KeySlotType.customPassword
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
    if (request.method == ProtectionMethod.encrypt &&
        request.passwordMode == PasswordMode.master &&
        !_session.isUnlocked) {
      throw const ProtectionException(ProtectionIssue.appLocked);
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

  /// Applies an item's protection again after it was unlocked.
  Future<ProtectedItem> lockAgain(
    ProtectedItem item, {
    String? customPassword,
    String? passwordHint,
  }) {
    _ensureIdle();
    final next = passwordHint == null
        ? item
        : item.copyWith(
            passwordHint: _clean(passwordHint),
            clearPasswordHint: _clean(passwordHint) == null,
          );
    return _protect(next, customPassword: customPassword);
  }

  /// Unlocks an item: decrypts it, removes its permission rule and/or
  /// shows it again.
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
      ProtectionMethod.blockAccess ||
      ProtectionMethod.readOnly => _removeRule(item),
      ProtectionMethod.none => _show(item),
    };
  }

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
    final name = p.basenameWithoutExtension(vaultPath);
    final placeholder = ProtectedItem(
      id: _newId(),
      name: name,
      kind: ItemKind.folder,
      itemPath: p.join(p.dirname(vaultPath), name),
      vaultPath: vaultPath,
      method: ProtectionMethod.encrypt,
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
      final restoredKind = FsUtils.isDirectory(outcome.item.itemPath)
          ? ItemKind.folder
          : ItemKind.file;
      final adopted = ProtectedItem(
        id: outcome.item.id,
        name: p.basename(outcome.item.itemPath),
        kind: restoredKind,
        itemPath: outcome.item.itemPath,
        method: ProtectionMethod.encrypt,
        hide: false,
        passwordMode: isOurMaster ? PasswordMode.master : PasswordMode.custom,
        status: ProtectionStatus.unprotected,
        sizeBytes: outcome.item.sizeBytes,
        fileCount: outcome.item.fileCount,
        unlockedAt: outcome.item.unlockedAt,
        addedAt: now,
        updatedAt: DateTime.now(),
      );
      await _items.upsert(adopted);
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
  /// files are gone), so nothing stays encrypted without being listed.
  Future<void> remove(ProtectedItem item) async {
    if (item.isProtected && FsUtils.exists(item.currentPath)) {
      throw const ProtectionException(ProtectionIssue.stillProtected);
    }
    _cache.remove(item.id);
    await _items.remove(item.id);
  }

  // -------------------------------------------------------------------------

  static const int _hiddenBits = FileSystemInfo.hidden | FileSystemInfo.system;

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
          FileSystemInfo.updateAttributes(path, remove: _hiddenBits);
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
        : FileSystemInfo.updateAttributes(path, remove: _hiddenBits);
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

  Future<ProtectedItem> _encrypt(
    ProtectedItem item,
    String? customPassword,
  ) async {
    final recoveryPublicKey = _session.keystore?.recoveryPublicKey;
    DerivedKey? newCustomKey;
    final VaultSlotsSpec slots;
    var usesCurrentMaster = true;

    switch (item.passwordMode) {
      case PasswordMode.master:
        final cached = _cache[item.id];
        final masterKey =
            _session.masterKey ??
            (cached?.slotType == KeySlotType.masterPassword
                ? cached!.key
                : throw const ProtectionException(ProtectionIssue.appLocked));
        final currentSalt = _session.keystore?.kdf.salt;
        usesCurrentMaster =
            currentSalt != null && listEquals(masterKey.kdf.salt, currentSalt);
        slots = VaultSlotsSpec(
          master: masterKey,
          recoveryPublicKey: recoveryPublicKey,
        );
      case PasswordMode.custom:
        final DerivedKey customKey;
        if (customPassword != null) {
          newCustomKey = await _runner.deriveKey(
            customPassword,
            ref
                .read(kdfPolicyProvider)
                .withSalt(
                  ref.read(cryptoProvider).randomBytes(KdfParams.saltLength),
                ),
          );
          customKey = newCustomKey;
        } else if (_cache[item.id] case final cached?
            when cached.slotType == KeySlotType.customPassword) {
          customKey = cached.key;
        } else {
          throw const ProtectionException(ProtectionIssue.passwordRequired);
        }
        slots = VaultSlotsSpec(
          custom: customKey,
          recoveryPublicKey: recoveryPublicKey,
        );
    }

    try {
      final vaultPath = FsUtils.freePath(
        p.join(
          p.dirname(item.itemPath),
          '${p.basename(item.itemPath)}${AppInfo.vaultExtension}',
        ),
      );
      final result = await _track(
        _runner.lock(
          LockRequest(
            operationId: _newId(),
            itemPath: item.itemPath,
            vaultPath: vaultPath,
            journalDir: _journalDir,
            tag: item.id,
          ),
          slots,
        ),
      );
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
        needsPassword: !usesCurrentMaster,
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
