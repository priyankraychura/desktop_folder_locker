import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auto_lock.dart';

/// Reports mouse and keyboard activity to [AutoLock].
class ActivityDetector extends ConsumerStatefulWidget {
  const ActivityDetector({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ActivityDetector> createState() => _ActivityDetectorState();
}

class _ActivityDetectorState extends ConsumerState<ActivityDetector> {
  late final AutoLock _autoLock = ref.read(autoLockProvider);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _autoLock.touch();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _autoLock.touch(),
      onPointerHover: (_) => _autoLock.touch(),
      onPointerSignal: (_) => _autoLock.touch(),
      child: widget.child,
    );
  }
}
