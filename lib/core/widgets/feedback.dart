import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'app_keys.dart';

/// Shows a short floating message at the bottom of the window.
void showToast(
  String message, {
  Tone tone = Tone.neutral,
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = rootMessengerKey.currentState;
  if (messenger == null) return;
  final context = messenger.context;
  final iconColor = switch (tone) {
    Tone.success => const Color(0xFF6EE7B7),
    Tone.warning => const Color(0xFFFCD34D),
    Tone.danger => const Color(0xFFFCA5A5),
    Tone.info || Tone.primary || Tone.accent => const Color(0xFFA5B4FC),
    Tone.neutral => Colors.white70,
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: Duration(seconds: actionLabel == null ? 4 : 7),
        content: Row(
          children: [
            Icon(icon ?? _defaultIcon(tone), color: iconColor, size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                message,
                style: context.text.bodyMedium?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
}

IconData _defaultIcon(Tone tone) => switch (tone) {
  Tone.success => Icons.check_circle_rounded,
  Tone.warning => Icons.warning_amber_rounded,
  Tone.danger => Icons.error_rounded,
  _ => Icons.info_rounded,
};

/// A tinted message box used inside dialogs and pages.
class InfoBanner extends StatelessWidget {
  const InfoBanner({
    required this.message,
    super.key,
    this.tone = Tone.info,
    this.icon,
    this.title,
  });

  final String message;
  final String? title;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.tone(tone);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.foreground.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? _defaultIcon(tone), size: 18, color: colors.foreground),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
                    child: Text(
                      title!,
                      style: context.text.labelLarge?.copyWith(
                        color: colors.foreground,
                      ),
                    ),
                  ),
                Text(
                  message,
                  style: context.text.bodySmall?.copyWith(
                    color: context.colors.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A centered illustration with a message and actions, for empty lists.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.primary;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.background.withValues(alpha: 0.7),
              ),
              child: Icon(icon, size: 44, color: colors.foreground),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title,
              style: context.text.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              style: context.text.bodyMedium?.copyWith(
                color: context.palette.mutedText,
              ),
              textAlign: TextAlign.center,
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xl),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
