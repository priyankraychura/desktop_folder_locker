import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/storage/json_file_store.dart';
import '../domain/keystore.dart';

final keystoreRepositoryProvider = Provider<KeystoreRepository>(
  (ref) => KeystoreRepository(
    JsonFileStore(ref.watch(appPathsProvider).keystoreFile),
  ),
);

/// Persists the [Keystore] in `keystore.json`.
class KeystoreRepository {
  KeystoreRepository(this._store);

  final JsonFileStore _store;

  Future<Keystore?> load() async {
    final json = await _store.read();
    return json == null ? null : Keystore.fromJson(json);
  }

  Future<void> save(Keystore keystore) => _store.write(keystore.toJson());
}
