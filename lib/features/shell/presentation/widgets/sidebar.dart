import 'package:flutter/material.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/brand_mark.dart';

/// One destination in the sidebar.
class SidebarDestination {
  const SidebarDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Small count shown on the right (for example unlocked items).
  final int? badge;
}

/// Left navigation: brand, destinations, a status summary and "Lock app".
class Sidebar extends StatelessWidget {
  const Sidebar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.onLockApp,
    super.key,
    this.footer,
  });

  final List<SidebarDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onLockApp;

  /// Shown above the "Lock app" button.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSizes.sidebarWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Row(
                children: [
                  const BrandMark(size: 36),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppInfo.name, style: context.text.titleMedium),
                        Text(
                          'Encrypt · Hide · Protect',
                          style: context.text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            for (var i = 0; i < destinations.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: _NavItem(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelect(i),
                ),
              ),
            const Spacer(),
            if (footer != null) ...[
              footer!,
              const SizedBox(height: AppSpacing.md),
            ],
            Tooltip(
              message: 'Ctrl+L',
              child: OutlinedButton.icon(
                onPressed: onLockApp,
                icon: const Icon(Icons.lock_rounded, size: 18),
                label: const Text('Lock app'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final SidebarDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final primary = context.palette.primary;
    final background = selected
        ? primary.background.withValues(alpha: 0.75)
        : _hovered
        ? context.colors.surfaceContainerHigh.withValues(alpha: 0.7)
        : Colors.transparent;
    final foreground = selected ? primary.foreground : context.colors.onSurface;
    final badge = widget.destination.badge;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Semantics(
        selected: selected,
        button: true,
        label: widget.destination.label,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 3,
                  height: selected ? 16 : 0,
                  margin: const EdgeInsets.only(right: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: primary.foreground,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                Icon(
                  selected
                      ? widget.destination.selectedIcon
                      : widget.destination.icon,
                  size: 20,
                  color: foreground,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    widget.destination.label,
                    style: context.text.labelLarge?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge != null && badge > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: context.palette.warning.background,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      '$badge',
                      style: context.text.labelSmall?.copyWith(
                        color: context.palette.warning.foreground,
                      ),
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
