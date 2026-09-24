import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_info.dart';
import '../../../engine/vault/drive_vault.dart';

/// Something Explorer asked the app to do through command-line arguments,
/// or, from the app itself, a question about a folder the user closed.
sealed class LaunchIntent {
  const LaunchIntent(this.path);

  final String path;

  /// Needs only a dialog, which can show without the app (see
  /// `WindowController`), even while the app is locked.
  bool get dialogOnly => false;

  /// Parses `--open <vault>`, `--lock <path>` and `--unlock <path>`.
  static LaunchIntent? parse(List<String> args) {
    for (var i = 0; i < args.length - 1; i++) {
      final path = args[i + 1].trim();
      if (path.isEmpty) continue;
      switch (args[i]) {
        case '--open':
          return OpenVaultIntent(path);
        // "Lock with…" on a vault (without the Explorer plug-in, every item
        // has it) means "unlock it".
        case '--lock' when _isVault(path):
        case '--unlock' when _isVault(path):
          return OpenVaultIntent(path);
        case '--lock':
          return LockPathIntent(path);
        case '--unlock':
          return UnlockPathIntent(path);
      }
    }
    return null;
  }

  static bool _isVault(String path) =>
      path.toLowerCase().endsWith(AppInfo.vaultExtension) ||
      DriveVault.isDrivePath(path);
}

/// A vault was double-clicked in Explorer: ask for its password.
final class OpenVaultIntent extends LaunchIntent {
  const OpenVaultIntent(super.path);

  @override
  bool get dialogOnly => true;
}

/// "Lock with Cloak" was chosen in Explorer: protect a new item,
/// or lock a listed one again.
final class LockPathIntent extends LaunchIntent {
  const LockPathIntent(super.path);
}

/// "Unlock with Cloak" was chosen in Explorer (the plug-in offers
/// it for blocked, read-only and hidden items).
final class UnlockPathIntent extends LaunchIntent {
  const UnlockPathIntent(super.path);
}

/// Lock the unlocked item [itemId] (at [path]) again, after asking: its
/// last Explorer window [closed] (see `FolderWindowWatcher`), or it needs
/// a password to lock ("Lock all" in the notification area).
final class LockAgainIntent extends LaunchIntent {
  const LockAgainIntent(super.path, {required this.itemId, this.closed = true});

  final String itemId;
  final bool closed;

  @override
  bool get dialogOnly => true;
}

final launchIntentsProvider =
    NotifierProvider<LaunchIntents, List<LaunchIntent>>(LaunchIntents.new);

/// Queue of requests, handled one at a time by the UI.
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
