import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/brand_mark.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/password_field.dart';
import '../../../core/widgets/window_fit.dart';
import '../application/session_controller.dart';
import 'password_dialogs.dart';

/// Asks for the master password to open the app. The window is compact
/// meanwhile (see `compactWindowProvider`), with Windows' title bar: the
/// form is all there is.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen>
    with SingleTickerProviderStateMixin {
  final _password = TextEditingController();
  final _focus = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  String? _error;
  bool _busy = false;
  bool _showHint = false;

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(sessionControllerProvider.notifier)
        .unlock(_password.text);
    if (!mounted || ok) return;
    setState(() {
      _busy = false;
      _error = 'That password is not correct.';
    });
    _password.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _password.text.length,
    );
    _focus.requestFocus();
    await _shake.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final hint = ref.watch(sessionControllerProvider).keystore?.hint;
    return Scaffold(
      body: Stack(
        children: [
          const _Backdrop(),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              // The compact window fits the form.
              child: FitsWindow(
                margin: 2 * AppSpacing.xxl,
                child: AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    // A short, fading side-to-side shake.
                    final t = _shake.value;
                    final dx = math.sin(t * math.pi * 6) * 10 * (1 - t);
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: child,
                    );
                  },
                  child: _form(context, hint),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, String? hint) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Center(child: BrandMark(size: 60)),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Welcome back',
            style: context.text.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Enter your master password to continue.',
            style: context.text.bodyMedium?.copyWith(
              color: context.palette.mutedText,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          PasswordField(
            controller: _password,
            focusNode: _focus,
            label: 'Master password',
            autofocus: true,
            errorText: _error,
            enabled: !_busy,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _unlock(),
          ),
          const SizedBox(height: AppSpacing.lg),
          LoadingButton(
            label: _busy ? 'Unlocking…' : 'Unlock',
            icon: Icons.lock_open_rounded,
            busy: _busy,
            expand: true,
            onPressed: _unlock,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              if (hint != null)
                TextButton(
                  onPressed: () => setState(() => _showHint = !_showHint),
                  child: Text(_showHint ? 'Hide hint' : 'Show hint'),
                ),
              TextButton(
                onPressed: () => showResetPasswordDialog(context),
                child: const Text('Forgot password?'),
              ),
            ],
          ),
          AnimatedSize(
            duration: AppMotion.fast,
            child: _showHint && hint != null
                ? Container(
                    margin: const EdgeInsets.only(top: AppSpacing.xs),
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: context.palette.info.background,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lightbulb_outline_rounded,
                          size: 18,
                          color: context.palette.info.foreground,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(hint, style: context.text.bodySmall),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Soft brand-colored shapes behind the lock form.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.heroGradient;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned(top: -140, left: -120, child: _blob(colors.first, 420)),
            Positioned(
              bottom: -180,
              right: -140,
              child: _blob(colors.last, 480),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blob(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
      ),
    ),
  );
}
