import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class NotificationService {
  NotificationService._();

  static final NotificationService instance =
      NotificationService._();

  final FirebaseMessaging _messaging =
      FirebaseMessaging.instance;

  final FirebaseFirestore _firestore =
      FirebaseFirestore.instance;

  final FirebaseAuth _auth =
      FirebaseAuth.instance;

  StreamSubscription<String>? _tokenRefreshSubscription;

  StreamSubscription<RemoteMessage>? _foregroundSubscription;

  StreamSubscription<RemoteMessage>? _openedSubscription;

  // ==========================================================
  // CLOUDFLARE WORKER
  // ==========================================================

  static const String workerUrl =
      'https://chatbot-worker.gokulmi56cro.workers.dev';

  // ==========================================================
  // WIND DOWN MODE
  // ----------------------------------------------------------
  // users/{uid} may carry:
  //   windDownEnabled     (bool)
  //   windDownStartHour   (int, 0-23)
  //   windDownStartMinute (int, 0-59)
  // Set from Settings -> Nexus Notify -> "Wind Down mode"
  // (nexus_notify_settings_page.dart). While enabled, the window
  // runs every night from the saved start time to a FIXED 5:00 AM
  // -- checked fresh right before every push send below, so it
  // repeats automatically every day with no re-arming needed; it
  // only stops once the user flips the Switch back OFF themselves.
  // NOTE: the Cloudflare Worker is only ever given a bare fcmToken
  // (no receiver uid), so this check has to happen here, client
  // side, using the receiver's users/{uid} doc we already fetch
  // just below for the token itself.
  // ==========================================================

  static const int _windDownEndHour = 5; // fixed 5:00 AM, not user-editable

  bool _isReceiverInWindDown(Map<String, dynamic>? data) {
    if (data == null) return false;

    // Master "Notify" switch (Settings -> Nexus Notify -> "Notify")
    // gates Wind Down mode too -- turning Notify off turns everything
    // under it off, including the actual push-silencing below, not
    // just the on-screen heads-up bar.
    final notifyEnabled = data['notifyEnabled'] as bool? ?? true;
    if (!notifyEnabled) return false;

    final enabled = data['windDownEnabled'] as bool? ?? false;
    if (!enabled) return false;

    final startHour = (data['windDownStartHour'] as num?)?.toInt();
    if (startHour == null) return false;
    final startMinute = (data['windDownStartMinute'] as num?)?.toInt() ?? 0;

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = startHour * 60 + startMinute;
    const endMinutes = _windDownEndHour * 60;

    if (startMinutes == endMinutes) {
      // Degenerate case (start time set to exactly 5:00 AM) -- treat
      // as always-on rather than a zero-length window.
      return true;
    }

    if (startMinutes > endMinutes) {
      // Normal case: window crosses midnight, e.g. 22:00 -> 05:00.
      return nowMinutes >= startMinutes || nowMinutes < endMinutes;
    }

    // Start time is itself between midnight and 5 AM, e.g. 02:00 -> 05:00.
    return nowMinutes >= startMinutes && nowMinutes < endMinutes;
  }

  // ==========================================================
  // INITIALIZE
  // ==========================================================

  Future<void> initialize() async {
    try {
      debugPrint(
        '======================================',
      );

      debugPrint(
        'INITIALIZING FCM',
      );

      debugPrint(
        '======================================',
      );

      // ======================================================
      // NOTIFICATION PERMISSION
      // ======================================================

      final settings =
          await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      debugPrint(
        'Notification permission: '
        '${settings.authorizationStatus}',
      );

      // ======================================================
      // ANDROID NOTIFICATION SETTINGS
      // ======================================================

      await _messaging
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // ======================================================
      // GET CURRENT FCM TOKEN
      // ======================================================

      final token =
          await _messaging.getToken();

      debugPrint(
        '======================================',
      );

      debugPrint(
        'CURRENT FCM TOKEN',
      );

      debugPrint(
        '$token',
      );

      debugPrint(
        '======================================',
      );

      if (token != null &&
          token.trim().isNotEmpty) {
        await saveFCMToken(token);
      } else {
        debugPrint(
          'FCM token is null/empty.',
        );
      }

      // ======================================================
      // TOKEN REFRESH
      // ======================================================

      await _tokenRefreshSubscription?.cancel();

      _tokenRefreshSubscription =
          _messaging.onTokenRefresh.listen(
        (newToken) async {
          debugPrint(
            '======================================',
          );

          debugPrint(
            'FCM TOKEN REFRESHED',
          );

          debugPrint(
            newToken,
          );

          debugPrint(
            '======================================',
          );

          await saveFCMToken(newToken);
        },
      );

      // ======================================================
      // FOREGROUND MESSAGE
      // ======================================================

      await _foregroundSubscription?.cancel();

      _foregroundSubscription =
          FirebaseMessaging.onMessage.listen(
        (RemoteMessage message) {
          debugPrint(
            '======================================',
          );

          debugPrint(
            'FOREGROUND FCM MESSAGE',
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
        },
      );

      // ======================================================
      // NOTIFICATION OPENED
      // ======================================================

      await _openedSubscription?.cancel();

      _openedSubscription =
          FirebaseMessaging.onMessageOpenedApp.listen(
        (RemoteMessage message) {
          debugPrint(
            '======================================',
          );

          debugPrint(
            'NOTIFICATION OPENED',
          );

          debugPrint(
            'Data: '
            '${message.data}',
          );

          debugPrint(
            '======================================',
          );
        },
      );

      // ======================================================
      // TERMINATED APP
      // ======================================================

      final initialMessage =
          await _messaging.getInitialMessage();

      if (initialMessage != null) {
        debugPrint(
          '======================================',
        );

        debugPrint(
          'APP OPENED FROM TERMINATED NOTIFICATION',
        );

        debugPrint(
          'Data: '
          '${initialMessage.data}',
        );

        debugPrint(
          '======================================',
        );
      }

      debugPrint(
        '======================================',
      );

      debugPrint(
        'FCM initialization completed.',
      );

      debugPrint(
        '======================================',
      );
    } catch (e) {
      debugPrint(
        'FCM initialization error: $e',
      );
    }
  }

  // ==========================================================
  // SAVE FCM TOKEN
  // ==========================================================

  Future<void> saveFCMToken(
    String token,
  ) async {
    try {
      final user =
          _auth.currentUser;

      if (user == null) {
        debugPrint(
          'No logged-in user. '
          'FCM token not saved.',
        );

        return;
      }

      final cleanToken =
          token.trim();

      if (cleanToken.isEmpty) {
        debugPrint(
          'Cannot save empty FCM token.',
        );

        return;
      }

      await _firestore
          .collection('users')
          .doc(user.uid)
          .set(
        {
          'fcmToken': cleanToken,

          'fcmTokenUpdatedAt':
              FieldValue.serverTimestamp(),
        },
        SetOptions(
          merge: true,
        ),
      );

      debugPrint(
        '======================================',
      );

      debugPrint(
        'FCM TOKEN SAVED',
      );

      debugPrint(
        'User UID: ${user.uid}',
      );

      debugPrint(
        'Current token: $cleanToken',
      );

      debugPrint(
        '======================================',
      );

      // ======================================================
      // COUNT TOKENS
      // ======================================================

      final usersSnapshot =
          await _firestore
              .collection('users')
              .get();

      int totalTokens = 0;

      for (final doc
          in usersSnapshot.docs) {
        final data =
            doc.data();

        final savedToken =
            (data['fcmToken'] ?? '')
                .toString()
                .trim();

        if (savedToken.isNotEmpty) {
          totalTokens++;
        }
      }

      debugPrint(
        'Total tokens: $totalTokens',
      );
    } catch (e) {
      debugPrint(
        'Error saving FCM token: $e',
      );
    }
  }

  // ==========================================================
  // GET CURRENT USER TOKEN
  // ==========================================================

  Future<String?> getCurrentUserToken() async {
    try {
      final user =
          _auth.currentUser;

      if (user == null) {
        return null;
      }

      final doc =
          await _firestore
              .collection('users')
              .doc(user.uid)
              .get();

      if (!doc.exists) {
        return null;
      }

      final data =
          doc.data();

      final token =
          (data?['fcmToken'] ?? '')
              .toString()
              .trim();

      if (token.isEmpty) {
        return null;
      }

      return token;
    } catch (e) {
      debugPrint(
        'Get current FCM token error: $e',
      );

      return null;
    }
  }

  // ==========================================================
  // SEND TO ONE USER
  // ==========================================================

  Future<bool> sendToUser({
    required String receiverUid,
    required String senderName,
    required String message,
    String type = 'chat',
    String? senderUid,
  }) async {
    try {
      final cleanReceiverUid =
          receiverUid.trim();

      if (cleanReceiverUid.isEmpty) {
        debugPrint(
          'Receiver UID is empty.',
        );

        return false;
      }

      // ======================================================
      // GET RECEIVER
      // ======================================================

      final userDoc =
          await _firestore
              .collection('users')
              .doc(cleanReceiverUid)
              .get();

      if (!userDoc.exists) {
        debugPrint(
          'Receiver user not found: '
          '$cleanReceiverUid',
        );

        return false;
      }

      final data =
          userDoc.data();

      // ======================================================
      // WIND DOWN MODE CHECK
      // ======================================================

      if (_isReceiverInWindDown(data)) {
        debugPrint(
          'Skipping notification (Wind Down mode active): '
          '$cleanReceiverUid',
        );

        return false;
      }

      final token =
          (data?['fcmToken'] ?? '')
              .toString()
              .trim();

      // ======================================================
      // TOKEN CHECK
      // ======================================================

      if (token.isEmpty) {
        debugPrint(
          '======================================',
        );

        debugPrint(
          'RECEIVER HAS NO FCM TOKEN',
        );

        debugPrint(
          'Receiver UID: '
          '$cleanReceiverUid',
        );

        debugPrint(
          '======================================',
        );

        return false;
      }

      // ======================================================
      // NEW DEBUG DETAILS
      // ======================================================

      debugPrint(
        '======================================',
      );

      debugPrint(
        'RECEIVER NOTIFICATION DETAILS',
      );

      debugPrint(
        'Receiver UID: $cleanReceiverUid',
      );

      debugPrint(
        'Receiver FCM Token: $token',
      );

      debugPrint(
        'Sender Name: $senderName',
      );

      debugPrint(
        'Message: $message',
      );

      debugPrint(
        'Type: $type',
      );

      debugPrint(
        'Sender UID: ${senderUid ?? ''}',
      );

      debugPrint(
        '======================================',
      );

      // ======================================================
      // SEND TO CLOUDFLARE WORKER
      // ======================================================

      final result =
          await _sendToWorker(
        fcmToken: token,
        senderName: senderName,
        message: message,
        type: type,
        senderUid: senderUid,
      );

      return result;
    } catch (e) {
      debugPrint(
        'sendToUser error: $e',
      );

      return false;
    }
  }

  // ==========================================================
  // SEND TO ALL USERS
  // ==========================================================

  Future<void> sendToAllUsers({
    required String senderName,
    required String message,
    String type = 'chat',
    String? senderUid,
  }) async {
    try {
      debugPrint(
        '======================================',
      );

      debugPrint(
        'SEND NOTIFICATION TO ALL USERS',
      );

      debugPrint(
        '======================================',
      );

      // ======================================================
      // GET ALL USERS
      // ======================================================

      final snapshot =
          await _firestore
              .collection('users')
              .get();

      debugPrint(
        'Total users: '
        '${snapshot.docs.length}',
      );

      int successCount = 0;

      int failedCount = 0;

      // ======================================================
      // LOOP ALL USERS
      // ======================================================

      for (final doc
          in snapshot.docs) {
        try {
          final receiverUid =
              doc.id.trim();

          final data =
              doc.data();

          // ==================================================
          // DON'T SEND TO SENDER
          // ==================================================

          if (senderUid != null &&
              senderUid.trim().isNotEmpty &&
              receiverUid ==
                  senderUid.trim()) {
            debugPrint(
              'Skipping sender: '
              '$receiverUid',
            );

            continue;
          }

          // ==================================================
          // WIND DOWN MODE CHECK
          // ==================================================

          if (_isReceiverInWindDown(data)) {
            debugPrint(
              'Skipping notification (Wind Down mode active): '
              '$receiverUid',
            );

            continue;
          }

          // ==================================================
          // GET FCM TOKEN
          // ==================================================

          final token =
              (data['fcmToken'] ?? '')
                  .toString()
                  .trim();

          if (token.isEmpty) {
            debugPrint(
              'No FCM token for user: '
              '$receiverUid',
            );

            failedCount++;

            continue;
          }

          // ==================================================
          // SEND
          // ==================================================

          final success =
              await _sendToWorker(
            fcmToken: token,
            senderName: senderName,
            message: message,
            type: type,
            senderUid: senderUid,
          );

          if (success) {
            successCount++;
          } else {
            failedCount++;
          }

          debugPrint(
            'Notification result '
            '[$receiverUid]: $success',
          );
        } catch (e) {
          failedCount++;

          debugPrint(
            'Error sending to ${doc.id}: $e',
          );
        }
      }

      debugPrint(
        '======================================',
      );

      debugPrint(
        'ALL USER NOTIFICATION COMPLETED',
      );

      debugPrint(
        'Success: $successCount',
      );

      debugPrint(
        'Failed: $failedCount',
      );

      debugPrint(
        '======================================',
      );
    } catch (e) {
      debugPrint(
        'sendToAllUsers error: $e',
      );
    }
  }

  // ==========================================================
  // SEND TO WORKER
  // ==========================================================

  Future<bool> _sendToWorker({
    required String fcmToken,
    required String senderName,
    required String message,
    required String type,
    String? senderUid,
  }) async {
    try {
      final cleanToken =
          fcmToken.trim();

      if (cleanToken.isEmpty) {
        debugPrint(
          'Cannot send notification: '
          'empty FCM token.',
        );

        return false;
      }

      // ======================================================
      // REQUEST BODY
      // ======================================================

      final body = {
        'fcmToken': cleanToken,

        'senderName':
            senderName.trim().isEmpty
                ? 'User'
                : senderName.trim(),

        'message':
            message.trim(),

        'type':
            type.trim().isEmpty
                ? 'chat'
                : type.trim(),

        'senderUid':
            senderUid?.trim() ?? '',
      };

      // ======================================================
      // DEBUG
      // ======================================================

      debugPrint(
        '======================================',
      );

      debugPrint(
        'WORKER REQUEST',
      );

      debugPrint(
        'URL: $workerUrl',
      );

      debugPrint(
        'FCM TOKEN: $cleanToken',
      );

      debugPrint(
        'SENDER NAME: '
        '${body['senderName']}',
      );

      debugPrint(
        'MESSAGE: '
        '${body['message']}',
      );

      debugPrint(
        'TYPE: '
        '${body['type']}',
      );

      debugPrint(
        'SENDER UID: '
        '${body['senderUid']}',
      );

      debugPrint(
        '======================================',
      );

      // ======================================================
      // HTTP POST
      // ======================================================

      final response =
          await http
              .post(
                Uri.parse(workerUrl),
                headers: {
                  'Content-Type':
                      'application/json',

                  'Accept':
                      'application/json',
                },
                body:
                    jsonEncode(body),
              )
              .timeout(
                const Duration(
                  seconds: 20,
                ),
              );

      // ======================================================
      // RESPONSE
      // ======================================================

      debugPrint(
        'Worker status: '
        '${response.statusCode}',
      );

      debugPrint(
        'Worker response: '
        '${response.body}',
      );

      // ======================================================
      // HTTP SUCCESS CHECK
      // ======================================================

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        debugPrint(
          'Worker returned HTTP error.',
        );

        return false;
      }

      // ======================================================
      // PARSE RESPONSE
      // ======================================================

      try {
        final result =
            jsonDecode(response.body);

        if (result is Map &&
            result['success'] == true) {
          debugPrint(
            'Notification sent successfully.',
          );

          return true;
        }

        debugPrint(
          'Worker returned success=false.',
        );

        return false;
      } catch (e) {
        debugPrint(
          'Worker response JSON parse error: $e',
        );

        return false;
      }
    } on TimeoutException catch (e) {
      debugPrint(
        'Worker request timeout: $e',
      );

      return false;
    } on http.ClientException catch (e) {
      debugPrint(
        'HTTP client error: $e',
      );

      return false;
    } catch (e) {
      debugPrint(
        'Worker notification error: $e',
      );

      return false;
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  Future<void> dispose() async {
    await _tokenRefreshSubscription?.cancel();

    await _foregroundSubscription?.cancel();

    await _openedSubscription?.cancel();

    _tokenRefreshSubscription = null;

    _foregroundSubscription = null;

    _openedSubscription = null;
  }
}