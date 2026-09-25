import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Collects the heights that [FitsWindow]s below it need, and tells
/// [onHeight] the largest: the compact window takes that height, so a
/// dialog, or the lock screen's form, has no empty space above and below.
class WindowFitController {
  WindowFitController(this.onHeight);

  final void Function(double height) onHeight;

  final Map<Object, double> _heights = {};
  double? _told;

  void _update(Object owner, double height) {
    _heights[owner] = height;
    _tell();
  }

  void _remove(Object owner) {
    if (_heights.remove(owner) != null) _tell();
  }

  void _tell() {
    // With nothing to fit, the window stays as it is.
    if (_heights.isEmpty) return;
    final height = _heights.values.reduce(math.max);
    if (height == _told) return;
    _told = height;
    onHeight(height);
  }
}

/// Makes a [WindowFitController] available to the [FitsWindow]s below.
class WindowFit extends InheritedWidget {
  const WindowFit({required this.controller, required super.child, super.key});

  final WindowFitController controller;

  static WindowFitController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowFit>()?.controller;

  @override
  bool updateShouldNotify(WindowFit oldWidget) =>
      controller != oldWidget.controller;
}

/// Tells the [WindowFit] above how tall the window should be for [child]
/// to show whole: its natural height, however much space it has now, plus
/// [margin] (the space around it, above and below together).
class FitsWindow extends StatefulWidget {
  const FitsWindow({required this.child, this.margin = 0, super.key});

  final Widget child;
  final double margin;

  @override
  State<FitsWindow> createState() => _FitsWindowState();
}

class _FitsWindowState extends State<FitsWindow> {
  WindowFitController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = WindowFit.maybeOf(context);
    if (controller != _controller) {
      _controller?._remove(this);
      _controller = controller;
    }
  }

  @override
  void dispose() {
    _controller?._remove(this);
    super.dispose();
  }

  void _measured(double height) {
    if (!mounted) return;
    _controller?._update(this, (height + widget.margin).ceilToDouble());
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : _MeasureHeight(onHeight: _measured, child: widget.child);
}

class _MeasureHeight extends SingleChildRenderObjectWidget {
  const _MeasureHeight({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasureHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

/// Lays its child out with all the height it wants first, to learn how tall
/// it would be, then in the space there is.
class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _natural;

  /// Much taller than any screen: the child's natural height fits.
  static const double _unbounded = 100000;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      constraints.copyWith(
        minHeight: 0,
        maxHeight: constraints.hasBoundedHeight ? _unbounded : double.infinity,
      ),
      parentUsesSize: true,
    );
    final natural = child.size.height;
    if (natural > constraints.maxHeight || natural < constraints.minHeight) {
      child.layout(constraints, parentUsesSize: true);
    }
    size = constraints.constrain(child.size);
    if (natural != _natural) {
      _natural = natural;
      // Not while laying out: the window changes size in response.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached && _natural == natural) onHeight(natural);
      });
    }
  }
}
