import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/new_password_fields.dart';
import '../../../core/widgets/recovery_key_box.dart';
import '../../../core/widgets/window_title_bar.dart';
import '../../auth/application/session_controller.dart';
import 'widgets/onboarding_hero.dart';

/// First-run onboarding: create the master password, then save the
/// recovery key.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  String? _recoveryKey;

  @override
  Widget build(BuildContext context) {
    final step = _recoveryKey == null ? 0 : 1;
    return Scaffold(
      body: Column(
        children: [
          WindowTitleBar(showControls: ref.watch(nativeWindowProvider)),
          Expanded(
            child: Row(
              children: [
                const Expanded(flex: 5, child: OnboardingHero()),
                Expanded(
                  flex: 6,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _StepIndicator(step: step),
                            const SizedBox(height: AppSpacing.xxl),
                            AnimatedSwitcher(
                              duration: AppMotion.normal,
                              switchInCurve: AppMotion.curve,
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween(
                                        begin: const Offset(0.04, 0),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                              child: _recoveryKey == null
                                  ? _CreatePasswordStep(
                                      key: const ValueKey('password'),
                                      onCreated: (key) =>
                                          setState(() => _recoveryKey = key),
                                    )
                                  : _RecoveryKeyStep(
                                      key: const ValueKey('recovery'),
                                      recoveryKey: _recoveryKey!,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});

  final int step;

  static const List<String> _labels = ['Master password', 'Recovery key'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0)
            Container(
              width: 48,
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              color: i <= step
                  ? context.colors.primary
                  : context.palette.border,
            ),
          Flexible(
            child: _StepDot(index: i, label: _labels[i], state: _stateOf(i)),
          ),
        ],
      ],
    );
  }

  _DotState _stateOf(int index) => index < step
      ? _DotState.done
      : index == step
      ? _DotState.active
      : _DotState.todo;
}

enum _DotState { todo, active, done }

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.index,
    required this.label,
    required this.state,
  });

  final int index;
  final String label;
  final _DotState state;

  @override
  Widget build(BuildContext context) {
    final active = state != _DotState.todo;
    final primary = context.colors.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: AppMotion.normal,
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? primary : Colors.transparent,
            border: Border.all(
              color: active ? primary : context.palette.border,
              width: 1.5,
            ),
          ),
          child: Center(
            child: state == _DotState.done
                ? Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: context.colors.onPrimary,
                  )
                : Text(
                    '${index + 1}',
                    style: context.text.labelMedium?.copyWith(
                      color: active
                          ? context.colors.onPrimary
                          : context.palette.mutedText,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.labelLarge?.copyWith(
              color: active ? null : context.palette.mutedText,
            ),
          ),
        ),
      ],
    );
  }
}

class _CreatePasswordStep extends ConsumerStatefulWidget {
  const _CreatePasswordStep({required this.onCreated, super.key});

  final ValueChanged<String> onCreated;

  @override
  ConsumerState<_CreatePasswordStep> createState() =>
      _CreatePasswordStepState();
}

class _CreatePasswordStepState extends ConsumerState<_CreatePasswordStep> {
  final _form = NewPasswordController();
  bool _busy = false;

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.validate()) return;
    setState(() => _busy = true);
    try {
      final recoveryKey = await ref
          .read(sessionControllerProvider.notifier)
          .setUp(password: _form.password.text, hint: _form.hintText);
      widget.onCreated(recoveryKey);
    } on Object catch (error) {
      showToast(
        'Could not save the master password: $error',
        tone: Tone.danger,
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Create your master password', style: context.text.headlineSmall),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'You\'ll use it to open the app and your locked items. Pick '
          'something long that you don\'t use anywhere else.',
          style: context.text.bodyMedium?.copyWith(
            color: context.palette.mutedText,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        NewPasswordFields(
          controller: _form,
          passwordLabel: 'Master password',
          autofocus: true,
          hintHelper: 'Shown on the lock screen. Never the password itself.',
          onSubmitted: _submit,
        ),
        const SizedBox(height: AppSpacing.xl),
        const InfoBanner(
          tone: Tone.warning,
          icon: Icons.key_rounded,
          message:
              'If you forget this password, only the recovery key you get in '
              'the next step can reset it. Nobody else can recover it.',
        ),
        const SizedBox(height: AppSpacing.xl),
        LoadingButton(
          label: 'Continue',
          icon: Icons.arrow_forward_rounded,
          busy: _busy,
          expand: true,
          onPressed: _submit,
        ),
      ],
    );
  }
}

class _RecoveryKeyStep extends ConsumerStatefulWidget {
  const _RecoveryKeyStep({required this.recoveryKey, super.key});

  final String recoveryKey;

  @override
  ConsumerState<_RecoveryKeyStep> createState() => _RecoveryKeyStepState();
}

class _RecoveryKeyStepState extends ConsumerState<_RecoveryKeyStep> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Save your recovery key', style: context.text.headlineSmall),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'It\'s the only way to reset your master password. Keep it in a '
          'password manager, or print it and store it somewhere safe.',
          style: context.text.bodyMedium?.copyWith(
            color: context.palette.mutedText,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        RecoveryKeyBox(recoveryKey: widget.recoveryKey),
        const SizedBox(height: AppSpacing.lg),
        const InfoBanner(
          message:
              'This key is shown only once. It is not stored on this PC, so '
              'nobody can read it from your files.',
        ),
        const SizedBox(height: AppSpacing.lg),
        CheckboxListTile(
          value: _saved,
          onChanged: (value) => setState(() => _saved = value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(
            'I saved my recovery key in a safe place',
            style: context.text.bodyMedium,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        LoadingButton(
          label: 'Finish setup',
          icon: Icons.check_rounded,
          expand: true,
          onPressed: _saved
              ? () => ref
                    .read(sessionControllerProvider.notifier)
                    .finishOnboarding()
              : null,
        ),
      ],
    );
  }
}
