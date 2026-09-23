import 'package:flutter/animation.dart';

/// Spacing scale. Use these instead of raw numbers so layouts stay
/// consistent.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radius scale.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double pill = 999;
}

/// Animation timings.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);
  static const Curve curve = Curves.easeOutCubic;
}

/// Fixed layout sizes.
abstract final class AppSizes {
  static const double titleBarHeight = 40;
  static const double sidebarWidth = 248;
  static const double dialogWidth = 480;
  static const double controlHeight = 44;
}
