import 'package:flutter/material.dart';
import 'login_page.dart';

class GetStartedPage extends StatelessWidget {
  const GetStartedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ==========================================
          // BACKGROUND IMAGE
          // ==========================================

          Positioned.fill(
            child: Image.asset(
              'assets/images/nexus_start.jpeg',
              fit: BoxFit.cover,
            ),
          ),

          // ==========================================
          // GET STARTED BUTTON
          // ==========================================

          Positioned(
            left: 55,
            right: 55,
            bottom: 40,
            child: SizedBox(
              height: 55,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  elevation: 5,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),

                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    _createLoginRoute(context),
                  );
                },

                child: const Text(
                  'LET\'S CHAT',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ================================================
  // CUSTOM LOGIN PAGE ANIMATION
  // ================================================

  Route _createLoginRoute(BuildContext context) {
    final RenderBox button =
        context.findRenderObject() as RenderBox;

    final Offset buttonPosition =
        button.localToGlobal(Offset.zero);

    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 900),
      reverseTransitionDuration: const Duration(milliseconds: 600),

      pageBuilder: (
        context,
        animation,
        secondaryAnimation,
      ) {
        return const LoginPage();
      },

      transitionsBuilder: (
        context,
        animation,
        secondaryAnimation,
        child,
      ) {
        // ==========================================
        // START POSITION
        // ==========================================

        final screenSize = MediaQuery.of(context).size;

        final centerX = screenSize.width / 2;
        final centerY = screenSize.height / 2;

        final buttonCenterX =
            buttonPosition.dx + button.size.width / 2;

        final buttonCenterY =
            buttonPosition.dy + button.size.height / 2;

        final dx = buttonCenterX - centerX;
        final dy = buttonCenterY - centerY;

        // ==========================================
        // SCALE ANIMATION
        // ==========================================

        final scaleAnimation = Tween<double>(
          begin: 0.08,
          end: 1.0,
        ).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
        );

        // ==========================================
        // FADE ANIMATION
        // ==========================================

        final fadeAnimation = Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(
          CurvedAnimation(
            parent: animation,
            curve: const Interval(
              0.15,
              1.0,
              curve: Curves.easeOut,
            ),
          ),
        );

        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            return Stack(
              children: [
                // ====================================
                // LOGIN PAGE
                // ====================================

                Transform.translate(
                  offset: Offset(
                    dx * (1 - animation.value),
                    dy * (1 - animation.value),
                  ),
                  child: Transform.scale(
                    scale: scaleAnimation.value,
                    alignment: Alignment.center,
                    child: Opacity(
                      opacity: fadeAnimation.value,
                      child: child,
                    ),
                  ),
                ),
              ],
            );
          },
          child: child,
        );
      },
    );
  }
}