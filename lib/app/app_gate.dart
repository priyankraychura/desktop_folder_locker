import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_tokens.dart';
import '../core/widgets/brand_mark.dart';
import '../features/auth/application/session_controller.dart';
import '../features/auth/presentation/lock_screen.dart';
import '../features/setup/presentation/setup_page.dart';
import '../features/shell/presentation/home_shell.dart';

/// Shows onboarding, the lock screen or the main window depending on the
/// session, with a soft cross-fade between them.
class AppGate extends ConsumerWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(
      sessionControllerProvider.select((state) => state.status),
    );
    final Widget page = switch (status) {
      SessionStatus.loading => const _Splash(),
      SessionStatus.needsSetup || SessionStatus.onboarding => const SetupPage(),
      SessionStatus.locked => const LockScreen(),
      SessionStatus.unlocked => const HomeShell(),
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

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: BrandMark(size: 64)));
  }
}
