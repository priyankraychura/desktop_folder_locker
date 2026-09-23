import 'dart:io';

import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:desktop_folder_locker/features/auth/application/auth_service.dart';
import 'package:desktop_folder_locker/features/auth/application/recovery_key_service.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/item_key_cache.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

void main() {
  late AppHarness harness;
  late String firstKey;

  SessionController session() =>
      harness.container.read(sessionControllerProvider.notifier);
  SessionState sessionState() =>
      harness.container.read(sessionControllerProvider);
  ProtectionController protection() =>
      harness.container.read(protectionControllerProvider.notifier);
  ItemsController items() =>
      harness.container.read(itemsControllerProvider.notifier);

  Future<ProtectedItem> encrypted(String name, PasswordMode mode) {
    final dir = Directory(harness.userPath(name))..createSync(recursive: true);
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('secret');
    return protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: ProtectionMethod.encrypt,
        hide: false,
        passwordMode: mode,
        customPassword: mode == PasswordMode.custom ? 'item-password' : null,
      ),
    );
  }

  setUp(() async {
    harness = await AppHarness.create();
    while (sessionState().status == SessionStatus.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await harness.container.read(itemsControllerProvider.future);
    firstKey = await session().setUp(password: 'master-password');
    session().finishOnboarding();
  });

  tearDown(() async {
    harness.container.dispose();
    await harness.dispose();
  });

  test('a new recovery key replaces the old one', () async {
    final taxes = await encrypted('Taxes', PasswordMode.master);
    final shared = await encrypted('Shared', PasswordMode.custom);
    // Its own password is not remembered, as after the app was locked.
    harness.container.read(itemKeyCacheProvider).remove(shared.id);

    final service = harness.container.read(recoveryKeyServiceProvider);
    final draft = service.draft();
    expect(draft.text, isNot(firstKey));
    final stale = await service.activate(draft);

    expect(stale.map((item) => item.id), [shared.id]);
    expect(sessionState().keystore!.recoveryUpdatePending, isTrue);

    // Only the new key can reset the master password now.
    session().lock();
    await expectLater(
      session().resetWithRecoveryKey(
        recoveryKey: firstKey,
        newPassword: 'another-password',
      ),
      throwsA(isA<InvalidRecoveryKeyException>()),
    );
    final failed = await session().resetWithRecoveryKey(
      recoveryKey: draft.text,
      newPassword: 'new-master-password',
    );
    expect(failed, 0, reason: 'the master vault opens with the new key');
    final opened = await protection().unlock(items().byId(taxes.id)!);
    expect(opened.item.isProtected, isFalse);

    // The item with its own password switches once it is locked again.
    final unlocked = await protection().unlock(
      items().byId(shared.id)!,
      credential: const PasswordCredential('item-password'),
    );
    await protection().lockAgain(unlocked.item);
    expect(await service.updateVaults(), isEmpty);
    expect(sessionState().keystore!.recoveryUpdatePending, isFalse);
  });

  test('pending updates are finished after the next unlock', () async {
    final taxes = await encrypted('Taxes', PasswordMode.master);
    final service = harness.container.read(recoveryKeyServiceProvider);
    final draft = service.draft();

    // As if the app stopped right after saving the new key.
    final keystore = sessionState().keystore!;
    final saved = await harness.container
        .read(authServiceProvider)
        .saveRecoveryKey(keystore, draft);
    session().updateKeystore(saved);
    expect(sessionState().keystore!.recoveryUpdatePending, isTrue);

    await service.updateVaultsIfPending();
    expect(sessionState().keystore!.recoveryUpdatePending, isFalse);

    // The vault now opens with the new key.
    session().lock();
    await session().resetWithRecoveryKey(
      recoveryKey: draft.text,
      newPassword: 'new-master-password',
    );
    final opened = await protection().unlock(items().byId(taxes.id)!);
    expect(opened.item.isProtected, isFalse);
  });
}
