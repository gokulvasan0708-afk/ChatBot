import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_shell.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/user_profile_service.dart';
import '../services/account_switch_service.dart';
import 'nexus_logo.dart';

import '../widgets/top_alert.dart';
class LoginPage extends StatefulWidget {
  final String? accountToLinkUid;
  final bool returnToPreviousPage;

  const LoginPage({
    super.key,
    this.accountToLinkUid,
    this.returnToPreviousPage = false,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with TickerProviderStateMixin {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final FocusNode emailFocusNode = FocusNode();
  final FocusNode passwordFocusNode = FocusNode();

  bool loading = false;
  bool googleLoading = false;
  bool obscurePassword = true;

  // Current Google Sign-In API
  final GoogleSignIn googleSignIn = GoogleSignIn.instance;

  // ==========================================================
  // PAGE TRANSITION / STARFIELD ANIMATION
  // ==========================================================

  late final AnimationController _starController;

  late final AnimationController _slideOutController;
  late final Animation<Offset> _slideOutAnimation;

  @override
  void initState() {
    super.initState();

    // Google Sign-In initialization
    unawaited(_initializeGoogleSignIn());

    // Star animation
    _starController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    // Login page slide-out animation
    _slideOutController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _slideOutAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-1.2, 0),
    ).animate(
      CurvedAnimation(
        parent: _slideOutController,
        curve: Curves.easeInOutCubic,
      ),
    );

    // Smoothly show stars
    _starController.forward();
  }

  Future<void> _initializeGoogleSignIn() async {
    try {
      await googleSignIn.initialize();
    } catch (e) {
      debugPrint('Google Sign-In initialization error: $e');
    }
  }

  // ==========================================================
  // NAVIGATION TRANSITION
  // ==========================================================

  Future<void> _completeLogin() async {
    final loggedIn = FirebaseAuth.instance.currentUser;
    if (loggedIn == null) return;

    if (widget.accountToLinkUid != null &&
        widget.accountToLinkUid!.isNotEmpty &&
        widget.accountToLinkUid != loggedIn.uid) {
      await AccountSwitchService.instance.linkAccounts(
        widget.accountToLinkUid!,
        loggedIn.uid,
      );
    }

    if (!mounted) return;

    if (widget.returnToPreviousPage) {
      Navigator.pop(context);
      return;
    }

    await _goToChatPage();
  }

  Future<void> _goToChatPage() async {
    if (!mounted) return;

    // Smoothly hide stars
    await _starController.reverse();

    if (!mounted) return;

    // Smoothly swipe login page to the left
    await _slideOutController.forward();

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      _createSlideRoute(const HomeShell()),
    );
  }

