import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_tokens.dart';
import '../core/widgets/brand_mark.dart';
import '../features/auth/application/session_controller.dart';
import '../features/auth/presentation/lock_screen.dart';
import '../features/setup/presentation/setup_page.dart';
import '../features/shell/presentation/home_shell.dart';
import 'app_window.dart';

/// Shows onboarding, the lock screen or the main window depending on the
/// session, with a soft cross-fade between them. In the compact window of
/// a request, only its dialog shows.
class AppGate extends ConsumerWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestWindow = ref.watch(
      windowStateProvider.select((state) => state.mode == WindowMode.request),
    );
    // Only the dialog Explorer asked for shows, on this background.
    if (requestWindow) {
      return Scaffold(
        backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
      );
    }
    final status = ref.watch(
      sessionControllerProvider.select((state) => state.status),
    );
    final Widget page = switch (status) {
      SessionStatus.loading => const _Splash(),
      SessionStatus.needsSetup || SessionStatus.onboarding => const SetupPage(),
      SessionStatus.locked => const LockScreen(),
      SessionStatus.unlocked => const _AtLeastAppSize(child: HomeShell()),
    };
    return AnimatedSwitcher(
      duration: AppMotion.slow,
      switchInCurve: AppMotion.curve,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        // Onboarding and setup share one page, so it isn't rebuilt when the
        // master password is created.
        key: ValueKey(
          status == SessionStatus.onboarding
              ? SessionStatus.needsSetup
              : status,
        ),
        child: page,
      ),
    );
  }
}

/// Lays the app out at least at its smallest window size, cut to the space
/// there is: for a moment, the window is compact around it (while it fades
/// out as the app locks, or before the window grows back).
class _AtLeastAppSize extends StatelessWidget {
  const _AtLeastAppSize({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const smallest = NativeAppWindow.appMinimumSize;
      final width = math.max(smallest.width, constraints.maxWidth);
      final height = math.max(smallest.height, constraints.maxHeight);
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: width,
          maxWidth: width,
          minHeight: height,
          maxHeight: height,
          child: child,
        ),
      );
    },
  );
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: BrandMark(size: 64)));
  }
}
