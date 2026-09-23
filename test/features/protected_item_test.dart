import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> json({Object? method, bool? encrypt}) => {
    'id': 'a1',
    'name': 'Secret',
    'kind': 'folder',
    'itemPath': r'C:\Docs\Secret',
    'hide': false,
    'passwordMode': 'master',
    'status': 'protected',
    'addedAt': '2026-01-01T00:00:00.000Z',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'method': ?method,
    'encrypt': ?encrypt,
  };

  test('reads lists written by version 1.0', () {
    expect(
      ProtectedItem.fromJson(json(encrypt: true)).method,
      ProtectionMethod.encrypt,
    );
    expect(
      ProtectedItem.fromJson(json(encrypt: false)).method,
      ProtectionMethod.none,
    );
  });

  test('round-trips the method and the unlock time', () {
    final item = ProtectedItem.fromJson(json(method: 'blockAccess'));
    expect(item.method, ProtectionMethod.blockAccess);
    expect(item.encrypt, isFalse);
    expect(item.method.usesAccessRule, isTrue);

    final unlocked = item.copyWith(
      status: ProtectionStatus.unprotected,
      unlockedAt: DateTime.utc(2026, 5, 1, 12),
    );
    final restored = ProtectedItem.fromJson(unlocked.toJson());
    expect(restored.method, ProtectionMethod.blockAccess);
    expect(restored.unlockedAt, DateTime.utc(2026, 5, 1, 12));

    // Locking again forgets when it was unlocked.
    final locked = restored.copyWith(status: ProtectionStatus.protected);
    expect(locked.unlockedAt, isNull);
  });
}
