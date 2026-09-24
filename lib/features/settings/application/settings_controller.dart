import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../platform/explorer_integration.dart';
import '../data/settings_repository.dart';
import '../domain/app_settings.dart';

/// Settings loaded before the first frame (so the theme doesn't flicker).
/// Overridden in `bootstrap()`.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final explorerIntegrationProvider = Provider<ExplorerIntegration>(
  (ref) => ExplorerIntegration(ref.watch(executablePathProvider)),
);

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(initialSettingsProvider);

  Future<void> _update(AppSettings next) async {
    state = next;
    await ref.read(settingsRepositoryProvider).save(next);
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _update(state.copyWith(themeMode: mode));

  Future<void> setAutoLockMinutes(int minutes) =>
      _update(state.copyWith(autoLockMinutes: minutes));

  Future<void> setAskToLockOnExit(bool value) =>
      _update(state.copyWith(askToLockOnExit: value));

  Future<void> setOpenAfterUnlock(bool value) =>
      _update(state.copyWith(openAfterUnlock: value));

  Future<void> setKeepRunningInTray(bool value) =>
      _update(state.copyWith(keepRunningInTray: value));

  Future<void> setAskToLockWhenClosed(bool value) =>
      _update(state.copyWith(askToLockWhenClosed: value));

  Future<void> setRemindAfterMinutes(int minutes) =>
      _update(state.copyWith(remindAfterMinutes: minutes));

  Future<void> setRelockAfterMinutes(int minutes) =>
      _update(state.copyWith(relockAfterMinutes: minutes));

  Future<void> setLockItemsWithApp(bool value) =>
      _update(state.copyWith(lockItemsWithApp: value));

  Future<void> markTrayHintShown() =>
      _update(state.copyWith(trayHintShown: true));

  /// Adds or removes the Explorer context menu and vault association.
  ///
  /// The setting is saved first: the Explorer plug-in reads it (for the
  /// lock badges) when Explorer refreshes, which the registry change
  /// starts. If that change fails, the next start of the app tries again.
  Future<void> setExplorerIntegration(bool enabled) async {
    await _update(state.copyWith(explorerIntegration: enabled));
    final integration = ref.read(explorerIntegrationProvider);
    if (enabled) {
      integration.register();
    } else {
      integration.unregister();
    }
  }

  /// Makes the registry match the setting at startup: registers again if
  /// the entries point to an old location (the app was moved or updated),
  /// and removes the entries the installer adds if the user turned the
  /// integration off.
  void syncExplorerIntegration() {
    if (!ExplorerIntegration.isSupported) return;
    final integration = ref.read(explorerIntegrationProvider);
    final registered = integration.isRegistered;
    if (state.explorerIntegration && !registered) {
      integration.register();
    } else if (!state.explorerIntegration && registered) {
      integration.unregister();
    }
  }
}
