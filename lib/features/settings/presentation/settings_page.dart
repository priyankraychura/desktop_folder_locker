import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/error_text.dart';
import '../../../core/constants/app_info.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/cards.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../platform/explorer_integration.dart';
import '../../../platform/shell_actions.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/presentation/password_dialogs.dart';
import '../application/settings_controller.dart';
import '../domain/app_settings.dart';

/// Preferences, security options and app information.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  static String _autoLockLabel(int minutes) => switch (minutes) {
    0 => 'Never',
    1 => 'After 1 minute',
    60 => 'After 1 hour',
    _ => 'After $minutes minutes',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final keystore = ref.watch(sessionControllerProvider).keystore;

    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error) {
        showToast(errorText(error), tone: Tone.danger);
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xxl,
      ),
      children: [
        Text('Settings', style: context.text.headlineMedium),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          'Appearance, security and Windows integration.',
          style: context.text.bodyMedium?.copyWith(
            color: context.palette.mutedText,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          title: 'Appearance',
          children: [
            SettingsRow(
              icon: Icons.palette_outlined,
              tone: Tone.accent,
              title: 'Theme',
              subtitle: 'Follow Windows, or always use light or dark.',
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_rounded, size: 18),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_rounded, size: 18),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_rounded, size: 18),
                    label: Text('Dark'),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (value) =>
                    unawaited(controller.setThemeMode(value.first)),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          title: 'Security',
          children: [
            SettingsRow(
              icon: Icons.timer_outlined,
              tone: Tone.info,
              title: 'Lock the app automatically',
              subtitle:
                  'Locks after a period without mouse or keyboard activity. '
                  'Running operations are never interrupted.',
              trailing: DropdownMenu<int>(
                width: 190,
                initialSelection: settings.autoLockMinutes,
                dropdownMenuEntries: [
                  for (final minutes in AppSettings.autoLockChoices)
                    DropdownMenuEntry(
                      value: minutes,
                      label: _autoLockLabel(minutes),
                    ),
                ],
                onSelected: (minutes) {
                  if (minutes != null) {
                    unawaited(controller.setAutoLockMinutes(minutes));
                  }
                },
              ),
            ),
            SettingsRow(
              icon: Icons.password_rounded,
              tone: Tone.primary,
              title: 'Master password',
              subtitle: keystore == null
                  ? null
                  : 'Last changed ${Format.relative(keystore.passwordChangedAt)}.',
              trailing: OutlinedButton(
                onPressed: () => showChangePasswordDialog(context),
                child: const Text('Change…'),
              ),
            ),
            SettingsRow(
              icon: Icons.key_rounded,
              tone: Tone.success,
              title: 'Recovery key',
              subtitle: keystore == null
                  ? null
                  : 'Created ${Format.relative(keystore.createdAt)}. It can '
                        'reset your master password and open any item. '
                        'Keep it somewhere safe.',
              trailing: const StatusBadge(
                tone: Tone.success,
                icon: Icons.check_rounded,
                label: 'Active',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          title: 'Windows integration',
          children: [
            SettingsRow(
              icon: Icons.ads_click_rounded,
              tone: Tone.primary,
              title: 'Explorer integration',
              subtitle: ExplorerIntegration.isSupported
                  ? 'Vaults show a lock icon and open the password dialog on '
                        'double-click. Adds “Lock with ${AppInfo.name}” to '
                        'the right-click menu (under “Show more options” on '
                        'Windows 11).'
                  : 'Only available on Windows.',
              trailing: Switch(
                value:
                    ExplorerIntegration.isSupported &&
                    settings.explorerIntegration,
                onChanged: ExplorerIntegration.isSupported
                    ? (value) => guarded(
                        () => controller.setExplorerIntegration(value),
                      )
                    : null,
              ),
            ),
            SettingsRow(
              icon: Icons.folder_open_rounded,
              tone: Tone.info,
              title: 'Open items after unlocking',
              subtitle: 'Show the item in Explorer as soon as it is unlocked.',
              trailing: Switch(
                value: settings.openAfterUnlock,
                onChanged: (value) =>
                    unawaited(controller.setOpenAfterUnlock(value)),
              ),
            ),
            SettingsRow(
              icon: Icons.exit_to_app_rounded,
              tone: Tone.warning,
              title: 'Remind me when closing',
              subtitle: 'Offer to lock unlocked items when the app closes.',
              trailing: Switch(
                value: settings.askToLockOnExit,
                onChanged: (value) =>
                    unawaited(controller.setAskToLockOnExit(value)),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          title: 'About',
          children: [
            const SettingsRow(
              icon: Icons.info_outline_rounded,
              title: '${AppInfo.name} ${AppInfo.version}',
              subtitle:
                  'Encryption: XChaCha20-Poly1305 · keys from Argon2id · '
                  'libsodium',
            ),
            SettingsRow(
              icon: Icons.code_rounded,
              title: 'Source code',
              subtitle: AppInfo.repositoryUrl,
              trailing: const Icon(Icons.open_in_new_rounded, size: 18),
              onTap: () =>
                  unawaited(ShellActions.openUrl(AppInfo.repositoryUrl)),
            ),
            SettingsRow(
              icon: Icons.description_outlined,
              title: 'Open-source licenses',
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: AppInfo.version,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
