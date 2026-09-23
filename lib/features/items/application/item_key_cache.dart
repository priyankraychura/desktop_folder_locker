import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/format/key_slot.dart';
import '../../../engine/vault/vault_keys.dart';

final itemKeyCacheProvider = Provider<ItemKeyCache>((ref) {
  final cache = ItemKeyCache();
  ref.onDispose(cache.clear);
  return cache;
});

/// A password-derived key remembered for one item.
class CachedItemKey {
  const CachedItemKey(this.key, this.slotType);

  final DerivedKey key;
  final KeySlotType slotType;
}

/// Keys of items unlocked during this session, kept in protected memory so
/// "Lock again" doesn't ask for a custom password a second time.
///
/// Cleared whenever the app locks.
class ItemKeyCache {
  final Map<String, CachedItemKey> _keys = {};

  CachedItemKey? operator [](String itemId) => _keys[itemId];

  void put(String itemId, DerivedKey key, KeySlotType slotType) {
    _keys.remove(itemId)?.key.dispose();
    _keys[itemId] = CachedItemKey(key, slotType);
  }

  void remove(String itemId) => _keys.remove(itemId)?.key.dispose();

  void clear() {
    for (final entry in _keys.values) {
      entry.key.dispose();
    }
    _keys.clear();
  }
}
