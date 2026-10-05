import 'dart:math';
import 'package:flutter/material.dart';

import 'app_theme.dart';

// ================================================================
// COSMIC BACKGROUND
// ----------------------------------------------------------------
// One shared widget used on every page (Splash, Get Started,
// Login, Chat List, Chat Screen, Me Page, Notifications) so the
// gradient, the floating stars and the fade-in feel identical
// everywhere. Wrap any page body with it:
//
//   Scaffold(
//     backgroundColor: Colors.transparent,
//     body: CosmicBackground(
//       child: ...your existing page content...
//     ),
//   )
//
// It automatically re-colors itself for Dark / Light mode by
// reading `Theme.of(context).brightness`, which is driven app-wide
// by ThemeController (see theme/app_theme.dart).
// ================================================================

class CosmicBackground extends StatefulWidget {
  final Widget child;

  /// Set to false on pages that want the gradient + stars only,
  /// without re-running the fade-in every time (e.g. nested pages
  /// pushed on top of an already-visible background).
  final bool fadeIn;

  /// Extra soft glow blobs (galaxy / nebula accent). Defaults to on.
  final bool showGlow;

  const CosmicBackground({
    super.key,
    required this.child,
    this.fadeIn = true,
    this.showGlow = true,
  });

  @override
  State<CosmicBackground> createState() => _CosmicBackgroundState();
}

class _CosmicBackgroundState extends State<CosmicBackground>
    with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final AnimationController _twinkleController;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _twinkleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);

    if (widget.fadeIn) {
      _fadeController.forward();
    } else {
      _fadeController.value = 1;
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _twinkleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        // ==================================================
        // BASE GRADIENT
        // ==================================================
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.4),
                radius: 1.3,
                colors: [colors.bgTop, colors.bgMid, colors.bgBottom],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),

        // ==================================================
        // SOFT NEBULA / GALAXY GLOW
        // ==================================================
        if (widget.showGlow) ...[
          Positioned(
            top: -140,
            left: -90,
            child: _glowOrb(AppColors.sienna, isDark ? 0.22 : 0.16, 300),
          ),
          Positioned(
            bottom: -120,
            right: -90,
            child: _glowOrb(AppColors.tan, isDark ? 0.20 : 0.18, 280),
          ),
        ],

        // ==================================================
        // FLOATING / TWINKLING STARS
        // ==================================================
        Positioned.fill(
          child: FadeTransition(
            opacity: _fadeController,
            child: AnimatedBuilder(
              animation: _twinkleController,
              builder: (context, _) {
                return CustomPaint(
                  painter: _StarFieldPainter(
                    twinkle: _twinkleController.value,
                    starColor: colors.starColor,
                  ),
                );
              },
            ),
          ),
        ),

        // ==================================================
        // PAGE CONTENT
        // ==================================================
        FadeTransition(
          opacity: _fadeController,
          child: widget.child,
        ),
      ],
    );
  }

  Widget _glowOrb(Color color, double alpha, double size) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: alpha),
              blurRadius: 130,
              spreadRadius: 40,
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// STAR FIELD PAINTER
// ----------------------------------------------------------------
// A fixed, deterministic set of star positions (so it doesn't
// re-shuffle on every rebuild) that gently twinkle in opacity.
// ================================================================

class _StarFieldPainter extends CustomPainter {
  final double twinkle;
  final Color starColor;

  _StarFieldPainter({required this.twinkle, required this.starColor});

  static final List<Offset> _positions = List.generate(60, (i) {
    final rnd = Random(i * 97);
    return Offset(rnd.nextDouble(), rnd.nextDouble());
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();

    for (int i = 0; i < _positions.length; i++) {
      final point = Offset(
        _positions[i].dx * size.width,
        _positions[i].dy * size.height,
      );

      final isGoldStar = i % 5 == 0;
      final isBigStar = i % 7 == 0;

      // Each star twinkles slightly out of phase with its neighbors.
      final phase = (i % 4) / 4;
      final localTwinkle =
          (sin((twinkle + phase) * 2 * pi) + 1) / 2; // 0..1

      final baseAlpha = isGoldStar ? 0.85 : 0.55;
      final alpha = (baseAlpha * (0.5 + 0.5 * localTwinkle)).clamp(0.0, 1.0);

      paint.color = (isGoldStar ? AppColors.glow : starColor)
          .withValues(alpha: alpha);

      canvas.drawCircle(point, isBigStar ? 1.5 : 0.8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarFieldPainter oldDelegate) {
    return oldDelegate.twinkle != twinkle || oldDelegate.starColor != starColor;
  }
}
