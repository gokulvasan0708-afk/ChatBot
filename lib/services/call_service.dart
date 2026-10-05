import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../navigation_key.dart';
import '../pages/call/incoming_call_screen.dart';
import '../pages/call/outgoing_call_screen.dart';
import 'call_signaling.dart';
import 'ringtone_service.dart';

import '../widgets/top_alert.dart';
// ==========================================================
// CALL STATUS CONSTANTS
// ----------------------------------------------------------
// Plain strings (not a Dart enum) so they read/write directly to the
// `calls/{callId}` Firestore document with no mapping layer.
// ==========================================================

class CallStatus {
  static const ringing = 'ringing';
  static const accepted = 'accepted';
  static const connected = 'connected';
  static const declined = 'declined';
  static const cancelled = 'cancelled';
  static const ended = 'ended';
  static const missed = 'missed';
  static const failed = 'failed';
}

/// Everything about the one call this device is currently on. A single
/// CallService only ever tracks one of these at a time -- this app is
/// 1-to-1 voice calling, not call-waiting/multi-call, so a second call
/// attempt while one is active is simply refused (see [startCall]).
class ActiveCall {
  ActiveCall({
    required this.callId,
    required this.isCaller,
    required this.otherUserId,
    required this.otherUserName,
    required this.otherUserImage,
    this.callType = 'voice',
  });

  final String callId;
  final bool isCaller;
  final String otherUserId;
  final String otherUserName;
  final String otherUserImage;
  final String callType;

  CallSignaling? signaling;
  Timer? ringTimeoutTimer;
  DateTime? connectedAt;
}

