import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../engine_exception.dart';
import 'archive_path.dart';
import 'byte_io.dart';
import 'payload_cipher.dart';

/// Whether a vault holds a folder or a single file.
enum ItemKind { folder, file }

/// Plain description of what is inside a vault (stored encrypted).
class ArchiveMetadata {
  const ArchiveMetadata({
    required this.kind,
    required this.name,
    required this.createdAt,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
  });

  factory ArchiveMetadata.fromJson(Map<String, Object?> json) {
    final kind = ItemKind.values.asNameMap()[json['kind']];
    final name = json['name'];
    if (kind == null || name is! String) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid vault metadata',
      );
    }
    return ArchiveMetadata(
      kind: kind,
      name: name,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      fileCount: json['fileCount'] as int? ?? 0,
      folderCount: json['folderCount'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
    );
  }

  final ItemKind kind;

  /// Original file or folder name.
  final String name;
  final DateTime createdAt;

  /// Expected counts, used to show progress while unlocking.
  final int fileCount;
  final int folderCount;
  final int totalBytes;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'fileCount': fileCount,
    'folderCount': folderCount,
    'totalBytes': totalBytes,
  };
}

/// One entry inside the archive.
sealed class ArchiveEntry {
  const ArchiveEntry({
    required this.path,
    required this.modified,
    required this.attributes,
  });

  /// Relative path with `/` separators.
  final String path;
  final DateTime? modified;

  /// Windows attribute bits to restore (read-only, hidden, system).
  final int attributes;
}

final class FolderEntry extends ArchiveEntry {
  const FolderEntry({
    required super.path,
    required super.modified,
    required super.attributes,
  });
}

final class FileEntry extends ArchiveEntry {
  const FileEntry({
    required super.path,
    required super.modified,
    required super.attributes,
    required this.size,
  });

  final int size;
}

abstract final class _Tag {
  static const int end = 0;
  static const int folder = 1;
  static const int file = 2;
}

final Uint8List _archiveMagic = ascii.encode('FLKARCH1');

/// Serializes files and folders into the plaintext stream of a vault.
///
/// ```text
/// "FLKARCH1" | u32 len + metadata JSON
/// entries:   u8 tag | u16 len + path | i64 modified ms | u32 attributes
///            [file only] u64 size | size bytes of content
/// end:       u8 0 | u64 files | u64 folders | u64 total bytes
/// ```
class ArchiveWriter {
  ArchiveWriter(this._sink);

  final ByteSink _sink;
  int _fileCount = 0;
  int _folderCount = 0;
  int _totalBytes = 0;
  int _pendingFileBytes = 0;
  bool _inFile = false;

  int get fileCount => _fileCount;
  int get folderCount => _folderCount;
  int get totalBytes => _totalBytes;

  void start(ArchiveMetadata metadata) {
    final writer = ByteWriter()
      ..bytes(_archiveMagic)
      ..string32(jsonEncode(metadata.toJson()));
    _sink.add(writer.toBytes());
  }

  void addFolder(String path, {DateTime? modified, int attributes = 0}) {
    _checkNotInFile();
    _writeEntryHeader(_Tag.folder, path, modified, attributes);
    _folderCount++;
  }

  void beginFile(
    String path, {
    required int size,
    DateTime? modified,
    int attributes = 0,
  }) {
    _checkNotInFile();
    _writeEntryHeader(_Tag.file, path, modified, attributes);
    _sink.add((ByteWriter()..u64(size)).toBytes());
    _pendingFileBytes = size;
    _inFile = true;
  }

  void addFileData(Uint8List data) {
    if (!_inFile || data.length > _pendingFileBytes) {
      throw const EngineException(
        EngineErrorCode.ioError,
        'A file changed size while it was being locked',
      );
    }
    _sink.add(data);
    _pendingFileBytes -= data.length;
    _totalBytes += data.length;
  }

  void endFile() {
    if (!_inFile || _pendingFileBytes != 0) {
      throw const EngineException(
        EngineErrorCode.ioError,
        'A file changed size while it was being locked',
      );
    }
    _inFile = false;
    _fileCount++;
  }

  void finish() {
    _checkNotInFile();
    _sink.add(
      (ByteWriter()
            ..u8(_Tag.end)
            ..u64(_fileCount)
            ..u64(_folderCount)
            ..u64(_totalBytes))
          .toBytes(),
    );
  }

