import 'dart:io';

import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/format/key_slot.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/item_key_cache.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/path_guard.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/application/relock_keys.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

void main() {
  late AppHarness harness;

  SessionController session() =>
      harness.container.read(sessionControllerProvider.notifier);
  ProtectionController protection() =>
      harness.container.read(protectionControllerProvider.notifier);
  ItemsController items() =>
      harness.container.read(itemsControllerProvider.notifier);

  Future<void> ready() async {
    // Wait until the session finished loading the keystore.
    while (harness.container.read(sessionControllerProvider).status ==
        SessionStatus.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await harness.container.read(itemsControllerProvider.future);
  }

  Directory folder(String name) {
    final dir = Directory(harness.userPath(name))..createSync(recursive: true);
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('secret A');
    Directory(p.join(dir.path, 'sub')).createSync();
    File(p.join(dir.path, 'sub', 'b.txt')).writeAsStringSync('secret B');
    return dir;
  }

  setUp(() async {
    harness = await AppHarness.create();
    await ready();
    expect(
      harness.container.read(sessionControllerProvider).status,
      SessionStatus.needsSetup,
    );
    final recoveryKey = await session().setUp(password: 'master-password');
    expect(recoveryKey, matches(RegExp(r'^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')));
    session().finishOnboarding();
  });

  tearDown(() async {
    harness.container.dispose();
    await harness.dispose();
  });

  test(
    'protects with the master password and unlocks with the session',
    () async {
      final dir = folder('Secret');
      final item = await protection().protectNew(
        ProtectRequest(
          path: dir.path,
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      expect(item.status, ProtectionStatus.protected);
      expect(File(item.vaultPath!).existsSync(), isTrue);
      expect(dir.existsSync(), isFalse);
      expect(items().items.single.id, item.id);

      // While the app is unlocked, no password is needed.
      expect(protection().sessionCredential(item), isA<DerivedKeyCredential>());
      final outcome = await protection().unlock(item);
      expect(outcome.renamed, isFalse);
      expect(
        File(p.join(dir.path, 'sub', 'b.txt')).readAsStringSync(),
        'secret B',
      );
      expect(items().items.single.status, ProtectionStatus.unprotected);

      final again = await protection().lockAgain(items().items.single);
      expect(again.isEncryptedNow, isTrue);
      expect(dir.existsSync(), isFalse);
    },
  );

  test(
    'custom password items need their password after the app locks',
    () async {
      final dir = folder('Shared');
      final item = await protection().protectNew(
        ProtectRequest(
          path: dir.path,
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: PasswordMode.custom,
          customPassword: 'item-password',
          passwordHint: 'the usual',
        ),
      );
      expect(item.passwordHint, 'the usual');
      // Remembered right after locking…
      expect(protection().sessionCredential(item), isNotNull);

      session().lock();
      expect(harness.container.read(itemKeyCacheProvider)[item.id], isNull);
      expect(protection().sessionCredential(item), isNull);
      await expectLater(
        protection().unlock(item),
        throwsA(
          isA<ProtectionException>().having(
            (e) => e.issue,
            'issue',
            ProtectionIssue.passwordRequired,
          ),
        ),
      );
      await expectLater(
        protection().unlock(
          item,
          credential: const PasswordCredential('master-password'),
        ),
        throwsA(
          isA<EngineException>().having(
            (e) => e.code,
            'code',
            EngineErrorCode.wrongPassword,
          ),
        ),
      );
      final outcome = await protection().unlock(
        item,
        credential: const PasswordCredential('item-password'),
      );
      expect(outcome.item.status, ProtectionStatus.unprotected);
      // The typed password is remembered for "Lock again".
      expect(
        harness.container.read(itemKeyCacheProvider)[item.id]?.slotType,
        KeySlotType.customPassword,
      );
      expect(protection().lockRequirement(outcome.item), LockRequirement.none);
    },
  );

  test('changing the master password re-keys vaults', () async {
    final item = await protection().protectNew(
      ProtectRequest(
        path: folder('Secret').path,
        method: ProtectionMethod.encrypt,
        hide: false,
        passwordMode: PasswordMode.master,
      ),
    );
    expect(await session().changePassword(newPassword: 'new-master'), 0);

    session().lock();
    expect(await session().unlock('master-password'), isFalse);
    expect(await session().unlock('new-master'), isTrue);
    final outcome = await protection().unlock(items().byId(item.id)!);
    expect(outcome.item.isProtected, isFalse);
  });

  group('an unlocked item', () {
    Future<ProtectedItem> unlocked({
      PasswordMode mode = PasswordMode.master,
    }) async {
      final item = await protection().protectNew(
        ProtectRequest(
          path: folder('Secret').path,
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: mode,
          customPassword: mode == PasswordMode.custom ? 'item-password' : null,
        ),
      );
      return (await protection().unlock(item)).item;
    }

    RelockKeys relockKeys() => harness.container.read(relockKeysProvider);

    test('locks again without a password after the app locked', () async {
      final item = await unlocked();
      expect(relockKeys().has(item.id), isTrue);

      session().lock();
      expect(protection().lockRequirement(item), LockRequirement.none);
      final locked = await protection().lockAgain(item);
      expect(locked.isProtected, isTrue);
      expect(locked.needsPassword, isFalse);
      expect(relockKeys().has(item.id), isFalse, reason: 'used once');

      final outcome = await protection().unlock(
        locked,
        credential: const PasswordCredential('master-password'),
      );
      expect(outcome.item.isProtected, isFalse);
    });

    test('with its own password, too', () async {
      final item = await unlocked(mode: PasswordMode.custom);
      session().lock();
      expect(protection().lockRequirement(item), LockRequirement.none);
      final locked = await protection().lockAgain(item);
      await expectLater(
        protection().unlock(
          locked,
          credential: const PasswordCredential('master-password'),
        ),
        throwsA(isA<EngineException>()),
      );
      final outcome = await protection().unlock(
        locked,
        credential: const PasswordCredential('item-password'),
      );
      expect(outcome.item.isProtected, isFalse);
    });

    test('follows a new master password', () async {
      final item = await unlocked();
      expect(await session().changePassword(newPassword: 'new-master'), 0);

      session().lock();
      final locked = await protection().lockAgain(item);
      expect(locked.needsPassword, isFalse);
      await expectLater(
        protection().unlock(
          locked,
          credential: const PasswordCredential('master-password'),
        ),
        throwsA(isA<EngineException>()),
      );
      final outcome = await protection().unlock(
        locked,
        credential: const PasswordCredential('new-master'),
      );
      expect(outcome.item.isProtected, isFalse);
    });

    test('removing it drops its keys', () async {
      final item = await unlocked();
      await protection().remove(item);
      expect(relockKeys().has(item.id), isFalse);
    });
  });

  test('the recovery key resets the master password', () async {
    // A fresh setup, so the recovery key is known to the test.
    harness.container.dispose();
    await harness.dispose();
    harness = await AppHarness.create();
    await ready();
    final recoveryKey = await session().setUp(password: 'forgotten');
    session().finishOnboarding();
    final item = await protection().protectNew(
      ProtectRequest(
        path: folder('Secret').path,
        method: ProtectionMethod.encrypt,
        hide: false,
        passwordMode: PasswordMode.master,
      ),
    );
    session().lock();

    await expectLater(
      session().resetWithRecoveryKey(
        recoveryKey: 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA',
        newPassword: 'x-new-password',
      ),
      throwsA(isA<InvalidRecoveryKeyException>()),
    );
    final failed = await session().resetWithRecoveryKey(
      recoveryKey: recoveryKey.toLowerCase(),
      newPassword: 'x-new-password',
    );
    expect(failed, 0);
    expect(
      harness.container.read(sessionControllerProvider).isUnlocked,
      isTrue,
    );
    final outcome = await protection().unlock(items().byId(item.id)!);
    expect(outcome.item.isProtected, isFalse);
  });

  test('hide-only protection and removal rules', () async {
    final dir = folder('Games');
    final item = await protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: ProtectionMethod.none,
        hide: true,
        passwordMode: PasswordMode.master,
      ),
    );
    expect(item.isProtected, isTrue);
    expect(dir.existsSync(), isTrue);
    await expectLater(
      protection().remove(item),
      throwsA(isA<ProtectionException>()),
    );
    final shown = await protection().unlock(item);
    await protection().remove(shown.item);
    expect(items().items, isEmpty);
  });

  test('refuses paths the guard rejects and leaves nothing behind', () async {
    final dir = folder('Secret');
    await protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: ProtectionMethod.none,
        hide: true,
        passwordMode: PasswordMode.master,
      ),
    );
    await expectLater(
      protection().protectNew(
        ProtectRequest(
          path: p.join(dir.path, 'sub'),
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      ),
      throwsA(
        isA<ProtectionException>().having(
          (e) => e.pathProblem,
          'problem',
          PathProblem.insideProtectedItem,
        ),
      ),
    );
    expect(items().items, hasLength(1));
  });

  test('block access adds a permission rule and unlock removes it', () async {
    final dir = folder('Big project');
    final item = await protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: ProtectionMethod.blockAccess,
        hide: true,
        passwordMode: PasswordMode.master,
      ),
    );
    expect(item.isProtected, isTrue);
    expect(dir.existsSync(), isTrue, reason: 'the folder stays in place');
    expect(harness.accessRules.ruleOn(dir.path), AccessRule.blockAll);
    expect(protection().lockRequirement(item), LockRequirement.none);

    final outcome = await protection().unlock(item);
    expect(outcome.item.status, ProtectionStatus.unprotected);
    expect(outcome.item.unlockedAt, isNotNull);
    expect(harness.accessRules.ruleOn(dir.path), isNull);

    final again = await protection().lockAgain(outcome.item);
    expect(again.isProtected, isTrue);
    expect(again.unlockedAt, isNull);
    expect(harness.accessRules.ruleOn(dir.path), AccessRule.blockAll);
  });

  test('read-only uses the read-only rule', () async {
    final dir = folder('Photos');
    await protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: ProtectionMethod.readOnly,
        hide: false,
        passwordMode: PasswordMode.master,
      ),
    );
    expect(harness.accessRules.ruleOn(dir.path), AccessRule.readOnly);
    expect(items().items.single.method, ProtectionMethod.readOnly);
  });

  test('refused or failed rules leave nothing behind', () async {
    final dir = folder('Shared');
    harness.accessRules.problem = AccessProblem.notOwner;
    await expectLater(
      protection().protectNew(
        ProtectRequest(
          path: dir.path,
          method: ProtectionMethod.blockAccess,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      ),
      throwsA(
        isA<ProtectionException>().having(
          (e) => e.accessProblem,
          'accessProblem',
          AccessProblem.notOwner,
        ),
      ),
    );
    expect(items().items, isEmpty);

    harness.accessRules
      ..problem = null
      ..failApply = true;
    await expectLater(
      protection().protectNew(
        ProtectRequest(
          path: dir.path,
          method: ProtectionMethod.readOnly,
          hide: true,
          passwordMode: PasswordMode.master,
        ),
      ),
      throwsA(
        isA<ProtectionException>().having(
          (e) => e.issue,
          'issue',
          ProtectionIssue.accessRuleFailed,
        ),
      ),
    );
    expect(items().items, isEmpty);
    expect(harness.accessRules.rules, isEmpty);
  });
}
