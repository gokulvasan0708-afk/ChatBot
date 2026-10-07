import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../navigation_key.dart';
import '../pages/app_theme.dart';
import '../pages/chat_screen.dart';
import '../pages/groupchat.dart';
import '../pages/private_chat_screen.dart';
import '../services/active_conversation.dart';
import 'nexus_notify.dart';

// ================================================================
// IN-APP INCOMING MESSAGE ALERT  (heads-up bar)
// ----------------------------------------------------------------
// WHAT THIS SOLVES
// ----------------
// While the app is OPEN (foreground), Android/iOS do not draw the
// system notification for an incoming FCM push, so a message landing
// in another chat/group was completely silent -- the user only found
// out by leaving the screen they were on. This file adds the missing
// piece: a real notification-style bar that slides in from the TOP of
// whatever screen is showing (Me page, Community, a different chat,
// anywhere), exactly like the system heads-up notification does when
// the app is closed.
//
// WHAT IT SHOWS
// -------------
//   1-to-1 chat
//       [ sender profile photo ]  <sender name>
//                                 <message>
//
//   group chat
//       [ group profile photo ]   <group name>
//                                 <sender name>
//                                 <message>
//
//   The sender's name AND photo follow the same identity rule the
//   Chats list uses everywhere else (see pages/chat_page.dart):
//       connected      -> privateName / privateImage
//                         (falling back to the public ones when the
//                          private fields were never set)
//       not connected  -> publicName  / publicImage
//
// WHEN IT MUST **NOT** SHOW  (the actual fix being asked for)
// ---------------------------------------------------------
//   * The message is one I sent myself.
//   * I am currently INSIDE that same conversation's screen -- if the
//     chat screen for that person (or that group's screen) is open,
//     the message is already visible in the thread, so no bar. This is
//     resolved through services/active_conversation.dart, which the
//     two chat screens push/pop themselves into.
//     Messages from ANY OTHER chat or group still show normally while
//     sitting inside a chat screen -- that is the whole point.
//   * The conversation is muted (per-chat mute in
//     users/{me}/chatSettings/{other}.muted, group mute in
//     groups/{id}.mutedBy[me]).
//   * Settings -> Nexus Notify -> "Message pop-up" is off (this bar's
//     own switch, sitting just above "Wind Down mode"), or the master
//     "Notify" switch above it is off. Stored as
//     users/{uid}.notifyMessagePopup (bool, absent == ON).
//   * The app is not in the foreground (a backgrounded app gets the
//     real system notification instead; the bar would otherwise queue
//     up and all fire at once on resume).
//
// HOW IT DETECTS MESSAGES
// -----------------------
// Two cheap collection listeners that the app already relies on
// elsewhere -- chats/ (participants contains me) and groups/ (members
// contains me) -- watching only the conversation documents, never the
// messages subcollections. Every send already updates
// lastMessage / lastMessageTime / lastMessageSenderId on the chat doc
// (chat_screen.dart) and lastMessage / lastMessageAt / lastMessageSender
// on the group doc (groupchat.dart), so one document change per new
// message is all that is needed.
//
// The FIRST snapshot of each listener only records a baseline and
// never alerts, so opening the app does not fire a burst of bars for
// messages that arrived while it was closed (those already got their
// system notification).
//
// TAPPING THE BAR
// ---------------
// Goes straight into the conversation the message came from, by the
// same route the Chats list / Groups tab use, so the screen that
// opens is the expected one:
//     group                  -> GroupChatScreen(groupDocId)
//     connected (private)    -> PrivateChatScreen(otherUserUid)
//     not connected (public) -> ChatScreen(uid, name, image)
// The read marker is written on the way in too, so the unread dot
// and the unseen-messages reminder clear just like they do when the
// conversation is opened from the list. Taps on the inline reply
// composer (below) are the one exception -- they stay put.
//
// INLINE QUICK REPLY  (added)
// ---------------------------
// Under the message preview the bar now shows a small "Reply" action.
// Tapping it does NOT navigate anywhere -- the bar stays exactly where
// it is, on whatever screen the user is already on, and the "Reply"
// text is REPLACED IN PLACE by the same composer row the chat screen
// uses at the bottom:
//
//     [ + ]  [ Type a message... ]  [ send / mic ]
//
// The field autofocuses the moment it appears, so the keyboard slides
// up straight away. Sending writes the message with the same document
// shape the real composers write (chat_screen.dart `_sendMessage`,
// groupchat.dart `_send`), including a best-effort `replyTo` quote of
// the message the bar was showing, then the bar dismisses itself
// automatically. Swiping the bar left or right still dismisses it,
// composer open or not. Leaving the field empty and dropping focus
// collapses the composer back to the plain "Reply" text and restarts
// the normal 5-second auto-dismiss.
//
// The [ + ] (attachments) and the mic (voice message) need the chat
// screen's own pickers / recorder / upload pipeline, so those two -
// and only those two - open the conversation, exactly like tapping the
// bar itself always has.
// ================================================================

