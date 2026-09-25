import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'icon_tile.dart';
import 'window_fit.dart';

/// Shared layout for every dialog: icon, title, optional subtitle, body
/// and right-aligned actions.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
    this.icon,
    this.tone = Tone.primary,
    this.subtitle,
    this.width = AppSizes.dialogWidth,
  });

  final IconData? icon;
  final Tone tone;
  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    // Header and actions stay visible; only the content scrolls when the
    // window is short. The compact window fits the dialog.
    return Dialog(
      insetPadding: const EdgeInsets.all(_inset),
      child: FitsWindow(
        margin: 2 * _inset,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.xl,
                  AppSpacing.xl,
                  0,
                ),
                child: _header(context),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: content,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  0,
                  AppSpacing.xl,
                  AppSpacing.xl,
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const double _inset = AppSpacing.xl;

  Widget _header(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (icon != null) ...[
        IconTile(icon: icon!, tone: tone, size: 44),
        const SizedBox(width: AppSpacing.lg),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: context.text.titleLarge),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                subtitle!,
                style: context.text.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

/// A message with an OK button, in the app's dialog style.
Future<void> showNoticeDialog(
  BuildContext context, {
  required String title,
  required String message,
  IconData icon = Icons.info_outline_rounded,
  Tone tone = Tone.primary,
}) => showDialog<void>(
  context: context,
  builder: (context) => AppDialog(
    icon: icon,
    tone: tone,
    title: title,
    content: Text(message, style: context.text.bodyMedium),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('OK'),
      ),
    ],
  ),
);

/// A yes/no question in the app's dialog style. Returns `true` when the
/// user confirms.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  IconData icon = Icons.help_outline_rounded,
  Tone tone = Tone.primary,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      icon: icon,
      tone: tone,
      title: title,
      content: Text(message, style: context.text.bodyMedium),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: context.palette.danger.foreground,
                  foregroundColor: context.colors.surface,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
