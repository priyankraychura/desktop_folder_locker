import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../engine/engine_runner.dart';
import '../../../engine/vault/vault_keys.dart';
import '../../items/application/items_controller.dart';
import '../../items/application/protection_controller.dart';
import '../../items/application/relock_keys.dart';
import '../../items/domain/protected_item.dart';
import 'auth_service.dart';
import 'session_controller.dart';

final recoveryKeyServiceProvider = Provider<RecoveryKeyService>(
  RecoveryKeyService.new,
);

/// Replaces the recovery key, and keeps every vault sealed to the current
/// one.
///
/// The new key is saved first, so from then on only it can reset the
/// master password. Vaults are then switched over one by one (each switch
/// is crash-safe). A vault the app can't open right now (it has its own
/// password, or its drive is missing) keeps the old key until it can be
/// updated: after the next unlock, or when the item is locked again.
class RecoveryKeyService {
  RecoveryKeyService(this._ref);

  final Ref _ref;
  bool _updating = false;

  AuthService get _auth => _ref.read(authServiceProvider);

  /// A new key to show the user. Nothing changes until [activate].
  RecoveryKeyDraft draft() => _auth.newRecoveryKey();

  /// Makes [draft] the recovery key and updates the vaults.
  ///
  /// Returns the items that still open only with the old recovery key.
  Future<List<ProtectedItem>> activate(RecoveryKeyDraft draft) async {
    final session = _ref.read(sessionControllerProvider);
    final keystore = session.keystore;
    if (keystore == null || !session.isUnlocked) {
      throw StateError('The app is locked');
    }
    final saved = await _auth.saveRecoveryKey(keystore, draft);
    _ref.read(sessionControllerProvider.notifier).updateKeystore(saved);
    return updateVaults();
  }

  /// Runs [updateVaults] if some vaults may still use an older key.
  Future<void> updateVaultsIfPending() async {
    final keystore = _ref.read(sessionControllerProvider).keystore;
    if (keystore?.recoveryUpdatePending ?? false) await updateVaults();
  }

  /// Seals every vault that still uses an older recovery key to the
  /// current one, when the app can open it without asking.
  ///
  /// Returns the items that still open only with an older key.
  Future<List<ProtectedItem>> updateVaults() async {
    final session = _ref.read(sessionControllerProvider);
    final keystore = session.keystore;
    if (_updating || keystore == null || !session.isUnlocked) return const [];
    _updating = true;
    try {
      // Unlocked items lock again for the current recovery key.
      _ref
          .read(relockKeysProvider)
          .update(recoveryPublicKey: keystore.recoveryPublicKey);
      final protection = _ref.read(protectionControllerProvider.notifier);
      final vaults = [
        for (final item in _ref.read(itemsControllerProvider.notifier).items)
          if (item.hasVault) item,
      ];
      final outcomes = await _ref
          .read(engineRunnerProvider)
          .resealRecovery(
            targets: [
              for (final item in vaults)
                ResealTarget(item.vaultPath!, switch (protection
                    .sessionCredential(item)) {
                  final DerivedKeyCredential key => key,
                  _ => null,
                }),
            ],
            recoveryPublicKey: keystore.recoveryPublicKey,
          );
      final stale = [
        for (var i = 0; i < vaults.length; i++)
          if (!outcomes[i].isCurrent) vaults[i],
      ];

      // Only clear the flag if the key didn't change in the meantime.
      final latest = _ref.read(sessionControllerProvider).keystore;
      if (latest != null &&
          listEquals(latest.recoveryPublicKey, keystore.recoveryPublicKey)) {
        final updated = await _auth.setRecoveryUpdatePending(
          latest,
          pending: stale.isNotEmpty,
        );
        _ref.read(sessionControllerProvider.notifier).updateKeystore(updated);
      }
      return stale;
    } finally {
      _updating = false;
    }
  }
}