ImageProvider? _alertImageProvider(String path) {
  final value = path.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return NetworkImage(value);
  }
  return AssetImage(value);
}

/// One pending heads-up bar.
class _IncomingAlert {
  /// 'chat:<chatId>' / 'group:<groupDocId>' -- same key space as
  /// ActiveConversation, so suppression is a plain lookup.
  final String key;

  /// Line 1: sender name (chat) or group name (group).
  final String title;

  /// Line 2 for groups only: who sent it inside the group.
  final String? senderLine;

  /// Message preview.
  final String body;

  final String imageUrl;
  final bool isGroup;
  final DateTime receivedAt;

  /// Enough to reopen the conversation when the bar is tapped.
  final String otherUserUid; // chats only
  final String groupDocId; // groups only
  final bool usePrivateProfile; // chats only

  /// chats/<chatDocId> -- the conversation document this message
  /// landed in. Needed by the inline quick reply so it can write
  /// straight back into the same thread without opening the screen.
  final String chatDocId; // chats only

  /// Who actually sent the message (the uid). For groups this is the
  /// member inside the group, not the group itself.
  final String senderUid;

  const _IncomingAlert({
    required this.key,
    required this.title,
    required this.senderLine,
    required this.body,
    required this.imageUrl,
    required this.isGroup,
    required this.receivedAt,
    this.otherUserUid = '',
    this.groupDocId = '',
    this.usePrivateProfile = false,
    this.chatDocId = '',
    this.senderUid = '',
  });
}

class IncomingMessageAlert {
  IncomingMessageAlert._();

  // ==========================================================
  // STATE
  // ==========================================================

  static String? _ownerUid;

  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chatsSub;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _groupsSub;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _connectionsSub;

  /// Baseline: conversation key -> newest message time already known.
  /// Anything not newer than this is old news and never alerts.
  static final Map<String, DateTime> _lastSeenAt = <String, DateTime>{};

  static bool _chatsPrimed = false;
  static bool _groupsPrimed = false;

  /// uids I am connected to -- decides private vs public name/photo.
  static final Set<String> _connectedUids = <String>{};

  /// uid -> {name, image} cache so repeated messages from the same
  /// person don't re-read their user document every time.
  static final Map<String, Map<String, String>> _profileCache =
      <String, Map<String, String>>{};

  /// other uid -> muted?, from users/{me}/chatSettings/{other}.
  static final Map<String, bool> _mutedCache = <String, bool>{};

  static bool? _notifyEnabled;

  /// Settings -> Nexus Notify -> "Message pop-up" -- this bar's own
  /// on/off switch (users/{uid}.notifyMessagePopup). Null until the
  /// user document has been read once this session.
  static bool? _popupEnabled;

  static final List<_IncomingAlert> _queue = <_IncomingAlert>[];
  static OverlayEntry? _currentEntry;

  // ==========================================================
  // ENTRY POINTS
  // ==========================================================

