import 'dart:io';

import 'package:desktop_folder_locker/features/auth/application/app_locker.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/item_key_cache.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/application/unlocked_items_watcher.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

void main() {
  late AppHarness harness;

  ProtectionController protection() =>
      harness.container.read(protectionControllerProvider.notifier);
  ItemsController items() =>
      harness.container.read(itemsControllerProvider.notifier);

  Future<void> start(AppSettings settings) async {
    harness = await AppHarness.create(settings: settings);
    while (harness.container.read(sessionControllerProvider).status ==
        SessionStatus.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await harness.container.read(itemsControllerProvider.future);
    await harness.container
        .read(sessionControllerProvider.notifier)
        .setUp(password: 'master-password');
    harness.container
        .read(sessionControllerProvider.notifier)
        .finishOnboarding();
  }

  /// Protects a new folder with [method] and unlocks it again.
  Future<ProtectedItem> unlockedItem(
    String name, {
    ProtectionMethod method = ProtectionMethod.blockAccess,
    PasswordMode mode = PasswordMode.master,
  }) async {
    final dir = Directory(harness.userPath(name))..createSync(recursive: true);
    File(p.join(dir.path, 'a.txt')).writeAsStringSync('secret');
    final item = await protection().protectNew(
      ProtectRequest(
        path: dir.path,
        method: method,
        hide: false,
        passwordMode: mode,
        customPassword: mode == PasswordMode.custom ? 'item-password' : null,
      ),
    );
    return (await protection().unlock(item)).item;
  }

  tearDown(() async {
    harness.container.dispose();
    await harness.dispose();
  });

  test(
    'reminds once per unlock, then locks again after the set time',
    () async {
      await start(const AppSettings(relockAfterMinutes: 60));
      final item = await unlockedItem('Taxes');
      final watcher = harness.container.read(unlockedItemsWatcherProvider);
      final reminders = <List<ProtectedItem>>[];
      final subscription = watcher.reminders.listen(reminders.add);
      addTearDown(subscription.cancel);
      final unlockedAt = item.unlockedAt!;

      Future<void> checkAt(int minutes) async {
        await watcher.check(now: unlockedAt.add(Duration(minutes: minutes)));
        await Future<void>.delayed(Duration.zero);
      }

      await checkAt(10);
      expect(reminders, isEmpty);
      await checkAt(31);
      expect(reminders.single.single.id, item.id);
      await checkAt(45);
      expect(reminders, hasLength(1), reason: 'only once per unlock');

      await checkAt(61);
      expect(items().byId(item.id)!.isProtected, isTrue);
      expect(harness.accessRules.ruleOn(item.itemPath), AccessRule.blockAll);
    },
  );

  test('nothing happens when both options are off', () async {
    await start(const AppSettings(remindAfterMinutes: 0));
    final item = await unlockedItem('Photos');
    final watcher = harness.container.read(unlockedItemsWatcherProvider);
    final reminders = <List<ProtectedItem>>[];
    final subscription = watcher.reminders.listen(reminders.add);
    addTearDown(subscription.cancel);

    await watcher.check(now: item.unlockedAt!.add(const Duration(days: 1)));
    await Future<void>.delayed(Duration.zero);
    expect(reminders, isEmpty);
    expect(items().byId(item.id)!.isProtected, isFalse);
  });

  test('locking the app can lock unlocked items first', () async {
    await start(const AppSettings(lockItemsWithApp: true));
    final blocked = await unlockedItem('Projects');
    final encrypted = await unlockedItem(
      'Contracts',
      method: ProtectionMethod.encrypt,
    );
    final shared = await unlockedItem(
      'Shared',
      method: ProtectionMethod.encrypt,
      mode: PasswordMode.custom,
    );
    // Its own password is no longer remembered, so it can't be locked
    // without asking.
    harness.container.read(itemKeyCacheProvider).remove(shared.id);

    final left = await harness.container.read(appLockerProvider).lockApp();

    expect(left.map((item) => item.id), [shared.id]);
    expect(items().byId(blocked.id)!.isProtected, isTrue);
    expect(items().byId(encrypted.id)!.isEncryptedNow, isTrue);
    expect(items().byId(shared.id)!.isProtected, isFalse);
    expect(
      harness.container.read(sessionControllerProvider).isUnlocked,
      isFalse,
    );
  });

  test('without that option, locking the app leaves items alone', () async {
    await start(const AppSettings());
    final item = await unlockedItem('Music');

    final left = await harness.container.read(appLockerProvider).lockApp();

    expect(left, isEmpty);
    expect(items().byId(item.id)!.isProtected, isFalse);
    expect(
      harness.container.read(sessionControllerProvider).isUnlocked,
      isFalse,
    );
  });
}
