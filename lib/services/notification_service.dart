import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FirebaseMessaging _messaging =
      FirebaseMessaging.instance;

  static final FlutterLocalNotificationsPlugin
      _notifications =
      FlutterLocalNotificationsPlugin();

  // ==========================================================
  // INITIALIZE NOTIFICATION SERVICE
  // ==========================================================

  static Future<void> initialize() async {
    // --------------------------------------------------------
    // ANDROID INITIALIZATION
    // --------------------------------------------------------

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings settings =
        InitializationSettings(
      android: androidSettings,
    );

    await _notifications.initialize(
      settings: settings,
    );

    // --------------------------------------------------------
    // NOTIFICATION PERMISSION
    // --------------------------------------------------------

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // --------------------------------------------------------
    // ANDROID 13+ PERMISSION
    // --------------------------------------------------------

    final androidPlugin =
        _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.requestNotificationsPermission();

    // --------------------------------------------------------
    // NOTIFICATION CHANNEL
    // --------------------------------------------------------

    const AndroidNotificationChannel channel =
        AndroidNotificationChannel(
      'chat_messages',
      'Chat Messages',
      description: 'New chat message notifications',
      importance: Importance.high,
    );

    await androidPlugin?.createNotificationChannel(
      channel,
    );

    // --------------------------------------------------------
    // FIREBASE USER
    // --------------------------------------------------------

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return;
    }

    // --------------------------------------------------------
    // GET FCM TOKEN
    // --------------------------------------------------------

    final token = await _messaging.getToken();

    if (token == null) {
      return;
    }

    print('FCM TOKEN: $token');

    // --------------------------------------------------------
    // SAVE TOKEN TO FIRESTORE
    // --------------------------------------------------------

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set(
      {
        'fcmToken': token,
      },
      SetOptions(merge: true),
    );

    print('FCM token saved');

    // --------------------------------------------------------
    // TOKEN REFRESH
    // --------------------------------------------------------

    _messaging.onTokenRefresh.listen(
      (newToken) async {
        print('FCM TOKEN UPDATED: $newToken');

        final currentUser =
            FirebaseAuth.instance.currentUser;

        if (currentUser == null) {
          return;
        }

        await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .set(
          {
            'fcmToken': newToken,
          },
          SetOptions(merge: true),
        );
      },
    );
  }

  // ==========================================================
  // SHOW LOCAL NOTIFICATION
  // ==========================================================

  static Future<void> showNotification({
    required String title,
    required String body,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription:
          'New chat message notifications',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(
      android: androidDetails,
    );

    await _notifications.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
    );
  }
}