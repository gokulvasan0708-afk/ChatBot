import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/user_profile_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final FocusNode emailFocusNode = FocusNode();
  final FocusNode passwordFocusNode = FocusNode();

  bool loading = false;
  bool googleLoading = false;
  bool obscurePassword = true;

  // Current Google Sign-In API
  final GoogleSignIn googleSignIn = GoogleSignIn.instance;

  @override
  void initState() {
    super.initState();

    // Google Sign-In must be initialized before using it.
    unawaited(_initializeGoogleSignIn());
  }

  Future<void> _initializeGoogleSignIn() async {
    try {
      await googleSignIn.initialize();
    } catch (e) {
      debugPrint('Google Sign-In initialization error: $e');
    }
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
        content: Text('Please enter email and password'),
      ),
    );
    return;
  }

  if (password.length < 6) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password must be at least 6 characters'),
      ),
    );
    return;
  }

  setState(() {
    loading = true;
  });

  try {
    // =====================================================
    // STEP 1: Try normal Firebase login
    // =====================================================

    try {
      final credential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      debugPrint('Existing user login');
      debugPrint('UID: ${credential.user?.uid}');

      if (credential.user != null) {
  await UserProfileService.createUserProfile(
    user: credential.user!,
  );
}

      // CREATE / GET USER PROFILE
final user = credential.user;

if (user != null) {
  await UserProfileService.createUserProfile(
    user: user,
  );
}

      if (!mounted) return;

      setState(() {
        loading = false;
      });

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );

      return;
    } on FirebaseAuthException catch (loginError) {
      debugPrint('Login error: ${loginError.code}');

      // ===================================================
      // STEP 2:
      // If login fails, try creating a new Firebase account
      // ===================================================

      try {
        final newUser =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        debugPrint('New Firebase account created');
        debugPrint('UID: ${newUser.user?.uid}');

        // ==========================================
        // CREATE FIRESTORE USER PROFILE
        // ==========================================

        if (newUser.user != null) {
          await UserProfileService.createUserProfile(
            user: newUser.user!,
          );
        }

        if (!mounted) return;

        setState(() {
          loading = false;
        });

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const HomePage(),
          ),
        );

        return;
      } on FirebaseAuthException catch (createError) {
        debugPrint('Create account error: ${createError.code}');

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
    debugPrint('Authentication error: $e');

    if (!mounted) return;

    setState(() {
      loading = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Something went wrong. Please try again.'),
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
      throw Exception('Google ID token is null');
    }

    final OAuthCredential credential =
        GoogleAuthProvider.credential(
      idToken: idToken,
    );

    await FirebaseAuth.instance.signInWithCredential(
      credential,
    );

    // ==========================================
    // CREATE / GET FIRESTORE USER PROFILE
    // =========================================

    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      await UserProfileService.createUserProfile(
        user: user,
      );
    }

    if (!mounted) return;

    setState(() {
      googleLoading = false;
    });

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const HomePage(),
      ),
    );
  } on GoogleSignInException catch (e) {
    debugPrint('Google Sign-In Error: ${e.code}');

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
    debugPrint('Firebase Auth Error: ${e.code}');

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
    debugPrint('Google Sign-In Error: $e');

    if (!mounted) return;

    setState(() {
      googleLoading = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Google Sign-In failed'),
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
          content: Text('Could not open Google account page'),
        ),
      );
    }
  } catch (e) {
    debugPrint('URL launch error: $e');

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open Google account page'),
      ),
    );
  }
}

  // ==========================================================
  // UI
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ==================================================
          // BACKGROUND IMAGE
          // ==================================================

          Positioned.fill(
  child: Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF020B18),
          Color(0xFF062B4F),
          Color(0xFF020B18),
        ],
      ),
    ),
  ),
),

          // ==================================================
          // DARK OVERLAY
          // ==================================================

          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.25),
            ),
          ),

          // ==================================================
          // LOGIN CONTENT
          // ==================================================

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(25),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ================================
                    // LOGIN TITLE
                    // ================================

                    const Text(
                      'ChatBot',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),

                    const SizedBox(height: 30),

                    // ================================
                    // GMAIL FIELD
                    // ================================

                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),

                        borderRadius: BorderRadius.circular(20),

                      border: Border.all(
                      color: Colors.lightBlueAccent,
                      width: 1.5,
                      ),

                      boxShadow: [
                    BoxShadow(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.7),
                      blurRadius: 20,
                      spreadRadius: 2,
                      ),
                    ],
                    ),

                    child: Column(
                    children: [
                    TextField(
                      controller: emailController,
                      focusNode: emailFocusNode,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                       FocusScope.of(context).requestFocus(
                          passwordFocusNode,
                        );
                      },
                      decoration: InputDecoration(
                        hintText: 'Gmail ID',
                        border: const OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(
                          Icons.email_outlined,
                        ),
                      ),
                    ),

                    const SizedBox(height: 15),

                    // ================================
                    // PASSWORD FIELD
                    // ================================

                    TextField(
                      controller: passwordController,
                      focusNode: passwordFocusNode,
                      obscureText: obscurePassword,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                      if (!loading) {
                      login();
                       }
                      },
                      decoration: InputDecoration(
                        hintText: 'Password',
                        border: const OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(
                          Icons.lock_outline,
                        ),
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() {
                              obscurePassword =
                                  !obscurePassword;
                            });
                          },
                          icon: Icon(
                            obscurePassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          tooltip: obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ================================
                    // LOGIN BUTTON
                    // ================================

                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          elevation: 5,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(12),
                          ),
                        ),
                        onPressed:
                            loading ? null : login,
                        child: loading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'LOGIN',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 15),

                        ],
  ),
),

                    // ================================
                    // OR
                    // ================================

                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 1,
                            color: Colors.white70,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          child: Text(
                            'OR',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Container(
                            height: 1,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 15),

                    // ================================
                    // GOOGLE LOGIN
                    // ================================

                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: OutlinedButton.icon(
                        onPressed: googleLoading
                            ? null
                            : loginWithGoogle,
                        icon: googleLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .account_circle_outlined,
                                color: Colors.black,
                              ),
                        label: Text(
                          googleLoading
                              ? 'Signing in...'
                              : 'LOGIN WITH GOOGLE',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          side: const BorderSide(
                            color: Colors.white,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ================================
                    // CREATE ACCOUNT
                    // ================================

                    Row(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Create an account? ',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),

                        GestureDetector(
                          onTap: createGoogleAccount,
                          child: const Text(
                            'Create account',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              decoration:
                                  TextDecoration.underline,
                              decorationColor:
                                  Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}