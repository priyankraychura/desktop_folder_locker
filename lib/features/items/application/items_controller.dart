import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/di/core_providers.dart';
import '../../../engine/operations/journal.dart';
import '../../../engine/vault/fs_utils.dart';
import '../data/items_repository.dart';
import '../domain/protected_item.dart';

final itemsControllerProvider =
    AsyncNotifierProvider<ItemsController, List<ProtectedItem>>(
      ItemsController.new,
    );

/// Operations that were interrupted last time and fixed at startup.
final recoveryReportProvider =
    NotifierProvider<RecoveryReport, List<RecoveryOutcome>>(RecoveryReport.new);

class RecoveryReport extends Notifier<List<RecoveryOutcome>> {
  @override
  List<RecoveryOutcome> build() => const [];

  void report(List<RecoveryOutcome> outcomes) => state = outcomes;

  void clear() => state = const [];
}

/// The list of protected items, persisted in `items.json`.
class ItemsController extends AsyncNotifier<List<ProtectedItem>> {
  @override
  Future<List<ProtectedItem>> build() async {
    final repository = ref.read(itemsRepositoryProvider);
    final journal = Journal(ref.read(appPathsProvider).journalDir);
    var items = await repository.load();

    // Finish or roll back operations interrupted by a crash or power loss.
    final outcomes = await Isolate.run(() => JournalRecovery.run(journal));
    if (outcomes.isNotEmpty) {
      items = _applyRecovery(items, outcomes);
      ref.read(recoveryReportProvider.notifier).report(outcomes);
    }
    // Drives close with the app, so none is open at a start.
    final closed = [
      for (final item in items)
        item.isMounted
            ? item.copyWith(
                status: ProtectionStatus.protected,
                clearMountPoint: true,
              )
            : item,
    ];
    if (outcomes.isNotEmpty || items.any((item) => item.isMounted)) {
      items = closed;
      await repository.save(items);
    }
    return items;
  }

  List<ProtectedItem> get items => state.value ?? const [];

  ProtectedItem? byId(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Finds the item whose vault (or original path) is [path].
  ProtectedItem? byPath(String path) {
    final key = p.normalize(path).toLowerCase();
    for (final item in items) {
      final paths = [item.itemPath, ?item.vaultPath];
      if (paths.any(
        (candidate) => p.normalize(candidate).toLowerCase() == key,
      )) {
        return item;
      }
    }
    return null;
  }

  /// Whether the item's current file or folder exists.
  bool existsOnDisk(ProtectedItem item) => FsUtils.exists(item.currentPath);

  /// Vaults that are opened with the master password (for re-keying),
  /// including drives, whose vault stays while they are open.
  List<ProtectedItem> masterPasswordVaults() => [
    for (final item in items)
      if (item.hasVault && item.passwordMode == PasswordMode.master) item,
  ];

  Future<void> upsert(ProtectedItem item) async {
    final next = [...items];
    final index = next.indexWhere((existing) => existing.id == item.id);
    if (index < 0) {
      next.insert(0, item);
    } else {
      next[index] = item;
    }
    await _save(next);
  }

  Future<void> remove(String id) => _save([
    for (final item in items)
      if (item.id != id) item,
  ]);

  Future<void> setNeedsPassword(Set<String> vaultPaths, bool value) {
    final keys = vaultPaths.map((path) => p.normalize(path).toLowerCase());
    return _save([
      for (final item in items)
        if (item.vaultPath != null &&
            keys.contains(p.normalize(item.vaultPath!).toLowerCase()))
          item.copyWith(needsPassword: value)
        else
          item,
    ]);
  }

  Future<void> _lastSave = Future.value();

  /// Completes once every change so far is on the disk.
  Future<void> get saved => _lastSave;

  Future<void> _save(List<ProtectedItem> next) async {
    state = AsyncData(next);
    final save = ref.read(itemsRepositoryProvider).save(next);
    _lastSave = save.catchError((Object _) {});
    await save;
  }

  static List<ProtectedItem> _applyRecovery(
    List<ProtectedItem> items,
    List<RecoveryOutcome> outcomes,
  ) {
    final byTag = {
      for (final outcome in outcomes)
        if (outcome.success && outcome.entry.tag != null)
          outcome.entry.tag!: outcome,
    };
    return [
      for (final item in items)
        if (byTag[item.id] case final outcome?)
          _recovered(item, outcome)
        else
          item,
    ];
  }

  static ProtectedItem _recovered(ProtectedItem item, RecoveryOutcome outcome) {
    final entry = outcome.entry;
    return switch ((entry.kind, outcome.completed)) {
      (JournalKind.lock, true) => item.copyWith(
        status: ProtectionStatus.protected,
        vaultPath: entry.vaultPath,
      ),
      (JournalKind.lock, false) => item.copyWith(
        status: ProtectionStatus.unprotected,
      ),
      (JournalKind.unlock, true) => item.copyWith(
        status: ProtectionStatus.unprotected,
        itemPath: entry.itemPath,
        clearVaultPath: true,
      ),
      (JournalKind.unlock, false) => item,
    };
  }
}
