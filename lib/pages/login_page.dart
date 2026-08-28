import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'chat_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/user_profile_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

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
      _createSlideRoute(const ChatPage()),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please enter email and password',
          ),
        ),
      );
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Password must be at least 6 characters',
          ),
        ),
      );
      return;
    }

    setState(() {
      loading = true;
    });

    try {
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

        await _goToChatPage();

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

          await _goToChatPage();

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

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
            ),
          );
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

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Something went wrong. Please try again.',
          ),
        ),
      );
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

      await _goToChatPage();
    } on GoogleSignInException catch (e) {
      debugPrint(
        'Google Sign-In Error: ${e.code}',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Google Sign-In failed: ${e.code}',
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      debugPrint(
        'Firebase Auth Error: ${e.code}',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Firebase login failed: ${e.message ?? e.code}',
          ),
        ),
      );
    } catch (e) {
      debugPrint(
        'Google Sign-In Error: $e',
      );

      if (!mounted) return;

      setState(() {
        googleLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Google Sign-In failed',
          ),
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open Google account page',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'URL launch error: $e',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open Google account page',
          ),
        ),
      );
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
    return Column(
      children: [
        // NEXUS LOGO
        ShaderMask(
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF00E5FF),
                Color(0xFF2196F3),
                Color(0xFF7C4DFF),
              ],
            ).createShader(bounds);
          },
          child: const Text(
            'N',
            style: TextStyle(
              fontSize: 105,
              height: 0.9,
              fontWeight: FontWeight.w900,
              letterSpacing: -8,
              color: Colors.white,
            ),
          ),
        ),

        const SizedBox(height: 2),

        const Text(
          'NEXUS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 42,
            fontWeight: FontWeight.w800,
            letterSpacing: 8,
          ),
        ),

        const SizedBox(height: 8),

        const Text(
          'CONNECT TO THE NEXT LAYER OF INTELLIGENCE',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xFFB9C7DD),
            fontSize: 11,
            letterSpacing: 1.7,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildStarField() {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _StarFieldPainter(),
      ),
    );
  }

  Widget _buildEmailField() {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFF071426)
            .withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF60718B)
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
        cursorColor: const Color(0xFF18C8FF),
        onSubmitted: (_) {
          FocusScope.of(context).requestFocus(
            passwordFocusNode,
          );
        },
        decoration: const InputDecoration(
          hintText: 'Email Address',
          hintStyle: TextStyle(
            color: Color(0xFF8D9BB2),
            fontSize: 16,
          ),
          prefixIcon: Icon(
            Icons.mail_outline_rounded,
            color: Color(0xFFD5DFEC),
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
        color: const Color(0xFF071426)
            .withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF60718B)
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
        cursorColor: const Color(0xFF18C8FF),
        onSubmitted: (_) {
          if (!loading) {
            login();
          }
        },
        decoration: InputDecoration(
          hintText: 'Password',
          hintStyle: const TextStyle(
            color: Color(0xFF8D9BB2),
            fontSize: 16,
          ),
          prefixIcon: const Icon(
            Icons.lock_outline_rounded,
            color: Color(0xFFD5DFEC),
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
              color: const Color(0xFFB9C7DD),
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
            Color(0xFF08A8F5),
            Color(0xFF1685F7),
            Color(0xFF2457E8),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00BFFF)
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
          backgroundColor: const Color(0xFF06111F),
          foregroundColor: Colors.white,
          side: const BorderSide(
            color: Color(0xFF19CFFF),
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
                  color: Color(0xFF18C8FF),
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
            color: const Color(0xFF536278)
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
              color: Color(0xFFB5C2D5),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: const Color(0xFF536278)
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
            color: Color(0xFFAAB8CC),
            fontSize: 14,
          ),
        ),
        GestureDetector(
          onTap: createGoogleAccount,
          child: const Text(
            'Sign Up',
            style: TextStyle(
              color: Color(0xFF1BC9FF),
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
      backgroundColor: const Color(0xFF01030A),
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
                    Color(0xFF071E3A),
                    Color(0xFF020B18),
                    Color(0xFF000108),
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
              child: _buildStarField(),
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
                    color: const Color(0xFF006EFF)
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
                    color: const Color(0xFF7B2FFF)
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
                            color: const Color(0xFF020B16)
                                .withValues(alpha: 0.91),
                            borderRadius:
                                BorderRadius.circular(28),
                            border: Border.all(
                              color: const Color(0xFF25CFFF)
                                  .withValues(alpha: 0.72),
                              width: 1.3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF00BFFF)
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
                                  color: Color(0xFFB5C4D9),
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
                                color: Color(0xFF18C8FF),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'NEXUS AI',
                              style: TextStyle(
                                color: Color(0xFF64758D),
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
                                color: Color(0xFF18C8FF),
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
// STAR FIELD PAINTER
// ==========================================================

class _StarFieldPainter extends CustomPainter {
  final List<Offset> stars = [
    const Offset(0.04, 0.08),
    const Offset(0.12, 0.17),
    const Offset(0.19, 0.06),
    const Offset(0.27, 0.13),
    const Offset(0.34, 0.04),
    const Offset(0.42, 0.19),
    const Offset(0.51, 0.08),
    const Offset(0.59, 0.15),
    const Offset(0.67, 0.05),
    const Offset(0.74, 0.18),
    const Offset(0.83, 0.09),
    const Offset(0.93, 0.16),
    const Offset(0.08, 0.34),
    const Offset(0.22, 0.28),
    const Offset(0.31, 0.39),
    const Offset(0.47, 0.31),
    const Offset(0.57, 0.37),
    const Offset(0.71, 0.30),
    const Offset(0.88, 0.35),
    const Offset(0.96, 0.28),
    const Offset(0.05, 0.53),
    const Offset(0.16, 0.64),
    const Offset(0.28, 0.57),
    const Offset(0.38, 0.69),
    const Offset(0.54, 0.58),
    const Offset(0.65, 0.67),
    const Offset(0.78, 0.56),
    const Offset(0.91, 0.66),
    const Offset(0.14, 0.82),
    const Offset(0.25, 0.74),
    const Offset(0.43, 0.86),
    const Offset(0.58, 0.79),
    const Offset(0.73, 0.88),
    const Offset(0.86, 0.77),
    const Offset(0.96, 0.91),
  ];

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint();

    for (int i = 0; i < stars.length; i++) {
      final point = Offset(
        stars[i].dx * size.width,
        stars[i].dy * size.height,
      );

      final radius =
          i % 7 == 0 ? 1.35 : 0.65;

      paint.color = i % 5 == 0
          ? const Color(0xFF6A8CFF)
              .withValues(alpha: 0.8)
          : Colors.white.withValues(alpha: 0.55);

      canvas.drawCircle(
        point,
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant CustomPainter oldDelegate,
  ) {
    return false;
  }
}