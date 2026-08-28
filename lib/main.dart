import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';
import 'pages/get_started_page.dart';
import 'pages/chat_page.dart';
import 'services/notification_service.dart';

// ==========================================================
// FIREBASE MESSAGING BACKGROUND HANDLER
// ==========================================================

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  debugPrint(
    'Background notification received: ${message.messageId}',
  );

  debugPrint(
    'Background notification data: ${message.data}',
  );
}

// ==========================================================
// SAVE FCM TOKEN
// ==========================================================

Future<void> saveFcmToken() async {
  try {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      debugPrint('No logged-in user. FCM token not saved.');
      return;
    }

    final token = await FirebaseMessaging.instance.getToken();

    if (token == null || token.isEmpty) {
      debugPrint('FCM token is null or empty.');
      return;
    }

    debugPrint('======================================');
    debugPrint('FCM TOKEN: $token');
    debugPrint('======================================');

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(
      {
        'fcmToken': token,
      },
      SetOptions(merge: true),
    );

    debugPrint('FCM token saved to Firestore.');
  } catch (e) {
    debugPrint('Save FCM token error: $e');
  }
}

// ==========================================================
// TOKEN REFRESH
// ==========================================================

void setupTokenRefreshListener() {
  FirebaseMessaging.instance.onTokenRefresh.listen(
    (newToken) async {
      debugPrint('FCM TOKEN UPDATED: $newToken');

      try {
        final user = FirebaseAuth.instance.currentUser;

        if (user == null) {
          debugPrint(
            'No logged-in user. Updated token not saved.',
          );
          return;
        }

        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set(
          {
            'fcmToken': newToken,
          },
          SetOptions(merge: true),
        );

        debugPrint('Updated FCM token saved.');
      } catch (e) {
        debugPrint(
          'FCM token refresh save error: $e',
        );
      }
    },
  );
}

// ==========================================================
// FOREGROUND MESSAGE
// ==========================================================

void setupForegroundMessageHandler() {
  FirebaseMessaging.onMessage.listen(
    (RemoteMessage message) {
      debugPrint(
        '======================================',
      );

      debugPrint(
        'FOREGROUND FCM MESSAGE',
      );

      debugPrint(
        'Message ID: ${message.messageId}',
      );

      debugPrint(
        'Title: ${message.notification?.title}',
      );

      debugPrint(
        'Body: ${message.notification?.body}',
      );

      debugPrint(
        'Data: ${message.data}',
      );

      debugPrint(
        '======================================',
      );
    },
  );
}

// ==========================================================
// NOTIFICATION TAP HANDLER
// ==========================================================

void setupNotificationTapHandler() {
  FirebaseMessaging.onMessageOpenedApp.listen(
    (RemoteMessage message) {
      debugPrint(
        'Notification tapped from background.',
      );

      debugPrint(
        'Notification data: ${message.data}',
      );

      // Later:
      // You can open ChatScreen here using message.data.
    },
  );
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
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ========================================================
  // BACKGROUND FCM HANDLER
  // ========================================================

  FirebaseMessaging.onBackgroundMessage(
    firebaseMessagingBackgroundHandler,
  );

  // ========================================================
  // LOCAL NOTIFICATION INITIALIZATION
  // ========================================================

  await NotificationService.initialize();

  // ========================================================
  // NOTIFICATION PERMISSION
  // ========================================================

  final messaging = FirebaseMessaging.instance;

  final notificationSettings =
      await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  debugPrint(
    'Notification permission: '
    '${notificationSettings.authorizationStatus}',
  );

  // ========================================================
  // GET INITIAL MESSAGE
  // ========================================================
  //
  // This checks whether the app was opened by tapping
  // a notification while the app was completely closed.
  // ========================================================

  final initialMessage =
      await FirebaseMessaging.instance.getInitialMessage();

  if (initialMessage != null) {
    debugPrint(
      'App opened from notification.',
    );

    debugPrint(
      'Initial notification data: '
      '${initialMessage.data}',
    );
  }

  // ========================================================
  // FCM TOKEN
  // ========================================================

  await saveFcmToken();

  // ========================================================
  // TOKEN REFRESH LISTENER
  // ========================================================

  setupTokenRefreshListener();

  // ========================================================
  // FOREGROUND MESSAGE LISTENER
  // ========================================================

  setupForegroundMessageHandler();

  // ========================================================
  // NOTIFICATION TAP LISTENER
  // ========================================================

  setupNotificationTapHandler();

  // ========================================================
  // RUN APP
  // ========================================================
  //
  // IMPORTANT:
  // runApp() ONLY ONCE.
  // ========================================================

  runApp(const chatbotApp());
}

// ==========================================================
// chatbot APP
// ==========================================================

class chatbotApp extends StatelessWidget {
  const chatbotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      title: 'Nexus',

      home: FirebaseAuth.instance.currentUser != null
          ? const ChatPage()
          : const GetStartedPage(),
    );
  }
}