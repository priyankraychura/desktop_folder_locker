import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/window_title_bar.dart';
import '../../auth/application/session_controller.dart';
import '../../items/application/items_controller.dart';
import '../../items/domain/protected_item.dart';
import '../../items/presentation/items_page.dart';
import '../../settings/presentation/settings_page.dart';
import 'widgets/sidebar.dart';

/// The main window once the app is unlocked: sidebar + content panel.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportRecovery());
  }

  /// Tells the user about operations that were finished or rolled back
  /// after an unexpected shutdown.
  void _reportRecovery() {
    final report = ref.read(recoveryReportProvider);
    if (report.isEmpty) return;
    final failed = report.where((outcome) => !outcome.success).length;
    showToast(
      failed == 0
          ? 'Finished ${report.length} operation(s) that were interrupted '
                'last time. Your files are safe.'
          : '$failed interrupted operation(s) could not be finished yet. '
                'They will be retried at the next start.',
      tone: failed == 0 ? Tone.info : Tone.warning,
    );
    ref.read(recoveryReportProvider.notifier).clear();
  }

  void _lockApp() => ref.read(sessionControllerProvider.notifier).lock();

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsControllerProvider).value ?? const [];
    final unlocked = items.where((item) => !item.isProtected).length;
    const pages = [ItemsPage(), SettingsPage()];

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): _lockApp,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            setState(() => _index = 0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            setState(() => _index = 1),
      },
      child: Scaffold(
        body: Column(
          children: [
            WindowTitleBar(showControls: ref.watch(nativeWindowProvider)),
            Expanded(
              child: Row(
                children: [
                  Sidebar(
                    selectedIndex: _index,
                    onSelect: (index) => setState(() => _index = index),
                    onLockApp: _lockApp,
                    destinations: [
                      SidebarDestination(
                        icon: Icons.shield_outlined,
                        selectedIcon: Icons.shield_rounded,
                        label: 'Protected items',
                        badge: unlocked,
                      ),
                      const SidebarDestination(
                        icon: Icons.settings_outlined,
                        selectedIcon: Icons.settings_rounded,
                        label: 'Settings',
                      ),
                    ],
                    footer: _StatusSummary(items: items),
                  ),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: context.palette.content,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(AppRadius.xl),
                        ),
                        border: Border(
                          left: BorderSide(color: context.palette.border),
                          top: BorderSide(color: context.palette.border),
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: AppMotion.normal,
                        switchInCurve: AppMotion.curve,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, 0.015),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_index),
                          child: pages[_index],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact "everything is safe" / "2 items are unlocked" card.
class _StatusSummary extends StatelessWidget {
  const _StatusSummary({required this.items});

  final List<ProtectedItem> items;

  @override
  Widget build(BuildContext context) {
    final unlocked = items.where((item) => !item.isProtected).length;
    final safe = unlocked == 0;
    final colors = safe ? context.palette.success : context.palette.warning;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            safe ? Icons.verified_user_rounded : Icons.lock_open_rounded,
            size: 20,
            color: colors.foreground,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  safe ? 'All protected' : '$unlocked unlocked',
                  style: context.text.labelLarge?.copyWith(
                    color: colors.foreground,
                  ),
                ),
                Text(
                  items.isEmpty
                      ? 'No items yet'
                      : '${items.length} item${items.length == 1 ? '' : 's'} '
                            'in your list',
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
