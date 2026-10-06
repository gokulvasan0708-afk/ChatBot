import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_service.dart';

// ================================================================
// ANNOUNCEMENT SERVICE  (Community spec — Section 2)
// ----------------------------------------------------------------
// Mirrors the exact pattern CommunityService already established:
// a top-level Firestore collection ('announcements'), direct
// client-side writes (no backend Worker needed — nothing here
// requires the Admin SDK), and CommunityService.isPrivileged() as
// the single source of truth for "who is allowed to do this".
//
// One announcement document = one 'announcements' doc, scoped to a
// communityDocId. Supports every announcement type in the spec
// (text/image/video/document/link/poll/event), pinning, editing,
// deleting, reporting, per-user read state, reactions, scheduling,
// an urgent flag, and audience targeting (entire community / a
// specific year / a specific department — Group- and Club-specific
// targeting will plug in the same way once those subsystems exist).
// ================================================================
class AnnouncementService {
  AnnouncementService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _announcements =>
      _firestore.collection('announcements');

  // ==========================================================
  // TYPES / TARGETING — kept as plain strings (same style as
  // Community.type) so new types/targets can be added without a
  // schema migration.
  // ==========================================================

  static const List<String> types = [
    'text',
    'image',
    'video',
    'document',
    'link',
    'poll',
    'event',
  ];

  static const List<String> audienceKinds = [
    'community', // entire community
    'year', // a specific year, e.g. "2nd Year"
    'department', // a specific department, e.g. "IT"
  ];

  // ==========================================================
  // CREATE
  // ==========================================================

