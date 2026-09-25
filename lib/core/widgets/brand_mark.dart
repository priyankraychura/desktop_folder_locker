import 'package:flutter/material.dart';

/// The app logo, as the app icon draws it (`tool/generate_icons.py`): an
/// indigo-to-violet folder with a padlock badge.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40, this.elevated = true});

  final double size;

  /// Adds a soft colored glow under the folder.
  final bool elevated;

  static const List<Color> gradient = [Color(0xFF6366F1), Color(0xFF8B5CF6)];

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _BrandPainter(elevated: elevated)),
  );
}

/// Draws on the generator's 1024-unit canvas, scaled to the size.
class _BrandPainter extends CustomPainter {
  const _BrandPainter({required this.elevated});

  final bool elevated;

  static const double _canvas = 1024;
  static const Color _deep = Color(0xFF4338CA);

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / _canvas);

    final folder = Path()
      ..addRRect(_rrect(70, 170, 470, 360, 70))
      ..addRRect(_rrect(70, 250, _canvas - 70, _canvas - 150, 90));
    if (elevated) {
      canvas.drawPath(
        folder.shift(const Offset(0, 0.12 * _canvas)),
        Paint()
          ..color = BrandMark.gradient.first.withValues(alpha: 0.35)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            Shadow.convertRadiusToSigma(0.4 * _canvas),
          ),
      );
    }
    canvas
      ..drawPath(
        folder,
        Paint()
          ..shader = const LinearGradient(
            colors: BrandMark.gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(const Rect.fromLTWH(0, 0, _canvas, _canvas)),
      )
      // Lighter front panel for depth.
      ..drawRRect(
        _rrect(70, 330, _canvas - 70, _canvas - 150, 90),
        Paint()..color = Colors.white.withValues(alpha: 38 / 255),
      );

    // Padlock badge.
    const center = Offset(_canvas - 250, _canvas - 250);
    const radius = 210.0;
    canvas
      ..drawCircle(center, radius + 24, Paint()..color = Colors.white)
      ..drawCircle(center, radius, Paint()..color = _deep);
    _padlock(canvas, center.dx, center.dy - 150, 200);
    canvas.restore();
  }

  /// A rounded padlock: shackle (arc) on top of a rounded body, with a
  /// keyhole.
  void _padlock(Canvas canvas, double centerX, double top, double width) {
    final bodyHeight = width * 0.78;
    final shackleWidth = width * 0.62;
    final thickness = width * 0.13;
    final bodyTop = top + width * 0.42;
    final white = Paint()..color = Colors.white;
    // The stroke is inside the shackle's box, as the generator draws it.
    canvas
      ..drawRRect(
        _rrect(
          centerX - shackleWidth / 2,
          top,
          centerX + shackleWidth / 2,
          bodyTop + thickness * 2,
          shackleWidth / 2,
        ).deflate(thickness / 2),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness,
      )
      ..drawRRect(
        _rrect(
          centerX - width / 2,
          bodyTop,
          centerX + width / 2,
          bodyTop + bodyHeight,
          width * 0.16,
        ),
        white,
      );
    final hole = width * 0.12;
    final holeY = bodyTop + bodyHeight * 0.45;
    final deep = Paint()..color = _deep;
    canvas
      ..drawCircle(Offset(centerX, holeY), hole, deep)
      ..drawRRect(
        _rrect(
          centerX - hole * 0.45,
          holeY,
          centerX + hole * 0.45,
          holeY + hole * 2.3,
          hole * 0.3,
        ),
        deep,
      );
  }

  static RRect _rrect(
    double left,
    double top,
    double right,
    double bottom,
    double radius,
  ) => RRect.fromLTRBR(left, top, right, bottom, Radius.circular(radius));

  @override
  bool shouldRepaint(_BrandPainter oldDelegate) =>
      elevated != oldDelegate.elevated;
}
