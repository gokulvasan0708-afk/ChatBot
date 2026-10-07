import 'package:flutter/material.dart';

import 'app_theme.dart';

// ================================================================
// NEXUS LOGO  (purple redesign)
// ----------------------------------------------------------------
// Shared brand mark: gradient "N" (purple -> cyan) + NEXUS wordmark
// + tagline "Connect • Collaborate • Grow".
// Same constructor as before, so Splash / Get Started / Login (and
// any other screen using it) stay in sync from this one file.
// ================================================================

class NexusLogo extends StatelessWidget {
  /// Font size of the stylized "N" mark.
  final double nSize;

  /// Font size of the "NEXUS" wordmark.
  final double wordSize;

  /// Letter spacing of the "NEXUS" wordmark.
  final double letterSpacing;

  /// Whether to show the tagline.
  final bool showTagline;

  /// Font size of the tagline (when shown).
  final double taglineSize;

  /// Gap between the "N" mark and the "NEXUS" wordmark.
  final double? nToWordGap;

  /// Gap between the wordmark and the tagline.
  final double? wordToTaglineGap;

  const NexusLogo({
    super.key,
    this.nSize = 84,
    this.wordSize = 30,
    this.letterSpacing = 10,
    this.showTagline = true,
    this.taglineSize = 11,
    this.nToWordGap,
    this.wordToTaglineGap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ==========================================
        // "N" MARK  (soft glow + purple -> cyan gradient)
        // ==========================================
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: nSize * 0.9,
              height: nSize * 0.9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: nSize * 0.55,
                    spreadRadius: nSize * 0.05,
                  ),
                ],
              ),
            ),
            ShaderMask(
              shaderCallback: (bounds) =>
                  AppColors.brandGradient.createShader(bounds),
              child: Text(
                'N',
                style: TextStyle(
                  fontSize: nSize,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1,
                ),
              ),
            ),
          ],
        ),

        SizedBox(height: nToWordGap ?? nSize * 0.11),

        // ==========================================
        // "NEXUS" WORDMARK
        // ==========================================
        Text(
          'NEXUS',
          style: TextStyle(
            fontSize: wordSize,
            fontWeight: FontWeight.w700,
            letterSpacing: letterSpacing,
            color: c.textPrimary,
          ),
        ),

        if (showTagline) ...[
          SizedBox(height: wordToTaglineGap ?? wordSize * 0.33),
          Text(
            'Connect  •  Collaborate  •  Grow',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.primaryLight,
              fontSize: taglineSize,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