  /// Starts (or restarts, after an account switch) the listeners.
  /// Safe to call on every app open/resume -- it no-ops when it is
  /// already running for the signed-in account.
  static void start() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      stop();
      return;
    }

    if (_ownerUid == uid && _chatsSub != null) return; // already running

    stop();
    _ownerUid = uid;

    final fs = FirebaseFirestore.instance;

    // ---- who am I connected to? (private vs public identity) ------
    _connectionsSub = fs
        .collection('connections')
        .where('users', arrayContains: uid)
        .where('status', isEqualTo: 'connected')
        .snapshots()
        .listen((snap) {
      final next = <String>{};
      for (final doc in snap.docs) {
        final users = List<String>.from(doc.data()['users'] ?? const []);
        final other = users.firstWhere((id) => id != uid, orElse: () => '');
        if (other.isNotEmpty) next.add(other);
      }
      _connectedUids
        ..clear()
        ..addAll(next);
      // Identity changed -> cached names/photos may be the wrong side.
      _profileCache.clear();
    }, onError: (e) => debugPrint('Incoming alert connections error: $e'));

    // ---- 1-to-1 chats ---------------------------------------------
    _chatsSub = fs
        .collection('chats')
        .where('participants', arrayContains: uid)
        .snapshots()
        .listen(
          (snap) => unawaited(_handleChatsSnapshot(uid, snap)),
          onError: (e) => debugPrint('Incoming alert chats error: $e'),
        );

    // ---- groups ---------------------------------------------------
    _groupsSub = fs
        .collection('groups')
        .where('members', arrayContains: uid)
        .snapshots()
        .listen(
          (snap) => unawaited(_handleGroupsSnapshot(uid, snap)),
          onError: (e) => debugPrint('Incoming alert groups error: $e'),
        );
  }

  /// Tears everything down (sign out, account switch, home shell
  /// dispose) and clears anything on screen or queued.
  static void stop() {
    _chatsSub?.cancel();
    _chatsSub = null;
    _groupsSub?.cancel();
    _groupsSub = null;
    _connectionsSub?.cancel();
    _connectionsSub = null;

    _ownerUid = null;
    _chatsPrimed = false;
    _groupsPrimed = false;

    _lastSeenAt.clear();
    _connectedUids.clear();
    _profileCache.clear();
    _mutedCache.clear();
    _notifyEnabled = null;
    _popupEnabled = null;

    _queue.clear();
    _currentEntry?.remove();
    _currentEntry = null;
  }

  /// Lets Settings -> Nexus Notify push its switches straight into
  /// this session the moment they are flipped, instead of waiting for
  /// the user document to be re-read on a cold start.
  ///
  ///   enabled       -> the master "Notify" switch
  ///   popupEnabled  -> this bar's own "Message pop-up" switch
  ///
  /// Turning either one OFF also clears whatever is on screen or
  /// queued, so no bar can slip through after the switch is off.
  static void updateCache({bool? enabled, bool? popupEnabled}) {
    if (enabled == null && popupEnabled == null) return;
    if (enabled != null) _notifyEnabled = enabled;
    if (popupEnabled != null) _popupEnabled = popupEnabled;

    if (enabled == false || popupEnabled == false) {
      _queue.clear();
      _currentEntry?.remove();
      _currentEntry = null;
    }
  }

  /// Per-chat mute changed from the chat screen -- drop the cached
  /// value so the next message re-reads it.
  static void invalidateMute(String otherUid) =>
      _mutedCache.remove(otherUid);

  // ==========================================================
  // SNAPSHOT HANDLING
  // ==========================================================

  static Future<void> _handleChatsSnapshot(
    String uid,
    QuerySnapshot<Map<String, dynamic>> snap,
  ) async {
    // First delivery = baseline only. Record every conversation's
    // newest message time and alert for none of them.
    if (!_chatsPrimed) {
      _chatsPrimed = true;
      for (final doc in snap.docs) {
        final at = _timeOf(doc.data()['lastMessageTime']);
        if (at != null) _lastSeenAt[ActiveConversation.chatKey(doc.id)] = at;
      }
      return;
    }

    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;

      final doc = change.doc;
      // My own pending write echoing back -- not an incoming message.
      if (doc.metadata.hasPendingWrites) continue;

      final data = doc.data();
      if (data == null) continue;

      final key = ActiveConversation.chatKey(doc.id);

      final receivedAt = _timeOf(data['lastMessageTime']);
      if (receivedAt == null) continue;

      final previous = _lastSeenAt[key];
      if (previous != null && !receivedAt.isAfter(previous)) continue;
      _lastSeenAt[key] = receivedAt;

      final senderUid = (data['lastMessageSenderId'] ?? '').toString().trim();
      if (senderUid.isEmpty || senderUid == uid) continue; // mine

      // Chat I deleted/hid on my side.
      final hiddenFor = List<String>.from(data['hiddenFor'] ?? const []);
      if (hiddenFor.contains(uid)) continue;

      final body = (data['lastMessage'] ?? '').toString().trim();
      if (body.isEmpty) continue;

      // ----- the suppression the user asked for -------------------
      // Inside THIS chat's own screen -> no bar (the message is
      // already on screen). Any other chat/group still alerts.
      if (ActiveConversation.isOpen(key)) continue;

      if (!await _shouldAlert()) continue;
      if (await _isChatMuted(uid, senderUid)) continue;

      final isConnected = _connectedUids.contains(senderUid);
      final profile = await _profileFor(senderUid, isConnected);
      final name = profile['name'] ?? '';
      if (name.isEmpty) continue;

      _enqueue(_IncomingAlert(
        key: key,
        title: name,
        senderLine: null,
        body: body,
        imageUrl: profile['image'] ?? '',
        isGroup: false,
        receivedAt: receivedAt,
        otherUserUid: senderUid,
        usePrivateProfile: isConnected,
        chatDocId: doc.id,
        senderUid: senderUid,
      ));
    }
  }

  static Future<void> _handleGroupsSnapshot(
    String uid,
    QuerySnapshot<Map<String, dynamic>> snap,
  ) async {
    if (!_groupsPrimed) {
      _groupsPrimed = true;
      for (final doc in snap.docs) {
        final at = _timeOf(doc.data()['lastMessageAt']);
        if (at != null) _lastSeenAt[ActiveConversation.groupKey(doc.id)] = at;
      }
      return;
    }

    for (final change in snap.docChanges) {
      if (change.type == DocumentChangeType.removed) continue;

      final doc = change.doc;
      if (doc.metadata.hasPendingWrites) continue;

      final data = doc.data();
      if (data == null) continue;

      final key = ActiveConversation.groupKey(doc.id);

      final receivedAt = _timeOf(data['lastMessageAt']);
      if (receivedAt == null) continue;

      final previous = _lastSeenAt[key];
      if (previous != null && !receivedAt.isAfter(previous)) continue;
      _lastSeenAt[key] = receivedAt;

      final senderUid = (data['lastMessageSender'] ?? '').toString().trim();
      if (senderUid.isEmpty || senderUid == uid) continue; // mine

      final body = (data['lastMessage'] ?? '').toString().trim();
      if (body.isEmpty) continue;

      // Inside THIS group's own screen -> no bar.
      if (ActiveConversation.isOpen(key)) continue;

      // Group muted by me (groups/{id}.mutedBy[<uid>]).
      final mutedBy = data['mutedBy'];
      if (mutedBy is Map && mutedBy[uid] == true) continue;

      if (!await _shouldAlert()) continue;

      final groupName = (data['groupName'] ?? '').toString().trim();
      if (groupName.isEmpty) continue;

      final groupImage = (data['groupProfileImage'] ?? '').toString().trim();

      // Sender's name inside the group follows the same connected ->
      // private / not connected -> public rule as everywhere else.
      final senderProfile =
          await _profileFor(senderUid, _connectedUids.contains(senderUid));
      final senderName = senderProfile['name'] ?? '';

      _enqueue(_IncomingAlert(
        key: key,
        title: groupName,
        senderLine: senderName.isEmpty ? null : senderName,
        body: body,
        imageUrl: groupImage,
        isGroup: true,
        receivedAt: receivedAt,
        groupDocId: doc.id,
        senderUid: senderUid,
      ));
    }
  }

  static DateTime? _timeOf(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }

  // ==========================================================
  // GATES
  // ==========================================================

  /// Foreground-only, and BOTH switches on: the master "Notify"
  /// switch and this bar's own "Message pop-up" switch.
  static Future<bool> _shouldAlert() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      // App is backgrounded -- the real system notification covers it.
      return false;
    }

    // Reuse whatever the greeting bar already read for this session.
    _notifyEnabled ??= NexusNotify.cachedEnabled;

    if (_notifyEnabled != null && _popupEnabled != null) {
      return _notifyEnabled! && _popupEnabled!;
    }

    final uid = _ownerUid;
    if (uid == null) return false;

    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();

      // Absent fields (older accounts / never touched in Settings)
      // default to ON, so behaviour is unchanged until the user turns
      // them off themselves.
      final notifyValue = (data?['notifyEnabled'] as bool?) ?? true;
      final popupValue = (data?['notifyMessagePopup'] as bool?) ?? true;

      _notifyEnabled = notifyValue;
      _popupEnabled = popupValue;
      NexusNotify.updateCache(enabled: notifyValue);

      return notifyValue && popupValue;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> _isChatMuted(String myUid, String otherUid) async {
    final cached = _mutedCache[otherUid];
    if (cached != null) return cached;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(myUid)
          .collection('chatSettings')
          .doc(otherUid)
          .get();
      final muted = snap.data()?['muted'] == true;
      _mutedCache[otherUid] = muted;
      return muted;
    } catch (_) {
      return false;
    }
  }

  /// Private name/photo when connected (falling back to the public
  /// ones if the private fields were never filled in), public
  /// name/photo otherwise -- identical to the Chats list rule.
  static Future<Map<String, String>> _profileFor(
    String uid,
    bool isConnected,
  ) async {
    final cacheKey = '$uid:$isConnected';
    final cached = _profileCache[cacheKey];
    if (cached != null) return cached;

    try {
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data();
      if (data == null) return const {'name': '', 'image': ''};

      final privateName = (data['privateName'] ?? '').toString().trim();
      final publicName = (data['publicName'] ?? '').toString().trim();
      final privateImage = (data['privateImage'] ?? '').toString().trim();
      final publicImage = (data['publicImage'] ?? '').toString().trim();

      final resolved = <String, String>{
        'name': (isConnected && privateName.isNotEmpty)
            ? privateName
            : publicName,
        'image': (isConnected && privateImage.isNotEmpty)
            ? privateImage
            : publicImage,
      };

      if ((resolved['name'] ?? '').isNotEmpty) {
        _profileCache[cacheKey] = resolved;
      }
      return resolved;
    } catch (e) {
      debugPrint('Incoming alert profile error: $e');
      return const {'name': '', 'image': ''};
    }
  }

  // ==========================================================
  // PRESENTATION (one bar at a time, queued)
  // ==========================================================

  static void _enqueue(_IncomingAlert alert) {
    // Two messages from the same conversation back to back: keep the
    // newest one instead of showing both.
    _queue.removeWhere((a) => a.key == alert.key);
    _queue.add(alert);
    _showNext();
  }

  static void _showNext() {
    if (_currentEntry != null) return; // one is already on screen
    if (_queue.isEmpty) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    final alert = _queue.removeAt(0);

    // The user may have walked into that very conversation between the
    // message landing and this bar getting its turn in the queue.
    if (ActiveConversation.isOpen(alert.key)) {
      _showNext();
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _IncomingMessageBar(
        alert: alert,
        onDismissed: () {
          if (_currentEntry == entry) _currentEntry = null;
          entry.remove();
          Future.delayed(const Duration(milliseconds: 250), _showNext);
        },
        onTap: () => _openConversation(alert),
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }

  /// Tapping the bar opens the conversation the message came from,
  /// exactly like tapping the system notification would -- and by the
  /// SAME route the Chats list / Groups tab use, so the screen that
  /// opens is the one the user expects:
  ///
  ///   group                 -> GroupChatScreen(groupDocId)
  ///   connected (private)   -> PrivateChatScreen(otherUserUid)
  ///                            (its own header listener shows the
  ///                             private name/photo -- see the Chats
  ///                             list tile in pages/chat_page.dart)
  ///   not connected (public)-> ChatScreen(...) with the public
  ///                            name/photo the bar was already showing
  ///
  /// The conversation's read marker is written on the way in as well,
  /// so the unread dot and the unseen-messages reminder clear the same
  /// way they do when the conversation is opened from the list.
  static void _openConversation(_IncomingAlert alert) {
    final navigator = rootNavigatorKey.currentState;

    if (navigator != null) {
      _pushConversation(navigator, alert);
      return;
    }

    // Navigator not attached yet (can happen on a very early tap
    // during a cold start) -- retry on the next frame instead of
    // silently dropping the tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final retry = rootNavigatorKey.currentState;
      if (retry != null) _pushConversation(retry, alert);
    });
  }

  static void _pushConversation(
    NavigatorState navigator,
    _IncomingAlert alert,
  ) {
    // ---- group ----------------------------------------------------
    if (alert.isGroup) {
      if (alert.groupDocId.isEmpty) return;

      unawaited(markGroupRead(alert.groupDocId));

      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => GroupChatScreen(groupDocId: alert.groupDocId),
        ),
      );
      return;
    }

    // ---- 1-to-1 ---------------------------------------------------
    if (alert.otherUserUid.isEmpty) return;

    final myUid = FirebaseAuth.instance.currentUser?.uid ?? _ownerUid ?? '';
    final chatId = alert.chatDocId.isNotEmpty
        ? alert.chatDocId
        : (myUid.isEmpty
            ? ''
            : (<String>[myUid, alert.otherUserUid]..sort()).join('_'));

    if (chatId.isNotEmpty) unawaited(markChatRead(chatId));

    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => alert.usePrivateProfile
            ? PrivateChatScreen(otherUserUid: alert.otherUserUid)
            : ChatScreen(
                otherUserUid: alert.otherUserUid,
                otherUserName:
                    alert.title.isEmpty ? 'Unknown User' : alert.title,
                otherUserImage: alert.imageUrl,
              ),
      ),
    );
  }

  // ==========================================================
  // INLINE QUICK REPLY  (sends from the bar itself)
  // ----------------------------------------------------------
  // Writes the exact same document shape the real composers write,
  // so a message sent from the bar is indistinguishable from one
  // typed inside the conversation:
  //
  //   1-to-1  chats/<chatId>/messages   (chat_screen.dart)
  //   group   groups/<id>/messages      (groupchat.dart)
  //
  // `replyTo` is filled in best-effort: the bar only knows the
  // conversation's newest message text + sender, so the newest
  // message document is read once and used as the quote when it
  // still matches what the bar was showing. If it doesn't match
  // (the other side sent again in the meantime) the message is sent
  // as a plain message rather than quoting the wrong thing.
  // ==========================================================

  static Future<bool> _sendQuickReply(_IncomingAlert alert, String text) async {
    final body = text.trim();
    if (body.isEmpty) return false;

    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return false;

    try {
      if (alert.isGroup) {
        await _sendGroupQuickReply(alert, body, me.uid);
      } else {
        await _sendChatQuickReply(alert, body, me);
      }
      return true;
    } catch (e) {
      debugPrint('Quick reply send error: $e');
      return false;
    }
  }

  static Future<void> _sendChatQuickReply(
    _IncomingAlert alert,
    String text,
    User me,
  ) async {
    final chatId = alert.chatDocId.isNotEmpty
        ? alert.chatDocId
        : (<String>[me.uid, alert.otherUserUid]..sort()).join('_');

    final chatRef = FirebaseFirestore.instance.collection('chats').doc(chatId);
    final messagesRef = chatRef.collection('messages');

    final replyTo = await _quoteFor(
      messagesRef,
      senderField: 'senderId',
      orderField: 'sentAt',
      alert: alert,
    );

    final now = FieldValue.serverTimestamp();
    final isPrivate = alert.usePrivateProfile;

    await messagesRef.add({
      'senderId': me.uid,
      'receiverId': alert.otherUserUid,
      'text': text,
      'sentAt': now,
      'savedBy': <String>[],
      'expiresAt': isPrivate
          ? null
          : Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
      'chatTypeAtSend': isPrivate ? 'private' : 'public',
      'hiddenFor': <String>[],
      'readBy': <String>[],
      'replyTo': replyTo,
    });

    await chatRef.set({
      'participants': [me.uid, alert.otherUserUid],
      'lastMessage': text,
      'lastMessageTime': now,
      'lastMessageSenderId': me.uid,
      'otherUserUid': alert.otherUserUid,
      'hiddenFor': FieldValue.arrayRemove([me.uid]),
      'updatedAt': now,
    }, SetOptions(merge: true));

    // Push notification to the other side -- same worker endpoint the
    // chat screen's composer posts to.
    unawaited(_notifyOtherSide(alert.otherUserUid, text, me));
  }

  static Future<void> _sendGroupQuickReply(
    _IncomingAlert alert,
    String text,
    String myUid,
  ) async {
    final groupRef =
        FirebaseFirestore.instance.collection('groups').doc(alert.groupDocId);
    final messagesRef = groupRef.collection('messages');

    final replyTo = await _quoteFor(
      messagesRef,
      senderField: 'senderUid',
      orderField: 'sentAt',
      alert: alert,
    );

    await messagesRef.add({
      'senderUid': myUid,
      'text': text,
      'sentAt': FieldValue.serverTimestamp(),
      'replyTo': replyTo,
    });

    await groupRef.update({
      'lastMessage': text,
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessageSender': myUid,
    });
  }

  /// The `replyTo` map for the message the bar is showing, or null
  /// when it can no longer be identified with confidence.
  static Future<Map<String, dynamic>?> _quoteFor(
    CollectionReference<Map<String, dynamic>> messagesRef, {
    required String senderField,
    required String orderField,
    required _IncomingAlert alert,
  }) async {
    if (alert.senderUid.isEmpty) return null;

    try {
      final snap = await messagesRef
          .orderBy(orderField, descending: true)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return null;

      final doc = snap.docs.first;
      final data = doc.data();

      final sender = (data[senderField] ?? '').toString();
      final messageText = (data['text'] ?? '').toString().trim();

      // Only quote when this really is the message the bar showed.
      if (sender != alert.senderUid) return null;
      if (messageText.isEmpty || messageText != alert.body.trim()) return null;

      if (senderField == 'senderUid') {
        return <String, dynamic>{
          'messageId': doc.id,
          'senderUid': sender,
          'messageType': (data['messageType'] ?? 'text').toString(),
          'text': messageText,
        };
      }

      return <String, dynamic>{
        'messageId': doc.id,
        'senderId': sender,
        'text': messageText,
      };
    } catch (e) {
      debugPrint('Quick reply quote lookup error: $e');
      return null;
    }
  }

  static Future<void> _notifyOtherSide(
    String otherUid,
    String text,
    User me,
  ) async {
    if (otherUid.isEmpty) return;
    try {
      final receiver = await FirebaseFirestore.instance
          .collection('users')
          .doc(otherUid)
          .get();

      final token = (receiver.data()?['fcmToken'] ?? '').toString().trim();
      if (token.isEmpty) return;

      await http.post(
        Uri.parse('https://chatbot-worker.gokulmi56cro.workers.dev'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fcmToken': token,
          'senderName': me.displayName ?? 'New message',
          'message': text,
          'senderUid': me.uid,
        }),
      );
    } catch (e) {
      debugPrint('Quick reply notification error: $e');
    }
  }
}