  Route _createSlideRoute(Widget page) {
    return PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (
        context,
        animation,
        secondaryAnimation,
        child,
      ) {
        final slideIn = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
        );

        return SlideTransition(
          position: slideIn,
          child: child,
        );
      },
    );
  }

  // ==========================================================
  // FIREBASE EMAIL/PASSWORD LOGIN + AUTO CREATE
  // ==========================================================

  Future<void> login() async {
    if (loading) return;

    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      showTopAlert(context, 'Please enter email and password');
      return;
    }

    if (password.length < 6) {
      showTopAlert(context, 'Password must be at least 6 characters');
      return;
    }

    setState(() {
      loading = true;
    });

    try {
      // Adding an account from the switcher: write the new account into
      // the CURRENT account's list now, while it is still signed in
      // (rules only allow a user to write their own switchAccounts).
      if (widget.accountToLinkUid != null &&
          widget.accountToLinkUid!.isNotEmpty) {
        await AccountSwitchService.instance.preLinkByEmail(
          widget.accountToLinkUid!,
          email,
        );
      }

      // =====================================================
      // STEP 1: TRY NORMAL FIREBASE LOGIN
      // =====================================================

      try {
        final credential =
            await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );

        debugPrint('Existing user login');
        debugPrint('UID: ${credential.user?.uid}');

        final user = credential.user;

        if (user != null) {
          await UserProfileService.createUserProfile(
            user: user,
          );
        }

        if (!mounted) return;

        await _completeLogin();

        return;
      } on FirebaseAuthException catch (loginError) {
        debugPrint(
          'Login error: ${loginError.code}',
        );

        // ===================================================
        // STEP 2:
        // IF LOGIN FAILS, TRY CREATING NEW ACCOUNT
        // ===================================================

        try {
          final newUser =
              await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: email,
            password: password,
          );

          debugPrint(
            'New Firebase account created',
          );

          debugPrint(
            'UID: ${newUser.user?.uid}',
          );

          if (newUser.user != null) {
            await UserProfileService.createUserProfile(
              user: newUser.user!,
            );
          }

          if (!mounted) return;

          await _completeLogin();

          return;
        } on FirebaseAuthException catch (createError) {
          debugPrint(
            'Create account error: ${createError.code}',
          );

          if (!mounted) return;

          setState(() {
            loading = false;
          });

          String message = 'Login failed';

          if (createError.code == 'email-already-in-use') {
            message = 'Incorrect email or password';
          } else if (createError.code == 'weak-password') {
            message = 'Password must be at least 6 characters';
          } else if (createError.code == 'invalid-email') {
            message = 'Invalid email address';
          } else {
            message = createError.message ?? 'Login failed';
          }

          showTopAlert(context, message);
        }
      }
    } catch (e) {
      debugPrint(
        'Authentication error: $e',
      );

      if (!mounted) return;

      setState(() {
        loading = false;
      });

      showTopAlert(context, 'Something went wrong. Please try again.');
    }
  }

  // ==========================================================
  // GOOGLE LOGIN
  // ==========================================================

  Future<void> loginWithGoogle() async {
    if (googleLoading) return;

    setState(() {
      googleLoading = true;
    });

    try {
      final GoogleSignInAccount googleUser =
          await googleSignIn.authenticate();

      final GoogleSignInAuthentication googleAuth =
          googleUser.authentication;

      final String? idToken = googleAuth.idToken;

      if (idToken == null) {
        throw Exception(
          'Google ID token is null',
        );
      }

      final OAuthCredential credential =
          GoogleAuthProvider.credential(
        idToken: idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(
        credential,
      );

      // CREATE / GET FIRESTORE USER PROFILE

      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        await UserProfileService.createUserProfile(
          user: user,
        );
      }

      if (!mounted) return;

      await _completeLogin();
    } on GoogleSignInException catch (e) {
      debugPrint(
        'Google Sign-In Error: ${e.code}',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      showTopAlert(context, 'Google Sign-In failed: ${e.code}', isError: true);
    } on FirebaseAuthException catch (e) {
      debugPrint(
        'Firebase Auth Error: ${e.code}',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      showTopAlert(context, 'Firebase login failed: ${e.message ?? e.code}', isError: true);
    } catch (e) {
      debugPrint(
        'Google Sign-In Error: $e',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      showTopAlert(context, 'Google Sign-In failed', isError: true);
    }
  }

  // ==========================================================
  // CREATE GOOGLE ACCOUNT
  // ==========================================================

  Future<void> createGoogleAccount() async {
    final Uri url = Uri.parse(
      'https://accounts.google.com/signup',
    );

    try {
      final bool opened = await launchUrl(
        url,
        mode: LaunchMode.externalApplication,
      );

      if (!opened && mounted) {
        showTopAlert(context, 'Could not open Google account page');
      }
    } catch (e) {
      debugPrint(
        'URL launch error: $e',
      );

      if (!mounted) return;

      showTopAlert(context, 'Could not open Google account page');
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();

    emailFocusNode.dispose();
    passwordFocusNode.dispose();

    _starController.dispose();
    _slideOutController.dispose();

    super.dispose();
  }

  // ==========================================================
  // UI HELPERS
  // ==========================================================

  Widget _buildLogo() {
    // Same brand mark, same gradient, same tagline as the Splash
    // Screen — only the sizing is tuned to sit above the login card.
    return const NexusLogo(
      nSize: 96,
      wordSize: 36,
      letterSpacing: 9,
      taglineSize: 11.5,
    );
  }

  Widget _buildEmailField() {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFF130C07)
            .withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF9C7B54)
              .withValues(alpha: 0.55),
          width: 1,
        ),
      ),
      child: TextField(
        controller: emailController,
        focusNode: emailFocusNode,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
        cursorColor: const Color(0xFFD2B48C),
        onSubmitted: (_) {
          FocusScope.of(context).requestFocus(
            passwordFocusNode,
          );
        },
        decoration: const InputDecoration(
          hintText: 'Email Address',
          hintStyle: TextStyle(
            color: Color(0xFFC2A883),
            fontSize: 16,
          ),
          prefixIcon: Icon(
            Icons.mail_outline_rounded,
            color: Color(0xFFF3E6CE),
            size: 26,
          ),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFF130C07)
            .withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF9C7B54)
              .withValues(alpha: 0.55),
          width: 1,
        ),
      ),
      child: TextField(
        controller: passwordController,
        focusNode: passwordFocusNode,
        obscureText: obscurePassword,
        textInputAction: TextInputAction.done,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
        ),
        cursorColor: const Color(0xFFD2B48C),
        onSubmitted: (_) {
          if (!loading) {
            login();
          }
        },
        decoration: InputDecoration(
          hintText: 'Password',
          hintStyle: const TextStyle(
            color: Color(0xFFC2A883),
            fontSize: 16,
          ),
          prefixIcon: const Icon(
            Icons.lock_outline_rounded,
            color: Color(0xFFF3E6CE),
            size: 26,
          ),
          suffixIcon: IconButton(
            onPressed: () {
              setState(() {
                obscurePassword = !obscurePassword;
              });
            },
            icon: Icon(
              obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: const Color(0xFFE8D4B0),
            ),
            tooltip: obscurePassword
                ? 'Show password'
                : 'Hide password',
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton() {
    return Container(
      width: double.infinity,
      height: 62,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xFFC9A063),
            Color(0xFFB8874A),
            Color(0xFF8B4513),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD2B48C)
                .withValues(alpha: 0.35),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: loading ? null : login,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 25,
                height: 25,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              )
            : const Text(
                'LOGIN',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
      ),
    );
  }

  Widget _buildGoogleButton() {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: OutlinedButton(
        onPressed:
            googleLoading ? null : loginWithGoogle,
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFF0D0805),
          foregroundColor: Colors.white,
          side: const BorderSide(
            color: Color(0xFFD2B48C),
            width: 1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: googleLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: Color(0xFFD2B48C),
                  strokeWidth: 2,
                ),
              )
            : Row(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  // Google style G
                  ShaderMask(
                    shaderCallback: (bounds) {
                      return const LinearGradient(
                        colors: [
                          Color(0xFF4285F4),
                          Color(0xFF34A853),
                          Color(0xFFFBBC05),
                          Color(0xFFEA4335),
                        ],
                      ).createShader(bounds);
                    },
                    child: const Text(
                      'G',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),

                  const SizedBox(width: 18),

                  const Text(
                    'Continue with Google',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFF8A6A45)
                .withValues(alpha: 0.55),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 18,
          ),
          child: Text(
            'OR',
            style: TextStyle(
              color: Color(0xFFE0CFAE),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFF8A6A45)
                .withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }

  Widget _buildCreateAccount() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          "Don't have an account? ",
          style: TextStyle(
            color: Color(0xFFD8C6A5),
            fontSize: 14,
          ),
        ),
        GestureDetector(
          onTap: createGoogleAccount,
          child: const Text(
            'Sign Up',
            style: TextStyle(
              color: Color(0xFFD2B48C),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060402),
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // ==================================================
          // SPACE BACKGROUND
          // ==================================================

          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.2,
                  colors: [
                    Color(0xFF1D1208),
                    Color(0xFF0A0704),
                    Color(0xFF000000),
                  ],
                  stops: [
                    0.0,
                    0.55,
                    1.0,
                  ],
                ),
              ),
            ),
          ),

          // ==================================================
          // STARS
          // ==================================================

          Positioned.fill(
            child: FadeTransition(
              opacity: _starController,
              child: const _LoginStarField(),
            ),
          ),

          // ==================================================
          // BLUE GLOW
          // ==================================================

          Positioned(
            top: -150,
            left: -100,
            child: Container(
              width: 330,
              height: 330,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8B4513)
                        .withValues(alpha: 0.12),
                    blurRadius: 120,
                    spreadRadius: 50,
                  ),
                ],
              ),
            ),
          ),

          // ==================================================
          // PURPLE GLOW
          // ==================================================

          Positioned(
            bottom: -100,
            right: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF8B4513)
                        .withValues(alpha: 0.13),
                    blurRadius: 120,
                    spreadRadius: 40,
                  ),
                ],
              ),
            ),
          ),

          // ==================================================
          // CONTENT
          // ==================================================

          SlideTransition(
            position: _slideOutAnimation,
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 640,
                    ),
                    child: Column(
                      children: [
                        // ==================================================
                        // LOGO
                        // ==================================================

                        _buildLogo(),

                        const SizedBox(height: 30),

                        // ==================================================
                        // LOGIN CARD
                        // ==================================================

                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(
                            22,
                            28,
                            22,
                            28,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0A0704)
                                .withValues(alpha: 0.91),
                            borderRadius:
                                BorderRadius.circular(28),
                            border: Border.all(
                              color: const Color(0xFFE0C29A)
                                  .withValues(alpha: 0.72),
                              width: 1.3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFD2B48C)
                                    .withValues(alpha: 0.18),
                                blurRadius: 30,
                                spreadRadius: 1,
                              ),
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: 0.6),
                                blurRadius: 35,
                                offset: const Offset(0, 18),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              // ==================================================
                              // WELCOME
                              // ==================================================

                              const Text(
                                'WELCOME BACK',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.1,
                                ),
                              ),

                              const SizedBox(height: 10),

                              const Text(
                                'Connect to the next layer of intelligence.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFFE3D2B0),
                                  fontSize: 14,
                                ),
                              ),

                              const SizedBox(height: 28),

                              // ==================================================
                              // EMAIL
                              // ==================================================

                              _buildEmailField(),

                              const SizedBox(height: 14),

                              // ==================================================
                              // PASSWORD
                              // ==================================================

                              _buildPasswordField(),

                              const SizedBox(height: 22),

                              // ==================================================
                              // LOGIN
                              // ==================================================

                              _buildLoginButton(),

                              const SizedBox(height: 18),

                              // ==================================================
                              // GOOGLE
                              // ==================================================

                              _buildGoogleButton(),

                              const SizedBox(height: 24),

                              // ==================================================
                              // OR
                              // ==================================================

                              _buildDivider(),

                              const SizedBox(height: 22),

                              // ==================================================
                              // SIGN UP
                              // ==================================================

                              _buildCreateAccount(),
                            ],
                          ),
                        ),

                        const SizedBox(height: 25),

                        // ==================================================
                        // BOTTOM BRANDING
                        // ==================================================

                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 5,
                              height: 5,
                              decoration:
                                  const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFD2B48C),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'NEXUS AI',
                              style: TextStyle(
                                color: Color(0xFFAB8A63),
                                fontSize: 10,
                                letterSpacing: 2.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 5,
                              height: 5,
                              decoration:
                                  const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFFD2B48C),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================================
