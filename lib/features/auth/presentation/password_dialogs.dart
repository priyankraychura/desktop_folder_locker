import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/error_text.dart';
import '../../../core/theme/app_palette.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_dialog.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/new_password_fields.dart';
import '../../../core/widgets/password_field.dart';
import '../application/session_controller.dart';

/// "Forgot password?": sets a new master password with the recovery key.
Future<void> showResetPasswordDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ResetPasswordDialog(),
);

/// Changes the master password (requires the current one).
Future<void> showChangePasswordDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ChangePasswordDialog(),
);

void _reportChange(String done, int failed) {
  if (failed == 0) {
    showToast(done, tone: Tone.success);
  } else {
    showToast(
      '$done $failed locked item(s) could not be updated (for example on a '
      'removed drive). They still open with the old password or your '
      'recovery key.',
      tone: Tone.warning,
    );
  }
}

class _ResetPasswordDialog extends ConsumerStatefulWidget {
  const _ResetPasswordDialog();

  @override
  ConsumerState<_ResetPasswordDialog> createState() =>
      _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends ConsumerState<_ResetPasswordDialog> {
  final _recoveryKey = TextEditingController();
  final _form = NewPasswordController();
  String? _keyError;
  bool _busy = false;

  @override
  void dispose() {
    _recoveryKey.dispose();
    _form.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final hasKey = _recoveryKey.text.trim().isNotEmpty;
    setState(() => _keyError = hasKey ? null : 'Enter your recovery key.');
    if (!_form.validate() || !hasKey) return;

    setState(() => _busy = true);
    try {
      final failed = await ref
          .read(sessionControllerProvider.notifier)
          .resetWithRecoveryKey(
            recoveryKey: _recoveryKey.text,
            newPassword: _form.password.text,
            hint: _form.hintText,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      _reportChange('Your master password was reset.', failed);
    } on InvalidRecoveryKeyException catch (error) {
      setState(() {
        _busy = false;
        _keyError = errorText(error);
      });
    } on Object catch (error) {
      setState(() => _busy = false);
      showToast(errorText(error), tone: Tone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      icon: Icons.key_rounded,
      tone: Tone.warning,
      title: 'Reset master password',
      subtitle: 'Use the recovery key you saved during setup.',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _recoveryKey,
            autofocus: true,
            style: context.text.bodyLarge?.copyWith(
              fontFamily: 'Consolas',
              fontFamilyFallback: const ['Cascadia Mono', 'monospace'],
              letterSpacing: 1,
            ),
            decoration: InputDecoration(
              labelText: 'Recovery key',
              hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
              errorText: _keyError,
              prefixIcon: const Icon(Icons.vpn_key_outlined, size: 20),
            ),
            onChanged: (_) {
              if (_keyError != null) setState(() => _keyError = null);
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          NewPasswordFields(controller: _form, onSubmitted: _submit),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        LoadingButton(label: 'Reset password', busy: _busy, onPressed: _submit),
      ],
    );
  }
}

class _ChangePasswordDialog extends ConsumerStatefulWidget {
  const _ChangePasswordDialog();

  @override
  ConsumerState<_ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _form = NewPasswordController();
  String? _currentError;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _form.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.validate()) return;
    setState(() {
      _busy = true;
      _currentError = null;
    });
    final session = ref.read(sessionControllerProvider.notifier);
    try {
      if (!await session.verifyPassword(_current.text)) {
        setState(() {
          _busy = false;
          _currentError = 'That password is not correct.';
        });
        return;
      }
      final failed = await session.changePassword(
        newPassword: _form.password.text,
        hint: _form.hintText,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      _reportChange('Your master password was changed.', failed);
    } on Object catch (error) {
      setState(() => _busy = false);
      showToast(errorText(error), tone: Tone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      icon: Icons.password_rounded,
      title: 'Change master password',
      subtitle: 'Your locked items are updated to the new password.',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PasswordField(
            controller: _current,
            label: 'Current password',
            autofocus: true,
            errorText: _currentError,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: AppSpacing.lg),
          NewPasswordFields(controller: _form, onSubmitted: _submit),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        LoadingButton(
          label: 'Change password',
          busy: _busy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
