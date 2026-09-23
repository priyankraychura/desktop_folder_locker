import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'password_field.dart';
import 'password_strength.dart';

/// State and validation for choosing a new password.
class NewPasswordController extends ChangeNotifier {
  final TextEditingController password = TextEditingController();
  final TextEditingController confirm = TextEditingController();
  final TextEditingController hint = TextEditingController();

  String? passwordError;
  String? confirmError;

  String get hintText => hint.text.trim();

  /// Checks length, confirmation and that the hint doesn't reveal the
  /// password. Shows errors and returns `false` when something is wrong.
  bool validate() {
    final value = password.text;
    passwordError = !PasswordStrength.isAcceptable(value)
        ? 'Use at least ${PasswordStrength.minimumLength} characters.'
        : hintText.isNotEmpty &&
              value.toLowerCase().contains(hintText.toLowerCase())
        ? 'The hint must not contain the password.'
        : null;
    confirmError = confirm.text == value ? null : 'The passwords don\'t match.';
    notifyListeners();
    return passwordError == null && confirmError == null;
  }

  void clearErrors() {
    if (passwordError == null && confirmError == null) return;
    passwordError = null;
    confirmError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    hint.dispose();
    super.dispose();
  }
}

/// Password + strength meter + confirmation + optional hint.
class NewPasswordFields extends StatefulWidget {
  const NewPasswordFields({
    required this.controller,
    super.key,
    this.passwordLabel = 'New password',
    this.autofocus = false,
    this.showHint = true,
    this.hintHelper = 'Shown when unlocking. Never the password itself.',
    this.onSubmitted,
  });

  final NewPasswordController controller;
  final String passwordLabel;
  final bool autofocus;
  final bool showHint;
  final String hintHelper;
  final VoidCallback? onSubmitted;

  @override
  State<NewPasswordFields> createState() => _NewPasswordFieldsState();
}

class _NewPasswordFieldsState extends State<NewPasswordFields> {
  final FocusNode _confirmFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
    widget.controller.password.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    widget.controller.password.removeListener(_rebuild);
    _confirmFocus.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PasswordField(
          controller: controller.password,
          label: widget.passwordLabel,
          autofocus: widget.autofocus,
          errorText: controller.passwordError,
          textInputAction: TextInputAction.next,
          onChanged: (_) => controller.clearErrors(),
          onSubmitted: (_) => _confirmFocus.requestFocus(),
        ),
        const SizedBox(height: AppSpacing.md),
        PasswordStrengthMeter(password: controller.password.text),
        const SizedBox(height: AppSpacing.lg),
        PasswordField(
          controller: controller.confirm,
          focusNode: _confirmFocus,
          label: 'Confirm password',
          prefixIcon: Icons.lock_reset_rounded,
          errorText: controller.confirmError,
          textInputAction: widget.showHint
              ? TextInputAction.next
              : TextInputAction.done,
          onChanged: (_) => controller.clearErrors(),
          onSubmitted: (_) => widget.onSubmitted?.call(),
        ),
        if (widget.showHint) ...[
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: controller.hint,
            decoration: InputDecoration(
              labelText: 'Password hint (optional)',
              helperText: widget.hintHelper,
              prefixIcon: const Icon(Icons.lightbulb_outline_rounded, size: 20),
            ),
            onSubmitted: (_) => widget.onSubmitted?.call(),
          ),
        ],
      ],
    );
  }
}