// LOGIN PAGE — LIVE STAR FIELD
// ----------------------------------------------------------
// Bright glowing stars that slowly drift around the background
// and continuously fade in and out. This lives on the Login
// Page only — every other screen keeps using CosmicBackground's
// stationary twinkle. Motion + fade are driven by a single
// repeating AnimationController; every star uses an INTEGER
// motion/fade frequency so its sin/cos position lands back on
// its exact starting value every loop — the drift never visibly
// "jumps" or resets when the controller wraps from 1.0 back to 0.0.
// ==========================================================

class _LoginStarSeed {
  final double baseX;
  final double baseY;
  final double driftX;
  final double driftY;
  final int moveFreq;
  final double movePhase;
  final int fadeFreq;
  final double fadePhase;
  final double minAlpha;
  final double maxAlpha;
  final double radius;
  final bool isGold;
  final bool glow;

  const _LoginStarSeed({
    required this.baseX,
    required this.baseY,
    required this.driftX,
    required this.driftY,
    required this.moveFreq,
    required this.movePhase,
    required this.fadeFreq,
    required this.fadePhase,
    required this.minAlpha,
    required this.maxAlpha,
    required this.radius,
    required this.isGold,
    required this.glow,
  });
}

class _LoginStarField extends StatefulWidget {
  const _LoginStarField();

