import 'package:flutter/material.dart';

import '../../../../core/constants/app_info.dart';
import '../../../../core/theme/app_palette.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/brand_mark.dart';

/// The colorful left panel of the onboarding screen.
class OnboardingHero extends StatelessWidget {
  const OnboardingHero({super.key});

  static const List<(IconData, String, String)> _features = [
    (
      Icons.shield_rounded,
      'Real encryption',
      'XChaCha20-Poly1305 and Argon2id, powered by libsodium.',
    ),
    (
      Icons.ads_click_rounded,
      'Works from Explorer',
      'Right-click to lock. Double-click a vault to unlock it.',
    ),
    (
      Icons.cloud_off_rounded,
      'Private and free',
      'No account, no cloud. Your keys never leave this PC.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, 0, AppSpacing.lg),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        gradient: LinearGradient(
          colors: context.palette.heroGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          // Soft decorative circles.
          Positioned(
            top: -80,
            right: -60,
            child: _Glow(size: 260, color: white.withValues(alpha: 0.08)),
          ),
          Positioned(
            bottom: -120,
            left: -80,
            child: _Glow(size: 320, color: white.withValues(alpha: 0.06)),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl + AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const BrandMark(size: 44),
                    const SizedBox(width: AppSpacing.md),
                    Text(
                      AppInfo.name,
                      style: context.text.titleLarge?.copyWith(color: white),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  'Your folders,\nlocked tight.',
                  style: context.text.displaySmall?.copyWith(
                    color: white,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Turn any folder into an encrypted vault that only opens '
                  'with your password, right where it was.',
                  style: context.text.bodyLarge?.copyWith(
                    color: white.withValues(alpha: 0.82),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                for (final (icon, title, text) in _features)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          child: Icon(icon, color: white, size: 19),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: context.text.titleSmall?.copyWith(
                                  color: white,
                                ),
                              ),
                              Text(
                                text,
                                style: context.text.bodySmall?.copyWith(
                                  color: white.withValues(alpha: 0.75),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
