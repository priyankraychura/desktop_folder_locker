import 'package:flutter/material.dart';

/// Semantic colors used for badges, icons and banners.
enum Tone { primary, success, warning, danger, info, accent, neutral }

/// Foreground/background pair for one [Tone].
@immutable
class ToneColors {
  const ToneColors(this.foreground, this.background);

  final Color foreground;
  final Color background;

  static ToneColors lerp(ToneColors a, ToneColors b, double t) => ToneColors(
    Color.lerp(a.foreground, b.foreground, t)!,
    Color.lerp(a.background, b.background, t)!,
  );
}

/// App-specific colors that Material's [ColorScheme] doesn't cover.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.windowBackground,
    required this.sidebar,
    required this.content,
    required this.border,
    required this.mutedText,
    required this.primary,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.accent,
    required this.neutral,
    required this.heroGradient,
  });

  factory AppPalette.light() => const AppPalette(
    windowBackground: Color(0xFFF1F3F9),
    sidebar: Color(0xFFF1F3F9),
    content: Color(0xFFFBFCFE),
    border: Color(0xFFE2E5EE),
    mutedText: Color(0xFF636B80),
    primary: ToneColors(Color(0xFF4338CA), Color(0xFFE6E5FF)),
    success: ToneColors(Color(0xFF047857), Color(0xFFD7F5E8)),
    warning: ToneColors(Color(0xFFB45309), Color(0xFFFDF0D2)),
    danger: ToneColors(Color(0xFFC0262D), Color(0xFFFDE3E3)),
    info: ToneColors(Color(0xFF1D5FD6), Color(0xFFE0EBFE)),
    accent: ToneColors(Color(0xFF7C3AED), Color(0xFFEFE7FE)),
    neutral: ToneColors(Color(0xFF4B5367), Color(0xFFE9ECF3)),
    heroGradient: [Color(0xFF4338CA), Color(0xFF6D28D9), Color(0xFF9333EA)],
  );

  factory AppPalette.dark() => const AppPalette(
    windowBackground: Color(0xFF0D0F15),
    sidebar: Color(0xFF0D0F15),
    content: Color(0xFF141720),
    border: Color(0xFF262B3A),
    mutedText: Color(0xFF98A1B6),
    primary: ToneColors(Color(0xFFB3B5FF), Color(0xFF272560)),
    success: ToneColors(Color(0xFF5EE0AE), Color(0xFF10301F)),
    warning: ToneColors(Color(0xFFFBC455), Color(0xFF362809)),
    danger: ToneColors(Color(0xFFFF9C9C), Color(0xFF3A1417)),
    info: ToneColors(Color(0xFF8DB6FF), Color(0xFF142440)),
    accent: ToneColors(Color(0xFFC8B2FF), Color(0xFF261A45)),
    neutral: ToneColors(Color(0xFFB7BFD0), Color(0xFF222634)),
    heroGradient: [Color(0xFF312E81), Color(0xFF4C1D95), Color(0xFF6B21A8)],
  );

  /// Behind the title bar and sidebar.
  final Color windowBackground;
  final Color sidebar;

  /// The main content panel.
  final Color content;
  final Color border;
  final Color mutedText;
  final ToneColors primary;
  final ToneColors success;
  final ToneColors warning;
  final ToneColors danger;
  final ToneColors info;
  final ToneColors accent;
  final ToneColors neutral;

  /// Colors of the onboarding hero panel.
  final List<Color> heroGradient;

  ToneColors tone(Tone tone) => switch (tone) {
    Tone.primary => primary,
    Tone.success => success,
    Tone.warning => warning,
    Tone.danger => danger,
    Tone.info => info,
    Tone.accent => accent,
    Tone.neutral => neutral,
  };

  @override
  AppPalette copyWith({Color? windowBackground, Color? content}) => AppPalette(
    windowBackground: windowBackground ?? this.windowBackground,
    sidebar: sidebar,
    content: content ?? this.content,
    border: border,
    mutedText: mutedText,
    primary: primary,
    success: success,
    warning: warning,
    danger: danger,
    info: info,
    accent: accent,
    neutral: neutral,
    heroGradient: heroGradient,
  );

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      windowBackground: Color.lerp(
        windowBackground,
        other.windowBackground,
        t,
      )!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      content: Color.lerp(content, other.content, t)!,
      border: Color.lerp(border, other.border, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      primary: ToneColors.lerp(primary, other.primary, t),
      success: ToneColors.lerp(success, other.success, t),
      warning: ToneColors.lerp(warning, other.warning, t),
      danger: ToneColors.lerp(danger, other.danger, t),
      info: ToneColors.lerp(info, other.info, t),
      accent: ToneColors.lerp(accent, other.accent, t),
      neutral: ToneColors.lerp(neutral, other.neutral, t),
      heroGradient: [
        for (var i = 0; i < heroGradient.length; i++)
          Color.lerp(heroGradient[i], other.heroGradient[i], t)!,
      ],
    );
  }
}

/// Short accessors for theme values.
extension ThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get text => Theme.of(this).textTheme;
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}
