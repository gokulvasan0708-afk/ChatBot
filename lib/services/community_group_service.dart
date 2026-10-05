import 'package:cloud_firestore/cloud_firestore.dart';

// ================================================================
// COMMUNITY GROUP SERVICE  (Community spec — Section 3)
// ----------------------------------------------------------------
// "Groups" here are the community's own focused-discussion spaces
// (IT 2nd Year, Placement Discussion, ...) -- a different thing from
// the personal password-protected Groups in groupstab.dart, and a
// different thing from the single auto-created "Community Chat"
// CommunityService already sets up for every community.
//
// Same trick as that Community Chat, applied per-group: every
// community group is, byte-for-byte, a real doc in the SAME 'groups'
// collection GroupChatScreen already reads -- so as soon as someone
// is a member, opening the group just pushes GroupChatScreen with
// no changes needed there. Mute/calls-toggle/typing/reactions all
// keep working because that screen already reads mutedBy/
// callsEnabledBy/members etc. straight off the doc.
//
// No backend/password involved (unlike personal groups) -- type-based
// join rules are enforced here as plain Firestore rules instead:
//   - public     : join instantly
//   - temporary  : join instantly, auto-archives after expiresAt
//   - approval   : request to join, an admin approves/rejects
//   - private    : invite-only -- an admin adds a member directly,
//                  there is no public "Join" action at all
// ================================================================
class CommunityGroupService {
  CommunityGroupService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _groups =>
      _firestore.collection('groups');

  static CollectionReference<Map<String, dynamic>> get _reports =>
      _firestore.collection('reports');

  static const List<String> groupTypes = ['public', 'private', 'approval', 'temporary'];

  // ==========================================================
  // CREATE
  // ==========================================================

