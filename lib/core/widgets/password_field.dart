import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// A password input with a show/hide toggle and a Caps Lock warning.
class PasswordField extends StatefulWidget {
  const PasswordField({
    required this.controller,
    super.key,
    this.label,
    this.hint,
    this.errorText,
    this.autofocus = false,
    this.focusNode,
    this.textInputAction = TextInputAction.done,
    this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.prefixIcon = Icons.lock_outline_rounded,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final String? errorText;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final IconData prefixIcon;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;
  bool _capsLock = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _capsLock = _isCapsLockOn();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  static bool _isCapsLockOn() => HardwareKeyboard.instance.lockModesEnabled
      .contains(KeyboardLockMode.capsLock);

  bool _onKey(KeyEvent event) {
    final capsLock = _isCapsLockOn();
    if (capsLock != _capsLock && mounted) setState(() => _capsLock = capsLock);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: widget.enabled,
          obscureText: _obscured,
          enableSuggestions: false,
          autocorrect: false,
          textInputAction: widget.textInputAction,
          onSubmitted: widget.onSubmitted,
          onChanged: widget.onChanged,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            errorText: widget.errorText,
            prefixIcon: Icon(widget.prefixIcon, size: 20),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: IconButton(
                tooltip: _obscured ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMotion.fast,
          child: _capsLock
              ? Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.xs,
                    left: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.keyboard_capslock_rounded,
                        size: 15,
                        color: context.palette.warning.foreground,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Caps Lock is on',
                        style: context.text.bodySmall?.copyWith(
                          color: context.palette.warning.foreground,
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
