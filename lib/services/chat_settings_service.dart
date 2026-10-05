import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Per-account chat controls and presence helpers.
///
/// Settings are stored per relationship so a nickname/mute/block/visibility
/// choice belongs to the user who created it and is not exposed globally.
class ChatSettingsService {
  ChatSettingsService._();
  static final ChatSettingsService instance = ChatSettingsService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> settingsRef({
    required String ownerUid,
    required String otherUid,
  }) => _db
      .collection('users')
      .doc(ownerUid)
      .collection('chatSettings')
      .doc(otherUid);

  Stream<Map<String, dynamic>> watchSettings({
    required String ownerUid,
    required String otherUid,
  }) => settingsRef(ownerUid: ownerUid, otherUid: otherUid)
      .snapshots()
      .map((d) => d.data() ?? <String, dynamic>{});

  Future<Map<String, dynamic>> getSettings({
    required String ownerUid,
    required String otherUid,
  }) async {
    final d = await settingsRef(ownerUid: ownerUid, otherUid: otherUid).get();
    return d.data() ?? <String, dynamic>{};
  }

  Future<void> setSetting({
    required String ownerUid,
    required String otherUid,
    required String field,
    required dynamic value,
  }) async {
    await settingsRef(ownerUid: ownerUid, otherUid: otherUid).set(
      {field: value, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<void> setNickname(String otherUid, String nickname) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'nickname',
      value: nickname.trim(),
    );
  }

  Future<void> setActiveInfo(String otherUid, bool enabled) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'activeInfoEnabled',
      value: enabled,
    );
  }

  Future<void> setTypingInfo(String otherUid, bool enabled) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'typingInfoEnabled',
      value: enabled,
    );
  }

  /// Grants (or revokes) [otherUid]'s permission to voice-call ME.
  ///
  /// This is stored under MY OWN doc (ownerUid: me, otherUid: them) --
  /// same direction as setActiveInfo/setTypingInfo -- so "I enable voice
  /// call" always means "I'm letting *them* call *me*", never "I can now
  /// call them". Whether *I* can call *them* depends entirely on whether
  /// *they* have separately enabled it for me (see
  /// isVoiceCallEnabledForMeBy / the chat screen's use of
  /// `_otherSettings['voiceCallEnabled']`).
  Future<void> setVoiceCallEnabled(String otherUid, bool enabled) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'voiceCallEnabled',
      value: enabled,
    );
  }

  /// Same one-directional model as [setVoiceCallEnabled] above, but
  /// for video calls -- kept as its own field so a person can allow
  /// one without the other.
  Future<void> setVideoCallEnabled(String otherUid, bool enabled) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'videoCallEnabled',
      value: enabled,
    );
  }

  Future<void> setMuted(String otherUid, bool muted) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'muted',
      value: muted,
    );
  }

  Future<void> setBlocked(String otherUid, bool blocked) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    await setSetting(
      ownerUid: me.uid,
      otherUid: otherUid,
      field: 'blocked',
      value: blocked,
    );
  }

  Future<bool> isBlockedByOther(String otherUid) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return false;
    final data = await getSettings(ownerUid: otherUid, otherUid: me.uid);
    return data['blocked'] == true;
  }

  Future<bool> isMutedByMe(String otherUid) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return false;
    final data = await getSettings(ownerUid: me.uid, otherUid: otherUid);
    return data['muted'] == true;
  }

  /// Updates app-level presence and/or the typing indicator.
  ///
  /// [active] is intentionally nullable: pass `true`/`false` when you are
  /// actually reporting whether the app itself is foregrounded (e.g. from
  /// an app-level lifecycle observer). Pass it as `null` (or simply omit
  /// it) when you only want to update the typing indicator -- e.g. when a
  /// single chat screen is opened/closed -- so that a screen-level action
  /// never overwrites the real app-level online/offline status.
  Future<void> updatePresence({
    bool? active,
    String? typingToUid,
  }) async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    final Map<String, dynamic> update = {
      'isTyping': typingToUid != null && typingToUid.isNotEmpty,
      'typingToUid': typingToUid ?? '',
    };
    if (active != null) {
      update['isActive'] = active;
      update['lastActiveAt'] = FieldValue.serverTimestamp();
    }
    await _db.collection('users').doc(me.uid).set(update, SetOptions(merge: true));
  }

  String activeLabel(Map<String, dynamic> data) {
    if (data['isActive'] == true) return 'Active now';
    final raw = data['lastActiveAt'];
    if (raw is! Timestamp) return '';
    final diff = DateTime.now().difference(raw.toDate());
    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes} min ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours} hr ago';
    return 'Active ${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
}