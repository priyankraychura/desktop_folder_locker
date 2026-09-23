import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/crypto/recovery_key.dart';
import '../../../engine/format/key_slot.dart';
import '../../../engine/vault/vault_keys.dart';
import '../../items/application/item_key_cache.dart';
import '../../items/application/items_controller.dart';
import '../domain/keystore.dart';
import 'auth_service.dart';

enum SessionStatus {
  loading,

  /// No master password yet.
  needsSetup,

  /// Master password created; the recovery key is being shown.
  onboarding,
  locked,
  unlocked,
}

@immutable
class SessionState {
  const SessionState({required this.status, this.keystore, this.masterKey});

  final SessionStatus status;
  final Keystore? keystore;

  /// The master key while the app is unlocked. Lives in libsodium's
  /// protected memory and is wiped when the app locks.
  final DerivedKey? masterKey;

  bool get isUnlocked => status == SessionStatus.unlocked && masterKey != null;
}

/// Thrown when a recovery key is invalid or belongs to another setup.
class InvalidRecoveryKeyException implements Exception {
  const InvalidRecoveryKeyException();
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Owns the master password session: setup, unlock, lock, change, reset.
class SessionController extends Notifier<SessionState> {
  AuthService get _auth => ref.read(authServiceProvider);

  /// Mirrors `state.masterKey`, so it can be wiped on dispose (Riverpod
  /// doesn't allow reading `state` there).
  DerivedKey? _key;

  @override
  set state(SessionState value) {
    _key = value.masterKey;
    super.state = value;
  }

  @override
  SessionState build() {
    ref.onDispose(() => _key?.dispose());
    unawaited(_load());
    return const SessionState(status: SessionStatus.loading);
  }

  Future<void> _load() async {
    final keystore = await _auth.load();
    state = SessionState(
      status: keystore == null
          ? SessionStatus.needsSetup
          : SessionStatus.locked,
      keystore: keystore,
    );
  }

  /// Creates the master password. Returns the recovery key to show once.
  ///
  /// The session stays in [SessionStatus.onboarding] until
  /// [finishOnboarding], so the recovery key screen isn't skipped.
  Future<String> setUp({required String password, String? hint}) async {
    final setup = await _auth.setUp(password: password, hint: hint);
    state = SessionState(
      status: SessionStatus.onboarding,
      keystore: setup.keystore,
      masterKey: setup.masterKey,
    );
    return setup.recoveryKey;
  }

  void finishOnboarding() {
    final keystore = state.keystore;
    final key = state.masterKey;
    if (state.status != SessionStatus.onboarding ||
        keystore == null ||
        key == null) {
      return;
    }
    _setUnlocked(keystore, key);
  }

  /// Returns `false` if the password is wrong.
  Future<bool> unlock(String password) async {
    final keystore = state.keystore;
    if (keystore == null) return false;
    final key = await _auth.unlock(keystore, password);
    if (key == null) return false;
    _setUnlocked(keystore, key);
    return true;
  }

  /// Checks [password] without changing the session.
  Future<bool> verifyPassword(String password) async {
    final keystore = state.keystore;
    if (keystore == null) return false;
    final key = await _auth.unlock(keystore, password);
    key?.dispose();
    return key != null;
  }

  /// Replaces the stored keystore, for example after a new recovery key
  /// was saved. Keeps the session as it is.
  void updateKeystore(Keystore keystore) => state = SessionState(
    status: state.status,
    keystore: keystore,
    masterKey: state.masterKey,
  );

  /// Locks the app and wipes every key from memory.
  void lock() {
    if (state.status != SessionStatus.unlocked) return;
    final key = state.masterKey;
    state = SessionState(
      status: SessionStatus.locked,
      keystore: state.keystore,
    );
    key?.dispose();
    ref.read(itemKeyCacheProvider).clear();
  }

  /// Changes the master password (the app must be unlocked).
  ///
  /// Returns how many vaults could not be updated.
  Future<int> changePassword({
    required String newPassword,
    String? hint,
  }) async {
    final masterKey = state.masterKey;
    if (masterKey == null) throw StateError('The app is locked');
    return _replacePassword(
      credential: DerivedKeyCredential(masterKey, KeySlotType.masterPassword),
      newPassword: newPassword,
      hint: hint,
    );
  }

  /// Resets a forgotten master password with the recovery key.
  ///
  /// Throws [InvalidRecoveryKeyException] if the key is not valid.
  Future<int> resetWithRecoveryKey({
    required String recoveryKey,
    required String newPassword,
    String? hint,
  }) async {
    final keystore = state.keystore;
    final parsed = RecoveryKey.tryParse(recoveryKey);
    if (keystore == null ||
        parsed == null ||
        !_auth.matchesRecoveryKey(keystore, parsed)) {
      throw const InvalidRecoveryKeyException();
    }
    return _replacePassword(
      credential: RecoveryCredential(parsed),
      newPassword: newPassword,
      hint: hint,
    );
  }

  Future<int> _replacePassword({
    required VaultCredential credential,
    required String newPassword,
    String? hint,
  }) async {
    final items = ref.read(itemsControllerProvider.notifier);
    final vaults = [
      for (final item in items.masterPasswordVaults()) item.vaultPath!,
    ];
    final change = await _auth.changePassword(
      keystore: state.keystore!,
      credential: credential,
      newPassword: newPassword,
      vaultPaths: vaults,
      hint: hint,
    );
    _setUnlocked(change.keystore, change.masterKey);

    final failed = {
      for (final outcome in change.failedVaults) outcome.vaultPath,
    };
    await items.setNeedsPassword(failed, true);
    await items.setNeedsPassword(vaults.toSet().difference(failed), false);
    return failed.length;
  }

  void _setUnlocked(Keystore keystore, DerivedKey masterKey) {
    final previous = state.masterKey;
    state = SessionState(
      status: SessionStatus.unlocked,
      keystore: keystore,
      masterKey: masterKey,
    );
    if (!identical(previous, masterKey)) previous?.dispose();
  }
}
