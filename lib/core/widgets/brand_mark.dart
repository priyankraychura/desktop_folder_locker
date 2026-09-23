import 'package:flutter/material.dart';

/// The app logo: a lock on a rounded indigo-to-violet gradient.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40, this.elevated = true});

  final double size;

  /// Adds a soft colored glow under the mark.
  final bool elevated;

  static const List<Color> gradient = [Color(0xFF6366F1), Color(0xFF8B5CF6)];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: const LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: gradient.first.withValues(alpha: 0.35),
                  blurRadius: size * 0.4,
                  offset: Offset(0, size * 0.12),
                ),
              ]
            : null,
      ),
      child: Icon(Icons.lock_rounded, color: Colors.white, size: size * 0.54),
    );
  }
}
