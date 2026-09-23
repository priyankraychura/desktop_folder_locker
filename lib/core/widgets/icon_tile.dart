import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// An icon on a tinted rounded square, optionally with a small badge icon
/// in the corner (for example a lock on a folder).
class IconTile extends StatelessWidget {
  const IconTile({
    required this.icon,
    super.key,
    this.tone = Tone.primary,
    this.size = 40,
    this.badge,
    this.badgeTone,
  });

  final IconData icon;
  final Tone tone;
  final double size;
  final IconData? badge;
  final Tone? badgeTone;

  @override
  Widget build(BuildContext context) {
    final colors = context.palette.tone(tone);
    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, color: colors.foreground, size: size * 0.52),
    );
    if (badge == null) return tile;

    final badgeColors = context.palette.tone(badgeTone ?? tone);
    final badgeSize = size * 0.46;
    return SizedBox(
      width: size + badgeSize * 0.3,
      height: size + badgeSize * 0.3,
      child: Stack(
        children: [
          tile,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: BoxDecoration(
                color: badgeColors.foreground,
                shape: BoxShape.circle,
                border: Border.all(
                  color: context.colors.surfaceContainerLowest,
                  width: 2,
                ),
              ),
              child: Icon(badge, size: badgeSize * 0.58, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