// ================================================================
// THE BAR
// ----------------------------------------------------------------
// Same slot, entrance animation, swipe-to-dismiss and 5-second
// auto-dismiss as the other Nexus Notify bars (widgets/nexus_notify.dart),
// so it reads as one consistent notification system rather than a
// second, different-looking popup.
// ================================================================

class _IncomingMessageBar extends StatefulWidget {
  final _IncomingAlert alert;
  final VoidCallback onDismissed;
  final VoidCallback onTap;

  const _IncomingMessageBar({
    required this.alert,
    required this.onDismissed,
    required this.onTap,
  });

  @override
  State<_IncomingMessageBar> createState() => _IncomingMessageBarState();
}

class _IncomingMessageBarState extends State<_IncomingMessageBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  Timer? _autoDismissTimer;

  // ---- inline quick reply -------------------------------------
  /// True once "Reply" has been tapped: the composer takes the place
  /// of the "Reply" text, right here in the bar.
  bool _replying = false;
  bool _sending = false;

  late final TextEditingController _replyController;
  late final FocusNode _replyFocus;

  @override
  void initState() {
    super.initState();

    _replyController = TextEditingController();
    _replyFocus = FocusNode();
    _replyFocus.addListener(_handleReplyFocusChange);

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _entrance.forward();

    HapticFeedback.vibrate();

    _autoDismissTimer = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _dismiss() async {
    _autoDismissTimer?.cancel();
    _closeKeyboard();
    if (!mounted) {
      widget.onDismissed();
      return;
    }
    await _entrance.reverse();
    widget.onDismissed();
  }

  void _closeKeyboard() {
    if (_replyFocus.hasFocus) _replyFocus.unfocus();
  }

  // ==========================================================
  // REPLY  ->  composer, in place, on this same screen
  // ==========================================================

  /// Tapping "Reply": swap the text for the composer and pull the
  /// keyboard up immediately. Nothing is pushed on the navigator, so
  /// the user stays exactly where they were.
  void _startReply() {
    if (_replying) return;

    // No auto-dismiss while the user is typing.
    _autoDismissTimer?.cancel();

    setState(() => _replying = true);

    // autofocus on the field covers most cases; requesting it after
    // the frame as well makes the keyboard reliable on the first tap
    // even though this lives in an overlay entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _replyFocus.requestFocus();
    });
  }

  /// Dropping focus with an empty field collapses the composer back to
  /// the plain "Reply" text, and the normal 5-second auto-dismiss
  /// takes over again -- so an accidental tap can't leave the bar
  /// parked on screen forever.
  void _handleReplyFocusChange() {
    if (!mounted || _sending) return;
    if (_replyFocus.hasFocus) return;
    if (!_replying) return;
    if (_replyController.text.trim().isNotEmpty) return;

    setState(() => _replying = false);
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _sendReply() async {
    if (_sending) return;

    final text = _replyController.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    _autoDismissTimer?.cancel();

    final sent = await IncomingMessageAlert._sendQuickReply(widget.alert, text);

    if (!mounted) return;

    if (sent) {
      // Sent -> the bar's job is done, it leaves by itself.
      _replyController.clear();
      await _dismiss();
      return;
    }

    setState(() => _sending = false);
    _replyFocus.requestFocus();
  }

  /// Opens the conversation this bar is about. Used by the bar tap
  /// itself, and by the composer's [ + ] / mic (attachments and voice
  /// notes need the chat screen's own pickers, recorder and upload
  /// pipeline, so those hand over instead of faking it here).
  ///
  /// The push is fired BEFORE the bar's exit animation is awaited, so
  /// the navigation can never be lost to this widget being disposed
  /// mid-dismiss.
  bool _opening = false;

  Future<void> _openConversation() async {
    if (_opening) return; // double-tap guard
    _opening = true;

    _autoDismissTimer?.cancel();
    _closeKeyboard();

    widget.onTap();

    await _dismiss();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _replyFocus.removeListener(_handleReplyFocusChange);
    _replyFocus.dispose();
    _replyController.dispose();
    _entrance.dispose();
    super.dispose();
  }

  // ==========================================================
  // "Reply"  (collapsed state)
  // ==========================================================

  Widget _buildReplyAction() {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Its own recogniser, so this tap replies instead of bubbling
        // up to the bar's "open the conversation" tap.
        onTap: _startReply,
        child: Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2, right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.reply_rounded, color: AppColors.tan, size: 15),
              SizedBox(width: 4),
              Text(
                'Reply',
                style: TextStyle(
                  color: AppColors.tan,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // THE COMPOSER  (expanded state)
  // ----------------------------------------------------------
  // Deliberately the same shape as the bottom bar inside the chat
  // screen (pages/chat_screen.dart): [ + ] field [ send / mic ],
  // same fill, same tan border, same brown circle.
  // ==========================================================

  Widget _buildReplyComposer() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // ---- + (attachments live in the chat screen) ----
          SizedBox(
            width: 34,
            height: 44,
            child: IconButton(
              padding: EdgeInsets.zero,
              tooltip: 'Attach',
              onPressed: _sending ? null : _openConversation,
              icon: const Icon(
                Icons.add_rounded,
                color: AppColors.tan,
                size: 24,
              ),
            ),
          ),

          // ---- type holder ----
          Expanded(
            child: TextField(
              controller: _replyController,
              focusNode: _replyFocus,
              autofocus: true,
              enabled: !_sending,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              cursorColor: AppColors.tan,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Type a message...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: AppColors.darkSheet,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide(
                    color: AppColors.tan.withValues(alpha: 0.35),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: const BorderSide(color: AppColors.tan),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide(
                    color: AppColors.tan.withValues(alpha: 0.2),
                  ),
                ),
              ),
              onSubmitted: (_) => _sendReply(),
            ),
          ),

          const SizedBox(width: 8),

          // ---- send / voice message ----
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _replyController,
            builder: (context, value, _) {
              final hasText = value.text.trim().isNotEmpty;
              return Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.saddleBrown,
                ),
                child: _sending
                    ? const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: hasText ? 'Send' : 'Voice message',
                        onPressed: hasText ? _sendReply : _openConversation,
                        icon: Icon(
                          hasText ? Icons.send_rounded : Icons.mic_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final topPadding = MediaQuery.of(context).padding.top;
    final timeText = TimeOfDay.fromDateTime(alert.receivedAt).format(context);
    final image = _alertImageProvider(alert.imageUrl);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Material(
          color: Colors.transparent,
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _fade,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, topPadding > 0 ? 8 : 16, 16, 0),
                child: Dismissible(
                  key: ValueKey(
                    'incoming_${alert.key}_'
                    '${alert.receivedAt.millisecondsSinceEpoch}',
                  ),
                  // Swipe left OR right always takes the bar away,
                  // composer open or not.
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) {
                    _autoDismissTimer?.cancel();
                    _closeKeyboard();
                    widget.onDismissed();
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Tapping the bar (avatar, name, message -- anywhere
                    // outside the composer row) always goes straight
                    // into that conversation's screen.
                    onTap: () => unawaited(_openConversation()),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.darkSheet,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppColors.saddleBrown,
                          width: 1,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ---- profile photo (account or group) ----
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  CircleAvatar(
                                    radius: 22,
                                    backgroundColor: AppColors.darkAvatarBg,
                                    backgroundImage: image,
                                    child: image == null
                                        ? Icon(
                                            alert.isGroup
                                                ? Icons.groups_rounded
                                                : Icons.person_rounded,
                                            color: Colors.white70,
                                            size: 22,
                                          )
                                        : null,
                                  ),
                                  Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        color: AppColors.darkSheet,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.mark_chat_unread_rounded,
                                        color: Color(0xFF10B981),
                                        size: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 12),

                              // ---- name / (group sender) / message ----
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            alert.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          timeText,
                                          style: const TextStyle(
                                            color: AppColors.tan,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (alert.senderLine != null) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        alert.senderLine!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.glow,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 3),
                                    Text(
                                      alert.body,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.darkTextSecondary,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),

                                    // ---- "Reply" -> becomes the composer
                                    // in this very slot, no navigation ----
                                    if (!_replying) _buildReplyAction(),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          if (_replying)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // Swallows taps on the composer's own
                              // padding so typing a reply can't throw
                              // the user into the chat screen.
                              onTap: () {},
                              child: _buildReplyComposer(),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}