  static Future<String> createAnnouncement({
    required String communityDocId,
    required String authorUid,
    required String authorName,
    required String authorAvatarUrl,
    required String type, // one of [types]
    required String title,
    required String body,
    String mediaUrl = '',
    String linkUrl = '',
    String audienceKind = 'community', // one of [audienceKinds]
    String audienceValue = '', // e.g. "2nd Year" / "IT"
    bool isUrgent = false,
    DateTime? scheduledFor,
    // "Show to all College": also listed on other colleges' Notice Boards.
    bool showToAllColleges = false,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw Exception('Announcement title is required');
    }

    final now = DateTime.now();
    final isScheduled = scheduledFor != null && scheduledFor.isAfter(now);

    final ref = _announcements.doc();
    await ref.set({
      'communityDocId': communityDocId,
      'authorUid': authorUid,
      'authorName': authorName,
      'authorAvatarUrl': authorAvatarUrl,
      'type': types.contains(type) ? type : 'text',
      'title': trimmedTitle,
      'body': body.trim(),
      'mediaUrl': mediaUrl,
      'linkUrl': linkUrl,
      'audienceKind': audienceKinds.contains(audienceKind) ? audienceKind : 'community',
      'audienceValue': audienceValue.trim(),
      'isUrgent': isUrgent,
      'showToAllColleges': showToAllColleges,
      'isPinned': false,
      'isScheduled': isScheduled,
      'scheduledFor': isScheduled ? Timestamp.fromDate(scheduledFor) : null,
      'publishedAt': isScheduled ? null : FieldValue.serverTimestamp(),
      'reactions': <String, dynamic>{}, // uid -> emoji
      'readBy': <String>[],
      'reportedBy': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
      'editedAt': null,
    });
    return ref.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Live feed for a community, newest first. Scheduled announcements
  /// whose time hasn't arrived yet are filtered out client-side so a
  /// single index covers both the normal and privileged views.
  static Stream<List<Map<String, dynamic>>> watchAnnouncements(
    String communityDocId, {
    bool includeUnpublishedScheduled = false,
  }) {
    return _announcements
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final now = DateTime.now();
      final docs = snap.docs.map((d) => {...d.data(), 'id': d.id}).where((a) {
        final isScheduled = a['isScheduled'] == true;
        if (!isScheduled) return true;
        if (includeUnpublishedScheduled) return true;
        final scheduledFor = (a['scheduledFor'] as Timestamp?)?.toDate();
        return scheduledFor != null && !scheduledFor.isAfter(now);
      }).toList();

      // Pinned first, then newest first (createdAt already descending).
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      docs.sort((a, b) {
        final pinnedA = a['isPinned'] == true;
        final pinnedB = b['isPinned'] == true;
        if (pinnedA != pinnedB) return pinnedA ? -1 : 1;
        return ms(b['createdAt']).compareTo(ms(a['createdAt']));
      });
      return docs;
    });
  }

  static Future<Map<String, dynamic>?> getAnnouncement(String id) async {
    final doc = await _announcements.doc(id).get();
    if (!doc.exists) return null;
    return {...doc.data()!, 'id': doc.id};
  }

  // ==========================================================
  // EDIT / DELETE / PIN
  // ==========================================================

  static Future<void> editAnnouncement({
    required String id,
    required String requesterUid,
    required Map<String, dynamic> community,
    String? title,
    String? body,
    bool? isUrgent,
  }) async {
    await _requireAuthorOrPrivileged(id, requesterUid, community);
    final update = <String, dynamic>{'editedAt': FieldValue.serverTimestamp()};
    if (title != null) update['title'] = title.trim();
    if (body != null) update['body'] = body.trim();
    if (isUrgent != null) update['isUrgent'] = isUrgent;
    await _announcements.doc(id).update(update);
  }

  static Future<void> deleteAnnouncement({
    required String id,
    required String requesterUid,
    required Map<String, dynamic> community,
  }) async {
    await _requireAuthorOrPrivileged(id, requesterUid, community);
    await _announcements.doc(id).delete();
  }

  static Future<void> setPinned({
    required String id,
    required String requesterUid,
    required Map<String, dynamic> community,
    required bool pinned,
  }) async {
    if (!CommunityService.isPrivileged(community, requesterUid)) {
      throw Exception('Only Community admins/moderators can pin announcements.');
    }
    await _announcements.doc(id).update({'isPinned': pinned});
  }

  static Future<void> _requireAuthorOrPrivileged(
    String id,
    String requesterUid,
    Map<String, dynamic> community,
  ) async {
    if (CommunityService.isPrivileged(community, requesterUid)) return;
    final doc = await _announcements.doc(id).get();
    final authorUid = (doc.data()?['authorUid'] ?? '').toString();
    if (authorUid != requesterUid) {
      throw Exception('You don\'t have permission to do that.');
    }
  }

  /// Normal members can create announcements ONLY for their own
  /// personal feed-style posts elsewhere; true Announcements require
  /// Community admin/moderator permission (spec: "Normal members
  /// should not be able to create admin announcements").
  static bool canCreate(Map<String, dynamic> community, String uid) {
    return CommunityService.isPrivileged(community, uid);
  }

  // ==========================================================
  // READ / UNREAD STATE
  // ==========================================================

  static Future<void> markRead({
    required String id,
    required String uid,
  }) async {
    await _announcements.doc(id).update({
      'readBy': FieldValue.arrayUnion([uid]),
    });
  }

  static bool isRead(Map<String, dynamic> announcement, String uid) {
    final readBy = announcement['readBy'] is List
        ? List<String>.from(announcement['readBy'])
        : <String>[];
    return readBy.contains(uid);
  }

  // ==========================================================
  // REACTIONS
  // ==========================================================

  static Future<void> setReaction({
    required String id,
    required String uid,
    required String emoji, // pass '' to remove the reaction
  }) async {
    final ref = _announcements.doc(id);
    if (emoji.isEmpty) {
      await ref.update({'reactions.$uid': FieldValue.delete()});
    } else {
      await ref.update({'reactions.$uid': emoji});
    }
  }

  // ==========================================================
  // REPORT
  // ==========================================================

  static Future<void> report({
    required String id,
    required String uid,
  }) async {
    await _announcements.doc(id).update({
      'reportedBy': FieldValue.arrayUnion([uid]),
    });
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  /// Whether the given announcement should be visible to a member
  /// with the supplied year/department (from their Community profile,
  /// once section 10's per-community profile fields exist). Until
  /// then, `memberYear`/`memberDepartment` may be passed empty and
  /// only community-wide announcements will match — never hides a
  /// community-wide announcement, never guesses a match.
  static bool isVisibleTo({
    required Map<String, dynamic> announcement,
    required String memberYear,
    required String memberDepartment,
  }) {
    final kind = (announcement['audienceKind'] ?? 'community').toString();
    if (kind == 'community') return true;

    final value = (announcement['audienceValue'] ?? '').toString().trim();
    if (value.isEmpty) return true;

    if (kind == 'year') return memberYear.trim() == value;
    if (kind == 'department') return memberDepartment.trim() == value;
    return true;
  }

  static int unreadCount(List<Map<String, dynamic>> announcements, String uid) {
    return announcements.where((a) => !isRead(a, uid)).length;
  }
}