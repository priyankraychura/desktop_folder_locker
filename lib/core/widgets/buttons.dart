import 'package:flutter/material.dart';

/// A filled button that shows a spinner while [busy] is true.
class LoadingButton extends StatelessWidget {
  const LoadingButton({
    required this.label,
    required this.onPressed,
    super.key,
    this.busy = false,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  /// Stretch to the available width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final foreground = Theme.of(context).colorScheme.onPrimary;
    final leading = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        : icon == null
        ? null
        : Icon(icon, size: 19);
    // While busy the button keeps its color but ignores presses.
    final VoidCallback? handler = busy ? () {} : onPressed;
    final button = leading == null
        ? FilledButton(onPressed: handler, child: Text(label))
        : FilledButton.icon(
            onPressed: handler,
            icon: leading,
            label: Text(label),
          );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