  @override
  State<_LoginStarField> createState() => _LoginStarFieldState();
}

class _LoginStarFieldState extends State<_LoginStarField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_LoginStarSeed> _stars;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 48),
    )..repeat();

    final rnd = Random(2026);

    _stars = List.generate(85, (i) {
      final isGold = i % 4 == 0;
      final isBig = i % 9 == 0;

      return _LoginStarSeed(
        baseX: rnd.nextDouble(),
        baseY: rnd.nextDouble(),
        driftX: 0.015 + rnd.nextDouble() * 0.035,
        driftY: 0.015 + rnd.nextDouble() * 0.035,
        moveFreq: 1 + rnd.nextInt(3),
        movePhase: rnd.nextDouble() * 2 * pi,
        fadeFreq: 2 + rnd.nextInt(4),
        fadePhase: rnd.nextDouble() * 2 * pi,
        minAlpha: 0.08 + rnd.nextDouble() * 0.12,
        maxAlpha: 0.65 + rnd.nextDouble() * 0.35,
        radius: isBig ? 2.0 : 0.9,
        isGold: isGold,
        glow: isBig || isGold,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            size: Size.infinite,
            painter: _LoginStarFieldPainter(
              t: _controller.value,
              stars: _stars,
            ),
          );
        },
      ),
    );
  }
}

