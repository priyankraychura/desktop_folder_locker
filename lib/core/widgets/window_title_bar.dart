import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// The custom title bar: a drag area plus Windows-style caption buttons.
///
/// With [showControls] off (widget tests, non-desktop), it is a plain bar.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    this.title,
    this.showControls = true,
    this.onClose,
  });

  final Widget? title;
  final bool showControls;

  /// Called by the close button (defaults to closing the window, which the
  /// app intercepts to confirm when items are still unlocked).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final bar = Padding(
      padding: const EdgeInsets.only(left: AppSpacing.lg),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DefaultTextStyle.merge(
          style: context.text.labelMedium?.copyWith(
            color: context.palette.mutedText,
          ),
          child: title ?? const SizedBox.shrink(),
        ),
      ),
    );
    return SizedBox(
      height: AppSizes.titleBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: showControls ? DragToMoveArea(child: bar) : bar),
          if (showControls) _WindowButtons(onClose: onClose),
        ],
      ),
    );
  }
}

class _WindowButtons extends StatefulWidget {
  const _WindowButtons({this.onClose});

  final VoidCallback? onClose;

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(
      windowManager.isMaximized().then((value) {
        if (mounted) setState(() => _maximized = value);
      }, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WindowCaptionButton.minimize(
          brightness: brightness,
          onPressed: windowManager.minimize,
        ),
        if (_maximized)
          WindowCaptionButton.unmaximize(
            brightness: brightness,
            onPressed: windowManager.unmaximize,
          )
        else
          WindowCaptionButton.maximize(
            brightness: brightness,
            onPressed: windowManager.maximize,
          ),
        WindowCaptionButton.close(
          brightness: brightness,
          onPressed: widget.onClose ?? windowManager.close,
        ),
      ],
    );
  }
}
