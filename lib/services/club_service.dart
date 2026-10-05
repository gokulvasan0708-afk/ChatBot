import 'package:cloud_firestore/cloud_firestore.dart';

import '../club/club_paths.dart';

// ================================================================
// CLUB SERVICE
// ----------------------------------------------------------------
// A Club is a STANDALONE entity. It does not belong to a Community
// and it is not a Group: one top-level 'clubs' collection, direct
// client-side Firestore writes, uid arrays for membership/roles.
//
// CLUB ID
// ----------------------------------------------------------------
// Generated with exactly the same rule a Group ID uses
// (see _CreateGroupDialogState._updateGroupIdPreview in
// groupstab.dart):
//     "@<club name>-<first 4 chars of creator's Account ID>"
//     e.g. "@Coding Club-A1B2"
// The Account ID is users/{uid}.userId. Group IDs are checked for
// uniqueness by the backend; clubs have no backend call, so
// createClub() runs the same uniqueness check itself: a quick query
// on the 'clubId' field of 'clubs' (covers older clubs), then a
// transaction that claims 'clubIds/{clubId}' and writes the club
// together, so two people creating the same ID at the same moment
// can never both succeed.
//
// The creator becomes the club's first "Club Leader" / owner.
// Recruitment (open positions + applications) lives in its own
// 'clubApplications' collection.
// ================================================================
class ClubService {
  ClubService._();

  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _clubs =>
      _firestore.collection('clubs');

  /// One tiny doc per Club ID ever claimed -- makes the ID unique
  /// atomically (see createClub).
  static CollectionReference<Map<String, dynamic>> get _clubIds =>
      _firestore.collection('clubIds');

  static String _clubIdKey(String clubId) => Uri.encodeComponent(clubId);

  static const List<String> joinModes = ['open', 'approval'];

  // ==========================================================
  // CLUB ID  (same rule as the Group ID)
  // "@<name>-<first 4 chars of creator's Account ID>"
  // ==========================================================

