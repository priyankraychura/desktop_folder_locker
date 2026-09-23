import 'dart:io';

import 'package:desktop_folder_locker/core/di/core_providers.dart';
import 'package:desktop_folder_locker/engine/crypto/recovery_key.dart';
import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/format/vault_header.dart';
import 'package:desktop_folder_locker/engine/vault/drive_vault.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
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
  late String recoveryKey;

  SessionController session() =>
      harness.container.read(sessionControllerProvider.notifier);
  ProtectionController protection() =>
      harness.container.read(protectionControllerProvider.notifier);
  ItemsController items() =>
      harness.container.read(itemsControllerProvider.notifier);

  Future<void> ready() async {
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

  Future<ProtectedItem> lockAsDrive(
    String name, {
    PasswordMode mode = PasswordMode.master,
    String? password,
  }) => protection().protectNew(
    ProtectRequest(
      path: folder(name).path,
      method: ProtectionMethod.drive,
      hide: false,
      passwordMode: mode,
      customPassword: password,
    ),
  );

  setUp(() async {
    harness = await AppHarness.create();
    await ready();
    recoveryKey = await session().setUp(password: 'master-password');
    session().finishOnboarding();
  });

  tearDown(() async {
    harness.container.dispose();
    await harness.dispose();
  });

  test('a folder becomes a drive vault next to it', () async {
    final item = await lockAsDrive('Taxes');

    expect(item.isProtected, isTrue);
    expect(item.isDrive, isTrue);
    expect(item.vaultPath, harness.userPath('Taxes${DriveVault.extension}'));
    expect(item.fileCount, 2);
    expect(Directory(item.itemPath).existsSync(), isFalse);
    final header = File(p.join(item.vaultPath!, 'vault.flk'));
    expect(header.lengthSync(), VaultHeader.blockSize);
    expect(
      File(p.join(item.vaultPath!, 'data', 'sub', 'b.txt')).existsSync(),
      isTrue,
      reason: 'the fake helper copies the files as they are',
    );
    // Nothing is left behind.
    expect(Directory(harness.userPath('')).listSync(), hasLength(1));
    expect(
      Directory(harness.container.read(appPathsProvider).journalDir).listSync(),
      isEmpty,
    );
  });

  test('opens as a drive and locks again without a password', () async {
    final item = await lockAsDrive('Photos');

    final opened = await protection().unlock(item);
    expect(opened.item.isMounted, isTrue);
    expect(opened.item.mountPoint, r'V:\');
    expect(harness.drives.isMounted(item.vaultPath!), isTrue);
    // The vault stays: nothing is decrypted to the disk.
    expect(opened.item.hasVault, isTrue);
    expect(Directory(item.itemPath).existsSync(), isFalse);
    expect(protection().lockRequirement(opened.item), LockRequirement.none);

    final locked = await protection().lockAgain(opened.item);
    expect(locked.isProtected, isTrue);
    expect(locked.mountPoint, isNull);
    expect(harness.drives.isMounted(item.vaultPath!), isFalse);
  });

  test('a drive with its own password needs it after the app locks', () async {
    final item = await lockAsDrive(
      'Shared',
      mode: PasswordMode.custom,
      password: 'drive-password',
    );
    harness.container.read(itemKeyCacheProvider).remove(item.id);

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
        credential: const PasswordCredential('wrong-password'),
      ),
      throwsA(isA<EngineException>()),
    );
    final opened = await protection().unlock(
      item,
      credential: const PasswordCredential('drive-password'),
    );
    expect(opened.item.isMounted, isTrue);

    // The recovery key opens it too.
    await protection().lockAgain(opened.item);
    final byRecovery = await protection().unlock(
      items().byId(item.id)!,
      credential: RecoveryCredential(RecoveryKey.tryParse(recoveryKey)!),
    );
    expect(byRecovery.item.isMounted, isTrue);
  });

  test('decrypting to a folder deletes the vault; it can lock again', () async {
    final item = await lockAsDrive('Notes');
    final opened = await protection().unlock(item);

    // A wrong password leaves the open drive open.
    await expectLater(
      protection().decryptDrive(
        opened.item,
        credential: const PasswordCredential('wrong-password'),
      ),
      throwsA(isA<EngineException>()),
    );
    expect(harness.drives.isMounted(item.vaultPath!), isTrue);
    expect(items().byId(item.id)!.isMounted, isTrue);

    final restored = await protection().decryptDrive(opened.item);
    expect(restored.item.isProtected, isFalse);
    expect(restored.item.hasVault, isFalse);
    expect(restored.item.isMounted, isFalse);
    expect(harness.drives.isMounted(item.vaultPath!), isFalse);
    expect(Directory(item.vaultPath!).existsSync(), isFalse);
    expect(
      File(p.join(item.itemPath, 'sub', 'b.txt')).readAsStringSync(),
      'secret B',
    );
    // Now it's a normal folder that may leave the list.
    await protection().lockAgain(restored.item);
    final relocked = items().byId(item.id)!;
    expect(relocked.isProtected, isTrue);
    expect(Directory(relocked.vaultPath!).existsSync(), isTrue);
    await expectLater(
      protection().remove(relocked),
      throwsA(isA<ProtectionException>()),
    );
  });

  test('a drive in use only closes when forced', () async {
    final item = await lockAsDrive('Busy');
    final vault = item.vaultPath!;
    await protection().unlock(item);
    harness.drives.busy.add(vault);
    final inUse = throwsA(
      isA<DriveException>().having((e) => e.code, 'code', DriveErrorCode.inUse),
    );

    await expectLater(protection().lockAgain(items().byId(item.id)!), inUse);
    await expectLater(protection().decryptDrive(items().byId(item.id)!), inUse);
    // Locking everything (the tray, or with the app) leaves it open too.
    final left = await protection().lockAllUnlocked();
    expect(left.map((left) => left.id), [item.id]);
    expect(items().byId(item.id)!.isMounted, isTrue);
    expect(harness.drives.isMounted(vault), isTrue);
    expect(Directory(vault).existsSync(), isTrue);

    final locked = await protection().lockAgain(
      items().byId(item.id)!,
      force: true,
    );
    expect(locked.isProtected, isTrue);
    expect(harness.drives.isMounted(vault), isFalse);
  });

  test('a failed import puts the folder back', () async {
    harness.drives.failNextImport = const EngineException(
      EngineErrorCode.diskFull,
      'full',
    );
    final original = folder('Big');
    await expectLater(
      protection().protectNew(
        ProtectRequest(
          path: original.path,
          method: ProtectionMethod.drive,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      ),
      throwsA(isA<EngineException>()),
    );
    expect(File(p.join(original.path, 'a.txt')).readAsStringSync(), 'secret A');
    expect(Directory(harness.userPath('')).listSync(), hasLength(1));
    expect(items().items, isEmpty);
  });

  test('files are refused: only folders become drives', () async {
    final file = File(harness.userPath('single.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    await expectLater(
      protection().protectNew(
        ProtectRequest(
          path: file.path,
          method: ProtectionMethod.drive,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      ),
      throwsA(
        isA<ProtectionException>().having(
          (e) => e.issue,
          'issue',
          ProtectionIssue.driveNeedsFolder,
        ),
      ),
    );
  });

  test('a drive closed from outside shows as locked', () async {
    final item = await lockAsDrive('Music');
    await protection().unlock(item);
    harness.drives.eject(item.vaultPath!);
    await Future<void>.delayed(Duration.zero);
    await items().saved;
    expect(items().byId(item.id)!.isMounted, isFalse);
    expect(items().byId(item.id)!.isProtected, isTrue);
  });

  test('no drive is open after a restart', () async {
    final item = await lockAsDrive('Work');
    await protection().unlock(item);
    expect(items().byId(item.id)!.isMounted, isTrue);

    await items().saved;
    harness.container.dispose();
    harness = await AppHarness.create(root: harness.root);
    await ready();
    final reloaded = items().byId(item.id)!;
    expect(reloaded.isProtected, isTrue);
    expect(reloaded.mountPoint, isNull);
  });

  test('a new master password reaches drive vaults, even open ones', () async {
    final locked = await lockAsDrive('Locked');
    final open = (await protection().unlock(await lockAsDrive('Open'))).item;

    final failed = await session().changePassword(
      newPassword: 'new-master-password',
    );
    expect(failed, 0);
    for (final item in [locked, open]) {
      final header = VaultHeader.read(
        item.vaultPath!,
        harness.container.read(cryptoProvider),
      );
      final unlocked = VaultKeys(harness.container.read(cryptoProvider))
          .unlock(header, const PasswordCredential('new-master-password'));
      unlocked.dataKey.dispose();
      unlocked.derivedKey?.dispose();
    }
  });
}
