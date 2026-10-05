import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';
import 'features/ai_assistant/ai_launcher.dart';
import 'navigation_key.dart';
import 'pages/splash_screen.dart';
import 'pages/app_theme.dart';
import 'services/call_service.dart';
import 'services/notification_service.dart';

// ==========================================================
// BACKGROUND FCM HANDLER
// ==========================================================

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  try {
    await Firebase.initializeApp(
      options:
          DefaultFirebaseOptions.currentPlatform,
    );

    debugPrint(
      '======================================',
    );

    debugPrint(
      'BACKGROUND FCM MESSAGE',
    );

    debugPrint(
      'Message ID: '
      '${message.messageId}',
    );

    debugPrint(
      'Title: '
      '${message.notification?.title}',
    );

    debugPrint(
      'Body: '
      '${message.notification?.body}',
    );

    debugPrint(
      'Data: '
      '${message.data}',
    );

    debugPrint(
      '======================================',
    );
  } catch (e) {
    debugPrint(
      'Background FCM handler error: $e',
    );
  }
}

// ==========================================================
// MAIN
// ==========================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ========================================================
  // FIREBASE INITIALIZATION
  // ========================================================

  await Firebase.initializeApp(
    options:
        DefaultFirebaseOptions.currentPlatform,
  );

  // ========================================================
  // BACKGROUND FCM HANDLER
  // ========================================================

  FirebaseMessaging.onBackgroundMessage(
    firebaseMessagingBackgroundHandler,
  );

  // ========================================================
  // FCM INITIALIZATION
  // ========================================================

  await NotificationService.instance
      .initialize();

  // ========================================================
  // CALL SERVICE INITIALIZATION
  // ----------------------------------------------------------
  // Wires itself to FirebaseAuth's auth-state stream internally, so
  // it starts/stops its real-time incoming-call listener automatically
  // as the signed-in account changes (login, logout, account switch).
  // ========================================================

  CallService.instance.initialize();

  // ========================================================
  // RUN APP
  // ========================================================

  runApp(
    const ChatbotApp(),
  );
}

// ==========================================================
// CHATBOT APP
// ----------------------------------------------------------
// Wrapped in a ValueListenableBuilder that watches
// ThemeController.instance so that switching Dark/Light Mode
// from Me Page -> Settings rebuilds the WHOLE app instantly,
// on every screen, with no extra plumbing required.
//
// Also a WidgetsBindingObserver: whenever the app is fully
// backgrounded (paused) or closed (detached) for 3 minutes or
// more and then reopened, it pushes the Splash Screen back on
// top of whatever screen was showing. The Splash Screen's own
// timer + pushAndRemoveUntil logic (see splash_screen.dart) then
// lands the user back on the correct page (Chats or Get Started)
// with a single clean route, so normal navigation/back-stack
// behavior on a fresh launch is completely unaffected — this only
// adds behavior for the "left the app for a while" case.
// ==========================================================

class ChatbotApp extends StatefulWidget {
  const ChatbotApp({super.key});

  @override
  State<ChatbotApp> createState() => _ChatbotAppState();
}

class _ChatbotAppState extends State<ChatbotApp> with WidgetsBindingObserver {
  static const Duration _splashReentryThreshold = Duration(minutes: 3);

  DateTime? _pausedAt;
  bool _splashReentryPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Remember the FIRST moment we left the foreground — don't let a
      // later paused/detached callback (e.g. transient state changes
      // during a permission dialog) reset the clock.
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;

      if (pausedAt == null) return;

      final awayFor = DateTime.now().difference(pausedAt);

      if (awayFor >= _splashReentryThreshold) {
        _showSplashAgain();
      }
    }
  }

  void _showSplashAgain() {
    if (_splashReentryPending) return;

    // Don't cover an incoming/outgoing/active call screen with the
    // splash re-entry screen -- if a call is ringing or connected right
    // now, leave the navigator alone so the call screen (and its
    // Accept/Decline/Cancel buttons) stays reachable. Once the call
    // resolves, normal navigation continues as usual.
    if (CallService.instance.isCallInProgress) return;

    _splashReentryPending = true;

    // Defer to the next frame so the navigator is guaranteed ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = rootNavigatorKey.currentState;

      if (navigator == null) {
        _splashReentryPending = false;
        return;
      }

      navigator
          .push(
            PageRouteBuilder<void>(
              transitionDuration: const Duration(milliseconds: 400),
              pageBuilder: (context, animation, secondaryAnimation) =>
                  const SplashScreen(),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                return FadeTransition(opacity: animation, child: child);
              },
            ),
          )
          .then((_) {
            _splashReentryPending = false;
          });
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, mode, _) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey,

          debugShowCheckedModeBanner: false,

          title: 'Nexus',
          builder: (context, child) => AiOverlayHost(child: child),

          themeMode: mode,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,

          home: const SplashScreen(),
        );
      },
    );
  }
}
