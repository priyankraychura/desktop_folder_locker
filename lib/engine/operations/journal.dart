import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../vault/fs_utils.dart';

enum JournalKind { lock, unlock }

/// How far an operation got before it was interrupted.
enum JournalPhase {
  /// Work started; the original data is still the source of truth.
  started,

  /// Lock only: the new vault was written and verified.
  verified,

  /// Lock: vault is in place. Unlock: files are restored.
  committed,
}

/// A small file written before every step that changes the disk, so an
/// interrupted lock or unlock (crash, power loss) can be completed or rolled
/// back the next time the app starts.
class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.kind,
    required this.phase,
    required this.itemPath,
    required this.workPath,
    required this.vaultPath,
    required this.startedAt,
    this.partialPath,
    this.tag,
  });

  factory JournalEntry.fromJson(Map<String, Object?> json) => JournalEntry(
    id: json['id']! as String,
    kind: JournalKind.values.byName(json['kind']! as String),
    phase: JournalPhase.values.byName(json['phase']! as String),
    itemPath: json['itemPath']! as String,
    workPath: json['workPath']! as String,
    vaultPath: json['vaultPath']! as String,
    partialPath: json['partialPath'] as String?,
    tag: json['tag'] as String?,
    startedAt: DateTime.parse(json['startedAt']! as String),
  );

  final String id;
  final JournalKind kind;
  final JournalPhase phase;

  /// Lock: the item being locked. Unlock: where the item is restored.
  final String itemPath;

  /// Lock: the renamed ("staged") item. Unlock: the temporary restore
  /// folder.
  final String workPath;

  /// The final vault file.
  final String vaultPath;

  /// Lock only: the vault while it's being written.
  final String? partialPath;

  /// Free-form value for the caller (the app stores the item id).
  final String? tag;
  final DateTime startedAt;

  JournalEntry withPhase(JournalPhase next) => JournalEntry(
    id: id,
    kind: kind,
    phase: next,
    itemPath: itemPath,
    workPath: workPath,
    vaultPath: vaultPath,
    partialPath: partialPath,
    tag: tag,
    startedAt: startedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'phase': phase.name,
    'itemPath': itemPath,
    'workPath': workPath,
    'vaultPath': vaultPath,
    'partialPath': partialPath,
    'tag': tag,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };
}

/// Stores [JournalEntry]s as one JSON file each.
class Journal {
  Journal(this.directory);

  final String directory;

  String _fileFor(String id) => p.join(directory, '$id.json');

  void save(JournalEntry entry) {
    Directory(directory).createSync(recursive: true);
    final target = _fileFor(entry.id);
    final temp = File('$target.tmp');
    FsUtils.guard(() {
      temp.writeAsStringSync(jsonEncode(entry.toJson()), flush: true);
      temp.renameSync(target);
    }, path: target);
  }

  void remove(String id) {
    final file = File(_fileFor(id));
    if (file.existsSync()) file.deleteSync();
  }

  List<JournalEntry> pending() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    final entries = <JournalEntry>[];
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(file.readAsStringSync());
        if (json is Map<String, Object?>) {
          entries.add(JournalEntry.fromJson(json));
        }
      } on Object {
        // An unreadable journal can't be acted on safely; leave it for
        // inspection instead of guessing.
      }
    }
    entries.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return entries;
  }
}

/// What startup recovery did for one interrupted operation.
class RecoveryOutcome {
  const RecoveryOutcome({
    required this.entry,
    required this.completed,
    required this.success,
  });

  final JournalEntry entry;

  /// `true` if the operation was finished, `false` if it was rolled back.
  final bool completed;

  /// `false` if recovery failed and will be retried at the next start.
  final bool success;
}

/// Completes or rolls back operations that were interrupted.
abstract final class JournalRecovery {
  static List<RecoveryOutcome> run(Journal journal) => [
    for (final entry in journal.pending()) _recover(journal, entry),
  ];

  static RecoveryOutcome _recover(Journal journal, JournalEntry entry) {
    var completed = false;
    try {
      switch (entry.kind) {
        case JournalKind.lock:
          completed = _recoverLock(entry);
        case JournalKind.unlock:
          completed = _recoverUnlock(entry);
      }
      journal.remove(entry.id);
      return RecoveryOutcome(entry: entry, completed: completed, success: true);
    } on Object {
      return RecoveryOutcome(
        entry: entry,
        completed: completed,
        success: false,
      );
    }
  }

  /// Returns `true` when the lock was completed, `false` when rolled back.
  static bool _recoverLock(JournalEntry entry) {
    final partial = entry.partialPath;
    final vaultReady =
        entry.phase == JournalPhase.committed ||
        (entry.phase == JournalPhase.verified &&
            (FsUtils.exists(entry.vaultPath) ||
                (partial != null && FsUtils.exists(partial))));

    if (vaultReady) {
      if (partial != null &&
          FsUtils.exists(partial) &&
          !FsUtils.exists(entry.vaultPath)) {
        FsUtils.rename(partial, entry.vaultPath);
      }
      _deleteOrThrow(entry.workPath);
      return true;
    }

    // Roll back: put the original item back where it was.
    if (FsUtils.exists(entry.workPath)) {
      final target = FsUtils.exists(entry.itemPath)
          ? FsUtils.freePath(entry.itemPath)
          : entry.itemPath;
      FsUtils.rename(entry.workPath, target);
    }
    if (partial != null) _deleteOrThrow(partial);
    return false;
  }

  /// Returns `true` when the unlock was completed, `false` when rolled back.
  static bool _recoverUnlock(JournalEntry entry) {
    if (entry.phase == JournalPhase.committed &&
        FsUtils.exists(entry.itemPath)) {
      _deleteOrThrow(entry.vaultPath);
      _deleteOrThrow(entry.workPath);
      return true;
    }
    _deleteOrThrow(entry.workPath);
    return false;
  }

  static void _deleteOrThrow(String path) {
    final failures = FsUtils.deleteTree(path);
    if (failures.isNotEmpty) {
      throw FileSystemException('Could not delete', failures.first);
    }
  }
}
