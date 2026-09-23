import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_info.dart';

/// Something Explorer asked the app to do through command-line arguments.
sealed class LaunchIntent {
  const LaunchIntent(this.path);

  final String path;

  /// Parses `--open <vault>` and `--lock <path>`.
  static LaunchIntent? parse(List<String> args) {
    for (var i = 0; i < args.length - 1; i++) {
      final path = args[i + 1].trim();
      if (path.isEmpty) continue;
      switch (args[i]) {
        case '--open':
          return OpenVaultIntent(path);
        case '--lock':
          // "Lock with…" on a vault file means "unlock it".
          return path.toLowerCase().endsWith(AppInfo.vaultExtension)
              ? OpenVaultIntent(path)
              : LockPathIntent(path);
      }
    }
    return null;
  }
}

/// A vault was double-clicked in Explorer: ask for its password.
final class OpenVaultIntent extends LaunchIntent {
  const OpenVaultIntent(super.path);
}

/// "Lock with Folder Locker" was chosen in Explorer.
final class LockPathIntent extends LaunchIntent {
  const LockPathIntent(super.path);
}

final launchIntentsProvider =
    NotifierProvider<LaunchIntents, List<LaunchIntent>>(LaunchIntents.new);

/// Queue of requests from Explorer, handled one at a time by the UI.
class LaunchIntents extends Notifier<List<LaunchIntent>> {
  @override
  List<LaunchIntent> build() => const [];

  void add(LaunchIntent intent) => state = [...state, intent];

  void addArgs(List<String> args) {
    final intent = LaunchIntent.parse(args);
    if (intent != null) add(intent);
  }

  /// Removes and returns the first intent that [canHandle] accepts.
  LaunchIntent? take(bool Function(LaunchIntent intent) canHandle) {
    for (final intent in state) {
      if (canHandle(intent)) {
        state = [...state]..remove(intent);
        return intent;
      }
    }
    return null;
  }
}
