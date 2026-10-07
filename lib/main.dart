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
// SPLASH SCREEN RULE
// The Splash Screen is the app's `home`, so it plays ONLY on a
// fresh launch -- i.e. when the app was completely closed (swiped
// away / killed by the system) and then opened again.
//
// It is NOT shown again when the app is merely sent to the
// background and brought back, when the user navigates between
// screens, or when the theme changes. (The old "away for 3+
// minutes -> push the splash back on top" lifecycle observer was
// removed for exactly that reason.)
// ==========================================================

class ChatbotApp extends StatelessWidget {
  const ChatbotApp({super.key});

  // One shared instance, so rebuilding MaterialApp (theme switch)
  // never hands it a "new" home widget.
  static const Widget _home = SplashScreen();

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
          navigatorObservers: [AiLauncher.routeObserver],

          themeMode: mode,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,

          home: _home,
        );
      },
    );
  }
}