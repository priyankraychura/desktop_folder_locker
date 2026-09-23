import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'icon_tile.dart';

/// A titled card that groups related rows (used by Settings).
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.children,
    super.key,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.xs,
            bottom: AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.titleMedium),
              if (subtitle != null)
                Text(subtitle!, style: context.text.bodySmall),
            ],
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(indent: 64),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One setting: icon, title, description and a control on the right.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.icon,
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.tone = Tone.neutral,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            IconTile(icon: icon, tone: tone, size: 34),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.text.titleSmall),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(subtitle!, style: context.text.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.lg),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact number card, e.g. "3 Locked".
class StatCard extends StatelessWidget {
  const StatCard({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
    this.tone = Tone.primary,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Tone tone;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.tone(tone);
    return AnimatedContainer(
      duration: AppMotion.fast,
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: selected ? colors.foreground : context.palette.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                IconTile(icon: icon, tone: tone),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(value, style: context.text.headlineSmall),
                      Text(label, style: context.text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A selectable card with an icon, title and description (checkbox-like).
class OptionCard extends StatelessWidget {
  const OptionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onChanged,
    super.key,
    this.tone = Tone.primary,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final Tone tone;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.tone(tone);
    return Semantics(
      checked: selected,
      button: true,
      enabled: enabled,
      child: AnimatedOpacity(
        duration: AppMotion.fast,
        opacity: enabled ? 1 : 0.55,
        child: _card(context, colors),
      ),
    );
  }

  Widget _card(BuildContext context, ToneColors colors) => AnimatedContainer(
    duration: AppMotion.fast,
    decoration: BoxDecoration(
      color: selected
          ? colors.background.withValues(alpha: 0.45)
          : context.colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(
        color: selected ? colors.foreground : context.palette.border,
        width: selected ? 1.6 : 1,
      ),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: enabled ? () => onChanged(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon: icon, tone: tone, size: 38),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.text.titleSmall),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(description, style: context.text.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(selected),
                  size: 22,
                  color: selected
                      ? colors.foreground
                      : context.palette.mutedText,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A compact, radio-like tile for a small grid of choices.
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onSelected,
    super.key,
    this.tone = Tone.primary,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onSelected;
  final Tone tone;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.tone(tone);
    return Semantics(
      checked: selected,
      button: true,
      enabled: enabled,
      label: title,
      child: AnimatedOpacity(
        duration: AppMotion.fast,
        opacity: enabled ? 1 : 0.55,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          decoration: BoxDecoration(
            color: selected
                ? colors.background.withValues(alpha: 0.45)
                : context.colors.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: selected ? colors.foreground : context.palette.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: enabled ? onSelected : null,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconTile(icon: icon, tone: tone, size: 32),
                        const Spacer(),
                        Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: selected
                              ? colors.foreground
                              : context.palette.mutedText,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      title,
                      style: context.text.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      subtitle,
                      style: context.text.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
