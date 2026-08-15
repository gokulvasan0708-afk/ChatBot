import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

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
  // NORMAL LOGIN
  // ==========================================================

  Future<void> login() async {
    // ===== TEMPORARY LOGIN =====

    if (emailController.text.trim() == 'abc@gmail.com' &&
        passwordController.text == '123456') {
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );

      return;
    }

    // Wrong credentials
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invalid email or password'),
      ),
    );

    // ===== END TEMPORARY LOGIN =====

    /*
    // BACKEND LOGIN - USE THIS LATER

    setState(() {
      loading = true;
    });

    final result = await ApiService.login(
      emailController.text.trim(),
      passwordController.text,
    );

    setState(() {
      loading = false;
    });

    if (result['success'] == true) {
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const HomePage(),
        ),
      );
    } else {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] ?? 'Login failed'),
        ),
      );
    }
    */
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
      // Start Google account selection
      final GoogleSignInAccount? account =
          await googleSignIn.authenticate();

      if (!mounted) return;

      // User cancelled Google account selection
      if (account == null) {
        setState(() {
          googleLoading = false;
        });
        return;
      }

      debugPrint('Google Account: ${account.email}');
      debugPrint('Google Name: ${account.displayName}');

      // Login successful
      setState(() {
        googleLoading = false;
      });

      if (!mounted) return;

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

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();

    super.dispose();
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
            child: Image.asset(
              'assets/images/login_bg.jpeg',
              fit: BoxFit.cover,
            ),
          ),

          // ==================================================
          // DARK OVERLAY
          // ==================================================

          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.25),
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
                      'Login',
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

                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Gmail ID',
                        floatingLabelBehavior:
                            FloatingLabelBehavior.auto,
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
                      obscureText: obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        floatingLabelBehavior:
                            FloatingLabelBehavior.auto,
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
                      height: 50,
                      child: ElevatedButton(
                        onPressed:
                            loading ? null : login,
                        child: loading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(),
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
                      height: 50,
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