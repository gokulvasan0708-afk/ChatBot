import '../features/ai_assistant/ai_launcher.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'get_started_page.dart';
import 'home_shell.dart';
import 'app_theme.dart';
import 'cosmic_background.dart';
import 'nexus_logo.dart';
import '../services/call_service.dart';

// ================================================================
// SPLASH SCREEN
// ----------------------------------------------------------------
// First screen shown when the app launches. Matches the reference
// branding: black cosmic backdrop, glowing "N" mark, NEXUS wordmark
// + tagline, and a thin orbiting loader ring.
//
// After the intro plays it routes automatically:
//   • signed in  -> HomeShell (Chats <-> Me tab shell)
//   • signed out -> GetStartedPage
//
// Wire it up in main.dart as the app's `home`:
//   home: const SplashScreen(),
//
// It plays ONCE per app process: when the app is completely closed
// and opened again. Backgrounding/resuming the app, navigating
// between screens or switching the theme never shows it again
// (see _splashAlreadyPlayed below).
// ================================================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

// True once the intro has played in this app process. A fully closed
// app starts a new process, so this resets to false and the splash
// plays again; anything that happens inside a running app can never
// replay it.
bool _splashAlreadyPlayed = false;

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin, AiLauncherHide {
  late final AnimationController _logoController;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;

  late final AnimationController _ringController;

  Timer? _navigationTimer;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _logoScale = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );

    _logoFade = CurvedAnimation(
      parent: _logoController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );

    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // Already played in this process (e.g. this widget was rebuilt
    // or re-created inside a running app) -> don't replay the intro,
    // go straight to the right page.
    if (_splashAlreadyPlayed) {
      _logoController.value = 1.0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _goToNextScreen());
      return;
    }

    _splashAlreadyPlayed = true;

    _logoController.forward();

    _navigationTimer = Timer(
      const Duration(milliseconds: 2600),
      _goToNextScreen,
    );
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    _logoController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  void _goToNextScreen() {
    if (!mounted) return;

    // If a call is ringing/dialing/connected while the splash is
    // finishing, pushAndRemoveUntil below would wipe the ENTIRE
    // navigator stack -- including the Incoming/Outgoing/Active call
    // screen -- out from under the user before they can even tap
    // Accept. Instead of navigating away, just wait and re-check
    // shortly until the call is resolved.
    if (CallService.instance.isCallInProgress) {
      _navigationTimer = Timer(
        const Duration(milliseconds: 400),
        _goToNextScreen,
      );
      return;
    }

    AiLauncher.ready.value = true; // splash finished -> AI button may show
    final user = FirebaseAuth.instance.currentUser;

    final nextPage = user != null ? const HomeShell() : const GetStartedPage();

    // pushAndRemoveUntil (rather than pushReplacement) so the splash
    // is replaced by a single clean landing page with no stale route
    // left underneath it.
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 700),
        pageBuilder: (context, animation, secondaryAnimation) => nextPage,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBgMid,
      body: CosmicBackground(
        child: Center(
          child: FadeTransition(
            opacity: _logoFade,
            child: ScaleTransition(
              scale: _logoScale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ==============================================
                  // BRAND MARK (shared with Login Page)
                  // ==============================================
                  const NexusLogo(
                    nSize: 84,
                    wordSize: 30,
                    letterSpacing: 10,
                    taglineSize: 11,
                  ),

                  const SizedBox(height: 48),

                  // ==============================================
                  // ORBIT LOADER
                  // ==============================================
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: AnimatedBuilder(
                      animation: _ringController,
                      builder: (context, _) {
                        return CustomPaint(
                          painter: _OrbitRingPainter(
                            progress: _ringController.value,
                          ),
                        );
                      },
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

class _OrbitRingPainter extends CustomPainter {
  final double progress;

  _OrbitRingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = AppColors.saddleBrown.withValues(alpha: 0.25);

    canvas.drawCircle(center, radius, track);

    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 3.14 * 2,
        colors: [
          AppColors.tan.withValues(alpha: 0),
          AppColors.tan,
        ],
        transform: GradientRotation(progress * 2 * 3.14159),
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      progress * 2 * 3.14159,
      3.14159 * 1.4,
      false,
      sweep,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}