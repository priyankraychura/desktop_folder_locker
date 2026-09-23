import '../engine_exception.dart';

/// The step a long-running operation is in.
enum OperationPhase { preparing, encrypting, verifying, decrypting, finishing }

/// A progress snapshot sent from the engine isolate to the UI.
class OperationProgress {
  const OperationProgress({
    required this.phase,
    this.processedBytes = 0,
    this.totalBytes = 0,
    this.processedFiles = 0,
    this.totalFiles = 0,
    this.currentItem,
  });

  final OperationPhase phase;
  final int processedBytes;
  final int totalBytes;
  final int processedFiles;
  final int totalFiles;

  /// Relative path of the file being processed.
  final String? currentItem;

  /// 0.0 – 1.0, or `null` when the total is unknown.
  double? get fraction {
    if (totalBytes <= 0) {
      return totalFiles <= 0 ? null : processedFiles / totalFiles;
    }
    return (processedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

/// Receives progress updates, at most every [interval].
class ProgressReporter {
  ProgressReporter(
    this._onProgress, {
    this.interval = const Duration(milliseconds: 80),
  });

  /// A reporter that drops every update.
  ProgressReporter.silent() : this((_) {});

  final void Function(OperationProgress progress) _onProgress;
  final Duration interval;
  final Stopwatch _clock = Stopwatch()..start();
  Duration _last = Duration.zero;
  bool _first = true;

  /// Reports [progress] if enough time passed (or when [force] is set).
  void report(OperationProgress progress, {bool force = false}) {
    final now = _clock.elapsed;
    if (force || _first || now - _last >= interval) {
      _first = false;
      _last = now;
      _onProgress(progress);
    }
  }
}

/// Lets the UI stop an operation. The engine checks it between chunks.
///
/// [externalCheck] allows reading a flag owned by another isolate (the
/// engine loops are synchronous, so they can't receive messages while
/// running).
class CancellationToken {
  CancellationToken([this._externalCheck]);

  final bool Function()? _externalCheck;
  bool _cancelled = false;

  bool get isCancelled => _cancelled || (_externalCheck?.call() ?? false);

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (isCancelled) {
      throw const EngineException(
        EngineErrorCode.cancelled,
        'Operation cancelled',
      );
    }
  }
}