  /// Pure builder shared by the live preview and by createClub(), so
  /// the ID the user sees is always the ID that gets stored.
  static String buildClubId(String name, String creatorAccountId) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    final suffix = creatorAccountId.length >= 4
        ? creatorAccountId.substring(0, 4)
        : creatorAccountId;
    return '@$trimmed-$suffix';
  }

  /// The creator's full Account ID (users/{uid}.userId) -- the same
  /// field the Group create flow reads its ID suffix from.
  static Future<String> loadAccountId(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    return (doc.data()?['userId'] ?? '').toString();
  }

  static Future<bool> isClubIdTaken(String clubId) async {
    final existing =
        await _clubs.where('clubId', isEqualTo: clubId).limit(1).get();
    return existing.docs.isNotEmpty;
  }

  // ==========================================================
  // CREATE  (standalone -- no community, no group)
  // ==========================================================

  static Future<String> createClub({
    required String name,
    required String category,
    required String description,
    required String logoUrl,
    required String joinMode, // 'open' | 'approval'
    required String creatorUid,
    required String creatorAccountId,
    String bannerUrl = '',
    String? about,
    String rules = '',
    List<String> moderators = const <String>[],
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw Exception('Club name is required');
    }
    if (creatorAccountId.isEmpty) {
      throw Exception('Your account is still loading. Try again in a moment.');
    }

    final clubId = buildClubId(trimmedName, creatorAccountId);
    if (await isClubIdTaken(clubId)) {
      throw Exception('A club with the ID $clubId already exists. '
          'Choose a different club name.');
    }

    final ref = _clubs.doc();
    final idRef = _clubIds.doc(_clubIdKey(clubId));
    final data = <String, dynamic>{
      'clubId': clubId,
      'name': trimmedName,
      'category': category.trim(),
      'description': description.trim(),
      'about': (about ?? description).trim(),
      'rules': rules.trim(),
      'logoUrl': logoUrl,
      'avatarUrl': logoUrl,
      'bannerUrl': bannerUrl.trim(),
      'joinMode': joinModes.contains(joinMode) ? joinMode : 'open',
      'leaders': [creatorUid],
      'ownerUid': creatorUid,
      'ownerAccountId': creatorAccountId,
      'moderators': moderators,
      'members': [creatorUid],
      'membersCount': 1,
      'pendingRequests': <String>[],
      'openPositions': <Map<String, dynamic>>[],
      'createdBy': creatorUid,
      'createdAt': FieldValue.serverTimestamp(),
    };

    await _firestore.runTransaction((tx) async {
      if ((await tx.get(idRef)).exists) {
        throw Exception('A club with the ID $clubId already exists. '
            'Choose a different club name.');
      }
      tx.set(idRef, {
        'clubId': clubId,
        'clubDocId': ref.id,
        'ownerUid': creatorUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      tx.set(ref, data);
    });
    return ref.id;
  }

  // ==========================================================
  // READ
  // ==========================================================

  /// Every club the user is a member of. Clubs are standalone, so this
  /// reads the `clubs` collection directly (no community lookup).
  /// Sorted client-side (newest first) so no composite index is needed
  /// for `members` + `createdAt`.
  static Stream<List<Map<String, dynamic>>> watchMyClubs(String uid) {
    return _clubs.where('members', arrayContains: uid).snapshots().map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      list.sort((a, b) => _createdMillis(b['createdAt'])
          .compareTo(_createdMillis(a['createdAt'])));
      return list;
    });
  }

  // ==========================================================
  // COMMUNITY CLUBS  (completely separate from the Hubs clubs)
  // ----------------------------------------------------------
  // Same club, same pages, same rules -- but stored in their own
  // collections (see ClubPaths) and tied to ONE community. They are
  // listed only inside that community and never on Hubs > Clubs.
  // The Club ID is unique per community.
  // ==========================================================

  static CollectionReference<Map<String, dynamic>> get _communityClubs =>
      _firestore.collection(ClubPaths.communityClubs);

  static String _communityClubIdKey(String communityDocId, String clubId) =>
      '${Uri.encodeComponent(communityDocId)}__${Uri.encodeComponent(clubId)}';

  static Future<String> createCommunityClub({
    required String communityDocId,
    required String name,
    required String category,
    required String description,
    required String logoUrl,
    required String joinMode, // 'open' | 'approval'
    required String creatorUid,
    required String creatorAccountId,
    String bannerUrl = '',
    String? about,
    String rules = '',
  }) async {
    final trimmedName = name.trim();
    if (communityDocId.isEmpty) {
      throw Exception('Community not found.');
    }
    if (trimmedName.isEmpty) {
      throw Exception('Club name is required');
    }
    if (creatorAccountId.isEmpty) {
      throw Exception('Your account is still loading. Try again in a moment.');
    }

    final clubId = buildClubId(trimmedName, creatorAccountId);
    final docId = ClubPaths.newCommunityClubDocId();
    final ref = _communityClubs.doc(docId);
    final idRef = _firestore
        .collection(ClubPaths.communityClubIds)
        .doc(_communityClubIdKey(communityDocId, clubId));

    final data = <String, dynamic>{
      'communityDocId': communityDocId,
      'scope': 'community',
      'clubId': clubId,
      'name': trimmedName,
      'category': category.trim(),
      'description': description.trim(),
      'about': (about ?? description).trim(),
      'rules': rules.trim(),
      'logoUrl': logoUrl,
      'avatarUrl': logoUrl,
      'bannerUrl': bannerUrl.trim(),
      'joinMode': joinModes.contains(joinMode) ? joinMode : 'open',
      'leaders': [creatorUid],
      'ownerUid': creatorUid,
      'ownerAccountId': creatorAccountId,
      'moderators': <String>[],
      'members': [creatorUid],
      'membersCount': 1,
      'pendingRequests': <String>[],
      'openPositions': <Map<String, dynamic>>[],
      'createdBy': creatorUid,
      'createdAt': FieldValue.serverTimestamp(),
    };

    await _firestore.runTransaction((tx) async {
      if ((await tx.get(idRef)).exists) {
        throw Exception('A club with the ID $clubId already exists '
            'in this community. Choose a different club name.');
      }
      tx.set(idRef, {
        'communityDocId': communityDocId,
        'clubId': clubId,
        'clubDocId': docId,
        'ownerUid': creatorUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      tx.set(ref, data);
    });
    return docId;
  }

  /// Every club of ONE community, newest first. Sorted client-side so
  /// no composite index is needed.
  static Stream<List<Map<String, dynamic>>> watchCommunityClubs(
      String communityDocId) {
    return _communityClubs
        .where('communityDocId', isEqualTo: communityDocId)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      list.sort((a, b) => _createdMillis(b['createdAt'])
          .compareTo(_createdMillis(a['createdAt'])));
      return list;
    });
  }

  // A just-created club has a null createdAt until the server timestamp
  // lands -- treat it as newest.
  static int _createdMillis(dynamic v) => v is Timestamp
      ? v.millisecondsSinceEpoch
      : DateTime.now().millisecondsSinceEpoch;

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchClub(String clubDocId) {
    return ClubPaths.club(clubDocId).snapshots();
  }

  /// Updates the Phase 1 profile fields. Authorization is also checked
  /// client-side here; production Firestore Rules in Phase 6 must enforce
  /// the same owner/moderator restrictions server-side.
  static Future<void> updateClubProfile({
    required String clubDocId,
    required String requesterUid,
    required Map<String, dynamic> club,
    String? name,
    String? description,
    String? about,
    String? rules,
    String? avatarUrl,
    String? bannerUrl,
  }) async {
    _requireLeader(club, requesterUid);
    final updates = <String, dynamic>{};

    if (name != null && name.trim().isNotEmpty) {
      updates['name'] = name.trim();
    }
    if (description != null) updates['description'] = description.trim();
    if (about != null) updates['about'] = about.trim();
    if (rules != null) updates['rules'] = rules.trim();
    if (avatarUrl != null) {
      updates['avatarUrl'] = avatarUrl.trim();
      updates['logoUrl'] = avatarUrl.trim();
    }
    if (bannerUrl != null) updates['bannerUrl'] = bannerUrl.trim();

    if (updates.isNotEmpty) {
      updates['updatedAt'] = FieldValue.serverTimestamp();
      await ClubPaths.club(clubDocId).update(updates);
    }
  }

  /// Creates the future-proof role fields used by the Club Home UI.
  /// Existing `leaders` data remains untouched for backwards compatibility.
  static Future<void> setModerators({
    required String clubDocId,
    required String requesterUid,
    required Map<String, dynamic> club,
    required List<String> moderatorUids,
  }) async {
    _requireLeader(club, requesterUid);
    await ClubPaths.club(clubDocId).update({
      'moderators': moderatorUids.toSet().toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ==========================================================
  // JOIN / REQUEST / LEAVE
  // ==========================================================

  /// Returns 'joined' or 'requested' so the UI can show the right
  /// confirmation without a second read.
  static Future<String> joinOrRequest({
    required String clubDocId,
    required String uid,
  }) async {
    final ref = ClubPaths.club(clubDocId);
    final snap = await ref.get();
    if (!snap.exists) throw Exception('Club not found');
    final data = snap.data()!;

    final members = _asStringList(data['members']);
    if (members.contains(uid)) return 'joined';

    final joinMode = (data['joinMode'] ?? 'open').toString();
    if (joinMode == 'approval') {
      await ref.update({'pendingRequests': FieldValue.arrayUnion([uid])});
      return 'requested';
    }

    await ref.update({
      'members': FieldValue.arrayUnion([uid]),
      'membersCount': FieldValue.increment(1),
    });
    return 'joined';
  }

  static Future<void> cancelRequest({
    required String clubDocId,
    required String uid,
  }) async {
    await ClubPaths.club(clubDocId).update({
      'pendingRequests': FieldValue.arrayRemove([uid]),
    });
  }

  static Future<void> respondToRequest({
    required String clubDocId,
    required String requesterUid,
    required String reviewerUid,
    required Map<String, dynamic> club,
    required bool approve,
  }) async {
    _requireLeader(club, reviewerUid);
    final ref = ClubPaths.club(clubDocId);
    if (approve) {
      await ref.update({
        'pendingRequests': FieldValue.arrayRemove([requesterUid]),
        'members': FieldValue.arrayUnion([requesterUid]),
        'membersCount': FieldValue.increment(1),
      });
    } else {
      await ref.update({
        'pendingRequests': FieldValue.arrayRemove([requesterUid]),
      });
    }
  }

  static Future<void> leaveClub({
    required String clubDocId,
    required String uid,
    required Map<String, dynamic> club,
  }) async {
    final leaders = _asStringList(club['leaders']);
    if (leaders.contains(uid) && leaders.length == 1) {
      throw Exception('You\'re the only leader. Promote someone else first.');
    }
    await ClubPaths.club(clubDocId).update({
      'members': FieldValue.arrayRemove([uid]),
      'leaders': FieldValue.arrayRemove([uid]),
      'membersCount': FieldValue.increment(-1),
    });
  }

  static Future<void> removeMember({
    required String clubDocId,
    required String targetUid,
    required String requesterUid,
    required Map<String, dynamic> club,
  }) async {
    _requireLeader(club, requesterUid);
    await ClubPaths.club(clubDocId).update({
      'members': FieldValue.arrayRemove([targetUid]),
      'leaders': FieldValue.arrayRemove([targetUid]),
      'membersCount': FieldValue.increment(-1),
    });
  }

  // ==========================================================
  // LEADERSHIP (Section 12 — "Club Leader" role)
  // ==========================================================

  static Future<void> setLeader({
    required String clubDocId,
    required String targetUid,
    required String requesterUid,
    required Map<String, dynamic> club,
    required bool isLeader,
  }) async {
    _requireLeader(club, requesterUid);
    final leaders = _asStringList(club['leaders']);
    if (!isLeader && leaders.contains(targetUid) && leaders.length == 1) {
      throw Exception('A club needs at least one leader.');
    }
    await ClubPaths.club(clubDocId).update({
      'leaders': isLeader
          ? FieldValue.arrayUnion([targetUid])
          : FieldValue.arrayRemove([targetUid]),
    });
  }

  static void _requireLeader(Map<String, dynamic> club, String uid) {
    if (!isLeader(club, uid)) {
      throw Exception('Only Club Leaders can do that.');
    }
  }

  static bool isLeader(Map<String, dynamic> club, String uid) {
    return _asStringList(club['leaders']).contains(uid);
  }

  static bool isMember(Map<String, dynamic> club, String uid) {
    return _asStringList(club['members']).contains(uid);
  }

  static bool hasPendingRequest(Map<String, dynamic> club, String uid) {
    return _asStringList(club['pendingRequests']).contains(uid);
  }

  // ==========================================================
  // RECRUITMENT — OPEN POSITIONS
  // ==========================================================

  static Future<void> addOpenPosition({
    required String clubDocId,
    required String requesterUid,
    required Map<String, dynamic> club,
    required String title,
    required String skills,
    required String description,
  }) async {
    _requireLeader(club, requesterUid);
    final positions = _asMapList(club['openPositions']);
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    positions.add({
      'id': id,
      'title': title.trim(),
      'skills': skills.trim(),
      'description': description.trim(),
      'open': true,
    });
    await ClubPaths.club(clubDocId).update({'openPositions': positions});
  }

  static Future<void> setPositionOpen({
    required String clubDocId,
    required String requesterUid,
    required Map<String, dynamic> club,
    required String positionId,
    required bool open,
  }) async {
    _requireLeader(club, requesterUid);
    final positions = _asMapList(club['openPositions']);
    for (final p in positions) {
      if (p['id'] == positionId) p['open'] = open;
    }
    await ClubPaths.club(clubDocId).update({'openPositions': positions});
  }

  static Future<void> removeOpenPosition({
    required String clubDocId,
    required String requesterUid,
    required Map<String, dynamic> club,
    required String positionId,
  }) async {
    _requireLeader(club, requesterUid);
    final positions = _asMapList(club['openPositions'])
        .where((p) => p['id'] != positionId)
        .toList();
    await ClubPaths.club(clubDocId).update({'openPositions': positions});
  }

  // ==========================================================
  // RECRUITMENT — APPLICATIONS
  // ==========================================================

  static Future<void> applyToPosition({
    required String clubDocId,
    required String positionId,
    required String positionTitle,
    required String applicantUid,
    required String applicantName,
    required String applicantAvatarUrl,
    required String message,
  }) async {
    // One pending application per member per position.
    final existing = await ClubPaths.applications(clubDocId)
        .where('clubDocId', isEqualTo: clubDocId)
        .where('positionId', isEqualTo: positionId)
        .where('applicantUid', isEqualTo: applicantUid)
        .where('status', isEqualTo: 'pending')
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) {
      throw Exception('You already applied for this position.');
    }

    await ClubPaths.applications(clubDocId).doc().set({
      'clubDocId': clubDocId,
      'positionId': positionId,
      'positionTitle': positionTitle,
      'applicantUid': applicantUid,
      'applicantName': applicantName,
      'applicantAvatarUrl': applicantAvatarUrl,
      'message': message.trim(),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'reviewedAt': null,
      'reviewedBy': '',
    });
  }

  static Stream<List<Map<String, dynamic>>> watchApplications(String clubDocId) {
    return ClubPaths.applications(clubDocId)
        .where('clubDocId', isEqualTo: clubDocId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  static Stream<List<Map<String, dynamic>>> watchMyApplications({
    required String clubDocId,
    required String uid,
  }) {
    return ClubPaths.applications(clubDocId)
        .where('clubDocId', isEqualTo: clubDocId)
        .where('applicantUid', isEqualTo: uid)
        .snapshots()
        .map((snap) => snap.docs.map((d) => {...d.data(), 'id': d.id}).toList());
  }

  static Future<void> reviewApplication({
    required String applicationId,
    required String clubDocId,
    required String reviewerUid,
    required Map<String, dynamic> club,
    required bool accept,
  }) async {
    _requireLeader(club, reviewerUid);

    final appRef = ClubPaths.applications(clubDocId).doc(applicationId);
    await appRef.update({
      'status': accept ? 'accepted' : 'rejected',
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': reviewerUid,
    });

    if (accept) {
      final appDoc = await appRef.get();
      final applicantUid = (appDoc.data()?['applicantUid'] ?? '').toString();
      if (applicantUid.isNotEmpty) {
        final ref = ClubPaths.club(clubDocId);
        final snap = await ref.get();
        final members = _asStringList(snap.data()?['members']);
        if (!members.contains(applicantUid)) {
          await ref.update({
            'members': FieldValue.arrayUnion([applicantUid]),
            'membersCount': FieldValue.increment(1),
          });
        }
      }
    }
  }

  // ==========================================================
  // HELPERS
  // ==========================================================

  static List<String> _asStringList(dynamic v) =>
      v is List ? List<String>.from(v) : <String>[];

  static List<Map<String, dynamic>> _asMapList(dynamic v) {
    if (v is! List) return <Map<String, dynamic>>[];
    return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