class _LoginStarFieldPainter extends CustomPainter {
  final double t;
  final List<_LoginStarSeed> stars;

  _LoginStarFieldPainter({
    required this.t,
    required this.stars,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final corePaint = Paint()..style = PaintingStyle.fill;
    final glowPaint = Paint()..style = PaintingStyle.fill;

    for (final star in stars) {
      final angleMove = (t * star.moveFreq * 2 * pi) + star.movePhase;
      final angleFade = (t * star.fadeFreq * 2 * pi) + star.fadePhase;

      final dx = (star.baseX + star.driftX * sin(angleMove)) * size.width;
      final dy = (star.baseY + star.driftY * cos(angleMove)) * size.height;

      final fadeUnit = (sin(angleFade) + 1) / 2; // 0..1
      final alpha =
          (star.minAlpha + (star.maxAlpha - star.minAlpha) * fadeUnit)
              .clamp(0.0, 1.0);

      final color = star.isGold ? const Color(0xFFFFE9B0) : Colors.white;

      final point = Offset(dx, dy);

      // Soft glow halo behind the bigger / gold stars.
      if (star.glow) {
        glowPaint
          ..color = color.withValues(alpha: alpha * 0.35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, star.radius * 4);
        canvas.drawCircle(point, star.radius * 3.2, glowPaint);
      }

      corePaint.color = color.withValues(alpha: alpha);
      canvas.drawCircle(point, star.radius, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LoginStarFieldPainter oldDelegate) {
    return oldDelegate.t != t;
  }
}