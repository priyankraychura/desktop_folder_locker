import 'package:flutter/material.dart';

import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';

/// A rounded rectangle with a dashed border.
class DashedBorder extends StatelessWidget {
  const DashedBorder({
    required this.child,
    super.key,
    this.color,
    this.radius = AppRadius.xl,
  });

  final Widget child;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedRectPainter(
      color: color ?? context.palette.border,
      radius: radius,
    ),
    child: child,
  );
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    const dash = 8.0;
    const gap = 6.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + dash), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color || old.radius != radius;
}

/// Shown over the items page while files are dragged onto the window.
class DropOverlay extends StatelessWidget {
  const DropOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = context.palette.primary;
    return IgnorePointer(
      child: Container(
        color: context.palette.content.withValues(alpha: 0.9),
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: DashedBorder(
          color: primary.foreground,
          child: Container(
            decoration: BoxDecoration(
              color: primary.background.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.move_to_inbox_rounded,
                    size: 56,
                    color: primary.foreground,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Drop to protect', style: context.text.headlineSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Folders and files are added one by one.',
                    style: context.text.bodyMedium?.copyWith(
                      color: context.palette.mutedText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
