import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:desktop_folder_locker/engine/crypto/crypto_service.dart';
import 'package:desktop_folder_locker/engine/crypto/kdf_params.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Shared helpers for engine tests.
class TestEnv {
  TestEnv._(this.crypto, this.root);

  final CryptoService crypto;
  final Directory root;

  static Future<TestEnv> create() async {
    final crypto = await CryptoService.create();
    final root = await Directory.systemTemp.createTemp('flk_test_');
    return TestEnv._(crypto, root);
  }

  Future<void> dispose() => root.delete(recursive: true);

  String path(String relative) => p.join(root.path, relative);

  String get journalDir => path('_journal');

  /// A key derived from [password] with cheap Argon2id settings.
  DerivedKey derive(String password, {Uint8List? salt}) {
    final kdf = KdfPolicy.fast.withSalt(
      salt ?? crypto.randomBytes(KdfParams.saltLength),
    );
    return DerivedKey(key: crypto.deriveKey(password, kdf), kdf: kdf);
  }

  /// Creates a folder with nested content, empty folders and files of
  /// various sizes (including around chunk boundaries).
  Directory createSampleFolder(String name, {int seed = 1}) {
    final random = Random(seed);
    final dir = Directory(path(name))..createSync(recursive: true);
    File(p.join(dir.path, 'empty.txt')).writeAsBytesSync([]);
    File(p.join(dir.path, 'hello.txt')).writeAsStringSync('Hello, vault!');
    File(p.join(dir.path, 'ünïcødé ✓.txt')).writeAsStringSync('unicode');
    Directory(p.join(dir.path, 'empty folder')).createSync();
    final nested = Directory(p.join(dir.path, 'a', 'b', 'c'))
      ..createSync(recursive: true);
    File(p.join(nested.path, 'deep.bin'))
        .writeAsBytesSync(_randomBytes(random, 256 * 1024 + 17));
    File(p.join(dir.path, 'a', 'big.bin'))
        .writeAsBytesSync(_randomBytes(random, 3 * 1024 * 1024 + 5));
    File(p.join(dir.path, 'a', 'exact.bin'))
        .writeAsBytesSync(_randomBytes(random, 256 * 1024));
    return dir;
  }

  static Uint8List _randomBytes(Random random, int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}

/// Map of relative path → file bytes (`null` for folders).
Map<String, List<int>?> snapshotTree(String rootPath) {
  final result = <String, List<int>?>{};
  final root = Directory(rootPath);
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: rootPath);
    result[relative] = entity is File ? entity.readAsBytesSync() : null;
  }
  return result;
}

void expectSameTree(
  Map<String, List<int>?> expected,
  Map<String, List<int>?> actual,
) {
  expect(actual.keys.toSet(), expected.keys.toSet());
  for (final entry in expected.entries) {
    expect(actual[entry.key], entry.value, reason: entry.key);
  }
}