  static Future<String> createGroup({
    required String communityDocId,
    required String name,
    required String description,
    required String imageUrl,
    required String groupType, // 'public' | 'private' | 'approval' | 'temporary'
    DateTime? expiresAt,
    required String creatorUid,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw Exception('Group name is required');
    }
    final type = groupTypes.contains(groupType) ? groupType : 'public';
    if (type == 'temporary' && expiresAt == null) {
      throw Exception('Temporary groups need an expiry date');
    }

    final ref = _groups.doc();
    await ref.set({
      'groupId': ref.id,
      'groupName': trimmedName,
      'groupProfileImage': imageUrl,
      'description': description.trim(),
      'adminUid': creatorUid,
      'coAdminUids': <String>[],
      'members': [creatorUid],
      'membersCount': 1,
      'mutedBy': <String, dynamic>{},
      'callsEnabledBy': <String, dynamic>{},
      'pendingMembers': <String>[],
      'communityDocId': communityDocId,
      'isCommunityChat': false,
      'groupType': type,
      'expiresAt': expiresAt == null ? null : Timestamp.fromDate(expiresAt),
      'archived': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Every community group EXCEPT the one auto-created "Community
  /// Chat" doc, which the Community Home screen already surfaces on
  /// its own -- listing it again here would just be a duplicate.
  static Stream<List<Map<String, dynamic>>> watchGroups(String communityDocId) {
    return _groups
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs
          .where((d) => d.data()['isCommunityChat'] != true)
          .map((d) => {...d.data(), 'id': d.id})
          .toList();
      int ms(dynamic v) => v is Timestamp ? v.millisecondsSinceEpoch : 0;
      list.sort((a, b) => ms(b['createdAt']).compareTo(ms(a['createdAt'])));
      return list;
    });
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchGroup(String groupDocId) {
    return _groups.doc(groupDocId).snapshots();
  }

  /// Temporary groups pass their expiry and stop showing as active --
  /// nothing is deleted, spec section 3's "automatically become
  /// archived after expiration" is just this check on read.
  static bool isExpired(Map<String, dynamic> group) {
    if (group['archived'] == true) return true;
    final expiresAt = (group['expiresAt'] as Timestamp?)?.toDate();
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt);
  }

  // ==========================================================
  // JOIN / REQUEST / INVITE / LEAVE
  // ==========================================================

  /// Returns 'joined' or 'requested'. Throws for private groups or
  /// an expired temporary group.
  static Future<String> joinOrRequest({
    required String groupDocId,
    required String uid,
    required Map<String, dynamic> group,
  }) async {
    if (isExpired(group)) {
      throw Exception('This group has expired and is now archived.');
    }
    final members = _asStringList(group['members']);
    if (members.contains(uid)) return 'joined';

    final type = (group['groupType'] ?? 'public').toString();
    if (type == 'private') {
      throw Exception('This group is invite-only. Ask an admin to invite you.');
    }
    if (type == 'approval') {
      await _groups.doc(groupDocId).update({
        'pendingMembers': FieldValue.arrayUnion([uid]),
      });
      return 'requested';
    }

    await _groups.doc(groupDocId).update({
      'members': FieldValue.arrayUnion([uid]),
      'membersCount': FieldValue.increment(1),
    });
    return 'joined';
  }

  static Future<void> cancelRequest({
    required String groupDocId,
    required String uid,
  }) async {
    await _groups.doc(groupDocId).update({
      'pendingMembers': FieldValue.arrayRemove([uid]),
    });
  }

  static Future<void> respondToRequest({
    required String groupDocId,
    required String requesterUid,
    required String reviewerUid,
    required Map<String, dynamic> group,
    required bool approve,
  }) async {
    _requireAdmin(group, reviewerUid);
    final ref = _groups.doc(groupDocId);
    if (approve) {
      await ref.update({
        'pendingMembers': FieldValue.arrayRemove([requesterUid]),
        'members': FieldValue.arrayUnion([requesterUid]),
        'membersCount': FieldValue.increment(1),
      });
    } else {
      await ref.update({'pendingMembers': FieldValue.arrayRemove([requesterUid])});
    }
  }

  /// Directly adds a member -- the only way into a "private" group,
  /// and a shortcut past approval for the others.
  static Future<void> inviteMember({
    required String groupDocId,
    required String targetUid,
    required String requesterUid,
    required Map<String, dynamic> group,
  }) async {
    _requireAdmin(group, requesterUid);
    final members = _asStringList(group['members']);
    if (members.contains(targetUid)) return;
    await _groups.doc(groupDocId).update({
      'members': FieldValue.arrayUnion([targetUid]),
      'membersCount': FieldValue.increment(1),
      'pendingMembers': FieldValue.arrayRemove([targetUid]),
    });
  }

  static Future<void> leaveGroup({
    required String groupDocId,
    required String uid,
    required Map<String, dynamic> group,
  }) async {
    if ((group['adminUid'] ?? '').toString() == uid) {
      throw Exception('You\'re the group admin. Promote someone else first.');
    }
    await _groups.doc(groupDocId).update({
      'members': FieldValue.arrayRemove([uid]),
      'coAdminUids': FieldValue.arrayRemove([uid]),
      'membersCount': FieldValue.increment(-1),
    });
  }

  static Future<void> removeMember({
    required String groupDocId,
    required String targetUid,
    required String requesterUid,
    required Map<String, dynamic> group,
  }) async {
    _requireAdmin(group, requesterUid);
    await _groups.doc(groupDocId).update({
      'members': FieldValue.arrayRemove([targetUid]),
      'coAdminUids': FieldValue.arrayRemove([targetUid]),
      'membersCount': FieldValue.increment(-1),
    });
  }

  // ==========================================================
  // ROLES (Section 12 — "Group Admin")
  // ==========================================================

  static Future<void> setCoAdmin({
    required String groupDocId,
    required String targetUid,
    required String requesterUid,
    required Map<String, dynamic> group,
    required bool isCoAdmin,
  }) async {
    _requireAdmin(group, requesterUid);
    await _groups.doc(groupDocId).update({
      'coAdminUids': isCoAdmin
          ? FieldValue.arrayUnion([targetUid])
          : FieldValue.arrayRemove([targetUid]),
    });
  }

  static void _requireAdmin(Map<String, dynamic> group, String uid) {
    if (!isAdmin(group, uid)) {
      throw Exception('Only group admins can do that.');
    }
  }

  static bool isAdmin(Map<String, dynamic> group, String uid) {
    if ((group['adminUid'] ?? '').toString() == uid) return true;
    return _asStringList(group['coAdminUids']).contains(uid);
  }

  static bool isMember(Map<String, dynamic> group, String uid) =>
      _asStringList(group['members']).contains(uid);

  static bool hasPendingRequest(Map<String, dynamic> group, String uid) =>
      _asStringList(group['pendingMembers']).contains(uid);

  // ==========================================================
  // ARCHIVE / DELETE
  // ==========================================================

  static Future<void> archiveNow({
    required String groupDocId,
    required String requesterUid,
    required Map<String, dynamic> group,
  }) async {
    _requireAdmin(group, requesterUid);
    await _groups.doc(groupDocId).update({'archived': true});
  }

  static Future<void> deleteGroup({
    required String groupDocId,
    required String requesterUid,
    required Map<String, dynamic> group,
  }) async {
    if ((group['adminUid'] ?? '').toString() != requesterUid) {
      throw Exception('Only the group admin can delete this group.');
    }
    await _groups.doc(groupDocId).delete();
  }

  // ==========================================================
  // MODERATION — REPORT (spec section 13, group-level)
  // ==========================================================

  static Future<void> reportGroup({
    required String groupDocId,
    required String communityDocId,
    required String reporterUid,
    required String category,
    required String details,
  }) async {
    await _reports.doc().set({
      'type': 'group',
      'targetId': groupDocId,
      'communityDocId': communityDocId,
      'reporterUid': reporterUid,
      'category': category,
      'details': details.trim(),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static List<String> _asStringList(dynamic v) =>
      v is List ? List<String>.from(v) : <String>[];
}