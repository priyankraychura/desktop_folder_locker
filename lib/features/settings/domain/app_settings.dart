import 'package:flutter/material.dart' show ThemeMode;

/// User preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.autoLockMinutes = 5,
    this.explorerIntegration = true,
    this.askToLockOnExit = true,
    this.openAfterUnlock = true,
    this.keepRunningInTray = true,
    this.askToLockWhenClosed = true,
    this.remindAfterMinutes = 30,
    this.relockAfterMinutes = 0,
    this.lockItemsWithApp = false,
    this.trayHintShown = false,
  });

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    themeMode:
        ThemeMode.values.asNameMap()[json['themeMode']] ?? ThemeMode.system,
    autoLockMinutes: json['autoLockMinutes'] as int? ?? 5,
    explorerIntegration: json['explorerIntegration'] as bool? ?? true,
    askToLockOnExit: json['askToLockOnExit'] as bool? ?? true,
    openAfterUnlock: json['openAfterUnlock'] as bool? ?? true,
    keepRunningInTray: json['keepRunningInTray'] as bool? ?? true,
    askToLockWhenClosed: json['askToLockWhenClosed'] as bool? ?? true,
    remindAfterMinutes: json['remindAfterMinutes'] as int? ?? 30,
    relockAfterMinutes: json['relockAfterMinutes'] as int? ?? 0,
    lockItemsWithApp: json['lockItemsWithApp'] as bool? ?? false,
    trayHintShown: json['trayHintShown'] as bool? ?? false,
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

  /// While items are unlocked, closing the window keeps the app running
  /// in the notification area, so reminders and locking keep working.
  final bool keepRunningInTray;

  /// Ask whether to lock an unlocked folder (or drive) again once no
  /// Explorer window shows it.
  final bool askToLockWhenClosed;

  /// Remind about items that stay unlocked this long (0 = never).
  final int remindAfterMinutes;

  /// Lock items again after they have been unlocked this long (0 = never).
  final int relockAfterMinutes;

  /// Lock unlocked items too when the app locks.
  final bool lockItemsWithApp;

  /// Whether the user was told once that closing keeps the app running.
  final bool trayHintShown;

  static const List<int> autoLockChoices = [0, 1, 5, 15, 30, 60];
  static const List<int> unlockedItemChoices = [0, 15, 30, 60, 120];

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? autoLockMinutes,
    bool? explorerIntegration,
    bool? askToLockOnExit,
    bool? openAfterUnlock,
    bool? keepRunningInTray,
    bool? askToLockWhenClosed,
    int? remindAfterMinutes,
    int? relockAfterMinutes,
    bool? lockItemsWithApp,
    bool? trayHintShown,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
    explorerIntegration: explorerIntegration ?? this.explorerIntegration,
    askToLockOnExit: askToLockOnExit ?? this.askToLockOnExit,
    openAfterUnlock: openAfterUnlock ?? this.openAfterUnlock,
    keepRunningInTray: keepRunningInTray ?? this.keepRunningInTray,
    askToLockWhenClosed: askToLockWhenClosed ?? this.askToLockWhenClosed,
    remindAfterMinutes: remindAfterMinutes ?? this.remindAfterMinutes,
    relockAfterMinutes: relockAfterMinutes ?? this.relockAfterMinutes,
    lockItemsWithApp: lockItemsWithApp ?? this.lockItemsWithApp,
    trayHintShown: trayHintShown ?? this.trayHintShown,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'autoLockMinutes': autoLockMinutes,
    'explorerIntegration': explorerIntegration,
    'askToLockOnExit': askToLockOnExit,
    'openAfterUnlock': openAfterUnlock,
    'keepRunningInTray': keepRunningInTray,
    'askToLockWhenClosed': askToLockWhenClosed,
    'remindAfterMinutes': remindAfterMinutes,
    'relockAfterMinutes': relockAfterMinutes,
    'lockItemsWithApp': lockItemsWithApp,
    'trayHintShown': trayHintShown,
  };
}