  void _writeEntryHeader(
    int tag,
    String path,
    DateTime? modified,
    int attributes,
  ) {
    _sink.add(
      (ByteWriter()
            ..u8(tag)
            ..string16(path)
            ..i64(modified?.millisecondsSinceEpoch ?? -1)
            ..u32(attributes))
          .toBytes(),
    );
  }

  void _checkNotInFile() {
    if (_inFile) throw StateError('endFile() was not called');
  }
}

/// Reads the plaintext stream written by [ArchiveWriter].
///
/// Structured fields are parsed from a small buffer, while file contents are
/// passed through in pieces without being copied.
class ArchiveReader {
  ArchiveReader(this._source);

  final ByteSource _source;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  bool _sourceDone = false;

  int _fileCount = 0;
  int _folderCount = 0;
  int _totalBytes = 0;

  ArchiveMetadata readStart() {
    final magic = _read(_archiveMagic.length);
    for (var i = 0; i < magic.length; i++) {
      if (magic[i] != _archiveMagic[i]) {
        throw const EngineException(
          EngineErrorCode.corruptVault,
          'Invalid vault contents',
        );
      }
    }
    final length = ByteReader(_read(4)).u32();
    if (length > 1024 * 1024) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid vault metadata',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(_read(length)));
    } on FormatException {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid vault metadata',
      );
    }
    if (json is! Map<String, Object?>) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid vault metadata',
      );
    }
    return ArchiveMetadata.fromJson(json);
  }

  /// Returns the next entry, or `null` once the end marker was read and
  /// checked. For a [FileEntry], call [readFileData] before asking for the
  /// next entry.
  ArchiveEntry? nextEntry() {
    final tag = _read(1)[0];
    if (tag == _Tag.end) {
      _readTrailer();
      return null;
    }
    if (tag != _Tag.folder && tag != _Tag.file) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Unknown entry in vault',
      );
    }
    final pathLength = ByteReader(_read(2)).u16();
    final String path;
    try {
      path = utf8.decode(_read(pathLength));
    } on FormatException {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid path in vault',
      );
    }
    ArchivePath.checkStored(path);
    final fields = ByteReader(_read(12));
    final modifiedMs = fields.i64();
    final attributes = fields.u32();
    final modified = modifiedMs < 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(modifiedMs);

    if (tag == _Tag.folder) {
      _folderCount++;
      return FolderEntry(
        path: path,
        modified: modified,
        attributes: attributes,
      );
    }
    final size = ByteReader(_read(8)).u64();
    if (size < 0) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid file size in vault',
      );
    }
    _fileCount++;
    return FileEntry(
      path: path,
      modified: modified,
      attributes: attributes,
      size: size,
    );
  }

  /// Streams exactly [size] bytes of file content to [onData].
  void readFileData(int size, void Function(Uint8List data) onData) {
    var remaining = size;
    while (remaining > 0) {
      if (_offset == _chunk.length) _loadNextChunk();
      final count = math.min(remaining, _chunk.length - _offset);
      onData(Uint8List.sublistView(_chunk, _offset, _offset + count));
      _offset += count;
      remaining -= count;
    }
    _totalBytes += size;
  }

  void _readTrailer() {
    final trailer = ByteReader(_read(24));
    final files = trailer.u64();
    final folders = trailer.u64();
    final bytes = trailer.u64();
    if (files != _fileCount ||
        folders != _folderCount ||
        bytes != _totalBytes) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault contents are incomplete',
      );
    }
    // Nothing may follow the end marker.
    if (_offset != _chunk.length || _source.next() != null) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Unexpected data after the end of the vault',
      );
    }
  }

  /// Reads exactly [count] bytes (copied, since they may span chunks).
  Uint8List _read(int count) {
    final result = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      if (_offset == _chunk.length) _loadNextChunk();
      final take = math.min(count - filled, _chunk.length - _offset);
      result.setRange(filled, filled + take, _chunk, _offset);
      _offset += take;
      filled += take;
    }
    return result;
  }

  void _loadNextChunk() {
    // Skip empty chunks (an empty payload produces one empty final chunk).
    while (true) {
      final next = _sourceDone ? null : _source.next();
      if (next == null) {
        _sourceDone = true;
        throw const EngineException(
          EngineErrorCode.corruptVault,
          'The vault ended unexpectedly',
        );
      }
      if (next.isNotEmpty) {
        _chunk = next;
        _offset = 0;
        return;
      }
    }
  }
}
