import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/storage/json_file_store.dart';
import '../domain/protected_item.dart';

final itemsRepositoryProvider = Provider<ItemsRepository>(
  (ref) =>
      ItemsRepository(JsonFileStore(ref.watch(appPathsProvider).itemsFile)),
);

/// Persists the list of [ProtectedItem]s in `items.json`.
class ItemsRepository {
  ItemsRepository(this._store);

  final JsonFileStore _store;

  static const int _version = 1;

  Future<List<ProtectedItem>> load() async {
    final json = await _store.read();
    final items = json?['items'];
    if (items is! List<Object?>) return [];
    return [
      for (final item in items)
        if (item is Map<String, Object?>) ProtectedItem.fromJson(item),
    ];
  }

  Future<void> save(List<ProtectedItem> items) => _store.write({
    'version': _version,
    'items': [for (final item in items) item.toJson()],
  });
}
