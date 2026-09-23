import 'package:flutter/material.dart' show ThemeMode;

/// User preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.autoLockMinutes = 5,
    this.explorerIntegration = true,
    this.askToLockOnExit = true,
    this.openAfterUnlock = true,
  });

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    themeMode:
        ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system,
    autoLockMinutes: json['autoLockMinutes'] as int? ?? 5,
    explorerIntegration: json['explorerIntegration'] as bool? ?? true,
    askToLockOnExit: json['askToLockOnExit'] as bool? ?? true,
    openAfterUnlock: json['openAfterUnlock'] as bool? ?? true,
  );

  final ThemeMode themeMode;

  /// Lock the app after this many idle minutes (0 = never).
  final int autoLockMinutes;

  /// Explorer right-click menu and vault double-click.
  final bool explorerIntegration;

  /// Offer to lock unlocked items again when the app closes.
  final bool askToLockOnExit;

  /// Open the folder in Explorer right after unlocking it.
  final bool openAfterUnlock;

  static const List<int> autoLockChoices = [0, 1, 5, 15, 30, 60];

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? autoLockMinutes,
    bool? explorerIntegration,
    bool? askToLockOnExit,
    bool? openAfterUnlock,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
    explorerIntegration: explorerIntegration ?? this.explorerIntegration,
    askToLockOnExit: askToLockOnExit ?? this.askToLockOnExit,
    openAfterUnlock: openAfterUnlock ?? this.openAfterUnlock,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'autoLockMinutes': autoLockMinutes,
    'explorerIntegration': explorerIntegration,
    'askToLockOnExit': askToLockOnExit,
    'openAfterUnlock': openAfterUnlock,
  };
}