/// App-wide singleton that owns the entire 1-to-1 voice calling
/// feature end to end:
///   - starting / accepting / declining / cancelling / ending calls
///   - the real-time Firestore listener that detects an incoming call
///   - showing the Incoming/Outgoing call screens over whatever the
///     app is currently displaying, via [rootNavigatorKey]
///   - ringtone lifecycle, call-history chat entries, and cleanup
///
/// Call [initialize] once near app start (see main.dart). It wires
/// itself to `FirebaseAuth.instance.authStateChanges()` internally, so
/// it automatically starts/stops its incoming-call listener whenever
/// the signed-in account changes -- including this app's own
/// account-switcher -- without any other file needing to call
/// start/stop by hand.
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const Duration ringTimeout = Duration(seconds: 60);

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _incomingCallsListener;

  ActiveCall? _activeCall;
  String? _incomingCallIdShowing;
  bool _initialized = false;

  CollectionReference<Map<String, dynamic>> get _calls =>
      _db.collection('calls');

  ActiveCall? get activeCall => _activeCall;

  /// True while this device has a call ringing (incoming screen showing),
  /// dialing out, or connected. Used by the splash-re-entry logic in
  /// main.dart/splash_screen.dart so it never wipes the navigator stack
  /// out from under an in-progress call's screen.
  bool get isCallInProgress =>
      _activeCall != null || _incomingCallIdShowing != null;

  // ==========================================================
  // LIFECYCLE
  // ==========================================================

  void initialize() {
    if (_initialized) return;
    _initialized = true;

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _stopIncomingListener();
      if (user != null) {
        _startIncomingListener(user.uid);
      }
    });
  }

  void _startIncomingListener(String uid) {
    _incomingCallsListener = _calls
        .where('receiverId', isEqualTo: uid)
        .where('status', isEqualTo: CallStatus.ringing)
        .snapshots()
        .listen(_handleIncomingSnapshot, onError: (e) {
      debugPrint('CallService incoming listener error: $e');
    });
  }

  void _stopIncomingListener() {
    _incomingCallsListener?.cancel();
    _incomingCallsListener = null;
  }

  void _handleIncomingSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    // Only ever react to genuinely NEW ringing calls ('added'). Any
    // later update to a call already being shown (e.g. it flips to
    // 'cancelled') is handled by IncomingCallScreen's own listener on
    // that one document, not here -- this is what prevents a second
    // Firestore update from spawning a duplicate incoming-call screen
    // or a duplicate ringtone.
    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;

      final data = change.doc.data();
      if (data == null) continue;

      final callId = change.doc.id;

      if (_activeCall != null || _incomingCallIdShowing == callId) {
        continue;
      }

      _showIncomingCallScreen(callId, data);
    }
  }

  void _showIncomingCallScreen(String callId, Map<String, dynamic> data) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    _incomingCallIdShowing = callId;
    RingtoneService.instance.playIncoming();

    navigator
        .push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callId: callId,
          callerId: (data['callerId'] ?? '').toString(),
          callerName: (data['callerName'] ?? 'Unknown').toString(),
          callerImage: (data['callerImage'] ?? '').toString(),
          callType: (data['callType'] ?? 'voice').toString(),
        ),
        fullscreenDialog: true,
      ),
    )
        .then((_) {
      if (_incomingCallIdShowing == callId) {
        _incomingCallIdShowing = null;
      }
    });
  }

  // ==========================================================
  // OUTGOING CALL
  // ==========================================================

  Future<void> startCall({
    required BuildContext context,
    required String receiverId,
    required String receiverName,
    required String receiverImage,
    bool isVideo = false,
  }) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;

    if (_activeCall != null) {
      showTopAlert(context, 'You are already on a call.');
      return;
    }

    final myProfileSnap = await _db.collection('users').doc(me.uid).get();
    final myData = myProfileSnap.data() ?? {};
    final myName = (myData['publicName'] ??
            myData['privateName'] ??
            me.displayName ??
            'Unknown')
        .toString();
    final myImage =
        (myData['publicImage'] ?? myData['privateImage'] ?? '').toString();

    final callRef = _calls.doc();
    final callType = isVideo ? 'video' : 'voice';

    await callRef.set({
      'callId': callRef.id,
      'callerId': me.uid,
      'callerName': myName,
      'callerImage': myImage,
      'receiverId': receiverId,
      'receiverName': receiverName,
      'receiverImage': receiverImage,
      'participants': [me.uid, receiverId],
      'callType': callType,
      'status': CallStatus.ringing,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    _activeCall = ActiveCall(
      callId: callRef.id,
      isCaller: true,
      otherUserId: receiverId,
      otherUserName: receiverName,
      otherUserImage: receiverImage,
      callType: callType,
    );

    unawaited(RingtoneService.instance.playOutgoing());
    unawaited(_sendCallPushNotification(
      receiverId: receiverId,
      callId: callRef.id,
      callerName: myName,
      callType: callType,
    ));

    _activeCall!.ringTimeoutTimer = Timer(ringTimeout, () {
      _expireIfStillRinging(callRef.id);
    });

    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => OutgoingCallScreen(
          callId: callRef.id,
          receiverId: receiverId,
          receiverName: receiverName,
          receiverImage: receiverImage,
          callType: callType,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _expireIfStillRinging(String callId) async {
    bool expired = false;
    try {
      await _db.runTransaction((tx) async {
        final ref = _calls.doc(callId);
        final snap = await tx.get(ref);
        final data = snap.data();
        if (data == null || data['status'] != CallStatus.ringing) return;
        tx.update(ref, {
          'status': CallStatus.missed,
          'updatedAt': FieldValue.serverTimestamp(),
          'endedAt': FieldValue.serverTimestamp(),
        });
        expired = true;
      });
    } catch (e) {
      debugPrint('CallService expire error: $e');
    }
    // Only the device whose timer actually won the race logs the
    // missed-call history entry -- if the transaction found the call
    // already accepted/declined/cancelled by the time the timer fired,
    // `expired` stays false and this is a no-op.
    if (expired) {
      await _teardownActiveCall(callId, CallStatus.missed);
    }
  }

  // ==========================================================
  // RECEIVER ACTIONS
  // ==========================================================

  /// Attempts to accept the call. Returns false if it lost a race
  /// against a timeout/cancel that landed at nearly the same moment
  /// (status was no longer 'ringing') -- IncomingCallScreen should
  /// only proceed to the active-call screen when this returns true.
  Future<bool> acceptCall(String callId) async {
    final callRef = _calls.doc(callId);
    bool accepted = false;

    await _db.runTransaction((tx) async {
      final snap = await tx.get(callRef);
      final data = snap.data();
      if (data == null || data['status'] != CallStatus.ringing) return;
      tx.update(callRef, {
        'status': CallStatus.accepted,
        'acceptedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      accepted = true;
    });

    if (!accepted) return false;

    await RingtoneService.instance.stop();
    _incomingCallIdShowing = null;

    final snap = await callRef.get();
    final data = snap.data() ?? {};

    _activeCall = ActiveCall(
      callId: callId,
      isCaller: false,
      otherUserId: (data['callerId'] ?? '').toString(),
      otherUserName: (data['callerName'] ?? 'Unknown').toString(),
      otherUserImage: (data['callerImage'] ?? '').toString(),
      callType: (data['callType'] ?? 'voice').toString(),
    );

    return true;
  }

  Future<void> declineCall(String callId) async {
    final callRef = _calls.doc(callId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(callRef);
      final data = snap.data();
      if (data == null || data['status'] != CallStatus.ringing) return;
      tx.update(callRef, {
        'status': CallStatus.declined,
        'updatedAt': FieldValue.serverTimestamp(),
        'endedAt': FieldValue.serverTimestamp(),
      });
    });
    await _teardownActiveCall(callId, CallStatus.declined);
  }

  // ==========================================================
  // CALLER ACTIONS
  // ==========================================================

  Future<void> cancelCall(String callId) async {
    final callRef = _calls.doc(callId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(callRef);
      final data = snap.data();
      if (data == null || data['status'] != CallStatus.ringing) return;
      tx.update(callRef, {
        'status': CallStatus.cancelled,
        'updatedAt': FieldValue.serverTimestamp(),
        'endedAt': FieldValue.serverTimestamp(),
      });
    });
    await _teardownActiveCall(callId, CallStatus.cancelled);
  }

  // ==========================================================
  // SHARED: CONNECT / END
  // ==========================================================

  Future<void> markConnected(String callId) async {
    try {
      await _calls.doc(callId).update({
        'status': CallStatus.connected,
        'connectedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('CallService markConnected error: $e');
    }
    if (_activeCall?.callId == callId) {
      _activeCall!.connectedAt = DateTime.now();
    }
  }

  Future<void> markFailed(String callId) async {
    try {
      await _calls.doc(callId).update({
        'status': CallStatus.failed,
        'updatedAt': FieldValue.serverTimestamp(),
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('CallService markFailed error: $e');
    }
    await _teardownActiveCall(callId, CallStatus.failed);
  }

  Future<void> endCall(String callId) async {
    final connectedAt =
        _activeCall?.callId == callId ? _activeCall?.connectedAt : null;
    final duration = connectedAt == null
        ? 0
        : DateTime.now().difference(connectedAt).inSeconds;

    try {
      await _calls.doc(callId).update({
        'status': CallStatus.ended,
        'endedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'endedBy': FirebaseAuth.instance.currentUser?.uid,
        'durationSeconds': duration,
      });
    } catch (e) {
      debugPrint('CallService endCall update error: $e');
    }

    await _teardownActiveCall(
      callId,
      CallStatus.ended,
      durationSeconds: duration,
    );
  }

  Future<void> _teardownActiveCall(
    String callId,
    String finalStatus, {
    int durationSeconds = 0,
  }) async {
    final call = _activeCall;
    if (call != null && call.callId == callId) {
      call.ringTimeoutTimer?.cancel();
      await call.signaling?.dispose();
      _activeCall = null;
    }

    await RingtoneService.instance.stop();
    if (_incomingCallIdShowing == callId) {
      _incomingCallIdShowing = null;
    }

    await _logCallHistory(callId, finalStatus, durationSeconds: durationSeconds);
  }

  /// Called by ActiveCallScreen right after building its
  /// [CallSignaling] so CallService can dispose it on any teardown
  /// path (End Call, remote hangup, timeout, error) without the
  /// screen having to coordinate that itself.
  void attachSignaling(String callId, CallSignaling signaling) {
    if (_activeCall?.callId == callId) {
      _activeCall!.signaling = signaling;
    }
  }

  /// Local-only cleanup for a terminal status this device did NOT
  /// itself cause (e.g. the other side declined/cancelled/ended the
  /// call, or this device's own ring timer already logged a missed
  /// call). Stops the ringtone, disposes any live signaling/timers,
  /// and clears local state -- but never re-writes Firestore or logs
  /// a second call-history entry, since whichever side caused the
  /// transition already did both.
  ///
  /// Safe to call any number of times, including when there is
  /// nothing left to clean up (e.g. this device's own button press
  /// already tore everything down and its own Firestore listener is
  /// now just echoing that same status back).
  Future<void> handleRemoteTermination(String callId) async {
    final call = _activeCall;
    if (call != null && call.callId == callId) {
      call.ringTimeoutTimer?.cancel();
      await call.signaling?.dispose();
      _activeCall = null;
    }
    await RingtoneService.instance.stop();
    if (_incomingCallIdShowing == callId) {
      _incomingCallIdShowing = null;
    }
  }

  // ==========================================================
  // CALL HISTORY (lightweight chat message, no audio ever stored)
  // ==========================================================

  String _chatIdFor(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }

  Future<void> _logCallHistory(
    String callId,
    String finalStatus, {
    int durationSeconds = 0,
  }) async {
    try {
      final snap = await _calls.doc(callId).get();
      final data = snap.data();
      if (data == null) return;

      final callerId = (data['callerId'] ?? '').toString();
      final receiverId = (data['receiverId'] ?? '').toString();
      if (callerId.isEmpty || receiverId.isEmpty) return;

      final me = FirebaseAuth.instance.currentUser;
      final isMeCaller = me != null && me.uid == callerId;
      final isVideoCall = (data['callType'] ?? 'voice').toString() == 'video';
      final icon = isVideoCall ? '🎥' : '📞';
      final typeLabel = isVideoCall ? 'Video call' : 'Voice call';

      final String label;
      switch (finalStatus) {
        case CallStatus.declined:
          label = '$icon Call declined';
          break;
        case CallStatus.cancelled:
          label = '$icon Call cancelled';
          break;
        case CallStatus.missed:
          label = isMeCaller ? '$icon No answer' : '$icon Missed call';
          break;
        case CallStatus.failed:
          label = '$icon Call failed';
          break;
        case CallStatus.ended:
          label = durationSeconds > 0
              ? '$icon $typeLabel · ${_formatDuration(durationSeconds)}'
              : '$icon Call ended';
          break;
        default:
          label = '$icon Call ended';
      }

      final chatId = _chatIdFor(callerId, receiverId);
      final chatRef = _db.collection('chats').doc(chatId);
      final now = FieldValue.serverTimestamp();

      // Deliberately mirrors the shape of a normal text message (see
      // chat_screen.dart's message-send code) so it renders through
      // the EXISTING default text bubble with zero changes to bubble
      // rendering -- 'call' just isn't one of the special-cased
      // messageTypes ('voice'/'photo'/'video'/'audio'/'file') there.
      await chatRef.collection('messages').add({
        'senderId': callerId,
        'receiverId': receiverId,
        'text': label,
        'messageType': 'call',
        'callId': callId,
        'callStatus': finalStatus,
        'sentAt': now,
        'expiresAt': null,
        'chatTypeAtSend': 'private',
        'savedBy': <String>[],
        'hiddenFor': <String>[],
        'readBy': <String>[],
        'replyTo': null,
      });

      await chatRef.set({
        'participants': [callerId, receiverId],
        'lastMessage': label,
        'lastMessageTime': now,
        'lastMessageSenderId': callerId,
        'updatedAt': now,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('CallService _logCallHistory error: $e');
    }
  }

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // ==========================================================
  // PUSH NOTIFICATION (best-effort wake-up while backgrounded)
  // ----------------------------------------------------------
  // Reuses the exact same Cloudflare Worker endpoint chat_screen.dart
  // already calls for new-message pushes (see the worker's src/index.js
  // in the same delivery), just with type: 'call'. This is a
  // best-effort nudge only -- the real-time Firestore listener in
  // _startIncomingListener is what actually detects and shows the
  // incoming call while the app process is alive; this push exists so
  // a backgrounded (not fully killed) app still gets a system
  // notification for it.
  // ==========================================================

  Future<void> _sendCallPushNotification({
    required String receiverId,
    required String callId,
    required String callerName,
    String callType = 'voice',
  }) async {
    try {
      final receiverDoc =
          await _db.collection('users').doc(receiverId).get();
      final token = (receiverDoc.data()?['fcmToken'] ?? '').toString().trim();
      if (token.isEmpty) return;

      await http.post(
        Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fcmToken': token,
          'senderName': callerName,
          'message': callType == 'video'
              ? 'Incoming video call'
              : 'Incoming voice call',
          'senderUid': FirebaseAuth.instance.currentUser?.uid ?? '',
          'type': 'call',
          'callId': callId,
          'callType': callType,
        }),
      );
    } catch (e) {
      debugPrint('CallService push notification error: $e');
    }
  }
}