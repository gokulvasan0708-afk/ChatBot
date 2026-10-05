import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

// ================================================================
// COMMUNITY BADGE SERVICE
// ----------------------------------------------------------------
// Powers the "new" badges on the Community Home quick-nav cards:
//
//   * Announcements / Events / Feed / Polls / Activities show a
//     NUMBER = how many items other people posted since the current
//     user last opened that section.
//   * Groups and Community Chat show a DOT (a new group, or unread
//     group messages / unread community chat messages).
//
// "Last opened" markers live on the user's OWN user doc, so no
// extra Firestore rules are needed (the user already writes there
// for presence/typing):
//
//   users/<uid> {
//     communitySeen: { <communityDocId>: { <section>: <Timestamp> } }
//   }
//
// Group / chat unread uses the marker the app already keeps:
// groups/<id>.lastReadAt[<uid>] vs groups/<id>.lastMessageAt
// (same rule as the dot on the Groups tab).
// ================================================================
class CommunityBadgeService {
  CommunityBadgeService._();

  /// Sections that keep a "last opened" marker.
  static const List<String> sections = [
    'announcements',
    'events',
    'feed',
    'polls',
    'activities',
    'groups',
  ];

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ==========================================================
  // LAST-SEEN MARKERS
  // ==========================================================

  /// section -> last time the current user opened it (this community).
  static Stream<Map<String, DateTime>> watchSeen(String communityDocId) {
    final uid = _uid;
    if (uid == null) return Stream.value(<String, DateTime>{});

    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((snap) {
      final out = <String, DateTime>{};
      final root = snap.data()?['communitySeen'];
      final mine = root is Map ? root[communityDocId] : null;
      if (mine is Map) {
        mine.forEach((key, value) {
          if (value is Timestamp) out[key.toString()] = value.toDate();
        });
      }
      return out;
    }).distinct((a, b) => mapEquals(a, b));
  }

  /// Marks the given sections as "seen right now" (server time).
  static Future<void> markSeen(
    String communityDocId, {
    required List<String> sections,
  }) async {
    final uid = _uid;
    if (uid == null || communityDocId.isEmpty || sections.isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {
          'communitySeen': {
            communityDocId: {
              for (final s in sections) s: FieldValue.serverTimestamp(),
            },
          },
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('Community markSeen error: $e');
    }
  }

  // ==========================================================
  // COUNTING
  // ==========================================================

  static DateTime? dateOf(dynamic v) => v is Timestamp ? v.toDate() : null;

  /// Number of items created after [seenAt] by someone other than
  /// [uid]. Returns 0 when [seenAt] is null (no baseline yet) so an
  /// old community never opens with a huge number.
  static int countNew(
    List<Map<String, dynamic>> items, {
    required DateTime? seenAt,
    required String uid,
    required String authorKey,
    DateTime? Function(Map<String, dynamic> item)? dateGetter,
    bool Function(Map<String, dynamic> item)? include,
  }) {
    if (seenAt == null) return 0;

    var count = 0;
    for (final item in items) {
      if (include != null && !include(item)) continue;
      if ((item[authorKey] ?? '').toString() == uid) continue;
      final created =
          dateGetter != null ? dateGetter(item) : dateOf(item['createdAt']);
      if (created != null && created.isAfter(seenAt)) count++;
    }
    return count;
  }

  // ==========================================================
  // GROUP / CHAT UNREAD
  // ==========================================================

  /// Same rule as the dot on the Groups tab: someone ELSE's message
  /// is newer than my last read marker.
  static bool groupHasUnread(
    Map<String, dynamic> group,
    String uid, {
    DateTime? localReadAt,
  }) {
    if (uid.isEmpty) return false;

    final lastMessageAt = dateOf(group['lastMessageAt']);
    final sender = (group['lastMessageSender'] ?? '').toString();
    if (lastMessageAt == null || sender.isEmpty || sender == uid) {
      return false;
    }

    DateTime? readAt = localReadAt;
    final readMap = group['lastReadAt'];
    if (readMap is Map) {
      final serverRead = dateOf(readMap[uid]);
      if (serverRead != null && (readAt == null || serverRead.isAfter(readAt))) {
        readAt = serverRead;
      }
    }

    return readAt == null || lastMessageAt.isAfter(readAt);
  }

  static bool isMember(Map<String, dynamic> group, String uid) {
    final members = group['members'];
    return members is List && members.contains(uid);
  }

  static bool isMuted(Map<String, dynamic> group, String uid) {
    final muted = group['mutedBy'];
    return muted is Map && muted[uid] == true;
  }
}
