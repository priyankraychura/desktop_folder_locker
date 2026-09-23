import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/file_system_info.dart';
import '../engine_exception.dart';
import '../format/archive.dart';
import '../format/archive_path.dart';
import '../operations/operation_progress.dart';
import 'fs_utils.dart';

/// One file or folder found while scanning the item to lock.
class SourceEntry {
  const SourceEntry({
    required this.relativePath,
    required this.isFolder,
    required this.size,
    required this.modified,
    required this.attributes,
  });

  /// Path relative to the item root, `/`-separated. For a single file this
  /// is the file name.
  final String relativePath;
  final bool isFolder;
  final int size;
  final DateTime modified;
  final int attributes;
}

/// Everything that will go into a vault, gathered before anything is
/// changed on disk. Problems (links, invalid names) are found here, so a
/// failed lock never leaves the item half-processed.
class SourceSnapshot {
  const SourceSnapshot({
    required this.kind,
    required this.name,
    required this.entries,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
  });

  final ItemKind kind;
  final String name;
  final List<SourceEntry> entries;
  final int fileCount;
  final int folderCount;
  final int totalBytes;

  /// Absolute path of [entry] when the item lives at [root].
  String resolve(String root, SourceEntry entry) => kind == ItemKind.file
      ? root
      : p.joinAll([root, ...entry.relativePath.split('/')]);
}

abstract final class SourceScanner {
  /// Scans the file or folder at [path].
  static SourceSnapshot scan(String path, {CancellationToken? cancel}) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    final name = p.basename(path);
    switch (type) {
      case FileSystemEntityType.notFound:
        throw EngineException(
          EngineErrorCode.notFound,
          'Item not found',
          path: path,
        );
      case FileSystemEntityType.link:
        throw EngineException(
          EngineErrorCode.unsupportedContent,
          'Shortcuts, symbolic links and junctions cannot be locked',
          path: path,
        );
      case FileSystemEntityType.directory:
        return _scanFolder(path, name, cancel);
      default:
        ArchivePath.checkSource(name, path);
        final stat = FsUtils.guard(() => File(path).statSync(), path: path);
        return SourceSnapshot(
          kind: ItemKind.file,
          name: name,
          entries: [
            SourceEntry(
              relativePath: name,
              isFolder: false,
              size: stat.size,
              modified: stat.modified,
              attributes: FileSystemInfo.preservedAttributes(path),
            ),
          ],
          fileCount: 1,
          folderCount: 0,
          totalBytes: stat.size,
        );
    }
  }

  static SourceSnapshot _scanFolder(
    String root,
    String name,
    CancellationToken? cancel,
  ) {
    ArchivePath.checkSource(name, root);
    final entries = <SourceEntry>[];
    // Windows compares names without case; two names that differ only by
    // case could not both be restored.
    final seen = <String>{};
    var files = 0;
    var folders = 0;
    var bytes = 0;

    void walk(String dir, String prefix) {
      cancel?.throwIfCancelled();
      final children = FsUtils.guard(
        () => Directory(dir).listSync(followLinks: false),
        path: dir,
      )..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      for (final child in children) {
        final childName = p.basename(child.path);
        final relative = prefix.isEmpty ? childName : '$prefix/$childName';
        ArchivePath.checkSource(relative, child.path);
        if (!seen.add(relative.toLowerCase())) {
          throw EngineException(
            EngineErrorCode.unsupportedContent,
            'Two items have the same name when case is ignored',
            path: child.path,
          );
        }
        if (child is Link) {
          throw EngineException(
            EngineErrorCode.unsupportedContent,
            'Folders that contain symbolic links or junctions cannot be '
            'locked yet',
            path: child.path,
          );
        }
        final stat = FsUtils.guard(child.statSync, path: child.path);
        final attributes = FileSystemInfo.preservedAttributes(child.path);
        if (child is Directory) {
          folders++;
          entries.add(
            SourceEntry(
              relativePath: relative,
              isFolder: true,
              size: 0,
              modified: stat.modified,
              attributes: attributes,
            ),
          );
          walk(child.path, relative);
        } else {
          files++;
          bytes += stat.size;
          entries.add(
            SourceEntry(
              relativePath: relative,
              isFolder: false,
              size: stat.size,
              modified: stat.modified,
              attributes: attributes,
            ),
          );
        }
      }
    }

    walk(root, '');
    return SourceSnapshot(
      kind: ItemKind.folder,
      name: name,
      entries: entries,
      fileCount: files,
      folderCount: folders,
      totalBytes: bytes,
    );
  }
}
