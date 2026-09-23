import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

enum StrengthLevel { empty, weak, fair, good, strong }

/// A simple, dependency-free password strength estimate: length, character
/// variety and a few very common patterns.
abstract final class PasswordStrength {
  static const int minimumLength = 8;

  static final RegExp _common = RegExp(
    r'(password|passw0rd|qwerty|123456|111111|abc123|letmein|iloveyou|admin|welcome)',
    caseSensitive: false,
  );

  static StrengthLevel evaluate(String password) {
    if (password.isEmpty) return StrengthLevel.empty;
    if (password.length < minimumLength ||
        _common.hasMatch(password) ||
        RegExp(r'^(.)\1+$').hasMatch(password)) {
      return StrengthLevel.weak;
    }
    final classes = [
      RegExp('[a-z]'),
      RegExp('[A-Z]'),
      RegExp('[0-9]'),
      RegExp(r'[^a-zA-Z0-9]'),
    ].where((pattern) => pattern.hasMatch(password)).length;

    var score = 0;
    if (password.length >= 12) score++;
    if (password.length >= 16) score++;
    if (classes >= 2) score++;
    if (classes >= 3) score++;
    return switch (score) {
      0 || 1 => StrengthLevel.fair,
      2 => StrengthLevel.good,
      _ => StrengthLevel.strong,
    };
  }

  static bool isAcceptable(String password) => password.length >= minimumLength;
}

/// Four animated bars plus a label describing the strength.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({required this.password, super.key});

  final String password;

  @override
  Widget build(BuildContext context) {
    final level = PasswordStrength.evaluate(password);
    final palette = context.palette;
    final (filled, color, label) = switch (level) {
      StrengthLevel.empty => (
        0,
        palette.border,
        'Use at least ${PasswordStrength.minimumLength} characters',
      ),
      StrengthLevel.weak => (1, palette.danger.foreground, 'Weak'),
      StrengthLevel.fair => (2, palette.warning.foreground, 'Fair'),
      StrengthLevel.good => (3, palette.info.foreground, 'Good'),
      StrengthLevel.strong => (4, palette.success.foreground, 'Strong'),
    };

    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: AppMotion.normal,
              curve: AppMotion.curve,
              height: 5,
              decoration: BoxDecoration(
                color: i < filled
                    ? color
                    : context.colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
          if (i < 3) const SizedBox(width: AppSpacing.xs),
        ],
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: 190,
          child: Text(
            label,
            style: context.text.bodySmall?.copyWith(
              color: level == StrengthLevel.empty ? null : color,
              fontWeight: level == StrengthLevel.empty ? null : FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
