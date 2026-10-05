import 'package:flutter/material.dart';

import 'app_theme.dart';

// ================================================================
// NEXUS LOGO
// ----------------------------------------------------------------
// Single shared brand mark used everywhere the "Nexus" wordmark
// appears (Splash Screen, Get Started Page, Login Page) so the
// glyph style, gradient and tagline are always pixel-identical —
// only the sizing changes per screen.
//
//   NexusLogo(
//     nSize: 84,
//     wordSize: 30,
//     letterSpacing: 10,
//   )
//
// Every screen using this widget automatically stays in sync if
// the brand gradient/tagline ever needs to change — edit it here
// once instead of in every page.
// ================================================================

class NexusLogo extends StatelessWidget {
  /// Font size of the stylized "N" mark.
  final double nSize;

  /// Font size of the "NEXUS" wordmark.
  final double wordSize;

  /// Letter spacing of the "NEXUS" wordmark.
  final double letterSpacing;

  /// Whether to show the "CONNECT • CREATE • EXPLORE" tagline.
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ==========================================
        // "N" MARK
        // ==========================================
        ShaderMask(
          shaderCallback: (bounds) =>
              AppColors.goldGradient.createShader(bounds),
          child: Text(
            'N',
            style: TextStyle(
              fontSize: nSize,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),

        SizedBox(height: nToWordGap ?? nSize * 0.11),

        // ==========================================
        // "NEXUS" WORDMARK
        // ==========================================
        ShaderMask(
          shaderCallback: (bounds) =>
              AppColors.goldGradient.createShader(bounds),
          child: Text(
            'NEXUS',
            style: TextStyle(
              fontSize: wordSize,
              fontWeight: FontWeight.w700,
              letterSpacing: letterSpacing,
              color: Colors.white,
            ),
          ),
        ),

        if (showTagline) ...[
          SizedBox(height: wordToTaglineGap ?? wordSize * 0.33),
          Text(
            'CONNECT • CREATE • EXPLORE',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.tan.withValues(alpha: 0.75),
              fontSize: taglineSize,
              letterSpacing: 3,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
